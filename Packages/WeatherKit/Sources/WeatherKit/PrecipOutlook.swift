//
//  PrecipOutlook.swift  (WeatherKit)
//
//  WHAT ELEVEN MODELS SAY ABOUT THE NEXT EIGHTEEN HOURS, DISAGREEMENT LEFT IN.
//
//  WHY THIS EXISTS AT ALL, AND THE AFTERNOON THAT CAUSED IT. On 20 September a
//  solid line of storms ran from Brady through San Saba to Hamilton, plainly on
//  the radar for hours. Two consecutive HRRR runs — including the 19Z one, which
//  initialised with that line already in its own radar assimilation — put NOTHING
//  over central Texas. Meanwhile, at the same point and the same moment:
//
//      model      20Z   21Z   22Z   23Z   00Z   01Z      (mm/h)
//      NBM        0.3   0.3   0.8   4.1   2.8   1.3
//      ECMWF      0.0   0.0   1.6   1.6   1.6   2.0
//      ICON       0.1   0.1   0.0   0.0   0.0   0.0
//      HRRR       0.0   0.0   0.0   0.0   0.0   0.0
//      GFS        0.0   0.0   0.0   0.0   0.0   0.0
//
//  A single-model layer would have shown that afternoon as dry, confidently and in
//  colour. The useful thing was never one model's answer; it was that two of them —
//  including the blend the official forecast is actually built from — had a real
//  event the others missed.
//
//  SO THE SPREAD IS THE PRODUCT, NOT AN ERROR BAR ON IT. Averaging them into one
//  number would have produced a quiet "a bit of rain", which is the one answer
//  none of the models gave and the worst of both readings. What a person actually
//  needs to decide whether to move the cattle is: how many say yes, when, how
//  much, and who is the odd one out.
//
//  NOT A MAP LAYER, AND THAT IS DELIBERATE. These are hourly ACCUMULATIONS at a
//  point, not reflectivity. Drawn as a raster they would look like radar and mean
//  something else entirely — see `Nowcast.swift` for the loop's own honesty rule.
//

import Foundation

// MARK: - Which models

/// THE PANEL, IN A FIXED ORDER THAT NEVER MOVES WITH THE DATA.
///
/// Grouped by `Family`, because eleven rows of equal weight would be a worse card
/// than five: the question "how many say yes" only means something if you can see
/// WHO. Eight coarse globals outvoting the one convection-resolving model is not
/// the same situation as the reverse, and a flat list hides which one happened.
///
/// WHAT IS DELIBERATELY NOT HERE, AND THE RULE BEHIND IT. Models are left out for
/// being INVALID at this longitude, never for being unskilful:
///
///  · KNMI and DMI return BYTE-IDENTICAL series over Texas — both are European
///    regional models outside their domain, served from the same underlying data.
///    Carrying both would count one forecast twice, and an inflated denominator
///    is the exact false confidence this card exists to prevent.
///  · BOM ACCESS and GraphCast answer with nothing at all for CONUS.
///
/// CMA is the weakest operational global on the list and it stays, because
/// dropping a valid forecast for disagreeing with the others is editing the vote.
/// Every row is named; the reader does the weighing.
public enum PrecipModel: String, CaseIterable, Identifiable, Sendable {
    case nbm
    case hrrr
    case ecmwf, ukmo, gfs, icon, gem, arpege, jma, cma
    case aifs

    public var id: String { rawValue }

    /// What KIND of forecast this is, which is what decides whether two rows
    /// agreeing means much.
    public enum Family: String, CaseIterable, Sendable {
        /// The operational blend the official forecast is built from.
        case blend
        /// Convection-resolving, rerun hourly, assimilates radar.
        case shortRange
        /// Global, coarse, with convection parameterised rather than resolved.
        case global
        /// Machine-learned rather than solved from the physics.
        case learned

        public var heading: String {
            switch self {
            case .blend:      return "Blend"
            case .shortRange: return "Short range"
            case .global:     return "Globals"
            case .learned:    return "AI"
            }
        }
    }

    public var family: Family {
        switch self {
        case .nbm:  return .blend
        case .hrrr: return .shortRange
        case .aifs: return .learned
        default:    return .global
        }
    }

    /// Open-Meteo's name for it.
    var apiName: String {
        switch self {
        case .nbm:    return "ncep_nbm_conus"
        case .hrrr:   return "ncep_hrrr_conus"
        case .ecmwf:  return "ecmwf_ifs025"
        case .ukmo:   return "ukmo_seamless"
        case .gfs:    return "gfs_seamless"
        case .icon:   return "icon_seamless"
        case .gem:    return "gem_seamless"
        case .arpege: return "meteofrance_seamless"
        case .jma:    return "jma_seamless"
        case .cma:    return "cma_grapes_global"
        case .aifs:   return "ecmwf_aifs025_single"
        }
    }

    public var label: String {
        switch self {
        case .nbm:    return "NBM"
        case .hrrr:   return "HRRR"
        case .ecmwf:  return "ECMWF"
        case .ukmo:   return "UKMO"
        case .gfs:    return "GFS"
        case .icon:   return "ICON"
        case .gem:    return "GEM"
        case .arpege: return "ARPEGE"
        case .jma:    return "JMA"
        case .cma:    return "CMA"
        case .aifs:   return "AIFS"
        }
    }

    /// One line on what it is — enough to know whose side to take when they
    /// disagree, which is the whole reason they are all on screen.
    public var note: String {
        switch self {
        case .nbm:    return "National Blend of Models — what the NWS forecast is built from"
        case .hrrr:   return "3 km, rerun hourly, assimilates radar — best on storms already underway"
        case .ecmwf:  return "The European global model, the usual benchmark for skill"
        case .ukmo:   return "The UK Met Office global model"
        case .gfs:    return "The American global model"
        case .icon:   return "The German global model"
        case .gem:    return "The Canadian global model"
        case .arpege: return "Météo-France's global model"
        case .jma:    return "The Japanese global model"
        case .cma:    return "The Chinese global model"
        case .aifs:   return "ECMWF's machine-learned model — same starting analysis as ECMWF, different method"
        }
    }
}

// MARK: - What they said

public struct PrecipOutlook: Equatable, Sendable {

    /// Measurable, in inches per hour. The archive already calls 0.01″ the
    /// smallest amount worth printing; anything under it is rounding and a model
    /// that produces it has not forecast rain.
    public static let measurable = 0.01

    /// One model's hourly accumulation, aligned to `times`.
    public struct Row: Equatable, Sendable, Identifiable {
        public let model: PrecipModel
        /// Inches in each hour. `nil` where the model does not reach that far —
        /// HRRR stops at 18 hours, and a short model must read as SILENT there
        /// rather than as forecasting nothing.
        public let inches: [Double?]

        public var id: String { model.id }

        public var total: Double { inches.compactMap { $0 }.reduce(0, +) }
        public var isWet: Bool { inches.contains { ($0 ?? 0) >= PrecipOutlook.measurable } }

        /// When this model first has measurable rain.
        public func onset(in times: [Date]) -> Date? {
            guard let i = inches.firstIndex(where: { ($0 ?? 0) >= PrecipOutlook.measurable }),
                  times.indices.contains(i) else { return nil }
            return times[i]
        }

        public init(model: PrecipModel, inches: [Double?]) {
            self.model = model; self.inches = inches
        }
    }

    public let times: [Date]
    public let rows: [Row]
    /// When the numbers were fetched, so the card can say how old they are.
    public let fetched: Date

    public init(times: [Date], rows: [Row], fetched: Date = Date()) {
        self.times = times; self.rows = rows; self.fetched = fetched
    }

    // MARK: Reading the spread

    public var wetModels: [Row] { rows.filter(\.isWet) }
    public var modelCount: Int { rows.count }

    /// How many models have measurable rain in a given hour — the number the
    /// heatmap's column is really showing.
    public func agreement(atHour i: Int) -> Int {
        rows.count { ($0.inches.indices.contains(i) ? ($0.inches[i] ?? 0) : 0) >= Self.measurable }
    }

    /// AROUND WHEN, taken as the MEDIAN of the wet models' onsets rather than the
    /// earliest of them. One eager model with a stray hundredth at noon should not
    /// be allowed to say the rain starts at noon.
    public var onset: Date? {
        let onsets = wetModels.compactMap { $0.onset(in: times) }.sorted()
        guard !onsets.isEmpty else { return nil }
        return onsets[onsets.count / 2]
    }

    /// Smallest and largest storm totals among the models that HAVE rain.
    ///
    /// Across the wet ones only, because the count is stated separately and a
    /// range that opened at 0.00″ next to "4 of 5 have rain" reads as a
    /// contradiction rather than as the spread.
    public var wetRange: (low: Double, high: Double)? {
        let totals = wetModels.map(\.total).sorted()
        guard let low = totals.first, let high = totals.last else { return nil }
        return (low, high)
    }

    /// The headline, in the form a person asks the question.
    ///
    /// A SENTENCE RATHER THAN A SCORE, and a count rather than a probability: "4
    /// of 5" is a thing someone can argue with, and "68%" is not — nobody can say
    /// where that number came from or which model is the holdout.
    public var headline: String {
        let wet = wetModels.count
        switch wet {
        case 0:            return "No rain in any of the \(spelled(modelCount)) models"
        case modelCount:   return "All \(spelled(modelCount)) models bring rain"
        default:           return "\(wet) of \(modelCount) models bring rain"
        }
    }

    /// How much and roughly when, or nil when nothing has rain.
    public var detail: String? {
        guard let range = wetRange else { return nil }
        let amount = range.low == range.high
            ? WeatherAlmanac.inches(range.high)
            : "\(WeatherAlmanac.inches(range.low))–\(WeatherAlmanac.inches(range.high))"
        guard let onset else { return amount }
        return "\(amount) · from around \(WeatherAlmanac.clock(Calendar.current.component(.hour, from: onset)))"
    }

    /// The model most out of step with the rest — named because "who is the odd
    /// one out" is the next question after "how many", and on the afternoon this
    /// was written the answer was the one model a single-model layer would have
    /// shown.
    public var holdout: PrecipModel? {
        let wet = wetModels.count
        guard modelCount > 2 else { return nil }
        if wet == modelCount - 1 { return rows.first { !$0.isWet }?.model }
        if wet == 1 { return wetModels.first?.model }
        return nil
    }

    private func spelled(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six",
                     "seven", "eight", "nine", "ten", "eleven", "twelve"]
        return words.indices.contains(n) ? words[n] : "\(n)"
    }
}

// MARK: - Fetching it

public struct PrecipOutlookClient: Sendable {
    public static let credit = "NBM, ECMWF, HRRR, ICON, GFS via Open-Meteo"

    /// Eighteen hours, because that is as far as HRRR runs. Past it the card
    /// would be comparing four models against a blank column and calling the gap
    /// disagreement.
    public static let hours = 18

    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public enum Failure: Error, LocalizedError {
        case badResponse(status: Int)
        case decoding(Error)
        case empty

        public var errorDescription: String? {
            switch self {
            case .badResponse(let status): return "Open-Meteo returned HTTP \(status)."
            case .decoding(let error): return "Couldn't read the forecast: \(error.localizedDescription)"
            case .empty: return "Open-Meteo returned no hours."
            }
        }
    }

    public func outlook(home: GeoPoint, hours: Int = PrecipOutlookClient.hours) async throws -> PrecipOutlook {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: "\(home.latitude)"),
            .init(name: "longitude", value: "\(home.longitude)"),
            .init(name: "hourly", value: "precipitation"),
            .init(name: "models", value: PrecipModel.allCases.map(\.apiName).joined(separator: ",")),
            .init(name: "forecast_hours", value: "\(hours)"),
            // ASKED FOR IN INCHES rather than converted here. The service does the
            // unit maths once and correctly; a conversion of our own would be one
            // more place for a factor to be wrong in a way that still looks like
            // plausible rain.
            .init(name: "precipitation_unit", value: "inch"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "timezone", value: "UTC"),
        ]

        let (data, response) = try await session.data(from: components.url!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.badResponse(status: status) }

        do {
            return try Self.decode(data)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.decoding(error)
        }
    }

    // MARK: Decoding

    /// The response keys the series by MODEL — `precipitation_ncep_nbm_conus` —
    /// so the container's keys are not known at compile time.
    struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    struct Response: Decodable {
        var times: [Date]
        var series: [String: [Double?]]

        enum Top: String, CodingKey { case hourly }

        init(from decoder: Decoder) throws {
            let root = try decoder.container(keyedBy: Top.self)
            let hourly = try root.nestedContainer(keyedBy: DynamicKey.self, forKey: .hourly)
            times = try hourly.decode([Double].self, forKey: DynamicKey(stringValue: "time"))
                .map { Date(timeIntervalSince1970: $0) }
            var found: [String: [Double?]] = [:]
            for key in hourly.allKeys where key.stringValue != "time" {
                found[key.stringValue] = try? hourly.decode([Double?].self, forKey: key)
            }
            series = found
        }
    }

    static func decode(_ data: Data) throws -> PrecipOutlook {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard !response.times.isEmpty else { throw Failure.empty }

        // ONE ROW PER MODEL, WHETHER OR NOT IT ANSWERED, and in the declared
        // order. A model that returned nothing must still occupy its row as a
        // silent one — dropping it would quietly shrink the denominator, so "4 of
        // 4 agree" could mean the one dissenter failed to load.
        let rows = PrecipModel.allCases.map { model in
            let values = response.series["precipitation_\(model.apiName)"]
                ?? response.series["precipitation"]
            return PrecipOutlook.Row(
                model: model,
                inches: response.times.indices.map { i in
                    guard let values, values.indices.contains(i) else { return nil }
                    return values[i]
                })
        }
        return PrecipOutlook(times: response.times, rows: rows)
    }
}
