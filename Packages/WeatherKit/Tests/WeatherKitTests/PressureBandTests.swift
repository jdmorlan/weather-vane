import Testing
@testable import WeatherKit

@Suite("Pressure band")
struct PressureBandTests {

    /// Days across one year, pressure oscillating in a realistically narrow band.
    private func records(_ count: Int, base: Double = 30.0) -> [DailyRecord] {
        (0..<count).map { i in
            var r = DailyRecord(day: String(format: "2025-%02d-%02d", i / 28 + 1, i % 28 + 1))
            let wobble = Double((i * 37) % 21 - 10) / 100  // ±0.10
            r.pressureMean = base + wobble
            r.pressureMin = base + wobble - 0.08
            r.pressureMax = base + wobble + 0.08
            r.sampleCount = 48
            r.expectedSamples = 48
            return r
        }
    }

    @Test("Too thin an archive says nothing rather than inventing a record")
    func refusesThinArchive() {
        let climate = Climatology(records: records(20))
        #expect(climate.pressureBand() == nil)
    }

    @Test("Extremes come from daily min/max, the usual range from means")
    func bandShape() throws {
        var recs = records(120)
        recs[5].pressureMin = 29.10          // the storm
        recs[5].pressureMean = 29.40
        recs[90].pressureMax = 30.85         // the cold high
        recs[90].pressureMean = 30.60
        let band = try #require(Climatology(records: recs).pressureBand())

        #expect(band.lowest.value == 29.10)
        #expect(band.lowest.day == recs[5].day)
        #expect(band.highest.value == 30.85)
        // The usual range is far tighter than the extremes — the whole point of
        // separating them. Two outliers must not widen "ordinary".
        #expect(band.usualLow > 29.5)
        #expect(band.usualHigh < 30.5)
        #expect(band.span > 1.5)
    }

    @Test("Position places a reading in the record, clamped")
    func position() throws {
        let band = try #require(Climatology(records: records(120)).pressureBand())
        #expect(abs(band.position(band.lowest.value) - 0) < 0.001)
        #expect(abs(band.position(band.highest.value) - 1) < 0.001)
        #expect(band.position(band.lowest.value - 5) == 0)
        #expect(band.position(band.highest.value + 5) == 1)
    }

    @Test("Percentile interpolates between neighbours")
    func percentile() {
        let sorted = [1.0, 2.0, 3.0, 4.0, 5.0]
        #expect(Climatology.percentile(sorted, 0) == 1)
        #expect(Climatology.percentile(sorted, 1) == 5)
        #expect(Climatology.percentile(sorted, 0.5) == 3)
        #expect(abs(Climatology.percentile(sorted, 0.25) - 2) < 0.0001)
    }

    @Test("The meaning leads with the level and ends with the trend")
    func meaning() throws {
        let band = try #require(Climatology(records: records(120)).pressureBand())
        let low = WeatherInterpreter.pressureMeaning(band.usualLow - 0.2, band: band, trend: "falling")
        #expect(low.contains("unusually low"))
        #expect(low.contains("Falling"))

        let high = WeatherInterpreter.pressureMeaning(band.usualHigh + 0.2, band: band, trend: "rising")
        #expect(high.contains("unusually high"))
        #expect(high.contains("Rising"))

        let steady = WeatherInterpreter.pressureMeaning(band.median, band: band, trend: "steady")
        #expect(steady.contains("Holding steady"))
    }
}
