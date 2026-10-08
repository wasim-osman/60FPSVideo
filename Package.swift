// swift-tools-version: 6.0
import PackageDescription

// Minimum macOS 15.4: that is where VTFrameRateConversionConfiguration landed, so
// everything works from there. macOS 26 additionally gives the low-latency path for
// 29.97->59.94, but film-rate sources (the primary content) gain nothing from it, so
// it is gated behind a runtime availability check rather than a higher floor.
// See BUILD-DECISIONS.md §9.
let package = Package(
    name: "Interpolator",
    platforms: [.macOS("15.4")],
    products: [
        .library(name: "Interpolator", targets: ["Interpolator"]),
        .executable(name: "interp-harness", targets: ["interp-harness"]),
    ],
    targets: [
        .target(name: "Interpolator"),
        .executableTarget(name: "interp-harness", dependencies: ["Interpolator"]),
        .testTarget(name: "InterpolatorTests", dependencies: ["Interpolator"]),
    ]
)
