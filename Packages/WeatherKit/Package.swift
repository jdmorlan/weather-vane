// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WeatherKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "WeatherKit", targets: ["WeatherKit"]),
    ],
    targets: [
        // Pure weather-interpretation domain logic: a Tempest forecast → plain-language
        // answers ("muggy", "brief sprinkle at 2pm", "pressure falling, unsettled"). The
        // networking client lives here too, but the INTERPRETATION is dependency-free and
        // verifiable on its own — the reason it's a kit, not view code. No UI.
        .target(name: "WeatherKit"),
        .testTarget(name: "WeatherKitTests", dependencies: ["WeatherKit"]),
    ]
)
