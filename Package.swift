// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DevOnCall",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DevOnCall", targets: ["DevOnCallApp"]),
        .executable(name: "dev-on-call", targets: ["DevOnCallCLI"]),
        .executable(name: "dev-on-call-self-test", targets: ["DevOnCallSelfTest"])
    ],
    targets: [
        .target(name: "DevOnCallCore"),
        .target(name: "DevOnCallAWS"),
        .executableTarget(
            name: "DevOnCallApp",
            dependencies: ["DevOnCallCore", "DevOnCallAWS"]
        ),
        .executableTarget(
            name: "DevOnCallCLI",
            dependencies: ["DevOnCallCore"]
        ),
        .executableTarget(
            name: "DevOnCallSelfTest",
            dependencies: ["DevOnCallCore", "DevOnCallAWS"]
        )
    ]
)
