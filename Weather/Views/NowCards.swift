//
//  NowCards.swift  (Weather)
//
//  The cards that answer "what is it like right now, and what's coming" — as
//  views that stand on their own rather than as functions inside `WeatherView`.
//
//  WHY THEY MOVED. They were private to the Mac dashboard, which also owns the
//  archive, the backfill, Explore and every other destination. The iPhone wants
//  exactly these cards and none of that: it is a live, archive-free app, and it
//  should not have to construct `StationModels` to draw a temperature. So each
//  card takes what it reads as plain values — the report, today's strip, and at
//  most one optional fact from the archive — and a device with no archive simply
//  passes nil for it.
//
//  THE ARCHIVE'S ONE FOOTHOLD HERE is `pressureBand`: the station's own record
//  is what turns 30.10 inHg into "lower than all but a handful of days". Nil is
//  a complete answer, not a degraded one — the instrument draws without its band.
//

import SwiftUI
import WeatherKit

// MARK: - The card itself

/// The dashboard's one container: a small-caps label over whatever it holds.
struct StationCard<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(label.uppercased())
                .font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.07)))
    }
}

// MARK: - Today's strip

extension DayStrip {
    /// Today as one strip: the station's own minutes up to now, the forecast after.
    static func today(_ r: WeatherReport, samples: [StationSample]) -> DayStrip {
        let tz = r.timezone ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        // Same fallback the interpreter uses when the daily forecast carries no
        // sun times — 6am to 8pm, wrong by an hour rather than absent.
        func clockHour(_ epoch: Int) -> Int {
            calendar.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(epoch)))
        }
        let sunrise = r.days.first?.sunrise.map(clockHour) ?? 6
        let sunset = r.days.first?.sunset.map(clockHour) ?? 20
        return DayStrip.build(day: DayKey.string(for: Date(), timeZone: tz),
                              samples: samples,
                              forecast: r.hours,
                              timeZone: tz,
                              sunriseHour: sunrise,
                              sunsetHour: sunset)
    }
}

// MARK: - Station alerts

/// The Tempest's own alerts (lightning nearby and the like) — only when there are
/// any. Distinct from `HazardBanner`, which is the NWS speaking.
struct StationAlertsBanner: View {
    let report: WeatherReport

    var body: some View {
        if !report.alerts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(report.alerts, id: \.self) { text in
                    Text(text)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Right now — conditions, the numbers behind them, and where they sit

/// One card for "what is it like out there this second": the headline sentence, the
/// reading, the stat tiles, the comfort gauges that place those readings on a scale,
/// and the daylight arc. These were four cards that all answered the same question,
/// and they repeated each other (sunrise twice, dew point three times).
struct RightNowCard: View {
    let report: WeatherReport
    let strip: DayStrip
    /// The station's own pressure record, from the archive. Nil where there is
    /// no archive, and the instrument draws without its band.
    var pressureBand: PressureBand?
    /// Inches per hour from the station's newest wet minute, while it's raining.
    /// The conditions word alone ("Moderate Rain") says nothing about how much.
    var rainRate: Double?

    @EnvironmentObject private var settings: AppSettings
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// A phone, or an iPad pane in Slide Over. The instrument column is 300pt
    /// wide, which beside the readings is more than a phone has in total — so
    /// there it goes underneath instead. A size class rather than `ViewThatFits`
    /// because the readings' IDEAL width is their headline on one line, and a
    /// long headline would have flipped the Mac into the stacked form too.
    private var isCompact: Bool {
        #if os(iOS)
        return sizeClass == .compact
        #else
        return false
        #endif
    }

    private var r: WeatherReport { report }

    var body: some View {
        StationCard(label: "Right now") {
            if isCompact {
                VStack(alignment: .leading, spacing: 18) {
                    readings
                    if hasInstruments {
                        Divider()
                        instruments
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 26) {
                    readings
                        .frame(maxWidth: .infinity)

                    // Two instruments about the same thing — where things are around
                    // you — so they share the column.
                    instruments
                        .frame(width: 300)
                }
            }
        }
    }

    private var readings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                if let t = r.temperature {
                    Text("\(Int(t.rounded()))°")
                        .font(.system(size: 58, weight: .thin, design: .rounded))
                        .lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 4) {
                    conditionsLine.font(.title3.weight(.medium))
                    // No "feels like" here: the gauge below states it AND places
                    // it on a scale, which is strictly more than this line said.
                    todayHiLo.font(.headline)
                }
                Spacer(minLength: 0)
                Image(systemName: WeatherView.symbol(r.icon))
                    .font(.system(size: 38)).symbolRenderingMode(.multicolor)
                    .foregroundStyle(.tint)
            }
            // The interpreter's one-line answer, which the dashboard never showed.
            Text(r.headline).font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            comfortGauges
            pressureRow
        }
    }

    /// Tempest's conditions word, except while the station is measuring rain:
    /// then the word comes from the measured rate, with the rate beside it.
    /// Tempest's "Moderate Rain" over a 0.06 in/hr reading put a word and a
    /// number side by side that disagreed — and the rain card below, which uses
    /// the same scale as this, said "light".
    private var conditionsLine: Text {
        guard let rate = rainRate else { return Text(r.conditions) }
        let word = RainIntensity.of(rate: rate).label.capitalized
        let number = Text(String(format: "(%.2f in/hr)", rate))
            .font(.callout.weight(.medium)).monospacedDigit()
            .foregroundStyle(Color.accentColor)
        return Text("\(word) \(number)")
    }

    private var hasInstruments: Bool {
        (r.days.first?.sunrise != nil && r.days.first?.sunset != nil) || r.windDirection != nil
    }

    private var instruments: some View {
        let today = r.days.first
        return VStack(alignment: .leading, spacing: 16) {
            if today?.sunrise != nil, today?.sunset != nil { daylight }
            if r.windDirection != nil {
                if today?.sunrise != nil { Divider() }
                windFacing
            }
        }
    }

    /// Pressure was the one tile whose number meant nothing to anybody: 30.10 inHg has
    /// no felt referent, and the band it moves in is so narrow that the digits look
    /// frozen. The fix isn't a better label, it's a REFERENT — the station's own record,
    /// so the reading becomes "lower than all but a handful of days here". See
    /// `PressureInstrument`, and `PressureBand` for where the band comes from.
    @ViewBuilder private var pressureRow: some View {
        let precip = r.precipToday ?? 0
        if r.pressure.current != nil || precip > 0 {
            HStack(alignment: .top, spacing: 22) {
                if r.pressure.current != nil {
                    PressureInstrument(current: r.pressure.current,
                                       trend: r.pressure.trend,
                                       delta3h: r.pressure.delta3h,
                                       band: pressureBand,
                                       trace: r.hours.compactMap(\.pressure))
                }
                Spacer(minLength: 0)
                // A 0.00 is not a reading, it's the absence of one. Rain that has
                // actually fallen today is worth a number; a dry day says nothing.
                if precip > 0 {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("RAIN TODAY").font(.caption2.weight(.semibold)).tracking(0.5)
                            .foregroundStyle(.tertiary)
                        Text(String(format: "%.2f in", precip))
                            .font(.callout.weight(.semibold)).foregroundStyle(.blue)
                    }
                }
            }
        }
    }

    // MARK: Wind, relative to you

    /// The dial says all of it — speed in the middle, direction as the picture, the
    /// issued bearing still readable off the ring, and the one line the picture can't say
    /// underneath. So there is no wind text anywhere else on the card: a paragraph beside
    /// an instrument is the instrument admitting it didn't work.
    @ViewBuilder private var windFacing: some View {
        if let from = r.windDirection {
            WindDial(from: from, speed: r.windAvg, gust: r.windGust, facing: settings.facing,
                     onFace: { settings.homeFacing = $0 })
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Daylight (lives inside this card — sunrise/sunset used to print twice)

    @ViewBuilder private var daylight: some View {
        if let today = r.days.first {
            let tomorrowSunrise = r.days.count > 1 ? StationClock.date(r.days[1].sunrise) : nil
            DaylightArc(sunrise: StationClock.date(today.sunrise),
                        sunset: StationClock.date(today.sunset),
                        nextSunrise: tomorrowSunrise,
                        now: Date(),
                        time: { d in d.map { StationClock.time($0, r) } ?? "—" })
        }
    }

    // MARK: Comfort gauges — where the current readings sit, and what the scale means

    @ViewBuilder private var comfortGauges: some View {
        // Stacked on a phone: side by side at that width each gauge gets about
        // 150pt, and its five zone labels truncate to "Co… Sti… Mu…".
        let layout = isCompact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 22))
        if r.comfort.dewPoint != nil || r.feelsLike != nil {
            layout {
                if let dew = r.comfort.dewPoint {
                    ComfortGauge(
                        title: "DEW POINT",
                        value: dew,
                        valueLabel: [
                            "\(Int(dew.rounded()))°",
                            WeatherInterpreter.dewComfortTag(dew),
                            // Humidity has no home of its own: it's the measurement the
                            // dew point is computed FROM, so it belongs to this gauge.
                            r.comfort.humidity.map { "\(Int($0.rounded()))% RH" }
                        ].compactMap { $0 }.joined(separator: " · "),
                        range: 40...80,
                        zones: [
                            GaugeZone(upper: 55, label: "Dry", color: .teal),
                            GaugeZone(upper: 60, label: "Comfortable", color: .green),
                            GaugeZone(upper: 65, label: "Sticky", color: .yellow),
                            GaugeZone(upper: 70, label: "Muggy", color: .orange),
                            GaugeZone(upper: 80, label: "Oppressive", color: .red),
                        ])
                    .frame(maxWidth: .infinity)
                }
                if let feels = r.feelsLike {
                    ComfortGauge(
                        title: "FEELS LIKE",
                        value: feels,
                        valueLabel: "\(Int(feels.rounded()))°",
                        range: 30...110,
                        zones: [
                            GaugeZone(upper: 45, label: "Cold", color: .blue),
                            GaugeZone(upper: 65, label: "Cool", color: .teal),
                            GaugeZone(upper: 80, label: "Comfortable", color: .green),
                            GaugeZone(upper: 92, label: "Hot", color: .orange),
                            GaugeZone(upper: 110, label: "Dangerous", color: .red),
                        ],
                        secondary: r.temperature.map { (value: $0, label: "actual \(Int($0.rounded()))°") })
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: Today's extremes

    /// Today's extremes, each labelled by whether it has HAPPENED yet.
    ///
    /// `88° / 61°` was a forecast pair pretending to be a description of the day,
    /// and by mid-morning half of it was already a matter of record while the
    /// other half was still a guess — printed identically. Worse, a low is a
    /// scalar with no time on it, so "61°" told you nothing about whether the
    /// morning you walked out into was cool: a low reached at 4am and one reached
    /// at 8am are the same number and different days.
    ///
    /// So each side takes the more extreme of what was measured and what is
    /// forecast, and says which it is. A measured one carries the moment.
    @ViewBuilder private var todayHiLo: some View {
        let high = extremeLine(strip.high, forecast: r.days.first?.high, isHigh: true)
        let low = extremeLine(strip.low, forecast: r.days.first?.low, isHigh: false)
        // Before the station has beaten either forecast there's nothing to
        // distinguish, and two lines both ending in "expected" is the same pair
        // of numbers spread over more screen. Fall back to the compact form.
        if high?.measured != true && low?.measured != true {
            hiLo(r.days.first?.high, r.days.first?.low)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                if let high { Text(high.text).fontWeight(.semibold) }
                if let low { Text(low.text).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder private func hiLo(_ high: Double?, _ low: Double?) -> some View {
        HStack(spacing: 6) {
            if let high { Text("\(Int(high.rounded()))°").fontWeight(.semibold) }
            if high != nil && low != nil { Text("/").foregroundStyle(.tertiary) }
            if let low { Text("\(Int(low.rounded()))°").foregroundStyle(.secondary) }
        }
    }

    private func extremeLine(_ observed: ObservedExtreme?, forecast: Double?,
                             isHigh: Bool) -> (text: String, measured: Bool)? {
        // The measurement wins only where it has actually gone past the forecast.
        // Short of that the day still has room to get there, so the forecast is
        // the more honest number and it says so.
        if let observed, forecast.map({ isHigh ? observed.value >= $0 : observed.value <= $0 }) ?? true {
            return ("\(Int(observed.value.rounded()))° at \(StationClock.moment(observed.date, r))", true)
        }
        if let forecast { return ("\(Int(forecast.rounded()))° expected", false) }
        return observed.map { ("\(Int($0.value.rounded()))°", true) }
    }
}

// MARK: - Today — the whole day, at the resolution it happens in

/// The day-part cards that used to sit above this were a downsample of the hourly
/// strip, and the strip itself was a row of boxes spending equal ink on every hour.
/// Both are gone. What the cards had that a figure doesn't is WORDS — the shape
/// sentence and the heads-up lines — so those lead, and the day itself is one
/// continuous drawing: `HourlyRibbon`.
///
/// It used to start at NOW, which meant the morning stopped existing by lunch.
/// It now runs midnight to midnight over `DayStrip` — measured behind the seam,
/// forecast ahead of it — so "how cool was it at eight" is a question the card
/// can answer at ten. See DayStrip.swift for why the frame is fixed.
struct TodayCard: View {
    let report: WeatherReport
    let strip: DayStrip

    private var r: WeatherReport { report }

    var body: some View {
        let rows = headsUpRows
        let sentence = todaySentence
        // WITH NOTHING MEASURED THERE IS NO TODAY-SO-FAR TO DRAW, and a
        // midnight-anchored frame would spend its whole left half on blank
        // columns — a worse card than the one this replaced. So a failed or
        // unfinished fetch falls back to the forward-looking strip rather than
        // rendering an empty morning as if the morning hadn't happened.
        let hours = strip.hasObservations ? strip.hours : r.hours
        if !hours.isEmpty || !rows.isEmpty || sentence != nil {
            StationCard(label: strip.hasObservations ? "Today" : "Hourly") {
                VStack(alignment: .leading, spacing: 14) {
                    if let sentence {
                        Text(sentence).font(.callout.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(rows.indices, id: \.self) { i in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Image(systemName: rows[i].0).foregroundStyle(.tint).frame(width: 20)
                                    Text(rows[i].1).font(.callout)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                    if !hours.isEmpty {
                        if sentence != nil || !rows.isEmpty { Divider() }
                        HourlyRibbon(hours: hours, timezone: r.timezone)
                        // Said once, because the two halves of the curve are a
                        // claim about evidence and a legend is cheaper than
                        // hoping a dash reads as doubt. Absent when the station
                        // hasn't filled anything in — there'd be no contrast.
                        if strip.hasObservations {
                            Text("Solid: measured at the station  ·  Dashed: forecast")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private var headsUpRows: [(String, String)] {
        var rows: [(String, String)] = []
        if r.rain.willRain { rows.append(("cloud.rain", r.rain.text)) }
        if r.wind.isNotable { rows.append(("wind", r.wind.text)) }
        if r.pressure.isNotable {
            rows.append((r.pressure.trend == "falling" ? "arrow.down.right.circle" : "arrow.up.right.circle",
                         r.pressure.text))
        }
        // The headline is drawn from these same notes, so drop whichever one it already
        // said rather than printing the sentence twice on one screen.
        return rows.filter { $0.1 != r.headline }
    }

    /// How today feels as one line. Empty when the headline already said it — the
    /// screen shouldn't state the same weather twice.
    private var todaySentence: String? {
        guard let today = r.days.first else { return nil }
        if !today.shape.isEmpty { return today.shape == r.headline ? nil : today.shape }
        if let dew = today.dewPoint {
            return "Humidity holds steady — dew point around \(Int(dew.rounded()))°, \(WeatherInterpreter.dewComfortTag(dew).lowercased()) start to finish."
        }
        return nil
    }
}

// MARK: - 10-day

/// Ten day boxes made you difference ten pairs of numbers by eye to answer the
/// only questions a week-out forecast gets asked — when does it break, when does
/// the muggy stretch end, which day does the rain land on. The grid is gone; the
/// week is one figure. The words that the boxes couldn't hold lead, as in Hourly.
///
/// `header` is the forecast's own report card on the Mac, where there is a
/// History to send "Detail" to. It is a slot rather than a model because the
/// grade needs the forecast log's finished days, and a device that has kept no
/// log has nothing to put there.
struct TenDayCard<Header: View>: View {
    let report: WeatherReport
    @ViewBuilder var header: Header

    var body: some View {
        StationCard(label: "10-day forecast") {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let week = report.weekComfort {
                    Text(week).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                OutlookRibbon(days: report.days, timezone: report.timezone)
                HStack(spacing: 10) {
                    legendSwatch(.orange, "high")
                    legendSwatch(.blue.opacity(0.75), "low")
                    if report.days.contains(where: { !$0.parts.isEmpty }) {
                        Text("humidity: night · morning · afternoon · evening")
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    Text("\(Platform.pointVerb) a day for the rest").foregroundStyle(.tertiary)
                }
                .font(.caption2)
            }
        }
    }

    private func legendSwatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 10, height: 2.5)
            Text(label).foregroundStyle(.secondary)
        }
    }
}

extension TenDayCard where Header == EmptyView {
    init(report: WeatherReport) {
        self.init(report: report) { EmptyView() }
    }
}

// MARK: - Time formatting (station-local)

/// Times as the station's clock reads them, not the device's — a phone carried
/// two time zones away should still say the low was at 6:40 AM at home.
enum StationClock {
    static func date(_ epoch: Int?) -> Date? {
        epoch.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    static func time(_ d: Date, _ r: WeatherReport) -> String {
        let f = DateFormatter()
        f.timeZone = r.timezone
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "h:mm a"
        return f.string(from: d)
    }

    /// With its day, in the station's zone: "yesterday 11:50 PM".
    static func moment(_ d: Date, _ r: WeatherReport) -> String {
        When.moment(d, calendar: calendar(r))
    }

    static func calendar(_ r: WeatherReport) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = r.timezone ?? .current
        c.locale = Locale(identifier: "en_US")
        return c
    }
}
