#!/bin/sh
# Render the asset-catalog PNGs from the vector sources.
# Requires librsvg: brew install librsvg
set -e
cd "$(dirname "$0")/.."

rsvg-convert -w 1024 -h 1024 icon/icon.svg \
    -o PiControl/Assets.xcassets/AppIcon.appiconset/AppIcon.png
rsvg-convert -w 300 -h 300 icon/launch.svg \
    -o PiControl/Assets.xcassets/LaunchLogo.imageset/LaunchLogo@1x.png
rsvg-convert -w 600 -h 600 icon/launch.svg \
    -o PiControl/Assets.xcassets/LaunchLogo.imageset/LaunchLogo@2x.png
rsvg-convert -w 900 -h 900 icon/launch.svg \
    -o PiControl/Assets.xcassets/LaunchLogo.imageset/LaunchLogo@3x.png

echo "Rendered app icon and launch logo."
