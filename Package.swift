// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Modafinil",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Modafinil", targets: ["Modafinil"]),
        .executable(name: "ModafinilHelper", targets: ["ModafinilHelper"])
    ],
    targets: [
        .target(
            name: "ModafinilShared"
        ),
        .executableTarget(
            name: "Modafinil",
            dependencies: ["ModafinilShared"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "ModafinilHelper",
            dependencies: ["ModafinilShared"]
        )
    ]
)
