import XCTest
@testable import WeatherKit
@testable import RadarKernel

final class Level2LiveTests: XCTestCase {

    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/KFWS20260924_122217_V06", withExtension: "head"))
        return try Data(contentsOf: url)
    }

    func testChunkKeysParse() throws {
        let chunk = try XCTUnwrap(LiveChunk(key: "KGRK/998/20260924-155008-045-I", posted: nil))
        XCTAssertEqual(chunk.number, 45)
        XCTAssertEqual(chunk.kind, "I")
        // The same instant the archive file's name records.
        XCTAssertEqual(chunk.volumeStart, Level2Scan(name: "KGRK20260924_155008_V06")?.time)
        XCTAssertNil(LiveChunk(key: "KGRK/998/", posted: nil))
    }

    func testArchiveHeaderCarriesTheVolumeNumber() throws {
        // "AR2V0006.929" — KFWS's 12:22Z volume, which sat in chunk folder 929.
        XCTAssertEqual(Level2LiveClient.volumeNumber(fromHeader: try fixture().prefix(24)), 929)
        XCTAssertNil(Level2LiveClient.volumeNumber(fromHeader: Data("nonsense....".utf8)))
    }

    func testVolumeNumbersWrap() {
        XCTAssertEqual(Level2LiveClient.after(998), 999)
        XCTAssertEqual(Level2LiveClient.after(999), 1)
    }

    func testListingEntriesCarryPostedTimes() {
        let xml = Data("""
        <Contents><Key>KGRK/998/20260924-155008-001-S</Key><LastModified>2026-09-24T15:50:18.000Z</LastModified></Contents>\
        <Contents><Key>KGRK/998/20260924-155008-002-I</Key><LastModified>2026-09-24T15:50:30.000Z</LastModified></Contents>
        """.utf8)
        let entries = Level2LiveClient.entries(inListing: xml)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[1].posted, ISO8601DateFormatter().date(from: "2026-09-24T15:50:30Z"))
    }

    /// The plan in the fixture's metadata record: VCP 35, twelve tilts, and the
    /// chunk layout checked against all 55 chunks of KGRK volume 998.
    func testCoveragePatternMapsChunksToTilts() throws {
        let plan = try XCTUnwrap(Level2.coveragePattern(fixture()))
        XCTAssertEqual(plan.number, 35)
        XCTAssertEqual(plan.cuts.count, 12)
        XCTAssertEqual(plan.chunkRanges.first, 2...7, "the 0.5° surveillance cut: 720 radials, six chunks")
        XCTAssertEqual(plan.chunkRanges[6], 38...40, "1.8°: 360 radials, three chunks")
        XCTAssertEqual(plan.chunkRanges.last, 53...55)
        XCTAssertEqual(plan.lowestPasses(), [0])
        XCTAssertEqual(plan.cut(forChunk: 16), 2)
        XCTAssertNil(plan.cut(forChunk: 1), "chunk 1 is the metadata")
    }

    func testSAILSRevisitsAreEachAPass() {
        // KAMX, VCP 212 with SAILS on 2026-09-24: 0.5° again after 1.3°.
        let cut = { (a: Double, s: Bool, r: Int) in Level2.CoveragePattern.Cut(angle: a, isSurveillance: s, radials: r) }
        let plan = Level2.CoveragePattern(number: 212, cuts: [
            cut(0.5, true, 720), cut(0.5, false, 720), cut(0.9, true, 720), cut(0.9, false, 720),
            cut(1.3, true, 720), cut(1.3, false, 720), cut(0.5, true, 720), cut(0.5, false, 720),
            cut(1.8, false, 360)])
        XCTAssertEqual(plan.lowestPasses(), [0, 6])
        XCTAssertEqual(plan.chunkRanges[6], 38...43)
    }
}
