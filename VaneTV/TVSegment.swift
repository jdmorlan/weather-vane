//
//  TVSegment.swift  (tvOS)
//
//  A row of plain buttons, because `Picker` traps focus on a television.
//
//  The surface used two segmented `Picker`s. On a Mac that is a control you
//  click; on tvOS it is a focus CONTAINER — moving into it captures left/right
//  for changing the value, so there is no gesture left to move OUT of it, and a
//  second picker beside it is unreachable. Worse, tvOS renders a picker in some
//  contexts with the "press play/pause for options" convention, which turns a
//  visible control into a hidden modal and is a genuinely unpleasant way to
//  change a setting you are looking straight at.
//
//  Buttons have none of that. Every option is its own focusable element in one
//  flat row, so a swipe moves to the next thing whatever it is — the last
//  segment of one group hands off to the first of the next — and selection is
//  a single press with nothing hidden behind a modal.
//

import SwiftUI

struct TVSegment<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 10) {
            ForEach(options, id: \.value) { option in
                Button { selection = option.value } label: {
                    Text(option.label)
                        .font(.system(size: 28, weight: .medium))
                        .padding(.horizontal, 30).padding(.vertical, 14)
                        .frame(minWidth: 170)
                }
                .buttonStyle(TVSegmentStyle(isSelected: selection == option.value))
            }
        }
    }
}

/// Selection and focus are DIFFERENT states and have to look it: on a TV the
/// thing under the pointer is not the thing you chose, and a control that
/// conflates them leaves you unable to tell what will happen when you press.
private struct TVSegmentStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? .black : .white)
            .background {
                // A MATERIAL, not a tint. These sit over a full-screen map, and
                // at 14% white the unselected ones vanished completely against
                // anything pale — "Regional" was unreadable over open country.
                // A material keeps them legible on whatever is underneath.
                Capsule().fill(isSelected ? AnyShapeStyle(.white)
                                          : AnyShapeStyle(.thinMaterial))
            }
            .overlay {
                // The focus ring, drawn rather than inherited: the default
                // tvOS lift animates the whole button and at this size reads
                // as a wobble instead of a cursor.
                Capsule().strokeBorder(.white.opacity(isFocused ? 0.95 : 0), lineWidth: 4)
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}
