//
//  ForecasterModel.swift  (Weather, VaneTV)
//
//  The two channels' newest videos, and any storm coverage on the air now.
//  Shared with the TV: it holds no view and no platform code.
//
//  FIVE MINUTES, AND CHEAP WHEN NOTHING IS HAPPENING. A pass is two small
//  feeds, plus one watch page for each video the feed shows from the last
//  `LiveBroadcast.stormStreamLimit` whose state could still change. A roundup
//  is asked once and remembered as an upload; a finished broadcast is asked
//  until it ends and remembered as ended. On a quiet day a pass is the two feeds.
//

import Foundation
import Combine
import WeatherKit

@MainActor
final class ForecasterModel: ObservableObject {
    enum Shelf {
        case loading
        case loaded([ForecasterVideo], at: Date)
        /// The last list stays on screen under a failure, which says why and
        /// since when. A shelf never goes blank because one pass failed.
        case failed(String, kept: [ForecasterVideo])
    }

    @Published private(set) var shelves: [ForecasterChannel.ID: Shelf] =
        Dictionary(uniqueKeysWithValues: ForecasterChannel.all.map { ($0.id, .loading) })
    /// Storm coverage on the air now, newest first. Empty when nobody is live —
    /// and when the 24/7 stream is, which is the point. See `Forecasters.swift`.
    @Published private(set) var stormStreams: [ForecasterVideo] = []

    static let pollInterval: Duration = .seconds(300)

    private let client = ForecasterClient()
    private var settled: [ForecasterVideo.ID: LiveBroadcast] = [:]

    func shelf(_ channel: ForecasterChannel) -> Shelf { shelves[channel.id] ?? .loading }

    func channel(of video: ForecasterVideo) -> ForecasterChannel? {
        ForecasterChannel.all.first { $0.id == video.channelID }
    }

    func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    func refresh() async {
        let client = self.client
        let results = await withTaskGroup(of: (ForecasterChannel, Result<[ForecasterVideo], Error>).self) { group in
            for channel in ForecasterChannel.all {
                group.addTask {
                    do { return (channel, .success(try await client.videos(from: channel))) }
                    catch { return (channel, .failure(error)) }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        for (channel, result) in results {
            switch result {
            case .success(let videos):
                shelves[channel.id] = .loaded(videos, at: Date())
            case .failure(let error):
                shelves[channel.id] = .failed(error.localizedDescription, kept: videos(in: shelf(channel)))
            }
        }
        await checkLive()
    }

    private func videos(in shelf: Shelf) -> [ForecasterVideo] {
        switch shelf {
        case .loading: return []
        case .loaded(let videos, _), .failed(_, let videos): return videos
        }
    }

    /// Asks each recent, unsettled video whether it is on the air.
    private func checkLive() async {
        let now = Date()
        let recent = ForecasterChannel.all
            .flatMap { videos(in: shelf($0)) }
            .filter { now.timeIntervalSince($0.published) < LiveBroadcast.stormStreamLimit }
            .filter { settled[$0.id] == nil }
        let client = self.client
        let states = await withTaskGroup(of: (ForecasterVideo, LiveBroadcast).self) { group in
            for video in recent {
                group.addTask { (video, (try? await client.broadcast(of: video)) ?? .unknown) }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        for (video, state) in states where state.isSettled { settled[video.id] = state }
        stormStreams = states
            .filter { $0.1.isStormStream(title: $0.0.title, now: now) }
            .map(\.0)
            .sorted { $0.published > $1.published }
    }
}
