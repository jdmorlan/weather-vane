//
//  AskPopover.swift  (Weather)
//
//  "Ask a question" — from any page, in words, to the page that answers it, with
//  Explore already set up when the question is a search.
//
//  READ AS YOU TYPE. `QuestionParser` takes about a millisecond, so the popover
//  shows where the question will go and how it was read BEFORE you press Return:
//  "Explore · Low below 50°, in 2026, only the last each year". A misreading is
//  visible while it's still one keystroke from fixed, rather than after you've
//  landed on a page wondering why it shows that. Words it couldn't place are
//  said, never dropped — see `ParsedQuestion.unread`.
//
//  Rules rather than a model: Apple's on-device model was measured at this and
//  wrote no correct search out of eight (branch ask-experiment, `ask-eval`), and
//  most of the people using this are on an iPad, where a CLI-driven model can't run.
//

import SwiftUI
import WeatherKit

/// A question's query on its way to Explore. Carries its own id so asking the
/// same question twice still lands — the second time, after you've edited the
/// first, is exactly when you want it to.
struct AskedQuery: Equatable {
    let id = UUID()
    var query: DayQuery
}

struct AskPopover: View {
    /// Go to this page, handing Explore this query when it's the one asked.
    var go: (Destination, DayQuery?) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    private var parsed: ParsedQuestion? {
        text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : QuestionParser.parse(text)
    }

    private var target: Destination? {
        parsed.flatMap { p in Destination.allCases.first { $0.slug == p.page } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Ask a question", text: $text,
                      prompt: Text("When was the last night below 50?"))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(ask)
            preview
        }
        .padding(14)
        .frame(width: 380, alignment: .leading)
        .onAppear { focused = true }
    }

    @ViewBuilder private var preview: some View {
        if let parsed {
            VStack(alignment: .leading, spacing: 5) {
                if let target {
                    Label(target.title, systemImage: target.symbol)
                        .fontWeight(.medium)
                    if target == .explore, let query = parsed.query {
                        Text(query.describe).foregroundStyle(.secondary)
                    } else {
                        Text(target.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("No page answers that yet.").foregroundStyle(.secondary)
                }
                if !parsed.unread.isEmpty {
                    Text("Didn’t understand: \(parsed.unread.map { "“\($0)”" }.joined(separator: " "))")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("A search, like “hot dry days in July, three in a row”, or a page, like “show me the radar”.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func ask() {
        guard let parsed, let target else { return }
        var query = parsed.query
        // The question titles the view, in your own words.
        query?.name = text.trimmingCharacters(in: .whitespaces)
        go(target, target == .explore ? query : nil)
    }
}
