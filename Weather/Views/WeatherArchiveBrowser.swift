//
//  WeatherArchiveBrowser.swift
//  Almanac
//
//  THE HISTORY TAB IS A BROWSER, and it needs a stepper to be one.
//
//  The old surface offered `[ Months | Seasons | Recent | Custom ]` and then a
//  wrap of chips. Every control in it was a JUMP-TO: it could only take you
//  somewhere you had already decided to go. That's fine for answering a
//  question and useless for having one — which is why the period cards, and
//  everything built into them, went unfound. Registering a surface is not the
//  same as making it reachable.
//
//  What replaces it is Tempest's shape — a GRAIN and a POSITION you walk with
//  arrows — plus the one axis a live-station app has no reason to want:
//
//      [ Day │ Week │ Month │ Season │ Year │ All time ]
//              ‹     September 2025     ›
//              [ ● compare all Septembers ]
//
//  Moving is cheaper than choosing, so you can wander into a question. And the
//  second row means a position can be held in ONE year or pooled across every
//  year on record — "September 2025" and "every September" being the same
//  window read two ways, which is the comparison the local archive exists to
//  make.
//
//  Every card in the tab is now a lens under this control, including the three
//  that used to float loose at the bottom: `Records & streaks`, `Rainfall` and
//  `Winter chill` never took a period, because they are the whole archive —
//  which is to say they were always the All-time grain, just without a control
//  that could say so.
//

import SwiftUI
import WeatherKit

struct WeatherArchiveBrowser: View {
    let climate: Climatology
    /// Today's key, for the cards that need to know where "now" is.
    let today: String
    let precipToday: Double?
    /// Hands a built query to the Explore tab.
    var onExplore: (DayQuery) -> Void = { _ in }

    @EnvironmentObject private var settings: AppSettings
    /// One day's minutes, re-read whenever the walk lands somewhere new. Owned
    /// here rather than by the card, because the card renders nothing on a dry
    /// day and a view that resolves to `EmptyView` loses its `.task`.
    @StateObject private var dayRain = DayObservationsModel()

    @State private var grain: WeatherGrain = .month
    /// The position, as a real date. A day key rather than a `MM-dd` because the
    /// year is half the address whenever you're reading one instance.
    @State private var anchor: String?
    /// Pooled across every year at this position, or held in the anchor's year.
    ///
    /// Defaults to pooled: opening on "every September" is the view that has
    /// something to say the moment you arrive, where one September needs you to
    /// have picked the right one first.
    @State private var pooled = true

    /// The archive stops at yesterday by design, so that — not today — is the
    /// far end of the walk.
    private var latestDay: String { climate.latestDay ?? today }
    private var position: String { anchor ?? latestDay }
    private var period: WeatherPeriod? { grain.period(containing: position) }
    private var anchorYear: Int { DayKey.year(of: position) ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            controls
            content
        }
        .onAppear { if anchor == nil { anchor = latestDay } }
        // Only where a rain card could show. Walking through months mustn't pull
        // a day of minutes for a view that has nowhere to put them.
        .task(id: rainSubject) {
            guard let day = rainSubject else { return }
            await dayRain.load(day: day, key: day,
                               token: settings.tempestToken,
                               stationID: settings.tempestStationID,
                               timeZone: .current)
        }
    }

    /// The day whose minutes the rain card wants — nil at every other grain.
    private var rainSubject: String? {
        grain == .day && !pooled ? position : nil
    }

    // MARK: The control

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $grain) {
                ForEach(WeatherGrain.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 520)
            .onChange(of: grain) { _, new in
                // A grain that can't pool must not stay pooled — otherwise the
                // toggle vanishes while its state keeps driving the view.
                if !new.canPool { pooled = false }
                if new == .year { pooled = false }
            }

            if grain.isPositional {
                HStack(spacing: 14) {
                    stepper
                    if grain.canPool { poolToggle }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// `‹ September 2025 ›`.
    ///
    /// The arrows step by the grain's OWN width, which is what makes them a walk
    /// rather than a nudge: back from September is August, not August 31st.
    private var stepper: some View {
        HStack(spacing: 6) {
            arrow("chevron.left", by: -1)
            Text(positionLabel)
                .font(.callout.weight(.medium)).monospacedDigit()
                .frame(minWidth: 190)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.16), in: Capsule())
                .overlay(Capsule().stroke(Color.accentColor.opacity(0.35)))
            arrow("chevron.right", by: 1)
        }
    }

    private func arrow(_ symbol: String, by direction: Int) -> some View {
        // Forward past the archive is disabled rather than clamped: an arrow
        // that silently does nothing reads as a broken control, where a dimmed
        // one reads as the end of the record.
        let next = grain.step(position, by: direction)
        let allowed = next.map { canVisit($0) } ?? false
        return Button {
            if let next, allowed { anchor = next }
        } label: {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!allowed)
        .opacity(allowed ? 1 : 0.25)
    }

    /// A position is worth visiting when the archive holds any of it. Pooled,
    /// the year doesn't matter — only the place in the calendar does — so the
    /// walk is free to run the whole cycle.
    private func canVisit(_ day: String) -> Bool {
        guard let first = climate.earliestDay else { return false }
        if pooled { return true }
        guard let period = grain.period(containing: day),
              let bounds = period.bounds(inYear: DayKey.year(of: day) ?? 0) else { return false }
        return bounds.end >= first && bounds.start <= latestDay
    }

    private var positionLabel: String {
        guard let period else { return "All time" }
        switch grain {
        case .day:
            return pooled ? "every \(WeatherAlmanac.dateLabel(DayKey.monthDay(of: position)))"
                          : WeatherAlmanac.dayLabel(position, includeYear: true)
        case .year:
            return String(anchorYear)
        default:
            return pooled ? period.name : "\(period.name) \(anchorYear)"
        }
    }

    private var poolToggle: some View {
        // Named for what it will SHOW, not for the state it's in: "compare all
        // Septembers" says what the click gets you, where "pooled" is a word
        // about the implementation.
        Button {
            pooled.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: pooled ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                    .font(.caption)
                Text(pooled ? "comparing every \(cycleName)" : "compare every \(cycleName)")
                    .font(.callout)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(pooled ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06),
                        in: Capsule())
            .overlay(Capsule().stroke(pooled ? Color.accentColor.opacity(0.35) : .clear))
        }
        .buttonStyle(.plain)
        .help("Read this position in every year on record, rather than in \(anchorYear) alone.")
    }

    /// What one instance of this position is called — "September", "Sep 1".
    private var cycleName: String {
        switch grain {
        case .day: return WeatherAlmanac.dateLabel(DayKey.monthDay(of: position))
        default: return period?.name ?? "one"
        }
    }

    // MARK: The lenses

    @ViewBuilder private var content: some View {
        switch grain {
        case .all:
            allTimeCards
        case .day:
            if pooled { pooledDay } else { pinnedDay }
        default:
            if let period {
                PeriodHistoryView(climate: climate, today: today, period: period,
                                  focusYear: pooled ? nil : anchorYear,
                                  onExplore: onExplore)
            }
        }
    }

    /// The cards that never took a period. They were the All-time grain before
    /// there was one to put them under.
    ///
    /// Winter chill used to be a third one here and isn't: it is not a fact
    /// about the record, it is a fact about the YEAR — what the yard banks each
    /// winter — and it sat between Records and Rainfall with nothing in common
    /// with either. It's on Rhythms. Rainfall followed it out for the same
    /// reason and is on Rain, which left Records & streaks alone here — the one
    /// card that really is about the record rather than about the year.
    @ViewBuilder private var allTimeCards: some View {
        if climate.dayCount >= 30 {
            card(label: "Records & streaks") {
                StreaksAndRecords(climate: climate, today: today, precipToday: precipToday)
            }
        }
    }

    /// Every year's version of one date. The card at the top has been sitting in
    /// the Now tab nailed to today — the only thing it needed to answer "show me
    /// September 1st" was an anchor it didn't pick itself.
    @ViewBuilder private var pooledDay: some View {
        let monthDay = DayKey.monthDay(of: position)
        let history = climate.history(monthDay: monthDay)
        if history.isEmpty {
            emptyNote("The archive holds no \(WeatherAlmanac.dateLabel(monthDay)) yet.")
        } else {
            DayPooledView(history: history,
                          normal: climate.normal(monthDay: monthDay),
                          monthDay: monthDay,
                          emphasis: climate.seasonalEmphasis(monthDay: monthDay))
        }
    }

    @ViewBuilder private var pinnedDay: some View {
        if let record = climate.record(on: position) {
            DayInstanceCard(record: record,
                            normal: climate.normal(monthDay: DayKey.monthDay(of: position)),
                            history: climate.history(monthDay: DayKey.monthDay(of: position),
                                                     excludingYear: anchorYear))
            // The day grain's RAIN row says a total and stops. This is the same
            // card the Now tab uses, pointed at a day in the record: when it
            // rained, how hard, and what that rate meant. The archive is kept in
            // the local zone, so that's the zone its minutes are read back in.
            if let rain = dayRain.rain, rain.hasSomethingToSay {
                RainDayCard(rain: rain, climate: climate)
            }
        } else {
            emptyNote("The archive holds nothing for \(WeatherAlmanac.dayLabel(position, includeYear: true)).")
        }
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
    }

    private func card<Content: View>(label: String, @ViewBuilder _ content: () -> Content) -> some View {
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

// MARK: - One date, every year

/// What a September 1 IS, and what each one actually did.
///
/// This started as a single temperature strip, which made the day the thinnest
/// grain in the tab — one card, one measure, on a page where every other grain
/// gets five. The archive holds thirteen measures for each of these days; the
/// strip was showing one of them.
///
/// Three cards, in the order the questions arrive: what one of these is usually
/// like · where each year landed on the axis · the whole table, because once you
/// have four Septembers in front of you the thing you want is to read across
/// them.
struct DayPooledView: View {
    let history: [HistoricalDay]
    /// Pooled ±7 days across every year — see `usualCaption` for why that has to
    /// be said out loud on a card about ONE date.
    let normal: DailyNormal
    let monthDay: String
    let emphasis: Climatology.TemperatureEmphasis

    private var label: String { WeatherAlmanac.dateLabel(monthDay) }
    /// Years that actually hold this date — NOT `normal.years`, which counts the
    /// window's years. On a date near the end of the archive those differ, and
    /// the strip used to print "4 years of record" beside three points.
    private var yearsHeld: Int { history.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            usualCard
            card(label: "Every \(label) on record") {
                DayRangeRows(history: history, normal: normal, dateLabel: label)
            }
            tableCard
        }
    }

    // MARK: What one of these is like

    private var usualCard: some View {
        card(label: "What a \(label) is like") {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 12) {
                    GridRow {
                        stat("HIGH", degrees(normal.high))
                        stat("LOW", degrees(normal.low))
                        stat("PEAK DEW", degrees(normal.dewPointPeak))
                        stat("HUMIDITY", normal.humidity.map { "\(Int($0.rounded()))%" } ?? "—")
                        stat("GUST", normal.gust.map { "\(Int($0.rounded())) mph" } ?? "—")
                        stat("UV", normal.uv.map { String(format: "%.1f", $0) } ?? "—")
                    }
                    GridRow {
                        // Rain is a SHARE, never a mean. "0.10 inches" on one
                        // date is a downpour divided by the years it stayed dry,
                        // and this archive has been walked into that three times.
                        stat("RAIN", wetYears, wide: true)
                        stat("LIGHTNING", stormYears, wide: true)
                        stat("PRESSURE", normal.pressure.map { String(format: "%.2f inHg", $0) } ?? "—",
                             wide: true)
                    }
                }
                Text(usualCaption)
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Rain and lightning count THIS date only — \(yearsHeld) \(yearsHeld == 1 ? "year" : "years") — because \"does it rain on \(label)\" is a question about \(label)s, not about the fortnight around one.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The normal is pooled from the fortnight AROUND the date, not from the
    /// handful of that exact date. That's the right way to compute it — three
    /// September 1sts is noise — but on a card whose whole subject is one date
    /// it has to be said, or the reader takes these for averages of the three
    /// numbers in the table below and finds they don't add up.
    private var usualCaption: String {
        "Pooled from the \(normal.sampleDays) days within a week either side of \(label), "
        + "across \(normal.years) \(normal.years == 1 ? "year" : "years") — "
        + "a handful of \(label)s alone is too few to average."
    }

    private var wetYears: String { tally { ($0.precipTotal ?? 0) >= 0.01 } }
    private var stormYears: String { tally { ($0.strikeCount ?? 0) >= 1 } }

    /// "1 of 3" — counted over the years that hold THIS date.
    ///
    /// The first cut multiplied `normal.rainFrequency` by the number of years,
    /// which is a denominator swap: that share is over the ±7-day window's 46
    /// days, so scaling it by 3 years produced a per-year count out of a
    /// per-day rate. On Sep 1 it happened to land on the right answer, which is
    /// the worst way for that class of bug to behave. Counting the days the
    /// question is actually about needs no conversion and can't drift from the
    /// table below it.
    private func tally(_ matches: (DailyRecord) -> Bool) -> String {
        // A partial day can still PROVE rain — the reading is a floor — but it
        // can't prove the absence of it, so a dry partial day is excluded from
        // the denominator rather than counted as a dry year.
        let answered = history.filter { matches($0.record) || $0.record.isReliable }
        guard !answered.isEmpty else { return "—" }
        let count = answered.filter { matches($0.record) }.count
        return count == 0 ? "never, in \(answered.count)" : "\(count) of \(answered.count)"
    }

    // MARK: The table

    /// Once four Septembers are in front of you the thing you want is to read
    /// across them — which the strip can't do, because it draws one measure.
    private var tableCard: some View {
        card(label: "Year by year") {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        Text("").frame(width: 44, alignment: .leading)
                        head("HIGH"); head("LOW"); head("PEAK DEW")
                        head("RAIN"); head("GUST"); head("HUMIDITY")
                        Text("").gridCellUnsizedAxes(.horizontal)
                    }
                    ForEach(history.sorted { $0.year > $1.year }) { entry in
                        GridRow {
                            Text(String(entry.year))
                                .font(.callout.weight(.medium)).frame(width: 44, alignment: .leading)
                            cell(degrees(entry.record.tempMax))
                            cell(degrees(entry.record.tempMin))
                            cell(degrees(entry.record.dewPointMax))
                            cell(entry.record.precipTotal.map { $0 >= 0.01 ? WeatherAlmanac.inches($0) : "—" } ?? "—")
                            cell(entry.record.windGustMax.map { "\(Int($0.rounded()))" } ?? "—")
                            cell(entry.record.humidityMean.map { "\(Int($0.rounded()))%" } ?? "—")
                            // A partial day is a floor on the high and a ceiling
                            // on the low, so its row is real but not comparable.
                            if entry.record.isReliable {
                                Text("").gridCellUnsizedAxes(.horizontal)
                            } else {
                                Text("partial").font(.caption).foregroundStyle(.orange.opacity(0.9))
                                    .help("The station missed part of this day. Its high is a floor and its low is a ceiling.")
                            }
                        }
                    }
                }
                if let extremes = extremesLine {
                    Text(extremes).font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Stated as "of the N on record", never as a bare superlative: "the hottest
    /// September 1" off three years is a true sentence doing a much bigger one's
    /// work.
    private var extremesLine: String? {
        let highs = history.compactMap { entry in entry.record.tempMax.map { ($0, entry.year) } }
        let lows = history.compactMap { entry in entry.record.tempMin.map { ($0, entry.year) } }
        guard let hottest = highs.max(by: { $0.0 < $1.0 }),
              let coldest = lows.min(by: { $0.0 < $1.0 }), history.count >= 2 else { return nil }
        return "Of the \(yearsHeld) on record: hottest \(Int(hottest.0.rounded()))° in \(hottest.1), "
             + "coldest night \(Int(coldest.0.rounded()))° in \(coldest.1)."
    }

    // MARK: Chrome

    private func head(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(.tertiary)
            .frame(width: 66, alignment: .leading)
    }

    private func cell(_ text: String) -> some View {
        Text(text).font(.callout.monospacedDigit()).frame(width: 66, alignment: .leading)
    }

    private func stat(_ label: String, _ value: String, wide: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.tertiary)
            Text(value).font(.system(size: wide ? 15 : 19, weight: .light, design: .rounded))
        }
        .frame(minWidth: wide ? 132 : 74, alignment: .leading)
    }

    private func degrees(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))°" } ?? "—"
    }

    private func card<Content: View>(label: String, @ViewBuilder _ content: () -> Content) -> some View {
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

// MARK: - Every year's version of one date

/// One bar per year, low to high, on a shared scale — with the usual beneath.
///
/// This replaced a dot-per-year strip on ONE measure behind a High/Low toggle,
/// which had three problems the moment it held real data:
///
///  1. It showed HALF the answer. A day is a span, and a chart of highs alone
///     can't tell you that 2023 hit 98° off a 66° night while 2025 reached 89°
///     off 71° — different weather, and the toggle made you hold one half in
///     your head to compare it against the other.
///  2. Points that landed within about a tenth of the axis of each other got
///     pushed onto separate rows to keep their labels apart, so with three
///     years two of them were already off the shared line the design depends
///     on. A bar per row never collides.
///  3. Its loudest element was a band of the surrounding FORTNIGHT's spread —
///     the widest, greyest thing on a card about a single date, answering a
///     question nobody had asked. The usual is now one dimmed row, in the same
///     units as everything above it.
///
/// And the number the whole card exists for — how far apart these years are —
/// is stated as a sentence, because a reader should not have to measure it off
/// an axis.
struct DayRangeRows: View {
    let history: [HistoricalDay]
    let normal: DailyNormal
    let dateLabel: String

    private let gutter: CGFloat = 52
    private let readout: CGFloat = 84

    private var years: [HistoricalDay] { history.sorted { $0.year > $1.year } }
    private var highs: [Double] { history.compactMap(\.record.tempMax) }
    private var lows: [Double] { history.compactMap(\.record.tempMin) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let sentence = spreadSentence {
                Text(sentence)
                    .font(.title3.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(years) { entry in
                    row(String(entry.year),
                        low: entry.record.tempMin, high: entry.record.tempMax,
                        // A partial day's high is a floor and its low a ceiling,
                        // so its bar is at least this wide — never exactly this
                        // wide. Dimmed for the same reason the table says so.
                        dimmed: !entry.record.isReliable,
                        note: entry.record.isReliable ? nil : "partial")
                }
                Divider().padding(.vertical, 2)
                row("Usual", low: normal.low, high: normal.high, dimmed: true, note: nil)
            }
            axis
            footnote
        }
    }

    private func row(_ label: String, low: Double?, high: Double?,
                     dimmed: Bool, note: String?) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.callout.weight(dimmed && note == nil ? .regular : .medium).monospacedDigit())
                .foregroundStyle(dimmed && note == nil ? .secondary : .primary)
                .frame(width: gutter, alignment: .leading)
            TempRangeBar(low: low, high: high, scale: scale, dimmed: dimmed)
            HStack(spacing: 5) {
                Text(readout(low: low, high: high))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(dimmed ? .secondary : .primary)
                if let note {
                    Text(note).font(.caption2).foregroundStyle(.orange.opacity(0.9))
                        .help("The station missed part of this day: the high is a floor, the low a ceiling, so the real bar is at least this wide.")
                }
            }
            .frame(width: readout, alignment: .trailing)
        }
    }

    /// Degree ticks under the bars, aligned to the bar column rather than to the
    /// card, so a mark lines up with the value it labels.
    private var axis: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: gutter, height: 1)
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ForEach(ticks, id: \.self) { value in
                        VStack(spacing: 2) {
                            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 4)
                            Text("\(Int(value))°").font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                        .offset(x: fraction(value) * geo.size.width - 10)
                    }
                }
            }
            .frame(height: 16)
            Color.clear.frame(width: readout, height: 1)
        }
    }

    @ViewBuilder private var footnote: some View {
        HStack(spacing: 10) {
            Text("bars run that day's low to its high · \(history.count) \(history.count == 1 ? "year holds" : "years hold") this date")
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Text("\"Usual\" pools the fortnight around \(dateLabel) — a handful of \(dateLabel)s is too few to average.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: The sentence

    /// "Highs have run 87° to 98° — an 11° spread. Nights 66° to 71°."
    ///
    /// Two spans, not one: the range of the highs and the range of the lows are
    /// different facts, and the day that was hottest need not be the day that
    /// was warmest overnight — which on this archive's September 1 it is not.
    private var spreadSentence: String? {
        guard highs.count >= 2, let hMin = highs.min(), let hMax = highs.max() else {
            guard let only = years.first, let high = only.record.tempMax else { return nil }
            return "One \(dateLabel) on record: \(Int(high.rounded()))°."
        }
        var text = "Highs have run \(Int(hMin.rounded()))° to \(Int(hMax.rounded()))°"
        let spread = Int((hMax - hMin).rounded())
        text += spread > 0 ? " — a \(spread)° spread." : "."
        if lows.count >= 2, let lMin = lows.min(), let lMax = lows.max() {
            text += " Nights \(Int(lMin.rounded()))° to \(Int(lMax.rounded()))°."
        }
        return text
    }

    // MARK: Scale

    /// One scale for every row including Usual — that shared scale is the whole
    /// reason the bars can be compared by eye.
    private var scale: ClosedRange<Double> {
        let values = lows + highs + [normal.low, normal.high].compactMap { $0 }
        guard let low = values.min(), let high = values.max() else { return 0...100 }
        let padding = max(3, (high - low) * 0.12)
        return (low - padding)...(high + padding)
    }

    private func fraction(_ value: Double) -> CGFloat {
        let span = scale.upperBound - scale.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat((value - scale.lowerBound) / span)
    }

    private var ticks: [Double] {
        let span = scale.upperBound - scale.lowerBound
        let step: Double = span > 60 ? 20 : span > 30 ? 10 : span > 14 ? 5 : 2
        let first = (scale.lowerBound / step).rounded(.up) * step
        return stride(from: first, through: scale.upperBound, by: step).map { $0 }
    }

    private func readout(low: Double?, high: Double?) -> String {
        guard let low, let high else { return "—" }
        return "\(Int(high.rounded()))° / \(Int(low.rounded()))°"
    }
}

// MARK: - One day

/// A single date, against what that date usually does.
///
/// The day list in Explore has always dead-ended — you could find the days and
/// then not look at one. This is where a day lands, and it exists because the
/// day grain needs a pinned half like every other grain: `pooled` answers "what
/// is a September 1st", `pinned` answers "what was THIS one".
struct DayInstanceCard: View {
    let record: DailyRecord
    let normal: DailyNormal
    /// Other years' versions of this date, for the ranking line.
    let history: [HistoricalDay]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(headline)
                .font(.title3.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    stat("HIGH", record.tempMax, normal.high)
                    stat("LOW", record.tempMin, normal.low)
                    stat("PEAK DEW", record.dewPointMax, normal.dewPointPeak)
                    stat("RAIN", record.precipTotal, nil,
                         format: { WeatherAlmanac.inches($0) })
                    stat("GUST", record.windGustMax, normal.gust,
                         format: { "\(Int($0.rounded())) mph" },
                         departure: { String(format: "%+.0f mph", $0.rounded()) })
                }
            }

            if !record.isReliable {
                Text("The station reported \(Int(coverage * 100))% of this day. Its high is a floor and its low is a ceiling — the real extremes can only be further out.")
                    .font(.caption).foregroundStyle(.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.07)))
    }

    private var coverage: Double {
        guard record.expectedSamples > 0 else { return 0 }
        return min(1, Double(record.sampleCount) / Double(record.expectedSamples))
    }

    /// Where this day sat among the other years of the same date — the only
    /// context that makes one day's numbers mean anything.
    ///
    /// Stated as a rank out of the years actually held, never as a superlative
    /// on its own: "the hottest Sep 1" off three years of record is a true
    /// sentence doing the work of a much bigger one.
    private var headline: String {
        let title = WeatherAlmanac.dayLabel(record.day, includeYear: true)
        guard let high = record.tempMax else { return title }
        let others = history.compactMap(\.record.tempMax)
        guard others.count >= 2 else {
            return "\(title) — \(Int(high.rounded()))° high."
        }
        let warmer = others.filter { $0 > high }.count
        let total = others.count + 1
        let ordinal = warmer == 0 ? "the warmest"
                    : warmer == total - 1 ? "the coolest"
                    : "the \(warmer + 1)\(Self.suffix(warmer + 1)) warmest"
        return "\(title) reached \(Int(high.rounded()))° — \(ordinal) of the \(total) on record."
    }

    private static func suffix(_ n: Int) -> String {
        switch n % 100 {
        case 11, 12, 13: return "th"
        default:
            switch n % 10 {
            case 1: return "st"
            case 2: return "nd"
            case 3: return "rd"
            default: return "th"
            }
        }
    }

    private func stat(_ label: String, _ value: Double?, _ typical: Double?,
                      format: ((Double) -> String)? = nil,
                      departure: ((Double) -> String)? = nil) -> some View {
        let shown = value.map { v in format.map { f in f(v) } ?? "\(Int(v.rounded()))°" } ?? "—"
        let delta = (value != nil && typical != nil) ? value! - typical! : nil
        return VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.tertiary)
            Text(shown).font(.system(size: 19, weight: .light, design: .rounded))
            if let delta, abs(delta) >= 0.5 {
                Text(departure.map { $0(delta) } ?? String(format: "%+.0f°", delta.rounded()))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(delta > 0 ? Color.orange : Color.accentColor)
            } else if typical != nil {
                Text("normal").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(minWidth: 78, alignment: .leading)
    }
}
