//
//  WeatherArchiveBrowser.swift
//  Almanac
//
//  TWO PAGES, ONE WALK. The archive is read two ways, and they were one tab with
//  a toggle between them until it was clear they answer different questions:
//
//    COMPARE  "how does this stretch stack up?" — one position in the calendar
//             (Oct 2, October, fall) with every year on record lined up on it.
//             Opens on NOW, because the stretch you're standing in is the one
//             you're most likely to be asking about.
//    HISTORY  "what was this stretch like?" — ONE instance, September 2023 or
//             fall 2024, read on its own, down to a single day's hours.
//
//  Compare leads into History: a year's row is a door into that year's
//  instance. History leads back: "compare with other Septembers".
//
//  Both are walked the same way — Tempest's shape, a GRAIN and a POSITION you
//  step with arrows:
//
//      [ Day │ Week │ Month │ Season │ … ]
//              ‹     September 2025     ›
//
//  Moving is cheaper than choosing, so you can wander into a question. The old
//  surface was a family picker over a wrap of chips, where every control was a
//  jump-to and could only take you somewhere you had already decided to go.
//
//  WHAT LEFT. "When it turns" (the dated threshold crossings) is Rhythms'
//  question and lives there. The "Usually" grids were the climate of a stretch,
//  which is also Rhythms'. Day shapes, a 29-day overlay of recent mornings, was
//  retired outright.
//

import SwiftUI
import WeatherKit

/// Which page the browser is being.
enum ArchiveLens {
    case compare, history

    /// The grains each page offers. Compare has no Year — "every year" pooled
    /// is the whole archive, which is what All time already is — and History
    /// has no All time, because the whole record isn't one stretch.
    var grains: [WeatherGrain] {
        switch self {
        case .compare: return [.day, .week, .month, .season, .all]
        case .history: return [.day, .week, .month, .season, .year]
        }
    }
}

/// Today's forecast, for drawing among the years that already happened.
struct TodayForecast {
    var year: Int
    var high: Double?
    var low: Double?
}

/// Where one page asks the other to open: which page, a grain, and a day
/// inside it. The page is part of the address because both pages watch the same
/// handoff — without it, the page doing the asking would take its own request.
struct ArchiveFocus: Equatable {
    var lens: ArchiveLens
    var grain: WeatherGrain
    var day: String
}

struct WeatherArchiveBrowser: View {
    let lens: ArchiveLens
    let climate: Climatology
    /// Today's key, for the cards that need to know where "now" is.
    let today: String
    let precipToday: Double?
    /// The ten-day, by day key. Compare draws today's high and low beside every
    /// past year of the same date — at 8am that's the forecast against the
    /// record, and by tomorrow the archive has the real day in its place — and
    /// carries the running month on, dashed, through the days it reaches.
    var forecast: [String: (high: Double?, low: Double?, precip: Double?)] = [:]
    /// Today by clock hour — measured up to now, forecast after — for Compare's
    /// day to draw over every past year's hours.
    var todayHours: [HourSlice] = []
    /// Where a finished day's minutes already are. Nil only in previews; the
    /// network is the fallback for a day the archive hasn't caught up to.
    var sampleStore: (any SampleArchiveStore)?
    /// A position handed over by the other page, applied once on arrival.
    @Binding var focus: ArchiveFocus?
    /// Opens the other page at a position.
    var open: (ArchiveFocus) -> Void = { _ in }

    @EnvironmentObject private var settings: AppSettings
    /// One day's minutes, re-read whenever the walk lands somewhere new. Owned
    /// here rather than by the cards, because the rain card renders nothing on a
    /// dry day and a view that resolves to `EmptyView` loses its `.task`.
    @StateObject private var dayMinutes = DayObservationsModel()

    /// Set on arrival: Compare opens on a day (today), History on a month.
    @State private var grain: WeatherGrain = .month
    /// The position, as a real date. A day key rather than a `MM-dd` because the
    /// year is half the address whenever you're reading one instance.
    @State private var anchor: String?
    /// Years taken off Compare. Hidden rather than chosen, so a year that
    /// arrives with January is shown without anyone opting it in.
    @State private var hiddenYears: Set<Int> = []

    /// The archive stops at yesterday by design, so that — not today — is the
    /// far end of History's walk.
    private var latestDay: String { climate.latestDay ?? today }
    private var position: String { anchor ?? home }
    private var period: WeatherPeriod? { grain.period(containing: position) }
    private var anchorYear: Int { DayKey.year(of: position) ?? 0 }

    var body: some View {
        // THE CONTROLS STICK TO THE TOP. With a card per measure the page is
        // long, and changing the month meant scrolling back up for them. They
        // floated at the bottom for a while as a pinned footer — but a footer
        // sits where the content ENDS, so on a short page (one day) it rode up
        // the window, and it moved every time the page changed length. A pinned
        // header starts at the top of the page and stays at the top of the
        // window whatever the page's length: never scrolled for, never moving.
        LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
            Section {
                content
            } header: {
                controls
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.1)))
                    .shadow(color: .black.opacity(0.14), radius: 8, y: 2)
                    .padding(.top, 4)
            }
        }
        .onAppear(perform: arrive)
        .onChange(of: focus) { _, _ in arrive() }
        // Only at History's day grain. Walking through months mustn't read a
        // day of minutes for a view that has nowhere to put them.
        .task(id: minutesSubject) {
            guard let day = minutesSubject else { return }
            await dayMinutes.load(day: day, key: day,
                                  token: settings.tempestToken,
                                  stationID: settings.tempestStationID,
                                  timeZone: .current,
                                  store: sampleStore)
        }
    }

    /// A handed-over position wins; otherwise the walk starts at home.
    private func arrive() {
        if let focus, focus.lens == lens {
            grain = lens.grains.contains(focus.grain) ? focus.grain : .month
            anchor = focus.day
            self.focus = nil
        } else if anchor == nil {
            grain = lens == .compare ? .day : .month
            anchor = home
        }
    }

    /// Where each page starts. Compare stands on today. History stands in the
    /// month holding yesterday — unless that month is only a few days old, in
    /// which case "October 2026, 1 day so far" is a thinner page than the
    /// September that just finished.
    private var home: String {
        switch lens {
        case .compare:
            return today
        case .history:
            let day = latestDay
            guard let dayOfMonth = Int(day.suffix(2)), dayOfMonth < 7,
                  let previous = WeatherGrain.month.step(day, by: -1),
                  canVisit(previous) else { return day }
            return previous
        }
    }

    /// The day whose minutes the day cards want — nil everywhere else.
    private var minutesSubject: String? {
        lens == .history && grain == .day ? position : nil
    }

    // MARK: The control

    /// ONE ROW: `[Month ▾]  ‹ September 2026 ›  Today  │  Years (2022)…(2026)    Compare… →`.
    ///
    /// It was two controls on two lines — a six-way segmented picker centred
    /// over a stepper that sat flush left — which looked like two unrelated
    /// choices and lined up with nothing. They are one choice, "which stretch",
    /// in two parts: how wide, then where. A dropdown for the width keeps that
    /// part as small as the decision it is, and lets the row read left to right
    /// as a phrase. No measure menu: every measure gets its own card.
    ///
    /// The year chips share the row too. Pinned across a window that is nearly
    /// all width, a second line for them was height taken from the cards for
    /// nothing; they only drop below when the row truly doesn't
    /// fit — a narrow window, a phone.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                walk
                if showsChips {
                    Divider().frame(height: 20)
                    chips
                }
                Spacer(minLength: 0)
                if grain.isPositional { crossLink }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    walk
                    Spacer(minLength: 0)
                    if grain.isPositional { crossLink }
                }
                if showsChips { chips }
            }
        }
    }

    private var showsChips: Bool { lens == .compare && grain.isPositional && chipYears.count > 1 }

    private var chips: some View {
        YearChips(years: chipYears, firstYear: firstYear,
                  current: DayKey.year(of: today), hidden: $hiddenYears)
            .fixedSize()
    }

    /// Width, position, and the way back — the part of the row that moves you.
    @ViewBuilder private var walk: some View {
        Picker("Window", selection: $grain) {
            ForEach(lens.grains) { Text($0.label).tag($0) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .help("How wide a stretch to read")

        if grain.isPositional {
            stepper
            if position != home {
                Button { anchor = home } label: {
                    Label(lens == .compare ? "Today" : "Latest",
                          systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .help(lens == .compare ? "Back to the stretch you're standing in"
                                       : "Back to the most recent stretch")
            }
        }
    }

    /// `‹ September 2026 ›` as ONE control: the arrows and the position share a
    /// capsule, because they are one thing — where you are, and the way to the
    /// next place.
    ///
    /// The arrows step by the grain's OWN width, which is what makes them a walk
    /// rather than a nudge: back from September is August, not August 31st.
    private var stepper: some View {
        HStack(spacing: 0) {
            arrow("chevron.left", by: -1)
            Text(positionLabel)
                .font(.callout.weight(.medium)).monospacedDigit()
                .lineLimit(1)
                .frame(minWidth: 170)
                .padding(.horizontal, 4)
            arrow("chevron.right", by: 1)
        }
        .padding(.horizontal, 4)
        .frame(height: 28)
        .background(Color.primary.opacity(0.07), in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.12)))
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
                .font(.callout.weight(.semibold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!allowed)
        .opacity(allowed ? 1 : 0.25)
        .help(direction < 0 ? "Back one \(grain.label.lowercased())" : "Forward one \(grain.label.lowercased())")
    }

    /// A position is worth visiting when the archive holds any of it. On
    /// Compare the year doesn't matter — only the place in the calendar does —
    /// so the walk is free to run the whole cycle.
    private func canVisit(_ day: String) -> Bool {
        guard let first = climate.earliestDay else { return false }
        if lens == .compare { return true }
        guard let period = grain.period(containing: day),
              let bounds = period.bounds(inYear: DayKey.year(of: day) ?? 0) else { return false }
        return bounds.end >= first && bounds.start <= latestDay
    }

    /// Compare names a place in the calendar; History names one instance of it.
    private var positionLabel: String {
        guard let period else { return "All time" }
        switch (lens, grain) {
        case (.compare, .day):
            return WeatherAlmanac.dateLabel(DayKey.monthDay(of: position))
        case (.compare, _):
            return period.name
        case (.history, .day):
            return WeatherAlmanac.dayLabel(position, includeYear: true)
        case (.history, .year):
            return String(anchorYear)
        case (.history, _):
            return "\(period.name) \(anchorYear)"
        }
    }

    private var firstYear: Int { climate.earliestDay.flatMap(DayKey.year(of:)) ?? anchorYear }

    /// Every calendar year the record touches, through this one.
    private var chipYears: [Int] {
        let last = DayKey.year(of: today) ?? firstYear
        return firstYear <= last ? Array(firstYear...last) : []
    }

    /// The door to the other page, at this same position.
    @ViewBuilder private var crossLink: some View {
        switch lens {
        case .history where grain != .year:
            Button("Compare with other \(cycleName)s →") {
                open(ArchiveFocus(lens: .compare, grain: grain, day: position))
            }
            .buttonStyle(.link)
        case .compare where grain != .day:
            // A day's year rows are doors of their own; for the longer grains
            // the one most likely wanted is the instance you're standing in.
            Button("\(positionLabel) \(String(anchorYear)) in History →") {
                open(ArchiveFocus(lens: .history, grain: grain, day: min(position, latestDay)))
            }
            .buttonStyle(.link)
        default:
            EmptyView()
        }
    }

    /// What one instance of this position is called — "September", "Sep 1".
    private var cycleName: String {
        switch grain {
        case .day: return WeatherAlmanac.dateLabel(DayKey.monthDay(of: position))
        default: return period?.name ?? "one"
        }
    }

    /// The same position in another year — what a year's row opens.
    private func openYear(_ year: Int) {
        let day = "\(year)\(position.dropFirst(4))"
        open(ArchiveFocus(lens: .history, grain: grain, day: min(day, latestDay)))
    }

    // MARK: The lenses

    @ViewBuilder private var content: some View {
        switch (lens, grain) {
        case (_, .all):
            allTimeCards
        case (.compare, .day):
            everyYearDay
        case (.history, .day):
            oneDay
        case (.compare, _):
            if let period {
                CompareStretchView(climate: climate, period: period, today: today,
                                   forecast: forecast, hidden: hiddenYears,
                                   firstYear: firstYear, onPickYear: openYear)
            }
        case (.history, _):
            if let period {
                PeriodHistoryView(climate: climate, today: today, period: period,
                                  focusYear: anchorYear) { day in
                    // Down into one day's hours, still in History.
                    grain = .day
                    anchor = day
                }
            }
        }
    }

    /// The one card about the record rather than about a stretch: every year's
    /// extremes side by side. Winter chill and Rainfall used to sit here too and
    /// are on Rhythms and Rain, where their subject — the year — lives.
    @ViewBuilder private var allTimeCards: some View {
        card(label: "Records & streaks") {
            if climate.dayCount >= 30 {
                StreaksAndRecords(climate: climate, today: today, precipToday: precipToday)
            } else {
                Text("Records start counting at 30 days of record — there are \(climate.dayCount) so far.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// Every year's version of one date: its hours first, then its range.
    @ViewBuilder private var everyYearDay: some View {
        let monthDay = DayKey.monthDay(of: position)
        // One card per measure, hour by hour: temperature (its afternoon peak
        // and its overnight bottom), then the dew point and the gust.
        ForEach([DailyMeasure.high, .dewPoint, .gust]) { measure in
            CompareDayHoursView(monthDay: monthDay, today: today, todayHours: todayHours,
                                years: chipYears.filter { !hiddenYears.contains($0) },
                                firstYear: firstYear, store: sampleStore, measure: measure)
        }
        let history = climate.history(monthDay: monthDay)
            .filter { !hiddenYears.contains($0.year) }
        let todayYear = DayKey.year(of: today) ?? 0
        let showToday = monthDay == DayKey.monthDay(of: today) && !hiddenYears.contains(todayYear)
        if history.isEmpty && !showToday {
            emptyNote("The archive holds no \(WeatherAlmanac.dateLabel(monthDay)) yet.")
        } else {
            // Only on today's own date — Oct 2's forecast has nothing to say
            // about every Oct 3.
            let ahead = forecast[today]
            DayPooledView(history: history,
                          normal: climate.normal(monthDay: monthDay),
                          monthDay: monthDay,
                          today: showToday ? TodayForecast(year: todayYear,
                                                           high: ahead?.high ?? nil,
                                                           low: ahead?.low ?? nil) : nil,
                          onPickYear: openYear)
        }
    }

    @ViewBuilder private var oneDay: some View {
        if let record = climate.record(on: position) {
            DayInstanceCard(record: record,
                            normal: climate.normal(monthDay: DayKey.monthDay(of: position)),
                            history: climate.history(monthDay: DayKey.monthDay(of: position),
                                                     excludingYear: anchorYear))
            dayTrace
            // The day grain's RAIN row says a total and stops. This is the same
            // card the Now tab uses, pointed at a day in the record: when it
            // rained, how hard, and what that rate meant. The archive is kept in
            // the local zone, so that's the zone its minutes are read back in.
            if dayMinutes.day == position, let rain = dayMinutes.rain, rain.hasSomethingToSay {
                RainDayCard(rain: rain, climate: climate)
            }
        } else {
            emptyNote("The archive holds nothing for \(WeatherAlmanac.dayLabel(position, includeYear: true)).")
        }
    }

    /// The day as it happened, hour by hour — the same ribbon Now draws for
    /// today, every column of it measured. A day's high and low are the
    /// archive's summary; this is what the summary was taken from.
    private var dayTrace: some View {
        card(label: "Hour by hour") {
            if dayMinutes.day == position, !dayMinutes.samples.isEmpty {
                let strip = Self.strip(day: position, samples: dayMinutes.samples)
                VStack(alignment: .leading, spacing: 10) {
                    HourlyRibbon(hours: strip.hours, timezone: .current)
                    Text(traceCaption(strip))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            } else if dayMinutes.isLoading || dayMinutes.day != position && dayMinutes.error == nil {
                ProgressView("Reading the day's minutes…")
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if let error = dayMinutes.error {
                Text("Couldn't read this day's minutes — \(error)")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("The station kept no minutes for this day — only its summary above.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func traceCaption(_ strip: DayStrip) -> String {
        var parts: [String] = []
        if let high = strip.high {
            parts.append("high \(Int(high.value.rounded()))° at \(Self.clock(high.date))")
        }
        if let low = strip.low {
            parts.append("low \(Int(low.value.rounded()))° at \(Self.clock(low.date))")
        }
        if strip.observedHours < 24 {
            parts.append("\(strip.observedHours) of 24 hours measured")
        }
        return parts.joined(separator: " · ")
    }

    private static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    /// A finished day's strip: every column measured, no forecast to splice.
    ///
    /// Night shading comes off the station's own light sensor rather than an
    /// almanac — the first and last hours the sun registered — so it is right for
    /// the day being read, not for whatever day the app happens to be open on.
    static func strip(day: String, samples: [StationSample]) -> DayStrip {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let lit = samples.filter { ($0.solarRadiation ?? 0) > 10 }
            .map { calendar.component(.hour, from: $0.date) }
        return DayStrip.build(day: day, samples: samples, forecast: [],
                              timeZone: .current,
                              sunriseHour: lit.min() ?? 7,
                              sunsetHour: (lit.max() ?? 18) + 1)
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
    }

    private func card<Content: View>(label: String, @ViewBuilder _ content: () -> Content) -> some View {
        StationCard(label: label, content: content)
    }
}

// MARK: - One date, every year

/// Every year's version of one date, side by side.
///
/// This started as a single temperature strip, which made the day the thinnest
/// grain in the tab — one card, one measure, on a page where every other grain
/// gets five. The archive holds thirteen measures for each of these days; the
/// strip was showing one of them.
///
/// Two cards: where each year landed, low to high on one axis · the whole
/// table, because once you have four Septembers in front of you the thing you
/// want is to read across them. A "what one of these is usually like" grid led
/// here once, and left for Rhythms with the rest of the climate.
struct DayPooledView: View {
    let history: [HistoricalDay]
    /// Pooled ±7 days across every year, for the dimmed "Usual" bar.
    let normal: DailyNormal
    let monthDay: String
    /// This year's instance while it's still today — a forecast, not a record.
    var today: TodayForecast?
    /// Opens one year's instance of this date in History.
    var onPickYear: (Int) -> Void = { _ in }

    private var label: String { WeatherAlmanac.dateLabel(monthDay) }
    /// Years that actually hold this date — NOT `normal.years`, which counts the
    /// window's years. On a date near the end of the archive those differ, and
    /// the strip used to print "4 years of record" beside three points.
    private var yearsHeld: Int { history.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            card(label: "Every \(label) on record") {
                DayRangeRows(history: history, normal: normal, dateLabel: label, today: today)
            }
            tableCard
        }
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
                            Button(String(entry.year)) { onPickYear(entry.year) }
                                .buttonStyle(.link)
                                .font(.callout.weight(.medium)).frame(width: 44, alignment: .leading)
                                .help("Open \(label), \(String(entry.year)) in History")
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
                Text("Click a year to open that day in History.")
                    .font(.caption2).foregroundStyle(.tertiary)
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

    private func degrees(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))°" } ?? "—"
    }

    private func card<Content: View>(label: String, @ViewBuilder _ content: () -> Content) -> some View {
        StationCard(label: label, content: content)
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
    var today: TodayForecast?

    private let gutter: CGFloat = 52
    private let readout: CGFloat = 100

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
                if let today, today.high != nil || today.low != nil {
                    row("Today", low: today.low, high: today.high,
                        dimmed: false, note: "forecast")
                }
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
                    let isForecast = note == "forecast"
                    Text(note).font(.caption2)
                        .foregroundStyle(isForecast ? Color.accentColor : Color.orange.opacity(0.9))
                        .help(isForecast
                              ? "Today's forecast high and low. Tomorrow the archive holds what actually happened, and this row takes its place among the years."
                              : "The station missed part of this day: the high is a floor, the low a ceiling, so the real bar is at least this wide.")
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
        if let ranked = todaySentence { return ranked }
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

    /// "Today's forecast 91° would be the warmest Oct 2 of the 5 on record."
    ///
    /// Stated as a rank out of the years held, never as a bare superlative, and
    /// as WOULD BE — it is a forecast until tomorrow, when the archive has the
    /// day and this row becomes an ordinary one.
    private var todaySentence: String? {
        guard let high = today?.high, !highs.isEmpty else { return nil }
        let warmer = highs.filter { $0 > high }.count
        let total = highs.count + 1
        let place = warmer == 0 ? "the warmest"
                  : warmer == total - 1 ? "the coolest"
                  : "the \(DayInstanceCard.ordinal(warmer + 1)) warmest"
        return "Today's forecast \(Int(high.rounded()))° would be \(place) \(dateLabel) of the \(total) on record."
    }

    // MARK: Scale

    /// One scale for every row including Usual — that shared scale is the whole
    /// reason the bars can be compared by eye.
    private var scale: ClosedRange<Double> {
        let values = lows + highs + [normal.low, normal.high, today?.low, today?.high].compactMap { $0 }
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
                    : "the \(Self.ordinal(warmer + 1)) warmest"
        return "\(title) reached \(Int(high.rounded()))° — \(ordinal) of the \(total) on record."
    }

    static func ordinal(_ n: Int) -> String { "\(n)\(suffix(n))" }

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
