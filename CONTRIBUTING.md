# Contributing / Colaborar

Thanks for wanting to help. Issues and pull requests are welcome in **English or Spanish**. The code, its comments and the commit messages are in Spanish (Argentina); new code should follow the same style.

## Before you send a change

1. Build and run the engine tests (no Xcode needed, they use temporary folders and never touch real drives):

   ```bash
   swift run RelevoPruebas
   ```

2. If you touched drives, encryption or the app itself, also run the matching script in `herramientas/` (they work on disk images, see the README).
3. A fix comes with a test that failed before it. Relevo moves and deletes files: a change that "seems right" is not enough.
4. One topic per pull request, with a short description of what changes for the person using the app.

## Ground rules of the engine

- Nothing in the synced folders is ever deleted directly: whatever is removed or overwritten goes to Relevo's trash on that same drive.
- When in doubt (a folder that can't be read, a drive that left, a file that changed while copying), do nothing and try again later.
- Comments say what the code does, who calls it and why.

By contributing you agree that your contribution is licensed under the [Apache License 2.0](LICENSE).

---

## Colaborar

Gracias por querer ayudar. Los issues y pull requests pueden ser en **español o en inglés**. El código, los comentarios y los commits están en español rioplatense; lo nuevo tiene que seguir el mismo estilo.

Antes de mandar un cambio: corré `swift run RelevoPruebas` (y el script de `herramientas/` que corresponda si tocaste discos, cifrado o la app), sumá una prueba que fallaba antes del arreglo y mandá un tema por pull request. Las reglas del motor son las de arriba: nada de las carpetas sincronizadas se borra directo (todo va a la papelera de Relevo), ante la duda no se hace nada y se reintenta, y los comentarios dicen qué hace el código, quién lo llama y por qué.

Al colaborar aceptás que tu aporte queda bajo la [licencia Apache 2.0](LICENSE).
