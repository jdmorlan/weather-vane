//
//  RhythmQuestionViews.swift  (macOS)
//
//  One question, one answer, one small picture.
//
//  WHAT THIS REPLACES, and why. `YearRhythmView` drew four measures as four heat
//  strips on one shared date axis, with twelve threshold pills scattered across
//  them. Everything on it was true and none of it was a claim — the reader had
//  to find the finding, and the honest verdict it got back was "what is this
//  actually telling me". The axis was shared because the measures happened to
//  share one, which is a fact about drawing rather than about the questions.
//
//  So: the heading is the question, in the words you'd ask it. The answer is a
//  sentence with a date in it. The picture is evidence for that one sentence and
//  nothing else — a single strip, the window drawn to scale, today marked.
//
//  THE PICTURE IS DELIBERATELY SMALL. It is the working, not the answer, and it
//  is there to do two things prose does badly: show that the date is the middle
//  of a WINDOW several weeks wide, and show where in the year it sits relative
//  to where you are standing. Both are positions, and positions are what a strip
//  is for. Everything else on the card is words, because everything else reads
//  better as words.
//
//  THE FULL YEAR IN EVERY CARD, not a zoom onto the answer. "Where in the year"
//  is half of what is being asked, and it can only be read against the whole.
//  Twelve identical frames also means the strips can be compared down the page
//  without anyone being asked to notice that the axis changed.
//

import SwiftUI
import WeatherKit

struct RhythmQuestionCard: View {
    let question: RhythmQuestion
    /// Today, so the strip can mark it and the answer can be dated.
    let today: String
    /// The near-term tracks, for the one line the climatology can't supply —
    /// what THIS year is doing about it. Often nothing, and correctly so.
    var nearTerm: [SeasonTrack] = []
    /// Extra context the question earns on its own, like the frost-free season
    /// under the two freeze questions.
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: question.symbol)
                    .font(.title3).foregroundStyle(tint)
                Text(question.question)
                    .font(.title2.weight(.semibold))
            }

            answerLine

            if let live = question.thisYear(nearTerm) {
                Label(live, systemImage: "calendar.badge.clock")
                    .font(.body)
                    .foregroundStyle(.tint)
                    .fixedSize(horizontal: false, vertical: true)
                    // Prose gets a readable measure even on a wide window; the
                    // strip below it does not, because a strip is a scale and
                    // wants every pixel it can have.
                    .frame(maxWidth: Self.proseWidth, alignment: .leading)
            }

            QuestionYearStrip(question: question, today: today)

            if !question.alternates.isEmpty {
                alternatesLine
            }
            if let footnote {
                Label(footnote, systemImage: "leaf.fill")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Self.proseWidth, alignment: .leading)
            }

            // The parameters, last and quiet — but present. A date like this is
            // unusable without knowing what the app means by "hot", and a
            // definition that lives only in a tooltip gets a number trusted
            // further than it has earned.
            Text(question.basis)
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Self.proseWidth, alignment: .leading)
        }
    }

    /// A comfortable line length for the sentences. Without it a wide window
    /// runs the definition line the full width of the display, which is the
    /// other way a card can be hard to read.
    static let proseWidth: CGFloat = 780

    /// The answer, with the window in the same breath as the date.
    ///
    /// Never a bare date. The record knows this as a spread of several weeks,
    /// and "September 28" alone invites planting against a precision that isn't
    /// there — the rule this whole area of the app was built on.
    private var answerLine: some View {
        let answer = question.answer
        return Group {
            if let earliest = answer.earliestMonthDay, let latest = answer.latestMonthDay,
               earliest != latest {
                Text("Usually **\(WeatherAlmanac.dateLabel(answer.monthDay))** — as early as \(WeatherAlmanac.dateLabel(earliest)), as late as \(WeatherAlmanac.dateLabel(latest)).")
            } else {
                Text("Usually **\(WeatherAlmanac.dateLabel(answer.monthDay))**.")
            }
        }
        .font(.title3)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: Self.proseWidth, alignment: .leading)
    }

    /// The same crossing at the thresholds that didn't get to be the answer.
    ///
    /// One line, not a second chart. "90° is the answer, 95° went three weeks
    /// ago and 85° hangs on another month" is the shape of an aside, and the
    /// four-row chart's mistake was drawing it with the same weight as the
    /// question.
    private var alternatesLine: some View {
        HStack(spacing: 10) {
            ForEach(question.alternates) { alternate in
                HStack(spacing: 6) {
                    Text("\(Int(alternate.threshold))°")
                        .font(.callout.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(tint)
                    Text(WeatherAlmanac.dateLabel(alternate.monthDay))
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 11).padding(.vertical, 4)
                .background(Capsule().fill(tint.opacity(0.14)))
            }
            Spacer(minLength: 0)
        }
    }

    private var tint: Color { QuestionYearStrip.color(question.measure) }
}

// MARK: - The evidence

/// One measure's year, with this question's answer marked on it.
///
/// Inherited wholesale from the chart this replaced — heat strip from the
/// normal curve, gaps where the archive is silent, window band under the mark —
/// because none of that was what was wrong with it. What was wrong was drawing
/// four of them at once and calling it an answer.
struct QuestionYearStrip: View {
    let question: RhythmQuestion
    let today: String

    private let stripHeight: CGFloat = 34
    private let bandHeight: CGFloat = 8

    private var todayIndex: Int {
        YearAxis.day(of: DayKey.monthDay(of: today)) ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .topLeading) {
                    strip(width: width)
                    monthLines(width: width)
                    windowBand(width: width)
                    todayMark(width: width)
                    answerMark(width: width)
                }
            }
            .frame(height: stripHeight + bandHeight + 3)
            monthAxis
        }
    }

    private func x(_ slot: Int, in width: CGFloat) -> CGFloat {
        width * CGFloat(slot) / CGFloat(YearAxis.dayCount)
    }

    private func strip(width: CGFloat) -> some View {
        let tint = Self.color(question.measure)
        let curve = question.curve
        return Canvas { context, size in
            let slot = size.width / CGFloat(max(1, curve.count))
            for (index, value) in curve.enumerated() {
                guard let value else { continue }
                let rect = CGRect(x: CGFloat(index) * slot - 0.5, y: 0,
                                  width: slot + 1, height: size.height)
                context.fill(Path(rect),
                             with: .color(tint.opacity(0.10 + 0.72 * question.intensity(value))))
            }
        }
        .frame(width: width, height: stripHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help("The usual reading for every day of the year at this station.")
    }

    private func monthLines(width: CGFloat) -> some View {
        ForEach(YearAxis.monthMarks, id: \.month) { mark in
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(width: 1, height: stripHeight)
                .offset(x: x(mark.start, in: width))
        }
    }

    /// The spread, to scale, under the mark it belongs to. The single most
    /// honest element on the card: it is the visible width of the app's
    /// uncertainty about a date it is otherwise printing to the day.
    @ViewBuilder
    private func windowBand(width: CGFloat) -> some View {
        if let earliest = question.answer.earliest, let latest = question.answer.latest,
           latest > earliest {
            let start = x(earliest, in: width)
            let end = x(latest, in: width)
            Capsule()
                .fill(Self.color(question.measure).opacity(0.55))
                .frame(width: max(4, end - start), height: bandHeight)
                .offset(x: start, y: stripHeight + 3)
                .help("The record has seen it as early as \(WeatherAlmanac.dateLabel(question.answer.earliestMonthDay ?? "")) and as late as \(WeatherAlmanac.dateLabel(question.answer.latestMonthDay ?? "")).")
        }
    }

    private func answerMark(width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.8))
            .frame(width: 3, height: stripHeight + bandHeight + 3)
            .offset(x: x(question.answer.dayOfYear, in: width) - 1.5)
            .help("Usually \(WeatherAlmanac.dateLabel(question.answer.monthDay)), across \(question.answer.yearsObserved) \(question.answer.yearsObserved == 1 ? "year" : "years") of record.")
    }

    /// Where you are standing. Dashed so it can never be mistaken for the
    /// answer mark beside it — on some cards the two sit days apart.
    private func todayMark(width: CGFloat) -> some View {
        Rectangle()
            .fill(.white.opacity(0.85))
            .frame(width: 2, height: stripHeight)
            .offset(x: x(todayIndex, in: width) - 1)
            .overlay(alignment: .topLeading) {
                Text("today")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize()
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(.black.opacity(0.35)))
                    .offset(x: x(todayIndex, in: width) + 4, y: 3)
            }
            .help("Today")
    }

    private var monthAxis: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(YearAxis.monthMarks, id: \.month) { mark in
                    // Names rather than initials. A row of J F M A M J J A S O
                    // N D is unreadable at a glance and ambiguous three times
                    // over, which is a poor trade for the pixels it saves.
                    Text(mark.name)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .frame(width: 32, alignment: .center)
                        .offset(x: x(mark.start + mark.length / 2, in: geo.size.width) - 16)
                }
            }
        }
        .frame(height: 15)
    }

    /// One colour per measure, shared with every other chart on the page so a
    /// reader doesn't have to relearn it card by card.
    static func color(_ measure: SeasonTrack.Measure) -> Color {
        switch measure {
        case .afternoons: return .orange
        case .nights: return .indigo
        case .humidity: return .teal
        case .freeze: return .blue
        }
    }
}

// MARK: - The page

/// Every question this station can answer, built once and listed.
///
/// ORDER IS FIXED, and it is a cycle rather than a ranking: the heat breaks,
/// the nights let go, the air dries, it freezes, it thaws, the nights warm, the
/// heat returns. Sorting by nearness would put a different question at the top
/// every few weeks and make the page impossible to learn — the same mistake the
/// old countdown made, which could only ever show the half of the year it
/// happened to be pointing at.
struct RhythmQuestionsView: View {
    let climate: Climatology
    let today: String
    /// The ten-day outlook in archive terms, so each question can say what THIS
    /// year is doing about it.
    var forecast: [SeasonForecastDay] = []

    /// Nil until the first build lands — NOT empty. The difference is what lets
    /// a card say "working it out" rather than "can't be answered".
    @State private var questions: [RhythmQuestion]?
    @State private var nearTerm: [SeasonTrack] = []
    @State private var frostFree: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // EVERY QUESTION HOLDS ITS PLACE, answered or not. This used to list
            // only what had been built, so while the build ran — or for a question
            // the record can't answer — the page was simply shorter, and a missing
            // card looks exactly like a card that was never meant to be there.
            ForEach(RhythmQuestionKind.catalogue) { kind in
                Group {
                    if let question = questions?.first(where: { $0.id == kind.id }) {
                        RhythmQuestionCard(question: question, today: today,
                                           nearTerm: nearTerm,
                                           footnote: question.measure == .freeze ? frostFree : nil)
                    } else {
                        RhythmQuestionPlaceholder(kind: kind, isBuilding: questions == nil)
                    }
                }
                .padding(26)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.045)))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.07)))
            }
        }
        // TWO BUILDS, KEYED ON WHAT EACH ACTUALLY READS. This was one build keyed
        // on today plus the forecast, which meant two things went wrong: every
        // forecast refresh restarted the whole seconds-long archive scan for the
        // answers, which don't read the forecast at all; and a nightly archive
        // top-up never rebuilt them, because the archive wasn't in the key.
        .task(id: archiveKey) {
            let climate = self.climate
            let built = await Task.detached(priority: .userInitiated) { () -> ([RhythmQuestion], String?) in
                let questions = climate.rhythmQuestions()
                let measured = climate.growingSeasons().compactMap(\.days).sorted()
                var line: String?
                if measured.count >= 2, let shortest = measured.first, let longest = measured.last {
                    line = "Between the two, the frost-free season runs \(measured[measured.count / 2]) days here — \(shortest) to \(longest) across \(measured.count) years."
                }
                return (questions, line)
            }.value
            guard !Task.isCancelled else { return }
            questions = built.0
            frostFree = built.1
        }
        .task(id: nearTermKey) {
            let climate = self.climate
            let day = self.today
            let outlook = self.forecast
            let tracks = await Task.detached(priority: .utility) {
                climate.seasonalTracks(asOf: day, horizonDays: 75, forecast: outlook)
            }.value
            guard !Task.isCancelled else { return }
            nearTerm = tracks
        }
    }

    /// Changes when the archive gains a day or the last one is revised — which
    /// is when the answers can change.
    private var archiveKey: String {
        "\(climate.all.count)|\(climate.all.last?.day ?? "")"
    }

    private var nearTermKey: String {
        archiveKey + "|" + today + forecast.map { "\($0.day):\($0.tempMin ?? -999):\($0.tempMax ?? -999)" }
            .joined(separator: "|")
    }
}

/// A question's place on the page before — or without — its answer.
///
/// The heading and the definition are printed either way: they are known before
/// any archive is read, and they are what tells you which card this is.
struct RhythmQuestionPlaceholder: View {
    let kind: RhythmQuestionKind
    /// Still being worked out, as opposed to worked out and unanswerable.
    let isBuilding: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: kind.symbol)
                    .font(.title3).foregroundStyle(QuestionYearStrip.color(kind.measure).opacity(0.5))
                Text(kind.question)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if isBuilding {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Working it out from the years behind you…")
                        .font(.title3).foregroundStyle(.secondary)
                }
                // The strip's footprint, held empty, so the page doesn't jump
                // when the answers land.
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.05))
                    .frame(height: 34 + 8 + 3 + 3 + 15)
            } else {
                Label("The years on file don't cross this line clearly enough to put a date on it yet. The answer appears here once they do.",
                      systemImage: "hourglass")
                    .font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: RhythmQuestionCard.proseWidth, alignment: .leading)
            }

            Text(kind.basis)
                .font(.footnote).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: RhythmQuestionCard.proseWidth, alignment: .leading)
        }
    }
}
