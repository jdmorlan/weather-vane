//
//  VideoPlayer.swift  (Weather)
//
//  One forecaster's video, playing beside the app rather than instead of it.
//  The point is to listen to someone work a storm while looking at your own
//  radar, and to make him the whole screen the moment he says something worth
//  seeing.
//
//  YOUTUBE'S OWN EMBEDDED PLAYER, IN A WEB VIEW, and nothing else is allowed:
//  YouTube's terms forbid pulling the stream out into AVPlayer. The embed
//  brings its own controls, captions, quality menu and any ads, and they can't
//  be restyled or hidden.
//
//  A CARD OVER THE WINDOW, the same on the Mac and the iPad: the video's own
//  shape, in any corner, any size, and expanded to fill the window. See
//  `FloatingPlayer`. The SAME web view grows and shrinks — the frame changes,
//  the view is never replaced — so expanding a live stream doesn't restart it.
//
//  THE REFERER IS THE BUNDLE ID. YouTube refuses to play an embed that doesn't
//  say who is embedding it (its "error 153"), and a page loaded from a string
//  has no origin of its own. `origin` gives the page `https://<bundle id>`,
//  which is the form YouTube asks apps to use.
//

import SwiftUI
import WebKit
import WeatherKit

/// What is playing, and whether it fills the window. Owned above every
/// destination so the video carries on as you move between them.
@MainActor
final class VideoPlayback: ObservableObject {
    @Published var video: ForecasterVideo?
    /// The video fills the window instead of sharing it.
    @Published var expanded = false

    func play(_ video: ForecasterVideo) {
        self.video = video
    }

    func stop() {
        video = nil
        expanded = false
    }
}

// MARK: - The embed

struct YouTubePlayer {
    let videoID: String

    /// See the file's header.
    private static var origin: URL {
        URL(string: "https://\((Bundle.main.bundleIdentifier ?? "vane.app").lowercased())")!
    }

    private static func page(_ id: String) -> String {
        let src = "https://www.youtube.com/embed/\(id)?autoplay=1&playsinline=1&rel=0"
            + "&origin=\(origin.absoluteString)"
        return """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}
        iframe{position:fixed;inset:0;width:100%;height:100%;border:0}</style>
        </head><body>
        <iframe src="\(src)" allow="autoplay; encrypted-media; picture-in-picture; fullscreen"
          allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe>
        </body></html>
        """
    }

    final class Coordinator { var loaded: String? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        // Chosen from a list is consent enough; without this the video sits on
        // its poster frame until tapped a second time.
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        #if os(iOS)
        // Otherwise an iPad plays every video full screen the moment it starts,
        // which is exactly what the floating card exists to avoid.
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        #endif
        let view = WKWebView(frame: .zero, configuration: config)
        #if os(iOS)
        view.scrollView.isScrollEnabled = false
        view.isOpaque = false
        view.backgroundColor = .black
        #endif
        return view
    }

    /// Only when the video changes: a redraw that reloaded the page would
    /// restart the stream every time the card moved.
    private func load(_ view: WKWebView, _ coordinator: Coordinator) {
        guard coordinator.loaded != videoID else { return }
        coordinator.loaded = videoID
        view.loadHTMLString(Self.page(videoID), baseURL: Self.origin)
    }
}

#if os(macOS)
extension YouTubePlayer: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView() }
    func updateNSView(_ view: WKWebView, context: Context) { load(view, context.coordinator) }
}
#else
extension YouTubePlayer: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView() }
    func updateUIView(_ view: WKWebView, context: Context) { load(view, context.coordinator) }
}
#endif

// MARK: - The floating card

/// Laid over the whole window by `RootView`. Empty — and so transparent to
/// clicks and touches — when nothing is playing.
///
/// OUR OWN PICTURE-IN-PICTURE, because the system's can't be had: it needs
/// the video in Apple's player, and it is in YouTube's (see the file's
/// header). What it keeps from the system's is the shape — a card exactly the
/// video's proportions, no black above or below, in a corner of your choosing
/// and as large as you make it.
///
/// WHAT CAME BEFORE, ON THE MAC. First a separate floating window, which left
/// two windows to arrange every time. Then a pane beside the destination,
/// which put a wide video in a tall column: most of the pane was black bars.
struct FloatingPlayer: View {
    @ObservedObject var playback: VideoPlayback
    @AppStorage("videoCardCorner") private var corner = Corner.bottomTrailing
    /// The card's width; its height follows at 16:9. Remembered, since the
    /// size you settle on for watching beside the radar is the size you want
    /// next time.
    @AppStorage("videoCardWidth") private var cardWidth: Double = 420
    @State private var drag = CGSize.zero
    @State private var resizeStart: Double?

    enum Corner: String, CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing
        var isLeading: Bool { self == .topLeading || self == .bottomLeading }
        var isTop: Bool { self == .topLeading || self == .topTrailing }
    }

    #if os(macOS)
    private static var bar: CGFloat { 28 }
    #else
    private static var bar: CGFloat { 40 }
    #endif
    private static var inset: CGFloat { 16 }
    private static var minWidth: Double { 280 }

    var body: some View {
        GeometryReader { geo in
            if let video = playback.video {
                let size = playback.expanded ? geo.size : cardSize(in: geo.size)
                VStack(spacing: 0) {
                    controls(video, window: geo.size)
                    YouTubePlayer(videoID: video.id)
                }
                .frame(width: size.width, height: size.height)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: playback.expanded ? 0 : 12))
                .overlay {
                    if !playback.expanded {
                        RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.15))
                    }
                }
                .shadow(color: .black.opacity(playback.expanded ? 0 : 0.4), radius: 18, y: 6)
                .position(center(of: size, in: geo.size))
                .offset(playback.expanded ? .zero : drag)
                .animation(.snappy, value: playback.expanded)
                .animation(.snappy, value: corner)
            }
        }
        .background {
            if playback.expanded { Color.black.ignoresSafeArea() }
        }
    }

    /// The largest the window allows, the smallest YouTube's controls fit in.
    private func maxWidth(in window: CGSize) -> Double {
        let byWidth = window.width - 2 * Self.inset
        let byHeight = (window.height - 2 * Self.inset - Self.bar) * 16 / 9
        return max(Self.minWidth, Double(min(byWidth, byHeight)))
    }

    private func cardSize(in window: CGSize) -> CGSize {
        let width = min(max(cardWidth, Self.minWidth), maxWidth(in: window))
        return CGSize(width: width, height: width * 9 / 16 + Self.bar)
    }

    private func center(of size: CGSize, in window: CGSize) -> CGPoint {
        if playback.expanded { return CGPoint(x: window.width / 2, y: window.height / 2) }
        let x = corner.isLeading ? Self.inset + size.width / 2
                                 : window.width - Self.inset - size.width / 2
        let y = corner.isTop ? Self.inset + size.height / 2
                             : window.height - Self.inset - size.height / 2
        return CGPoint(x: x, y: y)
    }

    /// A strip ABOVE the picture rather than buttons over it, so every click
    /// on the video still reaches YouTube's own controls. Dragging the strip
    /// moves the card to whichever corner it was thrown toward; the grip at
    /// its inner end — the end facing the middle of the window — resizes it.
    private func controls(_ video: ForecasterVideo, window: CGSize) -> some View {
        HStack(spacing: 12) {
            if !playback.expanded && !corner.isLeading { resizeGrip(window: window) }
            Text(video.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                playback.expanded.toggle()
            } label: {
                Image(systemName: playback.expanded ? "arrow.down.right.and.arrow.up.left"
                                                    : "arrow.up.left.and.arrow.down.right")
            }
            .help(playback.expanded ? "Back to the corner" : "Fill the window")
            Button {
                playback.stop()
            } label: {
                Image(systemName: "xmark")
            }
            .help("Close the video")
            if !playback.expanded && corner.isLeading { resizeGrip(window: window) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: Self.bar)
        .background(.black)
        .contentShape(Rectangle())
        .gesture(playback.expanded ? nil : DragGesture()
            .onChanged { drag = $0.translation }
            .onEnded { value in
                corner = nearest(after: value.predictedEndTranslation, card: cardSize(in: window))
                drag = .zero
            })
    }

    /// Dragged toward the middle of the window, the card grows; the corner it
    /// sits in stays put.
    private func resizeGrip(window: CGSize) -> some View {
        Image(systemName: corner.isLeading ? "arrow.down.forward.and.arrow.up.backward"
                                           : "arrow.down.backward.and.arrow.up.forward")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.7))
            .frame(width: 24, height: Self.bar)
            .contentShape(Rectangle())
            #if os(macOS)
            .onHover { inside in
                if inside {
                    NSCursor.frameResize(position: corner.isLeading ? .topRight : .topLeft,
                                         directions: .all).push()
                } else {
                    NSCursor.pop()
                }
            }
            #endif
            .highPriorityGesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = resizeStart ?? Double(cardSize(in: window).width)
                    resizeStart = start
                    let across = Double(corner.isLeading ? value.translation.width : -value.translation.width)
                    let down = Double(corner.isTop ? value.translation.height : -value.translation.height) * 16 / 9
                    let grow = abs(across) > abs(down) ? across : down
                    cardWidth = min(max(start + grow, Self.minWidth), maxWidth(in: window))
                }
                .onEnded { _ in resizeStart = nil })
            .help("Drag to resize")
    }

    private func nearest(after moved: CGSize, card: CGSize) -> Corner {
        // Half the card's own travel in a direction is enough to change sides.
        let goesLeft = corner.isLeading ? moved.width < card.width / 2 : moved.width < -card.width / 2
        let goesUp = corner.isTop ? moved.height < card.height / 2 : moved.height < -card.height / 2
        switch (goesLeft, goesUp) {
        case (true, true):   return .topLeading
        case (false, true):  return .topTrailing
        case (true, false):  return .bottomLeading
        case (false, false): return .bottomTrailing
        }
    }
}
