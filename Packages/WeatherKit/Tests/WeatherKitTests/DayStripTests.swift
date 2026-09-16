import Foundation
import Testing
@testable import WeatherKit

@Suite("Day strip")
struct DayStripTests {

    private let tz = TimeZone(identifier: "America/Chicago")!
    private let day = "2026-09-05"

    private var dayStart: Int {
        Int(DayKey.date(from: day, timeZone: tz)!.timeIntervalSince1970)
    }

    /// One sample per minute over a stretch of hours, warming through the morning.
    private func samples(fromHour: Int, throughHour: Int,
                         temp: (Int) -> Double) -> [StationSample] {
        var out: [StationSample] = []
        for hour in fromHour...throughHour {
            for minute in stride(from: 0, to: 60, by: 1) {
                var s = StationSample(timestamp: dayStart + hour * 3600 + minute * 60,
                                      bucketMinutes: 1)
                s.airTemp = temp(hour)
                s.humidity = 70
                out.append(s)
            }
        }
        return out
    }

    private func forecastHours(from: Int, through: Int, temp: Double) -> [HourSlice] {
        (from...through).map { hour in
            HourSlice(epoch: dayStart + hour * 3600,
                      clock: WeatherInterpreter.clock(hour),
                      temperature: temp, precipProbability: 10, precip: 0,
                      windAvg: 4, windGust: 9, windDirectionCardinal: "S",
                      windDirection: 180, pressure: 30.0, dewPoint: 60,
                      icon: "clear-day", conditions: "Clear",
                      isNight: false)
        }
    }

    @Test("The frame is always 24 columns, midnight to midnight")
    func fixedFrame() {
        let strip = DayStrip.build(day: day,
                                   samples: samples(fromHour: 0, throughHour: 9) { 60 + Double($0) },
                                   forecast: forecastHours(from: 10, through: 23, temp: 88),
                                   timeZone: tz, sunriseHour: 7, sunsetHour: 19)
        #expect(strip.hours.count == 24)
        #expect(strip.hours.first?.clock == "12am")
        #expect(strip.hours.last?.clock == "11pm")
        // Column i is hour i, whatever filled it.
        for (i, hour) in strip.hours.enumerated() {
            #expect(hour.epoch == dayStart + i * 3600)
        }
    }

    @Test("Behind the seam is measured, ahead of it is forecast")
    func splice() {
        let strip = DayStrip.build(day: day,
                                   samples: samples(fromHour: 0, throughHour: 9) { 60 + Double($0) },
                                   forecast: forecastHours(from: 10, through: 23, temp: 88),
                                   timeZone: tz, sunriseHour: 7, sunsetHour: 19)
        #expect(strip.observedHours == 10)
        #expect(strip.hours[0...9].allSatisfy { $0.isObserved })
        #expect(strip.hours[10...23].allSatisfy { !$0.isObserved })
        #expect(strip.hours[8].temperature == 68)
        #expect(strip.hours[14].temperature == 88)
    }

    /// The whole point of the feature: at ten in the morning the strip can say
    /// what eight o'clock was like, which no daily low can.
    @Test("A measured hour holds the temperature it actually was")
    func morningIsRecoverable() {
        let strip = DayStrip.build(day: day,
                                   samples: samples(fromHour: 5, throughHour: 9) { hour in
                                       hour == 8 ? 65 : 50
                                   },
                                   forecast: forecastHours(from: 10, through: 23, temp: 50),
                                   timeZone: tz, sunriseHour: 7, sunsetHour: 19)
        #expect(strip.hours[8].temperature == 65)
        // And the day's low — 50° — is nowhere near what the morning felt like.
        #expect(strip.low?.value == 50)
    }

    @Test("Extremes carry the moment they happened")
    func extremesAreTimestamped() throws {
        var samples = samples(fromHour: 5, throughHour: 9) { _ in 70 }
        samples[12].airTemp = 61            // 5:12am
        samples[200].airTemp = 84
        let strip = DayStrip.build(day: day, samples: samples,
                                   forecast: [], timeZone: tz,
                                   sunriseHour: 7, sunsetHour: 19)
        let low = try #require(strip.low)
        #expect(low.value == 61)
        #expect(low.timestamp == dayStart + 5 * 3600 + 12 * 60)
        #expect(strip.high?.value == 84)
    }

    @Test("Nothing measured yet is a strip, not an absence")
    func forecastOnly() {
        let strip = DayStrip.build(day: day, samples: [],
                                   forecast: forecastHours(from: 6, through: 23, temp: 80),
                                   timeZone: tz, sunriseHour: 7, sunsetHour: 19)
        #expect(strip.hours.count == 24)
        #expect(!strip.hasObservations)
        #expect(strip.low == nil)
        // Hours with neither source are present and empty rather than missing —
        // the ribbon addresses columns by position.
        #expect(strip.hours[3].temperature == nil)
        #expect(strip.hours[3].clock == "3am")
    }

    @Test("Samples from a neighbouring day don't leak into the strip")
    func fencedToTheDay() {
        var stray = StationSample(timestamp: dayStart - 600, bucketMinutes: 1)
        stray.airTemp = 20                  // yesterday, and far colder
        let strip = DayStrip.build(day: day,
                                   samples: samples(fromHour: 6, throughHour: 8) { _ in 70 } + [stray],
                                   forecast: [], timeZone: tz,
                                   sunriseHour: 7, sunsetHour: 19)
        #expect(strip.low?.value == 70)
        #expect(strip.observedHours == 3)
    }

    @Test("Forecast hours past midnight belong to tomorrow, not this strip")
    func forecastFenced() {
        let tomorrow = (0...5).map { hour in
            HourSlice(epoch: dayStart + 86_400 + hour * 3600,
                      clock: WeatherInterpreter.clock(hour), temperature: 99,
                      precipProbability: nil, precip: nil, windAvg: nil, windGust: nil,
                      windDirectionCardinal: nil, windDirection: nil, pressure: nil,
                      dewPoint: nil, icon: "clear-night", conditions: "Clear", isNight: true)
        }
        let strip = DayStrip.build(day: day, samples: [],
                                   forecast: forecastHours(from: 20, through: 23, temp: 75) + tomorrow,
                                   timeZone: tz, sunriseHour: 7, sunsetHour: 19)
        #expect(strip.hours[20].temperature == 75)
        #expect(!strip.hours.contains { $0.temperature == 99 })
    }

    /// A gust averaged over an hour is the dilution `StationSample` exists to
    /// stop; rain summed over an hour is the only honest reduction there is.
    @Test("Each measure gets the reduction it deserves")
    func reductions() {
        var bucket = samples(fromHour: 14, throughHour: 14) { _ in 90 }
        bucket[10].windGust = 31
        bucket[11].windGust = 12
        bucket[10].windAvg = 18
        bucket[10].windDirection = 315
        for i in bucket.indices { bucket[i].precip = 0.01 }
        let strip = DayStrip.build(day: day, samples: bucket, forecast: [],
                                   timeZone: tz, sunriseHour: 7, sunsetHour: 19)
        let hour = strip.hours[14]
        #expect(hour.windGust == 31)
        #expect((hour.precip ?? 0) > 0.59 && (hour.precip ?? 0) < 0.61)
        #expect(hour.windDirectionCardinal == "NW")
        // It either rained or it didn't — a measurement has no chance left in it.
        #expect(hour.precipProbability == 100)
    }
}
