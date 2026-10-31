#!/bin/zsh
# Arma Recursos/AppIcon.icns a partir de Recursos/AppIcon.png (1024x1024, fondo transparente).
# Uso: ./Recursos/hacer-icono.sh
set -euo pipefail
cd "$(dirname "$0")"
rm -rf AppIcon.iconset && mkdir AppIcon.iconset
for t in 16 32 128 256 512; do
  sips -z $t $t AppIcon.png --out AppIcon.iconset/icon_${t}x${t}.png >/dev/null
  sips -z $((t * 2)) $((t * 2)) AppIcon.png --out AppIcon.iconset/icon_${t}x${t}@2x.png >/dev/null
done
iconutil -c icns AppIcon.iconset -o AppIcon.icns
rm -rf AppIcon.iconset
echo "Listo: Recursos/AppIcon.icns"
