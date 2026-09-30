//
//  WeatherView.swift  (macOS)
//
//  The Weather surface. Card-based layout (inspired by a clean web dashboard) but
//  with WeatherKit's interpretation as the hero — the screen leads with ANSWERS
//  ("muggy", "a brief sprinkle at 2pm", "pressure steady"), and the numeric tiles
//  back them up. All fetch + interpretation live in WeatherKit; this is presentation.
//

import SwiftUI
import Combine
import WeatherKit

@MainActor
final class WeatherModel: ObservableObject {
    @Published var report: WeatherReport?
    @Published var isLoading = false
    @Published var error: String?
    @Published var lastUpdated: Date?

    /// Where captured forecasts land. `<data>/Weather/forecasts/2026/2026-09-14.ndjson.gz`,
    /// a sibling of the daily archive and keyed the same way, so the promise
    /// about a day and the measurement of it are one filename apart.
    private let log = FileForecastLog(root: AppGroup.dataDirectory
        .appendingPathComponent("Weather", isDirectory: true)
        .appendingPathComponent("forecasts", isDirectory: true))

    func refresh(token: String, stationID: Int) async {
        // Not twice at once. The automatic loop, launch and pull-to-refresh can
        // all ask in the same second; the one already in flight answers them all.
        guard !token.isEmpty, stationID != 0, !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let client = TempestClient(token: token, stationID: stationID)
            // Fetched raw rather than through `report()` so the ten days can be
            // WRITTEN DOWN before they're interpreted. A forecast is only
            // observable at the moment it is issued — WeatherFlow serves no
            // history of its own predictions — so a payload that renders and is
            // dropped is gone for good, and with it any chance of ever asking
            // whether the mornings were right.
            let forecast = try await client.fetch()
            let now = Date()
            await record(forecast, at: now)
            report = WeatherInterpreter.report(from: forecast, now: now)
            lastUpdated = now
        } catch {
            self.error = (error as? TempestClient.Failure)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Off the main actor and never allowed to fail the fetch: the log is a
    /// side-effect of looking at the weather, and a disk error must not blank a
    /// screen that has a perfectly good forecast in hand. Awaited rather than
    /// fired and forgotten so that by the time `lastUpdated` moves, the claim
    /// this fetch made is already on disk for the card below to read.
    private func record(_ forecast: BetterForecast, at instant: Date) async {
        let log = self.log
        await Task.detached(priority: .utility) {
            try? log.record(ForecastNote.notes(from: forecast, issuedAt: instant))
        }.value
    }
}

/// The station surfaces: Now, History, Wind and Explore.
///
/// FOUR OF THE SIX, and the four that have something in common — every one of
/// them is built out of THIS station's readings, live or archived. Radar and
/// Pattern are neither, which is why they're separate views entirely rather
/// than two more cases below.
///
/// It no longer owns its models or its navigation. Both moved up to the window
/// (`StationModels`, `Destination`) when the segmented picker became a sidebar:
/// a picker inside a `ScrollView` never unmounts anything, and a detail column
/// unmounts on every change of destination. The models are handed in and held
/// as `@ObservedObject` so this view still redraws on their changes while
/// something longer-lived keeps them alive.
struct WeatherView: View {
    @EnvironmentObject private var settings: AppSettings

    @ObservedObject private var model: WeatherModel
    @ObservedObject private var archive: WeatherArchiveModel
    @ObservedObject private var samples: WeatherSamplesModel
    @ObservedObject private var mornings: RecentWindowsModel
    @ObservedObject private var todaySamples: DayObservationsModel
    @ObservedObject private var hazards: WeatherHazardModel
    @ObservedObject private var forecastCheck: ForecastCheckModel
    @ObservedObject private var precip: PrecipOutlookModel
    @ObservedObject private var storms: StormOutlookModel

    /// Which of the four is on screen. A `let` rather than `@State`: the sidebar
    /// owns the selection now, and a second copy of it here would be a second
    /// source of truth for the same fact.
    let destination: Destination

    /// Held here rather than inside Explore so another card can hand one over.
    /// Opens on THIS year: "how often has it rained lately" is the question you
    /// arrive with, and all-time is a deliberate widening from there.
    @State private var query: DayQuery = {
        var seeded = DayQuery.presets[0]
        seeded.years = .year(Calendar.current.component(.year, from: Date()))
        return seeded
    }()

    /// Ask the window to go somewhere. The History → Explore hand-off used to be
    /// `tab = .explore` on a private `@State`; with selection living in the
    /// sidebar it has to be a request rather than an assignment.
    var navigate: (Destination) -> Void

    /// Ask the window to open setup. A request for the same reason `navigate` is
    /// one: the sheet is owned by the root, because a sheet presented by a view
    /// that navigation can unmount is a sheet that vanishes mid-flow.
    var openSetup: () -> Void

    /// Pull to refresh on the iPad — the same refresh as the toolbar button,
    /// asked for with the gesture a finger expects. A no-op on the Mac, where a
    /// scroll view has no pull; the button is the way in there.
    var refresh: () async -> Void

    init(models: StationModels,
         destination: Destination,
         navigate: @escaping (Destination) -> Void = { _ in },
         openSetup: @escaping () -> Void = {},
         refresh: @escaping () async -> Void = {}) {
        model = models.weather
        archive = models.archive
        samples = models.samples
        mornings = models.mornings
        todaySamples = models.todaySamples
        hazards = models.hazards
        forecastCheck = models.forecastCheck
        precip = models.precip
        storms = models.storms
        self.destination = destination
        self.navigate = navigate
        self.openSetup = openSetup
        self.refresh = refresh
    }

    var body: some View {
        Group {
            if let report = model.report {
                dashboard(report)
            } else if model.isLoading {
                ProgressView("Reading your station…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.error {
                ContentUnavailableView("Couldn’t load weather", systemImage: "cloud.bolt",
                                       description: Text(error))
                    .emptyStatePanel()
            } else {
                Color.clear
            }
        }
        // NOTE — Almanac wired two more modifiers in here: a `SurfaceRouter` that
        // let a conversation hand this view a `DayQuery` to adopt, and a matching
        // publish of whatever query is on screen so an ask could say "refine that".
        // That is the LLM harness, not weather, so it stayed behind. `query` still
        // lives at this level, which is the whole seam — anything that wants to
        // drive Explore from outside has one property to set.
    }

    // MARK: Dashboard

    @ViewBuilder private func dashboard(_ r: WeatherReport) -> some View {
        ScrollView {
            // Wrapped so a card can move the page — Explore's notices hand a
            // query to a builder that's usually below the fold, and changing
            // something off-screen is indistinguishable from a dead click.
            ScrollViewReader { scroll in
            // LAZY: the cards below the fold were rendering whether or not you'd scrolled to them, so a
            // rebuilt result paid for the day list, the calendar and the streaks even while you were
            // looking at the controls at the top.
            LazyVStack(alignment: .leading, spacing: 18) {
                // ABOVE everything, including the station's own lightning alerts:
                // a tornado warning outranks whatever you came to this
                // destination to read.
                HazardBanner(watch: hazards.watch)
                StationAlertsBanner(report: r)
                archiveBanner
                samplesBanner

                // The five-way segmented picker that used to sit here is gone —
                // it is the sidebar now. Worth naming what that fixed rather
                // than leaving a silent absence: the picker was INSIDE this
                // scroll, so opening History and reading down took the only way
                // back off the top of the screen.

                switch destination {
                // The split is by ANCHOR, not by where the data came from. Two
                // of these cards read the archive and still belong here: "this
                // day in past years" is context for the number at the top of
                // the screen, and "what's ahead" extends the ten-day forecast
                // out to a season. Both answer a question about TODAY, which is
                // what this destination is for — a period selector would have
                // nothing to say to either of them.
                case .now:
                    // Built once and handed down. Two cards read today's shape —
                    // the extremes at the top and the strip below — and reducing
                    // 1,400 samples twice per render is the kind of cost that
                    // only shows up as a scroll that isn't smooth.
                    let strip = DayStrip.today(r, samples: todaySamples.samples)
                    // Right now: conditions, the numbers, comfort, daylight. The
                    // pressure band is the one thing it takes from the archive.
                    RightNowCard(report: r, strip: strip,
                                 pressureBand: archive.climatology?.pressureBand())
                    // What the rain is DOING, on a day that saw any. Renders
                    // nothing otherwise, which is why it can sit this high: on a
                    // wet day it's the most important thing on the screen, and on
                    // a dry one it isn't there at all.
                    rainCard(r)
                    // Radar used to sit here, and doesn't now: it is its own
                    // destination, one click away in the sidebar, and a second
                    // copy on this scroll meant two `RadarModel`s warming two
                    // tile caches for the same loop.
                    // TODAY, midnight to midnight, at the resolution it actually
                    // happens in. The sentence and the heads-up lines lead; the
                    // hours carry the numbers; the day's parts are bands over the
                    // same strip.
                    TodayCard(report: r, strip: strip)
                    // Detail opens the next three days rather than the grade's
                    // working: the question after reading a ten-day is "tell me
                    // more about the part I'll act on", not "how has it scored".
                    if !r.days.isEmpty { TenDayCard(report: r) { forecastGrade(detail: .forecast) } }
                    seasonsCard(r)      // past ten days: what the season does next
                    // The ONE archive card on this page, and it earns the place:
                    // "is today hot for September 16" is a question about today.
                    // "How the forecast has done" and "Recent mornings" used to
                    // sit here too and don't now — one grades the source rather
                    // than describing the sky, the other is anchored to a
                    // finished day. Both are under History.
                    thisDateCard(r)
                // ONE control, and every card is a lens under it. Records,
                // Rainfall and Winter chill used to sit loose below the period
                // section; they take no period because they ARE the whole
                // archive, which is the All-time grain — so they moved inside
                // rather than staying as three cards with no door of their own.
                case .history:
                    periodSection(r)
                    // Both arrived from Now, and both belong to the same
                    // register: things measured about finished days. The period
                    // browser above governs a STRETCH; these two answer about
                    // the record itself, so they sit under it rather than
                    // inside its grain picker.
                    forecastCheckSection(r)
                    dayShapesSection
                case .forecast:
                    // The grade rides along, one line, where it changes how the
                    // numbers under it are read — and its Detail is the working,
                    // under History.
                    ForecastPage(report: r, storms: storms, precip: precip.outlook,
                                 home: settings.homePoint, openSetup: openSetup) {
                        forecastGrade(detail: .history)
                    }
                case .rhythms:
                    rhythmsSection(r)
                case .rain:
                    rainSection(r)
                case .wind:
                    windSection
                case .explore:
                    exploreSection(r) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            scroll.scrollTo(WeatherExploreView.builderAnchor, anchor: .top)
                        }
                    }
                // Their own views, reached from the sidebar. Listed rather than
                // defaulted so that adding another destination is a compile
                // error here instead of a blank screen.
                case .map, .pattern, .station:
                    EmptyView()
                }

                archiveFooter
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
            }
        }
        .refreshable { await refresh() }
    }

    /// The period surface, held back until the archive can say anything about a
    /// stretch at all. Below that the History tab is still worth opening — the
    /// records and rainfall cards explain what they're waiting for.
    @ViewBuilder private func periodSection(_ r: WeatherReport) -> some View {
        if let climate = archive.climatology, climate.dayCount >= 90 {
            WeatherArchiveBrowser(climate: climate, today: todayKey(r),
                                  precipToday: r.precipToday) { handOff in
                // A crossing card says WHEN nights start dropping below 70°.
                // The obvious next question is which nights those were, and
                // that's a query — so the card hands one over rather than
                // growing its own day list.
                query = handOff
                navigate(.explore)
            }
        }
    }

    /// RAIN — how much, how often, and how long between.
    ///
    /// Assembled rather than invented. `RainfallCard` was in History's All-time
    /// grain and answers the AMOUNT half; `RainHabits` is new and answers the
    /// other half, which nothing in the app could say before — two Octobers
    /// holding the same four inches draw identically on a totals chart and are
    /// not the same October.
    ///
    /// It also retires a detour. "Wettest month", "rain by year", "when did it
    /// last rain" were all reachable only by building a query in Explore, which
    /// is the right tool for a question you thought of and the wrong one for a
    /// question the app already knows you'll ask.
    @ViewBuilder private func rainSection(_ r: WeatherReport) -> some View {
        // ABOVE THE ARCHIVE GATE, DELIBERATELY. Everything below needs about a
        // season of record before it can say what is usual; this needs only a
        // home point, and "is rain coming" is the question someone opens Rain to
        // ask on the day they install the app.
        card(label: "Next 18 hours") {
            PrecipOutlookCard(outlook: precip.outlook,
                              failure: precip.failure,
                              isLoading: precip.isLoading,
                              needsHome: precip.needsHome,
                              onSetUpHome: openSetup)
        }

        if let climate = archive.climatology, climate.dayCount >= 90 {
            let today = todayKey(r)
            card(label: "Rainfall") {
                RainfallCard(climate: climate, today: today)
            }
            // NOTE — the biggest-days rows are deliberately not clickable. The
            // obvious destination is History's day grain pinned to that date,
            // and `WeatherArchiveBrowser` owns its grain and position privately
            // with no way in from outside. A tap that landed somewhere merely
            // rain-adjacent would be worse than no tap; opening it properly
            // means giving the browser an entry point, which is its own change.
            RainHabitsSection(climate: climate, today: today) { label, content in
                card(label: label) { content }
            }
        } else if archive.isLoadingClimatology {
            preparing("Reading your rain history", detail: "Going through the archive.")
        } else {
            ContentUnavailableView("Not enough record yet", systemImage: "drop",
                                   description: Text("Rain needs about a season of archive before it can say how much is usual, how often it falls, or how long the dry stretches run."))
                .emptyStatePanel()
        }
    }

    /// The wind surface, and the three things that can be true before it exists.
    ///
    /// Waiting is stated rather than hidden because on a cold archive this is a
    /// genuinely long wait — an hour of fetching and then sixteen seconds of
    /// folding — and a spinner with no number attached to it is how a user decides
    /// something is broken. Once the cache is warm it's a file read and none of
    /// this is ever seen again.
    @ViewBuilder private var windSection: some View {
        if let climate = samples.climate, climate.days > 0 {
            WindSurface(climate: climate, facing: settings.facing)
        } else if let fold = samples.foldProgress {
            waiting("Reading the wind out of \(fold.total.formatted()) days",
                    detail: "\(fold.done.formatted()) of \(fold.total.formatted())",
                    fraction: Double(fold.done) / Double(max(1, fold.total)))
        } else if let fill = samples.fillProgress, !fill.isFinished {
            waiting("Fetching the minutes behind your archived days",
                    detail: "\(fill.completedDays.formatted()) of \(fill.totalDays.formatted()) days"
                        + (fill.samplesWritten > 0 ? " · \(fill.samplesWritten.formatted()) readings" : ""),
                    fraction: fill.fraction)
        } else if samples.isPreparing {
            preparing("Reading the wind out of your archive",
                      detail: "The rose is built from every minute on record, which takes a moment the first time.")
        } else if let fill = archive.progress {
            // THE DAY-ONE STATE, and it used to fall through to "No wind history
            // yet" below — a flat claim about the station, made while the thing
            // the wind is derived FROM was still arriving. The sample fill cannot
            // even start until the daily archive knows which days exist (see
            // `StationModels.catchUpArchives`), so on a device that has nothing on
            // disk this is the first true answer, and it is a WAIT rather than a
            // nothing. Never seen on a machine that has been running a while,
            // where `progress` is nil within a second of launch.
            waiting("Finding out which days your station has",
                    detail: fill.daysArchived > 0
                        ? "\(fill.daysArchived.formatted()) days so far"
                        : "The minutes the wind is built from come after this.",
                    fraction: fill.fraction)
        } else {
            // Direction is the one measure the DAILY archive never kept — a mean of
            // a circular quantity is meaningless — so this tab cannot fall back on
            // it the way the others can. Saying so is better than an empty rose.
            ContentUnavailableView("No wind history yet", systemImage: "wind",
                                   description: Text("Wind direction lives in the station's minute-by-minute readings, which are still being collected. This fills in behind you."))
                .emptyStatePanel(minHeight: 260)
        }
    }

    /// "Something is happening" when there is no fraction to show.
    ///
    /// Deliberately the same card as `waiting` — same padding, same corner, same
    /// tint — because to a reader these are one state, not two. The difference
    /// between a bar and a spinner is whether the work can say how far along it
    /// is, which is a fact about the work rather than about what it is doing.
    private func preparing(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(title).font(.callout.weight(.medium))
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.045)))
    }

    private func waiting(_ title: String, detail: String, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.callout.weight(.medium))
            ProgressView(value: min(1, max(0, fraction)))
            HStack {
                Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { samples.cancel() }.buttonStyle(.link).font(.caption)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.045)))
    }

    @ViewBuilder private func exploreSection(_ r: WeatherReport,
                                             onOpenQuery: @escaping () -> Void) -> some View {
        if let climate = archive.climatology, climate.dayCount >= 30 {
            WeatherExploreView(climate: climate, today: todayKey(r), query: $query,
                               onOpenQuery: onOpenQuery)
        } else if archive.isLoadingClimatology {
            preparing("Reading your archive", detail: "Indexing the record so it can be questioned.")
        } else {
            ContentUnavailableView("Not enough archive yet", systemImage: "magnifyingglass",
                                   description: Text("Once the station's history has filled in, you can ask it for the days when anything happened."))
                .emptyStatePanel()
        }
    }

    // MARK: What the archive knows

    /// Today's local day key, in the STATION's timezone — the archive is bucketed
    /// by the station's day, so asking it about "today" in any other zone would
    /// look up the wrong date near midnight.
    private func todayKey(_ r: WeatherReport) -> String {
        DayKey.string(for: Date(), timeZone: r.timezone ?? .current)
    }

    /// The Day-shapes surface, under History where its subject lives.
    ///
    /// `.task` here rather than at the root: it is a 29-day raw fetch, and it
    /// used to run on every cold launch for a card most of the way down the Now
    /// scroll. Opening History is the first moment anyone has asked for it.
    @ViewBuilder private var dayShapesSection: some View {
        if mornings.windows.count >= 3 {
            card(label: "Day shapes") {
                DayShapesCard(model: mornings)
            }
        } else if mornings.isLoading {
            card(label: "Day shapes") {
                ProgressView("Reading the last month of minutes…")
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        } else if let error = mornings.error {
            card(label: "Day shapes") {
                Text("Couldn't read the recent days — \(error)")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// Today's rain, at the resolution it actually fell in — the same card the
    /// day grain uses, pointed at today, which is the only reason it can be
    /// checked on a clear afternoon.
    ///
    /// The load lives in `load()` alongside the forecast rather than in the
    /// card: a card that renders nothing on a dry day can't carry a `.task`,
    /// because SwiftUI drops modifiers on a view that resolves to `EmptyView`.
    @ViewBuilder private func rainCard(_ r: WeatherReport) -> some View {
        if let rain = todaySamples.rain, rain.hasSomethingToSay {
            RainDayCard(rain: rain, climate: archive.climatology)
        } else if let error = todaySamples.error {
            // Never silent. "No rain today" and "the fetch failed" look
            // identical when the answer is an empty screen, and that cost an
            // hour the first time.
            Text("Couldn’t read today’s rain — \(error)")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    /// Today against this date's record — the headline, the rank, and the years
    /// behind them, in one card.
    ///
    /// IT WAS TWO. A `NormalComparisonStrip` inside the Right-now card said
    /// "8° warmer than usual, the 3rd warmest", and four cards further down
    /// `PastYearsStrip` drew the same date across every year. Same question,
    /// answered twice at different resolutions, with four unrelated cards
    /// between them — so neither could be read as the elaboration of the other,
    /// and the strip up top was quietly the more complete of the two.
    ///
    /// Together they are one thing: the claim, then the evidence for it.
    @ViewBuilder private func thisDateCard(_ r: WeatherReport) -> some View {
        if let climate = archive.climatology, !climate.isEmpty {
            let key = todayKey(r)
            let monthDay = DayKey.monthDay(of: key)
            let today = r.days.first
            let comparison = WeatherAlmanac.comparison(climate, day: key,
                                                       high: today?.high, low: today?.low)
            let history = climate.history(monthDay: monthDay,
                                          excludingYear: DayKey.year(of: key))
            if comparison.hasSomethingToSay || !history.isEmpty {
                card(label: "Today for \(WeatherAlmanac.dateLabel(monthDay))") {
                    VStack(alignment: .leading, spacing: 16) {
                        if comparison.hasSomethingToSay {
                            NormalComparisonStrip(comparison: comparison,
                                                  todayHigh: today?.high,
                                                  todayLow: today?.low)
                        }
                        if !history.isEmpty {
                            // Only when BOTH are present: a divider above a lone
                            // chart is a rule under nothing.
                            if comparison.hasSomethingToSay { Divider().opacity(0.5) }
                            PastYearsStrip(history: history,
                                           normal: climate.normal(monthDay: monthDay),
                                           dateLabel: WeatherAlmanac.dateLabel(monthDay),
                                           todayHigh: today?.high,
                                           todayLow: today?.low,
                                           defaultEmphasis: climate.seasonalEmphasis(monthDay: monthDay))
                        }
                    }
                }
            }
        }
    }

    // Records & streaks, Rainfall and Winter chill used to live here as three
    // loose cards. They take no period because they describe the whole archive,
    // which is now a GRAIN — so they render inside `WeatherArchiveBrowser` under
    // All time, and the wrappers that used to place them are gone rather than
    // left behind as a second way in.

    /// The one sentence about where this year sits against the usual one, and a
    /// way through to the rest. What that sentence is ABOUT — when the heat
    /// breaks here, what "the heat breaking" even means — is Rhythms' job, one
    /// question to a card.
    @ViewBuilder private func seasonsCard(_ r: WeatherReport) -> some View {
        if let climate = archive.climatology, climate.dayCount >= 90 {
            card(label: "What’s ahead") {
                SeasonTransitionsCard(climate: climate, today: todayKey(r),
                                      forecast: seasonForecast(r),
                                      onOpen: { navigate(.rhythms) })
            }
        }
    }

    /// RHYTHMS — when things usually happen here.
    ///
    /// A LIST OF ANSWERED QUESTIONS, which is the third shape this page has had
    /// and the first one that says anything on its own. It opened as the Now
    /// card's season timeline handed a longer axis; then as a year-wide chart of
    /// four measures at once. Both were true, dense and silent — a FIELD, with
    /// the finding left in it for the reader to locate. The verdict that ended
    /// the second one was the right one: "you look at it and say, what the hell
    /// is this really telling me."
    ///
    /// The fault was one chart carrying several stories, fused because the
    /// measures happened to share a date axis. They now get a card each: the
    /// question as the heading, the answer as a sentence, the parameters printed
    /// under it, and a strip whose only job is to show that the date is the
    /// middle of a window and where that sits against today.
    ///
    /// WHAT IT IS NOT is Explore. That takes conditions and returns a set of
    /// days, for someone with a hypothesis. These take nothing and return a
    /// position on the calendar, for someone who just wants to know the place.
    @ViewBuilder private func rhythmsSection(_ r: WeatherReport) -> some View {
        if let climate = archive.climatology, climate.dayCount >= 90 {
            RhythmQuestionsView(climate: climate, today: todayKey(r),
                                forecast: seasonForecast(r))
            // ALWAYS A CARD, even without its answer. This one is built from the
            // minute archive rather than the daily one, so it arrives on its own
            // schedule — and when it was simply absent until then, nothing on the
            // page said it was coming.
            card(label: "The shape of a day") {
                if let shape = samples.dayShape, shape.isMeaningful {
                    DayShapeCard(climate: shape)
                } else if samples.isPreparing || samples.foldProgress != nil || samples.fillProgress != nil {
                    rhythmPending("Reading the shape of a day out of your archive",
                                  detail: "It's built from every minute on record, which takes a moment the first time.")
                } else if samples.dayShape != nil {
                    rhythmPending(nil, detail: "Not enough minute-by-minute record yet — it needs about ten days of it. It fills in as the station's minutes are archived.")
                } else {
                    rhythmPending(nil, detail: "Waiting on the minute-by-minute archive. It builds after the daily one has caught up; this card fills in once it has.")
                }
            }
            card(label: "Winter chill") {
                WinterChillCard(climate: climate, today: todayKey(r), alwaysOpen: true)
            }
        } else if archive.isLoadingClimatology {
            preparing("Reading the years behind you", detail: "Going through the archive.")
        } else {
            ContentUnavailableView("Not enough record yet", systemImage: "repeat",
                                   description: Text("Rhythms are read out of the years behind you — when the nights let go, when the first freeze lands. It needs about a season of archive before it can say any of that."))
                .emptyStatePanel()
        }
    }

    /// A card's body before it has anything to show — said in the card, so the
    /// card itself is still there to be missed.
    private func rhythmPending(_ title: String?, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(title).font(.callout.weight(.medium))
                }
            }
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The ten-day outlook in the archive's own terms, so the season timeline can
    /// correct its normals against days we actually know about.
    ///
    /// The archive's dew point is a daily MEAN; the outlook reports the muggiest
    /// and least-muggy hour, so the midpoint is the closest honest stand-in. A day
    /// with only one of the two is left unanswered rather than made up.
    private func seasonForecast(_ r: WeatherReport) -> [SeasonForecastDay] {
        let zone = r.timezone ?? .current
        return r.days.map { day in
            let dew: Double?
            if let high = day.dewPointHigh, let low = day.dewPointLow { dew = (high + low) / 2 }
            else { dew = nil }
            return SeasonForecastDay(
                day: DayKey.string(for: Date(timeIntervalSince1970: TimeInterval(day.epoch)),
                                   timeZone: zone),
                tempMax: day.high, tempMin: day.low, dewPointMean: dew)
        }
    }

    // MARK: The local archive

    /// Two registers, deliberately. The first-run backfill is ~47 requests over a
    /// couple of minutes — a real event that gets a determinate bar naming the
    /// window being fetched, because a bar that says "Oct 2022 – Nov 2022" reads as
    /// something happening where a spinner reads as a hang. The nightly one-chunk
    /// top-up says nothing at all; nobody wants a progress bar every night for one
    /// request. A fill that ends with failed windows is the third case: it must not
    /// pretend the archive is whole, so it offers a retry that re-runs only what
    /// failed.
    @ViewBuilder private var archiveBanner: some View {
        if let p = archive.progress, p.isSubstantial, !p.isFinished {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    // An upgrade isn't missing history — every day is already
                    // there, being re-read for detail the old rollup didn't keep.
                    Text(archive.isUpgrading ? "Adding detail to your archived days"
                                             : "Building your station archive")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text("\(p.completedChunks) of \(p.totalChunks)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                ProgressView(value: p.fraction)
                HStack(spacing: 8) {
                    if let start = p.currentStart, let end = p.currentEnd {
                        Text("\(Self.window.string(from: start)) – \(Self.window.string(from: end))")
                    }
                    if p.daysArchived > 0 {
                        Text("· \(p.daysArchived) days saved")
                    }
                    Spacer()
                    Button("Stop") { archive.cancel() }
                        .buttonStyle(.link).font(.caption)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

        } else if let failure = archive.lastFailure {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(failure.chunksFailed) \(failure.chunksFailed == 1 ? "window" : "windows") of history didn’t load")
                        .font(.callout.weight(.medium))
                    Text("Everything else was saved. You can fill the gaps now or leave it — the next catch-up will try again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Retry") {
                    archive.retryFailures(token: settings.tempestToken, stationID: settings.tempestStationID)
                }
            }
            .padding(14)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// Only the FAILURE half, and that asymmetry is deliberate. The sample fill's
    /// progress already has a home — the Wind tab, which is the only thing waiting
    /// on it — and repeating it up here would put a second progress bar above every
    /// tab for a job none of them need. A gap in the record is different: it makes
    /// the climatology quietly short, and you'd never find out by looking at a rose.
    @ViewBuilder private var samplesBanner: some View {
        if let failure = samples.lastFailure, !failure.failedDays.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "wind").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(failure.failedDays.count) \(failure.failedDays.count == 1 ? "day" : "days") of minute readings didn’t load")
                        .font(.callout.weight(.medium))
                    Text("The station’s history API throttles long runs. Everything else was saved — retrying usually lands the rest.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Retry") {
                    samples.retryFailures(token: settings.tempestToken,
                                          stationID: settings.tempestStationID)
                }
            }
            .padding(14)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// Footer line: what the local record actually holds.
    @ViewBuilder private var archiveFooter: some View {
        if archive.dayCount > 0, let first = archive.earliestDay {
            Text("\(archive.dayCount.formatted()) days archived locally since \(Self.day(first))")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private static let window: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return f
    }()

    private static func day(_ key: String) -> String {
        guard let date = DayKey.date(from: key, timeZone: .current) else { return key }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    // MARK: The ten-day's grade (the Mac's header for `TenDayCard`)

    /// The ten-day's own report card, as ONE LINE above the forecast it grades.
    ///
    /// It was a separate card titled "How the forecast has done", sitting
    /// between the ten-day and the season outlook. The instinct behind that
    /// placement was right — a grade is only useful while the number it grades
    /// is still on screen — but a card is the wrong size for it: it is not a
    /// subject, it is an annotation on the subject above it, and giving it
    /// equal chrome made the Now scroll read as if the forecast's accuracy were
    /// a peer of the forecast.
    ///
    /// So the finding rides in the header and the working — day by day, bias,
    /// worst miss — is under History, one click away, where the rest of the
    /// app's self-measurement lives.
    @ViewBuilder private func forecastGrade(detail: Destination) -> some View {
        if let verdict = forecastCheck.verdict {
            HStack(spacing: 8) {
                Image(systemName: verdict.isReassuring
                      ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(verdict.isReassuring
                                     ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                    .font(.caption)
                Text(verdict.headline)
                    .font(.caption.weight(.medium))
                Spacer(minLength: 0)
                Button("Detail") { navigate(detail) }
                    .buttonStyle(.link).font(.caption)
            }
        } else if forecastCheck.watchingSince != nil {
            // The waiting state still has to speak. A log quietly filling for a
            // week with nothing on screen is indistinguishable from one that is
            // broken, and the first thing you want to know after starting to
            // keep score is that score-keeping started.
            HStack(spacing: 8) {
                Image(systemName: "clock").foregroundStyle(.tertiary).font(.caption)
                Text("Keeping score — not enough finished days to grade yet")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button("Detail") { navigate(detail) }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }

    /// The full working, under History.
    @ViewBuilder private func forecastCheckSection(_ r: WeatherReport) -> some View {
        if forecastCheck.verdict != nil || forecastCheck.watchingSince != nil {
            card(label: "How the forecast has done") {
                ForecastCheckCard(model: forecastCheck, timezone: r.timezone ?? .current)
            }
        }
    }

    /// The shared container, kept under its old name so the dozen History,
    /// Rain and Wind call sites above read as they did. See `StationCard`.
    private func card<Content: View>(label: String, @ViewBuilder _ content: () -> Content) -> some View {
        StationCard(label: label, content: content)
    }

    // MARK: Time formatting (station-local)

    private func monthDay(_ epoch: Int, _ r: WeatherReport) -> String {
        let f = DateFormatter()
        f.timeZone = r.timezone
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM d"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    // MARK: Icon mapping (Tempest icon strings → SF Symbols)

    static func symbol(_ icon: String) -> String { WeatherSymbol.name(icon) }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
