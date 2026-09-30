//
//  ForecasterViews.swift  (Weather)
//
//  The Forecasters destination: storm coverage on the air now, if there is
//  any, then each channel's newest videos. Choosing one plays it beside the
//  app — see `VideoPlayer.swift`.
//
//  "NOBODY IS LIVE" IS SAID, NOT IMPLIED. The live section is the reason to
//  open this page during a storm, so when it is empty the page says so and
//  says when it last looked, rather than starting at the first channel as if
//  there were no such section. See [[cards-never-silently-absent]].
//

import SwiftUI
import WeatherKit

struct ForecasterView: View {
    @ObservedObject var model: ForecasterModel
    @EnvironmentObject private var playback: VideoPlayback

    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 18, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                onTheAir
                ForEach(ForecasterChannel.all) { channel in
                    shelf(channel)
                }
            }
            .padding(24)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Live

    @ViewBuilder private var onTheAir: some View {
        if model.stormStreams.isEmpty {
            Label(quietLine, systemImage: "dot.radiowaves.left.and.right")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("On the air").font(.title3.weight(.semibold))
                ForEach(model.stormStreams) { video in
                    Button { playback.play(video) } label: { liveCard(video) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private var quietLine: String {
        let checked = ForecasterChannel.all.compactMap { channel -> Date? in
            if case .loaded(_, let at) = model.shelf(channel) { return at }
            return nil
        }.min()
        guard let checked else { return "Checking for live storm coverage…" }
        return "No live storm coverage right now · checked \(When.moment(checked))"
    }

    private func liveCard(_ video: ForecasterVideo) -> some View {
        HStack(spacing: 16) {
            Thumbnail(video: video).frame(width: 240)
            VStack(alignment: .leading, spacing: 6) {
                LiveBadge()
                Text(video.title).font(.headline).multilineTextAlignment(.leading)
                Text(model.channel(of: video)?.name ?? "").font(.subheadline).foregroundStyle(.secondary)
                Text(playback.video == video ? "Playing" : "Listen while you watch the radar")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.red.opacity(0.35)))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Channels

    private func shelf(_ channel: ForecasterChannel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name).font(.title3.weight(.semibold))
                Text(channel.summary).font(.subheadline).foregroundStyle(.secondary)
            }
            switch model.shelf(channel) {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            case .loaded(let videos, _):
                grid(videos)
            case .failed(let why, let kept):
                Label("Couldn't reach YouTube: \(why)", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                grid(kept)
            }
        }
    }

    private func grid(_ videos: [ForecasterVideo]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(videos) { video in
                Button { playback.play(video) } label: { tile(video) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func tile(_ video: ForecasterVideo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Thumbnail(video: video)
                .overlay(alignment: .bottomLeading) {
                    if playback.video == video {
                        Label("Playing", systemImage: "speaker.wave.2.fill")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.7), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
            Text(video.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            Text(When.moment(video.published))
                .font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

/// A video's still, at 16:9 whatever width it is given.
struct Thumbnail: View {
    let video: ForecasterVideo

    var body: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                AsyncImage(url: video.thumbnailURL) { image in
                    // `hqdefault` is 4:3 with the 16:9 picture letterboxed
                    // inside it; filling crops the bars away.
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Image(systemName: "play.rectangle").foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct LiveBadge: View {
    var body: some View {
        Text("LIVE")
            .font(.caption2.weight(.heavy))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.red, in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.white)
    }
}
