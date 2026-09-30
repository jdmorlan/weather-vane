import XCTest
@testable import WeatherKit

final class ForecasterTests: XCTestCase {

    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    // MARK: Feed

    /// Trimmed from Texas Weather Center's real feed on 2026-09-30: the
    /// channel's own title and published date, then two entries, one of them a
    /// storm broadcast.
    private let feed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns:media="http://search.yahoo.com/mrss/" xmlns="http://www.w3.org/2005/Atom">
     <yt:channelId>oIfgmxArIATc2EpHD3W9EA</yt:channelId>
     <title>David Reimer | Texas Weather Roundup</title>
     <published>2022-09-29T05:11:24+00:00</published>
     <entry>
      <id>yt:video:N7NFCtCeetw</id>
      <yt:videoId>N7NFCtCeetw</yt:videoId>
      <yt:channelId>UCoIfgmxArIATc2EpHD3W9EA</yt:channelId>
      <title>LIVE BREAKING WEATHER: Texas Tornado Warnings 2</title>
      <published>2026-09-30T04:41:52+00:00</published>
      <media:group><media:title>not the title</media:title></media:group>
     </entry>
     <entry>
      <id>yt:video:8eM634tizx8</id>
      <yt:videoId>8eM634tizx8</yt:videoId>
      <yt:channelId>UCoIfgmxArIATc2EpHD3W9EA</yt:channelId>
      <title>Storms Move East Tonight. Here&apos;s Where Flooding Is Most Likely</title>
      <published>2026-09-30T18:08:35+00:00</published>
     </entry>
    </feed>
    """

    func testFeedReadsEntriesNewestFirstAndIgnoresTheChannelsOwnFields() throws {
        let videos = try ForecasterFeed.parse(Data(feed.utf8))
        XCTAssertEqual(videos.map(\.id), ["8eM634tizx8", "N7NFCtCeetw"])
        XCTAssertEqual(videos[0].title, "Storms Move East Tonight. Here's Where Flooding Is Most Likely")
        XCTAssertEqual(videos[1].title, "LIVE BREAKING WEATHER: Texas Tornado Warnings 2")
        XCTAssertEqual(videos[0].published, date("2026-09-30T18:08:35Z"))
        XCTAssertEqual(videos[0].channelID, "UCoIfgmxArIATc2EpHD3W9EA")
    }

    func testAPageThatIsNotAFeedThrows() {
        XCTAssertThrowsError(try ForecasterFeed.parse(Data("<html><body>".utf8)))
    }

    // MARK: Watch pages

    /// The fragments of three real watch pages, 2026-09-30.
    private let twentyFourSeven = #"…"isLiveContent":true…"liveBroadcastDetails":{"isLiveNow":true,"startTimestamp":"2026-07-30T03:33:41+00:00"},…"#
    private let endedStorm = #"…"isLiveContent":true…"liveBroadcastDetails":{"isLiveNow":false,"startTimestamp":"2026-09-30T00:05:49+00:00","endTimestamp":"2026-09-30T02:07:19+00:00"}…"#
    private let premiere = #"…"isLiveContent":false…"liveBroadcastDetails":{"isLiveNow":false,"startTimestamp":"2026-09-30T18:08:35+00:00","endTimestamp":"2026-09-30T18:22:09+00:00"}…"#

    func testAPremiereIsAnUploadEvenThoughItCarriesBroadcastDetails() {
        XCTAssertEqual(LiveBroadcast.parse(watchPage: premiere), .upload)
    }

    func testAFinishedBroadcastIsEnded() {
        XCTAssertEqual(LiveBroadcast.parse(watchPage: endedStorm), .ended)
    }

    func testABroadcastOnTheAirIsLiveSinceItsStart() {
        XCTAssertEqual(LiveBroadcast.parse(watchPage: twentyFourSeven),
                       .live(started: date("2026-07-30T03:33:41Z")))
    }

    func testAScheduledBroadcastIsUpcoming() {
        let page = #""isLiveContent":true,"isUpcoming":true,"liveBroadcastDetails":{"isLiveNow":false,"startTimestamp":"2026-10-01T00:00:00+00:00"}"#
        XCTAssertEqual(LiveBroadcast.parse(watchPage: page), .upcoming)
    }

    func testAPageThatSaysNothingIsUnknownNotLive() {
        XCTAssertEqual(LiveBroadcast.parse(watchPage: "<html>consent</html>"), .unknown)
        XCTAssertFalse(LiveBroadcast.unknown.isSettled)
    }

    func testOnlyUploadsAndEndedBroadcastsAreSettled() {
        XCTAssertTrue(LiveBroadcast.upload.isSettled)
        XCTAssertTrue(LiveBroadcast.ended.isSettled)
        XCTAssertFalse(LiveBroadcast.upcoming.isSettled)
        XCTAssertFalse(LiveBroadcast.live(started: .now).isSettled)
    }

    // MARK: Storm streams

    func testTheTwentyFourSevenStreamIsNeverAStormStream() {
        let now = date("2026-09-30T22:00:00Z")
        let live = LiveBroadcast.parse(watchPage: twentyFourSeven)
        // Too long on the air, whatever it is called…
        XCTAssertFalse(live.isStormStream(title: "Texas Weather Live", now: now))
        // …and called 24/7, however recently it restarted.
        XCTAssertFalse(LiveBroadcast.live(started: now.addingTimeInterval(-600))
            .isStormStream(title: "🔴 Texas Weather Live 24/7 | Live Radar", now: now))
    }

    func testCoverageThatBeganTonightIsAStormStream() {
        let now = date("2026-09-30T02:00:00Z")
        let live = LiveBroadcast.live(started: date("2026-09-30T00:05:49Z"))
        XCTAssertTrue(live.isStormStream(title: "LIVE BREAKING WEATHER: Texas Tornado Warnings", now: now))
        XCTAssertFalse(LiveBroadcast.ended.isStormStream(title: "LIVE BREAKING WEATHER", now: now))
    }
}
