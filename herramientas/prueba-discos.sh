#!/bin/zsh
# Prueba de la APP con discos de ensayo (nunca con discos reales) de dos cosas que dependen de cómo monta macOS:
# 1) Los nombres: hub y portátil se llaman igual. En casa el portátil lleva "<nombre> (portátil)" y, si al prender
#    la Mac se montó primero, se acomoda solo (cambiando nombres, sin desmontar, aunque estén en uso). Afuera toma el
#    nombre del hub; al volver, cada uno el suyo; con "Me voy" se va con el nombre del hub.
# 2) Desbloqueo automático: un portátil cifrado y cerrado, con su clave guardada, se abre solo al enchufarlo.
# Al final desmonta y borra las imágenes de ensayo, pase lo que pase.
# Uso: herramientas/prueba-discos.sh
set -uo pipefail
cd "$(dirname "$0")/.."
source herramientas/imagenes.sh   # soltar_imagenes / revisar_sin_imagenes (limpieza de imágenes de ensayo)
swift build -c release --product Relevo >/dev/null 2>&1 || { echo "no compila"; exit 1; }
BIN="$(swift build -c release --product Relevo --show-bin-path)/Relevo"
TMP=$(mktemp -d /private/tmp/relevo-discos.XXXX)
CASA="$TMP/casa"; mkdir -p "$CASA/Library/Application Support/Relevo"
LOG="$TMP/app.log"; PID=""; OCUPA=""; OCUPA2=""

limpiar() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  [ -n "$OCUPA" ] && kill "$OCUPA" 2>/dev/null
  [ -n "$OCUPA2" ] && kill "$OCUPA2" 2>/dev/null
  # Por el archivo de la imagen: también las adjuntadas con -nomount o que Relevo desmontó.
  soltar_imagenes "$TMP/"; revisar_sin_imagenes "$TMP/"
  rm -rf "$TMP"
}
trap limpiar EXIT

orden() { osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('team.halyon.relevo.prueba', '$1', \$(), true)" >/dev/null; }
esperar() { local s=$1; shift; for i in $(seq 1 $((s * 4))); do eval "$@" && return 0; sleep 0.25; done; return 1; }
uuid() { diskutil info "$1" 2>/dev/null | awk -F': *' '/Volume UUID/ {print $2}'; }
# macOS guarda las rutas con los acentos descompuestos (á = a + ´): se pasan a la forma común para comparar.
montado_en() { python3 -I -c 'import sys,unicodedata; print(unicodedata.normalize("NFC", sys.stdin.read().strip()))' \
  <<< "$(diskutil info "$1" 2>/dev/null | awk -F': *' '/Mount Point/ {print $2}')"; }
ok() { echo "✓ $1"; }
mal() { echo "✗ $1"; FALLAS=$((FALLAS + 1)); }
FALLAS=0
arrancar() {
  ARRANQUE=$(date +%s)
  : > "$LOG"
  RELEVO_PRUEBA=1 CFFIXED_USER_HOME="$CASA" "$BIN" > "$LOG" 2>&1 &
  PID=$!
}
parar() { kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; PID=""; }
ajustes() {  # ajustes <uuid hub> <nombre hub> <uuid portátil> <nombre portátil> [ocultar en casa: true/false, si no false]
cat > "$CASA/Library/Application Support/Relevo/ajustes.json" <<JSON
{"idioma":"es","automatico":false,"enVivo":false,"vinculos":[{"id":"prueba","hub":{"uuid":"$1","nombre":"$2","subcarpeta":""},
 "portatil":{"uuid":"$3","nombre":"$4","subcarpeta":""},"carpetas":["Proyectos/*"],"ocultarEnCasa":${5:-false}}]}
JSON
}
# ¿Está montado oculto (nobrowse, fuera de la barra lateral del Finder)? oculto <punto de montaje>
oculto() { [ -n "$1" ] && mount | grep -F "on $1 (" | grep -q nobrowse; }

# ── 1) Los nombres de los discos ───────────────────────────────────────────────────────────────────────────────
# Hub y portátil se llaman igual. En casa el portátil pasa a "SGAcomodo (portátil)"; solo (afuera), toma "SGAcomodo".
# Todo cambiando nombres, sin desmontar: anda aunque los discos estén en uso.
[ -e /Volumes/SGAcomodo ] && { echo "Ya hay un disco llamado SGAcomodo: desconectalo y probá de nuevo"; exit 1; }
hdiutil create -quiet -size 2g -fs APFS -volname SGAcomodo -type SPARSE "$TMP/hubA"
hdiutil create -quiet -size 2g -fs APFS -volname SGAcomodo -type SPARSE "$TMP/portA"
# Como al prender la Mac con los dos enchufados: el portátil monta primero, se queda con /Volumes/SGAcomodo y el hub
# pasa a "SGAcomodo 1" (al revés).
hdiutil attach -quiet "$TMP/portA.sparseimage"; UP=$(uuid /Volumes/SGAcomodo)
hdiutil attach -quiet "$TMP/hubA.sparseimage"; UH=$(uuid "/Volumes/SGAcomodo 1")
[ -n "$UP" ] && [ -n "$UH" ] && [ "$UP" != "$UH" ] || { echo "no montaron los discos de ensayo"; exit 1; }
mkdir -p "/Volumes/SGAcomodo 1/Proyectos/A"; echo hub > "/Volumes/SGAcomodo 1/Proyectos/A/quien.txt"
ajustes "$UH" SGAcomodo "$UP" SGAcomodo
# Los dos en uso (una terminal parada adentro de cada uno), como con Claude o un editor abiertos.
( cd "/Volumes/SGAcomodo 1/Proyectos" && exec sleep 300 ) &
OCUPA=$!
( cd "/Volumes/SGAcomodo" && exec sleep 300 ) &
OCUPA2=$!
echo "hecho en el portátil" > /Volumes/SGAcomodo/trabajo.txt; mkdir -p /Volumes/SGAcomodo/Proyectos/A
echo "afuera" > /Volumes/SGAcomodo/Proyectos/A/afuera.txt
arrancar
# Algo trabaja adentro del portátil (que tiene la ruta /Volumes/SGAcomodo): no se le cambia el nombre todavía,
# porque lo que guarda por esa ruta pasaría a escribir en el hub a mitad de camino. Se copia igual.
esperar 20 'grep -q "PANTALLA .* quedó abierto en el portátil. Cerralo" "$LOG"' && ok "Portátil en uso: avisa qué app cerrar para pasar al hub" \
  || mal "No avisó que espera ($(grep PANTALLA "$LOG" | tail -1))"
grep -q "AVISO Cerrá .* un momento" "$LOG" && ok "Portátil en uso: también como notificación" || mal "Sin notificación de la app a cerrar"
sleep 5
[ "$(montado_en "$UP")" = "/Volumes/SGAcomodo" ] && ok "Mientras lo usás, el portátil sigue con la ruta de siempre" \
  || mal "Le cambió el nombre al portátil en uso ('$(montado_en "$UP")')"
orden sincronizar
esperar 30 '[ "$(cat "/Volumes/SGAcomodo 1/Proyectos/A/afuera.txt" 2>/dev/null)" = "afuera" ]' && ok "Mientras espera, sincroniza igual (lo de afuera llegó al hub)" \
  || mal "Mientras esperaba no sincronizó ($(grep -E "ESTADO|REVISA" "$LOG" | tail -2 | tr '\n' ' '))"
kill $OCUPA2 2>/dev/null; wait $OCUPA2 2>/dev/null; OCUPA2=""
esperar 30 '[ "$(montado_en "$UH")" = "/Volumes/SGAcomodo" ] && [ "$(montado_en "$UP")" = "/Volumes/SGAcomodo (portátil)" ]' \
  && ok "Cuando lo dejás de usar, pasa al hub solo (hub en /Volumes/SGAcomodo, portátil en “SGAcomodo (portátil)”)" \
  || mal "No se acomodó (hub '$(montado_en "$UH")', portátil '$(montado_en "$UP")')"
[ "$(cat /Volumes/SGAcomodo/Proyectos/A/quien.txt 2>/dev/null)" = "hub" ] && ok "/Volumes/SGAcomodo es el hub" || mal "/Volumes/SGAcomodo no es el hub"
esperar 15 'grep -q "AVISO Listo, ya podés abrir tus apps" "$LOG"' && ok "Ya en el hub, avisa que se puede volver a abrir" \
  || mal "No avisó que ya se puede abrir ($(grep AVISO "$LOG" | tail -1))"
kill -0 $OCUPA 2>/dev/null && ok "Lo que estaba abierto en el hub sigue andando" || mal "Se cortó algo que estaba abierto"
kill $OCUPA 2>/dev/null; wait $OCUPA 2>/dev/null; OCUPA=""
esperar 15 '[ "$(grep ESTADO "$LOG" | tail -1)" != "ESTADO alReves" ]' \
  && ok "La app ya no los ve al revés ($(grep ESTADO "$LOG" | tail -1 | cut -d' ' -f2))" || mal "La app sigue viéndolos al revés"

# Afuera: se va el hub y queda el portátil solo. Pasados unos 20 segundos toma el nombre del hub.
hdiutil detach -quiet "/Volumes/SGAcomodo"
esperar 40 '[ "$(montado_en "$UP")" = "/Volumes/SGAcomodo" ]' && ok "Afuera, el portátil toma el nombre del hub (/Volumes/SGAcomodo)" \
  || mal "Afuera, el portátil quedó en '$(montado_en "$UP")'"

# De vuelta en casa con el portátil llamándose como el hub: el hub entra como "SGAcomodo 1" y se acomoda solo.
hdiutil attach -quiet "$TMP/hubA.sparseimage"
esperar 20 '[ "$(montado_en "$UH")" = "/Volumes/SGAcomodo" ] && [ "$(montado_en "$UP")" = "/Volumes/SGAcomodo (portátil)" ]' \
  && ok "Al volver, cada uno con su nombre otra vez" || mal "Al volver: hub '$(montado_en "$UH")', portátil '$(montado_en "$UP")'"

# "Me voy": copia, le pone al portátil el nombre del hub y expulsa todos los discos (el hub también: te vas).
orden mevoy
esperar 90 '[ -z "$(montado_en "$UP")" ]' && ok "Me voy: expulsó el portátil" || mal "Me voy no expulsó el portátil ($(grep PANTALLA "$LOG" | tail -1))"
esperar 30 '[ -z "$(montado_en "$UH")" ]' && ok "Me voy: expulsó también el hub" || mal "Me voy dejó el hub montado"
hdiutil attach -quiet "$TMP/hubA.sparseimage"
hdiutil attach -quiet -nomount "$TMP/portA.sparseimage"
NOMBRE_IDO=$(diskutil info -plist "$UP" 2>/dev/null | plutil -extract VolumeName raw - 2>/dev/null)
[ "$NOMBRE_IDO" = "SGAcomodo" ] && ok "Se fue llamándose como el hub (“SGAcomodo”)" || mal "Se fue llamándose “$NOMBRE_IDO”"
diskutil mount "$UP" >/dev/null 2>&1
esperar 20 '[ "$(montado_en "$UP")" = "/Volumes/SGAcomodo (portátil)" ] && [ "$(montado_en "$UH")" = "/Volumes/SGAcomodo" ]' \
  && ok "Enchufado de nuevo en casa, vuelve a “SGAcomodo (portátil)”" || mal "En casa quedó '$(montado_en "$UP")'"
# En casa le cambiás el nombre al portátil en el Finder: Relevo lo respeta (afuera igual va con el nombre del hub).
diskutil rename "$UP" "SGMiPortatil" >/dev/null 2>&1
sleep 8
[ "$(montado_en "$UP")" = "/Volumes/SGMiPortatil" ] && ok "En casa respeta el nombre que le pusiste al portátil" \
  || mal "En casa no respetó el nombre: quedó '$(montado_en "$UP")'"

# Sin "Me voy": se expulsa el portátil como en el Finder y se enchufa solo (afuera). Con Relevo ya andando, toma el
# nombre del hub en segundos.
while [ $(( $(date +%s) - ARRANQUE )) -lt 95 ]; do sleep 1; done
diskutil eject "$UP" >/dev/null 2>&1 || hdiutil detach -quiet "$(montado_en "$UP")"
hdiutil detach -quiet "/Volumes/SGAcomodo"
hdiutil attach -quiet "$TMP/portA.sparseimage"
esperar 12 '[ "$(montado_en "$UP")" = "/Volumes/SGAcomodo" ]' && ok "Expulsado sin “Me voy” y enchufado afuera: toma el nombre del hub en segundos" \
  || mal "Afuera sin “Me voy” quedó '$(montado_en "$UP")'"
parar
for u in $UP $UH; do m=$(montado_en $u); [ -n "$m" ] && hdiutil detach -quiet -force "$m" 2>/dev/null; done

# ── 1b) Borrados que esperan tu OK: "Me voy" no se traba y, pasado el plazo, se aplican solos ──────────────────────
hdiutil create -quiet -size 2g -fs APFS -volname SGBorraHub -type SPARSE "$TMP/hubB"
hdiutil create -quiet -size 2g -fs APFS -volname SGBorraPort -type SPARSE "$TMP/portB"
hdiutil attach -quiet "$TMP/hubB.sparseimage"; hdiutil attach -quiet "$TMP/portB.sparseimage"
UHB=$(uuid /Volumes/SGBorraHub); UPB=$(uuid /Volumes/SGBorraPort)
mkdir -p /Volumes/SGBorraHub/Proyectos/{viejo,nuevo}; echo x > /Volumes/SGBorraHub/Proyectos/viejo/a.txt; echo y > /Volumes/SGBorraHub/Proyectos/nuevo/b.txt
ajustes "$UHB" SGBorraHub "$UPB" SGBorraPort
RELEVO_PRUEBA_APLICAR_SEGUNDOS=25 arrancar
sleep 3; orden sincronizar
esperar 30 '[ -f /Volumes/SGBorraPort/Proyectos/viejo/a.txt ]' && ok "Primera copia hecha" || mal "No hizo la primera copia"
rm -rf /Volumes/SGBorraHub/Proyectos/viejo   # borrado a propósito en el hub
sleep 2; orden sincronizar
esperar 20 'grep -q "PEDIDO Proyectos/viejo" "$LOG"' && ok "Pide el OK para borrar Proyectos/viejo del portátil" || mal "No pidió el OK"
[ -f /Volumes/SGBorraPort/Proyectos/viejo/a.txt ] && ok "Sin OK todavía no se borró nada" || mal "Se borró sin OK"
sleep 30; orden sincronizar   # pasó el plazo (25 s en esta prueba)
esperar 30 '[ ! -e /Volumes/SGBorraPort/Proyectos/viejo ]' && ok "Pasado el plazo, el borrado se aplicó solo" || mal "No se aplicó solo"
esperar 10 'grep -q "PANTALLA Pasaron" "$LOG"' && ok "Avisó que lo aplicó" || mal "No avisó"
[ -n "$(find /Volumes/SGBorraPort/.Relevo/papelera -name a.txt 2>/dev/null)" ] && ok "Lo borrado quedó en la papelera de Relevo" || mal "No está en la papelera"
[ -f /Volumes/SGBorraPort/Proyectos/nuevo/b.txt ] && ok "Lo demás sigue igual" || mal "Se tocó algo de más"
# Otro borrado pendiente y "Me voy": no se traba.
rm -rf /Volumes/SGBorraHub/Proyectos/nuevo
sleep 2; orden sincronizar; esperar 20 'grep -q "PEDIDO Proyectos/nuevo" "$LOG"'
# Y algo de fondo parado en el portátil (sin ninguna app detrás, como un servidor o una terminal suelta): se cierra solo.
( cd /Volumes/SGBorraPort/Proyectos && nohup sleep 300 >/dev/null 2>&1 & )
sleep 1
FONDO=$(pgrep -f "^sleep 300$" | head -1)
orden mevoy
esperar 60 '[ -z "$(montado_en "$UPB")" ]' && ok "Con un borrado esperando OK y algo de fondo usándolo, “Me voy” igual expulsa" || mal "“Me voy” se trabó ($(grep PANTALLA "$LOG" | tail -1))"
[ -n "$FONDO" ] && ! kill -0 "$FONDO" 2>/dev/null && ok "Lo de fondo se cerró solo" || mal "Lo de fondo sigue abierto"
parar
for u in $UPB $UHB; do m=$(montado_en $u); [ -n "$m" ] && hdiutil detach -quiet -force "$m" 2>/dev/null; done

# ── 2) Desbloqueo automático de un portátil cifrado ────────────────────────────────────────────────────────────
[ -e /Volumes/SGCifPort ] && { echo "Ya hay un disco llamado SGCifPort: desconectalo y probá de nuevo"; exit 1; }
hdiutil create -quiet -size 200m -fs APFS -volname SGCifHub -type SPARSE "$TMP/hubC"
hdiutil create -quiet -size 200m -fs APFS -volname SGCifPort -type SPARSE "$TMP/portC"
hdiutil attach -quiet "$TMP/hubC.sparseimage"; hdiutil attach -quiet "$TMP/portC.sparseimage"
INFO=$(diskutil info -plist /Volumes/SGCifPort)
# Freno: que lo que se cifra sea la imagen de ensayo (y no otra cosa).
[ "$(plutil -extract VolumeName raw - <<< "$INFO")" = "SGCifPort" ] && [ "$(plutil -extract BusProtocol raw - <<< "$INFO")" = "Disk Image" ] \
  || { echo "✗ lo montado no es la imagen de ensayo"; exit 1; }
UC=$(plutil -extract VolumeUUID raw - <<< "$INFO"); DEV=$(plutil -extract DeviceIdentifier raw - <<< "$INFO")
UHC=$(uuid /Volumes/SGCifHub)
CLAVE="ensayo-$(uuidgen)"
echo "un archivo" > /Volumes/SGCifPort/hola.txt
print -rn -- "$CLAVE" | diskutil apfs encryptVolume "$DEV" -user disk -stdinpassphrase >/dev/null 2>&1 || { mal "No se pudo cifrar la imagen de ensayo"; exit 1; }
# La app corre con un hogar falso, sin llavero: la clave le llega por RELEVO_PRUEBA_CLAVE (solo en modo prueba).
# Que la lea bien del llavero real lo prueba herramientas/prueba-cifrado.sh.
export RELEVO_PRUEBA_CLAVE="$CLAVE"
hdiutil detach -quiet /Volumes/SGCifPort || hdiutil detach -quiet -force /Volumes/SGCifPort
# Con "ocultar en casa" prendido, como viene de fábrica: así se encontró el error del 25/10/2026 (al ocultarlo, el
# portátil cifrado quedaba cerrado y parecía desconectado). Antes esta prueba lo tenía apagado y no lo veía.
ajustes "$UHC" SGCifHub "$UC" SGCifPort true
arrancar
sleep 3
# Se enchufa sin montar (cerrado): así macOS no pide la clave y la tiene que poner Relevo.
hdiutil attach -quiet -nomount "$TMP/portC.sparseimage"
[ -z "$(montado_en "$UC")" ] && ok "El portátil cifrado llega cerrado" || mal "El portátil se montó solo, sin Relevo"
esperar 30 '[ -n "$(montado_en "$UC")" ]' && ok "Relevo lo abrió solo con su clave ($(montado_en "$UC"))" || mal "Relevo no lo abrió"
[ "$(cat "$(montado_en "$UC")/hola.txt" 2>/dev/null)" = "un archivo" ] && ok "Los datos se leen bien" || mal "No se leen los datos"
oculto "$(montado_en "$UC")" && ok "En casa entra directamente oculto" || mal "No quedó oculto"
esperar 15 'grep -q "ESTADO primeraVez\|ESTADO alDia\|ESTADO necesitaOK" "$LOG"' && ok "La app lo toma como portátil conectado" || mal "La app no lo tomó ($(grep ESTADO "$LOG" | tail -1))"
# Como cuando ponés la clave en la ventana de macOS: se cierra y se abre visible. Relevo lo oculta sin que se vuelva a cerrar.
diskutil unmount "$UC" >/dev/null 2>&1
esperar 10 '[ -z "$(montado_en "$UC")" ]'
print -rn -- "$CLAVE" | diskutil apfs unlockVolume "$UC" -stdinpassphrase >/dev/null 2>&1
esperar 10 '[ -n "$(montado_en "$UC")" ]' || mal "No se pudo abrir a mano la imagen de ensayo"
esperar 30 'oculto "$(montado_en "$UC")"' && ok "Abierto a mano y visible: Relevo lo oculta" \
  || mal "Abierto a mano no quedó oculto (montado en '$(montado_en "$UC")')"
sleep 5
[ -n "$(montado_en "$UC")" ] && [ "$(cat "$(montado_en "$UC")/hola.txt" 2>/dev/null)" = "un archivo" ] \
  && ok "Oculto sigue abierto y con los datos (no quedó cerrado)" || mal "Al ocultarlo quedó cerrado o sin montar"
parar
grep -q "falta traducir" "$LOG" && mal "Faltan traducciones: $(grep 'falta traducir' "$LOG" | head -3)"

echo
if [ $FALLAS = 0 ]; then echo "Todo bien"; else echo "$FALLAS falla(s). Registro de la app:"; tail -30 "$LOG"; fi
exit $FALLAS
