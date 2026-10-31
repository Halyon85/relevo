// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Relevo",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Actualizaciones de las versiones publicadas (ver docs/PUBLICAR.md). Solo la usa la app, no el motor.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        // El motor: escanear, comparar con la última sincronización y copiar sin romper nada. Sin dependencias.
        .target(
            name: "RelevoNucleo",
            path: "Sources/RelevoNucleo"
        ),
        // La app de la barra de menú (y las órdenes de terminal para probar).
        .executableTarget(
            name: "Relevo",
            dependencies: ["RelevoNucleo", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Relevo",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("DiskArbitration"),
                .linkedFramework("CoreServices"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        // Pruebas del motor (sin Xcode): `swift run RelevoPruebas`.
        .executableTarget(
            name: "RelevoPruebas",
            dependencies: ["RelevoNucleo"],
            path: "Sources/RelevoPruebas"
        ),
    ],
    swiftLanguageModes: [.v5]
)
