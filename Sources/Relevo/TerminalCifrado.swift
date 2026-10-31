import Foundation

/// Prueba de punta a punta del cifrado, SOLO con una imagen de disco de ensayo (la arma herramientas/prueba-cifrado.sh):
///   Relevo --probar-cifrado <ruta del volumen de ensayo>
/// Genera una clave, la guarda en el llavero, cifra, desmonta, abre con el llavero, lo oculta y lo muestra como en casa
/// (sin que se cierre) y borra la clave.
/// Se niega a tocar cualquier cosa que no sea una imagen montada en /private/tmp/relevo-cifrado.*
enum TerminalCifrado {
    static func correr(_ args: [String]) -> Bool {
        guard let i = args.firstIndex(of: "--probar-cifrado"), i + 1 < args.count else { return false }
        exit(probar(args[i + 1]) ? 0 : 1)
    }

    private static var fallas = 0
    private static func ok(_ condicion: Bool, _ texto: String) {
        print(condicion ? "✓ \(texto)" : "✗ \(texto)")
        if !condicion { fallas += 1 }
    }

    static func probar(_ ruta: String) -> Bool {
        // Freno: solo una imagen de ensayo montada adentro de la carpeta temporal de la prueba.
        // Se usa el punto de montaje que dice diskutil (no el texto recibido, que puede venir con "/tmp" o "/" al final).
        guard let i = Cifrado.info(ruta), let ruta = i["MountPoint"] as? String,
              ruta.hasPrefix("/private/tmp/relevo-cifrado."), i["BusProtocol"] as? String == "Disk Image",
              (i["VolumeName"] as? String)?.hasPrefix("RLCifrado") == true,
              let uuid = i["VolumeUUID"] as? String else {
            print("✗ No es la imagen de ensayo (tiene que ser una imagen RLCifrado montada en /private/tmp/relevo-cifrado.*). No toco nada.")
            return false
        }
        let nombre = i["VolumeName"] as? String ?? "RLCifrado"
        defer { Llavero.borrar(uuid) }

        // 1. La clave
        let clave = Cifrado.generarClave()
        let partes = clave.split(separator: "-")
        ok(partes.count == 7 && partes.prefix(6).allSatisfy { Cifrado.palabras.contains(String($0)) }
           && partes[6].count == 2 && partes[6].allSatisfy(\.isNumber), "Clave con 6 palabras y 2 números: \(clave)")
        let muchas = Set((0..<2000).map { _ in Cifrado.generarClave() })
        ok(muchas.count == 2000, "2000 claves seguidas, ninguna repetida")
        ok(Cifrado.palabras.count >= 512 && Set(Cifrado.palabras).count == Cifrado.palabras.count
           && Cifrado.palabras.allSatisfy { $0.allSatisfy { ("a"..."z").contains($0) } },
           "\(Cifrado.palabras.count) palabras, sin repetir, sin tildes ni ñ")

        // 2. El llavero
        let donde = Llavero.guardar(clave, uuid: uuid, nombre: nombre)
        ok(donde != nil, "Clave guardada en el llavero: \(donde.map { $0 == Llavero.Donde.icloud ? "iCloud" : "esta Mac (iCloud no se pudo: \(Llavero.ultimoError))" } ?? "no")")
        ok(Llavero.leer(uuid) == clave, "Se lee igual del llavero")
        ok(Llavero.donde(uuid) == donde, "Dice dónde está")

        // 3. Cifrar
        let prueba = ruta + "/prueba.txt"
        try? "hola desde antes de cifrar".write(toFile: prueba, atomically: true, encoding: .utf8)
        ok(Cifrado.estado(uuid: uuid) == .sinCifrar, "Antes: sin cifrar")
        ok(Cifrado.esAPFS(uuid: uuid), "Es APFS")
        switch Cifrado.cifrar(ruta: ruta, uuid: uuid, clave: clave) {
        case .success: ok(true, "Empezó el cifrado (clave por la entrada estándar)")
        case .failure(let e): ok(false, "No cifró: \(e.mensaje)"); return false
        }
        if case .failure(.yaCifrado) = Cifrado.cifrar(ruta: ruta, uuid: uuid, clave: clave) { ok(true, "Cifrar dos veces avisa que ya está") }
        else { ok(false, "Cifrar dos veces avisa que ya está") }
        var vistos: [String] = []
        let tope = Date().addingTimeInterval(180)
        var e = Cifrado.estado(uuid: uuid)
        while Date() < tope {
            e = Cifrado.estado(uuid: uuid)
            if case .cifrando(let avance) = e { vistos.append(String(format: "%.0f%%", avance * 100)) }
            if e == .cifrado { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        ok(e == .cifrado, "Terminó de cifrar" + (vistos.isEmpty ? " (al instante)" : ", avance visto: \(vistos.uniqued().joined(separator: " "))"))

        // 4. Desmontar → bloqueado → abrir con el llavero
        ok(Cifrado.desmontar(ruta), "Desmontado")
        ok(Cifrado.estado(uuid: uuid) == .bloqueado, "Desmontado queda bloqueado")
        ok(!Cifrado.desbloquear(uuid: uuid, clave: "clave-equivocada-00", puntoDeMontaje: ruta), "Con clave equivocada no abre")
        ok(Cifrado.estado(uuid: uuid) == .bloqueado, "Sigue bloqueado")
        ok(Cifrado.desbloquearConLlavero(uuid: uuid, puntoDeMontaje: ruta), "Abre solo con la clave del llavero")
        ok(Cifrado.estado(uuid: uuid) == .cifrado, "Abierto: cifrado")
        ok((try? String(contentsOfFile: prueba, encoding: .utf8)) == "hola desde antes de cifrar", "Los datos siguen ahí")
        ok(!Cifrado.desbloquearConLlavero(uuid: uuid), "Si ya está abierto, no hace nada")

        // 5. Ocultarlo y mostrarlo como en casa. Antes del arreglo del 25/10/2026, desmontar para ocultarlo lo dejaba
        // cerrado y sin montar (el portátil enchufado parecía desconectado).
        let v = Volumen(url: URL(fileURLWithPath: ruta), nombre: nombre, uuid: uuid, externo: true, capacidad: 0, libre: 0,
                        formato: "", visible: true, sistema: "apfs")
        ok(!Discos.remontar(v, oculto: true, clave: nil) && montaje(uuid)?.ruta == ruta, "Sin la clave no lo toca: sigue abierto")
        ok(Discos.remontar(v, oculto: true, clave: clave), "Ocultarlo con la clave: se vuelve a abrir")
        let oculto = montaje(uuid)
        ok(oculto?.oculto == true && Cifrado.estado(uuid: uuid) == .cifrado, "Queda montado, abierto y oculto")
        let leido = oculto.flatMap { try? String(contentsOfFile: $0.ruta + "/prueba.txt", encoding: .utf8) }
        ok(leido == "hola desde antes de cifrar", "Oculto, los datos se leen igual")
        if let o = oculto {
            let v2 = Volumen(url: URL(fileURLWithPath: o.ruta), nombre: nombre, uuid: uuid, externo: true, capacidad: 0, libre: 0,
                             formato: "", visible: false, sistema: "apfs")
            ok(Discos.remontar(v2, oculto: false, clave: clave) && montaje(uuid)?.oculto == false, "Mostrarlo otra vez (afuera): visible y abierto")
        }
        if let m = montaje(uuid) { ok(Cifrado.desmontar(m.ruta), "Desmontado otra vez (como al desenchufarlo)") }
        ok(Cifrado.abrir(uuid: uuid, clave: clave, oculto: true), "Al enchufarlo en casa se abre directamente oculto")
        ok(montaje(uuid)?.oculto == true && Cifrado.estado(uuid: uuid) == .cifrado, "Abierto y oculto, sin desmontar nada")

        // 6. Borrar la clave
        ok(Llavero.borrar(uuid) && Llavero.leer(uuid) == nil, "Clave borrada del llavero")
        print(fallas == 0 ? "Todo bien." : "\(fallas) fallas.")
        return fallas == 0
    }

    /// Dónde está montado ese volumen ahora y si está oculto del Finder (nil = sin montar).
    private static func montaje(_ uuid: String) -> (ruta: String, oculto: Bool)? {
        guard let m = Cifrado.info(uuid)?["MountPoint"] as? String, !m.isEmpty else { return nil }
        let visible = (try? URL(fileURLWithPath: m).resourceValues(forKeys: [.volumeIsBrowsableKey]))?.volumeIsBrowsable
        return (m, visible == false)
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var vistos = Set<Element>()
        return filter { vistos.insert($0).inserted }
    }
}
