#!/usr/bin/env bash
# File-backed tc fixture: no network or privileged operations.
set -euo pipefail
: "${QUENCH_TEST_TC_ROOT:?}"
case "$1 $2" in
    'qdisc show') cat "$QUENCH_TEST_TC_ROOT/qdisc"; exit ;;
    'class show') cat "$QUENCH_TEST_TC_ROOT/class"; exit ;;
    'filter show') cat "$QUENCH_TEST_TC_ROOT/filter"; exit ;;
esac
printf '%s\n' "$*" >> "$QUENCH_TEST_TC_ROOT/writes"
[ ! -f "$QUENCH_TEST_TC_ROOT/fail" ] || exit 1
[ ! -f "$QUENCH_TEST_TC_ROOT/no-effect" ] || exit 0
case "$1 $2" in
    'qdisc del')
        printf 'qdisc fq_codel 0: root refcnt 2\n' > "$QUENCH_TEST_TC_ROOT/qdisc"
        : > "$QUENCH_TEST_TC_ROOT/class"
        ;;
    'qdisc replace'|'qdisc add')
        case "$*" in
            *'root handle 7ffe: mq')
                printf '%s\n' 'qdisc mq 7ffe: root' 'qdisc fq 0: parent 7ffe:1' 'qdisc fq 0: parent 7ffe:2' > "$QUENCH_TEST_TC_ROOT/qdisc" ;;
            *'root handle 7ffd: fq')
                printf 'qdisc fq 7ffd: root refcnt 2\n' > "$QUENCH_TEST_TC_ROOT/qdisc" ;;
            *'root handle 1: htb default 10')
                printf 'qdisc htb 1: root default 0x10\n' > "$QUENCH_TEST_TC_ROOT/qdisc" ;;
            *'parent 1:10 handle 100: fq maxrate '*)
                printf 'qdisc fq 100: parent 1:10 maxrate %s\n' "${!#}" >> "$QUENCH_TEST_TC_ROOT/qdisc" ;;
            *) exit 1 ;;
        esac
        ;;
    'class add')
        RATE=''
        while [ "$#" -gt 0 ]; do
            if [ "$1" = rate ]; then RATE="$2"; break; fi
            shift
        done
        printf 'class htb 1:10 root rate %s ceil %s\n' "$RATE" "$RATE" > "$QUENCH_TEST_TC_ROOT/class"
        ;;
    *) exit 1 ;;
esac
