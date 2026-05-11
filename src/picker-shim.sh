#!/bin/bash
# Picker shim — compiles picker.swift on demand (cached), then exec's the binary.
# Installed as ~/.local/bin/quicktab-picker by install.sh.
#
# Source layout (after install):
#   ~/.local/bin/quicktab-picker        ← this file
#   ~/.local/bin/quicktab-picker.swift  ← Swift source
#   ~/.cache/quicktab-iterm2/picker            ← compiled binary (built on first run)
set -e

SRC="$HOME/.local/bin/quicktab-picker.swift"
BIN="$HOME/.cache/quicktab-iterm2/picker"

mkdir -p "$(dirname "$BIN")"

# Rebuild if source is newer than binary (or binary missing).
if [[ ! -x "$BIN" || "$SRC" -nt "$BIN" ]]; then
  swiftc -O -o "$BIN" "$SRC" 2>&1 | sed 's/^/[quicktab-build] /' >&2
fi

exec "$BIN" "$@"
