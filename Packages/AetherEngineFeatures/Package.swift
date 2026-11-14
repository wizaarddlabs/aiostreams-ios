// swift-tools-version: 6.1

import PackageDescription

// AetherEngine with its optional components turned on, re-exported for the apps. XcodeGen can't set
// a package's traits, so the apps depend on this package instead, the way AetherEngine's docs suggest
// (docs/installation.md, "Optional components").
//
// The default build, and the one public releases use. Packages/AetherEngineHeights is the same with
// TrueHD Atmos and DTS:X height channels added, chosen with HEIGHT_CHANNELS=on (scripts/make-ipa.sh).
//
// - DolbyVisionFelCurves: the curve fold. A Profile 7 FEL source's enhancement layer is folded into the
//   Profile 8.1 RPU on the native route, leaving every evaluation of the mapping to Apple's licensed
//   decoder; on whenever built in.
//
// DualLayerDolbyVision, the engine's own FEL composer, stays off on purpose: it evaluates the RPU's
// MMR prediction and the enhancement layer itself, steps covered by live Dolby patents, and the engine
// recommends the curve fold over it for any distributed app.
//
// These components may be subject to third-party patent licensing; whoever builds and distributes the
// app with them is responsible for their own licensing.
let package = Package(
    name: "AetherEngineFeatures",
    platforms: [
        .iOS(.v18),
        .tvOS(.v18),
    ],
    products: [
        .library(name: "AetherEngineFeatures", targets: ["AetherEngineFeatures"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/superuser404notfound/AetherEngine",
            exact: "7.67.0",
            traits: ["DolbyVisionFelCurves"]
        ),
    ],
    targets: [
        .target(
            name: "AetherEngineFeatures",
            dependencies: [.product(name: "AetherEngine", package: "AetherEngine")]
        ),
    ]
)
