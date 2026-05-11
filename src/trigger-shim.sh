#!/bin/bash
# Trigger shim — invokes the quicktab_show RPC from outside iTerm2.
# Useful for development / scripting (e.g. dock-icon trigger, voice control).
#
# Dynamically picks the highest installed iTerm2 bundled python so this
# survives iTerm2 upgrades that bump the bundled version.
set -e

# shellcheck disable=SC2012  # `find ... -print | sort | tail` would be more verbose for the same outcome
ITERM_PY=$(ls -1 "$HOME/.config/iterm2/AppSupport/iterm2env/versions/"*/bin/python3 2>/dev/null | sort -V | tail -1)

if [[ -z "$ITERM_PY" || ! -x "$ITERM_PY" ]]; then
  echo "iTerm2 bundled python not found. Enable the iTerm2 Python API:" >&2
  echo "  iTerm2 → Settings → General → Magic → 'Enable Python API'" >&2
  exit 1
fi

exec /Applications/iTerm.app/Contents/Resources/it2_api_wrapper.sh \
  "$ITERM_PY" \
  "$HOME/.local/bin/quicktab-trigger.py" "$@"
