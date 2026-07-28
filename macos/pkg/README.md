# macOS unsigned installer

This directory builds an unsigned `.pkg` for the Hammerspoon implementation.
The package installs the overlay script without replacing the user's existing
`~/.hammerspoon/init.lua`; it only appends a marked `require` block.

## Build

```zsh
cd macos/pkg
chmod +x build-unsigned-pkg.sh scripts/postinstall resources/Uninstall.command
./build-unsigned-pkg.sh 1.0.0
```

The output is placed in `macos/pkg/dist/`.

The package is intentionally unsigned. On another Mac, macOS may require the
user to Control-click the package and select **Open** before installation.

## Requirements

The target Mac needs Hammerspoon in `/Applications/Hammerspoon.app`. The
installer copies the script for the active macOS user, starts Hammerspoon when
available, and leaves its standard permissions unchanged.

## Uninstall

After installation, run:

```text
/Applications/Codex Pet Usage Overlay/Uninstall.command
```

It removes the installed script, this package's marked block in `init.lua`, and
the package support files. It does not remove Hammerspoon or any unrelated
Hammerspoon configuration.
