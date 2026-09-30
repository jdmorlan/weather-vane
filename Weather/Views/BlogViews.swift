//
//  BlogViews.swift  (Weather)
//
//  Space City Weather, read in the app: its recent posts down the side, and the
//  one you pick — the newest, to begin with — set in the app's own type.
//
//  FOR SOMEONE WHO READS IT EVERY MORNING, so three things matter more than
//  anything clever: it opens on today's post without a tap, the type is large
//  and can be made larger, and the sidebar says NEW when there is a post you
//  have not opened. Links inside a post open in the browser rather than
//  replacing the post you were reading.
//

import SwiftUI
import WebKit
import WeatherKit

@MainActor
final class BlogModel: ObservableObject {
    let blog: Blog
    @Published private(set) var posts: [BlogPost] = []
    @Published private(set) var failure: String?
    @Published private(set) var checked: Date?
    /// The newest post opened on this device. Per device on purpose: the one
    /// who reads it on the iPad has not read it just because the Mac has.
    @AppStorage("blogLastRead") private var lastRead = ""

    /// They post in the morning and update through the day when weather is
    /// happening. Half an hour is soon enough for either.
    static let pollInterval: Duration = .seconds(1800)

    init(blog: Blog = .spaceCityWeather) { self.blog = blog }

    var newest: BlogPost? { posts.first }
    var hasUnread: Bool { newest.map { $0.id != lastRead } ?? false }

    func markRead(_ post: BlogPost) {
        // Only the newest counts: reading last Tuesday's post does not mean
        // this morning's has been seen.
        if post.id == newest?.id { lastRead = post.id }
    }

    func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    func refresh() async {
        do {
            posts = try await BlogClient().posts(from: blog)
            failure = nil
            checked = Date()
        } catch {
            // The posts already here stay; the failure is said above them.
            failure = error.localizedDescription
        }
    }
}

struct BlogView: View {
    @ObservedObject var model: BlogModel
    @State private var chosen: BlogPost.ID?
    /// Remembered: the size someone settles on is the size they want tomorrow.
    @AppStorage("blogTextSize") private var textSize: Double = 19

    private var post: BlogPost? {
        model.posts.first { $0.id == chosen } ?? model.newest
    }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 290)
            Divider()
            reader
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: post?.id) { _, _ in
            if let post { model.markRead(post) }
        }
        .onAppear {
            if let post { model.markRead(post) }
        }
    }

    // MARK: The list

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if let failure = model.failure {
                    Label("Couldn't reach \(model.blog.name): \(failure)", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(10)
                }
                ForEach(model.posts) { item in
                    Button { chosen = item.id } label: { row(item) }
                        .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
    }

    private func row(_ item: BlogPost) -> some View {
        let isShown = item.id == post?.id
        return VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.headline)
                .multilineTextAlignment(.leading)
            Text([item.author, When.moment(item.published)].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            Text(item.summary)
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isShown ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: The post

    @ViewBuilder private var reader: some View {
        if let post {
            BlogReader(post: post, home: model.blog.home, textSize: textSize)
                .overlay(alignment: .topTrailing) { sizeControls.padding(12) }
        } else if model.failure != nil {
            ContentUnavailableView("Couldn't load \(model.blog.name)", systemImage: "newspaper",
                                   description: Text("It will try again on its own."))
        } else {
            ProgressView()
        }
    }

    private var sizeControls: some View {
        HStack(spacing: 0) {
            Button { textSize = max(15, textSize - 2) } label: {
                Image(systemName: "textformat.size.smaller").frame(width: 34, height: 28)
            }
            .help("Smaller text")
            Divider().frame(height: 18)
            Button { textSize = min(31, textSize + 2) } label: {
                Image(systemName: "textformat.size.larger").frame(width: 34, height: 28)
            }
            .help("Larger text")
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: Capsule())
    }
}

// MARK: - Reader

/// A post's HTML in the app's type: a readable measure, images to the column's
/// width, and the light or dark of the app around it.
struct BlogReader {
    let post: BlogPost
    let home: URL
    let textSize: Double

    @Environment(\.openURL) private var openURL

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?
        var open: (URL) -> Void = { _ in }

        /// A tapped link goes to the browser. The post stays where it was.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = coordinator
        return view
    }

    private func update(_ view: WKWebView, _ coordinator: Coordinator) {
        coordinator.open = { openURL($0) }
        let key = "\(post.id)|\(textSize)"
        guard coordinator.loaded != key else { return }
        // Same post, new size: restyle in place rather than reload, so the
        // reader keeps their place in the post.
        if let old = coordinator.loaded, old.hasPrefix("\(post.id)|") {
            view.evaluateJavaScript("document.documentElement.style.fontSize='\(Int(textSize))px'")
        } else {
            view.loadHTMLString(page, baseURL: home)
        }
        coordinator.loaded = key
    }

    private var page: String {
        let byline = [post.author, When.moment(post.published)].compactMap { $0 }.joined(separator: " · ")
        let link = post.link.map { #"<p class="source"><a href="\#($0.absoluteString)">Read on spacecityweather.com</a></p>"# } ?? ""
        return """
        <!doctype html><html style="font-size:\(Int(textSize))px"><head>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <style>
          :root { color-scheme: light dark; --ink:#1d1d1f; --soft:#6e6e73; --rule:#d2d2d7; --brief:#f2f2f7; --link:#0066cc; }
          @media (prefers-color-scheme: dark) {
            :root { --ink:#f5f5f7; --soft:#a1a1a6; --rule:#3a3a3c; --brief:#1c1c1e; --link:#4da3ff; }
          }
          html { -webkit-text-size-adjust: 100%; }
          body { margin:0; padding: 28px 28px 60px; background: transparent; color: var(--ink);
                 font: 1rem/1.6 -apple-system, system-ui, sans-serif; }
          main { max-width: 40em; margin: 0 auto; }
          h1 { font-size: 1.6rem; line-height: 1.25; margin: 0 0 .35em; }
          .byline { color: var(--soft); font-size: .8rem; margin: 0 0 1.6em; }
          h2, h3 { font-size: 1.15rem; margin: 1.8em 0 .5em; }
          p { margin: 0 0 1em; }
          a { color: var(--link); }
          img { max-width: 100%; height: auto; border-radius: 8px; }
          figure { margin: 1.4em 0; }
          figcaption { color: var(--soft); font-size: .75rem; line-height: 1.45; margin-top: .5em; }
          .has-background { background: var(--brief) !important; color: var(--ink) !important;
                            padding: .9em 1.1em; border-radius: 10px; }
          .source { border-top: 1px solid var(--rule); padding-top: 1em; margin-top: 2.5em; font-size: .8rem; }
        </style></head><body><main>
        <h1>\(escape(post.title))</h1>
        <p class="byline">\(escape(byline))</p>
        \(post.html)
        \(link)
        </main></body></html>
        """
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }
}

#if os(macOS)
extension BlogReader: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) { update(view, context.coordinator) }
}
#else
extension BlogReader: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) { update(view, context.coordinator) }
}
#endif
