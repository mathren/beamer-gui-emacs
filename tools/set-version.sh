#!/usr/bin/env bash
# Copyright (C) 2026 Mathieu Renzo
# SPDX-License-Identifier: GPL-3.0-or-later
# Set the package version everywhere the CURRENT version is written:
#
#   beamer-gui.el   the ";; Version:" header (the site's footer reads it)
#
# A version mentioned as history -- "blocks of version 0.1" -- is
# deliberately not touched: it says when something happened, and stays
# true.
#
#   tools/set-version.sh 0.2.1
set -euo pipefail
cd "$(dirname "$0")/.."

new="${1:-}"
if ! [[ "$new" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 X.Y.Z   (got '${new}')" >&2
  exit 2
fi

old="$(sed -n 's/^;; Version: *//p' beamer-gui.el | head -1)"
if [ "$new" = "$old" ]; then
  echo "set-version: already $old" >&2
  exit 1
fi
# refuse to go backwards: a lower version would sort before tags already out
if [ "$(printf '%s\n%s\n' "$old" "$new" | sort -V | tail -1)" != "$new" ]; then
  echo "set-version: $new is lower than the current $old" >&2
  exit 1
fi

sed -i "s/^;; Version: .*/;; Version: $new/" beamer-gui.el

# every place must now say NEW; say which one did not, if any
fail=0
check() { grep -q "$2" "$1" || { echo "set-version: $1 does not show $new" >&2; fail=1; }; }
check beamer-gui.el "^;; Version: $new\$"
[ "$fail" = 0 ] || exit 1
echo "set-version: $old -> $new"
