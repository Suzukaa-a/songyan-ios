#!/usr/bin/env bash
# Prints one section of CHANGELOG.md: the release notes of a version, or of the unreleased changes.
#
# Usage: Tools/CI/scripts/changelog-section.sh <X.Y.Z | 未发布> [CHANGELOG.md]
#
# A section starts at "## <name>" (anything after a space, such as a date, is ignored) and ends at the
# next "## " heading. Leading and trailing blank lines are dropped. Exits 1 when the section is missing
# or empty, so a release without notes fails.
set -euo pipefail
name=${1:?usage: Tools/CI/scripts/changelog-section.sh <X.Y.Z | 未发布> [CHANGELOG.md]}
file=${2:-$(dirname "$0")/../../../CHANGELOG.md}
body=$(awk -v name="${name}" '
  /^## / { if (on) exit; head = substr($0, 4); on = (head == name || index(head, name " ") == 1); next }
  on { print }
' "${file}" | sed -e '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')
if [[ -z "${body//[[:space:]]/}" ]]; then
  echo "no notes under \"## ${name}\" in ${file}" >&2
  exit 1
fi
printf '%s\n' "${body}"
