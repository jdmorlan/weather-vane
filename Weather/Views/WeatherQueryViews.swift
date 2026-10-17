//
//  WeatherQueryViews.swift  (macOS)
//
//  Building an Explore question by hand. The page itself is ExploreViews.swift;
//  a question that reports a number is answered by ReportViews.swift.
//

import SwiftUI
import WeatherKit

// MARK: - Building the question

struct QueryBuilder: View {
    @Binding var query: DayQuery
    /// Newest first — the years the archive actually holds.
    let availableYears: [Int]

    /// Which condition's threshold scale is open, if any — see `valueControl`.
    @State private var thresholdEditing: Int?
    @State private var precedingEditing = false

    /// One card per condition.
    ///
    /// Laid out inline, two conditions ran together into a single strip of
    /// controls with no boundary between them — you had to parse the row to
    /// find where one clause ended. A card makes each clause a discrete object,
    /// and the conjunction becomes its HEADING (WHEN · AND · IN), so the
    /// builder still reads as a sentence without needing separators wedged
    /// between the pieces.
    /// TWO TIERS, and they are not the same kind of thing.
    ///
    /// The cards are CONDITIONS — predicates a day either satisfies or doesn't,
    /// including "the day before had rain", which is still a fact about this
    /// day. The row beneath is a FILTER over whatever those conditions found:
    /// first of the year, last, in a run. Sitting them side by side as peer
    /// cards claimed they were the same kind of clause, and they aren't — one
    /// decides which days qualify, the other picks from the days that did.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WrappingRow(spacing: 10) {
                ForEach(Array(query.conditions.enumerated()), id: \.offset) { index, condition in
                    conditionChip(index, condition)
                }
                if query.precededBy != nil { afterCard }
                addCard
            }
            scopeCard
            // TWO VERBS, ONE LINE — until they don't fit. They were two labelled rows with their own
            // headings, 120pt for what is really one sentence about how to answer: which days, and what
            // to report about them. Side by side in an HStack, though, the extra controls an aggregate
            // brings (measure, grouping, ranking) push past the pane and SwiftUI takes the width out of
            // the only compressible things present — the segmented labels, which then wrap one letter
            // per line. `WrappingRow` sizes every child at its IDEAL width and moves the overflow to
            // the next line instead, so a narrow pane costs a row, never legibility.
            WrappingRow(spacing: 22) {
                sequenceFilter
                reportRow
            }
        }
    }

    // MARK: The other verb — report a number instead of listing days

    private enum ReportChoice: String, Hashable, CaseIterable, Identifiable {
        case days, total, average, highest, lowest
        var id: Self { self }
        var label: String { rawValue.capitalized }

        var reduction: Aggregate.Reduction? {
            switch self {
            case .days:    return nil          // no aggregate at all: count the days, the original verb
            case .total:   return .sum
            case .average: return .mean
            case .highest: return .max
            case .lowest:  return .min
            }
        }
    }

    private var reportChoice: ReportChoice {
        guard let aggregate = query.aggregate else { return .days }
        switch aggregate.reduce {
        case .sum:   return .total
        case .mean:  return .average
        case .max:   return .highest
        case .min:   return .lowest
        case .count: return .days
        }
    }

    /// REPORT — "how much", where SHOW above is "which days".
    ///
    /// Two verbs over one query, so they sit as sibling rows rather than as separate screens: the History
    /// tab's cards are questions of exactly this shape, and the only reason they lived somewhere else was
    /// that the language couldn't say them.
    private var reportRow: some View {
        HStack(spacing: 8) {
            Text("REPORT")
                .font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(.tertiary)
            HStack(spacing: 10) {
                HStack(spacing: 2) {
                    ForEach(offeredChoices) { option in reportButton(option) }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))

                if let aggregate = query.aggregate {
                    Menu(aggregate.measure.name) {
                        ForEach(Measure.allCases) { measure in
                            Button(measure.name) { setMeasure(measure) }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize()

                    Menu(groupLabel(aggregate.groupBy)) {
                        Button("all together") { setGrouping(.none) }
                        Button("per year") { setGrouping(.year) }
                        Button("per month") { setGrouping(.month) }
                        Button("per month of the year") { setGrouping(.monthOfYear) }
                    }
                    .menuStyle(.borderlessButton).fixedSize()

                    // Ranking is the difference between a trend and an answer to "the most", so it's a
                    // toggle rather than a hidden default.
                    Toggle("biggest first", isOn: Binding(
                        get: { query.aggregate?.rank != nil },
                        set: { on in setAggregate { $0.rank = on ? .highest : nil } }))
                        .toggleStyle(.checkbox).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Total is only a question you can ASK of a measure that accumulates.
    ///
    /// Rain and lightning strikes add up over a stretch; a temperature, a gust, a pressure does not.
    /// Summing daily highs gave "7,412°" — not a wrong answer but an answer to nothing, and it looked
    /// exactly as authoritative as a real one. The measure already knows which it is, so the button
    /// simply isn't there rather than being there and producing a number to be disbelieved.
    private var offeredChoices: [ReportChoice] {
        let current = query.aggregate
        let measure = current?.measure ?? defaultMeasure
        return ReportChoice.allCases.filter { option in
            guard let reduce = option.reduction else { return true }   // "Days" is always askable
            guard measure.reductions.contains(reduce) else { return false }
            // An average of an amount is per CYCLE, so under a grouping that holds one cycle it draws
            // the identical bars to Total. Two buttons, one answer, different words — offer one.
            let candidate = Aggregate(measure: measure, reduce: reduce,
                                      groupBy: current?.groupBy ?? .year)
            return !candidate.meanRestatesTotal
        }
    }

    /// Changing the grouping can strand the reduction the same way changing the measure can: a per-month
    /// rain average regrouped by year becomes the total under another name, so it moves to being the
    /// total outright rather than sitting on a button that's no longer offered.
    private func setGrouping(_ grouping: Aggregate.Grouping) {
        setAggregate {
            $0.groupBy = grouping
            if $0.meanRestatesTotal { $0.reduce = .sum }
        }
    }

    /// Changing the measure can invalidate the reduction — switching a rain TOTAL onto wind gust asks
    /// for something that isn't a number. The question moves to the measure's own natural reading
    /// (a gust's peak, a low's trough, a humidity's average) rather than being refused or left broken,
    /// and the change is visible: the highlighted button moves with it.
    private func setMeasure(_ measure: Measure) {
        setAggregate {
            $0.measure = measure
            if !measure.reductions.contains($0.reduce) { $0.reduce = measure.defaultReduction }
        }
    }

    private func groupLabel(_ grouping: Aggregate.Grouping) -> String {
        switch grouping {
        case .none:        return "all together"
        case .year:        return "per year"
        case .month:       return "per month"
        case .monthOfYear: return "per month of the year"
        }
    }

    private func setAggregate(_ change: (inout Aggregate) -> Void) {
        guard var aggregate = query.aggregate else { return }
        change(&aggregate)
        query.aggregate = aggregate
        query.name = ""
    }

    private func reportButton(_ option: ReportChoice) -> some View {
        let selected = reportChoice == option
        return Button {
            guard let reduce = option.reduction else {
                query.aggregate = nil
                query.name = ""
                return
            }
            // Keep whatever measure and grouping were already dialled in — switching from a total to an
            // average is a change of ONE thing, and resetting the rest would undo the setup.
            let existing = query.aggregate
            query.aggregate = Aggregate(measure: existing?.measure ?? defaultMeasure,
                                        reduce: reduce,
                                        groupBy: existing?.groupBy ?? .year,
                                        rank: existing?.rank,
                                        limit: existing?.limit)
            query.name = ""
        } label: {
            Text(option.label)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .lineLimit(1).fixedSize()
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor : Color.clear))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    /// What to report when nothing says otherwise: the measure the first condition already names, so
    /// "days over 100°" → "total high" isn't the first thing offered — rain is the usual subject of a sum.
    private var defaultMeasure: Measure { query.conditions.first?.measure ?? .rain }

    // MARK: The filter over what the conditions found

    private enum SequenceChoice: Hashable, CaseIterable, Identifiable {
        case all, first, last, runs
        var id: Self { self }
    }

    /// The label says what it's first OF.
    ///
    /// The rule already iterates instances of the SCOPE, not calendar years —
    /// scope a query to Winter and `bounds(inYear:)` hands back December
    /// through February. So "First each year" was never what the code did, and
    /// under a winter scope it was actively wrong: a winter's first freeze is
    /// not the year's first freeze.
    /// A named period reads straight into the sentence ("First each Winter").
    /// A brushed one is called something like "Sep 1 – Mar 1", which does not —
    /// so a hand-drawn stretch is simply a "window" here.
    private var scopeNoun: String {
        guard let scope = query.scope else { return "year" }
        return scope.kind == .custom ? "window" : scope.name
    }

    private func label(_ option: SequenceChoice) -> String {
        switch option {
        case .all: return "All days"
        case .first: return "First each \(scopeNoun)"
        case .last: return "Last each \(scopeNoun)"
        case .runs: return "In a run"
        }
    }

    private var choice: SequenceChoice {
        switch query.sequence {
        case nil: return .all
        case .firstEachYear: return .first
        case .lastEachYear: return .last
        case .inRunOfAtLeast: return .runs
        }
    }

    private var runLength: Int {
        if case .inRunOfAtLeast(let n) = query.sequence { return n }
        return 3
    }

    private var sequenceFilter: some View {
        // Buttons, not a segmented Picker.
        //
        // The Picker read its selection through a computed Binding and never
        // moved — clicking it changed neither the highlight nor anything below
        // it. Rather than keep guessing why, the selected state is now read
        // straight off the model and each choice is a Button whose action
        // plainly runs. Fewer moving parts than a control that has to be
        // trusted to round-trip a binding.
        HStack(spacing: 8) {
            Text("SHOW")
                .font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(.tertiary)
            HStack(spacing: 12) {
                HStack(spacing: 2) {
                    ForEach(SequenceChoice.allCases) { option in
                        choiceButton(option)
                    }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))

                if choice == .runs {
                    Stepper(value: Binding(get: { runLength },
                                           set: { query.sequence = .inRunOfAtLeast(max(2, $0)) }),
                            in: 2...30) {
                        Text("of \(runLength)+ days in a row")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .controlSize(.small).fixedSize()
                }
            }
        }
    }

    private func choiceButton(_ option: SequenceChoice) -> some View {
        let selected = choice == option
        return Button {
            switch option {
            case .all: query.sequence = nil
            case .first: query.sequence = .firstEachYear
            case .last: query.sequence = .lastEachYear
            // Keep the length you'd already dialled in.
            case .runs: query.sequence = .inRunOfAtLeast(runLength)
            }
            query.name = ""
        } label: {
            Text(label(option))
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .lineLimit(1).fixedSize()
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor : Color.clear))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    /// A condition on the day BEFORE. The per-day predicate model can't reach
    /// it — the fact lives in a different row — so it gets its own clause.
    /// A condition on the day BEFORE. The per-day predicate model can't reach it — the fact lives in a
    /// different row — so it stays its own clause, now as its own chip.
    @ViewBuilder private var afterCard: some View {
        if let condition = query.precededBy?.conditions.first {
            chip {
                connector("and the day before")
                Menu(condition.measure.name) {
                    ForEach(Measure.allCases) { measure in
                        Button(measure.name) {
                            setPreceding(Condition(measure, .atOrAbove(measure.defaultThreshold)))
                        }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                Menu(comparisonLabel(condition.test)) {
                    Button("at or above") { setPreceding(Condition(condition.measure, .atOrAbove(defaultValue(condition)))) }
                    Button("below") { setPreceding(Condition(condition.measure, .below(defaultValue(condition)))) }
                    Button("at or below") { setPreceding(Condition(condition.measure, .atOrBelow(defaultValue(condition)))) }
                }
                .menuStyle(.borderlessButton).fixedSize()
                precedingValue(condition)
                removeButton("Remove this clause") { query.precededBy = nil }
            }
        }
    }

    @ViewBuilder private func precedingValue(_ condition: Condition) -> some View {
        if case .inBand(let name) = condition.test {
            Text(name).font(.callout.weight(.medium)).foregroundStyle(Color.accentColor)
        } else {
            let value = defaultValue(condition)
            Button { precedingEditing.toggle() } label: {
                Text(condition.measure.format(value))
                    .font(.callout.weight(.medium)).foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $precedingEditing, arrowEdge: .bottom) {
                ThresholdSlider(measure: condition.measure, value: value, width: 220) { chosen in
                    setPreceding(Condition(condition.measure, moved(condition.test, to: chosen)))
                }
                .padding(14)
            }
        }
    }

    private func setPreceding(_ condition: Condition) {
        query.precededBy = PrecedingClause(conditions: [condition],
                                           within: query.precededBy?.within ?? 1)
        query.name = ""
    }

    /// A condition as a CHIP, reading as the clause it is: `when High 100° or above`.
    ///
    /// These were 272×86 cards, and the reason was real — laid out inline, two conditions ran together
    /// with no boundary between them. But what actually made a condition tall was the THRESHOLD SLIDER it
    /// held; the rest is three menus. Move the slider into a popover on the value and the clause fits on
    /// one line, with a border doing the boundary job the card was chosen for. The earlier decision isn't
    /// reversed so much as its cause is removed.
    private func conditionChip(_ index: Int, _ condition: Condition) -> some View {
        chip {
            connector(index == 0 ? "when" : "and")
            Menu(condition.measure.name) {
                ForEach(Measure.allCases) { measure in
                    Button(measure.name) { retarget(index, to: measure) }
                }
            }
            .menuStyle(.borderlessButton).fixedSize()

            Menu(comparisonLabel(condition.test)) {
                Button("at or above") { setTest(index, .atOrAbove(defaultValue(condition))) }
                Button("below") { setTest(index, .below(defaultValue(condition))) }
                Button("at or below") { setTest(index, .atOrBelow(defaultValue(condition))) }
                if !condition.measure.bands.isEmpty {
                    Button("is") { setTest(index, .inBand(condition.measure.bands[2].name)) }
                }
            }
            .menuStyle(.borderlessButton).fixedSize()

            valueControl(index, condition)

            if query.conditions.count > 1 {
                removeButton("Remove this condition") { query.conditions.remove(at: index) }
            }
        }
    }

    /// The word that joins the clause to the sentence — lowercase and quiet, so the chips read as prose
    /// rather than as a row of labelled boxes.
    private func connector(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.tertiary)
    }

    private func removeButton(_ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
        }
        .buttonStyle(.plain).foregroundStyle(.tertiary).help(help)
    }

    /// The chip shell every clause wears — one line, bordered, sized by its contents.
    private func chip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 3) { content() }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.09)))
    }

    @ViewBuilder private func valueControl(_ index: Int, _ condition: Condition) -> some View {
        switch condition.test {
        case .inBand(let name):
            Menu(name) {
                ForEach(condition.measure.bands) { band in
                    Button(band.name) { setTest(index, .inBand(band.name)) }
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
        case .atOrAbove(let value), .below(let value), .atOrBelow(let value):
            // The number is the chip's content; the SCALE is a popover. A slider needs ~180pt of width to
            // be landable, and paying that in permanent page height for a control you touch once per
            // question was the whole reason the clause was a card.
            Button {
                thresholdEditing = thresholdEditing == index ? nil : index
            } label: {
                Text(condition.measure.format(value))
                    .font(.callout.weight(.medium)).foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .popover(isPresented: Binding(get: { thresholdEditing == index },
                                          set: { if !$0 { thresholdEditing = nil } }),
                     arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(condition.measure.name) \(comparisonLabel(condition.test))")
                        .font(.caption).foregroundStyle(.secondary)
                    ThresholdSlider(measure: condition.measure, value: value, width: 220) { chosen in
                        setTest(index, moved(condition.test, to: chosen))
                    }
                }
                .padding(14)
            }
        case .between(let lower, let upper):
            // Read-only, as it always was: a range has two handles and the builder has never had a control
            // for setting one. It arrives from the query language — a model can say it — and shows as what
            // it is.
            Text("\(condition.measure.format(lower))–\(condition.measure.format(upper))")
                .font(.callout.weight(.medium)).foregroundStyle(Color.accentColor)
        }
    }

    private var addCard: some View {
        Menu {
            Button("Condition on the day") {
                query.conditions.append(Condition(.dewPoint, .below(65)))
            }
            Button("Condition on the day before") {
                setPreceding(Condition(.rain, .atOrAbove(0.1)))
            }
            .disabled(query.precededBy != nil)
        } label: {
            // AN EMPTY CONTROL SHOULDN'T BE THE LOUDEST THING ON THE PAGE. This was a 118×86 dashed card
            // holding nothing — a footprint that grew, in effect, as the query got emptier.
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                Text("condition").font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.quaternary))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        // `.borderlessButton` + `.fixedSize` collapsed the label to bare text,
        // so the card lost its box and floated out of the row's alignment.
        // `.button` + `.plain` keeps the label exactly as drawn.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Narrow the question")
    }

    /// Scope isn't a condition, but it's one more clause of the same sentence —
    /// so it wears the same card with its own heading.
    /// Full width, and last — every condition above is asked WITHIN this
    /// stretch, so it's the ground the rest of the sentence stands on rather
    /// than another clause beside them. It also shares an axis with the "When
    /// it happens" curve in the results, which is why it's a strip and not a
    /// menu.
    private var scopeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("IN")
                    .font(.system(size: 9, weight: .bold)).tracking(0.8)
                    .foregroundStyle(.tertiary)
                // THE NAME IS THE CONTROL. It was a label, with a separate `presets ›` disclosure and an
                // `any date` link inside the brush to clear it — three affordances for "which stretch of
                // the year", and between them the words "any date" appeared four times on this card.
                scopeMenu
                if let length = scopeLength {
                    Text(length).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                Text("of").font(.callout).foregroundStyle(.secondary)
                yearMenu
            }
            PeriodBrush(period: Binding(get: { query.scope },
                                        set: { query.scope = $0; query.name = "" }))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
    }

    /// Named stretches of the year, and the way back to none. Brushing still draws any window you like;
    /// this is for the ones that already have names, which is most of what anyone asks for.
    private var scopeMenu: some View {
        Menu {
            Button("Any date") { query.scope = nil; query.name = "" }
            Section("Seasons") {
                ForEach(WeatherPeriod.seasons) { period in
                    Button(period.name) { query.scope = period; query.name = "" }
                }
            }
            Section("Months") {
                ForEach(WeatherPeriod.months) { period in
                    Button(period.name) { query.scope = period; query.name = "" }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(query.scope?.name ?? "any date").font(.callout.weight(.medium))
                Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// How long the window is — stated once, beside its name, instead of at the far end of its own row.
    private var scopeLength: String? {
        guard let scope = query.scope else { return nil }
        guard let start = YearAxis.day(of: scope.start), let end = YearAxis.day(of: scope.endExclusive)
        else { return nil }
        let length = start == end ? YearAxis.dayCount : YearAxis.wrap(end - start)
        let wraps = start + length > YearAxis.dayCount
        return "\(length) days\(wraps ? " · wraps the year end" : "")"
    }

    private func clause<Accessory: View, Content: View>(
        heading: String, width: CGFloat,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(heading)
                    .font(.system(size: 9, weight: .bold)).tracking(0.8)
                    .foregroundStyle(.tertiary)
                Spacer()
                accessory()
            }
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(width: width, height: 86, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
    }

    private var yearMenu: some View {
        Menu(query.years.label) {
            Button("all years") { query.years = .all }
            Divider()
            ForEach(availableYears, id: \.self) { year in
                Button(String(year)) { query.years = .year(year) }
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    // MARK: Edits

    /// Changing the measure has to rebuild the test too: "is Muggy" is
    /// meaningless once the measure is wind, and a 65 that meant degrees would
    /// silently become 65 mph.
    private func retarget(_ index: Int, to measure: Measure) {
        let wasAbove = isAbove(query.conditions[index].test)
        let value = measure.defaultThreshold
        query.conditions[index] = Condition(measure, wasAbove ? .atOrAbove(value) : .below(value))
    }

    private func setTest(_ index: Int, _ test: Test) {
        query.conditions[index] = Condition(query.conditions[index].measure, test)
        query.name = ""   // it's no longer the preset it started as
    }

    /// Keeps the number when only the direction changes, so flipping "below 90"
    /// to "at or above" doesn't also move the threshold.
    private func defaultValue(_ condition: Condition) -> Double {
        switch condition.test {
        case .atOrAbove(let v), .below(let v), .atOrBelow(let v): return condition.measure.clamp(v)
        case .between(let lower, _): return condition.measure.clamp(lower)
        case .inBand(let name):
            let band = condition.measure.bands.first { $0.name == name }
            return band?.lower ?? band?.upper ?? condition.measure.defaultThreshold
        }
    }

    /// The same comparison at a new threshold.
    private func moved(_ test: Test, to value: Double) -> Test {
        switch test {
        case .atOrBelow: return .atOrBelow(value)
        case .below: return .below(value)
        default: return .atOrAbove(value)
        }
    }

    private func isAbove(_ test: Test) -> Bool {
        if case .atOrAbove = test { return true }
        return false
    }

    private func comparisonLabel(_ test: Test) -> String {
        switch test {
        case .atOrAbove: return "at or above"
        case .below: return "below"
        case .atOrBelow: return "at or below"
        case .between: return "between"
        case .inBand: return "is"
        }
    }
}

// MARK: - Setting a threshold

/// A threshold on its own scale, with ticks.
///
/// Replaces a menu of six "sensible" values, which could only ever offer
/// somebody else's opinion about which numbers matter — and for rain, where the
/// difference between 1.00" and 1.40" is a real one, offered almost nothing.
struct ThresholdSlider: View {
    let measure: Measure
    let value: Double
    /// Sized by its container — inside a clause card there's more room than the
    /// old inline row ever gave it.
    var width: CGFloat = 176
    /// Called when the drag ENDS. Every intermediate position would re-run the
    /// whole query, so the number tracks the knob but the archive is only asked
    /// once you've landed.
    var onCommit: (Double) -> Void

    @State private var draft: Double = 0

    private var ticks: [Double] {
        let first = (measure.range.lowerBound / measure.tickStep).rounded(.up) * measure.tickStep
        return stride(from: first, through: measure.range.upperBound, by: measure.tickStep).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                // NO `step:` — macOS draws its own tick mark for every step,
                // and rain steps by 0.01 across three inches, so the control
                // came out wearing three hundred of them as a grey hatch. The
                // slider runs continuous and the value is snapped here instead,
                // which also leaves the labelled ticks below legible.
                Slider(value: Binding(get: { draft },
                                      set: { draft = snap($0) }),
                       in: measure.range) { editing in
                    if !editing { onCommit(draft) }
                }
                .controlSize(.small)
                .frame(width: width)

                Text(measure.format(draft))
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 62, alignment: .leading)
            }
            tickMarks
        }
        .onAppear { draft = measure.clamp(value) }
        // Re-seed when the condition changes underneath — a preset, a new
        // measure, or a hand-off from another card.
        .onChange(of: value) { _, new in draft = measure.clamp(new) }
        .onChange(of: measure) { _, new in draft = new.clamp(draft) }
    }

    /// Round to the measure's own granularity — fine enough to land on the
    /// number you meant, never so fine that a round one is hard to hit.
    private func snap(_ value: Double) -> Double {
        let stepped = (value / measure.step).rounded() * measure.step
        return measure.clamp(stepped)
    }

    /// Inset to match the slider's track, which reserves half a knob at each
    /// end — ticks flush to the frame would sit off the scale they label.
    private var tickMarks: some View {
        GeometryReader { geo in
            let inset: CGFloat = 9
            let span = measure.range.upperBound - measure.range.lowerBound
            let usable = geo.size.width - inset * 2
            ForEach(ticks, id: \.self) { tick in
                let fraction = (tick - measure.range.lowerBound) / span
                Text(shortTick(tick))
                    .font(.system(size: 8)).foregroundStyle(.tertiary)
                    .fixedSize()
                    // Centred on its own tick, but only as wide as its text —
                    // a fixed 30pt box per label had neighbours overlapping.
                    .frame(width: 24)
                    .offset(x: inset + CGFloat(fraction) * usable - 12)
            }
        }
        .frame(width: width, height: 11)
    }

    /// Ticks label the SCALE, not a reading — so they drop the unit's noise
    /// ("1.5" rather than "1.50\"") and let the value beside the slider carry
    /// the precise, formatted number.
    private func shortTick(_ tick: Double) -> String {
        switch measure {
        case .rain, .pressure, .uv:
            return tick == tick.rounded() ? "\(Int(tick))" : String(format: "%g", tick)
        default:
            return "\(Int(tick))"
        }
    }
}
