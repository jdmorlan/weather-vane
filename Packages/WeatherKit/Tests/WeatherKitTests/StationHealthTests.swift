import XCTest
@testable import WeatherKit

/// The health surface is the one screen a user opens when they already suspect
/// something is wrong, which makes a false clean bill the expensive failure
/// here: it sends someone away from a station that has actually stopped. Most
/// of what follows is therefore about the ways "fine" can be wrong.
final class StationHealthTests: XCTestCase {

    // MARK: Power modes

    /// The four documented steps, read at their falling edges.
    func testPowerModeThresholds() {
        XCTAssertEqual(PowerMode.forTempest(volts: 2.80), .normal)
        XCTAssertEqual(PowerMode.forTempest(volts: 2.455), .normal)
        XCTAssertEqual(PowerMode.forTempest(volts: 2.454), .saving)
        XCTAssertEqual(PowerMode.forTempest(volts: 2.415), .saving)
        XCTAssertEqual(PowerMode.forTempest(volts: 2.40), .conserving)
        XCTAssertEqual(PowerMode.forTempest(volts: 2.39), .conserving)
        XCTAssertEqual(PowerMode.forTempest(volts: 2.30), .critical)
    }

    /// The hysteresis band. Between 2.355 and 2.39 the hardware could be in
    /// either mode depending on which way it was travelling, and a voltage alone
    /// can't say. Reading the worse one is the point — rounding up here would
    /// mean telling someone the rain sensor is listening when it may not be.
    func testTheHysteresisBandReadsAsTheWorseMode() {
        XCTAssertEqual(PowerMode.forTempest(volts: 2.37), .critical)
    }

    // MARK: Contact

    /// Three missed reports of slack, so one dropped packet over wifi doesn't
    /// read as a fault.
    func testAStationOneReportLateIsStillReporting() {
        let now = Date()
        let contact = Contact.judge(lastObserved: now.addingTimeInterval(-90),
                                    reportInterval: 1, now: now)
        XCTAssertTrue(contact.isHealthy)
    }

    /// The grace has to scale with the station's OWN interval. A unit in mode 3
    /// reports every five minutes, and judging it against one minute would raise
    /// an alarm at exactly the moment the surface most needs to be believed.
    func testGraceFollowsTheStationsOwnReportInterval() {
        let now = Date()
        let fourMinutesAgo = now.addingTimeInterval(-240)
        XCTAssertTrue(Contact.judge(lastObserved: fourMinutesAgo, reportInterval: 5, now: now).isHealthy)
        // Same age, same verdict for a one-minute station: the floor of five
        // minutes' slack is what keeps a healthy fast station from flickering.
        XCTAssertTrue(Contact.judge(lastObserved: fourMinutesAgo, reportInterval: 1, now: now).isHealthy)
    }

    func testLateThenSilent() {
        let now = Date()
        guard case .late = Contact.judge(lastObserved: now.addingTimeInterval(-1800),
                                         reportInterval: 1, now: now) else {
            return XCTFail("half an hour with no report should read as late")
        }
        guard case .silent = Contact.judge(lastObserved: now.addingTimeInterval(-40_000),
                                           reportInterval: 1, now: now) else {
            return XCTFail("eleven hours with no report should read as silent")
        }
    }

    // MARK: Reading the wire

    /// A real Tempest row, taken verbatim from the live endpoint. Positions are
    /// unavoidable on this endpoint — it ships no `ob_fields` — so this test is
    /// the only thing standing between a column shift and a plausible-looking
    /// wrong voltage on screen.
    private let tempestRow = #"""
    {"device_id":224120,"type":"obs_st","obs":[[1789741535,1.4,1.7,2.0,163,6,972.7,
      27.3,68,37461,3.56,312,0.0,0,0,0,2.59,1,0.0,0.0,0.0,0]]}
    """#

    private func decode(_ json: String) throws -> DeviceObservations {
        try JSONDecoder().decode(DeviceObservations.self, from: Data(json.utf8))
    }

    func testATempestRowYieldsBatteryIntervalAndEverySensor() throws {
        let vitals = try XCTUnwrap(decode(tempestRow).vitals())
        XCTAssertEqual(vitals.battery ?? 0, 2.59, accuracy: 0.0001)
        XCTAssertEqual(vitals.reportInterval, 1)
        XCTAssertEqual(vitals.observedAt.timeIntervalSince1970, 1789741535)
        XCTAssertEqual(Set(vitals.sensors.map(\.kind)), Set(SensorKind.allCases))
        XCTAssertTrue(vitals.silentSensors.isEmpty)
    }

    /// The distinction the whole sensor panel rests on. This row is a quiet,
    /// dry, windless night: zeros everywhere the sky happens to be doing
    /// nothing. Not one of them is a fault.
    func testZeroIsAReadingAndNullIsNot() throws {
        let quiet = try decode(#"""
        {"type":"obs_st","obs":[[1789741535,0,0,0,0,3,972.7,12.0,90,0,0,0,0.0,0,0,0,2.7,1]]}
        """#)
        XCTAssertEqual(try XCTUnwrap(quiet.vitals()).silentSensors, [])

        // The same row with the haptic rain column null — one dead part, and the
        // only thing that tells you is that it stopped saying zero.
        let deadRain = try decode(#"""
        {"type":"obs_st","obs":[[1789741535,0,0,0,0,3,972.7,12.0,90,0,0,0,null,0,0,0,2.7,1]]}
        """#)
        XCTAssertEqual(try XCTUnwrap(deadRain.vitals()).silentSensors, [.rain])
    }

    /// An instrument counts as alive if ANY of its columns answered, so a
    /// partially reported wind block is not a dead anemometer.
    func testOneLiveColumnKeepsAnInstrumentAlive() throws {
        let partial = try decode(#"""
        {"type":"obs_st","obs":[[1789741535,null,null,null,163,3,972.7,12.0,90,0,0,0,0.0,0,0,0,2.7,1]]}
        """#)
        XCTAssertFalse(try XCTUnwrap(partial.vitals()).silentSensors.contains(.wind))
    }

    /// An unknown `type` must yield nothing rather than read a Tempest's layout
    /// out of some other unit's row. The failure being guarded is not a crash —
    /// it's a believable voltage that is silently the wind direction.
    func testAnUnknownPayloadTypeIsRefusedRatherThanGuessed() throws {
        let future = try decode(#"""
        {"type":"obs_xx","obs":[[1789741535,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,2.59,1]]}
        """#)
        XCTAssertNil(future.vitals())
        XCTAssertTrue(future.batteryTrend().isEmpty)
    }

    func testAnAirAndASkyAreReadAtTheirOwnPositions() throws {
        let air = try XCTUnwrap(try decode(#"""
        {"type":"obs_air","obs":[[1789741535,972.7,27.3,68,0,0,2.41,1]]}
        """#).vitals())
        XCTAssertEqual(air.battery ?? 0, 2.41, accuracy: 0.0001)
        XCTAssertEqual(Set(air.sensors.map(\.kind)), [.temperature, .pressure, .lightning])

        let sky = try XCTUnwrap(try decode(#"""
        {"type":"obs_sky","obs":[[1789741535,37461,3.5,0.0,1.4,1.7,2.0,163,3.12,1,312]]}
        """#).vitals())
        XCTAssertEqual(sky.battery ?? 0, 3.12, accuracy: 0.0001)
        XCTAssertEqual(Set(sky.sensors.map(\.kind)), [.wind, .light, .rain])
    }

    // MARK: The report-interval trap

    /// The subtle one, and the reason the two device calls are separate.
    ///
    /// In a WINDOWED response, the column that holds `report_interval` carries
    /// the server's bucket size instead — a week-long fetch of a station that
    /// speaks every minute reports 30. If the trend call also supplied the
    /// interval, a perfectly healthy station would look like it had throttled
    /// itself to half-hourly, and `Contact` would then hand it half an hour of
    /// slack it hasn't earned. So the trend contributes voltages and nothing else.
    func testAWindowedFetchContributesVoltagesOnly() throws {
        let windowed = try decode(#"""
        {"type":"obs_st","obs":[
          [1789137000,0.0,1.1,3.2,216,15,964.3,28.0,71,43281,3.92,361,0.0,0,0,0,2.57,30],
          [1789138800,0.0,1.0,3.0,210,15,964.0,27.0,72,41000,3.50,340,0.0,0,0,0,2.60,30]]}
        """#)
        let trend = windowed.batteryTrend()
        XCTAssertEqual(trend.readings.count, 2)
        XCTAssertEqual(trend.low ?? 0, 2.57, accuracy: 0.0001)

        // The vitals — including the interval — come from the unwindowed call,
        // which is the only one that reports the station's real cadence.
        let live = try XCTUnwrap(decode(tempestRow).vitals(trend: trend))
        XCTAssertEqual(live.reportInterval, 1)
        XCTAssertEqual(live.trend.readings.count, 2)
    }

    // MARK: Battery trend

    private func trend(_ volts: [Double]) -> BatteryTrend {
        let start = Date(timeIntervalSince1970: 1_789_000_000)
        return BatteryTrend(readings: volts.enumerated().map {
            BatteryReading(date: start.addingTimeInterval(Double($0.offset) * 1800), volts: $0.element)
        })
    }

    /// A healthy solar station swings a third of a volt every day and is fine.
    /// The daily sawtooth must not read as decline, or the surface cries wolf
    /// every single week.
    func testTheNormalDailySawtoothIsNotADecline() {
        let twoDays = [2.75, 2.60, 2.45, 2.55, 2.75, 2.60, 2.44, 2.56, 2.76, 2.61]
        XCTAssertFalse(trend(twoDays).isFalling)
    }

    /// A floor that walks downwards is the earliest honest warning there is —
    /// visible here while the latest reading is still comfortably in mode 0.
    func testAWalkingFloorReadsAsFalling() {
        let sliding = [2.78, 2.70, 2.76, 2.68, 2.66, 2.60, 2.62, 2.56, 2.58, 2.50]
        let t = trend(sliding)
        XCTAssertTrue(t.isFalling)
        XCTAssertEqual(PowerMode.forTempest(volts: t.readings.last!.volts), .normal,
                       "the newest reading is still normal — that's exactly why the trend matters")
    }

    /// Two points and a straight line through them is not a trend.
    func testTooFewReadingsRefuseToCallADirection() {
        XCTAssertNil(trend([2.75, 2.40]).driftVolts)
        XCTAssertFalse(trend([2.75, 2.40]).isFalling)
    }

    /// The worst mode passed through, which the current reading hides entirely.
    func testWorstModeSeesTheOvernightDip() {
        XCTAssertEqual(trend([2.78, 2.60, 2.43, 2.55, 2.77]).worstMode, .saving)
    }

    // MARK: Standing

    private func station(_ devices: [DeviceHealth]) -> StationHealth {
        StationHealth(stationID: 1, name: "Backyard", devices: devices)
    }

    private func tempest(vitals: DeviceVitals?, note: String? = nil) -> DeviceHealth {
        DeviceHealth(id: 1, kind: .tempest, serial: "ST-1", name: "Tempest",
                     vitals: vitals, note: note)
    }

    private func healthyVitals(at now: Date, battery: Double = 2.70) -> DeviceVitals {
        DeviceVitals(observedAt: now.addingTimeInterval(-30),
                     battery: battery,
                     reportInterval: 1,
                     sensors: SensorKind.allCases.map { SensorReport(kind: $0, isReporting: true) },
                     trend: trend([2.75, 2.62, 2.50, 2.60, 2.74, 2.63, 2.51, 2.61, 2.76, 2.64]))
    }

    func testAWorkingStationReadsGood() {
        let now = Date()
        let (standing, _) = station([tempest(vitals: healthyVitals(at: now))]).standing(now: now)
        XCTAssertEqual(standing, .good)
    }

    /// Silence outranks everything, because it invalidates every other screen in
    /// the app rather than merely degrading this one.
    func testSilenceOutranksADeadSensor() {
        let now = Date()
        var vitals = healthyVitals(at: now)
        vitals.observedAt = now.addingTimeInterval(-40_000)
        vitals.sensors = SensorKind.allCases.map {
            SensorReport(kind: $0, isReporting: $0 != .rain)
        }
        let (standing, why) = station([tempest(vitals: vitals)]).standing(now: now)
        XCTAssertEqual(standing, .trouble)
        XCTAssertTrue(why.contains("Nothing heard"), why)
    }

    /// A dead instrument is trouble even while the unit is chatting away on
    /// time — the archive is being written either way, and what it's recording
    /// is a lie about the sky.
    func testADeadSensorIsTroubleOnAPunctualStation() {
        let now = Date()
        var vitals = healthyVitals(at: now)
        vitals.sensors = SensorKind.allCases.map {
            SensorReport(kind: $0, isReporting: $0 != .lightning)
        }
        let (standing, why) = station([tempest(vitals: vitals)]).standing(now: now)
        XCTAssertEqual(standing, .trouble)
        XCTAssertTrue(why.localizedLowercase.contains("lightning"), why)
    }

    /// The failure mode this whole file exists for: a station reporting on time,
    /// every sensor answering, that has quietly stopped measuring gusts.
    func testAPunctualStationInAPowerSaveModeIsNotCalledHealthy() {
        let now = Date()
        let vitals = healthyVitals(at: now, battery: 2.40)
        let (standing, why) = station([tempest(vitals: vitals)]).standing(now: now)
        XCTAssertEqual(standing, .trouble)
        XCTAssertTrue(why.localizedLowercase.contains("wind"), why)
    }

    /// The false alarm this page must not raise. A great many perfectly healthy
    /// Tempests touch mode 1 at four in the morning after a cloudy day and are
    /// back at full charge by noon. Calling that "worth keeping an eye on" would
    /// put a warning here most weeks, and a page that cries wolf is one nobody
    /// reads on the week it matters — so the dip is mentioned, not flagged.
    func testAnOrdinaryNightlyDipIntoSavingIsStillHealthy() {
        let now = Date()
        var vitals = healthyVitals(at: now)
        vitals.trend = trend([2.77, 2.60, 2.43, 2.58, 2.76, 2.61, 2.44, 2.59, 2.77, 2.62])
        let (standing, why) = station([tempest(vitals: vitals)]).standing(now: now)
        XCTAssertEqual(standing, .good)
        XCTAssertTrue(why.localizedLowercase.contains("ordinary"), why)
    }

    /// A dip to mode 2 is a different matter — that's the point where gust peaks
    /// stop being trustworthy, so it earns the flag the mode-1 dip doesn't.
    func testADipIntoConservingIsWorthFlagging() {
        let now = Date()
        var vitals = healthyVitals(at: now)
        vitals.trend = trend([2.77, 2.60, 2.40, 2.58, 2.76, 2.61, 2.41, 2.59, 2.77, 2.62])
        let (standing, _) = station([tempest(vitals: vitals)]).standing(now: now)
        XCTAssertEqual(standing, .watch)
    }

    /// A hub carries no vitals by nature and must not drag the verdict down.
    func testTheHubDoesNotCountAgainstTheStation() {
        let now = Date()
        let hub = DeviceHealth(id: 2, kind: .hub, serial: "HB-1", name: "Hub",
                               note: "no readings of its own")
        let (standing, _) = station([hub, tempest(vitals: healthyVitals(at: now))]).standing(now: now)
        XCTAssertEqual(standing, .good)
    }

    /// An unreachable station is trouble, not a clean bill. The natural bug is
    /// an empty device list reading as "nothing wrong found".
    func testNoVitalsAtAllIsTroubleRatherThanSilence() {
        let (standing, _) = station([tempest(vitals: nil, note: "timed out")]).standing()
        XCTAssertEqual(standing, .trouble)
        let (empty, _) = station([]).standing()
        XCTAssertNotEqual(empty, .good)
    }

    // MARK: Registry decoding

    /// The live `/stations/{id}` payload, trimmed to the fields read here.
    func testTheRegistryYieldsBothUnitsWithTheirFirmware() throws {
        let payload = #"""
        {"stations":[{"station_id":68737,"name":"The Home","public_name":"JDM",
          "timezone":"America/Chicago","station_meta":{"elevation":421.87},
          "devices":[
            {"device_id":185911,"device_type":"HB","serial_number":"HB-00071390",
             "firmware_revision":"194","hardware_revision":"1",
             "device_meta":{"environment":"indoor","name":"HB-00071390"}},
            {"device_id":224120,"device_type":"ST","serial_number":"ST-00053513",
             "firmware_revision":"181","hardware_revision":"1",
             "device_meta":{"agl":2.1336,"environment":"outdoor","name":"ST-00053513"}}]}]}
        """#
        let registry = try JSONDecoder().decode(TempestClient.StationRegistry.self,
                                                from: Data(payload.utf8))
        let entry = try XCTUnwrap(registry.stations.first)
        XCTAssertEqual(entry.displayName, "JDM")
        XCTAssertEqual(entry.stationMeta?.elevation ?? 0, 421.87, accuracy: 0.01)

        let devices = entry.devices.map(\.health)
        XCTAssertEqual(devices.map(\.kind), [.hub, .tempest])
        XCTAssertEqual(devices.map(\.kind.senses), [false, true])
        XCTAssertEqual(devices[1].firmware, "181")
        XCTAssertEqual(devices[1].heightAboveGround ?? 0, 2.1336, accuracy: 0.0001)

        // Neither unit has been renamed, so both fall back to what they ARE
        // rather than repeating the serial number already shown beside them.
        XCTAssertEqual(devices.map(\.name), ["Hub", "Tempest"])
    }

    func testARenamedUnitKeepsItsName() throws {
        let payload = #"""
        {"stations":[{"station_id":1,"devices":[
          {"device_id":9,"device_type":"ST","serial_number":"ST-9",
           "device_meta":{"name":"Back fence"}}]}]}
        """#
        let registry = try JSONDecoder().decode(TempestClient.StationRegistry.self,
                                                from: Data(payload.utf8))
        XCTAssertEqual(registry.stations.first?.devices.first?.health.name, "Back fence")
    }

    /// An unknown device code must not claim to sense, or `health()` would ask
    /// an endpoint that answers 404 and record the failure as a fault.
    func testAnUnknownDeviceCodeIsNotAskedForVitals() {
        XCTAssertEqual(DeviceKind(code: "ZZ"), .unknown)
        XCTAssertFalse(DeviceKind(code: "ZZ").senses)
        XCTAssertFalse(DeviceKind(code: nil).senses)
    }
}
