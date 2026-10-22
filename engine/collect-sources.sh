#!/usr/bin/env bash
# Puts the complete corresponding source of an engine line next to its build, for the GitHub release.
#   engine/collect-sources.sh <1|2> <out dir>
# Each file is pinned in sources-<line>.sha256. They are fetched from the first UniveEngine release of that line,
# which mirrors what the engines were built from (the same files MacadeKit published).
set -euo pipefail
cd "$(dirname "$0")"
LINE="$1"; OUT="$2"; mkdir -p "$OUT"
case "$LINE" in
  1) BASE="${SOURCE_BASE_URL:-https://github.com/MuratDugan/UniveEngine/releases/download/engine-1.0.1}" ;;
  2) BASE="${SOURCE_BASE_URL:-https://github.com/MuratDugan/UniveEngine/releases/download/engine-2.0.2}" ;;
  *) echo "line must be 1 or 2" >&2; exit 1 ;;
esac
while read -r sha name; do
  [ -n "$name" ] || continue
  f="$OUT/$name"
  [ -f "$f" ] || curl -fL --retry 3 -sS -o "$f" "$BASE/$name"
  [ "$(shasum -a 256 "$f" | cut -d' ' -f1)" = "$sha" ] || { echo "checksum mismatch: $name" >&2; exit 1; }
  echo "source: $name"
done < "sources-$LINE.sha256"
