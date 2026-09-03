#!/usr/bin/env bash
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
SOURCE_SCRIPT="${SOURCE_SCRIPT:-$ROOT/vps-quench.sh}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

file_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    else
        return 1
    fi
}

usage() {
    cat <<'EOF'
Usage: ./build-offline-package.sh [--output DIR] [--source FILE]

Builds a self-contained archive for a VPS without Internet access. The archive
contains the full script, its SHA256 file, and an installer that creates
/usr/local/bin/vps-quench plus non-conflicting v/V shortcuts.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --output)
            [ "$#" -ge 2 ] || fail "--output needs a directory"
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --source)
            [ "$#" -ge 2 ] || fail "--source needs a script path"
            SOURCE_SCRIPT="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
done

[ -f "$SOURCE_SCRIPT" ] || fail "script not found: $SOURCE_SCRIPT"
command -v tar >/dev/null 2>&1 || fail "tar is required"
bash -n "$SOURCE_SCRIPT" || fail "source script has invalid Bash syntax"
VERSION=$(sed -nE 's/^APP_VERSION="(V[0-9]+\.[0-9]+(\.[0-9]+)?)".*/\1/p' "$SOURCE_SCRIPT" | head -1)
[ -n "$VERSION" ] || fail "cannot determine APP_VERSION"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/quench-offline.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM
PACKAGE_DIR="$TMP_DIR/quench-offline-$VERSION"
mkdir -p "$PACKAGE_DIR" "$OUTPUT_DIR"
cp "$SOURCE_SCRIPT" "$PACKAGE_DIR/vps-quench.sh"
ACTUAL_HASH=$(file_sha256 "$PACKAGE_DIR/vps-quench.sh" || true)
[ -n "$ACTUAL_HASH" ] || fail "no SHA256 utility is available"
printf '%s  %s\n' "$ACTUAL_HASH" "vps-quench.sh" > "$PACKAGE_DIR/vps-quench.sh.sha256"

cat > "$PACKAGE_DIR/install.sh" <<'INSTALLER'
#!/usr/bin/env bash
set -eu

PACKAGE_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
BIN_DIR=/usr/local/bin
CREATE_SHORTCUTS=1

fail() {
    printf 'Installation failed: %s\n' "$1" >&2
    exit 1
}

file_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    else
        return 1
    fi
}

usage() {
    cat <<'EOF'
Usage: bash install.sh [--bin-dir DIR] [--no-shortcuts]
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --bin-dir)
            [ "$#" -ge 2 ] || fail "--bin-dir needs a directory"
            BIN_DIR="$2"
            shift 2
            ;;
        --no-shortcuts)
            CREATE_SHORTCUTS=0
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
done

[ "$BIN_DIR" != /usr/local/bin ] || [ "$(id -u)" -eq 0 ] || fail "run as root or use --bin-dir for a user-writable directory"
SCRIPT="$PACKAGE_DIR/vps-quench.sh"
CHECKSUM="$PACKAGE_DIR/vps-quench.sh.sha256"
[ -f "$SCRIPT" ] && [ -f "$CHECKSUM" ] || fail "package files are missing"
EXPECTED=$(awk 'NR == 1 { print $1 }' "$CHECKSUM")
ACTUAL=$(file_sha256 "$SCRIPT" || true)
[ -n "$ACTUAL" ] && [ "$ACTUAL" = "$EXPECTED" ] || fail "SHA256 verification failed"
bash -n "$SCRIPT" || fail "script syntax verification failed"
grep -qE '^APP_VERSION="V[0-9]+\.[0-9]+(\.[0-9]+)?"' "$SCRIPT" || fail "script version marker is missing"

TARGET="$BIN_DIR/vps-quench"
mkdir -p "$BIN_DIR" || fail "cannot create $BIN_DIR"
TEMP=$(mktemp "$BIN_DIR/.vps-quench.install.XXXXXX") || fail "cannot create installation staging file"
trap 'rm -f "$TEMP"' EXIT HUP INT TERM
cp "$SCRIPT" "$TEMP" || fail "cannot write $TEMP"
chmod 755 "$TEMP"
mv "$TEMP" "$TARGET" || fail "cannot install $TARGET"
trap - EXIT HUP INT TERM

install_shortcut() {
    local NAME="$1" LINK="$BIN_DIR/$1" CURRENT
    if [ -L "$LINK" ]; then
        CURRENT=$(readlink "$LINK" 2>/dev/null || true)
        [ "$CURRENT" = "$TARGET" ] && return 0
        printf 'Skipped shortcut %s: already owned by %s\n' "$NAME" "${CURRENT:-another target}" >&2
        return 0
    elif [ -e "$LINK" ]; then
        printf 'Skipped shortcut %s: %s already exists\n' "$NAME" "$LINK" >&2
        return 0
    fi
    ln -s "$TARGET" "$LINK" || printf 'Skipped shortcut %s: cannot create %s\n' "$NAME" "$LINK" >&2
}

if [ "$CREATE_SHORTCUTS" -eq 1 ]; then
    install_shortcut v
    install_shortcut V
fi

printf 'Installed Quench to %s\n' "$TARGET"
printf 'SHA256 verified: %.16s...\n' "$ACTUAL"
INSTALLER
chmod 755 "$PACKAGE_DIR/install.sh"

cat > "$PACKAGE_DIR/README.txt" <<EOF
Quench offline package ($VERSION)

This package does not download anything during installation.

1. Transfer this archive and its .sha256 file to the VPS, for example with scp.
2. Verify the archive: sha256sum -c $(basename "quench-offline-$VERSION.tar.gz.sha256")
3. Extract it: tar -xzf quench-offline-$VERSION.tar.gz
4. Install it: cd quench-offline-$VERSION && sudo bash install.sh

The installer verifies the bundled script before placing it in /usr/local/bin/vps-quench.
Existing v or V commands owned by another program are never overwritten.

The installed script is self-contained. Features that install third-party software,
download updates, or contact DNS/CDN providers will still require network access.
EOF

ARCHIVE="$OUTPUT_DIR/quench-offline-$VERSION.tar.gz"
tar -czf "$ARCHIVE" -C "$TMP_DIR" "quench-offline-$VERSION"
ARCHIVE_HASH=$(file_sha256 "$ARCHIVE" || true)
[ -n "$ARCHIVE_HASH" ] || fail "cannot calculate archive SHA256"
printf '%s  %s\n' "$ARCHIVE_HASH" "$(basename "$ARCHIVE")" > "$ARCHIVE.sha256"

printf 'Created: %s\n' "$ARCHIVE"
printf 'Checksum: %s\n' "$ARCHIVE.sha256"
