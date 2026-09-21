//
//  SetupModel.swift  (Weather)
//
//  The state behind first-run setup: a token being typed, the stations it turns
//  out to see, and which one you picked.
//
//  THE WHOLE IDEA — the app needs a token, a station id and a home coordinate,
//  and the old settings form asked for all three as if they were independent.
//  They are not. `/swd/rest/stations` answers with an id, a name and a location
//  for every station on a token, so the second and third are DERIVABLE from the
//  first. Setup asks for one paste and works out the rest, which is the
//  difference between a form and something that feels like it is helping.
//

import Foundation
import SwiftUI
import WeatherKit

@MainActor
final class SetupModel: ObservableObject {

    /// Where the token stands. Four states and not a pair of booleans, because
    /// "typed but not yet checked" and "checked and empty" are different things
    /// to say and a `isLoading`/`isValid` pair can represent neither honestly.
    enum Check: Equatable {
        case idle
        case checking
        case found([TempestStation])
        case failed(String)
    }

    @Published var token: String = ""
    @Published var check: Check = .idle
    @Published var chosen: TempestStation?

    /// The debounce task for the live check. Held so a new keystroke can cancel
    /// the flight already in progress — without it, a slow first response can
    /// land after a faster later one and overwrite a good answer with a stale one.
    private var probe: Task<Void, Never>?

    var stations: [TempestStation] {
        if case .found(let list) = check { return list }
        return []
    }

    var isChecking: Bool { check == .checking }

    /// Enough to configure the app: a station chosen from a token that checked out.
    var isSatisfied: Bool { chosen != nil && !trimmedToken.isEmpty }

    var trimmedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Check the token after the typing settles.
    ///
    /// Debounced rather than run per keystroke because a pasted token arrives as
    /// one change but a typed one arrives as sixty, and sixty requests to find
    /// out the first fifty-nine were prefixes is rude to an API we want to keep
    /// using. Half a second is long enough to cover a paste-then-tidy and short
    /// enough that it still feels like the field is answering you.
    func tokenChanged() {
        probe?.cancel()
        chosen = nil
        let candidate = trimmedToken
        guard candidate.count >= 20 else {
            // Tempest personal tokens are UUID-shaped. Below that there is
            // nothing to check yet, and saying "invalid" about a half-typed
            // token is how a form makes you feel watched.
            check = .idle
            return
        }
        check = .checking
        probe = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.verify(candidate)
        }
    }

    /// Ask the token what it can see, and choose for the user when there is
    /// nothing to choose between. One station is the overwhelmingly common case
    /// and making someone click the only option is ceremony.
    func verify(_ candidate: String) async {
        do {
            let found = try await TempestClient.stations(token: candidate)
            guard !Task.isCancelled else { return }
            check = .found(found)
            if found.count == 1 { chosen = found.first }
        } catch {
            guard !Task.isCancelled else { return }
            check = .failed(Self.explain(error))
        }
    }

    /// Re-run the check now, for the Retry button. A network blip is the common
    /// reason to be here and waiting out the debounce again would be strange.
    func recheck() {
        probe?.cancel()
        let candidate = trimmedToken
        guard !candidate.isEmpty else { return }
        check = .checking
        probe = Task { [weak self] in await self?.verify(candidate) }
    }

    /// Adopt the flow's result. Everything learned lands in one place so there
    /// is no half-configured state to reason about.
    func commit(to settings: AppSettings) {
        guard let station = chosen else { return }
        settings.apply(token: trimmedToken, station: station)
    }

    /// Start from what is already configured, so re-running setup from the
    /// sidebar is an EDIT rather than a fresh interrogation.
    func seed(from settings: AppSettings) {
        guard !settings.tempestToken.isEmpty else { return }
        token = settings.tempestToken
        recheck()
    }

    /// The failure in the user's terms, not the transport's.
    ///
    /// 401 is the one that matters and the one a generic message serves worst:
    /// it almost always means a token copied from the wrong row of the Data
    /// Authorizations page, and saying so is the difference between a fixable
    /// message and a wall.
    private static func explain(_ error: Error) -> String {
        if let failure = error as? TempestClient.Failure {
            switch failure {
            case .badResponse(let status) where status == 401 || status == 403:
                return "That token wasn’t accepted. Check you copied a personal-use token, not a station or app key."
            case .badResponse(let status):
                return "WeatherFlow returned HTTP \(status). Worth trying again in a moment."
            case .decoding:
                return "The token worked, but the station list came back in a shape this app didn’t expect."
            case .notConfigured:
                return "Paste a token to continue."
            }
        }
        if (error as? URLError)?.code == .notConnectedToInternet {
            return "No internet connection — setup needs one to find your station."
        }
        return error.localizedDescription
    }
}
