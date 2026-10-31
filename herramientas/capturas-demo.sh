#!/bin/zsh
# Capturas para el README con datos de ejemplo (nunca con los discos o carpetas reales de nadie):
# dos discos de ensayo "Studio" (hub y portátil), proyectos inventados, una sincronización real con la app
# (para que haya historial) y un caso de "dos versiones". Deja las imágenes en docs/capturas/{es,en}.
# Uso: herramientas/capturas-demo.sh
set -uo pipefail
cd "$(dirname "$0")/.."
source herramientas/imagenes.sh   # soltar_imagenes / revisar_sin_imagenes (limpieza de imágenes de ensayo)
# Desde la app armada (así las capturas muestran el ícono de Relevo).
./compilar.sh >/dev/null 2>&1 || { echo "no compila"; exit 1; }
BIN="$PWD/build/Relevo.app/Contents/MacOS/Relevo"
TMP=$(mktemp -d /private/tmp/relevo-demo.XXXX)
CASA="$TMP/casa"; mkdir -p "$CASA/Library/Application Support/Relevo"
PID=""
limpiar() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  # Por el archivo de la imagen (en casa Relevo le cambia el nombre al portátil, así que por /Volumes no alcanza).
  soltar_imagenes "$TMP/"; revisar_sin_imagenes "$TMP/"
  rm -rf "$TMP"
}
trap limpiar EXIT

hdiutil create -quiet -size 2g -fs APFS -volname Studio -type SPARSE "$TMP/hub-img"
hdiutil create -quiet -size 2g -fs APFS -volname Studio -type SPARSE "$TMP/port-img"
# Relevo busca los discos en /Volumes: se montan ahí (el segundo queda como "Studio 1", igual que en la vida real).
[ -e /Volumes/Studio ] && { echo "Ya hay un disco llamado Studio: desconectalo y probá de nuevo"; exit 1; }
hdiutil attach -quiet "$TMP/hub-img.sparseimage"
hdiutil attach -quiet "$TMP/port-img.sparseimage"
HUB=/Volumes/Studio; PORT="/Volumes/Studio 1"
UH=$(diskutil info "$HUB" | awk -F': *' '/Volume UUID/ {print $2}')
UP=$(diskutil info "$PORT" | awk -F': *' '/Volume UUID/ {print $2}')

# Proyectos de ejemplo.
for p in "Web app" "Landing" "Mobile app" "Design system"; do
  mkdir -p "$HUB/Projects/$p/src" "$HUB/Projects/$p/node_modules/lib"
  for i in $(seq 1 40); do head -c $((RANDOM * 4)) /dev/urandom > "$HUB/Projects/$p/src/file$i.ts"; done
  echo "# $p" > "$HUB/Projects/$p/README.md"
done
mkdir -p "$HUB/Clients/Acme" "$HUB/Photos/2026" "$HUB/Music"
for i in $(seq 1 12); do head -c 900000 /dev/urandom > "$HUB/Photos/2026/IMG_$i.jpg"; done
echo "notes" > "$HUB/Clients/Acme/brief.md"

escribir_ajustes() {
cat > "$CASA/Library/Application Support/Relevo/ajustes.json" <<JSON
{"idioma":"$1","vinculos":[{"id":"demo","hub":{"uuid":"$UH","nombre":"Studio","subcarpeta":""},
 "portatil":{"uuid":"$UP","nombre":"Studio","subcarpeta":""},
 "carpetas":["Projects/*","Projects/.","Clients/*","Clients/."],"omitidas":[],"ocultarEnCasa":false}]}
JSON
}
orden() { osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('team.halyon.relevo.prueba', '$1', \$(), true)" >/dev/null; }

escribir_ajustes es
RELEVO_PRUEBA=1 CFFIXED_USER_HOME="$CASA" "$BIN" > "$TMP/app.log" 2>&1 &
PID=$!
sleep 3; orden sincronizar; sleep 8
# Un cambio en cada lado del mismo archivo: "dos versiones".
echo "home version" >> "$HUB/Projects/Landing/README.md"
# Con la app abierta el portátil ya se llama "Studio (portátil)": su ruta se busca por UUID.
PORT=$(diskutil info -plist "$UP" | plutil -extract MountPoint raw -)
sleep 1; echo "laptop version, newer" >> "$PORT/Projects/Landing/README.md"
echo "export const x = 1" > "$HUB/Projects/Web app/src/new.ts"
sleep 6; orden sincronizar; sleep 6
kill "$PID"; wait "$PID" 2>/dev/null; PID=""

for idioma in es en; do
  escribir_ajustes $idioma
  rm -rf "docs/capturas/$idioma"; mkdir -p "docs/capturas/$idioma"
  CFFIXED_USER_HOME="$CASA" "$BIN" --capturas "docs/capturas/$idioma" >/dev/null 2>&1
  rm -f docs/capturas/$idioma/disco-*.png
done
echo "Listo: $(ls docs/capturas/es | wc -l | tr -d ' ') capturas por idioma en docs/capturas/"
