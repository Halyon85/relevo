# Releases and updates / Publicar versiones

Relevo updates itself with [Sparkle](https://sparkle-project.org), but **only builds published with `herramientas/publicar-version.sh`** look for updates. A copy you build yourself with `compilar.sh` never does (an update would replace your build with someone else's): update it with `git pull && ./compilar.sh instalar`.

## How it works

- A published build carries two things in its `Info.plist`: the address of the version list (`SUFeedURL`, the *appcast*) and the public half of a signing key (`SUPublicEDKey`).
- Once a day it reads the list. If there's a newer version, it asks before installing it.
- Every `.zip` is signed with the private half of the key, which never leaves the publisher's Keychain. Relevo refuses any update that isn't signed with it, even if someone takes over the GitHub account or the download.

## Signing without a paid Apple account

You don't need the Apple Developer Program (99 USD a year) to publish, but it changes how the app opens the first time:

| | Without it (local, ad-hoc signature) | With Developer ID + notarization |
|---|---|---|
| First open of the downloaded `.zip` | macOS blocks it: **System Settings → Privacy & Security → Open Anyway** | Opens normally |
| Updates through Sparkle | Install normally, checked with the Sparkle key | Install normally |
| Permissions after an update | macOS may ask again for access to removable volumes | Kept |

`publicar-version.sh` uses a “Developer ID Application” certificate if it finds one, and the local signature otherwise. It never uses “Apple Development”: that one is for testing on your own Macs, not for handing out. With Developer ID it also sends the app to Apple (notarization), waits for the approval and staples it before making the `.zip`. That needs, once, an app-specific password from [account.apple.com](https://account.apple.com) stored in the Keychain: `xcrun notarytool store-credentials dixity --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID` (the same Apple account as Dixity and Alero, so one profile serves all three; `RELEVO_NOTARIO=<name>` uses another one).

## The first time

1. **Create the key.** It's saved in your login Keychain and prints the public key:

   ```bash
   swift package resolve
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account team.halyon.relevo
   ```

2. **Make a backup of the private key** and keep it somewhere safe, outside the repository (a password manager, an encrypted drive). Without it you can't publish updates for the copies already installed:

   ```bash
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account team.halyon.relevo -x relevo-clave-privada.txt
   ```

   Once saved, delete that file from the disk.

3. **If you publish your own copy of Relevo**, put your public key and your addresses in the first lines of `herramientas/publicar-version.sh`.

## Each version

1. Commit everything (the script refuses uncommitted changes).
2. Optional: write what's new in `docs/novedades/<version>.html`, a piece of HTML without `<html>` or `<body>` (for example `<ul><li>…</li></ul>`).
3. Build it:

   ```bash
   herramientas/publicar-version.sh 0.2.0
   ```

4. Create the release on GitHub with what it built: the `.zip` and `appcast.xml` go together as files of the release (the script prints the exact `gh release create` command). The app reads the list at `releases/latest/download/appcast.xml`, which always points to the newest release, so no other server is needed.
5. Release notes on GitHub: the same notes, plus how to open it the first time (see the table above) while the app isn't signed with Developer ID.

Each version is built in its own folder, `build/publicar/<version>/`, and its list has only that version: it's enough to update from any older one.

---

## En español

Relevo se actualiza sola con [Sparkle](https://sparkle-project.org), pero **solo las versiones armadas con `herramientas/publicar-version.sh`** buscan actualizaciones. La que compila cada uno con `compilar.sh` no busca nunca, porque una actualización le cambiaría su app por la de otro. Se actualiza con `git pull && ./compilar.sh instalar`.

### Cómo funciona

- Una versión publicada lleva en su `Info.plist` la dirección de la lista de versiones (`SUFeedURL`, el *appcast*) y la mitad pública de una clave (`SUPublicEDKey`).
- Una vez por día mira la lista. Si hay una versión nueva, pregunta antes de instalarla.
- Cada `.zip` va firmado con la mitad privada de la clave, que nunca sale del Llavero de quien publica. Relevo rechaza cualquier actualización que no esté firmada con ella, aunque alguien tome la cuenta de GitHub o la descarga.

### Firmar sin la cuenta paga de Apple

Sin el Apple Developer Program (99 USD por año) se puede publicar igual, con estas diferencias:

- **La primera vez**, macOS bloquea la app bajada: hay que ir a **Ajustes del Sistema → Privacidad y seguridad → Abrir igual**.
- **Las actualizaciones** se instalan normal.
- **Después de cada actualización**, macOS puede volver a pedir el permiso de los discos externos.

Con Developer ID y la notarización de Apple, la app abre normal desde el principio y los permisos no se pierden.

`publicar-version.sh` firma con un certificado «Developer ID Application» si lo encuentra y, si no, con la firma local. Nunca usa «Apple Development»: ese es para probar en tus Macs, no para repartir. Con Developer ID además manda la app a Apple (notarización), espera la aprobación y le pega el sello antes de armar el `.zip`. Para eso hace falta, una vez, una contraseña de app de [account.apple.com](https://account.apple.com) guardada en el Llavero: `xcrun notarytool store-credentials dixity --apple-id TU_APPLE_ID --team-id TU_EQUIPO` (la misma cuenta de Apple que Dixity y Alero, así que un perfil sirve para las tres; `RELEVO_NOTARIO=<nombre>` usa otro).

### La primera vez

1. **Crear la clave** (queda en tu Llavero):

   ```bash
   swift package resolve
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account team.halyon.relevo
   ```

2. **Guardar una copia de la clave privada** fuera del repositorio (gestor de contraseñas, disco cifrado). Sin ella no se pueden publicar actualizaciones para las copias ya instaladas:

   ```bash
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account team.halyon.relevo -x relevo-clave-privada.txt
   ```

   Después de guardarla, borrá ese archivo del disco.

3. **Si publicás tu propia copia de Relevo**, poné tu clave pública y tus direcciones en las primeras líneas de `herramientas/publicar-version.sh`.

### Cada versión

1. Hacé commit de todo (el script no arranca con cambios sin guardar).
2. Si querés, escribí las novedades en `docs/novedades/<versión>.html` (HTML sin `<html>` ni `<body>`).
3. Corré el script:

   ```bash
   herramientas/publicar-version.sh 0.2.0
   ```

4. Creá la versión en GitHub con lo que armó: el `.zip` y `appcast.xml` van juntos como archivos de la versión (el script te da el comando `gh release create` exacto). La app lee la lista en `releases/latest/download/appcast.xml`, que siempre apunta a la última versión, así que no hace falta otro servidor.
5. En las notas de GitHub: las novedades y, mientras no esté firmada con Developer ID, cómo abrirla la primera vez.

Cada versión se arma en su carpeta, `build/publicar/<versión>/`, y su lista lleva solo esa versión: alcanza para actualizar desde cualquiera anterior.
