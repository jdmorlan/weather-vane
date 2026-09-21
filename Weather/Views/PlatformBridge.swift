//
//  PlatformBridge.swift  (Weather)
//
//  The entire macOS↔iPadOS delta, collected in one file so the rest of the app
//  can stay written once.
//
//  WHY A BRIDGE AND NOT A SECOND TARGET'S WORTH OF VIEWS. VaneTV reimplements
//  its own surfaces, and that was right: a ten-foot deck you drive with a remote
//  is a different app that happens to share a domain. An iPad running the
//  sidebar app is not a different app — it is THIS app, on a screen that is
//  mostly the same size and a pointer that happens to be a finger. Forking
//  17,000 lines to change four modifiers and a map would mean every future
//  comment in those files rots on one side or the other.
//
//  So the rule here: nothing in this file has behaviour. It is aliases and
//  shims that make an expression that already compiles on macOS also compile on
//  iOS, with the same MEANING. Anything that would genuinely differ in
//  behaviour belongs at its own call site, fenced there where it can be read
//  next to the thing it changes.
//

import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformColor = UIColor
typealias PlatformImage = UIImage
#endif

extension PlatformImage {
    /// An SF Symbol as a platform image. The two initialisers differ only in
    /// spelling — AppKit wants an accessibility description it is happy to take
    /// as nil, UIKit does not ask.
    static func symbol(_ name: String) -> PlatformImage? {
        #if os(macOS)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)
        #else
        return UIImage(systemName: name)
        #endif
    }
}

#if !os(macOS)
// MARK: - .buttonStyle(.link)

/// `.link` is a macOS-only built-in, and it is used at sixteen call sites — all
/// of them a secondary action sitting next to a prominent one ("Stop", "See the
/// radar instead"). Reimplementing it is far cheaper than fencing sixteen
/// modifiers, and it keeps those call sites saying what they mean rather than
/// carrying a platform conditional apiece.
///
/// Deliberately NOT `.borderless`, which on iOS renders identically to `.plain`
/// and would lose the accent colour that makes these read as the lesser choice.
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.accentColor)
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

extension ButtonStyle where Self == LinkButtonStyle {
    static var link: LinkButtonStyle { LinkButtonStyle() }
}
#endif

// MARK: - Semantic colours

extension Color {
    /// The surface the app's chrome sits on — what a `Canvas` fills behind a
    /// label so an axis line does not run through the text, and what a card's
    /// background uses to punch a hole in what is under it.
    ///
    /// Spelled by MEANING rather than by AppKit's name. The four call sites were
    /// `Color(nsColor: .windowBackgroundColor)`, which named a platform detail to
    /// say "the background"; iOS's equivalent is called something else and there
    /// is no window involved on either platform at these call sites.
    static var windowBackground: Color {
        #if os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color(uiColor: .systemBackground)
        #endif
    }
}

#if !os(macOS)
// MARK: - .toggleStyle(.checkbox)

/// `.checkbox` is macOS-only, and the two call sites that use it both need what
/// a checkbox is FOR rather than what a switch is for: a dense list of things
/// that are on or off at once — map layers, query filters — where a row of iOS
/// switches would triple the height and read as a settings screen.
///
/// Drawn from SF Symbols rather than chased pixel-for-pixel against AppKit: the
/// job is a compact, tappable on/off that matches the platform it is running on,
/// not a Mac impression.
struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isOn ? AnyShapeStyle(Color.accentColor)
                                                        : AnyShapeStyle(.secondary))
                    .imageScale(.large)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension ToggleStyle where Self == CheckboxToggleStyle {
    static var checkbox: CheckboxToggleStyle { CheckboxToggleStyle() }
}
#endif

// MARK: - What to call the machine

enum Platform {
    /// The noun for the device in a user-facing sentence — "its own archive on
    /// this iPad".
    ///
    /// ASKED OF THE DEVICE RATHER THAN THE COMPILER on iOS, even though the iPad
    /// target is iPad-only today. `TARGETED_DEVICE_FAMILY` is a build setting
    /// someone widens in a hurry; a sentence that then calls an iPhone an iPad is
    /// exactly the kind of wrongness nobody files a bug about and everybody
    /// notices. The idiom is free to read and cannot drift.
    static var deviceNoun: String {
        #if os(macOS)
        return "Mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .phone ? "iPhone" : "iPad"
        #endif
    }

    /// Tempest's personal-use token page, deep-linked.
    ///
    /// THE DEEP LINK IS THE WHOLE VALUE. Starting from tempestwx.com there is no
    /// discoverable path to this page — it is Settings → Data Authorizations,
    /// several levels in and named nothing like "token". Landing a logged-in user
    /// directly on it turns a hunt into "create one, or copy the one that's
    /// already there". That is why it is a constant rather than four call sites
    /// retyping a URL, and why it appears in Settings as well as in setup.
    static let tokenPage = URL(string: "https://tempestwx.com/settings/tokens")!
}
