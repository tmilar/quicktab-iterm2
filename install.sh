#!/bin/bash
# Installer for quicktab-iterm2.
# Idempotent: re-run to update.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$PROJECT_DIR/src"

BIN_DIR="$HOME/.local/bin"
AUTOLAUNCH_DIR="$HOME/Library/Application Support/iTerm2/Scripts/AutoLaunch"
CACHE_DIR="$HOME/.cache/quicktab"

# ─── prereqs ─────────────────────────────────────────────────────────────────

echo "Checking prerequisites…"

if [[ ! -d "/Applications/iTerm.app" ]]; then
  echo "  ✗ iTerm2 not found at /Applications/iTerm.app"
  echo "    Install from https://iterm2.com/ first."
  exit 1
fi
echo "  ✓ iTerm2"

if ! command -v swift >/dev/null 2>&1; then
  echo "  ✗ Swift toolchain not found"
  echo "    Install Xcode Command Line Tools: xcode-select --install"
  exit 1
fi
SWIFT_VER=$(swift --version 2>&1 | head -1 | sed -E 's/.*Swift version ([0-9.]+).*/\1/')
echo "  ✓ swift $SWIFT_VER"

# Pick the highest version under iterm2env (latest is sorted last).
# shellcheck disable=SC2012  # `find ... -print | sort | tail` would be more verbose for the same outcome
ITERM_PY=$(ls -1 "$HOME/.config/iterm2/AppSupport/iterm2env/versions/"*/bin/python3 2>/dev/null | sort -V | tail -1)
if [[ ! -x "$ITERM_PY" ]]; then
  echo "  ✗ iTerm2 bundled python not found at $ITERM_PY"
  echo "    Enable the iTerm2 Python API: iTerm2 → Settings → General → Magic →"
  echo "    check 'Enable Python API', then restart iTerm2 and re-run this installer."
  exit 1
fi
echo "  ✓ iTerm2 python ($ITERM_PY)"

# ─── install ─────────────────────────────────────────────────────────────────

echo
echo "Installing files…"
mkdir -p "$BIN_DIR" "$AUTOLAUNCH_DIR" "$CACHE_DIR"

# Picker source + shim
install -m 644 "$SRC/picker.swift" "$BIN_DIR/quicktab-picker.swift"
install -m 755 "$SRC/picker-shim.sh" "$BIN_DIR/quicktab-picker"
echo "  ✓ $BIN_DIR/quicktab-picker (shim + source)"

# Trigger source + shim (optional dev/scripting use)
install -m 755 "$SRC/trigger.py" "$BIN_DIR/quicktab-trigger.py"
install -m 755 "$SRC/trigger-shim.sh" "$BIN_DIR/quicktab-trigger"
echo "  ✓ $BIN_DIR/quicktab-trigger (shim + script)"

# Autolaunch RPC script (iTerm2 finds this automatically on launch)
install -m 644 "$SRC/autolaunch.py" "$AUTOLAUNCH_DIR/quicktab.py"
echo "  ✓ $AUTOLAUNCH_DIR/quicktab.py"

# Build the picker binary (so first hotkey press is instant)
echo
echo "Building picker binary…"
swiftc -O -o "$CACHE_DIR/picker" "$BIN_DIR/quicktab-picker.swift" 2>&1 | sed 's/^/  /' || {
  echo "  ✗ swiftc build failed"
  exit 1
}
echo "  ✓ $CACHE_DIR/picker"

# ─── start the autolaunch script (without requiring iTerm2 restart) ──────────

echo
echo "Starting autolaunch script…"
pkill -f "AutoLaunch/quicktab.py" >/dev/null 2>&1 || true
sleep 0.3
nohup /bin/zsh -c "/Applications/iTerm.app/Contents/Resources/it2_api_wrapper.sh '$ITERM_PY' '$AUTOLAUNCH_DIR/quicktab.py'" \
  >/tmp/quicktab-launch.log 2>&1 &
disown
# Wait up to 5s for registration message (autolaunch import can be slow first time)
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if grep -q "registered quicktab_show" /tmp/quicktab-launch.log 2>/dev/null; then
    echo "  ✓ registered quicktab_show"
    break
  fi
  sleep 0.5
done
if ! grep -q "registered quicktab_show" /tmp/quicktab-launch.log 2>/dev/null; then
  echo "  ⚠ couldn't confirm registration after 5s. Check /tmp/quicktab-launch.log"
fi

# ─── next steps ──────────────────────────────────────────────────────────────

cat <<EOF

╭─────────────────────────────────────────────────────────────────────────╮
│  quicktab-iterm2 installed.                                             │
╰─────────────────────────────────────────────────────────────────────────╯

Final step — set up the hotkey binding in iTerm2:

  1. iTerm2 → Settings → Keys → Key Bindings → "+"
  2. Keyboard Shortcut:  press your chord (e.g. ⌘E or ⌘⌥Space)
  3. Action:             Invoke Script Function
  4. Parameters:         quicktab_show()
  5. Scope:              For all sessions
  6. Save.

Then press your chord in any iTerm2 window — the picker appears.

Inside the picker:
  ↑ ↓           navigate tabs
  type          fuzzy-search by title
  ⏎  / click    open selected tab
  ⌘⌫  / hover X close highlighted tab
  esc           cancel

Permissions you'll be prompted for (grant once each):
  • iTerm2 Python API (Settings → General → Magic)
  • Automation → System Events (for activation)
  • Screen Recording (only if you want to use screencapture for debugging)

Logging:
  • Silent by default.
  • For verbose logs while debugging:  export QUICKTAB_DEBUG=1
    Logs go to /tmp/quicktab-debug.log + /tmp/quicktab-debug-swift.log

EOF
