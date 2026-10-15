//
//  FrontPicture.swift  (Weather, shared with VaneTV)
//
//  What the Front view puts ON the map — one metric coloured, the wind drawn
//  over it, the airports' readings as dots, numbers if wanted — and the scales
//  behind the colours. Shared with the TV, which has its own controls but the
//  same map; it has no platform code.
//
//  THE COLOUR IS THE VALUE. Temperature from blue through red, dewpoint from
//  dry brown to humid green: the scales every weather map uses, so the map can
//  be read without learning it first. The front shows as the edge where the
//  colours change. (It started as the 3-hour CHANGE in each, which a forecaster
//  reads well and nobody else could; "what do blue and yellow mean" was the
//  first question it got.) Pressure is the exception: its level means little,
//  so it stays coloured by its 3-hour change, which is the clue.
//

import SwiftUI
import MapKit
import CoreText
import WeatherKit

// MARK: - Colour scales

/// What a metric's colours mean, as stops from low to high.
struct FrontScale {
    struct Stop { let value: Double; let r: Double; let g: Double; let b: Double }
    let stops: [Stop]
    /// Values marked under the key's gradient.
    let ticks: [Double]
    let unit: String
    /// Coloured by change, centred on zero, and clear near it — pressure.
    let diverging: Bool

    static func of(_ metric: FrontClue) -> FrontScale {
        switch metric {
        case .temperature:
            return FrontScale(stops: [
                .init(value: 20, r: 0.55, g: 0.35, b: 0.85), .init(value: 32, r: 0.25, g: 0.45, b: 0.95),
                .init(value: 45, r: 0.25, g: 0.75, b: 0.95), .init(value: 55, r: 0.30, g: 0.80, b: 0.45),
                .init(value: 65, r: 0.75, g: 0.85, b: 0.30), .init(value: 75, r: 0.98, g: 0.82, b: 0.25),
                .init(value: 85, r: 0.98, g: 0.55, b: 0.18), .init(value: 95, r: 0.90, g: 0.22, b: 0.15),
                .init(value: 105, r: 0.65, g: 0.10, b: 0.25),
            ], ticks: [30, 50, 70, 90], unit: "°F", diverging: false)
        case .dewPoint:
            return FrontScale(stops: [
                .init(value: 20, r: 0.55, g: 0.40, b: 0.25), .init(value: 35, r: 0.78, g: 0.65, b: 0.42),
                .init(value: 45, r: 0.86, g: 0.84, b: 0.56), .init(value: 55, r: 0.45, g: 0.78, b: 0.40),
                .init(value: 65, r: 0.15, g: 0.60, b: 0.35), .init(value: 75, r: 0.10, g: 0.45, b: 0.55),
            ], ticks: [30, 45, 60, 70], unit: "°F", diverging: false)
        case .wind:
            return FrontScale(stops: [
                .init(value: 0, r: 0.45, g: 0.62, b: 0.85), .init(value: 10, r: 0.35, g: 0.75, b: 0.75),
                .init(value: 20, r: 0.55, g: 0.80, b: 0.40), .init(value: 30, r: 0.95, g: 0.80, b: 0.25),
                .init(value: 40, r: 0.95, g: 0.45, b: 0.20),
            ], ticks: [0, 10, 20, 30, 40], unit: "mph", diverging: false)
        case .gusts:
            return FrontScale(stops: [
                .init(value: 10, r: 0.45, g: 0.45, b: 0.80), .init(value: 25, r: 0.60, g: 0.35, b: 0.85),
                .init(value: 40, r: 0.82, g: 0.30, b: 0.75), .init(value: 55, r: 0.92, g: 0.25, b: 0.45),
            ], ticks: [10, 25, 40, 55], unit: "mph", diverging: false)
        case .pressure:
            return FrontScale(stops: [
                .init(value: -4, r: 0.18, g: 0.45, b: 0.95), .init(value: 4, r: 0.96, g: 0.56, b: 0.14),
            ], ticks: [-4, 0, 4], unit: "mb", diverging: true)
        }
    }

    /// RGB at `value`, between the stops either side; clamped at the ends.
    func rgb(_ value: Double) -> (Double, Double, Double) {
        guard let first = stops.first, let last = stops.last else { return (0.5, 0.5, 0.5) }
        if value <= first.value { return (first.r, first.g, first.b) }
        if value >= last.value { return (last.r, last.g, last.b) }
        for (a, b) in zip(stops, stops.dropFirst()) where value <= b.value {
            let t = (value - a.value) / (b.value - a.value)
            return (a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t)
        }
        return (last.r, last.g, last.b)
    }

    /// The field's colour: see-through enough for the roads and towns to read.
    /// Pressure is clear where it barely moved and deepens with the change.
    func color(_ value: Double, solid: Bool = false) -> CGColor? {
        if diverging {
            let strength = min(1, max(0, (abs(value) - 0.5) / 3.5))
            guard strength > 0 || solid else { return nil }
            let c = value < 0 ? stops[0] : stops[stops.count - 1]
            return CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: solid ? 0.4 + 0.6 * strength : 0.6 * strength)
        }
        let (r, g, b) = rgb(value)
        return CGColor(srgbRed: r, green: g, blue: b, alpha: solid ? 1 : 0.5)
    }

    var gradient: Gradient {
        if diverging {
            let c0 = stops[0], c1 = stops[stops.count - 1]
            return Gradient(stops: [
                .init(color: Color(red: c0.r, green: c0.g, blue: c0.b), location: 0),
                .init(color: Color(red: c0.r, green: c0.g, blue: c0.b).opacity(0.05), location: 0.45),
                .init(color: Color(red: c1.r, green: c1.g, blue: c1.b).opacity(0.05), location: 0.55),
                .init(color: Color(red: c1.r, green: c1.g, blue: c1.b), location: 1),
            ])
        }
        let lo = stops.first?.value ?? 0, hi = stops.last?.value ?? 1
        return Gradient(stops: stops.map {
            .init(color: Color(red: $0.r, green: $0.g, blue: $0.b), location: ($0.value - lo) / (hi - lo))
        })
    }

    var range: ClosedRange<Double> { (stops.first?.value ?? 0)...(stops.last?.value ?? 1) }
}

extension FrontClue {
    /// The metric's value at one place: the reading itself, except pressure,
    /// which is its 3-hour change.
    func value(_ now: SurfaceReading?, then: SurfaceReading?) -> Double? {
        guard let now else { return nil }
        switch self {
        case .temperature: return now.temperature
        case .dewPoint:    return now.dewPoint
        case .wind:        return now.windSpeed
        case .gusts:       return now.gust ?? now.windSpeed
        case .pressure:
            guard let p = now.pressure, let q = then?.pressure else { return nil }
            return p - q
        }
    }

    /// The number on the map. Short — the chips and the key say which metric
    /// and its unit — but never ambiguous: temperatures carry a degree sign.
    func label(_ value: Double) -> String {
        let whole = Int(value.rounded())
        switch self {
        case .temperature, .dewPoint: return "\(whole)°"
        case .wind, .gusts:           return "\(whole)"
        case .pressure:               return whole > 0 ? "+\(whole)" : whole < 0 ? "−\(-whole)" : "0"
        }
    }

    /// The chips' order: what people look at first, then the rest.
    static let displayOrder: [FrontClue] = [.temperature, .dewPoint, .wind, .gusts, .pressure]

    /// The chip's word.
    var chip: String {
        switch self {
        case .temperature: return "Temp"
        case .dewPoint:    return "Dewpoint"
        case .wind:        return "Wind"
        case .gusts:       return "Gusts"
        case .pressure:    return "Pressure"
        }
    }

    /// What the colours show, for the chip's hint and the key.
    var shows: String {
        switch self {
        case .temperature: return "Temperature, °F. The front is where the warm colours meet the cool ones."
        case .dewPoint:    return "Dewpoint, °F: how much water is in the air. Brown is dry, green is humid."
        case .wind:        return "Wind speed, mph. The arrows show which way it's going."
        case .gusts:       return "Gusts, mph. Deeper purple is stronger."
        case .pressure:    return "How much the pressure changed in the last 3 hours. Orange rose, blue fell; clear barely moved."
        }
    }
}

// MARK: - The picture

/// Everything the renderer draws for one hour and one metric, built once.
final class FrontPicture: @unchecked Sendable {
    struct Arrow {
        let at: MKMapPoint
        /// Radians, clockwise from north, the way the wind is GOING.
        let toward: Double
        let mph: Double
    }

    struct Dot {
        let at: MKMapPoint
        let fill: CGColor
        let toward: Double?
    }

    /// A number on the map: an airport's measurement, or on a forecast hour the
    /// HRRR's value at a grid point.
    struct Note {
        let at: MKMapPoint
        let text: String
        let measured: Bool
    }

    /// Changes when the picture does; the canvas redraws only then.
    let id: String
    /// The grid's extent, which the overlay keeps for as long as the grid is
    /// the same — an hour changing redraws, it doesn't rebuild.
    let gridID: String
    let bounds: MKMapRect
    let shading: CGImage?
    let arrows: [Arrow]
    let dots: [Dot]
    /// Nearest home first, which is the order collisions are settled in.
    let notes: [Note]
    /// The spacing of the grid, in map points, for thinning arrows when zoomed out.
    let spacing: Double

    init(id: String, gridID: String, bounds: MKMapRect, shading: CGImage?, arrows: [Arrow],
         dots: [Dot], notes: [Note], spacing: Double) {
        self.id = id; self.gridID = gridID; self.bounds = bounds; self.shading = shading
        self.arrows = arrows; self.dots = dots; self.notes = notes; self.spacing = spacing
    }

    static func make(run: SurfaceRun, index: Int, metric: FrontClue, numbers: Bool,
                     airports: [AirportReport], home: GeoPoint?, now: Date = Date()) -> FrontPicture {
        let grid = run.grid
        let hour = run.hours[index]
        let back = run.index(index, minusHours: 3).map { run.hours[$0].readings }
        let step = grid.latitudes.count > 1 ? grid.latitudes[1] - grid.latitudes[0] : 0.75
        let scale = FrontScale.of(metric)

        let nw = MKMapPoint(CLLocationCoordinate2D(latitude: (grid.latitudes.last ?? 0) + step / 2,
                                                   longitude: (grid.longitudes.first ?? 0) - step / 2))
        let se = MKMapPoint(CLLocationCoordinate2D(latitude: (grid.latitudes.first ?? 0) - step / 2,
                                                   longitude: (grid.longitudes.last ?? 0) + step / 2))
        let bounds = MKMapRect(x: nw.x, y: nw.y, width: se.x - nw.x, height: se.y - nw.y)
        let gridID = "\(grid.latitudes.first ?? 0),\(grid.longitudes.first ?? 0),\(grid.count)"

        // The shading: the metric per grid point, resampled into a small image
        // laid out in MAP space, so the north–south stretch of the projection is
        // in the pixels rather than fought at draw time.
        var shading: CGImage?
        let values: [Double?] = hour.readings.indices.map { metric.value(hour.readings[$0], then: back?[$0]) }
        let width = grid.cols * 8, height = Int(Double(width) * bounds.height / bounds.width)
        // THE EDGES FADE OUT over about a grid cell, rather than stopping in a
        // hard rectangle that reads as a box laid on the map.
        let feather = 10.0
        if width > 0, height > 0 {
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            for py in 0..<height {
                for px in 0..<width {
                    let point = MKMapPoint(x: bounds.minX + (Double(px) + 0.5) / Double(width) * bounds.width,
                                           y: bounds.minY + (Double(py) + 0.5) / Double(height) * bounds.height)
                    let c = point.coordinate
                    guard let v = grid.sample(values, at: GeoPoint(latitude: c.latitude, longitude: c.longitude)),
                          let color = scale.color(v),
                          let comps = color.components, comps.count >= 4 else { continue }
                    let o = (py * width + px) * 4
                    let edge = Double(min(px, py, width - 1 - px, height - 1 - py))
                    let a = comps[3] * min(1, (edge + 0.5) / feather)
                    // Premultiplied, as the image below declares.
                    pixels[o] = UInt8(comps[0] * a * 255); pixels[o + 1] = UInt8(comps[1] * a * 255)
                    pixels[o + 2] = UInt8(comps[2] * a * 255); pixels[o + 3] = UInt8(a * 255)
                }
            }
            if let provider = CGDataProvider(data: Data(pixels) as CFData) {
                shading = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            }
        }

        let arrows: [Arrow] = hour.readings.indices.compactMap { i in
            guard let r = hour.readings[i], let from = r.windFrom else { return nil }
            let p = grid.point(i)
            return Arrow(at: MKMapPoint(CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)),
                         toward: (from + 180) * .pi / 180, mph: r.windSpeed)
        }

        func nearestHomeFirst<T>(_ items: [T], _ point: (T) -> GeoPoint) -> [T] {
            guard let home else { return items }
            return items.sorted { FrontReader.miles(home, point($0)) < FrontReader.miles(home, point($1)) }
        }

        // Airports only for hours that have happened: they are measurements.
        var dots: [Dot] = []
        var notes: [Note] = []
        if hour.valid <= now {
            let current = AirportReportClient.latest(airports, at: hour.valid.addingTimeInterval(30 * 60))
            let earlier = Dictionary(
                AirportReportClient.latest(airports, at: hour.valid.addingTimeInterval(-150 * 60)).map { ($0.station, $0) },
                uniquingKeysWith: { a, _ in a })
            for report in nearestHomeFirst(current, \.point) {
                let at = MKMapPoint(CLLocationCoordinate2D(latitude: report.point.latitude,
                                                          longitude: report.point.longitude))
                let v = metric.value(report.reading, then: earlier[report.station]?.reading)
                dots.append(Dot(at: at, fill: v.flatMap { scale.color($0, solid: true) } ?? CGColor(gray: 1, alpha: 0.9),
                                toward: report.reading.windFrom.map { ($0 + 180) * .pi / 180 }))
                if numbers, let v { notes.append(Note(at: at, text: metric.label(v), measured: true)) }
            }
        } else if numbers {
            // The hours ahead have nothing measured; the model's own values.
            for i in nearestHomeFirst(Array(hour.readings.indices), grid.point) {
                guard let v = values[i] else { continue }
                let p = grid.point(i)
                notes.append(Note(at: MKMapPoint(CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)),
                                  text: metric.label(v), measured: false))
            }
        }

        let id = "\(gridID)|\(Int(hour.valid.timeIntervalSince1970))|\(metric.rawValue)|\(numbers)|\(Int(run.run?.initialised.timeIntervalSince1970 ?? 0))|\(dots.count)"
        return FrontPicture(id: id, gridID: gridID, bounds: bounds, shading: shading, arrows: arrows,
                            dots: dots, notes: notes, spacing: bounds.width / Double(max(1, grid.cols)))
    }
}

// MARK: - The overlay

final class FrontOverlay: NSObject, MKOverlay {
    let boundingMapRect: MKMapRect
    let gridID: String
    var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
    }

    init(_ picture: FrontPicture) {
        // A little beyond the grid, so arrows and numbers on its edge aren't clipped.
        boundingMapRect = picture.bounds.insetBy(dx: -picture.spacing, dy: -picture.spacing)
        gridID = picture.gridID
    }
}

final class FrontRenderer: MKOverlayRenderer {
    private let lock = NSLock()
    private var _picture: FrontPicture
    /// Everything drawn in screen points — arrows, dots, numbers — times this.
    /// 1 on a Mac or phone; larger on a TV, read from across a room.
    private let scale: Double
    /// Which numbers are drawn at each zoom, for the current picture. Decided
    /// over the WHOLE map, not per tile: MapKit draws tile by tile, and a label
    /// straddling two tiles has to be drawn — or not — in both.
    private var labelled: (pictureID: String, zoom: Int, which: Set<Int>)?
    private let ink: CGColor

    init(overlay: FrontOverlay, picture: FrontPicture, ink: CGColor, scale: Double = 1) {
        _picture = picture
        self.ink = ink
        self.scale = scale
        super.init(overlay: overlay)
    }

    /// Set from the main thread; read from MapKit's drawing threads.
    var picture: FrontPicture {
        get { lock.lock(); defer { lock.unlock() }; return _picture }
        set { lock.lock(); _picture = newValue; lock.unlock() }
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let picture = self.picture
        // A screen point in map points, times the platform's scale: every size
        // below is in these.
        let perPoint = scale / zoomScale

        if let image = picture.shading {
            let rect = self.rect(for: picture.bounds)
            context.saveGState()
            context.clip(to: self.rect(for: mapRect))
            context.interpolationQuality = .high
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        }

        // Every arrow, or every other one once they'd crowd: a grid cell under
        // 26 screen points apart.
        let stride = picture.spacing * Double(zoomScale) < 26 * scale ? 2 : 1
        let reach = mapRect.insetBy(dx: -picture.spacing, dy: -picture.spacing)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let arrowInk = ink.copy(alpha: 0.7) ?? ink
        for arrow in picture.arrows where reach.contains(arrow.at) {
            if stride > 1 {
                // Thinned on the grid, not the list, so the pattern stays even.
                let col = Int((arrow.at.x - picture.bounds.minX) / picture.spacing)
                let row = Int((arrow.at.y - picture.bounds.minY) / picture.spacing)
                guard (col + row) % 2 == 0 else { continue }
            }
            let length = (8 + min(arrow.mph, 35) * 0.5) * perPoint
            drawArrow(at: point(for: arrow.at), toward: arrow.toward, length: length,
                      width: 1.4 * perPoint, color: arrowInk, in: context)
        }

        // Airports on top: what was measured outranks what was modelled.
        let radius = 4.5 * perPoint
        for dot in picture.dots where reach.contains(dot.at) {
            let c = point(for: dot.at)
            if let toward = dot.toward {
                let tail = CGPoint(x: c.x + sin(toward) * 11 * perPoint, y: c.y - cos(toward) * 11 * perPoint)
                context.setStrokeColor(CGColor(gray: 0.1, alpha: 0.85))
                context.setLineWidth(1.6 * perPoint)
                context.move(to: c); context.addLine(to: tail); context.strokePath()
            }
            let circle = CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
            context.setFillColor(dot.fill)
            context.fillEllipse(in: circle)
            context.setStrokeColor(CGColor(gray: 0.1, alpha: 0.85))
            context.setLineWidth(1.2 * perPoint)
            context.strokeEllipse(in: circle)
        }

        let kept = labelledNotes(picture, perPoint: perPoint)
        for (n, note) in picture.notes.enumerated() where kept.contains(n) && reach.contains(note.at) {
            drawLabel(note, at: point(for: note.at), perPoint: perPoint, in: context)
        }
    }

    // MARK: Numbers

    /// THE MAP'S OWN LABEL STYLE: white, a soft shadow, the system font. The
    /// first version was dark text in a white outline, which read as stickers
    /// stuck on the map rather than part of it.
    static let fontSize: CGFloat = 13
    static let measuredFont = CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil)
        ?? CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
    /// The same weight as an airport's: lighter washed out over the warm end
    /// of the temperature scale. Where it sits — under an arrow, not beside a
    /// dot — already says it's the model's.
    static let modelFont = measuredFont

    /// Where a number sits relative to its point, in screen points: an
    /// airport's beside its dot, the model's centred under its arrow.
    private static func frame(_ note: FrontPicture.Note) -> CGRect {
        let width = CGFloat(note.text.count) * fontSize * 0.62 + 2
        return note.measured
            ? CGRect(x: 8, y: -fontSize / 2 - 1, width: width, height: fontSize + 2)
            : CGRect(x: -width / 2, y: 11, width: width, height: fontSize + 2)
    }

    /// Greedy, in the picture's order (nearest home first): a label is kept if
    /// it overlaps none kept before it.
    private func labelledNotes(_ picture: FrontPicture, perPoint: Double) -> Set<Int> {
        let zoom = Int((log2(perPoint) * 4).rounded())
        lock.lock()
        if let held = labelled, held.pictureID == picture.id, held.zoom == zoom {
            lock.unlock(); return held.which
        }
        lock.unlock()
        var kept: [MKMapRect] = []
        var which = Set<Int>()
        for (n, note) in picture.notes.enumerated() {
            let f = Self.frame(note).insetBy(dx: -3, dy: -2)
            let rect = MKMapRect(x: note.at.x + Double(f.minX) * perPoint, y: note.at.y + Double(f.minY) * perPoint,
                                 width: Double(f.width) * perPoint, height: Double(f.height) * perPoint)
            guard !kept.contains(where: { $0.intersects(rect) }) else { continue }
            kept.append(rect)
            which.insert(n)
        }
        lock.lock(); labelled = (picture.id, zoom, which); lock.unlock()
        return which
    }

    private func drawLabel(_ note: FrontPicture.Note, at c: CGPoint, perPoint: Double, in context: CGContext) {
        let font = note.measured ? Self.measuredFont : Self.modelFont
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: note.text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 1),
        ]))
        let f = Self.frame(note)
        context.saveGState()
        // INTO SCREEN POINTS FIRST, then text at its ordinary size. Scaling the
        // FONT into map points instead drew nothing at all on the map.
        context.translateBy(x: c.x, y: c.y)
        context.scaleBy(x: perPoint, y: perPoint)
        context.setShadow(offset: .zero, blur: 3.5, color: CGColor(gray: 0, alpha: 0.9))
        // Text draws y-up; the map is y-down.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: f.minX + 1, y: f.maxY - 4)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// A shaft and an open head, pointing where the wind is going. Map points
    /// grow southward, hence the minus on the cosine.
    private func drawArrow(at c: CGPoint, toward: Double, length: Double, width: Double,
                           color: CGColor, in context: CGContext) {
        let dx = sin(toward), dy = -cos(toward)
        let tip = CGPoint(x: c.x + dx * length / 2, y: c.y + dy * length / 2)
        let tail = CGPoint(x: c.x - dx * length / 2, y: c.y - dy * length / 2)
        let head = length * 0.38
        let left = CGPoint(x: tip.x - head * (dx * cos(0.5) - dy * sin(0.5)),
                           y: tip.y - head * (dy * cos(0.5) + dx * sin(0.5)))
        let right = CGPoint(x: tip.x - head * (dx * cos(0.5) + dy * sin(0.5)),
                            y: tip.y - head * (dy * cos(0.5) - dx * sin(0.5)))
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.move(to: tail); context.addLine(to: tip)
        context.move(to: left); context.addLine(to: tip); context.addLine(to: right)
        context.strokePath()
    }
}
