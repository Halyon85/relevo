import Foundation
@testable import RelevoNucleo

/// Pruebas de cuándo corre la revisión completa de fondo (`RevisionDeFondo.toca`). El caso del 17/11/2026: una
/// carpeta esperaba el OK con copias pendientes, ninguna revisión "cerraba bien" y se repetía cada media hora.
extension Escenarios {
    static let deFondo: [(String, () throws -> Void)] = [
        ("De fondo: una revisión que recorrió todo sin cerrar no se repite cada media hora", { Escenarios().sinCerrarNoSeRepite() }),
        ("De fondo: la de cada día y la de la vuelta siguen corriendo cuando toca", { Escenarios().deFondoCuandoToca() }),
    ]

    private static let hora: TimeInterval = 3600

    func sinCerrarNoSeRepite() {
        let h = Escenarios.hora
        // Dos días sin una que cierre bien, y la última que recorrió todo fue hace media hora: no toca, ni de
        // madrugada ni con la Mac sin uso.
        for (reloj, inactiva) in [(3, 0.0), (15, 2 * h), (0, 8 * h)] {
            espero(!RevisionDeFondo.toca(alVolver: false, desdeLaUltimaBien: 48 * h, desdeElUltimoIntento: 0.5 * h,
                                         hora: reloj, inactiva: inactiva))
        }
        // Al otro día sí se vuelve a intentar.
        espero(RevisionDeFondo.toca(alVolver: false, desdeLaUltimaBien: 72 * h, desdeElUltimoIntento: 21 * h,
                                    hora: 3, inactiva: 0))
    }

    func deFondoCuandoToca() {
        let h = Escenarios.hora
        let nunca = TimeInterval.infinity
        // La de cada día: pasadas 20 horas, de madrugada o con la Mac sin uso; no mientras la estás usando de día.
        espero(RevisionDeFondo.toca(alVolver: false, desdeLaUltimaBien: 21 * h, desdeElUltimoIntento: nunca, hora: 3, inactiva: 0))
        espero(RevisionDeFondo.toca(alVolver: false, desdeLaUltimaBien: 21 * h, desdeElUltimoIntento: nunca, hora: 15, inactiva: 0.5 * h))
        espero(!RevisionDeFondo.toca(alVolver: false, desdeLaUltimaBien: 21 * h, desdeElUltimoIntento: nunca, hora: 15, inactiva: 60))
        espero(!RevisionDeFondo.toca(alVolver: false, desdeLaUltimaBien: 5 * h, desdeElUltimoIntento: nunca, hora: 3, inactiva: h))
        // Nunca hubo ninguna: toca.
        espero(RevisionDeFondo.toca(alVolver: false, desdeLaUltimaBien: nunca, desdeElUltimoIntento: nunca, hora: 3, inactiva: 0))
        // La de la vuelta con el portátil corre aunque haya un intento reciente sin cerrar (cubre lo que macOS no anota).
        espero(RevisionDeFondo.toca(alVolver: true, desdeLaUltimaBien: 48 * h, desdeElUltimoIntento: 60, hora: 15, inactiva: 0))
        espero(!RevisionDeFondo.toca(alVolver: true, desdeLaUltimaBien: 600, desdeElUltimoIntento: nunca, hora: 15, inactiva: 0))
    }
}
