# Manual de Relevo

Relevo mantiene iguales dos lugares: el **hub**, el disco (o la carpeta de tu Mac) donde trabajás en casa, y el **portátil**, el disco que te llevás. Mientras están los dos conectados, cada cambio pasa solo al otro lado. Afuera trabajás en el portátil como siempre y, al volver, Relevo trae lo que hiciste.

[Read in English](MANUAL.en.md) · [Volver al inicio](../LEEME.md)

**Índice**

1. [Antes de empezar](#1-antes-de-empezar)
2. [Primer uso](#2-primer-uso)
3. [El día a día](#3-el-día-a-día)
4. [El menú de la barra](#4-el-menú-de-la-barra)
5. [Las pantallas del panel](#5-las-pantallas-del-panel)
6. [Qué se copia y qué no](#6-qué-se-copia-y-qué-no)
7. [Nada se borra del todo](#7-nada-se-borra-del-todo)
8. [Cifrar el portátil](#8-cifrar-el-portátil)
9. [Atajos y enlaces](#9-atajos-y-enlaces)
10. [Qué hacer si…](#10-qué-hacer-si)
11. [Actualizar Relevo](#11-actualizar-relevo)

---

## 1. Antes de empezar

- **Una Mac con Apple Silicon y macOS 14 o más nuevo.**
- **Un disco portátil en formato APFS.** Si está en exFAT o FAT (formatos de Windows), Relevo te avisa: pasalo a APFS en la Utilidad de Discos. Ojo, eso lo borra: primero copiá lo que tenga.
- **Un respaldo.** Relevo está muy probada, pero mueve y reemplaza archivos. No le confíes tu única copia.

La primera vez que la abrís, macOS te pide dos permisos: **mandar avisos** y **acceder a discos externos**. Los dos hacen falta.

## 2. Primer uso

Al abrir Relevo por primera vez aparece el asistente, de tres pasos:

1. **¿Dónde trabajás?** Elegís el hub: un disco que queda en casa, esta Mac, o una carpeta de esta Mac (por ejemplo, tu carpeta de Proyectos).
2. **¿Qué disco te llevás?** Elegís el portátil. Si no aparece, enchufalo y tocá «Volver a buscar discos». Si querés usar el mismo disco para más de una cosa (por ejemplo, proyectos y fotos), tildá «Guardar en una carpeta del portátil» y poné un nombre.
3. **Casi listo.** Relevo te ofrece ponerle al portátil el nombre del hub para usarlo afuera (ver [Las mismas rutas en todos lados](#las-mismas-rutas-en-todos-lados)). Después elegís qué carpetas se sincronizan.

Con eso queda armado un **vínculo**: un par hub + portátil. Después tocás «Sincronizar ahora». La primera vez copia todo (puede tardar); después, solo lo que cambia.

## 3. El día a día

### En casa, con los dos discos

No tenés que hacer nada. Cada cambio se copia a los pocos segundos (la **copia en vivo**). La pantalla de Inicio dice «Todo al día» cuando los dos lados tienen lo mismo.

### Cuando te vas

Tenés dos formas:

- **Expulsar el portátil**, desde Relevo o desde el Finder. Como todo ya está copiado, alcanza.
- **«Me voy»**, en el menú o en Inicio. Copia lo último que quedó pendiente (segundos) y expulsa el portátil. Cuando dice «Listo: ya podés desenchufarlo», lo sacás.

Si algo está usando el disco, Relevo cierra solo lo que corre de fondo. Las apps con ventana te las muestra: tocás «Cerrar y expulsar» o las cerrás vos. Las sesiones de Claude abiertas en el disco se pueden volver a abrir desde la app después.

### Afuera

Trabajás en el portátil como siempre. Si le pusiste el nombre del hub, tus proyectos están en la misma ubicación y tus apps los encuentran sin cambiar nada. El menú dice «Trabajando desde el portátil».

### Cuando volvés

Enchufás el portátil. Relevo:

1. Le cambia el nombre al portátil para que no choque con el hub (no desmonta nada).
2. Trae lo que hiciste afuera, revisando solo lo que cambió.

**Mientras tanto, esperá antes de abrir tus apps.** Si tarda más de unos segundos te llega el aviso «Esperá antes de abrir tus apps», la pantalla de Inicio dice «Esperá un momento» y el ícono de la barra se mueve. Cuando termina te llega «Listo, ya podés abrir tus apps», con lo que trajo.

Si abriste una app en el disco antes de tiempo (por ejemplo, Claude) y quedó trabajando en el portátil, Relevo te avisa: «Cerrá Claude un momento». Cuando la cerrás, termina de acomodar los discos y te llega el «Listo» para que la vuelvas a abrir. Así nunca queda trabajando en el disco equivocado.

### Las mismas rutas en todos lados

- **Afuera**, el portátil se llama igual que el hub. Tus proyectos están en `/Volumes/<nombre del hub>/…`, como en casa.
- **En casa** se llama «<nombre> (portátil)», así nunca hay dos discos con el mismo nombre y da igual cuál monte primero la Mac al prender.
- En casa, Relevo puede **ocultar el portátil del Finder** para que veas uno solo (se elige en Discos). Lo abrís desde el menú de Relevo con «Mostrar el portátil en el Finder».

## 4. El menú de la barra

Al tocar el ícono de Relevo ves, por cada vínculo:

- **El estado:** «Todo al día», «Copiando 3 de 10…», «Revisando…», «Hace falta tu OK», «En pausa hasta las 18:00», etc.
- **Sincronizar ahora:** revisa lo que cambió y lo copia.
- **Me voy (copiar y expulsar).**
- **Mostrar el portátil en el Finder**, cuando está oculto.
- **Pausar:** por 1 hora, hasta mañana o hasta que la reanudes. «Reanudar» la vuelve a prender.

Abajo de todo:

- **Expulsar discos:** todos juntos o de a uno. Antes de expulsar un portátil, copia lo pendiente.
- **Abrir Relevo…**, **Historial** y **Salir de Relevo**.
- **Buscar actualizaciones…**, solo en las versiones publicadas por Halyon Team (ver [Actualizar Relevo](#11-actualizar-relevo)).

## 5. Las pantallas del panel

### Inicio

- **Arriba:** el estado de un vistazo, con los dos discos («Queda en casa» y «Va con vos»), cuánto lugar libre tienen y cuándo fue la última copia.
- **Botones:** «Sincronizar ahora», «Me voy» y «Frenar» (si está copiando).
- **Lo que espera tu OK** (ver [Borrar un proyecto entero](#borrar-un-proyecto-entero)).
- **Archivos con dos versiones**, si hubo conflictos.
- **Últimos movimientos**, con un link a todo el historial.
- **Avisos útiles:** por ejemplo, si llevás claves (`.env`) en un portátil sin cifrar, o si a un proyecto le faltan las dependencias en ese disco (te da los comandos para instalarlas).

### Qué se sincroniza

Tiene dos partes:

- **Carpetas que se sincronizan.** Tildás las carpetas que querés tener iguales en los dos discos. Van con todo lo de adentro, también lo oculto (`.env`, `.git`), y en la misma ubicación. Lo que no tildes queda solo en su disco. Podés entrar a una carpeta y elegir solo algunas de adentro. Cada una muestra cuánto ocupa y cuántos archivos tiene, y abajo ves si entra en el portátil.
- **Lo que nunca se sincroniza.** Las reglas de [Qué se copia y qué no](#6-qué-se-copia-y-qué-no): dependencias, compilados, lo que ignora git y lo que vos agregues con «Agregar carpeta o archivo…». Destildás una regla para que vuelva a sincronizarse, y «Volver a la lista sugerida» deja todo como al principio.

### Discos

- **Tus vínculos:** cada vínculo con su hub y su portátil, si están conectados y cuánto lugar libre tienen. Con «Agregar otro vínculo» sumás otro par (por ejemplo, fotos en otro disco), y con «Quitar vínculo» Relevo deja de sincronizar ese par: no borra nada de ningún disco.
- **El nombre afuera:** «Usar “<nombre>” afuera» le pone al portátil el nombre del hub.
- **En casa, ocultar el portátil del Finder.**
- **Cifrado del portátil** (ver [Cifrar el portátil](#8-cifrar-el-portátil)).
- **Revisión a fondo:** compara el contenido de cada archivo, no solo la fecha y el tamaño, para encontrar copias dañadas. Es lenta porque lee todo. Si encuentra diferencias, te ofrece copiarlos de nuevo desde el hub.
- **Expulsar discos:** todos los discos externos conectados, de cualquier vínculo.

### Historial

- **Movimientos:** qué se copió, para dónde y cuándo. Podés buscar un archivo o una carpeta. Desde cada movimiento podés **recuperar** algo borrado o **volver a la versión anterior** de un archivo reemplazado.
- **Dos versiones:** los conflictos pendientes (ver [El mismo archivo cambió en los dos lados](#el-mismo-archivo-cambió-en-los-dos-lados)).
- **Papeleras de Relevo:** abre la papelera de cada disco en el Finder.
- **Borrar historial:** limpia la lista. No toca ningún archivo.

### Repositorios

Para quien trabaja con git:

- **Clonar con un link** (GitHub, GitLab, Bitbucket…) o desde tu lista de GitHub, si tenés instalada la herramienta `gh` y la sesión iniciada. Elegís si queda **en el hub** (Relevo lo copia al portátil) o **directo en el portátil** (Relevo lo copia al hub). Si la carpeta ya existe, no se pisa. Relevo no guarda ninguna clave: usa tus credenciales de siempre.
- **Tus repositorios:** Relevo busca carpetas con git un nivel adentro de cada carpeta que se sincroniza y te muestra cuáles tienen cambios sin commit, commits sin subir o están atrasados.
- **Buscar novedades** pregunta a cada remoto si hay commits nuevos (`git fetch`); no cambia tus archivos. **Actualizar** trae los commits nuevos solo si no hay que mezclar nada (`git pull --ff-only`).
- **Detalles:** abrirlo en el Finder o la Terminal, ver los cambios, hacer commit, unir ramas u ocultarlo de la lista. Los ocultos se siguen copiando igual.

Si git no está instalado, Relevo te dice cómo instalarlo.

### General

- **Automático:**
  - Sincronizar sola al enchufar.
  - Copia en vivo.
  - Abrir al iniciar sesión.
- **Cuidados:**
  - **Revisión completa diaria**, de madrugada o cuando no usás la Mac. «Revisar todo ahora» la corre en el momento.
  - **Revisión a fondo una vez por mes**, con la Mac enchufada, los dos discos y sin usarla un rato. Solo avisa si encuentra algo.
  - **Antes de que la Mac se duerma**, copia lo pendiente (no expulsa).
- **Atajos:** prender los atajos de teclado y ver los enlaces `relevo://`.
- **Papelera de Relevo:**
  - Cuántos días guardar lo borrado y reemplazado: 3, 7, 30 o 90.
  - **Vaciar ahora**, que muestra cuánto ocupa y te pide confirmación.
- **Apariencia:**
  - Tema: claro, oscuro o el de la Mac.
  - Idioma: español, inglés o el de la Mac.

## 6. Qué se copia y qué no

**Se copia todo lo de las carpetas que tildaste**, incluidos los archivos ocultos como `.env` y `.git`.

**Nunca se copia:**

- Lo propio de macOS (`.DS_Store`, papeleras, índices de Spotlight) y los candados de git: duran un instante y se arman solos.
- **Compilados y cachés**, que se arman de nuevo solos: `.next`, `.nuxt`, `.turbo`, `.expo`, `.build`, `DerivedData`, `.gradle`, `.parcel-cache`, `.svelte-kit`, `__pycache__`.
- Cualquier carpeta que se llame **«Cosas mías»**, esté donde esté: sirve para guardar algo que no querés que pase al otro disco.
- Lo que agregues vos en «Lo que nunca se sincroniza».

**Se puede elegir:**

- **Dependencias** (`node_modules`, `.pnpm-store`, `.venv`, `venv`, `Pods`). Por defecto **se copian**, así afuera tus proyectos funcionan sin volver a bajarlas (con las mismas rutas andan tal cual). Si las apagás, ocupan menos lugar, pero afuera hay que instalarlas de nuevo.
- **Lo que ignora git:** lo que el `.gitignore` de cada proyecto deja afuera (`dist`, `coverage`, logs…). Por defecto se copia. Los `.env` se copian igual.

**Lo que está prendido espera.** Una base de datos, un emulador de Android o una máquina virtual (UTM, VMware, Parallels, VirtualBox) cambian sin parar mientras están funcionando, y una copia de ese momento quedaría a medias. Relevo no los toca mientras están prendidos y los copia una sola vez cuando los cerrás.

## 7. Nada se borra del todo

- **Lo borrado y lo reemplazado no desaparece.** Cuando borrás algo en un disco, en el otro no se borra del todo: va a la **papelera de Relevo** de ese disco (una carpeta oculta, `.Relevo/Papelera`). Cuando un archivo se reemplaza por uno más nuevo, la versión vieja también va ahí.
- **Cuánto tiempo queda:** lo elegís en General (3, 7, 30 o 90 días); pasado ese tiempo, se borra solo. De los archivos muy grandes (256 MB o más) guarda solo la última versión, para no llenar el disco.
- **Cómo recuperar algo:** desde **Historial**, con «Recuperar» o «Volver a la anterior».
- **Vaciarla en el momento:** **General → Papelera de Relevo → Vaciar ahora**. Lo que estaba en la papelera ya no se puede recuperar; tus archivos no se tocan.

### Borrar un proyecto entero

Si borrás (o movés) una carpeta entera de un disco, Relevo **no la borra del otro sin preguntarte**. En Inicio aparece «Hace falta tu OK», con la lista:

- **«Sí, seguir»:** la saca también del otro disco (va a la papelera de Relevo).
- **«Ahora no»:** no toca nada.
- **Si no respondés**, se aplica sola a los 3 días. Lo borrado queda en la papelera.

### El mismo archivo cambió en los dos lados

Si cambiaste el mismo archivo distinto en el hub y en el portátil, Relevo **guarda las dos versiones**: la más nueva queda con su nombre y la otra al lado, en los dos discos, como «nombre (conflicto hub …)» o «nombre (conflicto portátil …)», con la fecha. En **Historial → Dos versiones** elegís cuál queda («Quedarme con la del hub», «Usar la otra») o, si ya lo arreglaste a mano, «Ya lo resolví».

### Repositorios con commits distintos en cada disco

Si un proyecto tiene commits distintos en el hub y en el portátil, Relevo **no toca su carpeta `.git`** (así las historias no se mezclan) y te avisa para que las unas con git. El resto de los archivos sigue sincronizándose.

### Si desenchufás el disco en medio de una copia

Cada archivo se escribe con un nombre temporal y se renombra al final, y un diario recuerda lo recién escrito. Así, si sacás el disco de golpe, la próxima vez Relevo repara lo que quedó a medias en vez de tomarlo como un borrado tuyo. Después de un desenchufe así, revisa todo por las dudas.

## 8. Cifrar el portátil

Si perdés el portátil, cualquiera puede leer lo que tiene, incluidas las claves de tus proyectos. Cifrarlo es opcional y se hace desde **Discos → Cifrado del portátil → Cifrar…**:

1. Relevo te explica qué va a pasar.
2. Te muestra la **clave del disco**: palabras simples, sin tildes, para tipearla en cualquier teclado. Copiala a la app Contraseñas (botón «+», nombre «Disco <nombre>») o anotala en un papel que no viaje con el disco.
3. Para confirmar que la guardaste, te pide la **última palabra**.
4. Cifra en segundo plano: podés seguir usando el disco y cerrar la ventana. Si lo desenchufás a la mitad, sigue la próxima vez.

En esta Mac no cambia nada: la clave queda en el llavero y Relevo abre el disco sola cada vez que lo enchufás. En otra Mac te pide la clave. Para volver a verla, «Ver la clave» te pide Touch ID o la contraseña de la Mac.

Si perdés la clave y no está en ningún lado, lo del portátil no se puede recuperar. Pero el hub tiene todo: se borra el portátil y Relevo lo vuelve a llenar.

## 9. Atajos y enlaces

**Atajos de teclado**, que se prenden en General:

| Atajo | Hace |
|---|---|
| ⌃⌥⌘S | Sincronizar |
| ⌃⌥⌘L | Me voy |
| ⌃⌥⌘E | Expulsar discos |

**Enlaces `relevo://`**, para Atajos de macOS, Raycast o Alfred:

| Enlace | Hace |
|---|---|
| `relevo://sincronizar` | Sincroniza lo que cambió |
| `relevo://mevoy` | Copia lo último y expulsa el portátil |
| `relevo://expulsar` | Expulsa los discos |
| `relevo://pausar?horas=1` | Pausa por la cantidad de horas que pongas |
| `relevo://reanudar` | Vuelve a prender la copia |

«Me voy», expulsar y reanudar te piden confirmación antes de hacer nada, porque cualquier página web podría abrir un enlace así. La pausa por enlace dura como máximo 30 días.

## 10. Qué hacer si…

**…el portátil aparece con el nombre del hub en casa («Los discos quedaron al revés»).** Pasa si el portátil se montó primero. Mientras tanto Relevo no sincroniza, para que nada vaya al disco equivocado. Tocá **«Acomodar»** en Inicio: les cambia el nombre sin desmontar nada.

**…no puedo expulsar el disco.** Relevo te muestra qué lo está usando. Cerralo o tocá «Cerrar y expulsar». Si macOS no dice qué lo usa, probá de nuevo en unos segundos.

**…Relevo dice «Falta la primera copia».** Tocá «Sincronizar ahora». La primera vez copia todo y puede tardar.

**…no encuentro un archivo que borré.** Andá a **Historial**, buscalo por nombre y tocá «Recuperar». Si pasó más tiempo que el que elegiste para la papelera, ya no está.

**…llevo claves (`.env`) en el portátil.** Relevo te lo avisa en Inicio. Cifrá el portátil (ver [Cifrar el portátil](#8-cifrar-el-portátil)).

**…un proyecto no anda afuera porque le faltan las dependencias.** En Inicio aparece el aviso con los comandos para instalarlas («Copiar los comandos»). Para que viajen siempre, dejá prendidas las dependencias en «Lo que nunca se sincroniza».

**…quiero que una carpeta no pase al otro disco.** Agregala en **Qué se sincroniza → Lo que nunca se sincroniza → Agregar carpeta o archivo…**, o ponele «Cosas mías» de nombre.

**…quiero parar un rato.** Menú de Relevo → **Pausar** (1 hora, hasta mañana o hasta que la reanudes).

## 11. Actualizar Relevo

- **Si la compilaste vos:** bajá el código nuevo y compilá otra vez.

  ```bash
  git pull && ./compilar.sh instalar
  ```

  Tus ajustes, tus vínculos y la papelera quedan como estaban.

- **Si instalaste una versión publicada por Halyon Team:** se actualiza sola. Relevo busca versiones nuevas una vez por día y te pregunta antes de instalar. También podés buscar a mano desde el menú, con «Buscar actualizaciones…». Las versiones nuevas vienen firmadas: Relevo solo instala las que firmó Halyon Team.

---

<p align="center">Desarrollado por <a href="https://halyon.team"><b>Halyon Team</b></a> · Hecho en Argentina 🇦🇷</p>
