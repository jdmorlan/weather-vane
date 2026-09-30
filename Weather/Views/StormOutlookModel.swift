//
//  StormOutlookModel.swift  (Weather, VaneTV)
//
//  SPC's and WPC's outlooks for the next three days, read at home — what the
//  Forecast page on every screen draws its storm and flood answers from.
//
//  Compiled into the TV from here rather than copied; see project.yml. It has
//  no platform code.
//

import SwiftUI
import WeatherKit

/// SPC's and WPC's outlooks for the next three days, read at home.
@MainActor
final class StormOutlookModel: ObservableObject {
    @Published private(set) var categorical: [Outlook] = []
    @Published private(set) var flood: [Outlook] = []
    @Published private(set) var probabilities: [SevereProbability] = []
    @Published private(set) var failure: String?
    @Published private(set) var fetched: Date?
    @Published private(set) var isLoading = false

    private let client = OutlookClient(contact: "vane.weather.app")
    /// SPC reissues up to five times a day; ten minutes is already eager.
    private static let refreshEvery: TimeInterval = 10 * 60

    func load(force: Bool = false) async {
        if !force, let fetched, Date().timeIntervalSince(fetched) < Self.refreshEvery { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let client = self.client
        // Thirteen small files, all at once. Each is a few kilobytes; asked in
        // turn they'd take longer than the page takes to be read.
        async let cat = Self.gather([1, 2, 3]) { try await client.outlook(.severeStorms, period: $0) }
        async let ero = Self.gather([1, 2, 3]) { try await client.outlook(.excessiveRain, period: $0) }
        let jobs = SevereHazard.allCases.flatMap { h in h.days.map { (h, $0) } }
        async let probs = Self.gather(jobs) { try await client.severeProbability($0.0, day: $0.1) }
        let (c, e, p) = await (cat, ero, probs)

        // Partial is fine — a hail file that failed shouldn't blank the
        // category that loaded. Only nothing-at-all is a failure, and then the
        // last good copy stays on screen.
        if c.values.isEmpty && e.values.isEmpty && p.values.isEmpty {
            failure = c.error ?? e.error ?? p.error ?? "The outlooks didn't load."
            return
        }
        categorical = c.values
        flood = e.values
        probabilities = p.values
        failure = nil
        fetched = Date()
    }

    func keepCurrent() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: .seconds(60))
        }
    }

    private static func gather<Input: Sendable, Output: Sendable>(
        _ inputs: [Input], _ fetch: @escaping @Sendable (Input) async throws -> Output
    ) async -> (values: [Output], error: String?) {
        await withTaskGroup(of: Result<Output, Error>.self) { group in
            for input in inputs {
                group.addTask {
                    do { return .success(try await fetch(input)) } catch { return .failure(error) }
                }
            }
            var values: [Output] = []
            var error: String?
            for await result in group {
                switch result {
                case .success(let v): values.append(v)
                case .failure(let e):
                    error = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
                }
            }
            return (values, error)
        }
    }

    /// One day's risk at home, or nil when nothing covering that day has
    /// loaded — which is not the same as a quiet day, and must not read as one.
    func risk(day: String, home: GeoPoint, timeZone: TimeZone) -> StormRisk? {
        func covers(_ until: Date?) -> Bool { OutlookDay.key(validUntil: until, timeZone: timeZone) == day }
        let cat = categorical.first { covers($0.validUntil) }
        let ero = flood.first { covers($0.validUntil) }
        let probs = probabilities.filter { covers($0.validUntil) }
        guard cat != nil || ero != nil || !probs.isEmpty else { return nil }
        return StormRisk(category: cat?.category(at: home),
                         hazards: probs.map { .init(hazard: $0.hazard, probability: $0.probability(at: home)) },
                         flood: ero?.category(at: home))
    }
}

