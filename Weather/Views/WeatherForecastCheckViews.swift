//
//  WeatherForecastCheckViews.swift  (macOS)
//
//  MARKING THE TEN-DAY CARD'S HOMEWORK, directly underneath it.
//
//  The card sits below the forecast rather than in History on purpose. It is not
//  a fact about the archive, it is a fact about the thing you just read — "the
//  number above this has run four degrees cold all week" is only useful while
//  the number is still on screen.
//
//  It renders in three states and the middle one is the reason it exists at all.
//  Before the log holds anything there is no card. Once it holds something but
//  not enough to speak, the card says exactly what it is waiting for — because a
//  record that quietly accumulates for a week and shows nothing is
//  indistinguishable from one that is broken, and the first thing you want to
//  know after starting to keep score is that score-keeping started.
//

import SwiftUI
import Combine
import WeatherKit

/// Grades the recent past: the captured forecasts against the measured days.
@MainActor
final class ForecastCheckModel: ObservableObject {
    @Published private(set) var verdict: ForecastVerdict?
    /// Finished days that can be graded — forecast AND fully measured. This is
    /// the number the verdict's minimum is counted against.
    @Published private(set) var gradedDays = 0
    /// Finished days with a forecast on file that can't be graded yet, and why.
    /// Named in the card so a stalled archive reads as stalled, not as a count
    /// that is somehow already at the threshold.
    @Published private(set) var awaiting: [(day: String, partial: Bool)] = []
    /// The first day we ever wrote down a forecast for — "keeping score since".
    @Published private(set) var watchingSince: String?

    private let log: FileForecastLog
    private var loadedKey: String?

    init(root: URL? = nil) {
        log = FileForecastLog(root: root ?? AppGroup.dataDirectory
            .appendingPathComponent("Weather", isDirectory: true)
            .appendingPathComponent("forecasts", isDirectory: true))
    }

    /// `window` is how far back to look for gradable days. Thirty covers the
    /// "last ten days" question with room for the days the app went unopened,
    /// and stays inside one or two year files.
    ///
    /// The grading itself runs off the main actor. It opens a year of the daily
    /// archive and up to thirty small gzip files, which is nothing on a warm
    /// cache and is still not work to do while a scroll is in flight.
    func load(store: FileDailyArchive, timeZone: TimeZone,
              key: String, window: Int = 30, now: Date = Date()) async {
        guard loadedKey != key else { return }
        loadedKey = key

        let log = self.log
        let result = await Task.detached(priority: .userInitiated) { () -> Result in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone

            // COMPLETE days only. Today has not finished setting its high, and
            // grading a forecast against a partial afternoon would make every
            // morning look optimistic.
            let days: [String] = (1...window).compactMap {
                calendar.date(byAdding: .day, value: -$0, to: now)
                    .map { DayKey.string(for: $0, timeZone: timeZone) }
            }

            let logged = Set((try? log.loggedDays()) ?? [])

            let years = Set(days.compactMap { DayKey.year(of: $0) })
            var records: [String: DailyRecord] = [:]
            for year in years {
                for record in (try? store.records(inYear: year)) ?? [] {
                    records[record.day] = record
                }
            }

            var graded = 0
            var awaiting: [Pending] = []
            for day in logged.intersection(days).sorted() {
                if ForecastAccuracy.check(day: day, log: log, record: records[day],
                                          timeZone: timeZone) != nil {
                    graded += 1
                } else if (try? log.morningClaim(for: day, timeZone: timeZone)) != nil {
                    awaiting.append(Pending(day: day, partial: records[day] != nil))
                }
            }

            return Result(verdict: ForecastAccuracy.verdict(days: days, log: log,
                                                            records: records, timeZone: timeZone),
                          gradedDays: graded,
                          awaiting: awaiting,
                          watchingSince: logged.min())
        }.value

        verdict = result.verdict
        gradedDays = result.gradedDays
        awaiting = result.awaiting.map { ($0.day, $0.partial) }
        watchingSince = result.watchingSince
    }

    private struct Pending: Sendable {
        var day: String
        /// A record exists but covers too little of the day to score.
        var partial: Bool
    }

    private struct Result: Sendable {
        var verdict: ForecastVerdict?
        var gradedDays: Int
        var awaiting: [Pending]
        var watchingSince: String?
    }
}

struct ForecastCheckCard: View {
    let model: ForecastCheckModel
    let timezone: TimeZone

    var body: some View {
        if let verdict = model.verdict {
            graded(verdict)
        } else if model.watchingSince != nil {
            waiting
        }
    }

    // MARK: - Enough days to say something

    @ViewBuilder private func graded(_ v: ForecastVerdict) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(v.sentence)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if let caveat = v.caveat {
                Text(caveat)
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 22) {
                stat("Bias", signed(v.bias), "average, forecast minus actual")
                stat("Typical miss", "\(number(v.meanAbsoluteError))°", "regardless of direction")
                if let worst = v.largestMiss {
                    stat("Worst day", signed(worst.error), weekday(worst.day))
                }
            }

            Divider().opacity(0.5)

            VStack(spacing: 0) {
                ForEach(v.checks.reversed()) { check in
                    row(check, tolerance: v.tolerance)
                }
            }
        }
    }

    /// One graded day. Forecast, actual, and the gap — the gap last and coloured,
    /// because it is the only column anyone reads twice.
    private func row(_ check: ForecastCheck, tolerance: Double) -> some View {
        HStack(spacing: 0) {
            Text(weekday(check.day))
                .frame(width: 92, alignment: .leading)
            Text("said \(number(check.forecastHigh))°")
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text("hit \(number(check.actualHigh))°")
                .frame(width: 84, alignment: .leading)
            Text(signed(check.error))
                .foregroundStyle(color(for: check, tolerance: tolerance))
                .frame(width: 60, alignment: .leading)
            // Silent on the common case. A lead of 1 means the app went unopened
            // that morning and yesterday's word was what stood, which changes how
            // hard the day should be judged.
            if check.leadDays > 0 {
                Text("from the day before")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .font(.callout.monospacedDigit())
        .padding(.vertical, 3)
    }

    private func color(for check: ForecastCheck, tolerance: Double) -> Color {
        if check.wasClose(tolerance: tolerance) { return .secondary }
        return check.error < 0 ? .orange : .blue
    }

    private func stat(_ label: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.tertiary)
            Text(value).font(.title3.weight(.medium).monospacedDigit())
            Text(note).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Not enough yet

    @ViewBuilder private var waiting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(sinceLine)
                .font(.callout)
            Text("A verdict needs \(ForecastAccuracy.minimumDays) finished days that were both "
                 + "forecast and fully measured. \(model.gradedDays) so far.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let line = awaitingLine {
                Text(line)
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The forecast days that don't count yet, named — so "4 so far" beside a
    /// week of captures explains itself instead of looking broken.
    private var awaitingLine: String? {
        let unmeasured = model.awaiting.filter { !$0.partial }.map { shortDay($0.day) }
        let partial = model.awaiting.filter { $0.partial }.map { shortDay($0.day) }
        var parts: [String] = []
        if !unmeasured.isEmpty {
            parts.append("\(list(unmeasured)) \(unmeasured.count == 1 ? "was" : "were") forecast "
                         + "but \(unmeasured.count == 1 ? "hasn't" : "haven't") been measured into the archive yet.")
        }
        if !partial.isEmpty {
            parts.append("\(list(partial)) \(partial.count == 1 ? "was" : "were") only partly "
                         + "measured, so \(partial.count == 1 ? "it" : "they") can't be scored.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func shortDay(_ day: String) -> String {
        guard let date = DayKey.date(from: day, timeZone: timezone) else { return day }
        let f = DateFormatter()
        f.timeZone = timezone
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    private func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items.last!
        }
    }

    private var sinceLine: String {
        guard let since = model.watchingSince,
              let date = DayKey.date(from: since, timeZone: timezone) else {
            return "Keeping every forecast from now on."
        }
        let f = DateFormatter()
        f.timeZone = timezone
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMMM d"
        return "Keeping every forecast since \(f.string(from: date))."
    }

    // MARK: - Formatting

    private func weekday(_ day: String) -> String {
        guard let date = DayKey.date(from: day, timeZone: timezone) else { return day }
        let f = DateFormatter()
        f.timeZone = timezone
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEE MMM d"
        return f.string(from: date)
    }

    private func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// The sign is the finding, so it is always shown — including the `+`.
    private func signed(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == 0 { return "0°" }
        return (rounded > 0 ? "+" : "−") + number(abs(rounded)) + "°"
    }
}
