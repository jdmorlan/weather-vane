//
//  PeriodBrush.swift  (macOS)
//
//  Saying WHICH STRETCH OF THE YEAR a question is about, by drawing it.
//
//  The menu this replaces offered twelve months and four seasons over a model
//  that has always accepted any two `MM-dd` values — including a pair that runs
//  backwards through New Year. A pattern that starts in October and lets go in
//  March was expressible and unsayable.
//
//  Two things decide the whole design:
//
//  The year is a CYCLE, so a window has no natural end. Dragging an edge past
//  the other doesn't clamp or flip — the window just keeps growing around the
//  ring. That falls out of holding a start and a LENGTH rather than a start and
//  an end, which is why nothing here special-cases wrapping.
//
//  The AXIS is not a cycle. January is pinned to the left edge and December to
//  the right, always, because the curve this control sits above is drawn on
//  exactly that axis and two calendars in one column that disagree about where
//  January is are worse than no picture at all. So a wrapping window arrives on
//  screen in two pieces, and the work is making those two pieces read as one
//  window: matching fill, a chevron off each cut edge, and a sentence saying so.
//

import SwiftUI
import WeatherKit


// MARK: - The control

struct PeriodBrush: View {

    /// `nil` is "any date" — no scope at all, not a window that happens to be a
    /// year long. The distinction is load-bearing downstream: the seasonal
    /// curve is only computed for an unscoped query.
    @Binding var period: WeatherPeriod?

    // Tightened 2026-08-17: the band was 54pt tall with 24 above it, and none of that height carried
    // information — the strip is a horizontal instrument, so its height is only ever a drag target and a
    // place for labels. What sets the floor is the edge PILL below the band, not the band itself.
    /// Taller only when there's a window to hold: the extra room below the band exists for the edge
    /// PILLS, and reserving it while nothing is selected was 24pt of blank grey.
    private var stripHeight: CGFloat { selection == nil ? 62 : 86 }
    private static let bandTop: CGFloat = 14
    private static let bandHeight: CGFloat = 38
    private var bandBottom: CGFloat { Self.bandTop + Self.bandHeight }

    /// The visible span of the year, in days. Fenced inside `0...dayCount`, so
    /// zooming in can never pan January off the left edge — it can only put a
    /// magnifier over part of a year whose ends stay where they are.
    @State private var viewStart: Double = 0
    @State private var viewEnd: Double = Double(YearAxis.dayCount)

    @State private var drag: Drag?
    /// THE WINDOW WHILE YOUR MOUSE IS DOWN, held locally.
    ///
    /// Dragging used to write the binding on every frame, and the binding is the QUERY — so each frame
    /// invalidated the whole Explore page and re-evaluated the headline, the calendar, the month profile,
    /// the streaks and the day list. Debouncing the archive lookup didn't help, because the lookup was
    /// never the expensive part; the view churn was. (Symptom: a drag that beachballed, ignored the first
    /// press, and then resized when you tried again.)
    ///
    /// So a drag now moves LOCAL state — the canvas redraws, nothing else does — and the query is written
    /// once, on release. Which is also what every native range control does.
    @State private var live: (start: Int, length: Int)?
    /// Which edge's date is being typed, if either.
    @State private var editingEdge: Edge?
    @State private var typed = ""
    @State private var zoomBase: (start: Double, end: Double)?

    private enum Drag {
        /// Resizing pins the OPPOSITE edge and lets length run around the ring.
        case edge(anchor: Int, movingEnd: Bool)
        case shift(grabOffset: Double)
    }

    // MARK: Reading and writing the period

    private var selection: (start: Int, length: Int)? {
        // Mid-drag, the local window is the truth.
        if let live { return live }
        guard let period,
              let start = YearAxis.day(of: period.start),
              let end = YearAxis.day(of: period.endExclusive) else { return nil }
        // start == end means the window closed where it opened: a whole year.
        return (start, start == end ? YearAxis.dayCount : YearAxis.wrap(end - start))
    }

    private var wraps: Bool {
        guard let selection else { return false }
        return selection.start + selection.length > YearAxis.dayCount
    }

    /// The pieces the fixed axis forces the window into — one, or two when it
    /// runs through the year end.
    private var pieces: [(Int, Int)] {
        guard let selection else { return [] }
        let end = selection.start + selection.length
        return end <= YearAxis.dayCount
            ? [(selection.start, end)]
            : [(selection.start, YearAxis.dayCount), (0, end - YearAxis.dayCount)]
    }

    /// While `live` is set this only moves the local window; `commitWindow` is what reaches the query.
    private func setWindow(start: Int, length: Int) {
        let start = YearAxis.wrap(start)
        let length = max(1, min(YearAxis.dayCount, length))
        if drag != nil || live != nil {
            live = (start, length)
            return
        }
        write(start: start, length: length)
    }

    private func write(start: Int, length: Int) {
        let last = YearAxis.label(start + length - 1)
        period = WeatherPeriod(name: "\(YearAxis.label(start)) – \(last)",
                               start: YearAxis.monthDay(of: start),
                               endExclusive: YearAxis.monthDay(of: start + length),
                               kind: .custom)
    }

    /// One write per drag, on release.
    private func commitWindow() {
        defer { live = nil }
        guard let live else { return }
        write(start: live.start, length: live.length)
    }

    // MARK: Geometry

    private var span: Double { viewEnd - viewStart }
    private var isZoomed: Bool { span < Double(YearAxis.dayCount) - 0.5 }

    private func x(_ day: Double, _ width: CGFloat) -> CGFloat {
        CGFloat((day - viewStart) / span) * width
    }
    private func day(at x: CGFloat, _ width: CGFloat) -> Double {
        viewStart + Double(x / max(width, 1)) * span
    }

    private func clampView() {
        var visible = max(21, min(Double(YearAxis.dayCount), span))
        var center = (viewStart + viewEnd) / 2
        center = max(visible / 2, min(Double(YearAxis.dayCount) - visible / 2, center))
        if visible >= Double(YearAxis.dayCount) { center = Double(YearAxis.dayCount) / 2; visible = Double(YearAxis.dayCount) }
        viewStart = center - visible / 2
        viewEnd = center + visible / 2
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            strip
            if isZoomed { overview }
            fields
        }
    }

    private var strip: some View {
        Canvas { context, size in
            drawStrip(context, size)
        }
        .frame(height: stripHeight)
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { measuredWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, new in measuredWidth = new }
        })
        .contentShape(Rectangle())
        .gesture(brushGesture)
        .gesture(zoomGesture)
        .overlay(alignment: .topLeading) { pills }
        // ONE popover, hosted by the strip.
        //
        // It was attached to each pill instead — and the pills are rebuilt on every frame of a drag, so
        // every frame stood up two popover hosts. That beachballed the drag before it moved. A popover is
        // heavy AppKit machinery; it belongs on something that exists once, with state deciding its
        // content, not on a view that's re-created 60 times a second.
        .popover(isPresented: Binding(get: { editingEdge != nil },
                                      set: { if !$0 { editingEdge = nil } }),
                 attachmentAnchor: .rect(.rect(editorAnchor)),
                 arrowEdge: .bottom) {
            HStack(spacing: 6) {
                Text(editingEdge == .end ? "Through" : "From").font(.caption).foregroundStyle(.secondary)
                TextField("Mar 21", text: $typed)
                    .textFieldStyle(.roundedBorder).frame(width: 96)
                    .onSubmit(commitTypedDate)
            }
            .padding(12)
        }
    }

    /// Where the editor points — the handle whose date is being typed.
    private var editorAnchor: CGRect {
        guard let selection, measuredWidth > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let day = editingEdge == .end ? selection.start + selection.length : selection.start
        return CGRect(x: x(Double(day), measuredWidth) - 1, y: bandBottom, width: 2, height: 18)
    }

    private func commitTypedDate() {
        defer { editingEdge = nil }
        guard let parsed = YearAxis.parse(typed) else { return }
        editingEdge == .end ? moveClosingEdge(to: parsed) : moveOpeningEdge(to: parsed)
    }

    /// The two date readouts, as buttons. Clicking one opens a field over it — you type on the label that
    /// was already showing the date, which is why the FROM/THROUGH row underneath could go: it was a
    /// second copy of these two values, in a place with no relationship to the edge it moved.
    @ViewBuilder private var pills: some View {
        if let selection, measuredWidth > 0 {
            let closing = selection.start + selection.length
            let startX = x(Double(selection.start), measuredWidth)
            let endX = x(Double(closing), measuredWidth)
            ZStack(alignment: .topLeading) {
                pill(day: selection.start, at: startX, toTheLeft: true, edge: .start)
                pill(day: closing - 1, at: endX, toTheLeft: false, edge: .end)
            }
            .frame(width: measuredWidth, alignment: .topLeading)
            .opacity(drag == nil ? 1 : 0)       // the canvas draws the moving window; these can wait
            .allowsHitTesting(drag == nil)      // never steal a drag that's in progress
        }
    }

    private enum Edge { case start, end }

    private func pill(day: Int, at x: CGFloat, toTheLeft: Bool, edge: Edge) -> some View {
        let label = YearAxis.label(day)
        return Button {
            typed = label
            editingEdge = edge
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor))
        }
        .buttonStyle(.plain)
        // Positioned by the same maths the canvas draws with, so the readout hangs under its own handle
        // and never off the end of the strip.
        .offset(x: max(2, min(measuredWidth - 74, toTheLeft ? x - 72 : x + 5)), y: bandBottom + 6)
    }

    /// The whole year, small, while the strip is zoomed into part of it — so a magnified window still
    /// says where it sits. Drag it to pan.
    private var overview: some View {
        Canvas { context, size in
            drawOverview(context, size)
        }
        .frame(height: 26)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            let visible = span
            let center = Double(value.location.x / max(measuredWidth, 1)) * Double(YearAxis.dayCount)
            viewStart = center - visible / 2
            viewEnd = center + visible / 2
            clampView()
        })
    }

    // MARK: Drawing

    private func drawStrip(_ context: GraphicsContext, _ size: CGSize) {
        let width = size.width
        let band = CGRect(x: 0, y: Self.bandTop, width: width, height: Self.bandHeight)

        for (index, month) in YearAxis.months.enumerated() {
            let x0 = x(Double(YearAxis.monthStart[index]), width)
            let x1 = x(Double(YearAxis.monthStart[index] + month.length), width)
            guard x1 > -40, x0 < width + 40 else { continue }

            context.fill(Path(CGRect(x: x0, y: band.minY, width: x1 - x0, height: band.height)),
                         with: .color(.primary.opacity(index.isMultiple(of: 2) ? 0.055 : 0.03)))
            context.fill(Path(CGRect(x: x0, y: band.minY, width: 1, height: band.height)),
                         with: .color(.primary.opacity(0.09)))

            if x1 - x0 > 22 {
                context.draw(context.resolve(Text(month.name.uppercased())
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)),
                             at: CGPoint(x: (x0 + x1) / 2, y: Self.bandTop - 9), anchor: .center)
            }
        }

        if span < 130 {
            let daily = span < 46
            for dayIndex in 0..<YearAxis.dayCount {
                let dayOfMonth = YearAxis.monthAndDay(of: dayIndex).day
                guard daily || dayOfMonth % 7 == 1 else { continue }
                let tick = x(Double(dayIndex), width)
                guard tick > -20, tick < width + 20 else { continue }
                context.fill(Path(CGRect(x: tick, y: band.maxY, width: 1, height: 4)),
                             with: .color(.primary.opacity(0.12)))
                if daily, dayOfMonth % 5 == 0 {
                    context.draw(context.resolve(Text("\(dayOfMonth)")
                        .font(.system(size: 9)).foregroundStyle(.quaternary)),
                                 at: CGPoint(x: tick, y: band.maxY + 11), anchor: .center)
                }
            }
        }

        for (from, to) in pieces {
            let x0 = x(Double(from), width), x1 = x(Double(to), width)
            guard x1 > -60, x0 < width + 60 else { continue }
            let rect = CGRect(x: x0, y: band.minY, width: x1 - x0, height: band.height)
            context.fill(Path(rect), with: .color(.accentColor.opacity(0.2)))
            context.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 2)),
                         with: .color(.accentColor.opacity(0.55)))
            context.fill(Path(CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2)),
                         with: .color(.accentColor.opacity(0.55)))
        }

        // A cut edge is not the end of the window — it's the year running out.
        if wraps {
            if viewEnd >= Double(YearAxis.dayCount) - 0.5 { chevrons(context, at: x(Double(YearAxis.dayCount), width) - 12, direction: 1) }
            if viewStart <= 0.5 { chevrons(context, at: x(0, width) + 12, direction: -1) }
            context.draw(context.resolve(Text("ONE WINDOW, CONTINUING ACROSS THE YEAR END")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.accentColor.opacity(0.7))),
                         at: CGPoint(x: width / 2, y: band.maxY + 30), anchor: .center)
        }

        if let selection {
            let dragging = drag != nil
            let closing = selection.start + selection.length
            handle(context, at: x(Double(selection.start), width), width: width,
                   reading: dragging ? YearAxis.label(selection.start) : nil, toTheLeft: true)
            handle(context, at: x(Double(closing), width), width: width,
                   reading: dragging ? YearAxis.label(closing - 1) : nil, toTheLeft: false)
        }

        context.stroke(Path(band), with: .color(.primary.opacity(0.1)))
    }

    private func chevrons(_ context: GraphicsContext, at x: CGFloat, direction: CGFloat) {
        let midY = Self.bandTop + Self.bandHeight / 2
        for step in 0..<2 {
            let cx = x + direction * CGFloat(step) * 7
            var path = Path()
            path.move(to: CGPoint(x: cx - direction * 3, y: midY - 5))
            path.addLine(to: CGPoint(x: cx + direction * 3, y: midY))
            path.addLine(to: CGPoint(x: cx - direction * 3, y: midY + 5))
            context.stroke(path, with: .color(.accentColor.opacity(0.8)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }

    /// The GRAB — line and caps only. The date readout that used to be drawn here is now a real view
    /// (`pill`), because a canvas drawing can be looked at but not clicked, and the readout is the obvious
    /// place to type a date: it's already showing the one you'd be replacing.
    private func handle(_ context: GraphicsContext, at x: CGFloat, width: CGFloat,
                        reading: String? = nil, toTheLeft: Bool = true) {
        guard x > -30, x < width + 30 else { return }
        context.fill(Path(CGRect(x: x - 1.5, y: Self.bandTop - 5, width: 3, height: Self.bandHeight + 10)),
                     with: .color(.accentColor))
        for y in [Self.bandTop - 5, bandBottom + 5] {
            context.fill(Path(ellipseIn: CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7)),
                         with: .color(.accentColor))
        }
        // The date readout is a real VIEW at rest (so it can be clicked and typed into) and a DRAWING while
        // dragging (so a frame costs nothing). Same pill either way; the two never show at once.
        guard let reading else { return }
        let resolved = context.resolve(Text(reading).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white))
        let pillWidth = resolved.measure(in: CGSize(width: 200, height: 20)).width + 14
        var pillX = toTheLeft ? x - pillWidth - 5 : x + 5
        pillX = max(2, min(width - pillWidth - 2, pillX))     // never let a readout fall off
        let pill = CGRect(x: pillX, y: bandBottom + 8, width: pillWidth, height: 17)
        context.fill(Path(roundedRect: pill, cornerRadius: 9), with: .color(.accentColor))
        context.draw(resolved, at: CGPoint(x: pill.midX, y: pill.midY), anchor: .center)
    }

    /// The whole year, always, so zooming in never costs the answer to "where
    /// am I". Drag it to pan.
    private func drawOverview(_ context: GraphicsContext, _ size: CGSize) {
        let width = size.width
        let position = { (day: Double) in CGFloat(day / Double(YearAxis.dayCount)) * width }
        let track = CGRect(x: 0, y: 5, width: width, height: 12)

        context.fill(Path(track), with: .color(.primary.opacity(0.05)))
        for start in YearAxis.monthStart.dropFirst() {
            context.fill(Path(CGRect(x: position(Double(start)), y: track.minY, width: 1, height: track.height)),
                         with: .color(.primary.opacity(0.08)))
        }
        for (from, to) in pieces {
            let x0 = position(Double(from)), x1 = position(Double(to))
            context.fill(Path(CGRect(x: x0, y: track.minY, width: max(1, x1 - x0), height: track.height)),
                         with: .color(.accentColor.opacity(0.35)))
        }
        let window = CGRect(x: position(viewStart) + 0.75, y: track.minY - 2.25,
                            width: max(3, position(viewEnd) - position(viewStart)) - 1.5,
                            height: track.height + 4.5)
        context.stroke(Path(roundedRect: window, cornerRadius: 3),
                       with: .color(.accentColor), lineWidth: 1.5)

        context.draw(context.resolve(Text("JAN 1").font(.system(size: 9)).foregroundStyle(.quaternary)),
                     at: CGPoint(x: 0, y: track.maxY + 5), anchor: .topLeading)
        context.draw(context.resolve(Text("DEC 31").font(.system(size: 9)).foregroundStyle(.quaternary)),
                     at: CGPoint(x: width, y: track.maxY + 5), anchor: .topTrailing)
    }

    // MARK: Gestures

    private var brushGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if drag == nil {
                    // Seed the local window from whatever the query currently holds, so the first frame
                    // has something to move and the binding is left alone until release.
                    live = selection
                    drag = beginDrag(at: value.startLocation.x, width: measuredWidth)
                }
                apply(drag, at: value.location.x, width: measuredWidth)
            }
            .onEnded { _ in
                drag = nil
                commitWindow()
            }
    }

    /// A gesture arrives with no idea how wide the thing it's on is, and every
    /// hit test here is in day-space. The canvas measures itself once per
    /// layout and the gestures read that.
    @State private var measuredWidth: CGFloat = 1

    private func beginDrag(at x: CGFloat, width: CGFloat) -> Drag {
        let grab: CGFloat = 7
        if let selection {
            let opening = self.x(Double(selection.start), width)
            let closing = self.x(Double(selection.start + selection.length), width)
            if abs(x - opening) <= grab {
                return .edge(anchor: YearAxis.wrap(selection.start + selection.length), movingEnd: false)
            }
            if abs(x - closing) <= grab {
                return .edge(anchor: selection.start, movingEnd: true)
            }
            for (from, to) in pieces where x > self.x(Double(from), width) && x < self.x(Double(to), width) {
                return .shift(grabOffset: day(at: x, width) - Double(selection.start))
            }
        }
        // Drawing a fresh window: the press is the opening edge.
        let start = YearAxis.wrap(Int(day(at: x, width).rounded()))
        setWindow(start: start, length: 1)
        return .edge(anchor: start, movingEnd: true)
    }

    private func apply(_ drag: Drag?, at x: CGFloat, width: CGFloat) {
        guard let drag else { return }
        let pointed = Int(day(at: x, width).rounded())
        switch drag {
        case .shift(let grabOffset):
            guard let selection else { return }
            setWindow(start: Int((day(at: x, width) - grabOffset).rounded()), length: selection.length)
        case .edge(let anchor, let movingEnd):
            if movingEnd {
                setWindow(start: anchor, length: YearAxis.wrap(pointed - anchor) + 1)
            } else {
                let start = YearAxis.wrap(pointed)
                let length = YearAxis.wrap(anchor - start)
                setWindow(start: start, length: length == 0 ? YearAxis.dayCount : length)
            }
        }
    }

    /// Pinch, not scroll. A scroll-wheel zoom inside the Explore page would have
    /// to steal wheel events from the scroll view it lives in, and get the
    /// hand-back exactly right; pinch is unambiguous and already the Mac gesture
    /// for this.
    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = zoomBase ?? (viewStart, viewEnd)
                if zoomBase == nil { zoomBase = base }
                let at = base.start + Double(value.startLocation.x / max(measuredWidth, 1)) * (base.end - base.start)
                let scale = 1 / max(0.05, value.magnification)
                viewStart = at - (at - base.start) * scale
                viewEnd = at + (base.end - at) * scale
                clampView()
            }
            .onEnded { _ in zoomBase = nil }
    }

    // MARK: Fields and presets

    /// Only the zoom escape hatch remains down here. FROM/THROUGH went away because the date PILLS carry
    /// the same two values, attached to the edges they move — a second copy in a row underneath was one
    /// more place for "any date" to be written and one more thing to keep in sync.
    @ViewBuilder private var fields: some View {
        if isZoomed {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                link("fit year") { viewStart = 0; viewEnd = Double(YearAxis.dayCount) }
            }
        }
    }

    /// Read by the scope card's header — the one place the window's extent is stated.
    var lengthLabel: String {
        guard let selection else { return "any date" }
        return "\(selection.length) days\(wraps ? " · wraps" : "")"
    }

    /// Typing an edge pins the other one, exactly like dragging it does.
    private func moveOpeningEdge(to start: Int) {
        let closing = selection.map { $0.start + $0.length } ?? start + 1
        let length = YearAxis.wrap(closing - start)
        setWindow(start: start, length: length == 0 ? YearAxis.dayCount : length)
    }

    private func moveClosingEdge(to last: Int) {
        let start = selection?.start ?? last
        setWindow(start: start, length: YearAxis.wrap(last - start) + 1)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(.tertiary)
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain).font(.callout).foregroundStyle(Color.accentColor)
    }

}
