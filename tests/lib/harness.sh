# shellcheck shell=bash
# ══════════════════════════════════════════════════════════
#  Quench 测试骨架（零依赖，纯 bash）
# ══════════════════════════════════════════════════════════
# 解决原来一长串 `断言 || { echo; exit 1; }` 的三个问题：
#   1. 第一个失败就整体中断，后面的用例根本没跑；
#   2. 没有用例名，失败时只有一句 echo 可查；
#   3. 子 shell 的退出码被 set -e 静默吞掉时，整个套件无声退出、零输出。
# 用例体只能通过 exit / fail 报告失败：最后一条命令的退出码不参与判定，
# 所以生成的用例都以 `:` 结尾。否则 `cmd && { echo; exit 1; }` 这种断言在
# cmd 按预期失败时，会把自己的非零状态当成整个用例失败。
# 用法：
#   t_something() { ...断言...; :; }
#   run_test "人话描述" t_something
#   ...
#   test_summary "Smoke"      # 末尾调用；有失败则返回 1
# 只跑某一条：QUENCH_TEST_FILTER='部分名字' tests/smoke.sh
# 逐条显示通过项：QUENCH_TEST_VERBOSE=1 tests/smoke.sh

QUENCH_TESTS_RUN=0
QUENCH_TESTS_FAILED=0
QUENCH_FAILED_NAMES=""

# run_test NAME COMMAND [ARG...]
# 用例体跑在命令替换的子 shell 里：exit / set -e 只终止该用例，
# 变量与函数改动不会泄漏到后续用例，输出只在失败时打印。
run_test() {
    local NAME="$1"
    shift
    if [ -n "${QUENCH_TEST_FILTER:-}" ]; then
        case "$NAME" in
            *"$QUENCH_TEST_FILTER"*) ;;
            *) return 0 ;;
        esac
    fi
    QUENCH_TESTS_RUN=$((QUENCH_TESTS_RUN + 1))
    local OUT RC=0
    # 子 shell 内必须重新 set：命令替换处在 `|| RC=$?` 这个条件上下文里，
    # bash 会在整棵子树上关掉 -e，用例体中间的失败命令就会被静默跳过，
    # 于是只靠 exit/fail 才算失败，普通命令失败一律算通过。
    OUT=$( set -Eeuo pipefail; "$@" 2>&1 ) || RC=$?
    if [ "$RC" -eq 0 ]; then
        [ -z "${QUENCH_TEST_VERBOSE:-}" ] || printf '  ok    %s\n' "$NAME"
        return 0
    fi
    QUENCH_TESTS_FAILED=$((QUENCH_TESTS_FAILED + 1))
    QUENCH_FAILED_NAMES="${QUENCH_FAILED_NAMES}${NAME} (exit ${RC})"$'\n'
    printf '  FAIL  %s\n' "$NAME" >&2
    [ -z "$OUT" ] || printf '%s\n' "$OUT" | sed 's/^/        /' >&2
    return 0
}

# 用例体内报错并结束该用例。
fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

assert_eq() {
    [ "$1" = "$2" ] || fail "${3:-值不相等}: 期望 [$2]，实际 [$1]"
}

assert_ne() {
    [ "$1" != "$2" ] || fail "${3:-值不应相等}: 两者都是 [$1]"
}

assert_ok() {
    "$@" || fail "命令应当成功但失败了: $*"
}

assert_fail() {
    ! "$@" || fail "命令应当失败但成功了: $*"
}

assert_contains() {
    case "$1" in
        *"$2"*) ;;
        *) fail "${3:-未包含期望内容}: [$1] 不含 [$2]" ;;
    esac
}

assert_file_contains() {
    [ -f "$1" ] || fail "${3:-文件不存在}: $1"
    grep -qF -- "$2" "$1" || fail "${3:-文件内容不符}: $1 不含 [$2]"
}

test_summary() {
    local LABEL="${1:-Tests}"
    if [ "$QUENCH_TESTS_FAILED" -eq 0 ]; then
        printf '%s: %d 个用例全部通过\n' "$LABEL" "$QUENCH_TESTS_RUN"
        return 0
    fi
    printf '%s: %d 通过, %d 失败\n' "$LABEL" \
        "$((QUENCH_TESTS_RUN - QUENCH_TESTS_FAILED))" "$QUENCH_TESTS_FAILED" >&2
    printf '%s' "$QUENCH_FAILED_NAMES" | sed 's/^/  - /' >&2
    return 1
}
