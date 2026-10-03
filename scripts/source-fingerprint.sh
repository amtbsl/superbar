#!/bin/zsh
set -euo pipefail

# Content identity of every compilation/resource input. This works both in the
# checkout and in an extracted git source archive, without Git or user settings.
source_root="${1:-${0:A:h:h}}"
cd "$source_root"
{
  find Sources Resources -type f
  print -l LICENSE scripts/build.sh scripts/make-icon.swift scripts/source-fingerprint.sh scripts/verify-app.sh
} | LC_ALL=C sort | while IFS= read -r source_file; do
  [[ -f "$source_file" ]] || { print -u2 "Missing build input: $source_file"; exit 1; }
  shasum -a 256 "$source_file"
done | shasum -a 256 | awk '{print $1}'
