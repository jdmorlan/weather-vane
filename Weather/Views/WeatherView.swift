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
        guard !token.isEmpty, stationID != 0 else { return }
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

struct WeatherView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = WeatherModel()
    @StateObject private var archive = WeatherArchiveModel()
    /// The station's MINUTES, and the wind climatology derived from them. Its own
    /// model rather than a corner of `archive` because the two fill on different
    /// clocks and at wildly different costs — a day of samples is 1,400 readings
    /// against the daily archive's one row — and because this one owns a cache
    /// that has to be folded after a fetch, which the daily archive has no notion of.
    @StateObject private var samples = WeatherSamplesModel()
    @StateObject private var mornings = RecentWindowsModel()
    /// Today's minutes. Its own model for the same reason `mornings` has one: the
    /// archive keeps a day reduced to its extremes and means, and everything here
    /// is a question about the shape INSIDE the day — when it rained, and what
    /// the morning was actually like. Both read the same fetch.
    @StateObject private var todaySamples = DayObservationsModel()
    /// NWS watches and warnings for the home point. Its own model because it
    /// polls on its own clock — a warning issued while you're reading the ten-day
    /// has to arrive without you asking.
    @StateObject private var hazards = WeatherHazardModel()
    /// How the ten-day card has been doing. Its own model because it reads two
    /// stores and neither of them is the fetch: the forecast log this view
    /// writes on every refresh, and the daily archive `archive` is filling in
    /// behind it.
    @StateObject private var forecastCheck = ForecastCheckModel()
    /// The 500 mb pattern. Its own model because it has nothing to do with the
    /// station: a different source (the GFS), a different clock (four runs a
    /// day), and it works with no Tempest configured at all.
    @StateObject private var upperAir = UpperAirModel()
    @State private var tab: Tab = .now
    /// Held here rather than inside Explore so another card can hand one over.
    /// Opens on THIS year: "how often has it rained lately" is the question you
    /// arrive with, and all-time is a deliberate widening from there.
    @State private var query: DayQuery = {
        var seeded = DayQuery.presets[0]
        seeded.years = .year(Calendar.current.component(.year, from: Date()))
        return seeded
    }()

    var body: some View {
        Group {
            if !settings.hasWeatherStation {
                notConfigured
            } else if let report = model.report {
                dashboard(report)
            } else if model.isLoading {
                ProgressView("Reading your station…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.error {
                ContentUnavailableView("Couldn’t load weather", systemImage: "cloud.bolt",
                                       description: Text(error))
            } else {
                Color.clear
            }
        }
        .navigationTitle("Weather")
        .toolbar {
            ToolbarItem {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.isLoading || upperAir.isLoading)
                    .help("Refresh")
            }
        }
        // NOTE — Almanac wired three more modifiers in here: a `SurfaceRouter` that
        // let a conversation hand this view a `DayQuery` to adopt, and a matching
        // publish of whatever query is on screen so an ask could say "refine that".
        // That is the LLM harness, not weather, so it stayed behind. `query` still
        // lives at this level, which is the whole seam — anything that wants to
        // drive Explore from outside has one property to set.
        .task {
            if model.report == nil { await load() }
            // The cache first and separately: it's a small file read, it paints the
            // Wind tab immediately, and it must not wait behind a network catch-up
            // that on a cold archive takes the better part of an hour.
            samples.loadCached()
            catchUpArchives()
            await mornings.load(token: settings.tempestToken, stationID: settings.tempestStationID)
        }
        // A separate task, because it never finishes: it polls for as long as
        // Weather is on screen, and SwiftUI cancels it when the view goes away.
        .task { await hazards.poll(settings: settings) }
        // A kept-alive pane outlives midnight, and appearing is no longer a
        // proxy for "a new day". Without this the archive stopped at the day the
        // app was launched, and yesterday could never be measured or graded.
        .task {
            for await _ in NotificationCenter.default.notifications(named: .NSCalendarDayChanged) {
                catchUpArchives()
            }
        }
        // Re-graded when the archive gains a day — yesterday can only be scored
        // once the catch-up has measured it — and when a refresh files a new
        // claim, which is what makes the card appear on the very first morning
        // instead of after a relaunch.
        .task(id: checkKey) {
            await forecastCheck.load(store: archive.store,
                                     timeZone: model.report?.timezone ?? .current,
                                     key: checkKey)
        }
        // Only while the pattern is on screen, and re-run when home moves — a run
        // fetched for another point holds the wrong "height here". `load` itself
        // decides whether a newer GFS run can exist yet, so reopening the tab costs
        // a file read, not a fetch.
        .task(id: patternKey) {
            guard patternVisible else { return }
            await upperAir.load(home: homePoint)
        }
    }

    private var patternVisible: Bool { tab == .pattern || !settings.hasWeatherStation }

    private var homePoint: GeoPoint? {
        settings.hasHome ? GeoPoint(latitude: settings.homeLat, longitude: settings.homeLon) : nil
    }

    private var patternKey: String {
        "\(patternVisible)|\(settings.homeLat)|\(settings.homeLon)"
    }

    private var patternSection: some View {
        UpperAirPatternView(model: upperAir, home: homePoint) {
            Task { await upperAir.load(home: homePoint, force: true) }
        }
    }

    /// What the forecast check depends on: the last measured day, the station's
    /// zone, and the moment of the newest capture.
    private var checkKey: String {
        let tz = model.report?.timezone?.identifier ?? "—"
        let updated = model.lastUpdated.map { String(Int($0.timeIntervalSince1970)) } ?? "—"
        return "\(archive.latestDay ?? "—")|\(tz)|\(updated)"
    }

    /// Bring the daily archive and the sample store up to yesterday. Runs
    /// alongside the live fetch rather than gating it: the forecast is what you
    /// opened this screen for, and the archive filling in behind it is background
    /// work. Both models ignore a call while one is already running.
    private func catchUpArchives() {
        archive.catchUp(token: settings.tempestToken, stationID: settings.tempestStationID)
        samples.catchUp(token: settings.tempestToken, stationID: settings.tempestStationID,
                        daily: archive.store)
    }

    private func load() async {
        // An explicit refresh on the pattern asks Open-Meteo whether a newer run
        // has landed, even inside the window where one normally couldn't.
        if patternVisible { await upperAir.load(home: homePoint, force: true) }
        await model.refresh(token: settings.tempestToken, stationID: settings.tempestStationID)
        // The refresh button means "tell me what's true now", and what's active
        // over the acre is part of that — waiting out the poll interval after an
        // explicit ask is the wrong answer.
        await hazards.refresh(settings: settings)
        // And the finished days behind today — a no-op when the archive already
        // holds yesterday.
        catchUpArchives()

        // Today's minutes. Re-read on every refresh, because while it's raining
        // the card IS the live end of an open spell — but no more often than
        // every five minutes, which is finer than the answer can change.
        if let r = model.report {
            let bucket = Int(Date().timeIntervalSince1970 / 300)
            await todaySamples.load(day: todayKey(r), key: "\(todayKey(r))|\(bucket)",
                                 token: settings.tempestToken,
                                 stationID: settings.tempestStationID,
                                 timeZone: r.timezone ?? .current)
        }
    }

    /// No station, but the upper-air pattern needs none — so it's shown rather
    /// than hidden behind a setup screen.
    private var notConfigured: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Connect your Tempest station", systemImage: "cloud.sun").font(.headline)
                    Text("Add your WeatherFlow API token and station ID in Settings → Weather to see your forecast here. The upper-air pattern below doesn’t need a station.")
                        .foregroundStyle(.secondary)
                }
                patternSection
            }
            .padding(24)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Dashboard

    /// Two registers, and they want different things from the screen.
    ///
    /// NOW is anchored to a moment: what it's like, what today does next, what
    /// the week holds. HISTORY is anchored to a STRETCH — a month, a season, a
    /// range you picked — and everything under it answers for that stretch.
    /// They were one scroll of ten cards, which meant the archive cards sat
    /// below the forecast ignoring each other, and there was nowhere to put a
    /// period selector that could plausibly govern anything.
    /// EXPLORE is the third register: not a moment and not a stretch, but a
    /// QUESTION — "show me the days when…" — answered over the whole record.
    enum Tab: String, CaseIterable, Identifiable {
        case now = "Now"
        case history = "History"
        // WIND is a fourth register and not a slice of History, which is organised
        // by PERIOD — a month, a season, all-time. Every question about the wind is
        // already all-time (which way does it usually come from) or all-time sliced
        // by month (does that turn with the season), so a period selector would have
        // nothing to govern. It's the same reasoning that kept Records and Rainfall
        // out of the period section, one step further along.
        case wind = "Wind"
        case explore = "Explore"
        // PATTERN is the upper air: not this acre's weather but the wave that
        // steers it, from a model run rather than the station.
        case pattern = "Pattern"
        var id: String { rawValue }
    }

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
                // ABOVE the tab picker, and above the station's own lightning
                // alerts: a tornado warning outranks everything else on the
                // screen, including whichever tab you came here for.
                HazardBanner(watch: hazards.watch)
                alertsBanner(r)
                archiveBanner
                samplesBanner
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // `alignment: .leading` is doing real work: the control's
                // intrinsic width is under 240, and a bare `maxWidth` centres it
                // in the leftover space — which parked it against the cards'
                // INNER padding instead of their edge.
                .frame(maxWidth: 320, alignment: .leading)

                switch tab {
                // The split is by ANCHOR, not by where the data came from. Two
                // of these cards read the archive and still belong here: "this
                // day in past years" is context for the number at the top of
                // the screen, and "what's ahead" extends the ten-day forecast
                // out to a season. Both answer a question about TODAY, which is
                // what this tab is for — a period selector would have nothing
                // to say to either of them.
                case .now:
                    // Built once and handed down. Two cards read today's shape —
                    // the extremes at the top and the strip below — and reducing
                    // 1,400 samples twice per render is the kind of cost that
                    // only shows up as a scroll that isn't smooth.
                    let strip = todayStrip(r)
                    nowCard(r, strip)   // right now: conditions, the numbers, comfort, daylight
                    // What the rain is DOING, on a day that saw any. Renders
                    // nothing otherwise, which is why it can sit this high: on a
                    // wet day it's the most important thing on the screen, and on
                    // a dry one it isn't there at all.
                    rainCard(r)
                    radarCard           // what's coming, and any warning drawn over it
                    // TODAY, midnight to midnight, at the resolution it actually
                    // happens in. The sentence and the heads-up lines lead; the
                    // hours carry the numbers; the day's parts are bands over the
                    // same strip.
                    hourlyCard(r, strip)
                    if !r.days.isEmpty { tenDayCard(r) }
                    forecastCheckCard(r)
                    seasonsCard(r)      // past ten days: what the season does next
                    morningsCard(r)     // raw samples: the last ten mornings, overlaid
                    pastYearsCard(r)    // the archive: this date, every year
                // ONE control, and every card is a lens under it. Records,
                // Rainfall and Winter chill used to sit loose below the period
                // section; they take no period because they ARE the whole
                // archive, which is the All-time grain — so they moved inside
                // rather than staying as three cards with no door of their own.
                case .history:
                    periodSection(r)
                case .wind:
                    windSection
                case .pattern:
                    patternSection
                case .explore:
                    exploreSection(r) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            scroll.scrollTo(WeatherExploreView.builderAnchor, anchor: .top)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    if let updated = model.lastUpdated {
                        Text("Updated \(updated.formatted(date: .omitted, time: .shortened)) · Tempest")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    archiveFooter
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
            }
        }
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
                tab = .explore
            }
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
        } else {
            // Direction is the one measure the DAILY archive never kept — a mean of
            // a circular quantity is meaningless — so this tab cannot fall back on
            // it the way the others can. Saying so is better than an empty rose.
            ContentUnavailableView("No wind history yet", systemImage: "wind",
                                   description: Text("Wind direction lives in the station's minute-by-minute readings, which are still being collected. This fills in behind you."))
                .frame(height: 260)
        }
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
        } else {
            ContentUnavailableView("Not enough archive yet", systemImage: "magnifyingglass",
                                   description: Text("Once the station's history has filled in, you can ask it for the days when anything happened."))
        }
    }

    // MARK: What the archive knows

    /// Today's local day key, in the STATION's timezone — the archive is bucketed
    /// by the station's day, so asking it about "today" in any other zone would
    /// look up the wrong date near midnight.
    private func todayKey(_ r: WeatherReport) -> String {
        DayKey.string(for: Date(), timeZone: r.timezone ?? .current)
    }

    /// Today against the normal for the date, inside the Right-now card. Renders
    /// nothing at all until there's enough record to say something true — a young
    /// archive stays quiet rather than quoting a "normal" built from one year.
    @ViewBuilder private func normalComparison(_ r: WeatherReport) -> some View {
        if let climate = archive.climatology, !climate.isEmpty {
            let today = r.days.first
            let comparison = WeatherAlmanac.comparison(climate, day: todayKey(r),
                                                       high: today?.high, low: today?.low)
            if comparison.hasSomethingToSay {
                Divider()
                NormalComparisonStrip(comparison: comparison,
                                      todayHigh: today?.high, todayLow: today?.low)
            }
        }
    }

    /// The last ten mornings laid over each other. Not from the archive — the
    /// archive keeps a day's extremes, and this is a question about the shape
    /// inside a day, so it re-fetches the raw half-hourly samples.
    ///
    /// Held back until there's a subject day with neighbours to compare it to; a
    /// single morning drawn alone answers nothing.
    @ViewBuilder private func morningsCard(_ r: WeatherReport) -> some View {
        if let yesterday = DayKey.previous(todayKey(r)), mornings.windows.count >= 3 {
            card(label: "Recent mornings") {
                RecentMorningsCard(windows: mornings.windows,
                                   window: mornings.window,
                                   subject: yesterday)
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

    @ViewBuilder private func pastYearsCard(_ r: WeatherReport) -> some View {
        if let climate = archive.climatology {
            let key = todayKey(r)
            let monthDay = DayKey.monthDay(of: key)
            let history = climate.history(monthDay: monthDay, excludingYear: DayKey.year(of: key))
            if !history.isEmpty {
                card(label: "This day in past years") {
                    PastYearsStrip(history: history,
                                   normal: climate.normal(monthDay: monthDay),
                                   dateLabel: WeatherAlmanac.dateLabel(monthDay),
                                   todayHigh: r.days.first?.high,
                                   todayLow: r.days.first?.low,
                                   defaultEmphasis: climate.seasonalEmphasis(monthDay: monthDay))
                }
            }
        }
    }

    // Records & streaks, Rainfall and Winter chill used to live here as three
    // loose cards. They take no period because they describe the whole archive,
    // which is now a GRAIN — so they render inside `WeatherArchiveBrowser` under
    // All time, and the wrappers that used to place them are gone rather than
    // left behind as a second way in.

    @ViewBuilder private func seasonsCard(_ r: WeatherReport) -> some View {
        if let climate = archive.climatology, climate.dayCount >= 90 {
            card(label: "What’s ahead") {
                SeasonTransitionsCard(climate: climate, today: todayKey(r),
                                      forecast: seasonForecast(r))
            }
        }
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

    // MARK: Radar

    /// Needs a home location rather than a station: the station tells you what is
    /// happening ON the acre, and radar's whole job is what hasn't got here yet.
    /// Without a home point there is nothing to centre on, and a map of somewhere
    /// arbitrary is worse than no map.
    @ViewBuilder private var radarCard: some View {
        if let home = settings.homeCoordinate {
            card(label: "Radar") {
                // Only the hazards that HAVE an outline get drawn. A watch covers
                // whole counties, and tracing its boundary on a 30-mile view would
                // draw a line across the picture that means nothing about where
                // the storm is.
                RadarCard(home: home, hazards: hazards.watch.state().drawable)
            }
        } else {
            card(label: "Radar") {
                Text("Set your home location in Settings to centre the radar on it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Alerts (only when something needs attention)

    @ViewBuilder private func alertsBanner(_ r: WeatherReport) -> some View {
        if !r.alerts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(r.alerts, id: \.self) { text in
                    Text(text)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Right now — conditions, the numbers behind them, and where they sit

    /// One card for "what is it like out there this second": the headline sentence, the
    /// reading, the stat tiles, the comfort gauges that place those readings on a scale,
    /// and the daylight arc. These were four cards that all answered the same question,
    /// and they repeated each other (sunrise twice, dew point three times).
    private func nowCard(_ r: WeatherReport, _ strip: DayStrip) -> some View {
        let today = r.days.first
        return card(label: "Right now") {
            HStack(alignment: .top, spacing: 26) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 16) {
                        if let t = r.temperature {
                            Text("\(Int(t.rounded()))°")
                                .font(.system(size: 58, weight: .thin, design: .rounded))
                                .lineLimit(1)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(r.conditions).font(.title3.weight(.medium))
                            // No "feels like" here: the gauge below states it AND places
                            // it on a scale, which is strictly more than this line said.
                            todayHiLo(r, strip).font(.headline)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: Self.symbol(r.icon))
                            .font(.system(size: 38)).symbolRenderingMode(.multicolor)
                            .foregroundStyle(.tint)
                    }
                    // The interpreter's one-line answer, which the dashboard never showed.
                    Text(r.headline).font(.callout.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    comfortGauges(r)
                    pressureRow(r)
                    normalComparison(r)
                }
                .frame(maxWidth: .infinity)

                // Two instruments about the same thing — where things are around
                // you — so they share the column.
                VStack(alignment: .leading, spacing: 16) {
                    if today?.sunrise != nil, today?.sunset != nil { daylight(r) }
                    if r.windDirection != nil {
                        if today?.sunrise != nil { Divider() }
                        windFacing(r)
                    }
                }
                .frame(width: 300)
            }
        }
    }

    /// Pressure was the one tile whose number meant nothing to anybody: 30.10 inHg has
    /// no felt referent, and the band it moves in is so narrow that the digits look
    /// frozen. The fix isn't a better label, it's a REFERENT — the station's own record,
    /// so the reading becomes "lower than all but a handful of days here". See
    /// `PressureInstrument`, and `PressureBand` for where the band comes from.
    @ViewBuilder private func pressureRow(_ r: WeatherReport) -> some View {
        let precip = r.precipToday ?? 0
        if r.pressure.current != nil || precip > 0 {
            HStack(alignment: .top, spacing: 22) {
                if r.pressure.current != nil {
                    PressureInstrument(current: r.pressure.current,
                                       trend: r.pressure.trend,
                                       delta3h: r.pressure.delta3h,
                                       band: archive.climatology?.pressureBand(),
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
    @ViewBuilder private func windFacing(_ r: WeatherReport) -> some View {
        if let from = r.windDirection {
            WindDial(from: from, speed: r.windAvg, gust: r.windGust, facing: settings.facing,
                     onFace: { settings.homeFacing = $0 })
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Daylight (lives inside the Right-now card — sunrise/sunset used to print twice)

    @ViewBuilder private func daylight(_ r: WeatherReport) -> some View {
        if let today = r.days.first {
            let tomorrowSunrise = r.days.count > 1 ? date(r.days[1].sunrise) : nil
            DaylightArc(sunrise: date(today.sunrise),
                        sunset: date(today.sunset),
                        nextSunrise: tomorrowSunrise,
                        now: Date(),
                        time: { d in d.map { fullTime($0, r) } ?? "—" })
        }
    }

    // MARK: Comfort gauges — where the current readings sit, and what the scale means

    @ViewBuilder private func comfortGauges(_ r: WeatherReport) -> some View {
        if r.comfort.dewPoint != nil || r.feelsLike != nil {
            HStack(alignment: .top, spacing: 22) {
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

    private func headsUpRows(_ r: WeatherReport) -> [(String, String)] {
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

    // MARK: Today — the whole day, at the resolution it happens in

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
    @ViewBuilder private func hourlyCard(_ r: WeatherReport, _ strip: DayStrip) -> some View {
        let rows = headsUpRows(r)
        let sentence = todaySentence(r)
        // WITH NOTHING MEASURED THERE IS NO TODAY-SO-FAR TO DRAW, and a
        // midnight-anchored frame would spend its whole left half on blank
        // columns — a worse card than the one this replaced. So a failed or
        // unfinished fetch falls back to the forward-looking strip rather than
        // rendering an empty morning as if the morning hadn't happened.
        let hours = strip.hasObservations ? strip.hours : r.hours
        if !hours.isEmpty || !rows.isEmpty || sentence != nil {
            card(label: strip.hasObservations ? "Today" : "Hourly") {
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

    /// Today as one strip: the station's own minutes up to now, the forecast after.
    private func todayStrip(_ r: WeatherReport) -> DayStrip {
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
        return DayStrip.build(day: todayKey(r),
                              samples: todaySamples.samples,
                              forecast: r.hours,
                              timeZone: tz,
                              sunriseHour: sunrise,
                              sunsetHour: sunset)
    }

    /// How today feels as one line. Empty when the headline already said it — the
    /// screen shouldn't state the same weather twice.
    private func todaySentence(_ r: WeatherReport) -> String? {
        guard let today = r.days.first else { return nil }
        if !today.shape.isEmpty { return today.shape == r.headline ? nil : today.shape }
        if let dew = today.dewPoint {
            return "Humidity holds steady — dew point around \(Int(dew.rounded()))°, \(WeatherInterpreter.dewComfortTag(dew).lowercased()) start to finish."
        }
        return nil
    }

    // MARK: 10-day

    /// Ten day boxes made you difference ten pairs of numbers by eye to answer the
    /// only questions a week-out forecast gets asked — when does it break, when does
    /// the muggy stretch end, which day does the rain land on. The grid is gone; the
    /// week is one figure. The words that the boxes couldn't hold lead, as in Hourly.
    private func tenDayCard(_ r: WeatherReport) -> some View {
        card(label: "10-day forecast") {
            VStack(alignment: .leading, spacing: 14) {
                if let week = r.weekComfort {
                    Text(week).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                OutlookRibbon(days: r.days, timezone: r.timezone)
                HStack(spacing: 10) {
                    legendSwatch(.orange, "high")
                    legendSwatch(.blue.opacity(0.75), "low")
                    if r.days.contains(where: { !$0.parts.isEmpty }) {
                        Text("humidity: night · morning · afternoon · evening")
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    Text("hover a day for the rest").foregroundStyle(.tertiary)
                }
                .font(.caption2)
            }
        }
    }

    /// Directly under the ten-day, and wrapped in the same card chrome — this is
    /// a note about that card, not a card of its own subject. Renders nothing
    /// until the log holds something, so it appears the first morning after this
    /// shipped rather than announcing an empty feature.
    @ViewBuilder private func forecastCheckCard(_ r: WeatherReport) -> some View {
        if forecastCheck.verdict != nil || forecastCheck.watchingSince != nil {
            card(label: "How the forecast has done") {
                ForecastCheckCard(model: forecastCheck, timezone: r.timezone ?? .current)
            }
        }
    }

    private func legendSwatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 10, height: 2.5)
            Text(label).foregroundStyle(.secondary)
        }
    }

    // MARK: Building blocks

    @ViewBuilder private func hiLo(_ high: Double?, _ low: Double?) -> some View {
        HStack(spacing: 6) {
            if let high { Text("\(Int(high.rounded()))°").fontWeight(.semibold) }
            if high != nil && low != nil { Text("/").foregroundStyle(.tertiary) }
            if let low { Text("\(Int(low.rounded()))°").foregroundStyle(.secondary) }
        }
    }

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
    @ViewBuilder private func todayHiLo(_ r: WeatherReport, _ strip: DayStrip) -> some View {
        let high = extremeLine(strip.high, forecast: r.days.first?.high, isHigh: true, r)
        let low = extremeLine(strip.low, forecast: r.days.first?.low, isHigh: false, r)
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

    private func extremeLine(_ observed: ObservedExtreme?, forecast: Double?,
                             isHigh: Bool, _ r: WeatherReport) -> (text: String, measured: Bool)? {
        // The measurement wins only where it has actually gone past the forecast.
        // Short of that the day still has room to get there, so the forecast is
        // the more honest number and it says so.
        if let observed, forecast.map({ isHigh ? observed.value >= $0 : observed.value <= $0 }) ?? true {
            return ("\(Int(observed.value.rounded()))° at \(fullTime(observed.date, r))", true)
        }
        if let forecast { return ("\(Int(forecast.rounded()))° expected", false) }
        return observed.map { ("\(Int($0.value.rounded()))°", true) }
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

    // MARK: Time formatting (station-local)

    private func date(_ epoch: Int?) -> Date? {
        epoch.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    private func fullTime(_ d: Date, _ r: WeatherReport) -> String {
        let f = DateFormatter()
        f.timeZone = r.timezone
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "h:mm a"
        return f.string(from: d)
    }

    private func monthDay(_ epoch: Int, _ r: WeatherReport) -> String {
        let f = DateFormatter()
        f.timeZone = r.timezone
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM d"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    // MARK: Icon mapping (Tempest icon strings → SF Symbols)

    static func symbol(_ icon: String) -> String {
        switch icon {
        case "clear-day": return "sun.max.fill"
        case "clear-night": return "moon.stars.fill"
        case "partly-cloudy-day", "possibly-cloudy-day": return "cloud.sun.fill"
        case "partly-cloudy-night", "possibly-cloudy-night": return "cloud.moon.fill"
        case "cloudy": return "cloud.fill"
        case "rainy", "possibly-rainy-day", "possibly-rainy-night": return "cloud.rain.fill"
        case "sleet", "possibly-sleet-day", "possibly-sleet-night": return "cloud.sleet.fill"
        case "snow", "possibly-snow-day", "possibly-snow-night": return "cloud.snow.fill"
        case "thunderstorm", "possibly-thunderstorm-day", "possibly-thunderstorm-night": return "cloud.bolt.rain.fill"
        case "windy": return "wind"
        case "foggy": return "cloud.fog.fill"
        default: return "cloud.fill"
        }
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
