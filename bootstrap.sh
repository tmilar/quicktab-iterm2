#!/bin/bash
# Bootstrap installer for quicktab-iterm2.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/tmilar/quicktab-iterm2/main/bootstrap.sh | bash
#
# Downloads the latest main-branch tarball to a temp directory and runs
# install.sh from it. No git clone, no permanent source checkout.
# Re-run any time to update.
set -euo pipefail

REPO="tmilar/quicktab-iterm2"
TARBALL_URL="https://github.com/${REPO}/archive/refs/heads/main.tar.gz"

TMPDIR=$(mktemp -d -t quicktab-bootstrap.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading quicktab-iterm2…"
curl -fsSL "$TARBALL_URL" | tar -xz -C "$TMPDIR"

# The tarball extracts as quicktab-iterm2-main/
SRC_DIR=$(find "$TMPDIR" -maxdepth 1 -type d -name 'quicktab-iterm2-*' | head -1)
if [[ -z "$SRC_DIR" || ! -x "$SRC_DIR/install.sh" ]]; then
  echo "Could not locate install.sh in the downloaded tarball." >&2
  exit 1
fi

exec "$SRC_DIR/install.sh"
