#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUTPUT="$ROOT/vps-quench.sh"
CHECKSUM="$ROOT/vps-quench.sh.sha256"
MANIFEST="$ROOT/vps-quench.manifest.json"
MODE="${1:-build}"

PARTS=(
    src/lib/core.sh
    src/modules/ssh.sh
    src/modules/users.sh
    src/modules/fail2ban.sh
    src/modules/bbr.sh
    src/modules/firewall.sh
    src/modules/user-menu.sh
    src/modules/dns.sh
    src/modules/mirrors.sh
    src/modules/ip.sh
    src/modules/caddy.sh
    src/modules/time.sh
    src/modules/swap.sh
    src/modules/stun.sh
    src/modules/toolbox.sh
    src/modules/onboarding.sh
    src/modules/software.sh
    src/modules/docker.sh
    src/modules/self-update.sh
    src/modules/nft.sh
    src/modules/main.sh
)

TMP=$(mktemp "${TMPDIR:-/tmp}/quench-build.XXXXXX")
trap 'rm -f "$TMP"' EXIT

for part in "${PARTS[@]}"; do
    [ -f "$ROOT/$part" ] || { echo "Missing source part: $part" >&2; exit 1; }
    cat "$ROOT/$part" >> "$TMP"
done

bash -n "$TMP"

if [ "$MODE" = "--check" ]; then
    cmp -s "$TMP" "$OUTPUT" || {
        echo "vps-quench.sh is stale; run ./build.sh" >&2
        exit 1
    }
    echo "Generated script is up to date."
    exit 0
fi

mv "$TMP" "$OUTPUT"
trap - EXIT
chmod 755 "$OUTPUT"

if command -v sha256sum >/dev/null 2>&1; then
    (cd "$ROOT" && sha256sum vps-quench.sh > vps-quench.sh.sha256)
else
    HASH=$(shasum -a 256 "$OUTPUT" | awk '{print $1}')
    printf '%s  vps-quench.sh\n' "$HASH" > "$CHECKSUM"
fi

HASH=$(awk 'NR==1{print $1}' "$CHECKSUM")
VERSION=$(grep -oE 'V[0-9]+\.[0-9]+\.[0-9]+|V[0-9]+\.[0-9]+' "$OUTPUT" | head -1)
cat > "$MANIFEST" <<EOF
{
  "name": "vps-quench",
  "version": "${VERSION:-unknown}",
  "file": "vps-quench.sh",
  "sha256": "$HASH",
  "generated_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "urls": [
    "https://raw.githubusercontent.com/boyang-hu/vps-quench/refs/heads/main/vps-quench.sh",
    "https://github.com/boyang-hu/vps-quench/raw/refs/heads/main/vps-quench.sh",
    "https://cdn.jsdelivr.net/gh/boyang-hu/vps-quench@main/vps-quench.sh"
  ]
}
EOF

echo "Built vps-quench.sh and refreshed SHA256/manifest."
