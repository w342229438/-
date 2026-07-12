#!/bin/zsh
set -euo pipefail

DIR="${0:A:h}"
BIN="$("$DIR/Build.command")"
"$BIN" run "$@"
