#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ICONSET=".build/AppIcon.iconset"
mkdir -p "$ICONSET"
SOURCE_SIZE=$(sips -g pixelWidth -g pixelHeight Assets/AppIcon.png | awk '/pixelWidth|pixelHeight/ {if ($2 > max) max=$2} END {print max}')
# Keep the complete supplied artwork, centered on a square without stretching or cropping.
sips --padToHeightWidth "$SOURCE_SIZE" "$SOURCE_SIZE" --padColor FFFFFF Assets/AppIcon.png --out .build/AppIcon-square.png >/dev/null
for SIZE in 16 32 128 256 512; do
    DOUBLE=$((SIZE * 2))
    sips -z "$SIZE" "$SIZE" .build/AppIcon-square.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    sips -z "$DOUBLE" "$DOUBLE" .build/AppIcon-square.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o .build/AppIcon.icns
