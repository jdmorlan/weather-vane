//
//  FacingPicker.swift  (Weather)
//
//  Which way the house looks, asked the way a person actually knows it.
//
//  IT WAS A SLIDER, and a slider asks a question nobody can answer. The value it
//  produced — "184°" — reads like precision, but no one knows their house to a
//  degree; they know it faces south. The control was demanding a measurement in
//  order to record a FACT, and the two-degree difference between 184 and 186
//  changes nothing any sentence in this app will ever say.
//
//  So the eight points are the control, laid out as the compass they are: N at
//  the top, SW at the bottom-left, the house in the middle. You answer it by
//  pointing at the answer. Degrees are still reachable — `WindRose` and the
//  facing-relative phrasings work in them, and someone who has stood in the
//  garden with a compass app should be able to say 186 — but they are behind a
//  disclosure, which is the correct rank for a refinement of an answer you have
//  already given.
//
//  UNSET STAYS REACHABLE, which is the one thing the old toggle got right: a
//  facing you cannot clear would make every egocentric phrasing ("the wind is on
//  the back of the house") a claim you never agreed to. Choosing a point is what
//  turns it on — the toggle was a second control for a state the picker already
//  expresses — and Clear is what turns it off.
//

import SwiftUI

struct FacingPicker: View {
    /// Degrees true, or `-1` for unset — `AppSettings.homeFacing`'s own encoding,
    /// bound through rather than translated so there is one representation of
    /// "we don't know" in the app.
    @Binding var degrees: Double

    @State private var fineTuning = false

    /// The eight points, in compass order. Sixteen would be a worse control for
    /// the same reason the slider was: nobody volunteers "west-northwest", and
    /// the person who would has the fine-tune.
    private static let points: [(name: String, degrees: Double)] = [
        ("N", 0), ("NE", 45), ("E", 90), ("SE", 135),
        ("S", 180), ("SW", 225), ("W", 270), ("NW", 315),
    ]

    private var isSet: Bool { degrees >= 0 }

    /// The point a value belongs to, so a fine-tuned 186° still lights up S
    /// rather than leaving the grid looking untouched.
    private var nearest: String? {
        guard isSet else { return nil }
        return Self.points.min {
            Self.separation($0.degrees, degrees) < Self.separation($1.degrees, degrees)
        }?.name
    }

    /// Shortest angle between two bearings. The naive difference makes 359° and
    /// 1° look 358° apart, which would snap a nearly-north house to south.
    private static func separation(_ a: Double, _ b: Double) -> Double {
        let raw = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(raw, 360 - raw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            compass
            if isSet { refinement }
        }
    }

    // MARK: The rose

    private var compass: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow { cell("NW"); cell("N");  cell("NE") }
            GridRow { cell("W");  readout;    cell("E")  }
            GridRow { cell("SW"); cell("S");  cell("SE") }
        }
        .fixedSize()
    }

    private func cell(_ name: String) -> some View {
        let point = Self.points.first { $0.name == name }!
        let picked = nearest == name
        return Button {
            // Snapped to the exact point rather than nudged toward it: clicking
            // S after fine-tuning to 186° means "no, plain south", and leaving
            // the six degrees on would make the button look broken.
            degrees = point.degrees
            fineTuning = false
        } label: {
            Text(name)
                .font(.callout.weight(picked ? .semibold : .regular))
                .frame(width: 54, height: 34)
                .background(picked ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                            in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(picked ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("The front of the house faces \(name)")
    }

    /// The middle of the rose, which is where the house is. It answers back in
    /// the same words you'd use — "faces S" — and only shows the number when the
    /// number is telling you something the letters aren't.
    private var readout: some View {
        VStack(spacing: 1) {
            Image(systemName: "house.fill")
                .font(.caption)
                .foregroundStyle(isSet ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            if isSet {
                Text(isExactPoint ? (nearest ?? "") : "\(Int(degrees))°")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("—").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(width: 54, height: 34)
    }

    private var isExactPoint: Bool {
        isSet && degrees.truncatingRemainder(dividingBy: 45) == 0
    }

    // MARK: Degrees, for whoever wants them

    @ViewBuilder private var refinement: some View {
        HStack(spacing: 10) {
            Text("Faces \(CompassPoint.name(degrees))\(isExactPoint ? "" : " · \(Int(degrees))°")")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(fineTuning ? "Done" : "Fine-tune") {
                withAnimation(.easeInOut(duration: 0.15)) { fineTuning.toggle() }
            }
            .buttonStyle(.link)
            .font(.callout)
            // Clearing lives beside the readout rather than in the grid: it is
            // an answer about the whole question, not a ninth direction.
            Button("Clear") { degrees = -1; fineTuning = false }
                .buttonStyle(.link)
                .font(.callout)
        }

        if fineTuning {
            VStack(alignment: .leading, spacing: 3) {
                Slider(value: $degrees, in: 0...359, step: 1)
                Text("\(Int(degrees))° true — \(CompassPoint.name(degrees))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
