import Foundation
import SwiftUI

// Idioma de la interfaz: español o inglés. Los textos se escriben en español en el código y se envuelven con `T(...)`:
// en español salen tal cual; en inglés se buscan en `traduccionesIngles` (la clave es el texto en español exacto).
// Lo que no se traduce a propósito: nombres de carpetas y archivos, comandos, claves de JSON, la salida de las órdenes
// de terminal y las palabras de la clave del cifrado.

enum Idioma: String, Codable, CaseIterable, Identifiable {
    case automatico, es, en

    var id: String { rawValue }

    /// Cada idioma con su nombre en su propio idioma (así lo encuentra cualquiera); "Automático" sí se traduce.
    var nombre: String {
        switch self {
        case .automatico: T("Automático")
        case .es: "Español"
        case .en: "English"
        }
    }

    /// El idioma con el que se muestra todo ahora (nunca `.automatico`). Arranca con el guardado en los ajustes (sin
    /// cargarlos enteros: así las órdenes de terminal no los tocan) y cambia con ellos (`Ajustes.datos.didSet` llama a `usar`).
    private(set) static var activo: Idioma = resolver(Ajustes.idiomaGuardado())

    static func usar(_ elegido: Idioma) { activo = resolver(elegido) }

    /// Para números y tamaños: la coma o el punto según el idioma de la app, no el de la Mac.
    static var locale: Locale { Locale(identifier: activo == .en ? "en_US" : "es_AR") }

    /// Automático: el primer idioma preferido de la Mac. Si es español (cualquier variante), español; si no, inglés.
    static func resolver(_ elegido: Idioma) -> Idioma {
        guard elegido == .automatico else { return elegido }
        let primero = Locale.preferredLanguages.first?.lowercased() ?? "es"
        return primero.hasPrefix("es") ? .es : .en
    }
}

/// Un texto que ve el usuario, en el idioma activo. Si falta la traducción, queda en español.
func T(_ es: String) -> String {
    guard Idioma.activo == .en else { return es }
    if let en = traduccionesIngles[es] ?? traduccionesExtras[es] ?? traduccionesRepos[es] { return en }
    #if DEBUG
    Faltantes.anotar(es)
    #endif
    return es
}

/// Igual, para textos con datos: `T("Copiando %ld de %ld…", hechos, total)`. `%@` = texto, `%ld` = Int,
/// `%lld` = Int64, `%d` = Int32, `%%` = el signo de porcentaje.
func T(_ es: String, _ datos: CVarArg...) -> String {
    String(format: T(es), arguments: datos)
}

extension Text {
    /// Texto con **negrita** o `código` (un `String` común se muestra tal cual, sin interpretar el formato).
    init(markdown: String) { self.init(LocalizedStringKey(markdown)) }
}

#if DEBUG
/// En las compilaciones de prueba, avisa una sola vez por cada texto sin traducir.
private enum Faltantes {
    private static let candado = NSLock()
    private static var vistos = Set<String>()

    static func anotar(_ es: String) {
        candado.lock()
        let nuevo = vistos.insert(es).inserted
        candado.unlock()
        if nuevo { FileHandle.standardError.write(Data("Relevo: falta traducir al inglés: \(es)\n".utf8)) }
    }
}
#endif

/// Español → inglés. Inglés de producto de Mac: corto y natural, no literal.
/// Glosario: hub → hub · portátil → portable drive · sincronizar → sync · vínculo → link · Me voy → I'm leaving.
private let traduccionesIngles: [String: String] = [
    // Lados (llegan del motor como "hub"/"portátil")
    "hub": "hub",
    "portátil": "portable drive",

    // Ajustes
    "Sistema": "System",
    "Claro": "Light",
    "Oscuro": "Dark",
    "Esta Mac": "This Mac",
    "Automático": "Automatic",

    // Estado (menú de la barra e inicio)
    "Falta elegir qué se sincroniza": "Choose what syncs",
    "Trabajando desde el portátil": "Working from the portable drive",
    "Listo: ya podés desenchufarlo": "Done: you can unplug it now",
    "Portátil desconectado": "Portable drive disconnected",
    "Los discos quedaron al revés": "The drives got swapped",
    "Falta la primera copia": "First copy pending",
    "En pausa hasta %@": "Paused until %@",
    "En pausa": "Paused",
    "Revisando…": "Checking…",
    "Copiando %ld de %ld…": "Copying %ld of %ld…",
    "Copiando…": "Copying…",
    "Todo al día": "All up to date",
    "Hace falta tu OK": "Needs your OK",
    "Expulsando…": "Ejecting…",

    // Menú de la barra
    "Falta configurar": "Not set up yet",
    "Vínculo": "Link",
    "Sincronizar ahora": "Sync now",
    "Me voy (copiar y expulsar)": "I'm leaving (copy and eject)",
    "Mostrar el portátil en el Finder": "Show the portable drive in Finder",
    "Reanudar": "Resume",
    "Pausar": "Pause",
    "1 hora": "1 hour",
    "Hasta mañana": "Until tomorrow",
    "Hasta que la reanude": "Until I resume it",
    "Abrir Relevo…": "Open Relevo…",
    "Historial": "History",
    "Salir de Relevo": "Quit Relevo",

    // Cifrado (errores)
    "Solo se pueden cifrar discos en formato APFS (este es %@). Para cambiarlo hay que borrarlo con la Utilidad de Discos; el hub tiene todo, así que después se vuelve a copiar.": 
        "Only APFS drives can be encrypted (this one is %@). Changing that means erasing it in Disk Utility; the hub has everything, so it gets copied back afterwards.",
    "otro formato": "another format",
    "Solo se cifran discos externos.": "Only external drives can be encrypted.",
    "Este disco ya está cifrado.": "This drive is already encrypted.",
    "No encuentro el disco. ¿Sigue enchufado?": "Can't find the drive. Is it still plugged in?",
    "La clave está vacía.": "The password is empty.",
    "macOS no lo pudo cifrar: %@": "macOS couldn't encrypt it: %@",
    "no se pudo abrir diskutil": "couldn't run diskutil",

    // Pedidos de OK y avisos
    "No está en el %@, pero la última vez sí. Si la borraste o la moviste a propósito, seguí y se manda a la papelera del otro lado.": 
        "It's missing on the %@, but it was there last time. If you deleted or moved it on purpose, continue and it goes to the other side's trash.",
    "Se mandarían %ld archivos a la papelera del %@. Puede ser una limpieza tuya o un error.": 
        "%ld files would go to the %@'s trash. It could be your own cleanup, or a mistake.",
    "No entra en el %@: hacen falta %@ y hay %@.": "It doesn't fit on the %@: it needs %@ and there's %@.",
    "Sacaste el portátil sin expulsarlo. Cuando lo vuelvas a enchufar reviso lo último que se le copió.": 
        "You unplugged the portable drive without ejecting it. When you plug it back in, I'll check the last things copied to it.",
    "Relevo necesita tu OK": "Relevo needs your OK",
    "%ld archivo(s) cambiaban mientras se copiaban: van en la próxima.": "%ld file(s) changed while being copied: they'll go next time.",
    "Se desconectó el %@ a mitad de %@. Lo hecho quedó bien; al volver a enchufarlo sigo donde quedé.": 
        "The %@ was disconnected halfway through %@. What was done is fine; when you plug it back in, I'll pick up where I left off.",
    "El portátil no está conectado.": "The portable drive isn't connected.",
    "Antes de irte, fijate lo que necesita tu OK.": "Before you leave, check what needs your OK.",
    "Quedó algo sin copiar (mirá el historial). Probá de nuevo antes de irte.": 
        "Something wasn't copied (see History). Try again before you leave.",
    "Listo: todo copiado y el portátil expulsado. Ya podés desenchufarlo.": 
        "Done: everything is copied and the portable drive is ejected. You can unplug it now.",
    "Listo para irte": "Ready to go",
    "Todo copiado. Ya podés desenchufar %@.": "Everything is copied. You can unplug %@ now.",

    // Ícono de cada disco
    "HUB · CASA": "HUB · HOME",
    "PORTÁTIL": "PORTABLE",

    // Historial (resumen de cada pasada)
    "%ld al portátil": "%ld to portable",
    "%ld al hub": "%ld to hub",
    "%ld a la papelera": "%ld to trash",
    "%ld con dos versiones": "%ld with two versions",
    "revisado": "checked",

    // Llavero
    "Relevo: clave del disco %@": "Relevo: password for drive %@",
    "Clave de disco cifrado": "Encrypted drive password",
    "La pide otra Mac al enchufar el disco “%@”. Relevo la usa para abrirlo solo en esta.": 
        "Another Mac asks for it when you plug in the drive “%@”. Relevo uses it to unlock the drive automatically on this one.",

    // Asistente
    "Paso %ld de 3": "Step %ld of 3",
    "Atrás": "Back",
    "Seguir": "Continue",
    "Crear y elegir qué se sincroniza": "Create and choose what syncs",
    "¿Dónde trabajás?": "Where do you work?",
    "El hub: el disco (o la carpeta de esta Mac) que queda en casa y tiene todo.": 
        "The hub: the drive (or folder on this Mac) that stays at home and has everything.",
    "%@ libres": "%@ free",
    "Una carpeta de esta Mac…": "A folder on this Mac…",
    "Por ejemplo, tu carpeta de Proyectos en el disco de la Mac.": "For example, your Projects folder on the Mac's drive.",
    "Volver a buscar discos": "Look for drives again",
    "¿Qué disco te llevás?": "Which drive do you take with you?",
    "El portátil: queda igual al hub y lo usás afuera. Tiene que estar en formato de Mac (APFS).": 
        "The portable drive: it mirrors the hub and you use it away from home. It must be in Mac format (APFS).",
    "Enchufá el disco que te vas a llevar y tocá “Volver a buscar discos”.": 
        "Plug in the drive you'll take with you and click “Look for drives again”.",
    "%@: es formato de Windows. Pasalo a APFS en la Utilidad de Discos para usarlo (eso lo borra).": 
        "%@: this is a Windows format. Convert it to APFS in Disk Utility to use it (that erases it).",
    "Utilidad de Discos": "Disk Utility",
    "Guardar en una carpeta del portátil": "Save to a folder on the portable drive",
    "Para usar el mismo disco en más de un vínculo (por ejemplo, Proyectos y Fotos).": 
        "To use the same drive in more than one link (for example, Projects and Photos).",
    "Nombre de la carpeta": "Folder name",
    "Casi listo": "Almost done",
    "Después elegís qué carpetas se sincronizan.": "Next, you'll choose which folders sync.",
    "Hub": "Hub",
    "Portátil": "Portable drive",
    "Ponerle al portátil el nombre “%@”": "Rename the portable drive to “%@”",
    "Si querés, después podés cifrar el portátil desde Discos (por si lo perdés).": 
        "If you want, you can encrypt the portable drive later from Drives (in case you lose it).",
    "Ese portátil ya está en otro vínculo. Usá “Guardar en una carpeta del portátil” para compartirlo.": 
        "That portable drive is already in another link. Use “Save to a folder on the portable drive” to share it.",
    "Usar como hub": "Use as hub",
    "Elegí la carpeta donde trabajás (por ejemplo, Proyectos).": "Choose the folder where you work (for example, Projects).",

    // Hoja de cifrar
    "La clave del portátil": "Portable drive password",
    "Cifrar el portátil": "Encrypt the portable drive",
    "paso %ld de 4": "step %ld of 4",
    "Cifrar es guardar todo el disco bajo llave. Si lo perdés o te lo roban, nadie puede leer lo que tiene.": 
        "Encrypting locks the whole drive. If you lose it or it gets stolen, nobody can read what's on it.",
    "En esta Mac no cambia nada: Relevo guarda la clave en el llavero y abre el disco sola cada vez que lo enchufás.": 
        "Nothing changes on this Mac: Relevo stores the password in the keychain and unlocks the drive every time you plug it in.",
    "En otra Mac te va a pedir la clave. Por eso, en el paso siguiente te la muestro y la guardás en un lugar seguro.": 
        "Another Mac will ask for the password. That's why the next step shows it to you, so you can keep it somewhere safe.",
    "Cifra en segundo plano: podés seguir usando el disco y cerrar esta ventana. Si lo desenchufás a la mitad, sigue la próxima vez.": 
        "It encrypts in the background: you can keep using the drive and close this window. If you unplug it halfway, it continues next time.",
    "Esta es la clave del disco. Son palabras simples, sin tildes, para que la puedas tipear en cualquier teclado.": 
        "This is the drive's password. It's made of simple words with no accents, so you can type it on any keyboard.",
    "Copiada": "Copied",
    "Copiar": "Copy",
    "Otra clave": "Another password",
    "Abrir Contraseñas": "Open Passwords",
    "Dónde guardarla": "Where to keep it",
    "• Queda sola en el llavero de esta Mac (por eso acá se abre sin pedirla).\n• Guardala también en la app Contraseñas (botón “+”, nombre: “Disco %@”) o anotala en un papel que no viaje con el disco.\n• Si se pierde la clave y no está en ningún lado, lo del disco no se puede recuperar. Pero tranqui: el hub tiene todo, así que se borra el portátil y Relevo lo vuelve a llenar.": 
        "• It's saved automatically in this Mac's keychain (that's why it unlocks here without asking).\n• Also save it in the Passwords app (“+” button, name: “Drive %@”) or write it on paper that doesn't travel with the drive.\n• If the password is lost and isn't saved anywhere, the drive's contents can't be recovered. But don't worry: the hub has everything, so the portable drive gets erased and Relevo fills it again.",
    "Para estar seguros de que la guardaste: escribí la **última palabra** de la clave (la sexta, antes del número).": 
        "To make sure you saved it: type the **last word** of the password (the sixth one, before the number).",
    "última palabra": "last word",
    "No coincide. Si no la anotaste, volvé un paso.": "That doesn't match. If you didn't write it down, go back one step.",
    "Listo: el disco está cifrado.": "Done: the drive is encrypted.",
    "Cifrando… %ld %%": "Encrypting… %ld %%",
    "Empezando…": "Starting…",
    "Podés cerrar esta ventana y seguir usando el disco: macOS sigue cifrando solo.": 
        "You can close this window and keep using the drive: macOS keeps encrypting on its own.",
    "La clave quedó en el llavero de iCloud: la ves también en el iPhone, en Contraseñas.": 
        "The password is in iCloud Keychain: you can also see it on your iPhone, in Passwords.",
    "La clave quedó en el llavero de esta Mac. Si no la pasaste a Contraseñas o a un papel, hacelo ahora.": 
        "The password is in this Mac's keychain. If you haven't saved it in Passwords or on paper, do it now.",
    "Este disco está cifrado y cerrado. Para verla, Relevo te pide Touch ID o la contraseña de la Mac.": 
        "This drive is encrypted and locked. To see the password, Relevo asks for Touch ID or your Mac password.",
    "Este disco está cifrado. Para ver la clave, Relevo te pide Touch ID o la contraseña de la Mac.": 
        "This drive is encrypted. To see the password, Relevo asks for Touch ID or your Mac password.",
    "Todavía cifrando: %ld %%": "Still encrypting: %ld %%",
    "Cancelar": "Cancel",
    "Siguiente": "Next",
    "Ya la guardé": "I saved it",
    "Cifrar": "Encrypt",
    "Listo": "Done",
    "Cerrar (sigue solo)": "Close (keeps going)",
    "Ver la clave": "Show password",
    "No pude leer el estado del disco. ¿Sigue enchufado?": "Couldn't read the drive's status. Is it still plugged in?",
    "La clave de este disco no está en el llavero de esta Mac (¿se cifró en otra?).": 
        "This drive's password isn't in this Mac's keychain (was it encrypted on another Mac?).",
    "No se pudo guardar la clave en el llavero (error %d). No cifré nada.": 
        "Couldn't save the password to the keychain (error %d). Nothing was encrypted.",
    "mostrar la clave del disco “%@”": "show the password for drive “%@”",
    "No se pudo comprobar que sos vos.": "Couldn't verify it's you.",
    "La clave no está en el llavero de esta Mac.": "The password isn't in this Mac's keychain.",

    // Qué se releva
    "Qué se sincroniza": "What syncs",
    "No hay carpetas": "No folders",
    "Creá carpetas en el hub y aparecen acá.": "Create folders on the hub and they'll show up here.",
    "Conectá el hub para elegir": "Connect the hub to choose",
    "Las carpetas se leen del hub (%@).": "Folders are read from the hub (%@).",
    "Todavía no hay discos elegidos": "No drives chosen yet",
    "Empezar": "Get started",
    "Sin subcarpetas": "No subfolders",
    "Se sincronizan %ld carpeta(s) de adentro": "%ld folder(s) inside are synced",
    "No se sincroniza": "Not synced",
    "Se sincroniza todo (y lo nuevo que crees adentro)": "Everything is synced (including anything new you create inside)",
    "Se sincroniza todo menos %ld carpeta(s)": "Everything is synced except %ld folder(s)",
    "%@ arch.": "%@ files",
    "Todavía no elegiste nada": "Nothing chosen yet",
    "Se sincroniza %@ en %@ archivos": "Syncing %@ in %@ files",
    "(midiendo…)": "(measuring…)",
    "%@ libres en el portátil": "%@ free on the portable drive",

    // Discos
    "Discos": "Drives",
    "Elegir los discos": "Choose the drives",
    "Agregar otro vínculo": "Add another link",
    "Abrir": "Open",
    "En casa, ocultar el portátil del Finder": "At home, hide the portable drive from Finder",
    "Revisar": "Check",
    "¿Quitar este vínculo?": "Remove this link?",
    "Quitar": "Remove",
    "Quitar vínculo": "Remove link",
    "no conectado": "not connected",
    "Compara el contenido de cada archivo (no solo fecha y tamaño) para encontrar copias dañadas. Lento: lee todo.": 
        "Compares the contents of every file (not just date and size) to find damaged copies. Slow: it reads everything.",
    "Última: %@.": "Last: %@.",
    "El portátil está en formato %@, que es para Windows: no guarda permisos ni enlaces, y si lo sacás de golpe se puede dañar. Para usarlo con Relevo, pasalo a APFS en la Utilidad de Discos (eso lo borra: primero copiá lo que tenga).": 
        "The portable drive is formatted as %@, which is meant for Windows: it doesn't keep permissions or links, and unplugging it suddenly can damage it. To use it with Relevo, convert it to APFS in Disk Utility (that erases it: copy what's on it first).",
    "Abrir Utilidad de Discos": "Open Disk Utility",
    "Revisando a fondo: %@": "Deep checking: %@",
    "Frenar": "Stop",
    "Revisión terminada: todo coincide byte a byte.": "Check finished: everything matches byte for byte.",
    "%ld archivo(s) no coinciden aunque figuran iguales:": "%ld file(s) don't match even though they look identical:",
    "Copiarlos de nuevo desde el hub": "Copy them again from the hub",
    "Ahora no": "Not now",

    // Lo que nunca se releva (pestaña de "Qué se releva")
    "Compilados y cachés de sitios web": "Website builds and caches",
    "Compilados de Swift y Xcode": "Swift and Xcode builds",
    "Cómo funciona": "How it works",
    "Volver a la lista sugerida": "Restore the suggested list",
    "Caché de Android": "Android cache",

    // General
    "General": "General",
    "Opciones para todos los discos.": "Options for all drives.",
    "Sincronizar sola al enchufar": "Sync automatically when plugged in",
    "Apenas conectás el portátil, trae y lleva lo que cambió.": "As soon as you connect the portable drive, changes are synced both ways.",
    "Copia en vivo": "Live copy",
    "Con los dos conectados, cada cambio se copia a los pocos segundos. Así “Me voy” es instantáneo.": 
        "With both connected, every change is copied within seconds. That makes “I'm leaving” instant.",
    "Abrir al iniciar sesión": "Open at login",
    "Relevo vive en la barra de menú y gasta muy poco.": "Relevo lives in the menu bar and uses very little.",
    "Papelera de Relevo": "Relevo Trash",
    "Cuánto tiempo guardar lo que se borra o se reemplaza": "How long to keep what's deleted or replaced",
    "Cuando borrás algo en un disco, en el otro no se borra del todo: va a una papelera escondida de ese disco. Cuando un archivo se reemplaza por uno más nuevo, la versión vieja también. Desde el Historial lo podés recuperar. Pasado este tiempo, se borra solo.": 
        "When you delete something on one drive, it isn't fully deleted on the other: it goes to a hidden trash on that drive. When a file is replaced by a newer one, the old version goes there too. You can recover it from History. After this time, it's deleted automatically.",
    "%ld días": "%ld days",
    "Apariencia": "Appearance",
    "Tema": "Theme",
    "Idioma": "Language",
    "Automático usa el idioma de la Mac.": "Automatic uses your Mac's language.",

    // Historial
    "Movimientos": "Activity",
    "Dos versiones": "Two versions",
    "Qué se copió, para dónde y cuándo. Nada se borra del todo: podés volver atrás.": 
        "What was copied, where and when. Nothing is ever fully deleted: you can go back.",
    "Buscar archivo o carpeta": "Search file or folder",
    "Todavía no hubo movimientos": "No activity yet",
    "Papeleras de Relevo": "Relevo Trash",
    "Borrar historial": "Clear history",
    "%ld pasadas en vivo": "%ld live passes",
    "Se desconectó el %@ a mitad (se retomó después)": "The %@ was disconnected halfway (resumed later)",
    "…y %@ más": "…and %@ more",
    "Sin detalle archivo por archivo (de una versión anterior de Relevo).": "No file-by-file detail (from an earlier version of Relevo).",
    "Volver a la anterior": "Restore previous",
    "Recuperar": "Recover",
    "→ portátil": "→ portable",
    "→ hub": "→ hub",
    "nuevo %@": "new %@",
    "actualizado %@": "updated %@",
    "a la papelera del %@": "to the %@'s trash",
    "carpeta %@": "folder %@",
    "dos versiones": "two versions",
    "No hay archivos con dos versiones": "No files with two versions",
    "Si cambiás el mismo archivo distinto en los dos lados, Relevo guarda las dos y te pregunta acá cuál queda.": 
        "If you change the same file differently on both sides, Relevo keeps both and asks you here which one stays.",
    "más nuevo": "newest",
    "Cambió distinto en los dos lados. Quedó con su nombre la versión del %@ (la más nueva); la otra está al lado como “%@”.": 
        "It changed differently on both sides. The %@ version (the newest) kept the name; the other one sits next to it as “%@”.",
    "Ver las dos": "Show both",
    "Quedarme con la del %@": "Keep the %@ version",
    "Usar la otra": "Use the other one",
    "Conectá el hub para elegir.": "Connect the hub to choose.",
    "Las dos versiones están en la carpeta.": "Both versions are in the folder.",
    "Ya lo resolví": "I've resolved it",

    // Inicio
    "Inicio": "Home",
    "Hola": "Hi",
    "Relevo mantiene iguales un disco que queda en casa y uno que te llevás.": 
        "Relevo keeps a drive that stays at home identical to one you take with you.",
    "%ld archivo(s) con dos versiones": "%ld file(s) with two versions",
    "Cambiaron distinto en los dos lados. Elegí cuál queda.": "They changed differently on both sides. Choose which one stays.",
    "Ver": "View",
    "Últimos movimientos": "Recent activity",
    "Enchufá el portátil": "Plug in the portable drive",
    "Los dos lados tienen lo mismo.": "Both sides have the same files.",
    "Lo que cambies se copia solo.": "Whatever you change is copied automatically.",
    "Cuando lo enchufes, sincronizo solo lo que cambió.": "When you plug it in, I'll sync only what changed.",
    "El hub no está: cuando vuelvas y lo conectes, te traigo los cambios.": 
        "The hub isn't here: when you're back and connect it, I'll bring your changes over.",
    "Tocá “Sincronizar ahora”: la primera vez copia todo (puede tardar); después, solo lo que cambia.": 
        "Click “Sync now”: the first time copies everything (it may take a while); after that, only what changes.",
    "Elegí qué carpetas se sincronizan en “Qué se sincroniza”.": "Choose which folders sync in “What syncs”.",
    "Elegís el hub (el disco o la carpeta donde trabajás) y el portátil (el disco que te llevás).": 
        "Choose the hub (the drive or folder where you work) and the portable drive (the one you take with you).",
    "Listo: mientras están los dos conectados, cada cambio pasa solo. Con “Me voy” copia lo último y expulsa el disco; al volver, trae lo que cambiaste afuera.": 
        "That's it: while both are connected, every change goes across automatically. “I'm leaving” copies the latest changes and ejects the drive; when you're back, it brings over what you changed while away.",
    "Nada se borra del todo: lo borrado y lo reemplazado va a una papelera de Relevo en cada disco.": 
        "Nothing is ever fully deleted: deleted and replaced files go to a Relevo trash on each drive.",
    "Queda en casa": "Stays at home",
    "Va con vos": "Goes with you",
    "%@: %@ de %@": "%@: %@ of %@",
    "Elegir qué se sincroniza": "Choose what syncs",
    "Me voy": "I'm leaving",
    "Copia lo último y expulsa el portátil para que lo desenchufes tranquilo.": 
        "Copies the latest changes and ejects the portable drive so you can unplug it safely.",
    "Sin elegir": "Not chosen",
    "Sí, seguir": "Yes, continue",
    "Acomodar": "Fix it",

    // Pie
    "Desarrollado por": "Developed by",
    "Hecho en Argentina 🇦🇷": "Made in Argentina 🇦🇷",

    // Seguridad del portátil
    "Cifrar…": "Encrypt…",
    "Si perdés el disco, cualquiera puede leer lo que tiene (incluidas claves de tus proyectos). Cifrarlo es opcional: en esta Mac se abre solo; en otra te pide la clave.": 
        "If you lose the drive, anyone can read what's on it (including your projects' keys). Encrypting is optional: on this Mac it unlocks automatically; another Mac asks for the password.",
    "Para cifrarlo, el disco tiene que estar en formato APFS.": "To encrypt it, the drive must be formatted as APFS.",
    "Podés seguir usándolo mientras tanto. Si lo desenchufás, sigue la próxima vez.": 
        "You can keep using it meanwhile. If you unplug it, it continues next time.",
    "No está en el llavero de esta Mac: guardala.": "It isn't in this Mac's keychain: save it.",
    "La clave está en el llavero de esta Mac.": "The password is in this Mac's keychain.",
    "Si lo perdés, nadie puede leerlo. %@ En otra Mac te la pide al enchufarlo.": 
        "If you lose it, nobody can read it. %@ Another Mac asks for it when you plug it in.",
    "Está cifrado y cerrado. Relevo lo abre solo si la clave está en el llavero.": 
        "It's encrypted and locked. Relevo unlocks it automatically if the password is in the keychain.",

    // Fechas
    "recién": "just now",
    "hace %ld min": "%ld min ago",
    "hace %ld h": "%ld h ago",

    // Acomodar los discos
]
