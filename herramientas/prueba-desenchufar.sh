#!/bin/zsh
# Prueba dura: dos discos de ensayo (imágenes de disco APFS) y se "desenchufa" el portátil a la fuerza en medio de
# la copia, varias veces y en momentos distintos. Al final los dos tienen que quedar idénticos.
# Uso: herramientas/prueba-desenchufar.sh [vueltas]   (no toca ningún disco real)
set -uo pipefail
cd "$(dirname "$0")/.."
source herramientas/imagenes.sh   # soltar_imagenes / revisar_sin_imagenes (limpieza de imágenes de ensayo)
VUELTAS=${1:-5}
TMP=$(mktemp -d /private/tmp/relevo-desenchufar.XXXX)
# Desde el principio (si no monta, igual se limpia) y por el archivo de la imagen, montada o no.
trap 'soltar_imagenes "$TMP/"; revisar_sin_imagenes "$TMP/"; rm -rf "$TMP"' EXIT
BIN="$(swift build -c release --product Relevo --show-bin-path)/Relevo"
swift build -c release --product Relevo >/dev/null 2>&1 || { echo "no compila"; exit 1; }

hdiutil create -quiet -size 20g -fs APFS -volname SGHub -type SPARSE "$TMP/hub" 
hdiutil create -quiet -size 20g -fs APFS -volname SGPort -type SPARSE "$TMP/port"
# Puntos de montaje fijos adentro de la carpeta temporal: así nunca se escribe fuera de los discos de ensayo.
HUB="$TMP/mnt-hub"; PORT="$TMP/mnt-port"
mkdir -p "$HUB" "$PORT"
hdiutil attach -quiet -nobrowse -mountpoint "$HUB" "$TMP/hub.sparseimage" 2>/dev/null || { echo "no montó el hub"; exit 1; }
montar_port() {
  mkdir -p "$PORT"
  hdiutil attach -quiet -nobrowse -mountpoint "$PORT" "$TMP/port.sparseimage" 2>/dev/null || { echo "no montó el portátil"; exit 1; }
}
montar_port
mount | grep -q " on $HUB " || { echo "el hub no quedó montado"; exit 1; }
echo "Hub: $HUB   Portátil: $PORT"

# Datos: 3000 archivos chicos en carpetas + 24 grandes de 40 MB.
mkdir -p "$HUB/Proyectos/Demo"
for d in $(seq 1 30); do mkdir -p "$HUB/Proyectos/Demo/src$d"; for f in $(seq 1 100); do head -c $((RANDOM * 3)) /dev/urandom > "$HUB/Proyectos/Demo/src$d/f$f.bin"; done; done
mkdir -p "$HUB/Proyectos/Demo/videos"
for g in $(seq 1 24); do head -c 41943040 /dev/urandom > "$HUB/Proyectos/Demo/videos/v$g.mov"; done
echo "Datos de prueba: $(du -sh "$HUB/Proyectos/Demo" | cut -f1)"

ESTADO="$TMP/estado"
for v in $(seq 1 $VUELTAS); do
  # Cada vuelta cambia algo de los dos lados para que haya trabajo en los dos sentidos.
  for g in $(seq 1 6); do head -c 41943040 /dev/urandom > "$HUB/Proyectos/Demo/videos/nuevo$v-$g.mov"; done
  mkdir -p "$HUB/Proyectos/Demo/lote$v" "$PORT/Proyectos/Demo/afuera$v"
  for f in $(seq 1 300); do head -c $((RANDOM)) /dev/urandom > "$HUB/Proyectos/Demo/lote$v/f$f"; head -c $((RANDOM)) /dev/urandom > "$PORT/Proyectos/Demo/afuera$v/f$f"; done
  for g in $(seq 1 4); do head -c 41943040 /dev/urandom > "$PORT/Proyectos/Demo/afuera$v/grande$g.bin"; done
  # Se borra algo viejo de cada lado, para probar la papelera cortada.
  rm -rf "$HUB/Proyectos/Demo/src$v" "$PORT/Proyectos/Demo/videos/v$v.mov"
  CORTE=$([ $((v % 2)) = 0 ] && echo "$HUB" || echo "$PORT")
  "$BIN" --sincronizar "$HUB" "$PORT" Proyectos/Demo --estado "$ESTADO" --si > "$TMP/salida$v.txt" 2>&1 &
  PID=$!
  ESPERA=$(( RANDOM % 25 + 5 ))
  sleep $(echo "scale=2; $ESPERA/100" | bc)
  hdiutil detach -force "$CORTE" >/dev/null 2>&1 && echo "vuelta $v: desenchufado el $([ "$CORTE" = "$HUB" ] && echo hub || echo portátil) a los 0.$ESPERA s"
  wait $PID; echo "   salida: $(grep -E 'Listo|desconect|No se pudo' "$TMP/salida$v.txt" | tr '\n' ' ')"
  if [ "$CORTE" = "$HUB" ]; then hdiutil attach -quiet -nobrowse -mountpoint "$HUB" "$TMP/hub.sparseimage"; else montar_port; fi
  # Se vuelve a enchufar y se sincroniza hasta terminar.
  "$BIN" --sincronizar "$HUB" "$PORT" Proyectos/Demo --estado "$ESTADO" --si > "$TMP/fin$v.txt" 2>&1
  echo "   al volver: $(grep -E 'Listo|reparar' "$TMP/fin$v.txt" | tr '\n' ' ')"
done

# Comparación final por contenido.
(cd "$HUB/Proyectos/Demo" && find . -type f ! -name '.*' -print0 | sort -z | xargs -0 shasum) > "$TMP/a.txt"
(cd "$PORT/Proyectos/Demo" && find . -type f ! -name '.*' -print0 | sort -z | xargs -0 shasum) > "$TMP/b.txt"
TEMPORALES=$(find "$HUB" "$PORT" -name '*.relevo-tmp' 2>/dev/null | wc -l | tr -d ' ')
CANT=$(wc -l < "$TMP/a.txt" | tr -d ' ')
if [ "$CANT" -gt 3000 ] && cmp -s "$TMP/a.txt" "$TMP/b.txt" && [ "$TEMPORALES" = "0" ]; then
  echo "RESULTADO: idénticos ($(wc -l < "$TMP/a.txt" | tr -d ' ') archivos), sin restos temporales ✓"
else
  echo "RESULTADO: DIFERENCIAS ✗ (temporales: $TEMPORALES)"; diff "$TMP/a.txt" "$TMP/b.txt" | head
  exit 1
fi
