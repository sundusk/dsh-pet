// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DSHPet",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "DSHPet",
            path: "Sources/DSHPet"
        ),
        .testTarget(
            name: "DSHPetTests",
            dependencies: ["DSHPet"],
            path: "tests/DSHPetTests"
        ),
    ]
)
