import Foundation
import RelevoNucleo

/// Órdenes de terminal para probar el motor sin la interfaz.
///   Relevo --medir <carpeta>                                      cuánto tarda en fotografiar una carpeta
///   Relevo --quien-usa <disco>                                     quién usa un disco (solo mira)
///   Relevo --marca <carpeta> · --cambios <carpeta> <registro> <evento>   registro de cambios de macOS (solo mira)
///   Relevo --sincronizar <disco hub> <disco portátil> <carpeta> [--si] [--estado <carpeta>] [--zonas <c1,c2…>]
///          (--zonas: mirar solo esas carpetas, como si macOS hubiera avisado cambios ahí; "" = la raíz)
enum Terminal {
    static func correr(_ args: [String]) -> Bool {
        if let i = args.firstIndex(of: "--medir"), i + 1 < args.count {
            medir(args[i + 1])
            return true
        }
        if let i = args.firstIndex(of: "--marcar-discos"), i + 2 < args.count {
            print("hub: \(MarcaDisco.poner(args[i + 1], hub: true) ? "listo" : "no se pudo")")
            print("portátil: \(MarcaDisco.poner(args[i + 2], hub: false) ? "listo" : "no se pudo")")
            return true
        }
        if let i = args.firstIndex(of: "--marca"), i + 1 < args.count {
            // Hasta dónde llega el registro de cambios del disco (solo mira).
            if let m = Historia.marca(args[i + 1]) { print("\(m.registro) \(m.evento)") } else { print("sin registro") }
            return true
        }
        if let i = args.firstIndex(of: "--cambios"), i + 3 < args.count, let evento = UInt64(args[i + 3]) {
            // Qué carpetas cambiaron desde una marca (solo mira). "todo" = no se puede saber: habría que revisar todo.
            if let c = Historia.cambios(desde: .init(registro: args[i + 2], evento: evento), en: args[i + 1]) {
                c.carpetas.sorted().forEach { print(c.enteras.contains($0) ? $0 + " (entera)" : $0) }
            } else { print("todo") }
            return true
        }
        if let i = args.firstIndex(of: "--quien-usa"), i + 1 < args.count {
            // Solo mira (no cierra nada): quién usa un disco y qué haría Relevo al expulsarlo.
            for g in Procesos.usando(args[i + 1]).grupos {
                let que = !g.cerrable ? "no se cierra desde Relevo" : (g.deFondo ? "de fondo: se cierra solo" : "con ventana: se ofrece cerrar")
                print("\(g.app) · \(g.pids.count) proceso(s) · \(g.carpetas.sorted().joined(separator: ", ")) · \(que)")
            }
            return true
        }
        if let i = args.firstIndex(of: "--explicar"), i + 1 < args.count {
            explicar(args[i + 1])
            return true
        }
        if let i = args.firstIndex(of: "--vista-previa"), i + 3 < args.count {
            vistaPrevia(hub: args[i + 1], portatil: args[i + 2], carpetas: Array(args[(i + 3)...]))
            return true
        }
        if let i = args.firstIndex(of: "--sincronizar"), i + 3 < args.count {
            var estado = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Relevo/pruebas")
            if let j = args.firstIndex(of: "--estado"), j + 1 < args.count { estado = URL(fileURLWithPath: args[j + 1]) }
            var zonas: Zonas?
            if let j = args.firstIndex(of: "--zonas"), j + 1 < args.count {
                zonas = Zonas(planas: Set(args[j + 1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)))
            }
            sincronizar(hub: args[i + 1], portatil: args[i + 2], carpeta: args[i + 3], estado: estado,
                        confirmado: args.contains("--si"), zonas: zonas)
            return true
        }
        return false
    }

    static func medir(_ carpeta: String) {
        let s = Sincronizador(volumenHub: carpeta, volumenPortatil: carpeta,
                              estado: URL(fileURLWithPath: NSTemporaryDirectory() + "relevo-medir"))
        for vuelta in 1...2 {
            let t = Date()
            guard let a = try? s.analizar("") else { print("No se pudo leer \(carpeta)"); return }
            print("vuelta \(vuelta): \(a.hub.archivos) archivos, \(formato(a.hub.bytes)), \(a.hub.entradas.count) rutas, "
                  + String(format: "%.2f s (dos fotos en paralelo)", Date().timeIntervalSince(t)))
        }
    }

    /// Con la configuración y la base reales del primer vínculo: qué haría con una carpeta y por qué. Solo mira.
    static func explicar(_ carpeta: String) {
        guard let v = Ajustes.shared.datos.vinculos.first, let h = v.hub.raiz(), let p = v.portatil.raiz() else {
            print("No están los dos lados del vínculo"); return
        }
        let s = Sincronizador(volumenHub: h, volumenPortatil: p, reglas: Ajustes.shared.reglas, estado: Ajustes.carpetaEstado(v.id))
        guard let a = try? s.analizar(carpeta) else { print("No se pudo analizar"); return }
        let r = a.plan.resumen
        print("alertas: \(a.alertas)")
        print("→ portátil \(r.haciaPortatil)  → hub \(r.haciaHub)  papelera hub \(r.aPapeleraHub)  papelera portátil \(r.aPapeleraPortatil)")
        for paso in a.plan.borrar.prefix(40) {
            let enHub = a.hub.entradas[paso.ruta] != nil, enPort = a.portatil.entradas[paso.ruta] != nil
            print("papelera en \(paso.lado.nombre): \(paso.ruta)  (en hub: \(enHub), en portátil: \(enPort))")
        }
        for paso in a.plan.copias.prefix(10) { print("copiar → \(paso.lado.nombre): \(paso.ruta)") }
    }

    /// Solo mira: no escribe nada en ningún disco.
    static func vistaPrevia(hub: String, portatil: String, carpetas: [String]) {
        let s = Sincronizador(volumenHub: hub, volumenPortatil: portatil,
                              estado: URL(fileURLWithPath: NSTemporaryDirectory() + "relevo-vista-previa-" + UUID().uuidString))
        var archivos = 0, bytes: Int64 = 0, conflictos = 0
        let t = Date()
        for c in carpetas {
            guard let a = try? s.analizar(c) else { print("  ✗ \(c): no se pudo leer"); continue }
            let r = a.plan.resumen
            archivos += r.haciaPortatil + r.haciaHub
            bytes += r.bytesHaciaPortatil + r.bytesHaciaHub
            conflictos += r.conflictos.count
            let alertas = a.alertas.isEmpty ? "" : "  ⚠︎ \(a.alertas)"
            print(String(format: "  %-40@ → portátil %6d (%@)  → hub %d%@", c as NSString, r.haciaPortatil,
                         formato(r.bytesHaciaPortatil) as NSString, r.haciaHub, alertas as NSString))
        }
        print("TOTAL: \(archivos) archivos, \(formato(bytes)), \(conflictos) conflictos. Análisis en " + String(format: "%.1f s", Date().timeIntervalSince(t)))
    }

    static func sincronizar(hub: String, portatil: String, carpeta: String, estado: URL, confirmado: Bool, zonas: Zonas?) {
        let s = Sincronizador(volumenHub: hub, volumenPortatil: portatil, estado: estado)
        let a: Analisis
        do { a = try s.analizar(carpeta, zonas: zonas) } catch { print("No se pudo analizar: \(error)"); exit(2) }
        let r = a.plan.resumen
        print(String(format: "Análisis %@en %.2f s (%d rutas)", a.porZonas ? "por zonas " : "", a.duracion, a.hub.entradas.count))
        print("  → portátil: \(r.haciaPortatil) (\(formato(r.bytesHaciaPortatil)))   → hub: \(r.haciaHub) (\(formato(r.bytesHaciaHub)))")
        print("  a la papelera: hub \(r.aPapeleraHub), portátil \(r.aPapeleraPortatil)   conflictos: \(r.conflictos.count)   a reparar: \(a.reparar)")
        for alerta in a.alertas { print("  ⚠︎ \(alerta)") }
        if a.plan.vacio && !a.plan.soloAnotar {
            if a.baseActualizada { try? s.guardarBase(a) }
            print("Todo al día.")
            return
        }

        var ultimo = Date.distantPast
        let res = s.ejecutar(a, confirmado: confirmado) { p in
            guard Date().timeIntervalSince(ultimo) > 0.5 else { return }
            ultimo = Date()
            print("  \(p.hechos)/\(p.total)  \(formato(p.bytesHechos))/\(formato(p.bytesTotal))")
        }
        print(String(format: "Listo en %.2f s: ", res.duracion)
              + "\(res.copiados) copiados (\(formato(res.bytes))), \(res.carpetas) carpetas, \(res.aPapelera) a la papelera, "
              + "\(res.conflictos.count) conflictos, \(res.pendientes) pendientes")
        if let d = res.desconectado { print("  ⚠︎ Se desconectó el \(d.nombre)") }
        if res.cancelado { print("  ⚠︎ Cancelado (si hay alertas, repetir con --si)") }
        for p in res.problemas.prefix(10) { print("  ✗ \(p.ruta): \(p.detalle)") }
        exit(res.completo ? 0 : 1)
    }

    static func formato(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
