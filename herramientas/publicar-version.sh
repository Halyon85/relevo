#!/bin/zsh
# Arma una versión publicada de Relevo: la app con la búsqueda de actualizaciones prendida, el .zip firmado con la
# clave de Sparkle y la lista de versiones (appcast.xml). NO sube nada: al final dice cómo crear la versión en GitHub,
# que guarda el .zip y la lista.
# Uso: herramientas/publicar-version.sh 0.2.0
# Paso a paso y qué hacer la primera vez: docs/PUBLICAR.md.
set -euo pipefail
cd "$(dirname "$0")/.."

# Dónde viven las versiones publicadas: en las versiones (Releases) de GitHub. Cada una lleva su .zip y la lista
# (appcast.xml); "latest/download" siempre apunta a la de la última, así la app la encuentra sin otro servidor.
# Si publicás tu propia copia de Relevo, cambiá estas líneas (y generá tu clave: ver docs/PUBLICAR.md).
REPO="Halyon85/relevo"
LISTA="https://github.com/$REPO/releases/latest/download/appcast.xml"   # la lista de versiones que mira la app
CLAVE_PUBLICA="eg5eD1efM+l3Pg6O3UJOv89z2yr6AFuTGRPNtL7YC+0="   # la pública: puede estar a la vista
CUENTA="team.halyon.relevo"                            # el nombre de la clave privada en el Llavero

VERSION=${1:?"Uso: herramientas/publicar-version.sh <versión, por ejemplo 0.2.0>"}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "La versión tiene que ser como 0.2.0"; exit 1; }
# Lo que se publica tiene que ser exactamente lo que está guardado en git (así se puede saber qué código lleva).
[[ -z "$(git status --porcelain)" ]] || { echo "Hay cambios sin commit: guardalos antes de publicar."; exit 1; }

# Sparkle compara el número de compilación (CFBundleVersion), que tiene que crecer siempre: sale de la versión
# (0.2.0 → 200, 1.4.12 → 10412), así no depende del historial de git (la copia pública arranca sin historial).
IFS=. read -r MAYOR MENOR ARREGLO <<< "$VERSION"
NUMERO=$(( MAYOR * 10000 + MENOR * 100 + ARREGLO ))

# Cada versión en su carpeta, sola: la lista lleva solo la última (alcanza para actualizar desde cualquiera anterior).
SALIDA=build/publicar/$VERSION
[[ -e "$SALIDA" ]] && { echo "Ya existe $SALIDA: esa versión ya se armó. Usá otro número."; exit 1; }
mkdir -p "$SALIDA"
ZIP="$SALIDA/Relevo-$VERSION.zip"
DESCARGAS="https://github.com/$REPO/releases/download/v$VERSION/"

# El Info.plist de la versión publicada: el de siempre más la versión, la lista y la clave. Busca sola una vez por
# día y pregunta antes de instalar.
INFO=build/Info-publicada.plist
cp Recursos/Info.plist "$INFO"
PB=/usr/libexec/PlistBuddy
$PB -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $NUMERO" "$INFO"
$PB -c "Add :SUFeedURL string $LISTA" -c "Add :SUPublicEDKey string $CLAVE_PUBLICA" \
    -c "Add :SUEnableAutomaticChecks bool true" -c "Add :SUScheduledCheckInterval integer 86400" "$INFO"

# Firma: con Developer ID si lo tenés (la cuenta paga de Apple); si no, la firma local. Nunca con el certificado
# "Apple Development": ese es para probar en tus Macs, no para repartir.
FIRMA=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
RELEVO_INFO="$INFO" RELEVO_FIRMA="${FIRMA:--}" ./compilar.sh

# El .zip (ditto conserva los enlaces y permisos de adentro de la app, cosa que zip no siempre hace).
ditto -c -k --sequesterRsrc --keepParent build/Relevo.app "$ZIP"

# Las novedades, si las escribiste: docs/novedades/<versión>.html (un pedazo de HTML, sin <html> ni <body>).
NOTAS=docs/novedades/$VERSION.html
[[ -f "$NOTAS" ]] && cp "$NOTAS" "$SALIDA/Relevo-$VERSION.html"

# Firma el .zip con la clave privada del Llavero y arma la lista.
HERRAMIENTAS=.build/artifacts/sparkle/Sparkle/bin
"$HERRAMIENTAS/generate_appcast" --account "$CUENTA" --download-url-prefix "$DESCARGAS" \
  --link "https://relevo.halyon.app" --maximum-deltas 0 -o "$SALIDA/appcast.xml" "$SALIDA"

echo
echo "Listo: Relevo $VERSION (compilación $NUMERO), firmada con ${FIRMA:-la firma local}, en $SALIDA."
echo "Para publicarla, desde la copia pública (el .zip y la lista van juntos en la versión de GitHub):"
echo "  gh release create v$VERSION --repo $REPO --title \"Relevo $VERSION\" --notes-file <notas.md> \\"
echo "    \"$PWD/$ZIP\" \"$PWD/$SALIDA/appcast.xml\""
