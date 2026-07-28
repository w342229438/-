#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h:h}"
VERSION="${1:-1.0.0}"
PACKAGE_ID="com.w342229438.codex-pet-usage-overlay"
BUILD_DIR="${TMPDIR:-/private/tmp}/codex-pet-usage-pkg-${UID}"
SCRIPTS_DIR="$BUILD_DIR/scripts"
DIST_DIR="$SCRIPT_DIR/dist"
OUTPUT="$DIST_DIR/CodexPetUsageOverlay-${VERSION}-unsigned.pkg"

if ! command -v pkgbuild >/dev/null; then
  print -u2 "pkgbuild is unavailable. Install Xcode Command Line Tools first: xcode-select --install"
  exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$SCRIPTS_DIR"
mkdir -p "$DIST_DIR"

/bin/cp -X "$SCRIPT_DIR/scripts/postinstall" "$SCRIPTS_DIR/postinstall"
chmod 755 "$SCRIPTS_DIR/postinstall"

append_payload() {
  local name="$1"
  local source="$2"
  print "__CODEX_PET_USAGE_${name}_START__" >> "$SCRIPTS_DIR/postinstall"
  /usr/bin/base64 < "$source" >> "$SCRIPTS_DIR/postinstall"
  print "__CODEX_PET_USAGE_${name}_END__" >> "$SCRIPTS_DIR/postinstall"
}

append_payload "OVERLAY" "$REPO_ROOT/hammerspoon/codex-pet-usage-overlay.lua"
append_payload "UNINSTALL" "$SCRIPT_DIR/resources/Uninstall.command"
append_payload "README" "$SCRIPT_DIR/resources/README.txt"

pkgbuild \
  --nopayload \
  --scripts "$SCRIPTS_DIR" \
  --identifier "$PACKAGE_ID" \
  --version "$VERSION" \
  "$OUTPUT"

pkgutil --check-signature "$OUTPUT" || true
print "Signature: none (intentionally unsigned)"
print "Created unsigned installer: $OUTPUT"
