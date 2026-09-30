//
//  HazardTint.swift  (WeatherKit)
//
//  One severity ramp, shared by every surface that draws a warning.
//
//  It lived in the Mac app's hazard views until the TV needed the same colours.
//  Two copies would have been two ramps eventually, and a tornado warning that
//  is red on the desktop and orange on the television is worse than either
//  choice alone — the colour is the fastest thing anyone reads on a warning and
//  it has to mean the same everywhere.
//

import SwiftUI

extension Hazard {
    /// Colour reads off `level`, not off the kind — so the normalized scale is
    /// what the eye sorts by, and a heat advisory can never out-shout a warning
    /// just because fire is red.
    public var tint: Color { Self.tint(forLevel: level) }

    /// Static because the radar draws warning polygons in the same colours from
    /// a polygon subclass that carries only the level. One ramp, so the outline
    /// on the map and the row in the banner can never disagree about how serious
    /// the same warning is.
    public static func tint(forLevel level: Double) -> Color {
        switch level {
        case 0.9...:     return .red
        case 0.7..<0.9:  return .orange
        case 0.45..<0.7: return .yellow
        default:         return .secondary
        }
    }
}

extension HazardWatch.State {
    /// Only the hazards that HAVE an outline. A watch covers whole counties, and
    /// tracing its boundary on a close view draws a line across the picture that
    /// says nothing about where the storm is.
    public var drawable: [Hazard] {
        if case .active(let live) = self { return live.filter { $0.shape != nil } }
        return []
    }
}

extension OutlookColor {
    /// SPC's and WPC's own colours for an outlook category. Here rather than
    /// in the Mac's map code for the same reason as the ramp above: the TV's
    /// forecast draws the same "Slight" in the same yellow.
    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
}
