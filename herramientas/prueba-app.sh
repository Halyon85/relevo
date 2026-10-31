#!/bin/zsh
# Prueba de punta a punta de la APP (no solo del motor) con dos discos de ensayo, sin tocar discos reales:
# enchufar → sincroniza sola; copia en vivo de los dos lados; abrir/cerrar panel; "Me voy" expulsa;
# trabajar "afuera" y volver; memoria (footprint) y fugas (leaks) en cada etapa.
# Uso: herramientas/prueba-app.sh
set -uo pipefail
cd "$(dirname "$0")/.."
source herramientas/imagenes.sh   # soltar_imagenes / revisar_sin_imagenes (limpieza de imágenes de ensayo)
swift build -c release --product Relevo >/dev/null 2>&1 || { echo "no compila"; exit 1; }
BIN="$(swift build -c release --product Relevo --show-bin-path)/Relevo"
TMP=$(mktemp -d /private/tmp/relevo-app.XXXX)
CASA="$TMP/casa"; mkdir -p "$CASA/Library/Application Support/Relevo"
LOG="$TMP/app.log"; PID=""; OCUPA=""

limpiar() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  [ -n "$OCUPA" ] && kill "$OCUPA" 2>/dev/null
  # Por el archivo de la imagen, no por /Volumes: "Me voy" y Expulsar las desmontan y quedaban adjuntas.
  soltar_imagenes "$TMP/"; revisar_sin_imagenes "$TMP/"
  rm -rf "$TMP"
}
trap limpiar EXIT

hdiutil create -quiet -size 6g -fs APFS -volname SGHubApp -type SPARSE "$TMP/hub"
hdiutil create -quiet -size 6g -fs APFS -volname SGPortApp -type SPARSE "$TMP/port"
hdiutil attach -quiet "$TMP/hub.sparseimage"; hdiutil attach -quiet "$TMP/port.sparseimage"
HUB=/Volumes/SGHubApp; PORT=/Volumes/SGPortApp
[ -d "$HUB" ] && [ -d "$PORT" ] || { echo "no montaron los discos de ensayo"; exit 1; }
UH=$(diskutil info "$HUB" | awk -F': *' '/Volume UUID/ {print $2}')
UP=$(diskutil info "$PORT" | awk -F': *' '/Volume UUID/ {print $2}')
cat > "$CASA/Library/Application Support/Relevo/ajustes.json" <<JSON
{"idioma":"es","hubUUID":"$UH","hubNombre":"SGHubApp","portatilUUID":"$UP","portatilNombre":"SGPortApp",
 "carpetas":["Proyectos/*","Notas"],"automatico":true,"enVivo":true}
JSON

# Datos: 2 proyectos (uno con node_modules, que no viaja) y una carpeta suelta.
mkdir -p "$HUB/Proyectos/A" "$HUB/Proyectos/B/node_modules/x" "$HUB/Notas"
for i in $(seq 1 500); do echo "archivo $i" > "$HUB/Proyectos/A/f$i.txt"; done
for i in 1 2 3; do head -c 31457280 /dev/urandom > "$HUB/Proyectos/B/video$i.mov"; done
echo "dependencia" > "$HUB/Proyectos/B/node_modules/x/index.js"
mkdir -p "$HUB/Proyectos/B/.next/cache"; echo "compilado" > "$HUB/Proyectos/B/.next/cache/x"
# Un repo git con un cambio sin commit (para el aviso al irse).
if [ -x /opt/homebrew/bin/git ] || [ -x /Library/Developer/CommandLineTools/usr/bin/git ]; then
  ( cd "$HUB/Proyectos/A" && git init -q && git add -A && git -c user.name=prueba -c user.email=prueba@ejemplo.com commit -qm inicial && echo cambio >> f1.txt )
fi
echo "nota" > "$HUB/Notas/hola.md"
hdiutil detach -quiet "$PORT"   # la app arranca con el portátil desenchufado

orden() { osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('team.halyon.relevo.prueba', '$1', \$(), true)" >/dev/null; }
memoria() { footprint -p "$PID" 2>/dev/null | awk '/phys_footprint:/ {print $2, $3; exit}'; }
fugas() { leaks "$PID" 2>/dev/null | grep -E "leaks for|Process [0-9]+: [0-9]+ leak" | head -1; }
esperar() {  # esperar <segundos> <condición>
  local s=$1; shift
  for i in $(seq 1 $((s * 4))); do eval "$@" && return 0; sleep 0.25; done; return 1
}
iguales() { diff -rq -x '.Relevo' -x '.DS_Store' -x '.next' -x '.fseventsd' -x '.Spotlight-V100' -x '.Trashes' -x '.TemporaryItems' "$HUB/$1" "$PORT/$1" >/dev/null 2>&1; }
ok() { echo "✓ $1"; }
mal() { echo "✗ $1"; FALLAS=$((FALLAS + 1)); }
FALLAS=0

RELEVO_PRUEBA=1 CFFIXED_USER_HOME="$CASA" "$BIN" > "$LOG" 2>&1 &
PID=$!
sleep 3
echo "Memoria en reposo, sin portátil: $(memoria)"

hdiutil attach -quiet "$TMP/port.sparseimage"
esperar 90 'iguales Proyectos && iguales Notas' && ok "Al enchufar sincronizó sola" || mal "No sincronizó al enchufar"
esperar 15 'mount | grep " on $PORT " | grep -q nobrowse' && ok "En casa el portátil quedó oculto del Finder" || mal "El portátil no quedó oculto"
[ -f "$HUB/.VolumeIcon.icns" ] && [ -f "$PORT/.VolumeIcon.icns" ] && ok "Cada disco tiene su ícono" || mal "Faltan los íconos de los discos"
[ -f "$PORT/Proyectos/B/node_modules/x/index.js" ] && ok "Las dependencias viajaron (opción prendida)" || mal "node_modules no viajó"
[ ! -e "$PORT/Proyectos/B/.next" ] && ok ".next (regenerable) no viajó" || mal ".next viajó"
esperar 10 'grep -q "ESTADO alDia" "$LOG"' && ok "Quedó \"Todo al día\"" || mal "No llegó a al día"
echo "Memoria después de la primera copia: $(memoria)"

echo "cambio en casa" >> "$HUB/Proyectos/A/f1.txt"
esperar 15 'iguales Proyectos/A' && ok "En vivo: cambio del hub llegó al portátil" || mal "En vivo hub→portátil"
mkdir -p "$PORT/Proyectos/C"; echo "nuevo proyecto afuera" > "$PORT/Proyectos/C/leeme.md"
esperar 15 '[ -f "$HUB/Proyectos/C/leeme.md" ]' && ok "En vivo: proyecto nuevo del portátil llegó al hub" || mal "En vivo portátil→hub"

# Antes de dormir: un cambio recién hecho (todavía esperando la copia en vivo) se copia antes de "dormir".
echo "antes de dormir" > "$HUB/Proyectos/A/dormir.txt"; orden dormir
esperar 20 'grep -q DORMIR-LISTO "$LOG"' && [ -f "$PORT/Proyectos/A/dormir.txt" ] && ok "Antes de dormir copió lo pendiente" || mal "Antes de dormir"

orden panel; sleep 2; echo "Memoria con el panel abierto: $(memoria)"
orden cerrar; sleep 2; echo "Memoria con el panel cerrado: $(memoria)"
echo "Fugas: $(fugas)"

# Un proyecto cuya configuración de git trae un comando (como podría venir en un portátil armado en otra máquina):
# Relevo corre git solo al irse ("Ojo con git") y no tiene que ejecutarlo.
[ -d "$HUB/Proyectos/A/.git" ] && git -C "$HUB/Proyectos/A" config core.fsmonitor "touch $TMP/MARCA_GIT; false"
orden mevoy
esperar 30 '! mount | grep -q " on $PORT "' && ok "Me voy: copió y expulsó el portátil" || mal "Me voy no expulsó"
[ ! -e "$TMP/MARCA_GIT" ] && ok "git no ejecutó el comando de la configuración del proyecto" || mal "git ejecutó un comando del proyecto"
esperar 10 'grep -q "AVISO Listo para irte" "$LOG"' && ok "Avisó \"Listo para irte\"" || mal "No avisó al irse"
if [ -d "$HUB/Proyectos/A/.git" ]; then
  esperar 10 'grep -q "Ojo con git: A" "$LOG"' && ok "Al irse avisó de git (A sin commit)" || mal "No avisó de git"
fi

# "Afuera": la app cerrada y sin hub; se trabaja en el portátil.
kill "$PID"; wait "$PID" 2>/dev/null; PID=""
hdiutil detach -quiet "$HUB"; hdiutil attach -quiet "$TMP/port.sparseimage"
echo "editado afuera" >> "$PORT/Proyectos/A/f2.txt"; rm "$PORT/Proyectos/A/f3.txt"; echo "otra nota" > "$PORT/Notas/afuera.md"
hdiutil detach -quiet "$PORT"; hdiutil attach -quiet "$TMP/hub.sparseimage"
RELEVO_PRUEBA=1 CFFIXED_USER_HOME="$CASA" "$BIN" >> "$LOG" 2>&1 &
PID=$!
sleep 2
hdiutil attach -quiet "$TMP/port.sparseimage"
esperar 60 'iguales Proyectos && iguales Notas' && ok "Al volver trajo lo de afuera" || mal "No trajo lo de afuera"
# Al juntarse los discos avisa que esperes antes de abrir tus apps y, al terminar, "Listo" con el resumen de lo traído
# (un solo aviso: el "Bienvenido de vuelta" va adentro del "Listo").
grep -q "AVISO Esperá antes de abrir tus apps" "$LOG" && ok "Al volver avisó que esperes" || mal "Al volver no avisó que esperes"
esperar 15 'grep -q "AVISO Listo, ya podés abrir tus apps: Traje" "$LOG"' && ok "Listo con el resumen al volver" \
  || mal "Sin listo con resumen al volver ($(grep AVISO "$LOG" | tail -2 | tr '\n' ' '))"
[ ! -e "$HUB/Proyectos/A/f3.txt" ] && ls "$HUB/.Relevo/Papelera/"*/Proyectos/A/f3.txt >/dev/null 2>&1 \
  && ok "Lo borrado afuera fue a la papelera del hub" || mal "Borrado afuera"
echo "Memoria al final: $(memoria)"
echo "Fugas antes de expulsar: $(fugas)"
# Expulsar discos (solo los de ensayo).
orden expulsar
esperar 30 '! mount | grep -q " on $PORT " && ! mount | grep -q " on $HUB "' && ok "Expulsar discos: expulsó los dos de ensayo" || mal "Expulsar discos"
esperar 10 'grep -q "AVISO Discos expulsados" "$LOG"' && ok "Avisó que se pueden desenchufar" || mal "Sin aviso de expulsados"

# El portátil ya enchufado (afuera, con cambios) y el hub llega después: la copia automática arranca igual al
# aparecer el hub, sin esperar a que se vuelva a enchufar el portátil.
N=$(( $(wc -l < "$LOG") ))   # sin los espacios que pone wc en macOS (si no, `tail -n +N` falla)
hdiutil attach -quiet "$TMP/hub.sparseimage"; hdiutil attach -quiet "$TMP/port.sparseimage"
# Que termine la vuelta de enchufarlos (y la revisión que le sigue) antes de sacar el hub.
esperar 30 'tail -n +$N "$LOG" | grep -q "^REVISA"'; esperar 30 '[ "$(grep ESTADO "$LOG" | tail -1)" = "ESTADO alDia" ]'; sleep 4
# Algo trabaja adentro del portátil (como una sesión de Claude): así Relevo no lo puede volver a montar para mostrarlo u
# ocultarlo, que es lo que antes hacía arrancar la vuelta de casualidad.
( cd "$PORT/Notas" && exec sleep 120 ) &
OCUPA=$!
hdiutil detach -quiet "$HUB"; sleep 2      # se va solo el hub; el portátil queda enchufado
echo "hecho antes de que llegue el hub" > "$PORT/Notas/antes-del-hub.md"; sleep 2
cp "$LOG" "$LOG.antes"
hdiutil attach -quiet "$TMP/hub.sparseimage"
esperar 40 '[ -f "$HUB/Notas/antes-del-hub.md" ]' && ok "Con el portátil ya enchufado, al llegar el hub copia solo" \
  || mal "Al llegar el hub no copió lo del portátil"
# Y no solo por la copia en vivo: arranca la vuelta de "llegué a casa" (revisa lo que cambió afuera).
esperar 15 '[ "$(grep -c "^REVISA" "$LOG")" -gt "$(grep -c "^REVISA" "$LOG.antes")" ]' \
  && ok "Al llegar el hub arranca la vuelta automática" || mal "Al llegar el hub no arrancó la vuelta automática"
kill "$OCUPA" 2>/dev/null; wait "$OCUPA" 2>/dev/null; OCUPA=""
orden expulsar
esperar 30 '! mount | grep -q " on $PORT " && ! mount | grep -q " on $HUB "' || mal "No expulsó al final"

echo "Restos temporales: $(find "$HUB" "$PORT" -name '*.relevo-tmp' 2>/dev/null | wc -l | tr -d ' ')"
echo "Historial: $(python3 -c "import json;print(len(json.load(open('$CASA/Library/Application Support/Relevo/historial.json'))))" 2>/dev/null) movimientos"
[ $FALLAS = 0 ] && echo "RESULTADO: todo bien" || { echo "RESULTADO: $FALLAS con problemas"; tail -20 "$LOG"; exit 1; }
