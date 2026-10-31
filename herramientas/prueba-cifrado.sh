#!/bin/zsh
# Prueba del cifrado opcional del portátil, SOLO con una imagen de disco de ensayo (nunca con discos reales):
# clave nueva → llavero → cifrar → desmontar (queda bloqueado) → clave equivocada no abre → abre con el llavero
# → los datos siguen → se borra la clave. Al final desmonta y borra la imagen y la clave, pase lo que pase.
# Uso: herramientas/prueba-cifrado.sh
set -uo pipefail
cd "$(dirname "$0")/.."
source herramientas/imagenes.sh   # soltar_imagenes / revisar_sin_imagenes (limpieza de imágenes de ensayo)
CONSTRUIR=/private/tmp/relevo-build-cifrado   # carpeta de compilación aparte (no choca con otra sesión)

TMP=$(mktemp -d /private/tmp/relevo-cifrado.XXXX)
MONTAJE="$TMP/m"; mkdir -p "$MONTAJE"
limpiar() {
  # Por el archivo de la imagen: una vez cifrada y bloqueada queda adjunta sin montar.
  soltar_imagenes "$TMP/"; revisar_sin_imagenes "$TMP/"
  [ -n "${UUID_ENSAYO:-}" ] && security delete-generic-password -s "Relevo - clave del disco" -a "$UUID_ENSAYO" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap limpiar EXIT

# La prueba corre con la app entera (`Relevo --probar-cifrado`): desde el 25/10/2026 también prueba ocultar el disco
# como en casa (`Discos.remontar`), que necesita el resto de la app. Si no compila, no hay prueba.
if swift build -c release --product Relevo --scratch-path "$CONSTRUIR" > "$TMP/compilar.log" 2>&1; then
  echo "✓ Compila la app"
else
  perl -pe 's/\e\[[0-9;]*m//g' "$TMP/compilar.log" | grep -E "\.swift:[0-9]+:[0-9]+: error" | head -20
  echo "✗ La app no compila (¿otra sesión editando?): sin la app no se puede probar."; exit 1
fi
BIN="$(swift build -c release --product Relevo --scratch-path "$CONSTRUIR" --show-bin-path)/Relevo"

hdiutil create -quiet -size 200m -fs APFS -volname RLCifrado -type SPARSE "$TMP/ensayo" || { echo "✗ no se creó la imagen"; exit 1; }
hdiutil attach -quiet -nobrowse -mountpoint "$MONTAJE" "$TMP/ensayo.sparseimage" 2>/dev/null || { echo "✗ no montó"; exit 1; }
# Freno: que lo montado sea la imagen de ensayo (y no otra cosa) antes de cifrar.
INFO=$(diskutil info -plist "$MONTAJE")
[ "$(plutil -extract VolumeName raw - <<< "$INFO")" = "RLCifrado" ] && [ "$(plutil -extract BusProtocol raw - <<< "$INFO")" = "Disk Image" ] \
  || { echo "✗ lo montado no es la imagen de ensayo"; exit 1; }
UUID_ENSAYO=$(plutil -extract VolumeUUID raw - <<< "$INFO")
head -c 120000000 /dev/urandom > "$MONTAJE/relleno.bin"   # algo de datos, para ver el avance

"$BIN" --probar-cifrado "$MONTAJE"
