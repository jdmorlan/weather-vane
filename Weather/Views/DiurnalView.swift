//
//  DiurnalView.swift  (macOS)
//
//  The shape of a day here, twelve months deep: midnight to midnight across,
//  January to December down, the reading as colour.
//
//  WHY A MATRIX AND NOT TWELVE CURVES. Twelve overlaid line charts is the
//  obvious drawing and it fails at the one question worth asking, which is not
//  "how warm is a July afternoon" — the year chart answers that — but "does the
//  afternoon peak LATER in July than in January". That is a comparison of
//  positions along a shared axis, twelve times over, and twelve overlapping
//  curves turn it into untangling. Stack them as rows and the answer is the
//  slant of a line through the marks.
//
//  THE RAMP IS SHARED BY EVERY ROW, deliberately, and it is the decision most
//  worth defending. Normalising each month against its own range would make
//  every afternoon the same shade of hot and every dawn the same shade of cold —
//  a chart that looks informative and has thrown away the comparison it exists
//  for. One ramp across the whole matrix means January reads as genuinely
//  colder than July, and the diagonal you can see is real.
//
//  THE PEAK LINE IS THE FINDING. Marks alone leave the reader to sight down a
//  column; the thread through them turns the seasonal lag into a shape you see
//  before reading a single label. The trough marks get the same treatment for
//  temperature, because the day's coldest minute landing at sunrise rather than
//  at midnight is the other thing in here nobody knows about their own yard.
//
//  A SLOT NOTHING WAS RECORDED IN DRAWS AS A HOLE — the same rule the season
//  strips keep. On this chart it matters more than usual: a station that came
//  online at noon has no 3am, and a zero there would draw as the coldest hour on
//  record.
//

import SwiftUI
import WeatherKit

struct DiurnalView: View {
    let climate: DiurnalClimate
    let measure: DiurnalMeasure

    private let labelWidth: CGFloat = 46
    private let rowHeight: CGFloat = 26
    private let rowGap: CGFloat = 3

    /// Every month that has something to say, in calendar order. A month the
    /// archive has never watched is left out of the chart rather than drawn as
    /// an empty row — twelve rows with three blanks reads as a broken chart,
    /// nine rows reads as nine months of record.
    private var months: [(month: Int, profile: DiurnalProfile)] {
        (1...12).compactMap { month in
            guard let profile = climate.byMonth[month],
                  profile.values(measure).contains(where: { $0 != nil }) else { return nil }
            return (month, profile)
        }
    }

    private var range: (low: Double, high: Double)? { climate.range(measure) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(months, id: \.month) { entry in
                    monthRow(entry.month, profile: entry.profile)
                }
            }
            // An overlay rather than a layer inside each row: the whole point of
            // the thread is that it crosses rows, and nothing drawn inside a row
            // can reach the one below it.
            .overlay { peakThread }
            clockAxis
        }
    }

    /// The seasonal lag, drawn.
    ///
    /// The marks already say where each month peaks; this says that the peaks
    /// MOVE, which is the finding and is otherwise left to the reader to sight
    /// down a column and discover. Thin and half-transparent on purpose — the
    /// marks are the data and this is the line through them.
    private var peakThread: some View {
        GeometryReader { geo in
            let plot = max(1, geo.size.width - labelWidth - 8)
            Path { path in
                for (index, entry) in months.enumerated() {
                    guard let peak = entry.profile.extremes(measure)?.peak else { continue }
                    let point = CGPoint(x: labelWidth + 8 + x(peak, in: plot),
                                        y: CGFloat(index) * (rowHeight + rowGap) + rowHeight / 2)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            .stroke(.white.opacity(0.55),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
    }

    private func x(_ slot: Int, in width: CGFloat) -> CGFloat {
        width * CGFloat(slot) / CGFloat(DiurnalClimate.slotCount)
    }

    // MARK: One month

    private func monthRow(_ month: Int, profile: DiurnalProfile) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(YearAxis.months[month - 1].name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)

            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .topLeading) {
                    strip(profile, width: width)
                    sixHourLines(width: width)
                    marks(profile, width: width)
                }
            }
            .frame(height: rowHeight)
        }
        .padding(.bottom, rowGap)
    }

    /// The month's mean reading for each quarter hour, as colour.
    private func strip(_ profile: DiurnalProfile, width: CGFloat) -> some View {
        let series = profile.values(measure)
        let tint = color
        let span = range
        return Canvas { context, size in
            let slot = size.width / CGFloat(max(1, series.count))
            for (index, value) in series.enumerated() {
                guard let value, let span else { continue }
                let position = (value - span.low) / max(0.001, span.high - span.low)
                let rect = CGRect(x: CGFloat(index) * slot - 0.5, y: 0,
                                  width: slot + 1, height: size.height)
                context.fill(Path(rect), with: .color(tint.opacity(0.10 + 0.78 * position)))
            }
        }
        .frame(width: width, height: rowHeight)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// Midnight, six, noon, six. Four lines rather than a tick every hour: this
    /// axis is read for QUARTERS of the day, and hourly rules would turn the
    /// matrix into graph paper and compete with the marks.
    private func sixHourLines(width: CGFloat) -> some View {
        ForEach([0, 24, 48, 72], id: \.self) { slot in
            Rectangle()
                .fill(Color.primary.opacity(slot == 48 ? 0.16 : 0.09))
                .frame(width: 1, height: rowHeight)
                .offset(x: x(slot, in: width))
        }
    }

    /// Where this month peaks, and — for temperature — where it bottoms out.
    @ViewBuilder
    private func marks(_ profile: DiurnalProfile, width: CGFloat) -> some View {
        if let extremes = profile.extremes(measure) {
            Rectangle()
                .fill(.white.opacity(0.9))
                .frame(width: 3, height: rowHeight)
                .offset(x: x(extremes.peak, in: width) - 1)
                .help(peakHelp(profile, slot: extremes.peak))

            if measure == .temperature {
                Rectangle()
                    .fill(.black.opacity(0.45))
                    .frame(width: 3, height: rowHeight)
                    .offset(x: x(extremes.trough, in: width) - 1)
                    .help("Coldest around \(Self.clock(extremes.trough)) — near sunrise, not midnight.")
            }
        }
    }

    private func peakHelp(_ profile: DiurnalProfile, slot: Int) -> String {
        var text = "\(measure.name) peaks around \(Self.clock(slot))"
        if let value = profile.values(measure)[slot] {
            text += " at \(Int(value.rounded()))\(measure.unit)"
        }
        if let swing = profile.swing(measure) {
            text += ". It travels \(Int(swing.rounded()))\(measure.unit) across the day"
        }
        return text + "."
    }

    // MARK: Axis

    private var clockAxis: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: labelWidth)
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ForEach([0, 24, 48, 72, 96], id: \.self) { slot in
                        Text(Self.clock(slot, short: true))
                            .font(.system(size: 10, weight: slot == 48 ? .semibold : .regular))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .frame(width: 44, alignment: .center)
                            // The two ends are pulled inside the plot rather
                            // than hanging off it; midnight is on both edges and
                            // would otherwise be half-clipped twice.
                            .offset(x: min(max(x(slot, in: geo.size.width) - 22, 0),
                                           max(0, geo.size.width - 44)))
                    }
                }
            }
            .frame(height: 16)
            .padding(.top, 4)
        }
    }

    /// A slot as a wall-clock time.
    ///
    /// Rounded to the quarter hour it stands for and never finer — see
    /// `DiurnalClimate`'s header on why claiming the minute would be a lie about
    /// a curve that is flat near its top.
    static func clock(_ slot: Int, short: Bool = false) -> String {
        let minute = DiurnalClimate.minuteOfDay(ofSlot: slot % DiurnalClimate.slotCount)
        let hour24 = minute / 60
        let minutes = minute % 60
        let suffix = hour24 < 12 ? "am" : "pm"
        let hour = hour24 % 12 == 0 ? 12 : hour24 % 12
        if short { return minutes == 0 ? "\(hour)\(suffix)" : "\(hour):\(String(format: "%02d", minutes))\(suffix)" }
        return minutes == 0 ? "\(hour) \(suffix)" : "\(hour):\(String(format: "%02d", minutes)) \(suffix)"
    }

    /// One hue per measure, sequential rather than categorical — this is a
    /// magnitude on a shared scale, and a rainbow would invent boundaries the
    /// data doesn't have. Temperature and dew point keep the colours they wear
    /// on the year chart so a reader doesn't have to relearn the page.
    private var color: Color {
        switch measure {
        case .temperature: return .orange
        case .dewPoint: return .teal
        case .wind: return .cyan
        }
    }
}
