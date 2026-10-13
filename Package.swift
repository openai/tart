// swift-tools-version:5.10

import PackageDescription
let package = Package(
  name: "Tart",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .executable(name: "tart", targets: ["tart"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.6.1"),
    .package(url: "https://github.com/mhdhejazi/Dynamic", branch: "master"),
    .package(url: "https://github.com/apple/swift-algorithms", from: "1.2.0"),
    .package(url: "https://github.com/malcommac/SwiftDate", from: "7.0.0"),
    .package(url: "https://github.com/antlr/antlr4", exact: "4.13.2"),
    .package(url: "https://github.com/apple/swift-atomics.git", .upToNextMajor(from: "1.2.0")),
    .package(url: "https://github.com/nicklockwood/SwiftFormat", from: "0.53.6"),
    .package(url: "https://github.com/cfilipov/TextTable", branch: "master"),
    .package(url: "https://github.com/sersoft-gmbh/swift-sysctl.git", from: "1.8.0"),
    .package(url: "https://github.com/orchetect/SwiftRadix", from: "1.3.1"),
    .package(url: "https://github.com/groue/Semaphore", from: "0.0.8"),
    .package(url: "https://github.com/fumoboy007/swift-retry", from: "0.2.3"),
    .package(url: "https://github.com/jozefizso/swift-xattr", from: "3.0.0"),
    .package(url: "https://github.com/grpc/grpc-swift.git", .upToNextMajor(from: "1.27.0")),
    .package(url: "https://buf.build/gen/swift/git/1.27.1-20260114140118-bd09c26a260f.1/cirruslabs_tart-guest-agent_grpc_swift.git", branch: "main"),
    .package(url: "https://github.com/open-telemetry/opentelemetry-swift", branch: "main"),
    .package(url: "https://github.com/open-telemetry/opentelemetry-swift-core", from: "2.3.0"),

  ],
  targets: [
    .target(
      name: "TartCoreFoundationShim",
      path: "Sources/TartCoreFoundationShim",
      publicHeadersPath: "include",
      linkerSettings: [.linkedFramework("CoreFoundation")]
    ),
    .executableTarget(name: "tart", dependencies: [
      "TartCoreFoundationShim",
      .product(name: "Algorithms", package: "swift-algorithms"),
      .product(name: "ArgumentParser", package: "swift-argument-parser"),
      .product(name: "Dynamic", package: "Dynamic"),
      .product(name: "SwiftDate", package: "SwiftDate"),
      .product(name: "Antlr4Static", package: "Antlr4"),
      .product(name: "Atomics", package: "swift-atomics"),
      .product(name: "TextTable", package: "TextTable"),
      .product(name: "Sysctl", package: "swift-sysctl"),
      .product(name: "SwiftRadix", package: "SwiftRadix"),
      .product(name: "Semaphore", package: "Semaphore"),
      .product(name: "DMRetry", package: "swift-retry"),
      .product(name: "XAttr", package: "swift-xattr"),
      .product(name: "GRPC", package: "grpc-swift"),
      .product(name: "Cirruslabs_TartGuestAgent_Grpc_Swift", package: "cirruslabs_tart-guest-agent_grpc_swift"),
      .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
      .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
      .product(name: "OpenTelemetryProtocolExporterHTTP", package: "opentelemetry-swift"),
      .product(name: "ResourceExtension", package: "opentelemetry-swift"),
    ], exclude: [
      "OCI/Reference/Makefile",
      "OCI/Reference/Reference.g4",
      "OCI/Reference/Generated/Reference.interp",
      "OCI/Reference/Generated/Reference.tokens",
      "OCI/Reference/Generated/ReferenceLexer.interp",
      "OCI/Reference/Generated/ReferenceLexer.tokens",
    ]),
    .testTarget(name: "TartTests", dependencies: ["tart"])
  ]
)
