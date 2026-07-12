#!/bin/zsh
set -euo pipefail

DIR="${0:A:h}"
SRC="$DIR/CodexPetUsageOverlayMac.swift"
OUT_DIR="$DIR/.build"
OUT="$OUT_DIR/codex-pet-usage-overlay-mac"

mkdir -p "$OUT_DIR"

if [[ ! -x "$OUT" || "$SRC" -nt "$OUT" ]]; then
  mkdir -p "$OUT_DIR/module-cache"
  swiftc -swift-version 5 -parse-as-library -O -module-cache-path "$OUT_DIR/module-cache" -framework AppKit "$SRC" -o "$OUT"
fi

echo "$OUT"
