#!/bin/zsh
# Prueba de la revisión inteligente con discos de ensayo (nunca con discos reales): Relevo revisa solo lo que cambió
# según el registro de cambios de macOS, también con Relevo cerrado y con el portátil usado afuera; si el registro no
# sirve, revisa todo; la revisión completa de fondo se frena sola si te vas.
# Uso: herramientas/prueba-inteligente.sh
set -uo pipefail
cd "$(dirname "$0")/.."
source herramientas/imagenes.sh   # soltar_imagenes / revisar_sin_imagenes (limpieza de imágenes de ensayo)
swift build -c release --product Relevo >/dev/null 2>&1 || { echo "no compila"; exit 1; }
BIN="$(swift build -c release --product Relevo --show-bin-path)/Relevo"
TMP=$(mktemp -d /private/tmp/relevo-intel.XXXX)
CASA="$TMP/casa"; mkdir -p "$CASA/Library/Application Support/Relevo"
LOG="$TMP/app.log"; PID=""
limpiar() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  # Por el archivo de la imagen, no por /Volumes: la que Relevo expulsó o desmontó también sale.
  soltar_imagenes "$TMP/"; revisar_sin_imagenes "$TMP/"
  rm -rf "$TMP"
}
trap limpiar EXIT
orden() { osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('team.halyon.relevo.prueba', '$1', \$(), true)" >/dev/null; }
esperar() { local s=$1; shift; for i in $(seq 1 $((s * 4))); do eval "$@" && return 0; sleep 0.25; done; return 1; }
ok() { echo "✓ $1"; }
mal() { echo "✗ $1"; FALLAS=$((FALLAS + 1)); }
FALLAS=0
arrancar() { : > "$LOG"; RELEVO_PRUEBA=1 CFFIXED_USER_HOME="$CASA" "$BIN" >> "$LOG" 2>&1 & PID=$!; sleep 3; }
parar() { kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; PID=""; }
# Sincroniza (revisión inteligente) y espera a que termine; deja en $REVISA lo que decidió revisar.
vuelta() {
  : > "$LOG"; orden "${1:-sincronizar}"
  esperar 60 'grep -q "^REVISA" "$LOG"'
  REVISA=$(grep "^REVISA" "$LOG" | tail -1)
  esperar 120 'grep -q "ESTADO revisando\|ESTADO copiando" "$LOG" || [[ "$REVISA" == "REVISA 0:"* ]]'
  esperar 120 '[ "$(grep ESTADO "$LOG" | tail -1)" = "ESTADO alDia" ] || [[ "$REVISA" == "REVISA 0:"* ]]'
  sleep 1
}

hdiutil create -quiet -size 2g -fs APFS -volname SGIntHub -type SPARSE "$TMP/h"
hdiutil create -quiet -size 2g -fs APFS -volname SGIntPort -type SPARSE "$TMP/p"
hdiutil attach -quiet "$TMP/h.sparseimage"; hdiutil attach -quiet "$TMP/p.sparseimage"
H=/Volumes/SGIntHub; P=/Volumes/SGIntPort
UH=$(diskutil info $H | awk -F': *' '/Volume UUID/ {print $2}'); UP=$(diskutil info $P | awk -F': *' '/Volume UUID/ {print $2}')
python3 -I - <<'PY'
import os
for p in "ABC":
    for d in range(30):
        c = f"/Volumes/SGIntHub/Proyectos/{p}/c{d}"; os.makedirs(c, exist_ok=True)
        for f in range(100): open(f"{c}/a{f}.txt", "w").write("x" * 40)
PY
cat > "$CASA/Library/Application Support/Relevo/ajustes.json" <<JSON
{"idioma":"es","automatico":false,"enVivo":false,"vinculos":[{"id":"intel","hub":{"uuid":"$UH","nombre":"SGIntHub","subcarpeta":""},
 "portatil":{"uuid":"$UP","nombre":"SGIntPort","subcarpeta":""},"carpetas":["Proyectos/*"],"ocultarEnCasa":false}]}
JSON
arrancar
vuelta; [[ "$REVISA" == "REVISA todo" ]] && ok "La primera vez revisa todo" || mal "La primera vez: $REVISA"
[ -f $P/Proyectos/C/c29/a99.txt ] && ok "Copió todo" || mal "No copió todo"
vuelta; vuelta
[[ "$REVISA" == "REVISA 0:"* ]] && ok "Sin cambios no revisa nada ($REVISA)" || mal "Sin cambios revisó: $REVISA"

echo cambio > $H/Proyectos/B/c3/a1.txt; sleep 2
vuelta; [[ "$REVISA" == "REVISA 1: Proyectos/B" ]] && ok "Un cambio en el hub: revisa solo ese proyecto" || mal "Revisó: $REVISA"
[ "$(cat $P/Proyectos/B/c3/a1.txt)" = "cambio" ] && ok "Y lo copió" || mal "No lo copió"
grep -q "^ANALISIS Proyectos/B zonas" "$LOG" && ok "Miró solo la carpeta que cambió, no el proyecto entero ($(grep '^ANALISIS' "$LOG" | tail -1))" \
  || mal "Miró el proyecto entero: $(grep '^ANALISIS' "$LOG" | tail -1)"

parar
echo cerrado > $H/Proyectos/C/c0/a0.txt; sleep 2   # con Relevo cerrado
arrancar
vuelta; [[ "$REVISA" == *"Proyectos/C"* && "$REVISA" != *"Proyectos/A"* ]] && ok "Lo que cambió con Relevo cerrado se ve igual ($REVISA)" || mal "Con Relevo cerrado: $REVISA"
[ "$(cat $P/Proyectos/C/c0/a0.txt)" = "cerrado" ] && ok "Y lo copió" || mal "No lo copió"
grep -q "^ANALISIS Proyectos/C zonas" "$LOG" && ok "También por zonas tras cerrar bien Relevo" || mal "Tras cerrar bien: $(grep '^ANALISIS' "$LOG")"
vuelta

# Corte de luz (Relevo cerrado de golpe, sin cerrar bien): el registro puede no tener lo último, así que mira todo.
kill -9 "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; PID=""
echo corte > $H/Proyectos/A/c1/a1.txt; sleep 2
arrancar
vuelta; [[ "$REVISA" == "REVISA todo" ]] && ok "Después de un cierre de golpe revisa todo" || mal "Tras un cierre de golpe: $REVISA"
[ "$(cat $P/Proyectos/A/c1/a1.txt)" = "corte" ] && ok "Y lo copió" || mal "No lo copió tras el corte"
# La vez siguiente, de nuevo solo lo que cambió (a lo sumo lo que acaba de copiar Relevo, por zonas: centésimas).
vuelta; { [[ "$REVISA" == "REVISA 0:"* ]] || ! grep "^ANALISIS" "$LOG" | grep -qv " zonas "; } \
  && ok "La vez siguiente vuelve a mirar solo lo que cambió ($REVISA)" || mal "Después del corte sigue: $REVISA $(grep '^ANALISIS' "$LOG")"

# Afuera: sin el hub, se trabaja en el portátil (proyecto existente y uno nuevo).
hdiutil detach -quiet $H
echo afuera > $P/Proyectos/A/c5/a5.txt; mkdir -p $P/Proyectos/D; echo nuevo > $P/Proyectos/D/n.txt; sleep 2
hdiutil attach -quiet "$TMP/h.sparseimage"; sleep 3
vuelta; [[ "$REVISA" == *"Proyectos/A"* && "$REVISA" == *"Proyectos/D"* && "$REVISA" != *"Proyectos/C"* ]] && ok "Al volver revisa solo lo de afuera ($REVISA)" || mal "Al volver: $REVISA"
[ "$(cat $H/Proyectos/A/c5/a5.txt)" = "afuera" ] && [ -f $H/Proyectos/D/n.txt ] && ok "Trajo lo de afuera, también el proyecto nuevo" || mal "No trajo lo de afuera"
grep -q "^ANALISIS Proyectos/A zonas" "$LOG" && grep -q "^ANALISIS Proyectos/D entera" "$LOG" \
  && ok "Lo de afuera por zonas; el proyecto nuevo, entero" || mal "Al volver: $(grep '^ANALISIS' "$LOG" | tr '\n' ' ')"

rm -f "$CASA/Library/Application Support/Relevo/pares/intel/marcas.json"
vuelta; [[ "$REVISA" == "REVISA todo" ]] && ok "Sin marca (registro perdido): revisa todo" || mal "Sin marca: $REVISA"

# La revisión completa de fondo se frena sola si te vas.
python3 -I - <<'PY'
import os
for p in ["E", "F", "G"]:
    for d in range(150):
        c = f"/Volumes/SGIntHub/Proyectos/{p}/c{d}"; os.makedirs(c, exist_ok=True)
        for f in range(100): open(f"{c}/a{f}.txt", "w").write("y")
PY
vuelta
: > "$LOG"; orden revision-completa
esperar 20 'grep -q "REVISION COMPLETA" "$LOG"' && ok "Arranca la revisión completa de fondo" || mal "No arrancó la revisión completa"
sleep 0.3; T0=$(date +%s); orden mevoy
esperar 60 '! diskutil info $P >/dev/null 2>&1' && ok "“Me voy” en medio: la frena y expulsa en $(( $(date +%s) - T0 )) s" || mal "“Me voy” no expulsó ($(grep PANTALLA "$LOG" | tail -1))"
parar

echo
if [ $FALLAS = 0 ]; then echo "Todo bien"; else echo "$FALLAS falla(s)"; tail -20 "$LOG"; fi
exit $FALLAS
