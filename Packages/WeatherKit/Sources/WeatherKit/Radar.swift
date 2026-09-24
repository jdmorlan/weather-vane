//
//  Radar.swift  (WeatherKit)
//
//  One frame of the loop, and the few constants every radar view shares.
//
//  The frames are single-site NEXRAD Level II volumes — see `Level2Client` for
//  where they come from and `Level2Render` for how they are drawn. This file
//  used to hold the Iowa State mosaic too (a WMS index, tile URLs, a colour ramp
//  read back out of its PNGs). That went when the Level II loop replaced it: a
//  kilometre-gridded picture of somebody else's rendering could not be made to
//  look or read as well as the radar's own measurements.
//

import Foundation

/// One volume scan in the loop.
public struct RadarFrame: Codable, Equatable, Sendable, Identifiable {
    /// When the volume began.
    public var time: Date
    /// The volume's file name, e.g. `KFWS20260924_122217_V06`. Unique and
    /// permanent — a finished volume never changes — which is what makes it
    /// correct as both the tile-cache stamp and the frame's identity.
    public var key: String

    public var stamp: String { key }
    public var id: String { key }

    public init(time: Date, key: String) { self.time = time; self.key = key }
}

public enum Radar {
    /// A newest frame older than this is not a picture of now. Volumes take
    /// four to ten minutes (longer in clear-air mode) and post about seven
    /// minutes after they start, so a healthy feed's newest frame can be
    /// seventeen minutes old; past half an hour the site has stopped sending.
    public static let staleAfter: TimeInterval = 30 * 60

    /// Tile edge in pixels. 512 rather than 256: a quarter of the tiles for the
    /// same ground, and each one is drawn on this device, so tile count is CPU.
    public static let tileSize = 512
}

// MARK: - How far out to look

/// The viewport is FIXED on your acre, so the only spatial control left is how far
/// out it reaches. Three steps rather than a free zoom, because a cell over the
/// next field and a line 60 miles west are different questions — and a continuous
/// zoom makes you re-answer "where am I looking" every single time.
public enum RadarRange: String, CaseIterable, Identifiable, Sendable {
    case overhead, close, nearby, regional

    public var id: String { rawValue }

    /// Radius in metres.
    public var radius: Double {
        switch self {
        // ~7 mi. Tighter than `close`, because nineteen miles is still a county
        // away: once a cell is nearly on you the question stops being "where is
        // it" and becomes "is it over the house or the next road up", and that
        // is a scale the wider views cannot resolve. A Level II gate is 250 m,
        // so even here the picture is resolving the weather, not its pixels.
        case .overhead: return 11_500
        case .close:    return 30_000     // ~19 mi — the near neighbourhood
        case .nearby:   return 90_000     // ~56 mi — what is about to be
        case .regional: return 240_000    // ~150 mi — what the day is made of
        }
    }

    public var label: String {
        switch self {
        case .overhead: return "Overhead"
        case .close:    return "Close"
        case .nearby:   return "Nearby"
        case .regional: return "Regional"
        }
    }
}
