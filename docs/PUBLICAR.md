# Releases and updates / Publicar versiones

Relevo updates itself with [Sparkle](https://sparkle-project.org), but **only builds published with `herramientas/publicar-version.sh`** look for updates. A copy you build yourself with `compilar.sh` never does (an update would replace your build with someone else's): update it with `git pull && ./compilar.sh instalar`.

## How it works

- A published build carries two things in its `Info.plist`: the address of the version list (`SUFeedURL`, the *appcast*) and the public half of a signing key (`SUPublicEDKey`).
- Once a day it reads the list. If there's a newer version, it asks before installing it.
- Every `.zip` is signed with the private half of the key, which never leaves the publisher's Keychain. Relevo refuses any update that isn't signed with it, even if someone takes over the website.

## Signing without a paid Apple account

You don't need the Apple Developer Program (99 USD a year) to publish, but it changes how the app opens the first time:

| | Without it (local, ad-hoc signature) | With Developer ID + notarization |
|---|---|---|
| First open of the downloaded `.zip` | macOS blocks it: **System Settings → Privacy & Security → Open Anyway** | Opens normally |
| Updates through Sparkle | Install normally, checked with the Sparkle key | Install normally |
| Permissions after an update | macOS may ask again for access to removable volumes | Kept |

`publicar-version.sh` uses a “Developer ID Application” certificate if it finds one, and the local signature otherwise. It never uses “Apple Development”: that one is for testing on your own Macs, not for handing out.

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

4. Upload what it prints, in this order:
   1. The `.zip` (and the notes, if you wrote them) to the downloads folder.
   2. **Last**, `appcast.xml` to its address.
5. Create the release on GitHub (Releases) with the tag `v0.2.0` and the same `.zip`.

`build/publicar/` keeps every version you've built: don't delete it. The list is generated from what's there.

---

## En español

Relevo se actualiza sola con [Sparkle](https://sparkle-project.org), pero **solo las versiones armadas con `herramientas/publicar-version.sh`** buscan actualizaciones. La que compila cada uno con `compilar.sh` no busca nunca, porque una actualización le cambiaría su app por la de otro. Se actualiza con `git pull && ./compilar.sh instalar`.

### Cómo funciona

- Una versión publicada lleva en su `Info.plist` la dirección de la lista de versiones (`SUFeedURL`, el *appcast*) y la mitad pública de una clave (`SUPublicEDKey`).
- Una vez por día mira la lista. Si hay una versión nueva, pregunta antes de instalarla.
- Cada `.zip` va firmado con la mitad privada de la clave, que nunca sale del Llavero de quien publica. Relevo rechaza cualquier actualización que no esté firmada con ella, aunque alguien tome el sitio.

### Firmar sin la cuenta paga de Apple

Sin el Apple Developer Program (99 USD por año) se puede publicar igual, con estas diferencias:

- **La primera vez**, macOS bloquea la app bajada: hay que ir a **Ajustes del Sistema → Privacidad y seguridad → Abrir igual**.
- **Las actualizaciones** se instalan normal.
- **Después de cada actualización**, macOS puede volver a pedir el permiso de los discos externos.

Con Developer ID y la notarización de Apple, la app abre normal desde el principio y los permisos no se pierden.

`publicar-version.sh` firma con un certificado «Developer ID Application» si lo encuentra y, si no, con la firma local. Nunca usa «Apple Development»: ese es para probar en tus Macs, no para repartir.

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

4. Subí lo que te indica, en este orden:
   1. El `.zip` (y las novedades, si las escribiste) a la carpeta de descargas.
   2. **Al final**, `appcast.xml` a su dirección.
5. Creá la versión en GitHub (Releases) con la etiqueta `v0.2.0` y el mismo `.zip`.

`build/publicar/` guarda todas las versiones que armaste: no la borres. La lista se arma con lo que hay ahí.
