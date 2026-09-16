//
//  RecentMorningsView.swift  (macOS)
//
//  "Yesterday morning felt better than the mornings before it — was it?"
//
//  Every other archive card on this screen reads DailyRecords. This one can't:
//  a day's min and max say nothing about the shape inside it, and the question is
//  entirely about that shape. So it re-fetches raw half-hourly observations for
//  the last month — one request, because bucket=30 caps a window at 30 days and
//  ten mornings therefore cost the same as two.
//
//  Nothing is stored. This is a live comparison of the recent past, not a second
//  archive; if it turns out to be something you look at every day, THAT's when
//  keeping the samples earns its disk.
//
//  The chart is ordinary on purpose: one line per morning, all on one temperature
//  axis, clock time along the bottom. The comparison IS the overlay — a reader
//  should be able to see the subject day sitting apart, or not, without decoding
//  an encoding.
//

import SwiftUI
import Combine
import WeatherKit

// MARK: - Loading

/// Fetches the last month of raw observations and slices them to one clock
/// window per day.
@MainActor
final class RecentWindowsModel: ObservableObject {
    @Published private(set) var windows: [DayWindow] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var window: ClockWindow = .morning

    /// Days back to request. One under the API's 30-day cap at this bucket, for
    /// the same reason ArchiveSync steps 29: a DST-long local day mustn't tip a
    /// window over the limit and fail the whole fetch.
    private let daysBack = 29

    private var raw: StationObservations?

    func load(token: String, stationID: Int, window: ClockWindow = .morning,
              now: Date = Date()) async {
        guard !token.isEmpty, stationID != 0, !isLoading else { return }
        // The fetch doesn't depend on the window — re-slicing what we already
        // hold is free, so asking for a different stretch of clock must never
        // re-hit the network.
        guard raw == nil else { return show(window) }

        isLoading = true
        error = nil
        self.window = window
        defer { isLoading = false }

        let calendar = Calendar.current
        let end = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -daysBack, to: end) else { return }

        do {
            let client = TempestClient(token: token, stationID: stationID)
            raw = try await client.observations(start: start, end: end,
                                                bucketMinutes: ArchiveSync.bucketMinutes)
            reslice()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func show(_ window: ClockWindow) {
        self.window = window
        reslice()
    }

    private func reslice() {
        guard let raw else { return }
        windows = DayWindows.slice(raw, window: window)
    }
}

// MARK: - The card

struct RecentMorningsCard: View {
    let windows: [DayWindow]
    let window: ClockWindow
    /// The day being asked about — yesterday, since today's morning is still
    /// being compared against days that already ended.
    let subject: String

    enum Measure: String, CaseIterable, Identifiable {
        case temperature = "Temperature"
        case dewPoint = "Dew point"
        var id: String { rawValue }

        var path: KeyPath<WindowSample, Double?> {
            switch self {
            case .temperature: return \.temp
            case .dewPoint: return \.dewPoint
            }
        }

        /// Lower-cased for mid-sentence use, which is where the engine puts it.
        var name: String { rawValue.lowercased() }
    }

    @State private var measure: Measure = .temperature

    /// The last ten days is a reading limit, not a data one — the fetch holds a
    /// month, and past about ten lines the chart stops being legible.
    private var shown: [DayWindow] { DayWindows.recent(windows, count: 10) }

    private var standout: WindowStandout? {
        DayWindows.standout(shown, day: subject,
                            measure: measure.path, measureName: measure.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if let standout {
                    Text(standout.sentence(subject: subjectLabel))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Not enough fully-recorded \(windowNoun)s in the last ten days to compare.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Picker("", selection: $measure) {
                    ForEach(Measure.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }

            WindowOverlayChart(days: shown, window: window,
                               measure: measure.path, subject: subject)

            legend
        }
    }

    private var subjectLabel: String { "Yesterday \(windowNoun)" }

    private var windowNoun: String {
        window.startHour < 12 ? "morning" : "afternoon"
    }

    private var legend: some View {
        HStack(spacing: 14) {
            label(color: .accentColor, text: subjectLabel, bold: true)
            label(color: .secondary, text: "Other \(windowNoun)s", bold: false)
            if shown.contains(where: { !$0.isReliable }) {
                label(color: .secondary, text: "Dashed: partly recorded", bold: false)
            }
            Spacer(minLength: 0)
        }
        .font(.caption2).foregroundStyle(.tertiary)
    }

    private func label(color: Color, text: String, bold: Bool) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 14, height: bold ? 3 : 1.5)
            Text(text)
        }
    }
}

// MARK: - The chart

/// One line per day over a shared clock axis and a shared measure axis.
struct WindowOverlayChart: View {
    let days: [DayWindow]
    let window: ClockWindow
    let measure: KeyPath<WindowSample, Double?>
    let subject: String

    private var scale: ClosedRange<Double> {
        let values = days.flatMap { $0.samples.compactMap { $0[keyPath: measure] } }
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        // A little air top and bottom so a line never rides the frame edge.
        let pad = max(1, (hi - lo) * 0.12)
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                axisLabels
                GeometryReader { geo in
                    ZStack {
                        gridLines(in: geo.size)
                        ForEach(days) { day in
                            line(for: day, in: geo.size)
                        }
                    }
                }
                .frame(height: 180)
            }
            hourLabels
                .padding(.leading, 44)
        }
    }

    private func x(_ minuteOfDay: Int, width: CGFloat) -> CGFloat {
        let span = Double(window.hours * 60)
        guard span > 0 else { return 0 }
        let t = (Double(minuteOfDay) - Double(window.startHour * 60)) / span
        return width * min(1, max(0, t))
    }

    private func y(_ value: Double, height: CGFloat) -> CGFloat {
        let span = scale.upperBound - scale.lowerBound
        guard span > 0 else { return height / 2 }
        return height * (1 - (value - scale.lowerBound) / span)
    }

    @ViewBuilder
    private func line(for day: DayWindow, in size: CGSize) -> some View {
        let isSubject = day.day == subject
        let points = day.samples.compactMap { s -> CGPoint? in
            guard let v = s[keyPath: measure] else { return nil }
            return CGPoint(x: x(s.minuteOfDay, width: size.width), y: y(v, height: size.height))
        }
        if points.count > 1 {
            Path { p in
                p.move(to: points[0])
                for point in points.dropFirst() { p.addLine(to: point) }
            }
            .stroke(isSubject ? Color.accentColor : Color.secondary,
                    style: StrokeStyle(lineWidth: isSubject ? 2.5 : 1.2,
                                       lineCap: .round, lineJoin: .round,
                                       dash: day.isReliable ? [] : [3, 3]))
            // The other days recede so the subject reads first, but they stay
            // individually visible — the spread is what makes "apart" mean
            // anything.
            .opacity(isSubject ? 1 : 0.4)
        }
    }

    private func gridLines(in size: CGSize) -> some View {
        ForEach(gridValues, id: \.self) { value in
            Path { p in
                let yPos = y(value, height: size.height)
                p.move(to: CGPoint(x: 0, y: yPos))
                p.addLine(to: CGPoint(x: size.width, y: yPos))
            }
            .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    /// Round values inside the scale, so the gridlines are numbers a reader
    /// recognises rather than wherever the data happened to land.
    private var gridValues: [Double] {
        let step: Double = (scale.upperBound - scale.lowerBound) > 25 ? 10 : 5
        var values: [Double] = []
        var v = (scale.lowerBound / step).rounded(.up) * step
        while v <= scale.upperBound {
            values.append(v)
            v += step
        }
        return values
    }

    private var axisLabels: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(gridValues.reversed(), id: \.self) { value in
                Text("\(Int(value))°")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(width: 36, height: 180)
    }

    private var hourLabels: some View {
        HStack(spacing: 0) {
            ForEach(Array(stride(from: window.startHour, through: window.endHour, by: 1)), id: \.self) { hour in
                Text(hourText(hour))
                    .font(.caption2).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: hour == window.startHour ? .leading
                                                        : (hour == window.endHour ? .trailing : .center))
            }
        }
    }

    private func hourText(_ hour: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        return "\(h)\(hour < 12 ? "am" : "pm")"
    }
}
