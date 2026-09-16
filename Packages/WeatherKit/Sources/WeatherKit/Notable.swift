//
//  Notable.swift  (WeatherKit)
//
//  The archive volunteering something, instead of waiting to be asked.
//
//  Everything else here answers a question. That's a real limit: the good
//  findings — that hot-but-dry days peak in October, that one summer was an
//  outlier rather than a trend — only turn up if you happen to ask the right
//  thing. The archive knows hundreds of them and has no way to speak first.
//
//  So: run a battery of probes over the record, score each candidate by HOW
//  UNUSUAL IT IS, and surface the few that clear the bar. Rule-based and scored,
//  like the rest of WeatherKit — no model, nothing to explain away.
//
//  Two rules do most of the work:
//
//  1. SAY NOTHING RATHER THAN SAY SOMETHING THIN. Every probe is gated on
//     having enough record to make its claim, and every notice carries a score
//     that must clear a floor. An ordinary week produces an empty list, and that
//     is the correct output — a surface that always has news is a surface whose
//     news means nothing.
//  2. A NOTICE IS A DOOR. Each one carries the query that produced it, so
//     "the longest run of oppressive air on record" is one click from the days
//     themselves. A finding you can't interrogate is a fact you have to trust.
//

import Foundation

/// One thing worth saying about the record right now.
public struct Notice: Equatable, Sendable, Identifiable {

    public enum Kind: String, Sendable {
        /// A run of matching days that is at or near the longest on record.
        case streak
        /// A run WITHOUT them that is at or near the longest.
        case absence
        /// This year running well ahead of or behind its usual count.
        case pace
        /// Something the season is late to deliver.
        case overdue
        /// A recent day far from normal for the date.
        case anomaly
        /// Where today sits in this condition's own season.
        ///
        /// Not an anomaly — and that's the point. Checked against the real
        /// archive, an ordinary August week produced exactly ONE anomaly, about
        /// wind. A surface that's empty most weeks is a surface nobody opens,
        /// and the fix isn't to lower the bar for "unusual" until ordinary
        /// things qualify — it's to also say the timely things that are simply
        /// worth knowing. These score below the anomalies, so real news always
        /// wins the top of the list.
        case position
    }

    public var kind: Kind
    /// The finding, as one sentence.
    public var headline: String
    /// The numbers behind it.
    public var detail: String?
    public var symbol: String
    /// 0…1. Comparable across probes — that's what lets them be ranked together.
    public var score: Double
    /// The question that produced this, so the notice can be opened.
    public var query: DayQuery?

    public var id: String { "\(kind.rawValue)·\(headline)" }
}

extension Climatology {

    /// What's unusual about the record as of `day`, most striking first.
    ///
    /// Returns an empty list on an ordinary week, deliberately.
    public func notable(asOf day: String,
                        queries: [DayQuery] = DayQuery.presets,
                        limit: Int = 6,
                        floor: Double = 0.4) -> [Notice] {
        guard let latest = all.last?.day, yearsOfRecord >= 3 else { return [] }

        // COUNTING PROBES ASK THE ARCHIVE, NOT THE CALENDAR.
        //
        // Anchored to today, a stale archive invents findings: run against a
        // date past the record's end, the pace probe reported "only 0 days of
        // rain so far, usually 15" — the absence of DATA read as a fact about
        // the weather. That's this file's own rule broken a level up, and a
        // closed laptop is enough to trigger it.
        let anchor = min(day, latest)

        var notices: [Notice] = []
        for query in queries {
            let result = run(query)
            // A question the record can barely answer can't be surprising.
            guard result.matchCount >= 5 else { continue }
            var forQuery: [Notice] = []
            forQuery += streakNotice(query, result, endingAt: latest)
            forQuery += absenceNotice(query, result, endingAt: latest)
            forQuery += paceNotice(query, result, asOf: anchor)
            forQuery += overdueNotice(query, result, asOf: anchor)
            forQuery += positionNotice(query, result, asOf: day)
            // ONE notice per question. Three ways of saying "it's muggy" crowd
            // out the things the list isn't saying at all.
            if let best = forQuery.max(by: { $0.score < $1.score }) { notices.append(best) }
        }
        notices += anomalyNotices(endingAt: latest)

        // Cap the everyday kind. In high summer, five different questions all
        // report "you're in the stretch for it", which is five ways of saying
        // it's August — and they'd crowd out the one probe that found something.
        var seen = Set<String>()
        var positions = 0
        return notices
            .filter { $0.score >= floor }
            .sorted { $0.score > $1.score }
            .filter { seen.insert($0.id).inserted }
            .filter { notice in
                guard notice.kind == .position else { return true }
                positions += 1
                return positions <= 3
            }
            .prefix(limit)
            .map { $0 }
    }

    /// "1 day", "12 days" — a plural that agrees with its number.
    static func days(_ count: Int) -> String {
        "\(count) \(count == 1 ? "day" : "days")"
    }

    // MARK: Probes

    /// A run happening RIGHT NOW that stands against the record's longest.
    private func streakNotice(_ query: DayQuery, _ result: QueryResult,
                              endingAt latest: String) -> [Notice] {
        let matching = Set(result.days.map(\.day))
        guard let current = currentRun(endingAt: latest, matches: { matching.contains($0.day) }),
              current.length >= 3 else { return [] }

        // Compare against every OTHER run, so a record doesn't measure itself.
        let others = result.streaks.filter { $0.firstDay != current.firstDay }
        let best = others.map(\.length).max() ?? 0
        guard best > 0 else { return [] }

        let ratio = Double(current.length) / Double(best)
        guard ratio >= 0.75 else { return [] }
        let isRecord = current.length >= best

        return [Notice(
            kind: .streak,
            // The query NAME leads, as a label rather than folded into a
            // sentence. Declined as a noun phrase it produced "0 days of days
            // it rained" — a name someone typed for a chip can't be relied on
            // to fit English grammar.
            headline: isRecord
                ? "\(query.name): \(current.length) days running — the longest streak on record, and still going."
                : "\(query.name): \(current.length) days running, close to the record of \(best).",
            detail: isRecord
                ? "The previous longest was \(best) days."
                : "The record is \(best) days.",
            symbol: "flame",
            score: isRecord ? 1.0 : min(0.85, 0.4 + (ratio - 0.75) * 1.6),
            query: query)]
    }

    /// The opposite: a long gap where this normally happens by now.
    ///
    /// Only for things common enough that their absence means something — a gap
    /// in something rare is just the rare thing being rare.
    private func absenceNotice(_ query: DayQuery, _ result: QueryResult,
                               endingAt latest: String) -> [Notice] {
        guard (result.rate ?? 0) >= 0.08,
              let last = result.days.first?.day,
              let gap = DayKey.distance(from: last, to: latest), gap >= 7 else { return [] }

        // Every historical gap between consecutive matches, for scale.
        let days = result.days.map(\.day).sorted()
        var gaps: [Int] = []
        for (earlier, later) in zip(days, days.dropFirst()) {
            if let span = DayKey.distance(from: earlier, to: later) { gaps.append(span) }
        }
        guard let longest = gaps.max(), longest > 0 else { return [] }

        let ratio = Double(gap) / Double(longest)
        guard ratio >= 0.75 else { return [] }

        return [Notice(
            kind: .absence,
            headline: gap >= longest
                ? "\(query.name): \(gap) days since the last one — the longest gap on record."
                : "\(query.name): \(gap) days since the last one.",
            detail: "The longest gap on record is \(longest) days.",
            symbol: "hourglass",
            score: gap >= longest ? 0.95 : min(0.8, 0.4 + (ratio - 0.75) * 1.6),
            query: query)]
    }

    /// This year's count against what it usually is BY THIS DATE.
    ///
    /// To-date, never against a whole year: comparing August's tally to a full
    /// year's normal would report a drought every spring.
    private func paceNotice(_ query: DayQuery, _ result: QueryResult,
                            asOf day: String) -> [Notice] {
        guard let year = DayKey.year(of: day) else { return [] }
        let monthDay = DayKey.monthDay(of: day)

        // THIS year has to have watched the stretch too, or a gap in the record
        // reads as a quiet season.
        guard hasCoverage(from: "\(year)-01-01", through: day, minimum: 0.85) else { return [] }

        let soFar = result.days.filter { $0.day >= "\(year)-01-01" && $0.day <= day }.count
        let past: [Int] = years.filter { $0 < year }.compactMap { priorYear in
            let end = "\(priorYear)-\(monthDay)"
            // Only years that watched the same stretch can set the pace.
            guard hasCoverage(from: "\(priorYear)-01-01", through: end, minimum: 0.85) else { return nil }
            return result.days.filter { $0.day >= "\(priorYear)-01-01" && $0.day <= end }.count
        }
        guard past.count >= 2, let usual = past.map(Double.init).sorted().median else { return [] }

        let gap = Double(soFar) - usual
        // Needs to be a real difference, not two versus three.
        guard abs(gap) >= max(3, usual * 0.4) else { return [] }

        let ahead = gap > 0
        // The query NAME leads, as a label rather than as a noun phrase. Folded
        // into a sentence it produced "0 days of days it rained" and "days of
        // the shop stays cool" — a name someone wrote for a chip can't be
        // relied on to decline.
        return [Notice(
            kind: .pace,
            headline: "\(query.name): \(soFar) so far this year, against a usual \(Int(usual.rounded())) by now.",
            detail: "Compared against the same stretch of \(past.count) earlier years.",
            symbol: ahead ? "arrow.up.right" : "arrow.down.right",
            score: min(0.95, 0.35 + abs(gap) / max(4, usual) * 0.5),
            query: query)]
    }

    /// Something the season should have delivered by now and hasn't.
    ///
    /// Measured in days INTO the window rather than in calendar dates, so a
    /// window that wraps the year end doesn't produce nonsense arithmetic.
    private func overdueNotice(_ query: DayQuery, _ result: QueryResult,
                               asOf day: String) -> [Notice] {
        guard let season = result.season, season.isMeaningful, season.hasUsefulActiveWindow,
              let start = season.activeBegins, let end = season.activeEnds else { return [] }

        let today = DayKey.monthDay(of: day)
        let window = WeatherPeriod(name: "", start: start,
                                   endExclusive: DayKey.next("2000-\(end)").map(DayKey.monthDay) ?? end)
        guard window.contains(monthDay: today) else { return [] }

        /// Days from the window's opening to a month-day, walking the window.
        func offset(_ monthDay: String) -> Int? {
            window.monthDays.firstIndex(of: monthDay)
        }
        guard let elapsed = offset(today) else { return [] }

        // How far into the window each past year saw its first one.
        let firsts: [Int] = years.compactMap { year -> Int? in
            guard let bounds = window.bounds(inYear: year),
                  hasCoverage(from: bounds.start, through: min(bounds.end, day), minimum: 0.85)
            else { return nil }
            let hit = result.days.map(\.day).sorted()
                .first { $0 >= bounds.start && $0 <= bounds.end }
            return hit.flatMap { offset(DayKey.monthDay(of: $0)) }
        }
        guard firsts.count >= 2, let usual = firsts.map(Double.init).sorted().median else { return [] }

        // Has THIS window seen one yet?
        guard let thisYear = DayKey.year(of: day),
              let bounds = window.bounds(inYear: window.wrapsYearEnd && today < start
                                         ? thisYear - 1 : thisYear) else { return [] }
        let seenThisYear = result.days.contains { $0.day >= bounds.start && $0.day <= day }
        guard !seenThisYear else { return [] }

        let late = Double(elapsed) - usual
        guard late >= 10 else { return [] }

        return [Notice(
            kind: .overdue,
            headline: "\(query.name): none yet this season — usually there'd have been one by now.",
            detail: "Typically the first arrives about \(Int(usual.rounded())) days into the window, which opened \(Climatology.days(elapsed)) ago.",
            symbol: "clock.badge.exclamationmark",
            score: min(0.9, 0.4 + late / 60),
            query: query)]
    }

    /// Where today sits inside this condition's own season.
    ///
    /// The everyday content of the surface. Three shapes, in the order they're
    /// worth hearing: it's about to start, you're in the thick of it, or it's
    /// nearly over. Each one is a date you can plan against rather than a
    /// statistic about the past.
    private func positionNotice(_ query: DayQuery, _ result: QueryResult,
                                asOf day: String) -> [Notice] {
        guard let season = result.season, season.isMeaningful else { return [] }

        // Prefer the "more often than not" season; fall back to the wider
        // window for things that never become the norm but still have a season.
        let (begins, ends, isNorm): (String?, String?, Bool) = season.hasSeason
            ? (season.begins, season.ends, true)
            : (season.hasUsefulActiveWindow ? season.activeBegins : nil,
               season.hasUsefulActiveWindow ? season.activeEnds : nil, false)
        guard let begins, let ends else { return [] }

        let window = WeatherPeriod(name: "", start: begins,
                                   endExclusive: DayKey.next("2000-\(ends)").map(DayKey.monthDay) ?? ends)
        let today = DayKey.monthDay(of: day)

        if window.contains(monthDay: today) {
            guard let left = Climatology.daysUntil(monthDay: ends, from: day) else { return [] }
            // Nearly over is the news; deep in the middle is just a state.
            let closing = left <= 21
            return [Notice(
                kind: .position,
                headline: closing
                    ? "\(query.name) usually eases around \(WeatherAlmanac.dateLabel(ends)) — about \(Climatology.days(left)) away."
                    : "\(query.name): you're in the stretch for it\(isNorm ? ", more likely than not" : ""), through about \(WeatherAlmanac.dateLabel(ends)).",
                detail: season.peak.map {
                    "It peaks around \(WeatherAlmanac.dateLabel($0.monthDay)), when \(Int(($0.rate * 100).rounded()))% of years have one."
                },
                symbol: "calendar.badge.clock",
                score: closing ? 0.55 : 0.45,
                query: query)]
        }

        guard let until = Climatology.daysUntil(monthDay: begins, from: day), until <= 45 else { return [] }
        return [Notice(
            kind: .position,
            headline: "\(query.name) usually \(isNorm ? "becomes the norm" : "starts") around \(WeatherAlmanac.dateLabel(begins)) — about \(Climatology.days(until)) away.",
            detail: season.peak.map {
                "The peak is around \(WeatherAlmanac.dateLabel($0.monthDay))."
            },
            symbol: "calendar.badge.clock",
            // Something arriving soon is more use than something you're already
            // living in.
            score: 0.6,
            query: query)]
    }

    /// A recent day a long way from normal for its date.
    ///
    /// Against the ±7-day pooled normal rather than the exact date: with a few
    /// years of record, "the warmest August 13" is a claim about four readings,
    /// while "unusually warm for mid-August" rests on sixty.
    private func anomalyNotices(endingAt latest: String, lookback: Int = 3) -> [Notice] {
        var notices: [Notice] = []
        let measures: [(String, KeyPath<DailyRecord, Double?>,
                        KeyPath<DailyNormal, Double?>, KeyPath<DailyNormal, Double?>, String)] = [
            ("afternoon", \.tempMax, \.high, \.highSpread, "thermometer.sun"),
            ("night", \.tempMin, \.low, \.lowSpread, "thermometer.snowflake"),
        ]

        var cursor: String? = latest
        for _ in 0..<lookback {
            guard let day = cursor, let record = record(on: day), record.isReliable else { break }
            defer { cursor = DayKey.previous(day) }

            let monthDay = DayKey.monthDay(of: day)
            let normal = normal(monthDay: monthDay)
            guard normal.isMeaningful else { continue }

            for (name, measure, centre, spread, symbol) in measures {
                guard let value = record[keyPath: measure],
                      let sigma = anomalyScore(value, normal: normal[keyPath: centre],
                                               spread: normal[keyPath: spread]),
                      abs(sigma) >= 2 else { continue }
                let warm = sigma > 0
                let usual = normal[keyPath: centre] ?? 0
                notices.append(Notice(
                    kind: .anomaly,
                    headline: "\(WeatherAlmanac.dayLabel(day))'s \(name) hit \(WeatherAlmanac.degrees(value)) — "
                            + "\(WeatherAlmanac.degrees(abs(value - usual))) \(warm ? "above" : "below") normal for the date.",
                    detail: "Mid-\(WeatherAlmanac.monthName(String(monthDay.prefix(2)))) usually brings \(WeatherAlmanac.degrees(usual)).",
                    symbol: symbol,
                    score: min(0.95, 0.35 + (abs(sigma) - 2) * 0.2),
                    query: nil))
            }
        }
        return notices
    }
}
