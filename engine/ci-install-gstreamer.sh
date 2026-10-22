#!/usr/bin/env bash
# CI only: the official GStreamer framework (runtime + devel) that engine 2.x's winegstreamer is built against.
# Users who want game videos install the runtime themselves; the engine never ships GStreamer.
# Pins: the .sha256sum files published next to the packages on gstreamer.freedesktop.org.
set -euo pipefail
GST_VERSION=1.28.8
BASE="https://gstreamer.freedesktop.org/data/pkg/osx/$GST_VERSION"
DL="${RUNNER_TEMP:-/tmp}/gstreamer"; mkdir -p "$DL"
while read -r sha pkg; do
  curl -fL --retry 3 -sS -o "$DL/$pkg" "$BASE/$pkg"
  [ "$(shasum -a 256 "$DL/$pkg" | cut -d' ' -f1)" = "$sha" ] || { echo "checksum mismatch: $pkg" >&2; exit 1; }
  sudo installer -pkg "$DL/$pkg" -target /
done <<PINS
d371ab04a7632713626836c2fc234e863cc98484c74c473eba99b0fbd9b3a3fe gstreamer-1.0-$GST_VERSION-universal.pkg
e6d380bc17be7eccf13e0154567d4718fc9321da822408c7ca0cd808b3d4a3f7 gstreamer-1.0-devel-$GST_VERSION-universal.pkg
PINS
ls /Library/Frameworks/GStreamer.framework/Versions
