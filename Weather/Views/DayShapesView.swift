//
//  DayShapesView.swift  (macOS)
//
//  "Was yesterday morning different from the mornings before it?" — and, now
//  that it is a surface rather than a card, the same question about any stretch
//  of clock and any day in the last month.
//
//  WHAT IT WAS. A card at the bottom of the Now scroll called "Recent mornings",
//  wired to exactly one window (6–10am) and one subject (yesterday). Everything
//  under it was already general — `DayWindows.slice` takes any `ClockWindow`,
//  `WindowOverlayChart` takes any measure and any subject day, and
//  `RecentWindowsModel.show` re-slices what it already holds WITHOUT touching
//  the network. `ClockWindow.afternoon` had been defined and never once used.
//  So the card was showing one-eighth of a thing that was already built and
//  paid for, from a page whose every other card is anchored to today.
//
//  WHY IT LIVES UNDER HISTORY. Its subject is a finished day — it has to be,
//  since a morning still in progress can't be compared to ones that ended. That
//  is the archive's register, not Now's. It also costs a 29-day raw fetch, which
//  has no business running at launch for a card most of the way down a scroll;
//  under History it is fetched when the surface is first opened.
//
//  Every other archive surface reads DailyRecords. This one can't: a day's min
//  and max say nothing about the shape inside it, and the question is entirely
//  about that shape. So it re-fetches raw half-hourly observations for the last
//  month — one request, because bucket=30 caps a window at 30 days and ten
//  mornings therefore cost the same as two.
//
//  Nothing is stored. This is a live comparison of the recent past, not a second
//  archive; if it turns out to be something you look at every day, THAT's when
//  keeping the samples earns its disk.
//
//  The chart is ordinary on purpose: one line per day, all on one measure axis,
//  clock time along the bottom. The comparison IS the overlay — a reader should
//  be able to see the subject day sitting apart, or not, without decoding an
//  encoding.
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

    /// Days actually present in the fetch, newest first — what the subject-day
    /// stepper walks. Derived rather than stored so it can never disagree with
    /// the windows on screen.
    var availableDays: [String] { windows.map(\.day).sorted(by: >) }

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

// MARK: - The surface

/// The controls the old card had hardcoded: which stretch of clock, which
/// measure, and which day is the one being asked about.
struct DayShapesCard: View {
    @ObservedObject var model: RecentWindowsModel

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
    /// Nil means "the most recent day we have", which is what the card always
    /// showed and is still the right thing to open on. Held as an override
    /// rather than seeded, so the default survives the window changing under it.
    @State private var pinnedSubject: String?

    /// The last ten days is a READING limit, not a data one — the fetch holds a
    /// month, and past about ten lines the chart stops being legible. Ten ending
    /// at the subject, so stepping back walks a window through the month rather
    /// than shortening it to nothing.
    private var shown: [DayWindow] {
        guard let subject else { return DayWindows.recent(model.windows, count: 10) }
        let upTo = model.windows.filter { $0.day <= subject }
        return DayWindows.recent(upTo, count: 10)
    }

    private var subject: String? { pinnedSubject ?? model.availableDays.first }

    private var standout: WindowStandout? {
        guard let subject else { return nil }
        return DayWindows.standout(shown, day: subject,
                                   measure: measure.path, measureName: measure.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            controls
            finding
            WindowOverlayChart(days: shown, window: model.window,
                               measure: measure.path, subject: subject ?? "")
            legend
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 14) {
            Picker("", selection: Binding(
                get: { model.window },
                // Free: the fetch holds a month of raw samples and a different
                // window is a re-slice, never a request. See `RecentWindowsModel.show`.
                set: { model.show($0) })) {
                ForEach(ClockWindow.presets, id: \.startHour) { w in
                    Text(w.name.capitalized).tag(w)
                }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 260)

            Text(model.window.label)
                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)

            Spacer(minLength: 0)

            Picker("", selection: $measure) {
                ForEach(Measure.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 200)
        }
    }

    /// The subject stepper reads as a date rather than as an index, because the
    /// question is "what was Tuesday like" and not "what was day seven like".
    private var subjectStepper: some View {
        let days = model.availableDays
        let index = subject.flatMap { days.firstIndex(of: $0) } ?? 0
        return HStack(spacing: 6) {
            Button { step(to: index + 1, in: days) } label: { Image(systemName: "chevron.left") }
                .disabled(index + 1 >= days.count)
            Text(subjectLabel).font(.callout.weight(.medium)).frame(minWidth: 108)
            Button { step(to: index - 1, in: days) } label: { Image(systemName: "chevron.right") }
                .disabled(index <= 0)
            if pinnedSubject != nil {
                Button("Latest") { pinnedSubject = nil }.buttonStyle(.link).font(.caption)
            }
        }
        .buttonStyle(.borderless)
    }

    private func step(to index: Int, in days: [String]) {
        guard days.indices.contains(index) else { return }
        pinnedSubject = days[index]
    }

    @ViewBuilder private var finding: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let standout {
                Text(standout.sentence(subject: subjectLabel))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Not enough fully-recorded \(model.window.name)s around this day to compare.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            subjectStepper
        }
    }

    /// "Yesterday morning" only when it IS yesterday. Once the stepper has moved,
    /// a label that still said "yesterday" would be describing a different day
    /// from the one drawn in bold.
    private var subjectLabel: String {
        guard let subject else { return "—" }
        guard let date = DayKey.date(from: subject, timeZone: .current) else { return subject }
        let calendar = Calendar.current
        if calendar.isDateInYesterday(date) { return "Yesterday \(model.window.name)" }
        if calendar.isDateInToday(date) { return "This \(model.window.name)" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private var legend: some View {
        HStack(spacing: 14) {
            label(color: .accentColor, text: subjectLabel, bold: true)
            label(color: .secondary, text: "Other \(model.window.name)s", bold: false)
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
