//
//  WeatherUpperAirViews.swift  (macOS)
//
//  The 500 mb pattern reader. All of the reading — detrending, the wave profile,
//  ridges, troughs, which side of the trough you're on — lives in WeatherKit's
//  `UpperAir.swift`. This file draws it; `PatternPlaybar`, at the bottom,
//  is the transport, pinned to the surface rather than scrolling with the page.
//
//  NO MAP, DELIBERATELY. The wave is shown straightened out: longitude along the
//  bottom, departure from the latitude's mean up the side. Picking a trough out of
//  curved contours over a basemap is the hard part this surface exists to remove.
//
//  STALE IS NEVER SILENT. A run that couldn't be confirmed as the newest is not
//  drawn as though it were: a failure shows the failure, and an older stored run
//  is offered behind a button that names which run it is.
//

import SwiftUI
import Combine
import WeatherKit

@MainActor
final class UpperAirModel: ObservableObject {
    @Published private(set) var run: UpperAirRun?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    /// A stored run held back after a failure. Shown only when asked for.
    @Published private(set) var fallback: UpperAirRun?
    /// Whether `run` is that held-back run, adopted on request.
    @Published private(set) var showingFallback = false
    @Published var frameIndex = 0
    @Published var reference: WaveReference = .zonal

    /// The last valid frame index, or 0 when there is no run.
    var lastFrame: Int { max((run?.frames.count ?? 1) - 1, 0) }

    /// Move the playhead, clamped. ON THE MODEL because the page's arrow keys and
    /// the floating playbar's buttons are now separate views driving one
    /// playhead, and two copies of a clamp is how one of them ends up off by one.
    func go(to index: Int) { frameIndex = min(max(index, 0), lastFrame) }
    func step(_ delta: Int) { go(to: frameIndex + delta) }

    /// The window. Configurable here rather than in Settings: one grid serves the
    /// question, and a panel of bounds would be a control that never changes.
    let grid = UpperAirGrid.conus

    /// Kept, one file per run, beside the forecast log and the archive.
    private let store = UpperAirStore(root: AppGroup.dataDirectory
        .appendingPathComponent("Weather", isDirectory: true)
        .appendingPathComponent("upper-air", isDirectory: true))

    /// Once a new run COULD exist, Open-Meteo's metadata is asked at most this
    /// often. It's a tiny file, but reopening the tab is not a reason to ask again.
    static let checkInterval: TimeInterval = 15 * 60
    private var lastCheck: Date?

    var frame: UpperAirFrame? {
        guard let run, run.frames.indices.contains(frameIndex) else { return nil }
        return run.frames[frameIndex]
    }

    func load(home: GeoPoint?, force: Bool = false) async {
        guard !isLoading else { return }

        if let run, !run.covers(grid: grid, home: home) { self.run = nil }
        if run == nil {
            let store = self.store, grid = self.grid
            if let cached = await Task.detached(priority: .utility, operation: {
                store.latest(covering: grid, home: home)
            }).value {
                adopt(cached)
            }
        }

        // NOT DUE: the newest run we hold is the newest that can exist yet.
        let now = Date()
        if !force, let run, !showingFallback {
            if now < run.nextRunPossible { return }
            if let lastCheck, now.timeIntervalSince(lastCheck) < Self.checkInterval { return }
        }

        isLoading = true
        defer { isLoading = false }
        lastCheck = now
        let client = UpperAirClient(grid: grid, home: home)
        do {
            let latest = try await client.latestRun()
            if let run, run.initialized >= latest {
                error = nil; fallback = nil; showingFallback = false
                return
            }
            let fresh = try await client.fetch(initialized: latest)
            let store = self.store
            await Task.detached(priority: .utility) { try? store.save(fresh) }.value
            adopt(fresh)
            error = nil; fallback = nil; showingFallback = false
        } catch {
            // What we hold can no longer be called current, so it stops being
            // drawn as though it were — it moves behind the "show older run" button.
            if let run { fallback = run }
            run = nil
            showingFallback = false
            self.error = (error as? UpperAirClient.Failure)?.errorDescription ?? error.localizedDescription
        }
    }

    func showFallback() {
        guard let fallback else { return }
        adopt(fallback)
        showingFallback = true
        self.fallback = nil
    }

    /// Stay on the same VALID TIME across runs, so a new run arriving while you're
    /// looking at Thursday keeps showing Thursday.
    private func adopt(_ new: UpperAirRun) {
        let valid = frame?.valid
        run = new
        frameIndex = valid.flatMap { v in new.frames.firstIndex { $0.valid == v } } ?? 0
    }
}

// MARK: - Palette

/// Blue for troughing, orange for ridging — one ramp shared by the chart's fill
/// and the table, so the two can't disagree about which is which.
enum PatternColor {
    static let troughRGB = (r: 0.10, g: 0.34, b: 0.72)
    static let ridgeRGB = (r: 0.91, g: 0.50, b: 0.12)
    static let trough = Color(red: troughRGB.r, green: troughRGB.g, blue: troughRGB.b)
    static let ridge = Color(red: ridgeRGB.r, green: ridgeRGB.g, blue: ridgeRGB.b)

    /// Full colour at this many dam from the mean.
    static let saturation = 12.0

    static func opacity(_ deviation: Double) -> Double {
        min(abs(deviation) / saturation, 1) * 0.9
    }

    static func fill(_ deviation: Double) -> Color {
        (deviation < 0 ? trough : ridge).opacity(opacity(deviation))
    }

    /// Black or white, whichever contrasts more with the fill AS COMPOSITED over
    /// the card. A fixed rule ("white on strong colour") fails on orange, which is
    /// light even at full strength.
    static func text(_ deviation: Double, scheme: ColorScheme) -> Color {
        let ground = scheme == .dark ? 0.15 : 0.96
        let rgb = deviation < 0 ? troughRGB : ridgeRGB
        let a = opacity(deviation)
        func linear(_ c: Double) -> Double {
            let v = c * a + ground * (1 - a)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(rgb.r) + 0.7152 * linear(rgb.g) + 0.0722 * linear(rgb.b)
        return 1.05 / (luminance + 0.05) > (luminance + 0.05) / 0.05 ? .white : .black
    }
}

// MARK: - Formatting

enum PatternFormat {
    static func longitude(_ lon: Double) -> String {
        "\(Int(abs(lon).rounded()))°\(lon < 0 ? "W" : "E")"
    }

    static func latitude(_ lat: Double) -> String {
        let text = lat.rounded() == lat ? "\(Int(lat))" : String(format: "%.1f", abs(lat))
        return "\(text)°\(lat < 0 ? "S" : "N")"
    }

    static func signed(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return rounded > 0 ? "+\(rounded)" : rounded < 0 ? "−\(abs(rounded))" : "0"
    }

    private static func utc(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = format
        return f
    }
    static let day = utc("EEE MMM d")
    static let cycle = utc("HH'Z' EEE MMM d")

    /// "Tue Sep 15 12Z"
    static func valid(_ date: Date) -> String { "\(day.string(from: date)) 12Z" }

    /// "f048"
    static func hour(_ h: Int) -> String { String(format: "f%03d", h) }
}

// MARK: - The reader

struct UpperAirPatternView: View {
    @ObservedObject var model: UpperAirModel
    let home: GeoPoint?
    /// Owned by `UpperAirSurface`, because the playbar it drives is now pinned to
    /// the surface rather than scrolling away inside this page. Declared before
    /// `retry` so the memberwise init keeps the trailing closure last.
    @Binding var playing: Bool
    let retry: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: Control?
    /// Only the page now. The play button and slider hold their own focus inside
    /// `PatternPlaybar`, which is no longer part of this view's focus chain.
    private enum Control { case page }

    var body: some View {
        if let run = model.run, let frame = model.frame {
            loaded(run, frame)
        } else if model.isLoading {
            section("500 mb pattern") {
                ProgressView("Reading the GFS…").frame(maxWidth: .infinity, minHeight: 120)
            }
        } else if let error = model.error {
            failure(error)
        } else {
            section("500 mb pattern") {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
        }
    }

    // MARK: Failure

    private func failure(_ message: String) -> some View {
        section("500 mb pattern") {
            VStack(alignment: .leading, spacing: 10) {
                Label("The upper-air data couldn’t load", systemImage: "exclamationmark.icloud")
                    .font(.headline)
                Text(message).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Retry", action: retry)
                    if let older = model.fallback {
                        Button("Show the older \(PatternFormat.cycle.string(from: older.initialized)) run") {
                            model.showFallback()
                        }
                        .help("Stored from an earlier fetch. The pattern may have moved since.")
                    }
                }
            }
        }
    }

    // MARK: Loaded

    @ViewBuilder private func loaded(_ run: UpperAirRun, _ frame: UpperAirFrame) -> some View {
        // Every frame analysed once per render: the time chart, its tracks and the
        // fixed vertical scale all need the whole run, and it's 16 × 72 cells.
        let analyses = run.frames.map {
            WavePattern.analyze($0.field, grid: run.grid, reference: model.reference, home: home)
        }
        let analysis = analyses[model.frameIndex]
        let referenceName = model.reference == .zonal ? "whole-latitude" : "US"

        VStack(alignment: .leading, spacing: 18) {
            section("500 mb pattern") {
                VStack(alignment: .leading, spacing: 14) {
                    header(run, frame)
                    if model.showingFallback {
                        Label("Showing an older stored run — Open-Meteo couldn’t be reached to check for a newer one.",
                              systemImage: "clock.badge.exclamationmark")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
            }

            section("Where you sit in the wave") {
                HStack(alignment: .top, spacing: 28) {
                    UpperAirReadout(analysis: analysis, field: frame.field, home: home, grid: run.grid)
                    if let home, let height = frame.field.home {
                        AirColumnView(height: height,
                                      mean: WavePattern.referenceMean(atLatitude: home.latitude, field: frame.field,
                                                                      grid: run.grid, reference: model.reference),
                                      meanLabel: "\(model.reference == .zonal ? "avg around" : "US avg at") \(PatternFormat.latitude(home.latitude))",
                                      thickness: frame.field.homeThickness)
                            .frame(width: 270)
                    }
                }
            }

            section("The wave · \(bandLabel(run.grid)) · dam from the \(referenceName) mean") {
                VStack(alignment: .leading, spacing: 10) {
                    ZStack {
                        WaveProfileChart(longitudes: run.grid.longitudes, profile: analysis.profile,
                                         features: analysis.features,
                                         homeLongitude: home?.longitude, extent: chartExtent(analyses))
                            .id(model.frameIndex)
                            .transition(.opacity)
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.frameIndex)
                    Text("Each point averages \(bandLabel(run.grid)), where the jet runs. Ridges and troughs are named when they stand at least \(String(format: "%.1f", WavePattern.reliefThreshold)) dam above or below the wave on both sides.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            section("The wave over time · \(bandLabel(run.grid))") {
                WaveTimeChart(longitudes: run.grid.longitudes,
                              days: run.frames.map(\.valid),
                              profiles: analyses.map(\.profile),
                              features: analyses.map(\.features),
                              selected: model.frameIndex,
                              homeLongitude: home?.longitude) {
                    playing = false
                    model.frameIndex = $0
                    focus = .page
                }
            }

            section("Heights · dam") {
                HeightTable(grid: run.grid, field: frame.field, deviations: analysis.deviations,
                            home: home, reference: model.reference)
            }

            Text("\(UpperAirClient.credit) · fetched \(run.fetched.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.tertiary)
        }
        // STEPPING IS THE PRIMARY WAY THROUGH THE DAYS; play is the secondary one.
        // So the keys belong to the page, not to a control you'd have to tab to.
        // A focused slider or play button still handles its own keys first.
        .focusable()
        .focused($focus, equals: .page)
        .focusEffectDisabled()
        .defaultFocus($focus, .page)
        .onAppear { focus = .page }
        // Stepping pauses playback: reaching for the arrows means you want to
        // hold a day, not fight the timer for it.
        .onKeyPress(.leftArrow) { playing = false; model.step(-1); return .handled }
        .onKeyPress(.rightArrow) { playing = false; model.step(+1); return .handled }
        .onKeyPress(.home) { playing = false; model.go(to: 0); return .handled }
        .onKeyPress(.end) { playing = false; model.go(to: model.lastFrame); return .handled }
        .onKeyPress(.space) { togglePlay(); return .handled }
        // A segmented picker eats ← and → itself — they'd flip the reference
        // instead of the day — so focus comes straight back after choosing one.
        .onChange(of: model.reference) { _, _ in focus = .page }
    }

    private func header(_ run: UpperAirRun, _ frame: UpperAirFrame) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Valid \(PatternFormat.valid(frame.valid))")
                    .font(.title3.weight(.semibold))
                Text("\(PatternFormat.hour(run.forecastHour(frame))) · \(run.model) run \(PatternFormat.cycle.string(from: run.initialized))")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Picker("Reference", selection: $model.reference) {
                ForEach(WaveReference.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)
            .help("What each row is compared against. Whole latitude is the standard. Switching moves the zero line — the colours and your deviation — but not which ridges and troughs are named, because those are found by relief.")
        }
    }

    private func togglePlay() {
        if !playing && model.frameIndex >= model.lastFrame { model.frameIndex = 0 }
        playing.toggle()
    }

    private func focusRing(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(Color.accentColor, lineWidth: 2)
            .padding(-3)
            .opacity(on ? 1 : 0)
    }

    // MARK: Helpers

    /// One fixed vertical scale for the whole run, so scrubbing shows the wave
    /// growing and shrinking instead of the axis silently rescaling under it.
    private func chartExtent(_ analyses: [WaveAnalysis]) -> Double {
        let peak = analyses.map { $0.profile.map(abs).max() ?? 0 }.max() ?? 0
        return max(12, ((peak * 1.4) / 4).rounded(.up) * 4)
    }

    private func bandLabel(_ grid: UpperAirGrid) -> String {
        "\(Int(grid.midLatitudes.lowerBound))–\(Int(grid.midLatitudes.upperBound))°N"
    }

    private func section<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(label.uppercased())
                .font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.07)))
    }
}

// MARK: - Readout

struct UpperAirReadout: View {
    let analysis: WaveAnalysis
    let field: HeightField
    let home: GeoPoint?
    let grid: UpperAirGrid

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let home, let position = analysis.position {
                let (title, detail) = Self.sentence(position, home: home, grid: grid)
                Text(title).font(.title2.weight(.semibold))
                Text(detail).font(.body)
                numbers(home)
            } else {
                Text("Set your home location in Settings to place yourself in the wave.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func numbers(_ home: GeoPoint) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let height = analysis.homeHeight, let deviation = analysis.homeDeviation {
                Text("Height here \(Int(height.rounded())) dam · \(PatternFormat.signed(deviation)) dam vs. the \(PatternFormat.latitude(home.latitude)) \(analysis.reference == .zonal ? "whole-latitude" : "US") mean")
            }
            if let wind = field.homeWind {
                Text("Wind at 500 mb over you: from the \(FlowVector.compass(wind.fromDegrees)) at \(Int(wind.speedMPH.rounded())) mph")
            }
            if let nearest = analysis.position?.nearest {
                let degrees = abs(nearest.longitude - home.longitude)
                let direction = nearest.longitude < home.longitude ? "west" : "east"
                Text("Nearest feature: \(nearest.kind == .ridge ? "ridge" : "trough") near \(PatternFormat.longitude(nearest.longitude)), \(Int(degrees.rounded()))° \(direction) · \(String(format: "%.1f", nearest.relief)) dam relief")
            }
            Text("The wave is read at \(Int(grid.midLatitudes.lowerBound))–\(Int(grid.midLatitudes.upperBound))°N, where the jet runs — the pattern upstream and north of \(PatternFormat.latitude(home.latitude)).")
        }
        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
    }

    /// Describes the PATTERN, not the weather it will bring.
    static func sentence(_ p: WavePosition, home: GeoPoint, grid: UpperAirGrid) -> (String, String) {
        func away(_ f: WaveFeature) -> String {
            let d = Int(abs(f.longitude - home.longitude).rounded())
            return "\(d)° to your \(f.longitude < home.longitude ? "west" : "east")"
        }
        switch p.side {
        case .eastOfTrough:
            let anchor = p.trough.map { "Trough axis near \(PatternFormat.longitude($0.longitude)), \(away($0))." }
                ?? p.ridge.map { "Ridge axis near \(PatternFormat.longitude($0.longitude)), \(away($0)); the trough behind you is west of the map." }
                ?? ""
            return ("East of the trough",
                    "\(anchor) Southwest flow aloft — the side of a trough that favors rising air and moisture return.")
        case .westOfTrough:
            let anchor = p.trough.map { "Trough axis near \(PatternFormat.longitude($0.longitude)), \(away($0))." }
                ?? p.ridge.map { "Ridge axis near \(PatternFormat.longitude($0.longitude)), \(away($0)); the trough ahead of you is east of the map." }
                ?? ""
            return ("West of the trough",
                    "\(anchor) Northwest flow aloft — sinking air behind the trough, typically cooler and drier.")
        case .troughAxis:
            let lon = p.trough.map { PatternFormat.longitude($0.longitude) } ?? ""
            return ("On the trough axis",
                    "The axis is near \(lon), overhead — the turn from northwest flow to southwest flow.")
        case .ridgeAxis:
            let lon = p.ridge.map { PatternFormat.longitude($0.longitude) } ?? ""
            return ("Under the ridge axis",
                    "The axis is near \(lon), overhead — sinking air under the ridge, with the flow aloft turning from southwest to northwest.")
        case .flat:
            return ("No ridge or trough stands out",
                    "Nothing in the wave between \(PatternFormat.longitude(grid.west)) and \(PatternFormat.longitude(grid.east)) has \(String(format: "%.1f", WavePattern.reliefThreshold)) dam of relief. The flow aloft is close to straight west-to-east.")
        }
    }
}

// MARK: - Wave profile

struct WaveProfileChart: View {
    let longitudes: [Double]
    let profile: [Double]
    let features: [WaveFeature]
    let homeLongitude: Double?
    /// Symmetric: the y axis runs −extent…+extent dam.
    let extent: Double

    private let inset = EdgeInsets(top: 30, leading: 40, bottom: 26, trailing: 14)

    var body: some View {
        Canvas { context, size in draw(context, size) }
            .frame(height: 300)
            .accessibilityElement()
            .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let named = features.map { "\($0.kind == .ridge ? "Ridge" : "Trough") near \(PatternFormat.longitude($0.longitude))" }
        var parts = ["Wave profile"]
        parts.append(named.isEmpty ? "no ridge or trough named" : named.joined(separator: ", "))
        if let homeLongitude { parts.append("you are at \(PatternFormat.longitude(homeLongitude))") }
        return parts.joined(separator: ". ")
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize) {
        guard let west = longitudes.first, let east = longitudes.last, east > west,
              profile.count == longitudes.count else { return }
        let plot = CGRect(x: inset.leading, y: inset.top,
                          width: size.width - inset.leading - inset.trailing,
                          height: size.height - inset.top - inset.bottom)
        func x(_ lon: Double) -> CGFloat { plot.minX + CGFloat((lon - west) / (east - west)) * plot.width }
        func y(_ v: Double) -> CGFloat { plot.minY + CGFloat((extent - v) / (2 * extent)) * plot.height }
        let zeroY = y(0)

        // Horizontal gridlines + y labels.
        let tick: Double = extent <= 16 ? 4 : extent <= 32 ? 8 : 12
        var v = -(extent / tick).rounded(.down) * tick
        while v <= extent {
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y(v)))
            line.addLine(to: CGPoint(x: plot.maxX, y: y(v)))
            if v == 0 {
                context.stroke(line, with: .color(.secondary), lineWidth: 1)
            } else {
                context.stroke(line, with: .color(.primary.opacity(0.08)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            context.draw(Text(PatternFormat.signed(v)).font(.caption2).foregroundStyle(.secondary).monospacedDigit(),
                         at: CGPoint(x: plot.minX - 6, y: y(v)), anchor: .trailing)
            v += tick
        }

        // X labels — every other one when the columns get tight.
        let every = plot.width / CGFloat(longitudes.count) < 44 ? 2 : 1
        for (i, lon) in longitudes.enumerated() where i % every == 0 {
            context.draw(Text(PatternFormat.longitude(lon)).font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: x(lon), y: plot.maxY + 6), anchor: .top)
        }

        let points = zip(longitudes, profile).map { CGPoint(x: x($0), y: y($1)) }

        // Ridging and troughing shaded in the table's colours.
        var area = Path()
        area.move(to: CGPoint(x: points[0].x, y: zeroY))
        points.forEach { area.addLine(to: $0) }
        area.addLine(to: CGPoint(x: points[points.count - 1].x, y: zeroY))
        area.closeSubpath()
        context.drawLayer { layer in
            layer.clip(to: Path(CGRect(x: plot.minX, y: plot.minY, width: plot.width, height: zeroY - plot.minY)))
            layer.fill(area, with: .color(PatternColor.ridge.opacity(0.22)))
        }
        context.drawLayer { layer in
            layer.clip(to: Path(CGRect(x: plot.minX, y: zeroY, width: plot.width, height: plot.maxY - zeroY)))
            layer.fill(area, with: .color(PatternColor.trough.opacity(0.22)))
        }

        // You.
        if let homeLongitude, homeLongitude >= west, homeLongitude <= east {
            var marker = Path()
            marker.move(to: CGPoint(x: x(homeLongitude), y: plot.minY - 4))
            marker.addLine(to: CGPoint(x: x(homeLongitude), y: plot.maxY))
            context.stroke(marker, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            context.draw(Text("you").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor),
                         at: CGPoint(x: x(homeLongitude), y: plot.minY - 6), anchor: .bottom)
        }

        // The wave.
        var line = Path()
        line.addLines(points)
        context.stroke(line, with: .color(.primary), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        for p in points {
            context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.primary))
        }

        // Callouts: ridges above the line, troughs below, on a short dashed leader.
        for feature in features {
            let anchor = CGPoint(x: x(feature.longitude), y: y(feature.value))
            let up = feature.kind == .ridge
            let labelY = up ? max(anchor.y - 34, plot.minY + 12) : min(anchor.y + 34, plot.maxY - 12)
            var leader = Path()
            leader.move(to: CGPoint(x: anchor.x, y: anchor.y + (up ? -5 : 5)))
            leader.addLine(to: CGPoint(x: anchor.x, y: labelY + (up ? 12 : -12)))
            let tint = up ? PatternColor.ridge : PatternColor.trough
            context.stroke(leader, with: .color(tint), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
            context.draw(Text(up ? "Ridge" : "Trough").font(.caption.weight(.semibold)).foregroundStyle(tint),
                         at: CGPoint(x: anchor.x, y: labelY - 6), anchor: .center)
            context.draw(Text(PatternFormat.longitude(feature.longitude)).font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: anchor.x, y: labelY + 7), anchor: .center)
        }
    }
}

// MARK: - Height table

/// The numbers, laid out as the map they are: north up, west left, one cell per
/// 5°. Height lines and flow arrows are drawn over the same cells, so the table
/// reads like a real 500 mb chart with its values showing.
struct HeightTable: View {
    let grid: UpperAirGrid
    let field: HeightField
    let deviations: [[Double]]
    let home: GeoPoint?
    let reference: WaveReference

    @Environment(\.colorScheme) private var scheme
    @State private var showLines = true

    fileprivate static let labelWidth: CGFloat = 44
    fileprivate static let headerHeight: CGFloat = 18
    fileprivate static let rowHeight: CGFloat = 30
    fileprivate static let gap: CGFloat = 2

    /// The grid cell nearest home, outlined so the table can be read from "here".
    private var homeCell: (row: Int, column: Int)? {
        guard let home else { return nil }
        let row = grid.latitudes.indices.min { abs(grid.latitudes[$0] - home.latitude) < abs(grid.latitudes[$1] - home.latitude) }
        let column = grid.longitudes.indices.min { abs(grid.longitudes[$0] - home.longitude) < abs(grid.longitudes[$1] - home.longitude) }
        guard let row, let column else { return nil }
        return (row, column)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                map(width: geo.size.width)
            }
            .frame(height: Self.headerHeight + CGFloat(grid.latitudes.count) * (Self.rowHeight + Self.gap))
            footer
        }
    }

    fileprivate struct Layout {
        let cellWidth: CGFloat
        func x(_ column: Double) -> CGFloat {
            HeightTable.labelWidth + CGFloat(column) * (cellWidth + HeightTable.gap) + cellWidth / 2
        }
        func y(_ row: Double) -> CGFloat {
            HeightTable.headerHeight + CGFloat(row) * (HeightTable.rowHeight + HeightTable.gap) + HeightTable.rowHeight / 2
        }
    }

    private func map(width: CGFloat) -> some View {
        let cols = grid.longitudes.count
        let layout = Layout(cellWidth: max(20, (width - Self.labelWidth - Self.gap * CGFloat(cols - 1)) / CGFloat(cols)))
        return ZStack(alignment: .topLeading) {
            ForEach(grid.longitudes.indices, id: \.self) { c in
                Text(PatternFormat.longitude(grid.longitudes[c]))
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(width: layout.cellWidth)
                    .position(x: layout.x(Double(c)), y: Self.headerHeight / 2)
            }
            ForEach(grid.latitudes.indices, id: \.self) { r in
                rowLabel(r)
                    .frame(width: Self.labelWidth - 8, alignment: .trailing)
                    .position(x: (Self.labelWidth - 8) / 2, y: layout.y(Double(r)))
                ForEach(grid.longitudes.indices, id: \.self) { c in
                    cell(row: r, column: c)
                        .frame(width: layout.cellWidth, height: Self.rowHeight)
                        .position(x: layout.x(Double(c)), y: layout.y(Double(r)))
                }
            }
            if showLines {
                Canvas { context, _ in drawLines(context, layout) }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private func rowLabel(_ row: Int) -> some View {
        let lat = grid.latitudes[row]
        let inBand = grid.midLatitudes.contains(lat)
        return Text(PatternFormat.latitude(lat))
            .font(.caption.weight(inBand ? .semibold : .regular))
            .foregroundStyle(inBand ? .primary : .secondary)
            .help(inBand ? "Averaged into the wave profile" : "Shown, not averaged into the wave")
    }

    private func cell(row: Int, column: Int) -> some View {
        let height = field.heights[row][column]
        let deviation = deviations[row][column]
        let isHome = homeCell.map { $0.row == row && $0.column == column } ?? false
        return Text("\(Int(height.rounded()))")
            .font(.system(.callout, design: .rounded).weight(.medium).monospacedDigit())
            .lineLimit(1).minimumScaleFactor(0.7)
            .foregroundStyle(PatternColor.text(deviation, scheme: scheme))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 4).fill(PatternColor.fill(deviation)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: isHome ? 2 : 0))
            .help("\(PatternFormat.latitude(grid.latitudes[row])) \(PatternFormat.longitude(grid.longitudes[column])) · \(Int(height.rounded())) dam · \(PatternFormat.signed(deviation)) dam\(isHome ? " · nearest cell to you" : "")")
            .accessibilityLabel("\(PatternFormat.latitude(grid.latitudes[row])) \(PatternFormat.longitude(grid.longitudes[column])), \(Int(height.rounded())) decameters, \(PatternFormat.signed(deviation)) from the mean")
    }

    private func drawLines(_ context: GraphicsContext, _ layout: Layout) {
        func point(_ p: GridPoint) -> CGPoint { CGPoint(x: layout.x(p.column), y: layout.y(p.row)) }

        for line in HeightContours.lines(field.heights) {
            var path = Path()
            for s in line.segments {
                path.move(to: point(s.a))
                path.addLine(to: point(s.b))
            }
            context.stroke(path, with: .color(.primary.opacity(0.6)), lineWidth: 1.3)

            // Labelled once, at its westernmost point, the way charts label contours
            // along an edge.
            guard let s = line.segments.min(by: { min($0.a.column, $0.b.column) < min($1.a.column, $1.b.column) })
            else { continue }
            let at = point(s.a.column <= s.b.column ? s.a : s.b)
            let text = context.resolve(Text("\(Int(line.level))").font(.caption2.weight(.bold)).foregroundStyle(.primary))
            let size = text.measure(in: CGSize(width: 60, height: 20))
            let box = CGRect(x: at.x - size.width / 2 - 3, y: at.y - size.height / 2 - 1,
                             width: size.width + 6, height: size.height + 2)
            context.fill(Path(roundedRect: box, cornerRadius: 3),
                         with: .color(Color.windowBackground.opacity(0.92)))
            context.draw(text, at: at)
        }

        // Arrows in the gaps where four cells meet, clear of the numbers. Length
        // grows with speed; near-calm air gets no arrow rather than a random one.
        for flow in GeostrophicFlow.corners(field.heights, grid: grid) where flow.speedMPH >= 3 {
            let centre = point(flow.at)
            let length = CGFloat(min(24, 7 + flow.speedMPH * 0.3))
            let magnitude = (flow.east * flow.east + flow.north * flow.north).squareRoot()
            let dx = CGFloat(flow.east / magnitude), dy = CGFloat(-flow.north / magnitude)
            let tail = CGPoint(x: centre.x - dx * length / 2, y: centre.y - dy * length / 2)
            let tip = CGPoint(x: centre.x + dx * length / 2, y: centre.y + dy * length / 2)
            var arrow = Path()
            arrow.move(to: tail)
            arrow.addLine(to: tip)
            for angle in [0.45, -0.45] {
                let (c, s) = (CGFloat(cos(angle)), CGFloat(sin(angle)))
                let bx = -dx * 5, by = -dy * 5
                arrow.move(to: tip)
                arrow.addLine(to: CGPoint(x: tip.x + bx * c - by * s, y: tip.y + bx * s + by * c))
            }
            context.stroke(arrow, with: .color(.primary.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("−12").font(.caption2).foregroundStyle(.secondary)
                LinearGradient(colors: [PatternColor.fill(-12), PatternColor.fill(-4), .clear,
                                        PatternColor.fill(4), PatternColor.fill(12)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 140, height: 8)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.1)))
                Text("+12 dam from the \(reference == .zonal ? "whole-latitude" : "US") mean")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Toggle("Height lines & flow", isOn: $showLines)
                    .toggleStyle(.switch).controlSize(.mini)
                    .font(.caption)
            }
            Text(showLines
                 ? "Lines every 6 dam, as on a real 500 mb chart. Air flows along them with lower heights on its left — faster where they crowd. Bold rows make up the wave; the outlined cell is nearest you."
                 : "Bold rows make up the wave; the outlined cell is nearest you.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - The column over you

/// What a height IS: the altitude of the level with half the atmosphere's air
/// below it, drawn as a column you can watch grow and shrink as you scrub.
struct AirColumnView: View {
    /// dam
    let height: Double
    /// The reference mean at your latitude, dam.
    let mean: Double?
    let meanLabel: String
    /// 1000–500 mb thickness, dam.
    let thickness: Double?

    /// FIXED — across days, runs and seasons — so any two looks at this column
    /// compare honestly. Texas runs from the high 550s in a cold winter to the mid
    /// 590s under a summer ridge.
    static let scale: ClosedRange<Double> = 550...600

    static func feet(_ dam: Double) -> Double { dam * 10 * 3.280_84 }

    static func feetText(_ dam: Double) -> String {
        "\((Int(feet(dam) / 10) * 10).formatted()) ft"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Canvas { context, size in draw(context, size) }
                .frame(height: 220)
                .accessibilityElement()
                .accessibilityLabel(accessibilityText)
            if let thickness {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(LayerTemperature.fahrenheit(thicknessDam: thickness).rounded()))°F")
                        .font(.title2.weight(.semibold)).monospacedDigit()
                    Text("average temperature of the air below it")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("Warm air takes up more room, so the column stands taller: every 10 dam of depth is about \(Int((LayerTemperature.fahrenheitPerDam * 10).rounded()))°F warmer.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This run doesn’t carry the layer temperature.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var accessibilityText: String {
        var text = "The 500 millibar level over you is at \(Self.feetText(height))"
        if let mean {
            text += ", \(PatternFormat.signed(Self.feet(height) - Self.feet(mean))) feet from the \(meanLabel)"
        }
        return text
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize) {
        let lo = Self.scale.lowerBound, hi = Self.scale.upperBound
        let plot = CGRect(x: 54, y: 10, width: size.width - 54, height: size.height - 30)
        func y(_ dam: Double) -> CGFloat {
            plot.maxY - CGFloat((min(max(dam, lo), hi) - lo) / (hi - lo)) * plot.height
        }

        for dam in stride(from: lo, through: hi, by: 10) {
            var tick = Path()
            tick.move(to: CGPoint(x: plot.minX, y: y(dam)))
            tick.addLine(to: CGPoint(x: plot.maxX, y: y(dam)))
            context.stroke(tick, with: .color(.primary.opacity(0.07)), lineWidth: 1)
            context.draw(Text("\(Int(dam))").font(.caption2.weight(.medium)).foregroundStyle(.secondary),
                         at: CGPoint(x: plot.minX - 8, y: y(dam) - 5), anchor: .trailing)
            context.draw(Text("\(String(format: "%.1f", Self.feet(dam) / 1000))k ft").font(.system(size: 9)).foregroundStyle(.tertiary),
                         at: CGPoint(x: plot.minX - 8, y: y(dam) + 6), anchor: .trailing)
        }

        let deviation = mean.map { height - $0 } ?? 0
        let bar = CGRect(x: plot.minX + 8, y: y(height), width: 54, height: plot.maxY - y(height))
        let tint = deviation < 0 ? PatternColor.trough : PatternColor.ridge
        context.fill(Path(roundedRect: bar, cornerRadius: 3),
                     with: .color(mean == nil ? .secondary.opacity(0.3) : tint.opacity(max(0.3, PatternColor.opacity(deviation)))))

        // A scale break: the column really starts at the ground, ~17,000 ft lower.
        var zig = Path()
        let zy = plot.maxY - 8
        zig.move(to: CGPoint(x: bar.minX - 3, y: zy))
        for i in 0...6 {
            zig.addLine(to: CGPoint(x: bar.minX + CGFloat(i) * bar.width / 6, y: zy + (i % 2 == 0 ? -3 : 3)))
        }
        context.stroke(zig, with: .color(Color.windowBackground), lineWidth: 3)
        context.draw(Text("ground far below").font(.system(size: 9)).foregroundStyle(.tertiary),
                     at: CGPoint(x: bar.minX, y: plot.maxY + 4), anchor: .topLeading)

        var top = Path()
        top.move(to: CGPoint(x: bar.minX - 4, y: y(height)))
        top.addLine(to: CGPoint(x: bar.maxX + 4, y: y(height)))
        context.stroke(top, with: .color(.primary), lineWidth: 2)

        let labelX = bar.maxX + 10
        let meanAbove = mean.map { $0 > height } ?? false
        let levelY = y(height) + (meanAbove ? 8 : -8)
        context.draw(Text("500 mb level").font(.caption.weight(.semibold)),
                     at: CGPoint(x: labelX, y: levelY - 6), anchor: .leading)
        context.draw(Text(Self.feetText(height)).font(.caption2).foregroundStyle(.secondary).monospacedDigit(),
                     at: CGPoint(x: labelX, y: levelY + 7), anchor: .leading)

        if let mean {
            var line = Path()
            line.move(to: CGPoint(x: bar.minX - 4, y: y(mean)))
            line.addLine(to: CGPoint(x: bar.maxX + 4, y: y(mean)))
            context.stroke(line, with: .color(.secondary), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            let diffFeet = Self.feet(height) - Self.feet(mean)
            let rounded = Int((diffFeet / 10).rounded()) * 10
            let meanY = y(mean) + (meanAbove ? -8 : 10)
            context.draw(Text(meanLabel).font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: labelX, y: meanY - 6), anchor: .leading)
            context.draw(Text("\(rounded >= 0 ? "+" : "−")\(abs(rounded).formatted()) ft \(rounded >= 0 ? "taller" : "shorter")")
                            .font(.caption2.weight(.semibold)).foregroundStyle(tint),
                         at: CGPoint(x: labelX, y: meanY + 7), anchor: .leading)
        }
    }
}

// MARK: - The wave over time

/// A Hovmöller diagram: longitude across, forecast days down, each row the wave
/// profile for that day. A moving ridge or trough draws a SLANTED stripe — the
/// slant is its speed — a stalled one a vertical stripe, and one backing west a
/// stripe leaning the other way. The lines follow each named feature day to day.
struct WaveTimeChart: View {
    let longitudes: [Double]
    let days: [Date]
    let profiles: [[Double]]
    let features: [[WaveFeature]]
    let selected: Int
    let homeLongitude: Double?
    let select: (Int) -> Void

    private static let rowHeight: CGFloat = 20
    private let inset = EdgeInsets(top: 22, leading: 58, bottom: 18, trailing: 78)

    /// Miles per degree of longitude at 40°N, mid-band.
    private static let milesPerDegree = 53.0

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE d"
        return f
    }()

    var body: some View {
        let tracks = FeatureTracks.build(features)
        VStack(alignment: .leading, spacing: 8) {
            Canvas { context, size in draw(context, size, tracks) }
                .frame(height: inset.top + inset.bottom + Self.rowHeight * CGFloat(days.count))
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    let row = Int(floor((location.y - inset.top) / Self.rowHeight))
                    if days.indices.contains(row) { select(row) }
                }
                .accessibilityElement()
                .accessibilityLabel(summary(tracks))
            HStack(spacing: 14) {
                Text("▲ ridge   ▼ trough").font(.caption.weight(.medium))
                Text("Each line follows one feature: leaning right is moving east, straight down is stalled, leaning left is backing west. Click a day to jump to it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    static func motion(_ track: FeatureTrack) -> String? {
        guard let degrees = track.degreesPerDay, track.points.count >= 3 else { return nil }
        if abs(degrees) < 2 { return "stalled" }
        let miles = Int((abs(degrees) * milesPerDegree / 10).rounded()) * 10
        return degrees > 0 ? "east \(miles) mi/day" : "west \(miles) mi/day"
    }

    private func summary(_ tracks: [FeatureTrack]) -> String {
        let described = tracks.compactMap { track -> String? in
            guard let motion = Self.motion(track), let first = track.points.first else { return nil }
            return "\(track.kind == .ridge ? "Ridge" : "Trough") from \(PatternFormat.longitude(first.longitude)), \(motion)"
        }
        return "The wave over time. " + (described.isEmpty ? "No feature lasts three days." : described.joined(separator: ". "))
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize, _ tracks: [FeatureTrack]) {
        guard let west = longitudes.first, let east = longitudes.last, longitudes.count > 1 else { return }
        let plot = CGRect(x: inset.leading, y: inset.top, width: size.width - inset.leading - inset.trailing,
                          height: Self.rowHeight * CGFloat(days.count))
        let cellWidth = plot.width / CGFloat(longitudes.count)
        let step = (east - west) / Double(longitudes.count - 1)
        func x(_ lon: Double) -> CGFloat { plot.minX + CGFloat((lon - west) / step + 0.5) * cellWidth }
        func rowMid(_ frame: Int) -> CGFloat { plot.minY + (CGFloat(frame) + 0.5) * Self.rowHeight }

        for (frame, profile) in profiles.enumerated() {
            for (j, value) in profile.enumerated() {
                let rect = CGRect(x: plot.minX + CGFloat(j) * cellWidth, y: plot.minY + CGFloat(frame) * Self.rowHeight,
                                  width: cellWidth + 0.5, height: Self.rowHeight + 0.5)
                context.fill(Path(rect), with: .color(PatternColor.fill(value)))
            }
            context.draw(Text(Self.dayFormatter.string(from: days[frame]))
                            .font(.caption2.weight(frame == selected ? .bold : .regular))
                            .foregroundStyle(frame == selected ? .primary : .secondary),
                         at: CGPoint(x: plot.minX - 8, y: rowMid(frame)), anchor: .trailing)
        }

        for (i, lon) in longitudes.enumerated() where i % 2 == 0 {
            context.draw(Text(PatternFormat.longitude(lon)).font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: x(lon), y: plot.minY - 4), anchor: .bottom)
        }

        if let homeLongitude, homeLongitude >= west, homeLongitude <= east {
            var marker = Path()
            marker.move(to: CGPoint(x: x(homeLongitude), y: plot.minY))
            marker.addLine(to: CGPoint(x: x(homeLongitude), y: plot.maxY))
            context.stroke(marker, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            context.draw(Text("you").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor),
                         at: CGPoint(x: x(homeLongitude), y: plot.maxY + 3), anchor: .top)
        }

        for track in tracks {
            let points = track.points.map { CGPoint(x: x($0.longitude), y: rowMid($0.frame)) }
            if points.count >= 2 {
                var path = Path()
                path.addLines(points)
                context.stroke(path, with: .color(.primary.opacity(0.75)),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            for p in points {
                var mark = Path()
                let up = track.kind == .ridge
                mark.move(to: CGPoint(x: p.x, y: p.y + (up ? -5 : 5)))
                mark.addLine(to: CGPoint(x: p.x - 4.5, y: p.y + (up ? 3.5 : -3.5)))
                mark.addLine(to: CGPoint(x: p.x + 4.5, y: p.y + (up ? 3.5 : -3.5)))
                mark.closeSubpath()
                context.fill(mark, with: .color(.primary))
            }
            if let motion = Self.motion(track), let last = points.last {
                let nearEdge = last.x + 8 > size.width - 70
                context.draw(Text(motion).font(.caption2.weight(.medium)).foregroundStyle(.primary),
                             at: CGPoint(x: nearEdge ? last.x - 8 : last.x + 8, y: last.y),
                             anchor: nearEdge ? .trailing : .leading)
            }
        }

        let row = CGRect(x: plot.minX - 2, y: plot.minY + CGFloat(selected) * Self.rowHeight,
                         width: plot.width + 4, height: Self.rowHeight)
        context.stroke(Path(roundedRect: row, cornerRadius: 3), with: .color(.accentColor), lineWidth: 2)
    }
}

// MARK: - The playbar

/// The transport for the forecast days, pinned to the bottom of the surface.
///
/// WHY IT FLOATS. It used to be the first card in the scroll, which meant the
/// control that drives every chart below it scrolled off the top as soon as you
/// went looking at those charts. You'd read the wave-over-time panel, want the
/// next day, and have to scroll back up to ask for it. A transport belongs where
/// a transport belongs: over the content, always reachable, out of the flow.
///
/// WHY THE ARROWS ARE NOT ON THE MAC. Stepping is the primary way through the
/// days and on the Mac ← and → already do it from anywhere on the page, which is
/// better than any button — no pointer travel, no target to hit. An iPad has no
/// such keys unless someone has attached a keyboard, so there the same job needs
/// something to touch. Each platform gets the affordance it can actually use,
/// and neither carries the other's.
struct PatternPlaybar: View {
    @ObservedObject var model: UpperAirModel
    @Binding var playing: Bool
    let frame: UpperAirFrame

    @FocusState private var focus: Control?
    private enum Control { case play, slider }

    var body: some View {
        let last = model.lastFrame
        HStack(spacing: 12) {
            Button {
                togglePlay()
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .frame(width: 22, height: 18)
            }
            .focusable()
            .focused($focus, equals: .play)
            .focusEffectDisabled()
            .onKeyPress(.space) { togglePlay(); return .handled }
            .onKeyPress(.return) { togglePlay(); return .handled }
            .overlay(focusRing(focus == .play))
            .accessibilityLabel(playing ? "Pause" : "Play through the forecast days")

            #if !os(macOS)
            stepButton("chevron.left", delta: -1, enabled: model.frameIndex > 0)
            #endif

            Slider(value: Binding(get: { Double(model.frameIndex) },
                                  set: { playing = false; model.go(to: Int($0.rounded())) }),
                   in: 0...Double(max(last, 1)), step: 1)
                .disabled(last < 1)
                .focusable()
                .focused($focus, equals: .slider)
                .focusEffectDisabled()
                .onKeyPress(.leftArrow) { playing = false; model.step(-1); return .handled }
                .onKeyPress(.rightArrow) { playing = false; model.step(+1); return .handled }
                .onKeyPress(.home) { model.go(to: 0); return .handled }
                .onKeyPress(.end) { model.go(to: last); return .handled }
                .padding(.horizontal, 4)
                .overlay(focusRing(focus == .slider))
                .accessibilityLabel("Forecast day")
                .accessibilityValue("Valid \(PatternFormat.valid(frame.valid)), day \(model.frameIndex + 1) of \(last + 1)")

            #if !os(macOS)
            stepButton("chevron.right", delta: +1, enabled: model.frameIndex < last)
            #endif

            // The day it is showing, which is the bar's actual subject. Kept
            // beside the count rather than only in the header, because the header
            // is now something you may have scrolled past.
            VStack(alignment: .trailing, spacing: 1) {
                Text(PatternFormat.valid(frame.valid))
                    .font(.caption.weight(.medium)).lineLimit(1)
                Text("\(model.frameIndex + 1) / \(last + 1)")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            .fixedSize()

            #if os(macOS)
            Text("← → step · space plays")
                .font(.caption).foregroundStyle(.tertiary)
            #endif
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // A real surface, not a tint over the scroll. The charts underneath are
        // dense and mostly ink; anything translucent enough to read through would
        // have a trough running under the slider.
        .background(.bar, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .frame(maxWidth: 820)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .task(id: playing) {
            guard playing else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled, playing else { return }
                model.go(to: model.frameIndex + 1)
                if model.frameIndex >= model.lastFrame { playing = false; return }
            }
        }
    }

    @ViewBuilder private func stepButton(_ symbol: String, delta: Int, enabled: Bool) -> some View {
        Button {
            playing = false
            model.step(delta)
        } label: {
            Image(systemName: symbol).frame(width: 22, height: 18)
        }
        .disabled(!enabled)
        .accessibilityLabel(delta < 0 ? "Previous day" : "Next day")
    }

    private func togglePlay() {
        if !playing && model.frameIndex >= model.lastFrame { model.frameIndex = 0 }
        playing.toggle()
    }

    private func focusRing(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(Color.accentColor, lineWidth: 2)
            .opacity(on ? 1 : 0)
    }
}
