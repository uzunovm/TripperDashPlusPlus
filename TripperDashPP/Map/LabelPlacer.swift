//
//  LabelPlacer.swift
//  TripperDashPP
//
//  Picks which vector-map labels (place, road, water names) show on the
//  dash frame, and keeps that choice stable from frame to frame.
//
//  At 4 fps a label that appears, vanishes and reappears is both
//  distracting and expensive (every change is new pixels for the H.264
//  encoder), so placement has hysteresis:
//    1. Labels shown last frame stay while they're still on the glass,
//       clear of the exclusions, and not hit by a higher-priority kept label.
//    2. At most `maxNewPerFrame` new label joins per frame, up to `maxLabels`.
//
//  Labels are horizontal and upright, centred on a fixed point of their
//  feature (`VectorLabel.point`), so they ride with the map without
//  sliding along the road. Pure value type — the frame code supplies the
//  screen points and text sizes, the tests drive it directly.
//

import CoreGraphics

nonisolated struct LabelPlacer: Sendable {
    /// One label that could be drawn this frame.
    struct Candidate: Sendable, Equatable {
        /// Stable across frames: text + kind + world anchor.
        var id: String
        /// Kind + text: one street crosses several tiles and each tile
        /// carries its own name point, so a name shows at most once.
        var name: String
        var priority: Int
        /// Label centre on the frame.
        var center: CGPoint
        /// Text image size (halo included).
        var size: CGSize

        var rect: CGRect {
            CGRect(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded(),
                   width: size.width, height: size.height)
        }
    }

    /// Where labels may go.
    struct Area: Sendable {
        var glassCenter: CGPoint
        var glassRadius: CGFloat
        /// Discs no label may touch (the dash's turn card while navigating).
        var discs: [(center: CGPoint, radius: CGFloat)]
        /// Rects no label may touch (puck, attribution).
        var rects: [CGRect]
        /// Gap kept from everything above, and between labels.
        var clearance: CGFloat = 4

        func allows(_ r: CGRect) -> Bool {
            // On the glass: every corner inside the inset circle (the
            // circle is convex, so the whole rect is).
            let gr = glassRadius - clearance
            for p in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                      CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)] {
                if hypot(p.x - glassCenter.x, p.y - glassCenter.y) > gr { return false }
            }
            for d in discs {
                // Nearest point of the rect to the disc centre.
                let nx = min(max(d.center.x, r.minX), r.maxX)
                let ny = min(max(d.center.y, r.minY), r.maxY)
                if hypot(nx - d.center.x, ny - d.center.y) < d.radius + clearance { return false }
            }
            let padded = r.insetBy(dx: -clearance, dy: -clearance)
            return !rects.contains { $0.intersects(padded) }
        }
    }

    static let maxLabels = 6
    static let maxNewPerFrame = 1

    /// Ids shown last frame.
    private(set) var shown: [String] = []

    /// Forget everything (labels switched off, palette or renderer change).
    mutating func reset() { shown = [] }

    /// This frame's labels, highest priority first.
    mutating func place(_ candidates: [Candidate], in area: Area) -> [Candidate] {
        var byId: [String: Candidate] = [:]
        for c in candidates where byId[c.id] == nil { byId[c.id] = c }

        var placed: [Candidate] = []
        func fits(_ c: Candidate) -> Bool {
            let r = c.rect
            guard area.allows(r) else { return false }
            let padded = r.insetBy(dx: -area.clearance, dy: -area.clearance)
            return !placed.contains { $0.rect.intersects(padded) || $0.name == c.name }
        }

        // 1. Keep last frame's labels, higher priority first.
        let kept = shown.compactMap { byId[$0] }
            .sorted { $0.priority != $1.priority ? $0.priority > $1.priority : $0.id < $1.id }
        for c in kept where placed.count < Self.maxLabels && fits(c) {
            placed.append(c)
        }

        // 2. Add new ones: priority, then nearest the glass centre.
        let shownSet = Set(placed.map(\.id))
        let fresh = byId.values.filter { !shownSet.contains($0.id) }.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            let da = hypot($0.center.x - area.glassCenter.x, $0.center.y - area.glassCenter.y)
            let db = hypot($1.center.x - area.glassCenter.x, $1.center.y - area.glassCenter.y)
            return da != db ? da < db : $0.id < $1.id
        }
        var added = 0
        for c in fresh where added < Self.maxNewPerFrame && placed.count < Self.maxLabels {
            if fits(c) {
                placed.append(c)
                added += 1
            }
        }

        shown = placed.map(\.id)
        return placed
    }

    /// Frame-relative label candidates from the tiles: each label's world
    /// anchor → puck-relative flat offset (heading-up, `zoom`), then
    /// `project` (nil = off screen / in the 3D sky). `size` measures the
    /// text (cached by the caller).
    static func candidates(tiles: [VectorTile], center: CGPoint, headingDegrees: Double, zoom: CGFloat,
                           frame: CGSize,
                           project: (CGPoint) -> CGPoint?,
                           size: (VectorLabel) -> CGSize?) -> [Candidate] {
        let k = Double(VectorProjection.scale(zoom: zoom))
        let th = -headingDegrees * .pi / 180
        let cosT = cos(th), sinT = sin(th)
        let bounds = CGRect(origin: .zero, size: frame)
        var out: [Candidate] = []
        for t in tiles {
            let ox = Double(t.x) * VectorProjection.tileUnits
            let oy = Double(t.y) * VectorProjection.tileUnits
            let unit = VectorProjection.tileUnits / Double(t.extent)
            for l in t.labels {
                let wx = ox + Double(l.point.x) * unit
                let wy = oy + Double(l.point.y) * unit
                let dx = (wx - Double(center.x)) * k
                let dy = (wy - Double(center.y)) * k
                let flat = CGPoint(x: dx * cosT - dy * sinT, y: dx * sinT + dy * cosT)
                guard let p = project(flat), bounds.contains(p), let s = size(l) else { continue }
                let name = "\(l.kind.rawValue)|\(l.text)"
                out.append(Candidate(id: "\(name)|\(Int(wx))|\(Int(wy))", name: name,
                                     priority: l.priority, center: p, size: s))
            }
        }
        return out
    }
}
