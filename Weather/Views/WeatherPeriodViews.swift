//
//  WeatherPeriodViews.swift  (macOS)
//
//  The History tab's own surface: pick a stretch of the calendar, see what it's
//  usually like AND what shape it has.
//
//  The hero is the curve, not the averages. "September's average high is 91°" is
//  true and answers nothing — the month is a slope, and the question people
//  actually arrive with ("August is brutal, does September let up, and WHEN?")
//  is about where that slope crosses something that matters. So the layout puts
//  the per-day curve and the threshold crossings first, and files the aggregates
//  underneath as backing detail.
//
//  The focus year is drawn raw against the smoothed normal on purpose. Where the
//  jagged line dives away from the smooth one for two or three days is a front
//  coming through — which is the thing you'd otherwise need an event detector to
//  find, visible for free because both lines share an axis.
//

import SwiftUI
import WeatherKit

// MARK: - Choosing the stretch
//
// DELETED: `PeriodFamily` + `PeriodPicker`, a family segmented control over a
// wrap of chips. Every control in it was a jump-to — it could only take you
// somewhere you had already decided to go — which is why nothing built into
// this surface got found. `WeatherArchiveBrowser` replaces it with a grain and
// a stepper you can walk. Kept nothing behind: a second way in is what made the
// first one unreachable.

/// Chips that wrap to the next line. AnyLayout rather than a LazyVGrid because
/// the chips are different widths ("May" against "September") and a grid would
/// column them into a ragged, mostly-empty table.
struct WrappingRow: Layout {
    var spacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - The curve

/// The window's internal shape: normal high and low with their spread, the most
/// recent real year drawn over them, and the crossings marked where they land.
struct PeriodCurve: View {
    let summary: PeriodSummary

    private var days: [PeriodDay] { summary.days }

    /// Vertical extent, from the bands rather than the lines so a wide spread
    /// isn't clipped. Padded to breathe, then snapped to 5° so the gridlines
    /// land on readable numbers.
    private var range: ClosedRange<Double> {
        var lows: [Double] = [], highs: [Double] = []
        for day in days {
            if let low = day.normal.low { lows.append(low - (day.normal.lowSpread ?? 0)) }
            if let high = day.normal.high { highs.append(high + (day.normal.highSpread ?? 0)) }
            if let actual = day.actual {
                if let v = actual.tempMin { lows.append(v) }
                if let v = actual.tempMax { highs.append(v) }
            }
        }
        guard let min = lows.min(), let max = highs.max(), max > min else { return 0...100 }
        return (min - 4).rounded(.down) ... (max + 4).rounded(.up)
    }

    private func y(_ value: Double, _ height: CGFloat) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        return height - CGFloat((value - range.lowerBound) / span) * height
    }

    private func x(_ index: Int, _ width: CGFloat) -> CGFloat {
        guard days.count > 1 else { return width / 2 }
        return CGFloat(index) / CGFloat(days.count - 1) * width
    }

    /// Gridlines every 10°, on multiples of 10.
    private var gridValues: [Double] {
        let start = (range.lowerBound / 10).rounded(.up) * 10
        return stride(from: start, through: range.upperBound, by: 10).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 0) {
                axisLabels
                GeometryReader { geo in
                    let w = geo.size.width, h = geo.size.height
                    ZStack(alignment: .topLeading) {
                        grid(w, h)
                        band(w, h, value: \.high, spread: \.highSpread, color: .orange)
                        band(w, h, value: \.low, spread: \.lowSpread, color: .teal)
                        crossingRules(w, h)
                        line(w, h, normal: \.high).stroke(.orange, lineWidth: 2)
                        line(w, h, normal: \.low).stroke(.teal, lineWidth: 2)
                        actualLine(w, h, \.tempMax).stroke(.orange.opacity(0.75), lineWidth: 1)
                        actualLine(w, h, \.tempMin).stroke(.teal.opacity(0.75), lineWidth: 1)
                    }
                }
            }
            .frame(height: 250)
            dateAxis
            legend
        }
    }

    private var axisLabels: some View {
        GeometryReader { geo in
            ForEach(gridValues, id: \.self) { value in
                Text("\(Int(value))°")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .frame(width: 26, alignment: .trailing)
                    .offset(y: y(value, geo.size.height) - 6)
            }
        }
        .frame(width: 30)
    }

    private func grid(_ w: CGFloat, _ h: CGFloat) -> some View {
        ForEach(gridValues, id: \.self) { value in
            Path { p in
                p.move(to: CGPoint(x: 0, y: y(value, h)))
                p.addLine(to: CGPoint(x: w, y: y(value, h)))
            }
            .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    /// The ±1σ envelope — what "usual" actually spans. Without it the normal
    /// line reads as a promise rather than a middle.
    private func band(_ w: CGFloat, _ h: CGFloat,
                      value: KeyPath<DailyNormal, Double?>,
                      spread: KeyPath<DailyNormal, Double?>,
                      color: Color) -> some View {
        Path { p in
            var upper: [CGPoint] = [], lower: [CGPoint] = []
            for (index, day) in days.enumerated() {
                guard let mid = day.normal[keyPath: value] else { continue }
                let sigma = day.normal[keyPath: spread] ?? 0
                upper.append(CGPoint(x: x(index, w), y: y(mid + sigma, h)))
                lower.append(CGPoint(x: x(index, w), y: y(mid - sigma, h)))
            }
            guard let first = upper.first else { return }
            p.move(to: first)
            for point in upper.dropFirst() { p.addLine(to: point) }
            for point in lower.reversed() { p.addLine(to: point) }
            p.closeSubpath()
        }
        .fill(color.opacity(0.14))
    }

    private func line(_ w: CGFloat, _ h: CGFloat, normal: KeyPath<DailyNormal, Double?>) -> Path {
        Path { p in
            var started = false
            for (index, day) in days.enumerated() {
                guard let value = day.normal[keyPath: normal] else { continue }
                let point = CGPoint(x: x(index, w), y: y(value, h))
                if started { p.addLine(to: point) } else { p.move(to: point); started = true }
            }
        }
    }

    /// The focus year, drawn RAW. Its departures from the smooth normal are the
    /// weather — a three-day dive is a front, and smoothing it would erase the
    /// one thing the comparison is for.
    private func actualLine(_ w: CGFloat, _ h: CGFloat,
                            _ measure: KeyPath<DailyRecord, Double?>) -> Path {
        Path { p in
            var started = false
            for (index, day) in days.enumerated() {
                // A gap must BREAK the line, never be bridged across — a
                // straight segment over three missing days is a claim the
                // archive can't make.
                guard let record = day.actual, record.isReliable,
                      let value = record[keyPath: measure] else { started = false; continue }
                let point = CGPoint(x: x(index, w), y: y(value, h))
                if started { p.addLine(to: point) } else { p.move(to: point); started = true }
            }
        }
    }

    private func crossingRules(_ w: CGFloat, _ h: CGFloat) -> some View {
        ForEach(summary.crossings) { crossing in
            if let index = days.firstIndex(where: { $0.monthDay == crossing.monthDay }) {
                Path { p in
                    p.move(to: CGPoint(x: x(index, w), y: 0))
                    p.addLine(to: CGPoint(x: x(index, w), y: h))
                }
                .stroke(Color.primary.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
    }

    /// Ticks at a readable density: about six across the window, always
    /// including its first and last day.
    private var dateAxis: some View {
        let step = max(1, days.count / 6)
        let marks = stride(from: 0, to: days.count, by: step).map { $0 }
        return GeometryReader { geo in
            ForEach(marks, id: \.self) { index in
                // Short form: six "September 12"s across an axis collide.
                Text(shortDate(days[index].monthDay))
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .fixedSize()
                    .offset(x: 30 + x(index, geo.size.width - 30) - 18)
            }
        }
        .frame(height: 12)
    }

    private func shortDate(_ monthDay: String) -> String {
        let parts = monthDay.split(separator: "-")
        guard parts.count == 2, let day = Int(parts[1]) else { return monthDay }
        return "\(WeatherAlmanac.monthName(String(parts[0]), long: false)) \(day)"
    }

    private var legend: some View {
        HStack(spacing: 14) {
            key(.orange, "Usual high")
            key(.teal, "Usual low")
            if let year = summary.focusYear {
                HStack(spacing: 5) {
                    Rectangle().fill(.secondary).frame(width: 12, height: 1)
                    Text(verbatim: "\(year) actual")
                }
            }
            HStack(spacing: 5) {
                Rectangle().fill(.secondary.opacity(0.3)).frame(width: 12, height: 8)
                Text("Usual range")
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    private func key(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 12, height: 2.5)
            Text(label)
        }
    }
}

// MARK: - The tab

/// Everything the archive knows about the chosen stretch. Held in its own view
/// so the summary is computed once per period change, off the main actor.
struct PeriodHistoryView: View {
    let climate: Climatology
    let today: String
    /// The window to read. Chosen by the browser above rather than by a picker
    /// of its own — a period is a POSITION, and there should be exactly one
    /// control in the tab that moves you.
    let period: WeatherPeriod
    /// Nil pools every year at this position; a year reads that one instance.
    ///
    /// The two are the same window asked two ways, which is why they share a
    /// summary rather than being separate views: "September" and "September
    /// 2025" differ in what you emphasise, not in what you compute.
    var focusYear: Int?
    /// Hands a built query to the Explore tab. A card that can say WHEN
    /// something typically happens should be able to show WHICH days did it,
    /// without growing a day list of its own.
    var onExplore: (DayQuery) -> Void = { _ in }

    @State private var summary: PeriodSummary?
    /// Which crossings have been opened to show the years behind them.
    @State private var openCrossings: Set<String> = []

    /// A rolling window counts back from the archive's last day, not from today
    /// — the archive stops at yesterday by design.
    private var latestDay: String { climate.latestDay ?? today }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let summary {
                if let focusYear, let instance = summary.years.first(where: { $0.year == focusYear }) {
                    instanceCards(summary, instance)
                } else {
                    pooledCards(summary)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(40)
            }
        }
        .task(id: "\(period.id)·\(focusYear.map(String.init) ?? "all")") { await rebuild() }
    }

    /// Every year at this position, pooled — what a September IS.
    @ViewBuilder private func pooledCards(_ s: PeriodSummary) -> some View {
        headline(s)
        curveCard(s)
        aggregates(s)
        if !s.crossings.isEmpty { crossingsCard(s) }
        yearsCard(s)
    }

    /// One instance — what THIS September did, against what a September does.
    ///
    /// The comparison is the point, so nothing here is shown as a bare number:
    /// every stat carries its departure from the pooled normal, and the curve
    /// is the same curve with this year drawn raw over it.
    @ViewBuilder private func instanceCards(_ s: PeriodSummary, _ year: PeriodYear) -> some View {
        instanceHeadline(s, year)
        curveCard(s)
        instanceStats(s, year)
        if !s.crossings.isEmpty { crossingsCard(s) }
    }

    /// Off the main actor: a period summary walks several years of smoothed
    /// series per measure, and doing that inside a SwiftUI body stutters the
    /// very arrow tap that asked for it.
    private func rebuild() async {
        let climate = climate, period = period
        // `asOf` is what picks the summary's focus year, so pinning an instance
        // is just asking the same question from inside that instance. Pooled,
        // the focus is the most recent instance — the one you'd compare to.
        let asOf = focusYear.flatMap { period.bounds(inYear: $0)?.end } ?? latestDay
        let clamped = min(asOf, latestDay)
        let built = await Task.detached(priority: .userInitiated) {
            climate.summary(for: period, asOf: clamped)
        }.value
        // A slower earlier period must not overwrite the one now selected.
        guard period.id == self.period.id else { return }
        summary = built
    }

    // MARK: Pieces

    @ViewBuilder private func headline(_ s: PeriodSummary) -> some View {
        if let text = WeatherAlmanac.periodHeadline(s) {
            Text(text)
                .font(.title3.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        } else if !s.isMeaningful {
            // The archive's standing rule: a young record reads as quiet, never
            // as confident and wrong.
            Text("\(s.comparableYears) complete \(s.comparableYears == 1 ? "year" : "years") of \(s.period.name) on record — not enough yet to say what's typical.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: One instance

    @ViewBuilder private func instanceHeadline(_ s: PeriodSummary, _ year: PeriodYear) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(instanceSentence(s, year))
                .font(.title3.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            // A thin instance is the one case where the numbers below are all
            // floors and means over the hours that were watched. Say so once,
            // here, rather than hedging every cell.
            if year.isInProgress {
                Text("This \(s.period.name) is still running — \(year.daysCovered) of \(year.daysExpected) days so far.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else if !year.isTrustworthy {
                Text("The station watched \(Int(year.coverage * 100))% of this \(s.period.name). Its rain total is a floor, and its means are over the hours it saw.")
                    .font(.caption).foregroundStyle(.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "September 2025 ran 2.1° warmer than a September."
    ///
    /// Led by the DEPARTURE, not the value: the number you can read off the card
    /// below is the high; the thing you opened one instance to find out is how
    /// it compared.
    private func instanceSentence(_ s: PeriodSummary, _ year: PeriodYear) -> String {
        let title = "\(s.period.name) \(year.year)"
        guard let high = year.high, let typical = s.typicalHigh, s.isMeaningful else {
            return "\(title) — \(degrees(year.high)) days, \(degrees(year.low)) nights."
        }
        let delta = high - typical
        guard abs(delta) >= 0.5 else {
            return "\(title) ran about normal — \(degrees(year.high)) days, \(degrees(year.low)) nights."
        }
        return "\(title) ran \(String(format: "%.1f", abs(delta)))° "
             + (delta > 0 ? "warmer" : "cooler")
             + " than a \(s.period.name) — \(degrees(year.high)) days, \(degrees(year.low)) nights."
    }

    private func instanceStats(_ s: PeriodSummary, _ year: PeriodYear) -> some View {
        card(label: "\(s.period.name) \(year.year)") {
            VStack(alignment: .leading, spacing: 14) {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    GridRow {
                        instanceStat("HIGH", year.high, s.typicalHigh)
                        instanceStat("LOW", year.low, s.typicalLow)
                        instanceStat("DEW POINT", year.dewPoint, s.typicalDewPoint)
                        instanceStat("RAIN", year.precip, s.typicalPrecip,
                                     format: { String(format: "%.2f\"", $0) },
                                     departure: { String(format: "%+.2f\"", $0) })
                        instanceStat("WET DAYS", Double(year.rainDays), s.typicalRainDays,
                                     format: { "\(Int($0.rounded()))" },
                                     departure: { String(format: "%+.0f", $0.rounded()) })
                    }
                }
                if let hottest = year.hottest, let coldest = year.coldest {
                    Divider()
                    Text("Hottest \(degrees(hottest.value)) on \(WeatherAlmanac.dayLabel(hottest.day, includeYear: false)) · "
                         + "coldest \(degrees(coldest.value)) on \(WeatherAlmanac.dayLabel(coldest.day, includeYear: false)).")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// A value with what it departs from — the whole reason to pin one instance.
    ///
    /// The unit is carried by the caller's formatters rather than assumed: a
    /// rain departure written `+2°` is the kind of plausible-looking wrong
    /// number this archive has already produced once.
    private func instanceStat(_ label: String, _ value: Double?, _ typical: Double?,
                              format: ((Double) -> String)? = nil,
                              departure: ((Double) -> String)? = nil) -> some View {
        let shown = format.map { f in value.map(f) ?? "—" } ?? degrees(value)
        let delta = (value != nil && typical != nil) ? value! - typical! : nil
        return VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.tertiary)
            Text(shown).font(.system(size: 19, weight: .light, design: .rounded))
            if let delta, abs(delta) >= 0.05 {
                Text(departure.map { $0(delta) } ?? signed(delta))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(delta > 0 ? Color.orange : Color.accentColor)
            } else if typical != nil {
                Text("normal").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(minWidth: 74, alignment: .leading)
    }

    private func curveCard(_ s: PeriodSummary) -> some View {
        card(label: "Through \(s.period.name)") {
            if s.days.contains(where: { $0.normal.isMeaningful }) {
                PeriodCurve(summary: s)
            } else {
                Text("Not enough record for a shape yet.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func aggregates(_ s: PeriodSummary) -> some View {
        card(label: "Usually") {
            VStack(alignment: .leading, spacing: 14) {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    GridRow {
                        stat("HIGH", degrees(s.typicalHigh))
                        stat("LOW", degrees(s.typicalLow))
                        stat("DEW POINT", degrees(s.typicalDewPoint))
                        stat("RAIN", s.typicalPrecip.map { String(format: "%.2f\"", $0) } ?? "—",
                             detail: s.typicalRainDays.map { "\(Int($0.rounded())) days" })
                    }
                }
                if let drift = s.drift, let high = drift.highChange, let low = drift.lowChange {
                    Divider()
                    // Stated as two ENDS rather than as one "trend" number: a
                    // window can be warmer at both ends than in the middle
                    // (winter), and a single delta would call that "warming".
                    Text("First \(drift.span) days → last \(drift.span): "
                         + "highs \(degrees(drift.startHigh)) → \(degrees(drift.endHigh)) "
                         + "(\(signed(high))), nights \(degrees(drift.startLow)) → \(degrees(drift.endLow)) "
                         + "(\(signed(low))).")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let hottest = s.extremes.hottest, let coldest = s.extremes.coldest {
                    Text("Most extreme on record for this stretch: \(degrees(hottest.value)) on \(WeatherAlmanac.dayLabel(hottest.day, includeYear: true)), \(degrees(coldest.value)) on \(WeatherAlmanac.dayLabel(coldest.day, includeYear: true)).")
                        .font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The dated claims this window makes — each one openable into the years it
    /// was computed from.
    ///
    /// "Nights drop below 70° on Sep 4" is a median of four real dates, and read
    /// as a sentence it has the confidence of a fact. The range beside it says
    /// how wide the estimate is; the years inside say what shape that width has,
    /// which is a different thing — Sep 1 · Sep 2 · Sep 6 · Sep 27 and four
    /// dates spread evenly across the month give the same range and mean very
    /// different things about next September.
    private func crossingsCard(_ s: PeriodSummary) -> some View {
        card(label: "When it turns") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(s.crossings) { crossing in
                    VStack(alignment: .leading, spacing: 8) {
                        crossingRow(crossing, in: s)
                        if openCrossings.contains(crossing.id), let spread = crossing.spread {
                            crossingEvidence(crossing, spread)
                        }
                    }
                }
            }
        }
    }

    private func crossingRow(_ crossing: PeriodCrossing, in s: PeriodSummary) -> some View {
        let canOpen = crossing.spread != nil
        let isOpen = openCrossings.contains(crossing.id)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: crossing.symbol)
                .font(.caption).foregroundStyle(.secondary).frame(width: 16)
            Text(crossing.track).font(.callout.weight(.medium)).frame(width: 90, alignment: .leading)
            Text(crossing.label).font(.callout).foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(WeatherAlmanac.dateLabel(crossing.monthDay))
                .font(.callout.weight(.semibold))
            Spacer()
            // The window, not just the median — "usually Sep 4" is a
            // lie of precision when the record spans Sep 1–Sep 27.
            if let earliest = crossing.earliest, let latest = crossing.latest,
               earliest != latest {
                Text("\(WeatherAlmanac.dateLabel(earliest)) – \(WeatherAlmanac.dateLabel(latest)) · \(crossing.yearsObserved) yrs")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            if canOpen {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            if let handOff = query(for: crossing, in: s.period) {
                Button("Show days") { onExplore(handOff) }
                    .buttonStyle(.link).font(.caption)
            }
        }
        // The whole row is the target: the date IS the thing you want to open,
        // so a separate disclosure control would put the affordance somewhere
        // other than the number that prompted the question.
        .contentShape(Rectangle())
        .onTapGesture {
            guard canOpen else { return }
            if isOpen { openCrossings.remove(crossing.id) } else { openCrossings.insert(crossing.id) }
        }
    }

    @ViewBuilder
    private func crossingEvidence(_ crossing: PeriodCrossing,
                                  _ spread: OccurrenceSpread) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            OccurrenceDates(spread: spread, typical: crossing.monthDay)
            // Two dates make a range, not a window. Saying so is cheaper than
            // letting the reader assume four years of evidence sit behind it.
            if !spread.isMeaningful {
                Text("One year on record — this is when it happened, not when it usually happens.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else if let days = spread.spreadDays, days > 0 {
                Text("\(spread.occurrences.count) years, \(days) days apart end to end. Each is that year's own crossing, not a share of the average.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 26).padding(.bottom, 4)
    }

    private func yearsCard(_ s: PeriodSummary) -> some View {
        card(label: "Year by year") {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text("").frame(width: 52, alignment: .leading)
                    header("HIGH"); header("LOW"); header("DEW"); header("RAIN"); header("WET DAYS")
                    Text("").gridCellUnsizedAxes(.horizontal)
                }
                ForEach(s.years) { year in
                    GridRow {
                        Text(String(year.year))
                            .font(.callout.weight(year.year == s.focusYear ? .bold : .regular))
                            .frame(width: 52, alignment: .leading)
                        value(degrees(year.high))
                        value(degrees(year.low))
                        value(degrees(year.dewPoint))
                        value(String(format: "%.2f\"", year.precip))
                        value("\(year.rainDays)")
                        // Only ever a caveat, never a silent short bar.
                        if year.isInProgress {
                            Text("running").font(.caption).foregroundStyle(.tertiary)
                        } else if !year.isTrustworthy {
                            Text("\(Int(year.coverage * 100))% watched")
                                .font(.caption).foregroundStyle(.orange.opacity(0.9))
                                .help("The station missed part of this stretch. Its rain total is a floor, and it can't inform what's typical.")
                        } else {
                            Text("").gridCellUnsizedAxes(.horizontal)
                        }
                    }
                }
            }
        }
    }

    /// Turn a crossing into the query that finds the days behind it.
    ///
    /// The crossing is computed on a SMOOTHED series — it's a claim about the
    /// season, not about any one day — so the query it hands over is a related
    /// question rather than the same one: "which individual days were on the far
    /// side of this threshold, in this window".
    private func query(for crossing: PeriodCrossing, in period: WeatherPeriod) -> DayQuery? {
        let measure: Measure
        switch crossing.track {
        case "Afternoons": measure = .high
        case "Nights": measure = .low
        case "Humidity": measure = .dewPoint
        default: return nil
        }
        let below = crossing.label.hasPrefix("below")
        return DayQuery(name: "\(crossing.track) \(crossing.label) in \(period.name)",
                        conditions: [Condition(measure, below ? .below(crossing.threshold)
                                                              : .atOrAbove(crossing.threshold))],
                        scope: period)
    }

    // MARK: Small parts

    private func header(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(.tertiary)
            .frame(width: 62, alignment: .leading)
    }

    private func value(_ text: String) -> some View {
        Text(text).font(.callout.monospacedDigit()).frame(width: 62, alignment: .leading)
    }

    private func stat(_ label: String, _ value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(.tertiary)
            HStack(spacing: 6) {
                Text(value).font(.callout.weight(.semibold))
                if let detail { Text("· \(detail)").font(.callout).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func degrees(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))°" } ?? "—"
    }

    private func signed(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return rounded == 0 ? "no change" : (rounded > 0 ? "+\(rounded)°" : "\(rounded)°")
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
