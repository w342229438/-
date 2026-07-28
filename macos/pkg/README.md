# macOS unsigned installer

This directory builds an unsigned `.pkg` for the Hammerspoon implementation.
The package installs the overlay script without replacing the user's existing
`~/.hammerspoon/init.lua`; it only appends a marked `require` block.

## Build

```zsh
cd macos/pkg
chmod +x build-unsigned-pkg.sh scripts/postinstall resources/Uninstall.command
./build-unsigned-pkg.sh 1.1.6
```

The output is placed in `macos/pkg/dist/`.

The package is intentionally unsigned. On another Mac, macOS may require the
user to Control-click the package and select **Open** before installation.

## Bundled Hammerspoon

The build script downloads the official Hammerspoon `1.1.1` ZIP from its GitHub
release and verifies the included app signature before producing the package.
The resulting installer includes it. On the target Mac, Hammerspoon is installed
to `/Applications/Hammerspoon.app` only when it is not already present; an
existing installation is never replaced. Hammerspoon `1.1.1` requires macOS 13
or later.

## Uninstall

After installation, run:

```text
/Applications/Codex Pet Usage Overlay/Uninstall.command
```

It removes the installed script, this package's marked block in `init.lua`, and
the package support files. It does not remove Hammerspoon or any unrelated
Hammerspoon configuration.
