#!/bin/bash
# Uninstaller for quicktab-iterm2.
# Idempotent — safe to re-run.
set -euo pipefail

BIN_DIR="$HOME/.local/bin"
AUTOLAUNCH_DIR="$HOME/Library/Application Support/iTerm2/Scripts/AutoLaunch"
CACHE_DIR="$HOME/.cache/quicktab-iterm2"

echo "Uninstalling quicktab-iterm2…"

# Stop the autolaunch script.
if pgrep -f "AutoLaunch/quicktab-iterm2.py" >/dev/null 2>&1; then
  pkill -f "AutoLaunch/quicktab-iterm2.py" 2>/dev/null || true
  echo "  ✓ stopped autolaunch script"
fi

# Stop any running picker.
if pgrep -f "/quicktab-iterm2/picker$" >/dev/null 2>&1; then
  pkill -9 -f "/quicktab-iterm2/picker$" 2>/dev/null || true
  echo "  ✓ stopped picker"
fi

# Remove binaries / shims / sources from ~/.local/bin.
removed=0
for f in \
  "$BIN_DIR/quicktab-picker" \
  "$BIN_DIR/quicktab-picker.swift" \
  "$BIN_DIR/quicktab-trigger" \
  "$BIN_DIR/quicktab-trigger.py"
do
  if [[ -e "$f" ]]; then
    rm -f "$f"
    removed=$((removed + 1))
  fi
done
[[ $removed -gt 0 ]] && echo "  ✓ removed $removed file(s) from $BIN_DIR"

# Remove autolaunch script.
if [[ -e "$AUTOLAUNCH_DIR/quicktab-iterm2.py" ]]; then
  rm -f "$AUTOLAUNCH_DIR/quicktab-iterm2.py"
  echo "  ✓ removed $AUTOLAUNCH_DIR/quicktab-iterm2.py"
fi

# Remove cache (compiled binary + state).
if [[ -d "$CACHE_DIR" ]]; then
  rm -rf "$CACHE_DIR"
  echo "  ✓ removed $CACHE_DIR"
fi

# Remove pidfile and debug logs.
rm -f /tmp/quicktab-picker.pid /tmp/quicktab-debug.log /tmp/quicktab-debug-swift.log
echo "  ✓ removed temp files"

cat <<'EOF'

╭─────────────────────────────────────────────────────────────────────────╮
│  quicktab-iterm2 uninstalled.                                           │
╰─────────────────────────────────────────────────────────────────────────╯

One manual step left — remove the iTerm2 hotkey binding:

  iTerm2 → Settings → Keys → Key Bindings
  Find the entry whose Parameters = "quicktab_show()" and delete it.

EOF
