# Ayudas para las pruebas que usan imágenes de disco de ensayo. Se cargan con `source herramientas/imagenes.sh`.
# Lo usan los `trap` de limpieza de prueba-app, prueba-discos, prueba-inteligente, prueba-cifrado, prueba-desenchufar
# y capturas-demo: antes se desconectaba por el lugar de montaje (/Volumes/<nombre>), y una imagen que Relevo había
# desmontado sin expulsar (o que se adjuntó con -nomount) quedaba adjunta para siempre en Utilidad de Discos.
# Acá se busca por el archivo de la imagen, así sale montada o no. Solo mira lo que lista `hdiutil info`
# (imágenes de disco): un disco real nunca aparece ahí.

# Los discos (/dev/diskN, el disco entero de cada imagen) de las imágenes cuyo archivo empieza con $1
# (las pruebas pasan su carpeta temporal con la barra final: "$TMP/").
imagenes_de() {
  [ -n "${1:-}" ] || return 0
  hdiutil info | awk -v c="$1" '
    /^image-path/ { sub(/^image-path[ \t]*:[ \t]*/, ""); p = (index($0, c) == 1); next }
    p && /^\/dev\/disk[0-9]+[ \t]/ { print $1; p = 0 }'
}

# Desconecta todas las imágenes que empiezan con $1 (reintenta: recién cerrada la app, macOS puede tardar en soltarla).
soltar_imagenes() {
  local carpeta="${1:-}" d vuelta
  [ -n "$carpeta" ] || return 0
  for vuelta in 1 2 3; do
    for d in $(imagenes_de "$carpeta"); do hdiutil detach -quiet -force "$d" 2>/dev/null; done
    [ -z "$(imagenes_de "$carpeta")" ] && return 0
    sleep 1
  done
  return 1
}

# Para el final de cada prueba: que no haya quedado ninguna imagen que empiece con $1 adjunta.
revisar_sin_imagenes() {
  local quedan
  quedan=$(imagenes_de "$1" | wc -l | tr -d ' ')
  if [ "$quedan" = 0 ]; then echo "✓ Sin imágenes de ensayo colgadas"; else echo "✗ Quedaron $quedan imágenes de ensayo adjuntas"; return 1; fi
}
