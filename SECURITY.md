# Security / Seguridad

Relevo moves, replaces and deletes files, keeps the password of an encrypted portable drive in the macOS Keychain and opens `relevo://` links. A bug in any of those can cost someone their data, so security reports get priority.

## Reporting a vulnerability

**Please do not open a public issue.** Use GitHub's private reporting instead: the **Security** tab of this repository → **Report a vulnerability**. Include what you did, what happened and, if you can, a way to reproduce it with test drives or disk images (never send your real files).

We will confirm we received it within a few days, tell you what we plan to do and credit you in the fix if you want.

## What counts

- Anything that makes Relevo write, move or delete outside the folders you chose to sync (for example, through links or a crafted portable drive).
- Losing or overwriting data without it ending up in Relevo's trash or as a conflict copy.
- Reading the Keychain password, or a `relevo://` link that does something without asking.

Only the latest version is supported.

---

## Avisar un problema de seguridad

Relevo mueve, reemplaza y borra archivos, guarda en el Llavero la clave de un portátil cifrado y abre enlaces `relevo://`. Un error en cualquiera de esas partes le puede costar los datos a alguien, así que estos avisos tienen prioridad.

**No abras un issue público.** Usá el aviso privado de GitHub: pestaña **Security** de este repositorio → **Report a vulnerability**. Contá qué hiciste, qué pasó y, si podés, cómo repetirlo con discos o imágenes de prueba (nunca mandes tus archivos reales).

Te confirmamos que lo recibimos en unos días, te contamos qué vamos a hacer y, si querés, te nombramos en el arreglo. Solo se mantiene la última versión.
