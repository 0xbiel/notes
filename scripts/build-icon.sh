#!/bin/zsh
set -eu
branding_root="${0:A:h:h}/Resources/Branding"
icon_stage="$(mktemp -d -t palladium-icon)"
trap 'rm -rf "$icon_stage"' EXIT
iconset="$icon_stage/Palladium.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$branding_root/PalladiumAppIcon.png" --out "$iconset/icon_${size}x${size}.png" > /dev/null
  retina_size=$((size * 2))
  sips -z "$retina_size" "$retina_size" "$branding_root/PalladiumAppIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil --convert icns "$iconset" --output "$branding_root/Palladium.icns"
print "$branding_root/Palladium.icns"
