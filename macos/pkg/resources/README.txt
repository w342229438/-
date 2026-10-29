Codex Pet Usage Overlay

This unsigned installer copies the current Hammerspoon overlay script into your
Hammerspoon configuration and appends a marked loading block to init.lua.

Version 2.0 is rebuilt for Codex 26.x inside ChatGPT.app. It tracks only the
active pet, handles Retina/multi-display coordinates, and removes the legacy
Swift renderer during upgrades to prevent duplicate rings.

It includes official Hammerspoon 1.1.1. If Hammerspoon is not already installed,
the installer verifies its code signature and installs it to /Applications.
Existing Hammerspoon installations are left unchanged.

Requirements
- macOS 13 or later is required by bundled Hammerspoon 1.1.1.
- Hammerspoon needs the macOS permissions it normally requests.

After installing
1. Open Hammerspoon if it did not open automatically.
2. Open Codex Desktop and its /pet view.
3. Hover over the pet to show the usage ring. Keep hovering for 3 seconds to
   show the detail card.

Uninstall
Open Uninstall.command in this folder. It requests an administrator password,
then removes only this project's script and marked init.lua block.
