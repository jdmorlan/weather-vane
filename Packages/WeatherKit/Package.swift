// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WeatherKit",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17)],
    products: [
        .library(name: "WeatherKit", targets: ["WeatherKit"]),
    ],
    targets: [
        // Pure weather-interpretation domain logic: a Tempest forecast → plain-language
        // answers ("muggy", "brief sprinkle at 2pm", "pressure falling, unsettled"). The
        // networking client lives here too, but the INTERPRETATION is dependency-free and
        // verifiable on its own — the reason it's a kit, not view code. No UI.
        .target(name: "WeatherKit", dependencies: ["RadarKernel"],
                // County outlines for the map. See `CountyBoundaries`.
                resources: [.copy("Resources/census-counties-5m.json.gz")]),
        // The Level II decoder and tile renderer, split out for ONE reason: to be
        // compiled optimised even in Debug. Their inner loops run a quarter of a
        // million times per tile, and unoptimised they went through Swift's
        // generic runtime on every pixel — measured in the running Debug app, no
        // tile finished in 85 seconds with ten cores busy. Everything else in
        // WeatherKit stays at -Onone and steps normally in the debugger.
        .target(name: "RadarKernel", dependencies: ["CBzip2"],
                swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        // libbz2 from the SDK, for NEXRAD Level II. A system library rather than a
        // vendored copy: every platform the app ships on already has it.
        .systemLibrary(name: "CBzip2"),
        .testTarget(name: "WeatherKitTests", dependencies: ["WeatherKit", "RadarKernel"],
                    // Real Level II bytes: the first two records of a KFWS volume.
                    resources: [.copy("Fixtures")]),
    ]
)
