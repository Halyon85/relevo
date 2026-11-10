#!/bin/zsh
# Prueba de carpetas elegidas una adentro de otra, con discos de ensayo (nunca con discos reales): "Proyectos/*" y
# también "Proyectos/Apps/*". La carpeta Apps no puede ir como un proyecto más: tendría su propia memoria de lo
# copiado, además de la de cada proyecto de adentro, y un cambio que una copiaba antes que la otra aparecía como
# conflicto (pasó el 31/10/2026 con Relevo editándose a sí mismo).
# Uso: herramientas/prueba-anidadas.sh
set -uo pipefail
cd "$(dirname "$0")/.."
source herramientas/imagenes.sh   # soltar_imagenes / revisar_sin_imagenes (limpieza de imágenes de ensayo)
swift build -c release --product Relevo >/dev/null 2>&1 || { echo "no compila"; exit 1; }
BIN="$(swift build -c release --product Relevo --show-bin-path)/Relevo"
TMP=$(mktemp -d /private/tmp/relevo-anid.XXXX)
CASA="$TMP/casa"; mkdir -p "$CASA/Library/Application Support/Relevo"
LOG="$TMP/app.log"; PID=""
limpiar() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
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
vuelta() {
  : > "$LOG"; orden sincronizar
  esperar 60 'grep -q "^REVISA" "$LOG"'
  REVISA=$(grep "^REVISA" "$LOG" | tail -1)
  esperar 60 'grep -q "ESTADO revisando\|ESTADO copiando" "$LOG" || [[ "$REVISA" == "REVISA 0:"* ]]'
  esperar 60 '[ "$(grep ESTADO "$LOG" | tail -1)" = "ESTADO alDia" ] || [[ "$REVISA" == "REVISA 0:"* ]]'
  sleep 1
}
ajustes() {
  cat > "$CASA/Library/Application Support/Relevo/ajustes.json" <<JSON
{"idioma":"es","automatico":false,"enVivo":${2:-false},"vinculos":[{"id":"anid","hub":{"uuid":"$UH","nombre":"SGAnHub","subcarpeta":""},
 "portatil":{"uuid":"$UP","nombre":"SGAnPort","subcarpeta":""},"carpetas":$1,"ocultarEnCasa":false}]}
JSON
}
conflictos() { find $H $P -name "*(conflicto *" 2>/dev/null; }

hdiutil create -quiet -size 2g -fs APFS -volname SGAnHub -type SPARSE "$TMP/h"
hdiutil create -quiet -size 2g -fs APFS -volname SGAnPort -type SPARSE "$TMP/p"
hdiutil attach -quiet "$TMP/h.sparseimage"; hdiutil attach -quiet "$TMP/p.sparseimage"
H=/Volumes/SGAnHub; P=/Volumes/SGAnPort
UH=$(diskutil info $H | awk -F': *' '/Volume UUID/ {print $2}'); UP=$(diskutil info $P | awk -F': *' '/Volume UUID/ {print $2}')
mkdir -p $H/Proyectos/Web $H/Proyectos/Apps/Relevo/Sources $H/Proyectos/Apps/Pipo
echo uno > $H/Proyectos/Web/index.html
echo v1 > $H/Proyectos/Apps/Relevo/Sources/Expulsar.swift
echo pipo > $H/Proyectos/Apps/Pipo/LEEME.md
echo mapa > $H/Proyectos/Apps/AGENTS.md

# Primero solo los proyectos de Apps, como cuando se ordenaron las carpetas.
ajustes '["Proyectos/Apps/*"]'
arrancar
vuelta
[ "$(cat $P/Proyectos/Apps/Relevo/Sources/Expulsar.swift 2>/dev/null)" = v1 ] && ok "Copió los proyectos de Apps" || mal "No copió Apps"
parar

# Un cambio en casa que todavía no viajó, y después se suma "Proyectos/*" (Apps queda adentro de las dos).
echo v2 > $H/Proyectos/Apps/Relevo/Sources/Expulsar.swift; sleep 1
ajustes '["Proyectos/*", "Proyectos/.", "Proyectos/Apps/*"]'
arrancar
vuelta
[ -z "$(conflictos)" ] && ok "Sin conflictos falsos" || mal "Conflicto falso: $(conflictos | tr '\n' ' ')"
[ "$(cat $P/Proyectos/Apps/Relevo/Sources/Expulsar.swift)" = v2 ] && ok "Llevó el cambio al portátil" || mal "No llevó el cambio"
grep -q "^ANALISIS Proyectos/Apps " "$LOG" && mal "Revisó Apps como un proyecto más: $(grep '^ANALISIS Proyectos/Apps ' "$LOG")" \
  || ok "Apps no va como un proyecto más"
[ "$(cat $P/Proyectos/Apps/AGENTS.md 2>/dev/null)" = mapa ] && ok "Los archivos sueltos de Apps también viajan" || mal "No copió Apps/AGENTS.md"
[ "$(cat $P/Proyectos/Web/index.html 2>/dev/null)" = uno ] && ok "Copió el resto de Proyectos" || mal "No copió Proyectos/Web"

# Cambios de los dos lados, en lugares distintos: cada uno viaja, sin conflictos.
echo v3 > $H/Proyectos/Apps/Relevo/Sources/Expulsar.swift
echo afuera > $P/Proyectos/Apps/Pipo/LEEME.md
echo mapa2 > $P/Proyectos/Apps/AGENTS.md; sleep 1
vuelta
[ "$(cat $P/Proyectos/Apps/Relevo/Sources/Expulsar.swift)" = v3 ] && [ "$(cat $H/Proyectos/Apps/Pipo/LEEME.md)" = afuera ] \
  && [ "$(cat $H/Proyectos/Apps/AGENTS.md)" = mapa2 ] && ok "Cambios de los dos lados, cada uno a su lugar" || mal "Los cambios de los dos lados no viajaron bien"
[ -z "$(conflictos)" ] && ok "Sigue sin conflictos" || mal "Conflicto: $(conflictos | tr '\n' ' ')"
parar

# Con la copia en vivo (como se usa todos los días): editar adentro de un proyecto de Apps y un archivo suelto de Apps.
ajustes '["Proyectos/*", "Proyectos/.", "Proyectos/Apps/*"]' true
arrancar
echo v4 > $H/Proyectos/Apps/Relevo/Sources/Expulsar.swift
echo mapa3 > $H/Proyectos/Apps/AGENTS.md
esperar 30 '[ "$(cat $P/Proyectos/Apps/Relevo/Sources/Expulsar.swift)" = v4 ] && [ "$(cat $P/Proyectos/Apps/AGENTS.md)" = mapa3 ]' \
  && ok "En vivo: llevó los dos cambios" || mal "En vivo no llevó los cambios"
sleep 2
[ -z "$(conflictos)" ] && ok "En vivo, sin conflictos" || mal "En vivo, conflicto: $(conflictos | tr '\n' ' ')"
grep -q "^ANALISIS Proyectos/Apps " "$LOG" && mal "En vivo revisó Apps como un proyecto más" || ok "En vivo, Apps tampoco va como un proyecto más"
parar

# Un conflicto de verdad (lo mismo cambiado distinto de los dos lados) y, después, la otra versión borrada a mano:
# el aviso de "Dos versiones" se tiene que ir solo (antes quedaba para siempre).
abiertos() { python3 -I -c "import json,sys; h=json.load(open(sys.argv[1])); print(sum(len([c for c in m.get('conflictos',[]) if c not in (m.get('resueltos') or [])]) for m in h))" "$CASA/Library/Application Support/Relevo/historial.json" 2>/dev/null || echo 0; }
ajustes '["Proyectos/*", "Proyectos/.", "Proyectos/Apps/*"]'
arrancar
echo casa > $H/Proyectos/Web/index.html; sleep 1; echo afuera > $P/Proyectos/Web/index.html; sleep 1
vuelta; sleep 1
[ "$(abiertos)" = 1 ] && ok "Un conflicto de verdad queda para elegir" || mal "Conflictos abiertos: $(abiertos)"
find $H $P -name "index (conflicto *" -delete; sleep 1
vuelta; sleep 1
[ "$(abiertos)" = 0 ] && ok "Borrada la otra versión, el aviso se va solo" || mal "Sigue el aviso de dos versiones: $(abiertos)"
parar

echo
[ $FALLAS -eq 0 ] && echo "Todo bien" || echo "$FALLAS con problemas"
