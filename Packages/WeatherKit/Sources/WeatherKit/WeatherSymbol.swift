//
//  WeatherSymbol.swift  (WeatherKit)
//
//  WeatherFlow's icon names, as SF Symbols.
//
//  ONE MAPPING FOR EVERY SCREEN. The Mac and the TV each had their own, and
//  they had drifted: the TV's matched on fragments and drew a sun behind the
//  clouds on a partly cloudy night. A forecast row drawing a different sky from
//  the card above it is the kind of wrong nobody reports and everybody notices.
//

import Foundation

public enum WeatherSymbol {
    public static func name(_ icon: String) -> String {
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
