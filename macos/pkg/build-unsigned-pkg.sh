#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h:h}"
VERSION="${1:-1.1.7}"
PACKAGE_ID="com.w342229438.codex-pet-usage-overlay"
HAMMERSPOON_VERSION="1.1.1"
HAMMERSPOON_ARCHIVE="Hammerspoon-${HAMMERSPOON_VERSION}.zip"
HAMMERSPOON_URL="https://github.com/Hammerspoon/hammerspoon/releases/download/${HAMMERSPOON_VERSION}/${HAMMERSPOON_ARCHIVE}"
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

print "Downloading official Hammerspoon ${HAMMERSPOON_VERSION}..."
/usr/bin/curl -fL --retry 2 "$HAMMERSPOON_URL" -o "$BUILD_DIR/$HAMMERSPOON_ARCHIVE"
mkdir -p "$BUILD_DIR/hammerspoon-check"
/usr/bin/unzip -q "$BUILD_DIR/$HAMMERSPOON_ARCHIVE" -d "$BUILD_DIR/hammerspoon-check"
/usr/bin/codesign --verify --deep --strict "$BUILD_DIR/hammerspoon-check/Hammerspoon.app"

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
append_payload "HAMMERSPOON_ZIP" "$BUILD_DIR/$HAMMERSPOON_ARCHIVE"

pkgbuild \
  --nopayload \
  --scripts "$SCRIPTS_DIR" \
  --identifier "$PACKAGE_ID" \
  --version "$VERSION" \
  "$OUTPUT"

pkgutil --check-signature "$OUTPUT" || true
print "Signature: none (intentionally unsigned)"
print "Created unsigned installer: $OUTPUT"
