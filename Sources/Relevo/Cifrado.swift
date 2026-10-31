import Foundation
import Security

// Cifrado opcional del disco portátil (APFS). Si lo perdés, nadie lo puede leer sin la clave.
// La clave la inventa Relevo, queda en el llavero y en esta Mac el disco se abre solo.
// En otra Mac te la pide: por eso la hoja de cifrar insiste en que la guardes también en otro lado.
//
// Nombres reales de diskutil (probados el 21/10/2026 en macOS 27 con una imagen de ensayo):
//   `diskutil info -plist <UUID>`     → "FileVault" (cifrado con clave), "Locked" (cifrado y sin abrir),
//                                        "FilesystemType" ("apfs"), "APFSContainerReference" ("disk9"), "Internal".
//   `diskutil apfs list -plist <contenedor>` → por volumen: "CryptoMigrationOn", "CryptoMigrationDirection"
//                                        ("Encrypting"/"Decrypting"), "CryptoMigrationProgressPercent" (0-100),
//                                        "CryptoMigrationState" ("InProgress").
//   Ojo: mientras cifra, `info` ya dice FileVault = true; el avance solo está en `apfs list`.
//   Al desmontar un volumen cifrado queda "Locked" = true. `unlockVolume` acepta el UUID.
//   Bloqueado, `diskutil mount` falla ("use diskutil apfs unlockVolume"): para montarlo oculto hay que abrirlo con
//   `unlockVolume -nomount` y después `diskutil mount nobrowse` (probado el 25/10/2026 con una imagen de ensayo).

enum EstadoCifrado: Equatable {
    case sinCifrar
    /// Cifrando en segundo plano: avance de 0 a 1.
    case cifrando(Double)
    case cifrado
    /// Cifrado y sin abrir (desenchufado y vuelto a enchufar, o desmontado).
    case bloqueado
    case desconocido
}

enum ErrorCifrado: Error, Equatable {
    case noEsAPFS(String)
    case noEsExterno
    case yaCifrado
    case noEncontrado
    case claveVacia
    case fallo(String)

    var mensaje: String {
        switch self {
        case .noEsAPFS(let formato):
            return T("Solo se pueden cifrar discos en formato APFS (este es %@). Para cambiarlo hay que borrarlo con la Utilidad de Discos; el hub tiene todo, así que después se vuelve a copiar.",
                     formato.isEmpty ? T("otro formato") : formato)
        case .noEsExterno: return T("Solo se cifran discos externos.")
        case .yaCifrado: return T("Este disco ya está cifrado.")
        case .noEncontrado: return T("No encuentro el disco. ¿Sigue enchufado?")
        case .claveVacia: return T("La clave está vacía.")
        case .fallo(let detalle): return T("macOS no lo pudo cifrar: %@", detalle)
        }
    }
}

enum Cifrado {
    // MARK: Clave

    /// 6 palabras simples (sin tildes ni ñ, para tipearla en cualquier teclado) + 2 números, con guiones.
    /// Ej.: `faro-tango-mate-nube-rio-pala-42`. Con 598 palabras son unos 62 bits: imposible de adivinar probando.
    static func generarClave() -> String {
        var partes = (0..<6).map { _ in palabras[azar(palabras.count)] }
        partes.append(String(format: "%02d", azar(100)))
        return partes.joined(separator: "-")
    }

    /// Número al azar de 0 a tope-1, con el generador seguro del sistema y sin preferir ninguno.
    private static func azar(_ tope: Int) -> Int {
        let t = UInt32(tope)
        let limite = (UInt32.max / t) * t   // lo que pasa del último múltiplo se descarta (si no, los primeros salen más)
        while true {
            var n: UInt32 = 0
            let r = withUnsafeMutableBytes(of: &n) { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
            precondition(r == errSecSuccess, "No anda el generador al azar del sistema")
            if n < limite { return Int(n % t) }
        }
    }

    // MARK: Estado

    static func estado(uuid: String) -> EstadoCifrado {
        guard let i = info(uuid) else { return .desconocido }
        if i["Locked"] as? Bool == true { return .bloqueado }
        guard i["FileVault"] as? Bool == true else { return .sinCifrar }
        // El avance solo aparece en la lista de APFS del contenedor.
        guard let contenedor = i["APFSContainerReference"] as? String,
              let lista = plist(correr(["apfs", "list", "-plist", contenedor]).salida),
              let contenedores = lista["Containers"] as? [[String: Any]] else { return .cifrado }
        let volumenes = contenedores.flatMap { $0["Volumes"] as? [[String: Any]] ?? [] }
        guard let v = volumenes.first(where: { ($0["APFSVolumeUUID"] as? String)?.caseInsensitiveCompare(uuid) == .orderedSame }),
              v["CryptoMigrationOn"] as? Bool == true else { return .cifrado }
        // Si está descifrando (alguien lo hizo a mano), todavía hace falta la clave: cuenta como cifrado.
        guard (v["CryptoMigrationDirection"] as? String) != "Decrypting" else { return .cifrado }
        let avance = (v["CryptoMigrationProgressPercent"] as? NSNumber)?.doubleValue ?? 0
        return .cifrando(min(max(avance / 100, 0), 1))
    }

    /// Si se puede cifrar (APFS). Para mostrar el aviso antes de empezar.
    static func esAPFS(_ v: Volumen) -> Bool { esAPFS(uuid: v.uuid) }
    static func esAPFS(uuid: String) -> Bool { (info(uuid)?["FilesystemType"] as? String) == "apfs" }

    /// Desmonta sin expulsar (un disco cifrado queda bloqueado). Para la prueba de terminal.
    static func desmontar(_ ruta: String) -> Bool { correr(["unmount", ruta]).codigo == 0 }

    // MARK: Cifrar y abrir

    /// Empieza el cifrado de APFS (sigue solo en segundo plano, aunque se cierre la app). La clave va por la entrada
    /// estándar: como argumento se vería en la lista de procesos.
    static func cifrar(_ v: Volumen, clave: String) -> Result<Void, ErrorCifrado> {
        guard v.externo else { return .failure(.noEsExterno) }
        return cifrar(ruta: v.ruta, uuid: v.uuid, clave: clave)
    }

    /// Lo mismo, por ruta y UUID (lo usa la prueba de terminal).
    static func cifrar(ruta: String, uuid: String, clave: String) -> Result<Void, ErrorCifrado> {
        guard !clave.isEmpty else { return .failure(.claveVacia) }
        // El dispositivo se busca por la ruta y se confirma que es el mismo disco (mismo UUID) antes de escribir nada.
        guard let porRuta = info(ruta), let dispositivo = porRuta["DeviceIdentifier"] as? String, let i = info(dispositivo),
              (i["VolumeUUID"] as? String)?.caseInsensitiveCompare(uuid) == .orderedSame else { return .failure(.noEncontrado) }
        guard (i["FilesystemType"] as? String) == "apfs" else {
            return .failure(.noEsAPFS(i["FilesystemUserVisibleName"] as? String ?? ""))
        }
        guard i["Internal"] as? Bool != true else { return .failure(.noEsExterno) }
        guard i["FileVault"] as? Bool != true else { return .failure(.yaCifrado) }
        let r = correr(["apfs", "encryptVolume", dispositivo, "-user", "disk", "-stdinpassphrase"], entrada: clave)
        return r.codigo == 0 ? .success(()) : .failure(.fallo(r.mensaje))
    }

    /// Abre (y monta) un disco cifrado. Sin punto de montaje va a /Volumes/<nombre>, como siempre.
    static func desbloquear(uuid: String, clave: String, puntoDeMontaje: String? = nil) -> Bool {
        guard !clave.isEmpty else { return false }
        var args = ["apfs", "unlockVolume", uuid, "-stdinpassphrase"]
        if let p = puntoDeMontaje { args += ["-mountpoint", p] }
        return correr(args, entrada: clave).codigo == 0
    }

    /// Abre un disco cifrado y lo monta oculto (sin aparecer en la barra lateral del Finder) o visible. Lo llama
    /// `Coordinador.intentarDesbloquear` al enchufar el portátil: así en casa entra oculto de una, sin el desmontar y
    /// volver a montar que lo dejaba cerrado (25/10/2026). Si el oculto falla, que al menos quede montado.
    static func abrir(uuid: String, clave: String, oculto: Bool) -> Bool {
        guard abrirSinMontar(uuid, clave: clave) else { return false }
        if oculto, correr(["mount", "nobrowse", uuid]).codigo == 0 { return true }
        return correr(["mount", uuid]).codigo == 0
    }

    /// Le saca el candado sin montarlo (después se monta con `diskutil mount`, oculto o no). `disco` puede ser el UUID
    /// o el dispositivo ("disk7s1"). Lo usan `abrir` y `Discos.remontar`.
    static func abrirSinMontar(_ disco: String, clave: String) -> Bool {
        guard !clave.isEmpty else { return false }
        return correr(["apfs", "unlockVolume", disco, "-stdinpassphrase", "-nomount"], entrada: clave).codigo == 0
    }

    /// ¿Tiene cifrado de APFS (abierto, cerrado o cifrándose)? Uno así queda cerrado al desmontarlo.
    static func tieneCifrado(_ disco: String) -> Bool { info(disco)?["FileVault"] as? Bool == true }

    /// Si está bloqueado y la clave está en el llavero, lo abre solo. Para llamar al enchufar el portátil.
    @discardableResult
    static func desbloquearConLlavero(uuid: String, puntoDeMontaje: String? = nil) -> Bool {
        guard estado(uuid: uuid) == .bloqueado, let clave = Llavero.leer(uuid) else { return false }
        return desbloquear(uuid: uuid, clave: clave, puntoDeMontaje: puntoDeMontaje)
    }

    // MARK: diskutil

    static func info(_ disco: String) -> [String: Any]? {
        let r = correr(["info", "-plist", disco])
        return r.codigo == 0 ? plist(r.salida) : nil
    }

    private static func plist(_ datos: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: datos, format: nil)) as? [String: Any]
    }

    private struct Salida {
        var codigo: Int32
        var salida: Data
        var mensaje: String
    }

    /// Corre diskutil. Si hay `entrada`, se escribe en su entrada estándar y se cierra (así lee la clave).
    private static func correr(_ args: [String], entrada: String? = nil) -> Salida {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        let salida = Pipe(), errores = Pipe(), tuboEntrada = Pipe()
        p.standardOutput = salida
        p.standardError = errores
        p.standardInput = entrada == nil ? FileHandle.nullDevice : tuboEntrada
        guard (try? p.run()) != nil else { return Salida(codigo: -1, salida: Data(), mensaje: T("no se pudo abrir diskutil")) }
        if let entrada {
            try? tuboEntrada.fileHandleForWriting.write(contentsOf: Data(entrada.utf8))
            try? tuboEntrada.fileHandleForWriting.close()
        }
        // Se leen los dos a la vez para que diskutil nunca se trabe con un tubo lleno.
        var datosError = Data()
        let listo = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { datosError = errores.fileHandleForReading.readDataToEndOfFile(); listo.signal() }
        let datos = salida.fileHandleForReading.readDataToEndOfFile()
        listo.wait()
        p.waitUntilExit()
        // diskutil explica los errores a veces por una salida y a veces por la otra: se usa la última línea con texto.
        let texto = String(decoding: datosError + datos, as: UTF8.self)
        let ultima = texto.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
        return Salida(codigo: p.terminationStatus, salida: datos, mensaje: ultima.isEmpty ? "error \(p.terminationStatus)" : ultima)
    }

    // MARK: Palabras

    /// Palabras comunes, cortas, sin tildes ni ñ (se pueden tipear en cualquier teclado). Se pueden sumar más
    /// (las claves ya hechas no dependen de la lista), pero ninguna con tilde, ñ o mayúscula.
    static let palabras: [String] = [
        "abanico", "abeja", "abrazo", "abril", "abuelo", "aceite", "acero", "acuarela", "adobe", "agua", "aguacero", "aguila",
        "ahorro", "aire", "ajo", "ala", "alba", "albahaca", "alegre", "alfombra", "alma", "almeja", "almohada", "alto",
        "amapola", "amigo", "ananas", "ancho", "ancla", "angel", "anillo", "animal", "anis", "antena", "anzuelo", "arbol",
        "arcilla", "arco", "ardilla", "arena", "armario", "arpa", "arroz", "arte", "asado", "ascensor", "atlas", "aula",
        "auto", "avellana", "avena", "avion", "ayer", "azafran", "azucar", "azul", "bahia", "baile", "balde", "ballena",
        "bambu", "banco", "banda", "bandeja", "barco", "barra", "barril", "barro", "baston", "bate", "batido", "baul",
        "bebe", "bellota", "beso", "bici", "bigote", "billete", "bizcocho", "bocina", "bodega", "bolsa", "bombilla", "bombo",
        "borde", "bosque", "bota", "bote", "boton", "brasa", "brazo", "brisa", "broma", "brote", "brujula", "buceo",
        "bufanda", "buho", "burro", "buzo", "caballo", "cabra", "cacao", "cactus", "cadena", "cafe", "caja", "calle",
        "calma", "cama", "camello", "camino", "campo", "canal", "cancion", "canela", "cangrejo", "canica", "canoa", "canto",
        "capa", "cara", "caracol", "carbon", "cardo", "carta", "casa", "cascada", "casco", "castillo", "castor", "cebolla",
        "cebra", "cedro", "cena", "cepillo", "cerca", "cereza", "cerezo", "cesta", "charco", "chispa", "cielo", "cinco",
        "cine", "cinta", "circo", "cisne", "ciudad", "clavel", "clavo", "clima", "cobija", "cobre", "cocina", "coco",
        "codo", "cohete", "cola", "colibri", "colina", "collar", "color", "cometa", "concha", "coral", "corazon", "cordel",
        "cordero", "corona", "costa", "crema", "cuaderno", "cuadro", "cubo", "cuchara", "cuento", "cuerda", "cueva", "cultura",
        "cuna", "dado", "dama", "danza", "dedo", "delfin", "dia", "diamante", "dibujo", "diente", "dinero", "disco",
        "doble", "domingo", "dragon", "ducha", "dulce", "duna", "durazno", "eco", "eje", "elefante", "empanada", "encina",
        "enero", "equipo", "escala", "escalera", "escoba", "espejo", "espiga", "esponja", "establo", "estrella", "estufa", "faro",
        "feria", "fideo", "fiesta", "flan", "flauta", "flor", "foca", "foco", "fogata", "forma", "foto", "frazada",
        "fresa", "frijol", "fruta", "fuego", "fuente", "fuerte", "futbol", "gacela", "gafas", "gaita", "galaxia", "galleta",
        "gallo", "ganso", "garaje", "garbanzo", "gato", "gaucho", "gaviota", "gema", "gesto", "girasol", "glaciar", "globo",
        "gol", "golfo", "golondrina", "gorra", "gorrion", "gota", "granito", "granja", "grano", "grillo", "grulla", "grupo",
        "guante", "guitarra", "gusano", "hacha", "hada", "hamaca", "harina", "helado", "hielo", "hierba", "hierro", "higo",
        "hilo", "hoja", "hongo", "hora", "hormiga", "horno", "hotel", "huerta", "hueso", "huevo", "humo", "idea",
        "iglu", "imagen", "iman", "isla", "jabon", "jaguar", "jamon", "jardin", "jarra", "jazmin", "jirafa", "joya",
        "juego", "jueves", "jugo", "julio", "junio", "kiwi", "lago", "laguna", "lana", "lapiz", "largo", "lata",
        "latido", "laurel", "lazo", "leche", "lechuza", "lente", "lenteja", "leon", "letra", "libro", "liebre", "limon",
        "lindo", "linea", "lino", "lirio", "lista", "llave", "lluvia", "lobo", "lombriz", "lomo", "lona", "loro",
        "luna", "lunes", "luz", "madera", "maiz", "malva", "mandarina", "mango", "mano", "manta", "mantel", "manzana",
        "mapa", "mar", "marco", "mareo", "mariposa", "martillo", "marzo", "masa", "mate", "mayo", "mecha", "medalla",
        "medusa", "mejillon", "melon", "mesa", "metal", "miel", "mimbre", "mimo", "mina", "mirlo", "mochila", "molino",
        "mono", "mora", "morral", "morsa", "mosca", "motor", "mueble", "muelle", "mundo", "muro", "museo", "musica",
        "nabo", "naranja", "nariz", "nave", "neblina", "nido", "niebla", "nieve", "noche", "nogal", "norte", "nota",
        "nube", "nudo", "nuez", "numero", "nutria", "oasis", "obra", "oca", "ocaso", "oceano", "ocho", "oeste",
        "ola", "olivo", "olla", "onda", "orca", "oro", "orquesta", "ortiga", "oso", "oveja", "padre", "paja",
        "pajaro", "pala", "palma", "paloma", "pan", "panal", "panda", "pantano", "papel", "paraguas", "parque", "paso",
        "pasto", "pato", "pausa", "pavo", "paz", "pecera", "peine", "pelota", "pepino", "pera", "perejil", "perla",
        "perro", "pesca", "piano", "pico", "pie", "piedra", "pimienta", "pinar", "pinguino", "pino", "pinza", "pipa",
        "pirata", "piso", "pista", "pizarra", "platano", "plato", "playa", "plaza", "pluma", "polo", "pomada", "pomelo",
        "poncho", "postre", "potro", "prado", "primo", "puchero", "puente", "puerta", "pulpo", "puma", "punto", "quena",
        "queso", "quinoa", "rabano", "radio", "raiz", "rama", "rana", "ranura", "rayo", "red", "regalo", "reloj",
        "remo", "rey", "rio", "risa", "roble", "roca", "rocio", "rodilla", "rojo", "romero", "rosa", "rueda",
        "ruta", "sabado", "sal", "salmon", "salsa", "salto", "sandia", "sapo", "sardina", "sarten", "sauce", "sello",
        "selva", "semilla", "senda", "serrucho", "sidra", "silla", "soga", "sol", "sombra", "sombrero", "sonido", "sopa",
        "sur", "tabla", "taco", "tambor", "tango", "tapa", "taza", "techo", "tecla", "tejado", "tejon", "tela",
        "telar", "tema", "tenis", "ternero", "tesoro", "tierra", "tigre", "tinta", "tio", "tiza", "toalla", "tomate",
        "tomillo", "torre", "tortuga", "trapo", "trebol", "tren", "trigo", "trineo", "trompo", "trucha", "trueno", "tubo",
        "tucan", "tulipan", "tuna", "turno", "urna", "uva", "vaca", "vagon", "valle", "vapor", "vaso", "vela",
        "velero", "venado", "ventana", "verano", "verde", "viaje", "viento", "viernes", "vino", "violeta", "violin", "volcan",
        "yate", "yegua", "yerba", "yeso", "yoga", "zanahoria", "zapato", "zarza", "zorro", "zumo"
    ]
}
