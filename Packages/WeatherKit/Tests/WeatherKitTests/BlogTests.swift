import XCTest
@testable import WeatherKit

final class BlogTests: XCTestCase {

    /// Trimmed from Space City Weather's real feed on 2026-09-30: the channel's
    /// own title, then two posts out of date order.
    private let feed = """
    <?xml version="1.0" encoding="UTF-8"?><rss version="2.0"
      xmlns:content="http://purl.org/rss/1.0/modules/content/"
      xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
      <title> Space City Weather</title>
      <item>
        <title>Houston&#8217;s weather: Hot for a few more days, then rainy, and then we cool off</title>
        <link>https://spacecityweather.com/houstons-weather-hot/</link>
        <dc:creator><![CDATA[Matt Lanza]]></dc:creator>
        <pubDate>Tue, 29 Sep 2026 12:00:12 +0000</pubDate>
        <guid isPermaLink="false">https://spacecityweather.com/?p=59500</guid>
        <description><![CDATA[A few more hot days ... <p class="read-more-container"><a href="x">See full post</a></p>]]></description>
        <content:encoded><![CDATA[<p>A few more hot days.</p>]]></content:encoded>
      </item>
      <item>
        <title>It will be rather windy today, followed by a much wetter pattern through the weekend</title>
        <link>https://spacecityweather.com/it-will-be-rather-windy-today/</link>
        <dc:creator><![CDATA[Eric Berger]]></dc:creator>
        <pubDate>Wed, 30 Sep 2026 11:57:43 +0000</pubDate>
        <guid isPermaLink="false">https://spacecityweather.com/?p=59538</guid>
        <description><![CDATA[In brief: After today ...]]></description>
        <content:encoded><![CDATA[
    <p class="has-background"><strong>In brief</strong>: After today, which will be windy, Houston will face a distinctly wetter pattern. We don&#8217;t have any specific flooding concerns.</p>
    <h3>A word about wind</h3><p>It&#8217;s been a minute.</p>]]></content:encoded>
      </item>
    </channel></rss>
    """

    func testPostsNewestFirstWithTheirAuthorsAndIDs() throws {
        let posts = try BlogFeed.parse(Data(feed.utf8))
        XCTAssertEqual(posts.map(\.id), ["https://spacecityweather.com/?p=59538",
                                         "https://spacecityweather.com/?p=59500"])
        XCTAssertEqual(posts.map(\.author), ["Eric Berger", "Matt Lanza"])
        XCTAssertEqual(posts[1].title, "Houston’s weather: Hot for a few more days, then rainy, and then we cool off")
        XCTAssertEqual(posts[0].published, ISO8601DateFormatter().date(from: "2026-09-30T11:57:43Z"))
    }

    func testTheSummaryIsTheInBriefParagraphAsPlainText() throws {
        let post = try BlogFeed.parse(Data(feed.utf8))[0]
        XCTAssertEqual(post.summary, "After today, which will be windy, Houston will face a distinctly wetter pattern. We don’t have any specific flooding concerns.")
        XCTAssertTrue(post.html.contains("<h3>A word about wind</h3>"), "the body is kept whole")
    }

    func testWithoutABriefTheSummaryIsTheExcerptWithoutItsReadMoreLink() throws {
        let post = try BlogFeed.parse(Data(feed.utf8))[1]
        XCTAssertEqual(post.summary, "A few more hot days ...")
    }
}
