#!/usr/bin/env bash
# shellcheck disable=SC2329 # Fixtures are invoked by sourced functions / the harness.
set -euo pipefail
exec < /dev/null
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export QUENCH_TEST_MODE=1
# shellcheck source=/dev/null
source "$ROOT/vps-quench.sh"
# shellcheck source=tests/lib/harness.sh
source "$ROOT/tests/lib/harness.sh"

t_answers() {
    local ANSWER INPUT
    for INPUT in y Y yes YES YeS $' \tyEs\t '; do
        assert_ok ui_read_yes_no ANSWER 'Test (y/N): ' n <<< "$INPUT"
        assert_eq "$ANSWER" y
    done
    for INPUT in n N no NO nO $' \tNo\t '; do
        assert_ok ui_read_yes_no ANSWER 'Test (Y/n): ' y <<< "$INPUT"
        assert_eq "$ANSWER" n
    done
}
run_test 'Y/n and yes/no accept mixed case and surrounding whitespace' t_answers

t_defaults() {
    local ANSWER DEFAULT
    for DEFAULT in y n; do
        assert_ok ui_read_yes_no ANSWER 'Test: ' "$DEFAULT" <<< ''
        assert_eq "$ANSWER" "$DEFAULT"
        assert_ok ui_read_yes_no ANSWER 'Test: ' "$DEFAULT" <<< $' \t '
        assert_eq "$ANSWER" "$DEFAULT"
    done
    assert_fail ui_read_yes_no ANSWER 'Test: ' unknown <<< y
    assert_fail ui_read_yes_no 'array[0]' 'Test: ' n <<< y
}
run_test 'Enter keeps the original default; invalid helper arguments fail closed' t_defaults

t_retry() {
    local ANSWER FOLLOWING
    {
        assert_ok ui_read_yes_no ANSWER 'Test (y/N): ' n
        assert_eq "$ANSWER" y
        IFS= read -r FOLLOWING || fail 'The confirmation consumed the next prompt'
        assert_eq "$FOLLOWING" next-step
    } <<< $'yy\nsure\ny n\n1\nYeS\nnext-step' 2> "$TMP/retry-errors"
    assert_eq "$(grep -c '输入无效' "$TMP/retry-errors")" 4
}
run_test 'Invalid answers retry only this prompt and preserve the following input' t_retry

t_retry_no() {
    local ANSWER
    assert_ok ui_read_yes_no ANSWER 'Test (Y/n): ' y <<< $'yy\nNO'
    assert_eq "$ANSWER" n
}
run_test 'A typo cannot implicitly accept a default-yes prompt' t_retry_no

t_eof() {
    local ANSWER DEFAULT
    for DEFAULT in y n; do
        ANSWER=y
        assert_fail ui_read_yes_no ANSWER 'Test: ' "$DEFAULT" < /dev/null
        assert_eq "$ANSWER" ''
        ANSWER=y
        assert_fail ui_read_yes_no ANSWER 'Test: ' "$DEFAULT" <<< yy
        assert_eq "$ANSWER" ''
    done
    printf y > "$TMP/partial-input"
    assert_fail ui_read_yes_no ANSWER 'Test: ' y < "$TMP/partial-input"
    assert_eq "$ANSWER" ''
}
run_test 'EOF and an incomplete line never use the default or loop forever' t_eof

t_previews() {
    menu_div() { :; }
    assert_ok confirm_change_preview test change <<< $'yy\ny'
    assert_fail confirm_change_preview test change <<< $'nn\nn'
    printf 'old\n' > "$TMP/old"
    printf 'new\n' > "$TMP/new"
    assert_ok confirm_file_diff "$TMP/old" "$TMP/new" test <<< $'invalid\nYES'
    assert_fail confirm_file_diff "$TMP/old" "$TMP/new" test < /dev/null
}
run_test 'Change previews and file diffs retry before accepting or cancelling' t_previews

t_onboarding() {
    local CALLED=0
    step() { CALLED=$((CALLED + 1)); }
    assert_ok first_run_offer_step test n step <<< $'yy\ny'
    assert_eq "$CALLED" 1
    assert_ok first_run_offer_step test y step <<< $'invalid\nn'
    assert_eq "$CALLED" 1
    assert_ok first_run_offer_step test y step <<< ''
    assert_eq "$CALLED" 2
    assert_fail first_run_offer_step test y step < /dev/null
    assert_eq "$CALLED" 2
}
run_test 'Onboarding does not skip a step after a typo or run it after EOF' t_onboarding

t_measure() {
    assert_ok bbr_measure_yes 'Test (Y/n):' y <<< $'yy\nYES'
    assert_fail bbr_measure_yes 'Test (Y/n):' y <<< $'nn\nno'
    assert_ok bbr_measure_yes 'Test (Y/n):' y <<< ''
    assert_fail bbr_measure_yes 'Test (Y/n):' y < /dev/null
}
run_test 'Measured tuning uses the same retry and EOF rules' t_measure

safety_fixture() {
    SAFETY_SCRIPT="$TMP/rollback-$RANDOM.sh"
    : > "$SAFETY_SCRIPT"
    CANCELLED=0
    audit_action() { :; }
    safety_arm() { fail 'Retry must not restart or extend the timer'; }
    cancel_safety_timer() { CANCELLED=$((CANCELLED + 1)); return 0; }
}

t_safety_retry() {
    safety_fixture
    assert_ok safety_confirm <<< $'yy\n?\ny'
    assert_eq "$CANCELLED" 1
    assert_ok safety_confirm <<< $'yy\nn'
    assert_eq "$CANCELLED" 1
    assert_ok test -f "$SAFETY_SCRIPT"
}
run_test 'Connection confirmation retries typos without changing the rollback deadline' t_safety_retry

t_safety_eof() {
    safety_fixture
    assert_fail safety_confirm <<< yy
    assert_eq "$CANCELLED" 0
    assert_ok test -f "$SAFETY_SCRIPT"
}
run_test 'EOF during connection confirmation leaves rollback protection intact' t_safety_eof

t_safety_expired() {
    safety_fixture
    local READ_COUNT=0 OUTPUT RC=0
    # 倒计时在纠正输入期间结束，最后收到 y 也不能声称保留了新配置。
    read() {
        builtin read -r "$@" || return 1
        READ_COUNT=$((READ_COUNT + 1))
        [ "$READ_COUNT" -ne 2 ] || rm -f "$SAFETY_SCRIPT"
    }
    cancel_safety_timer() {
        [ -f "$SAFETY_SCRIPT" ] || return 2
        fail 'Expected the rollback to have completed while re-prompting'
    }
    OUTPUT=$(safety_confirm <<< $'yy\ny' 2>&1) || RC=$?
    assert_ne "$RC" 0
    assert_contains "$OUTPUT" '自动回滚已在等待确认期间执行'
    assert_fail grep -q '已取消自动回滚' <<< "$OUTPUT"
}
run_test 'A rollback that expires while correcting input is still reported as expired' t_safety_expired

t_inventory() {
    # 防止新增提示绕过统一校验；强确认口令不属于 y/n。
    local MISSED
    MISSED=$(grep -nEi '(^|[;[:space:]])read[[:space:]].*[yY]/[nN]' "$ROOT"/src/lib/*.sh "$ROOT"/src/modules/*.sh || true)
    assert_eq "$MISSED" ''
    assert_file_contains "$ROOT/src/modules/toolbox.sh" '输入 RESTORE 确认恢复'
    assert_file_contains "$ROOT/src/modules/system-updates.sh" '输入 UPGRADE 12 TO 13 确认开始'
}
run_test 'All literal y/n prompts use the shared reader; typed safety tokens remain unchanged' t_inventory

test_summary 'Confirmation input'
