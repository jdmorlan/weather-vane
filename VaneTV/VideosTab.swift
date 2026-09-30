//
//  VideosTab.swift  (tvOS)
//
//  The forecasters' newest videos, and their storm coverage while it is on the
//  air — the same list as the Mac and iPad, but pressing one hands it to the
//  YouTube app instead of playing it here.
//
//  WHY IT CAN'T PLAY HERE. tvOS has no web view, and YouTube's embedded player
//  is the only way its terms allow a video to be played inside another app.
//  So on the TV there is no watching him over the radar; Menu on the remote
//  comes back from YouTube to Vane, on this tab.
//

import SwiftUI
import WeatherKit

struct VideosTab: View {
    @ObservedObject var model: ForecasterModel
    @Environment(\.openURL) private var openURL
    @State private var couldNotOpen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 44) {
                onTheAir
                ForEach(ForecasterChannel.all) { channel in
                    row(channel)
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 30)
        }
    }

    // MARK: Live

    @ViewBuilder private var onTheAir: some View {
        if model.stormStreams.isEmpty {
            Label("No live storm coverage right now", systemImage: "dot.radiowaves.left.and.right")
                .font(.system(size: 26)).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 20) {
                Text("On the air").font(.system(size: 36, weight: .semibold))
                ScrollView(.horizontal) {
                    HStack(spacing: 48) {
                        ForEach(model.stormStreams) { video in
                            tile(video, width: 640, live: true)
                        }
                    }
                    .padding(.vertical, 30)
                }
                .scrollClipDisabled()
            }
        }
        if couldNotOpen {
            Text("Couldn't open YouTube. Install the YouTube app from the App Store to watch these on the TV.")
                .font(.system(size: 24)).foregroundStyle(.orange)
        }
    }

    // MARK: Channels

    private func row(_ channel: ForecasterChannel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(channel.name).font(.system(size: 36, weight: .semibold))
            Text(channel.summary).font(.system(size: 24)).foregroundStyle(.secondary)
            switch model.shelf(channel) {
            case .loading:
                ProgressView().frame(height: 260)
            case .loaded(let videos, _):
                shelf(videos)
            case .failed(let why, let kept):
                Text("Couldn't reach YouTube: \(why)").font(.system(size: 22)).foregroundStyle(.secondary)
                shelf(kept)
            }
        }
    }

    private func shelf(_ videos: [ForecasterVideo]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 48) {
                ForEach(videos) { video in
                    tile(video, width: 420, live: false)
                }
            }
            .padding(.vertical, 30)
        }
        .scrollClipDisabled()
    }

    private func tile(_ video: ForecasterVideo, width: CGFloat, live: Bool) -> some View {
        Button { open(video) } label: {
            VStack(alignment: .leading, spacing: 10) {
                AsyncImage(url: video.thumbnailURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.secondary.opacity(0.15)
                }
                .frame(width: width, height: width * 9 / 16)
                .clipped()
                .overlay(alignment: .topLeading) {
                    if live {
                        Text("LIVE")
                            .font(.system(size: 22, weight: .heavy))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.red, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(.white)
                            .padding(14)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.title)
                        .font(.system(size: 22, weight: .medium))
                        .lineLimit(2, reservesSpace: true)
                    Text(When.moment(video.published))
                        .font(.system(size: 18)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            .frame(width: width)
        }
        .buttonStyle(.card)
    }

    /// The YouTube app's own scheme first. It is not documented, so if the app
    /// declines it the web address is tried, which tvOS hands to whichever app
    /// claims YouTube links.
    private func open(_ video: ForecasterVideo) {
        couldNotOpen = false
        openURL(URL(string: "youtube://watch/\(video.id)")!) { accepted in
            guard !accepted else { return }
            openURL(video.watchURL) { accepted in couldNotOpen = !accepted }
        }
    }
}
