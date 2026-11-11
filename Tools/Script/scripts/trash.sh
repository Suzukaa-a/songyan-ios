#!/usr/bin/env bash
# Moves a path to the Trash instead of deleting it permanently, the same way the repository's
# other clean-up steps do. A missing path is not an error.
set -euo pipefail

[[ $# -eq 1 ]] || {
  echo "usage: trash.sh <path>" >&2
  exit 64
}
[[ -e "$1" ]] || exit 0
xcrun swift -e 'import Foundation; try FileManager.default.trashItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), resultingItemURL: nil)' "$1"
