//
//  WeatherSymbol.swift  (tvOS)
//
//  WeatherFlow's icon names, as SF Symbols.
//
//  Its own file because two surfaces need it — the card deck and the days page —
//  and it began life private inside a view that has since been replaced. A
//  mapping this small is easy to copy and then easy to let drift, and a forecast
//  row drawing a different cloud from the card above it is the kind of wrong
//  that nobody reports and everybody notices.
//

import Foundation

enum WeatherSymbol {
    static func name(_ icon: String) -> String {
        switch icon {
        case let i where i.contains("thunder"):       return "cloud.bolt.rain.fill"
        case let i where i.contains("snow"):          return "cloud.snow.fill"
        case let i where i.contains("sleet"):         return "cloud.sleet.fill"
        case let i where i.contains("rain"):          return "cloud.rain.fill"
        case let i where i.contains("foggy"):         return "cloud.fog.fill"
        case let i where i.contains("partly-cloudy"): return "cloud.sun.fill"
        case let i where i.contains("cloudy"):        return "cloud.fill"
        case let i where i.contains("clear-night"):   return "moon.stars.fill"
        default:                                       return "sun.max.fill"
        }
    }
}
