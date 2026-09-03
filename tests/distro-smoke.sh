#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bash -n "$ROOT/vps-quench.sh"
"$ROOT/tests/smoke.sh"

case "${EXPECTED_PM:-}" in
    apt) command -v apt-get >/dev/null ;;
    apk) command -v apk >/dev/null ;;
    dnf) command -v dnf >/dev/null ;;
    *) echo "Unknown EXPECTED_PM=${EXPECTED_PM:-}" >&2; exit 1 ;;
esac

echo "Distribution smoke test passed for $EXPECTED_PM."
