//
//  TVBoundaries.swift  (tvOS)
//
//  The home state's counties, and the state's own edge, drawn over every map
//  view.
//
//  COUNTIES BECAUSE THE OFFICES SPEAK IN THEM. "A Slight risk for Hamilton and
//  Coryell counties" can only be placed with the lines on the map. The same
//  bundled Census file as the Mac (see `CountyBoundaries`), but only the home
//  state's counties: from a sofa that is the whole question, and it is a tenth
//  of the lines to draw.
//
//  THE STATE'S EDGE, BUILT FROM ITS COUNTIES. There is no state outline in the
//  bundle, and the base map's own border is a faint grey that vanishes under an
//  outlook. But a county edge that two counties share is inside the state, and
//  one that only one county has is the state's border (or its coast). The
//  Census file's neighbours share their vertices exactly, so counting each edge
//  and keeping those seen once gives the outline with no second file.
//

import Foundation
import WeatherKit

@MainActor
final class TVBoundaries: ObservableObject {
    @Published private(set) var counties: BoundarySet?
    @Published private(set) var outline: BoundarySet?
    private var loadedFor: String?

    func load(home: GeoPoint?) async {
        guard let home else { return }
        let key = "\(home.latitude),\(home.longitude)"
        guard loadedFor != key else { return }
        loadedFor = key
        // A quarter of a million points decoded, a few thousand kept: off the
        // main thread, and the rest dropped before anything is drawn.
        let built = await Task.detached(priority: .utility) { () -> (BoundarySet, BoundarySet)? in
            guard let all = try? CountyBoundaries.load(),
                  let state = CountyBoundaries.county(containing: home, in: all)?.state else { return nil }
            let mine = all.filter { $0.state == state }
            let rings = mine.flatMap(\.rings)
            return (BoundarySet(id: "counties-\(state)", rings: rings),
                    BoundarySet(id: "state-\(state)", rings: Self.edge(of: rings), closed: false))
        }.value
        guard let built else { loadedFor = nil; return }
        counties = built.0
        outline = built.1
    }

    /// The edges only one ring has, joined back into lines.
    nonisolated static func edge(of rings: [[GeoPoint]]) -> [[GeoPoint]] {
        struct Vertex: Hashable { let lat: Int64, lon: Int64 }
        func v(_ p: GeoPoint) -> Vertex {
            Vertex(lat: Int64((p.latitude * 1e6).rounded()), lon: Int64((p.longitude * 1e6).rounded()))
        }
        struct Edge: Hashable { let a: Vertex, b: Vertex }
        func edge(_ a: Vertex, _ b: Vertex) -> Edge {
            (a.lat, a.lon) < (b.lat, b.lon) ? Edge(a: a, b: b) : Edge(a: b, b: a)
        }

        var count: [Edge: Int] = [:]
        var point: [Vertex: GeoPoint] = [:]
        for ring in rings where ring.count > 2 {
            let vs = ring.map(v)
            for (i, p) in ring.enumerated() { point[vs[i]] = p }
            for i in vs.indices {
                let a = vs[i], b = vs[(i + 1) % vs.count]
                if a != b { count[edge(a, b), default: 0] += 1 }
            }
        }

        // Join the lone edges end to end, so the border is a few long lines
        // rather than thousands of two-point strokes.
        var next: [Vertex: [Vertex]] = [:]
        for (e, n) in count where n == 1 {
            next[e.a, default: []].append(e.b)
            next[e.b, default: []].append(e.a)
        }
        var used = Set<Edge>()
        var lines: [[GeoPoint]] = []
        // Endpoints first (odd degree), then whatever loops remain.
        let starts = next.keys.sorted { (next[$0]!.count % 2, $0.lat, $0.lon) > (next[$1]!.count % 2, $1.lat, $1.lon) }
        for start in starts {
            while let first = next[start]?.first(where: { !used.contains(edge(start, $0)) }) {
                var line = [start]
                var here = start, there = first
                while true {
                    used.insert(edge(here, there))
                    line.append(there)
                    guard let onward = next[there]?.first(where: { !used.contains(edge(there, $0)) }) else { break }
                    here = there; there = onward
                }
                lines.append(line.compactMap { point[$0] })
            }
        }
        return lines
    }
}
