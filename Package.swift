// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DTVideoQueue",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DTVideoQueue", targets: ["DTVideoQueue"])],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift.git", exact: "1.26.2"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.1.4")
    ],
    targets: [
        .target(name: "FPZip", path: "Vendors/fpzip-1.3.0", sources: ["src/error.cpp", "src/rcdecoder.cpp", "src/rcencoder.cpp", "src/rcqsmodel.cpp", "src/read.cpp", "src/version.cpp", "src/write.cpp"], publicHeadersPath: "include",
                cxxSettings: [.define("FPZIP_FP", to: "FPZIP_FP_FAST"), .define("FPZIP_BLOCK_SIZE", to: "0x1000")]),
        .executableTarget(name: "DTVideoQueue", dependencies: [
            "FPZip", .product(name: "GRPC", package: "grpc-swift"),
            .product(name: "NIO", package: "swift-nio"), .product(name: "NIOSSL", package: "swift-nio-ssl")
        ], path: "Sources/DTVideoQueue", resources: [.copy("Resources/root_ca.crt")]),
        .testTarget(name: "DTVideoQueueTests", dependencies: ["DTVideoQueue", "FPZip"])
    ],
    cxxLanguageStandard: .cxx11
)
