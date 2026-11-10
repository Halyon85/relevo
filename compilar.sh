#!/bin/zsh
# Compila Relevo, arma Relevo.app y la firma con un certificado de Apple (así los permisos no se pierden).
# Sin RELEVO_FIRMA usa el Developer ID si está (la misma firma que las versiones publicadas: macOS no pide los permisos
# de nuevo al actualizar) y, si no, "Apple Development" (lleva tu correo: solo para probar en tus Macs).
# Uso: ./compilar.sh            → deja la app en build/Relevo.app
#      ./compilar.sh instalar   → además la copia a /Applications y la abre
# Para publicar una versión, `herramientas/publicar-version.sh` la llama con RELEVO_INFO (un Info.plist con la versión,
# la lista de versiones y la clave de Sparkle) y RELEVO_FIRMA (con qué firmar; "-" es la firma local).
set -euo pipefail
cd "$(dirname "$0")"

# -Osize: binario más chico (va acá y no en Package.swift, así el paquete se puede usar como dependencia).
swift build -c release --arch arm64 --product Relevo -Xswiftc -Osize
CARPETA_BIN="$(swift build -c release --arch arm64 --product Relevo -Xswiftc -Osize --show-bin-path)"
BIN="$CARPETA_BIN/Relevo"
APP="build/Relevo.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Relevo"
cp "${RELEVO_INFO:-Recursos/Info.plist}" "$APP/Contents/Info.plist"
# Sparkle (actualizaciones): va en Frameworks y el ejecutable la busca ahí. Relevo no usa la caja de arena de macOS,
# así que los servicios XPC de Sparkle no hacen falta (son para apps en caja de arena) y se sacan.
ditto "$CARPETA_BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Relevo"
[[ -f Recursos/AppIcon.icns ]] && cp Recursos/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
strip -x "$APP/Contents/MacOS/Relevo" 2>/dev/null || true

CERTIFICADOS=$(security find-identity -v -p codesigning)
DEVELOPER_ID=$(awk -F'"' '/Developer ID Application/ {print $2; exit}' <<< "$CERTIFICADOS")
DESARROLLO=$(awk -F'"' '/Apple Development/ {print $2; exit}' <<< "$CERTIFICADOS")
IDENTIDAD=${RELEVO_FIRMA-${DEVELOPER_ID:-$DESARROLLO}}
IDENTIDAD=${IDENTIDAD:--}
# El sello de hora de Apple solo hace falta con Developer ID (la notarización lo exige; necesita internet).
SELLO=--timestamp=none
[[ "$IDENTIDAD" == *"Developer ID"* ]] && SELLO=--timestamp
# Primero lo de adentro de Sparkle (de adentro hacia afuera) y al final la app, todo con la misma firma.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for pieza in "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
  codesign --force --options runtime "$SELLO" --sign "$IDENTIDAD" "$pieza"
done
# Con la firma local macOS solo deja cargar bibliotecas del mismo equipo de Apple, y la firma local no tiene equipo:
# sin este permiso, Relevo no arranca porque no puede abrir Sparkle. Con un certificado de Apple no hace falta.
PERMISOS=Recursos/Relevo.entitlements
if [[ "$IDENTIDAD" == "-" ]]; then
  PERMISOS=build/Relevo-firma-local.entitlements
  cp Recursos/Relevo.entitlements "$PERMISOS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$PERMISOS"
fi
codesign --force --options runtime "$SELLO" \
  --entitlements "$PERMISOS" \
  --sign "$IDENTIDAD" "$APP"
[[ "$IDENTIDAD" == "-" ]] && echo "Firmada con: firma local (ad-hoc)" || echo "Firmada con: $IDENTIDAD"
du -sh "$APP"

# Que macOS no tome esta copia como "la" app (por ejemplo, al iniciar sesión): la de todos los días es la de
# Aplicaciones. Si igual la abre, Relevo se pasa solo a la instalada (`Instalada.abrirEnSuLugar`).
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
touch build/.metadata_never_index
"$LSREGISTER" -u "$PWD/$APP" 2>/dev/null || true

if [[ "${1:-}" == "instalar" ]]; then
  osascript -e 'tell application id "team.halyon.relevo" to quit' 2>/dev/null || true
  sleep 1
  rm -rf /Applications/Relevo.app
  cp -R "$APP" /Applications/Relevo.app
  "$LSREGISTER" -f /Applications/Relevo.app 2>/dev/null || true
  open /Applications/Relevo.app
  echo "Instalada en /Applications/Relevo.app"
fi
