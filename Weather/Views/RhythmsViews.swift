//
//  RhythmsViews.swift
//
//  Rhythms: the seasons here, one card each — when it's hot, muggy, when the
//  nights are warm or cool, when it can freeze.
//
//  THESE ARE EXPLORE'S QUESTIONS, ASKED FOR YOU. Rhythms was its own machine:
//  each question was a crossing of a smoothed normal ("the date a week of
//  afternoons drops below 90°"), answered in a sentence, with a strip as
//  evidence. True, and too many words for what a picture shows at a glance. A
//  season is better told by the same chart Explore draws — how often it happens
//  on each date, the pair of dates where it's the norm, the pair where it's
//  possible at all, and this season so far — so that's what each card is, and
//  "Open in Explore" takes the same question further: its readings, its records,
//  what those days were like.
//
//  "SETTLED IN" now means the curve is above half: more days like this than not.
//  The gap between the two pairs of dates is the false start and the false fall —
//  one cool morning in September and then the 90s again.
//

import SwiftUI
import WeatherKit

struct RhythmsView: View {
    let climate: Climatology
    let today: String
    /// Open one day in History.
    var openDay: (String) -> Void = { _ in }
    /// Take a question to Explore.
    var explore: (DayQuery) -> Void = { _ in }

    @State private var shapes: [String: WhenInTheYear] = [:]
    @State private var loaded = false

    private var seasons: [ExploreQuestion] { ExploreQuestion.all.filter { $0.group == .seasons } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(seasons) { season in
                if let shape = shapes[season.id], !shape.matchedDays.isEmpty {
                    WhenInTheYearCard(shape: shape, question: season, query: season.query,
                                      recordEnd: climate.latestDay ?? today, openDay: openDay) {
                        Button("Open in Explore") { explore(season.query) }
                            .buttonStyle(.link).font(.caption)
                    }
                } else {
                    placeholder(season)
                }
            }
        }
        // Once per archive, not per forecast refresh — none of this reads the forecast.
        .task(id: "\(climate.dayCount)|\(climate.latestDay ?? "")") {
            let climate = climate, seasons = seasons
            let built = await Task.detached(priority: .userInitiated) {
                Dictionary(uniqueKeysWithValues: seasons.compactMap { season in
                    climate.whenInTheYear(season.query).map { (season.id, $0) }
                })
            }.value
            shapes = built
            loaded = true
        }
    }

    /// Every season keeps its place, answered or not.
    private func placeholder(_ season: ExploreQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(season.asks).font(.system(size: 17, weight: .semibold))
            if loaded {
                Text("Not on record here yet: no \(season.query.conditions.allSatisfy { $0.measure == .low } ? "night" : "day") has \(season.matched).")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading the years behind you").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.07)))
    }
}
