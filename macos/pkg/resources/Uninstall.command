#!/bin/zsh
set -euo pipefail

SYSTEM_DIR="/Library/Application Support/CodexPetUsageOverlay"
APP_DIR="/Applications/Codex Pet Usage Overlay"
MARKER_BEGIN="-- BEGIN CODEX PET USAGE OVERLAY"
MARKER_END="-- END CODEX PET USAGE OVERLAY"

if [[ $EUID -ne 0 ]]; then
  exec sudo "$0"
fi

console_user="$(stat -f '%Su' /dev/console)"
if [[ -n "$console_user" && "$console_user" != "root" && "$console_user" != "loginwindow" ]]; then
  user_home="$(dscl . -read "/Users/$console_user" NFSHomeDirectory | awk '{print $2}')"
  config_dir="$user_home/.hammerspoon"
  init_file="$config_dir/init.lua"

  rm -f "$config_dir/codex-pet-usage-overlay.lua"
  if [[ -f "$init_file" ]] && grep -Fq -- "$MARKER_BEGIN" "$init_file"; then
    temporary_file="$(mktemp "$config_dir/init.lua.XXXXXX")"
    awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" '
      $0 == begin { skipping = 1; next }
      $0 == end { skipping = 0; next }
      !skipping { print }
    ' "$init_file" > "$temporary_file"
    mv "$temporary_file" "$init_file"
    chown "$console_user:$(id -gn "$console_user")" "$init_file"
  fi
fi

rm -rf "$SYSTEM_DIR"
rm -rf "$APP_DIR"
print "Codex Pet Usage Overlay has been removed. Reload Hammerspoon to apply the change."
