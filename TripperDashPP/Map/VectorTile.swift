//
//  VectorTile.swift
//  TripperDashPP
//
//  A decoded OpenMapTiles z14 tile in draw-ready form: one pre-built
//  CGPath per feature class (in tile units, 0…extent, y-down) plus the
//  label candidates the tile owns. Built once off the main actor when the
//  tile is loaded; the renderer only strokes / fills the paths under a
//  transform, so a frame costs no per-feature work.
//
//  What's kept is deliberately little — the dash is a 526×300 panel seen
//  at a glance: water, wood / grass / parks, residential tint, roads by
//  class, main railways. Buildings, house numbers and POIs are skipped at
//  decode (`MVTDecoder.decode(keepLayers:)`); tunnels, paths, ferries and
//  construction roads are dropped here.
//

import CoreGraphics
import Foundation

/// Draw classes in back-to-front order (areas first, then lines from
/// least to most important, so a motorway is never painted over by a
/// service road).
nonisolated enum VectorFeatureClass: Int, CaseIterable, Sendable {
    // Areas (filled)
    case residential, grass, wood, water
    // Lines (stroked, casing + fill)
    case waterway, rail, track, service, minor, tertiary, secondary, primary, trunk, motorway

    var isArea: Bool { rawValue <= VectorFeatureClass.water.rawValue }
    var isRoad: Bool { rawValue >= VectorFeatureClass.track.rawValue }

    /// Minor classes the renderer may drop when zoomed out or over budget.
    var isMinorRoad: Bool { self == .track || self == .service || self == .minor }
}

nonisolated struct VectorLabel: Sendable, Equatable {
    enum Kind: Int, Sendable {
        case city, town, village, suburb, locality, water, road, roadRef
    }

    var text: String
    var kind: Kind
    /// Higher = placed first, wins collisions.
    var priority: Int
    /// Anchor in tile units — a fixed point on the feature, so the label
    /// never slides along the road between frames.
    var point: CGPoint
}

/// Immutable after `build`; CGPath is immutable and thread-safe.
nonisolated final class VectorTile: @unchecked Sendable {
    let z: Int
    let x: Int
    let y: Int
    let extent: Int
    /// Indexed by `VectorFeatureClass.rawValue`; nil = nothing of that class.
    let paths: [CGPath?]
    let labels: [VectorLabel]
    /// Rough memory cost, for the NSCache limit.
    let cost: Int

    init(z: Int, x: Int, y: Int, extent: Int, paths: [CGPath?], labels: [VectorLabel], cost: Int) {
        self.z = z; self.x = x; self.y = y
        self.extent = extent
        self.paths = paths
        self.labels = labels
        self.cost = cost
    }

    func path(_ c: VectorFeatureClass) -> CGPath? { paths[c.rawValue] }

    /// Layers the builder reads; everything else is skipped by the decoder.
    static let layers: Set<String> = [
        "water", "waterway", "landcover", "landuse", "park",
        "transportation", "transportation_name", "place", "water_name",
    ]

    /// Douglas–Peucker tolerance in tile units. A z14 tile (4096 units) is
    /// 512 px at the base z15 scale and ~770 px at the closest zoom, so
    /// 2 units ≈ 0.4 px there — invisible, and it drops most vertices of
    /// gently curving roads.
    static let simplifyTolerance: CGFloat = 2

    static func build(from data: Data, z: Int, x: Int, y: Int) throws -> VectorTile {
        build(layers: try MVTDecoder.decode(data, keepLayers: layers), z: z, x: x, y: y)
    }

    static func build(layers: [MVTLayer], z: Int, x: Int, y: Int) -> VectorTile {
        let builders = VectorFeatureClass.allCases.map { _ in CGMutablePath() }
        var used = [Bool](repeating: false, count: VectorFeatureClass.allCases.count)
        var labels: [VectorLabel] = []
        var points = 0
        let extent = layers.first?.extent ?? 4096

        func add(_ c: VectorFeatureClass, _ f: MVTFeature) {
            let path = builders[c.rawValue]
            for part in f.parts {
                let pts = simplify(part.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) },
                                   tolerance: simplifyTolerance)
                guard pts.count >= (c.isArea ? 4 : 2) else { continue }
                path.addLines(between: pts)
                if c.isArea { path.closeSubpath() }
                points += pts.count
                used[c.rawValue] = true
            }
        }

        for layer in layers {
            let ext = CGFloat(layer.extent)
            for f in layer.features {
                switch layer.name {
                case "water":
                    if f.type == .polygon, f["brunnel"]?.stringValue != "tunnel" { add(.water, f) }
                case "waterway":
                    if f.type == .lineString, f["brunnel"]?.stringValue != "tunnel",
                       ["river", "canal"].contains(f["class"]?.stringValue ?? "") { add(.waterway, f) }
                case "landcover":
                    guard f.type == .polygon else { continue }
                    switch f["class"]?.stringValue {
                    case "wood": add(.wood, f)
                    case "grass": add(.grass, f)
                    default: break
                    }
                case "landuse":
                    if f.type == .polygon, f["class"]?.stringValue == "residential" { add(.residential, f) }
                case "park":
                    if f.type == .polygon { add(.grass, f) }
                case "transportation":
                    guard f.type == .lineString,
                          let c = roadClass(f) else { continue }
                    add(c, f)
                case "transportation_name":
                    if let l = roadLabel(f, extent: ext) { labels.append(l) }
                case "place":
                    if let l = placeLabel(f, extent: ext) { labels.append(l) }
                case "water_name":
                    if let l = waterLabel(f, extent: ext) { labels.append(l) }
                default:
                    break
                }
            }
        }
        let paths: [CGPath?] = zip(builders, used).map { $1 ? ($0.copy() ?? $0) : nil }
        let cost = points * 16 + labels.count * 64 + 1024
        return VectorTile(z: z, x: x, y: y, extent: extent, paths: paths, labels: labels, cost: cost)
    }

    /// OpenMapTiles `transportation.class` → draw class; nil = not drawn.
    static func roadClass(_ f: MVTFeature) -> VectorFeatureClass? {
        if f["brunnel"]?.stringValue == "tunnel" { return nil }
        switch f["class"]?.stringValue {
        case "motorway": return .motorway
        case "trunk": return .trunk
        case "primary": return .primary
        case "secondary": return .secondary
        case "tertiary": return .tertiary
        case "minor": return .minor
        case "service": return .service
        case "track": return .track
        case "rail":
            // Main-line railways only; trams and subways are city clutter.
            let sub = f["subclass"]?.stringValue ?? "rail"
            return sub == "rail" ? .rail : nil
        default:
            return nil   // path, ferry, transit, *_construction, raceway, …
        }
    }

    // MARK: Labels

    /// A label point is owned by the tile it lies in (half-open bounds):
    /// OpenMapTiles repeats name points in every neighbouring tile their
    /// label could reach, so without this each name would appear up to 9×.
    static func owns(_ p: CGPoint, extent: CGFloat) -> Bool {
        p.x >= 0 && p.x < extent && p.y >= 0 && p.y < extent
    }

    static func roadLabel(_ f: MVTFeature, extent: CGFloat) -> VectorLabel? {
        guard f.type == .lineString,
              let anchor = midpoint(ofLongest: f.parts), owns(anchor, extent: extent) else { return nil }
        let cls = f["class"]?.stringValue ?? ""
        let base: Int
        switch cls {
        case "motorway": base = 45
        case "trunk": base = 42
        case "primary": base = 40
        case "secondary": base = 35
        case "tertiary": base = 30
        case "minor": base = 20
        default: return nil   // service, track, path: unnamed in practice / noise
        }
        if let name = f["name"]?.stringValue, !name.isEmpty {
            return VectorLabel(text: name, kind: .road, priority: base, point: anchor)
        }
        if let ref = f["ref"]?.stringValue, !ref.isEmpty, base >= 35 {
            return VectorLabel(text: ref, kind: .roadRef, priority: base, point: anchor)
        }
        return nil
    }

    static func placeLabel(_ f: MVTFeature, extent: CGFloat) -> VectorLabel? {
        guard f.type == .point, let p = f.parts.first?.first,
              let name = f["name"]?.stringValue, !name.isEmpty else { return nil }
        let anchor = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
        guard owns(anchor, extent: extent) else { return nil }
        let kind: VectorLabel.Kind
        let base: Int
        switch f["class"]?.stringValue {
        case "city": kind = .city; base = 100
        case "town": kind = .town; base = 80
        case "village": kind = .village; base = 60
        case "suburb": kind = .suburb; base = 50
        case "hamlet", "neighbourhood", "quarter", "isolated_dwelling", "locality":
            kind = .locality; base = 25
        default: return nil
        }
        // `rank` 1 = most important within its class.
        let rank = Int(f["rank"]?.numberValue ?? 10)
        return VectorLabel(text: name, kind: kind, priority: base - min(rank, 10), point: anchor)
    }

    static func waterLabel(_ f: MVTFeature, extent: CGFloat) -> VectorLabel? {
        guard let name = f["name"]?.stringValue, !name.isEmpty else { return nil }
        let anchor: CGPoint?
        switch f.type {
        case .point: anchor = f.parts.first?.first.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
        case .lineString: anchor = midpoint(ofLongest: f.parts)
        default: anchor = nil
        }
        guard let anchor, owns(anchor, extent: extent) else { return nil }
        return VectorLabel(text: name, kind: .water, priority: 28, point: anchor)
    }

    /// Point halfway along the longest part, by length.
    static func midpoint(ofLongest parts: [[MVTPoint]]) -> CGPoint? {
        func len(_ p: [MVTPoint]) -> CGFloat {
            zip(p, p.dropFirst()).reduce(0) {
                $0 + hypot(CGFloat($1.1.x - $1.0.x), CGFloat($1.1.y - $1.0.y))
            }
        }
        guard let part = parts.max(by: { len($0) < len($1) }), part.count >= 2 else { return nil }
        var left = len(part) / 2
        for (a, b) in zip(part, part.dropFirst()) {
            let seg = hypot(CGFloat(b.x - a.x), CGFloat(b.y - a.y))
            if seg >= left, seg > 0 {
                let t = left / seg
                return CGPoint(x: CGFloat(a.x) + CGFloat(b.x - a.x) * t,
                               y: CGFloat(a.y) + CGFloat(b.y - a.y) * t)
            }
            left -= seg
        }
        return part.last.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
    }

    // MARK: Simplification

    /// Douglas–Peucker, iterative. Keeps the endpoints.
    static func simplify(_ pts: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        let tol2 = tolerance * tolerance
        while let (lo, hi) = stack.popLast() {
            guard hi > lo + 1 else { continue }
            let a = pts[lo], b = pts[hi]
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            var maxD: CGFloat = -1
            var idx = lo
            for i in (lo + 1)..<hi {
                let p = pts[i]
                let d2: CGFloat
                if len2 == 0 {
                    d2 = (p.x - a.x) * (p.x - a.x) + (p.y - a.y) * (p.y - a.y)
                } else {
                    let cross = (p.x - a.x) * dy - (p.y - a.y) * dx
                    d2 = cross * cross / len2
                }
                if d2 > maxD { maxD = d2; idx = i }
            }
            if maxD > tol2 {
                keep[idx] = true
                stack.append((lo, idx))
                stack.append((idx, hi))
            }
        }
        return zip(pts, keep).compactMap { $1 ? $0 : nil }
    }
}
