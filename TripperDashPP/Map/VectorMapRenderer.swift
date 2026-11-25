//
//  VectorMapRenderer.swift
//  TripperDashPP
//
//  Draws the vector base map (background, areas, roads) for one frame into
//  a private bitmap, off the main actor, with CoreGraphics only — no Metal,
//  no CoreImage, no map SDK, so it runs on the locked screen like the
//  raster composite stitch does (CLAUDE.md guidelines 4 and 6).
//
//  The geometry is projected with the same convention as the raster path
//  (`MapViewSource.drawProjectedTile`): Y-down canvas, the rider at
//  `anchor`, heading-up rotation, and `zoom` calibrated to the z15 base
//  layer (1 z15 px = 8 units of a 4096-extent z14 tile). The route line,
//  markers and puck are drawn afterwards on the main actor over this
//  bitmap, with that same projection, so they line up exactly.
//
//  Every frame strokes pre-built per-class CGPaths under one transform per
//  tile — no per-feature work — which keeps a dense city frame in the tens
//  of milliseconds and, because nothing is resampled, consecutive frames
//  differ only by the motion itself (better for the H.264 encoder than a
//  bilinearly rotated raster).
//

import CoreGraphics
import CoreLocation
import Foundation

/// Colours and line widths of the vector map. Widths are on-screen px at
/// zoom 1 (≈ 50 km/h city zoom).
nonisolated struct VectorPalette: @unchecked Sendable {
    struct Line {
        var fill: CGColor
        var casing: CGColor?
        var width: CGFloat
    }

    var background: CGColor
    var areas: [VectorFeatureClass: CGColor]
    var lines: [VectorFeatureClass: Line]
    /// Casing width added on top of a line's width (px, both sides together).
    var casingWidth: CGFloat
    var labelInk: CGColor
    var labelHalo: CGColor
    var majorLabelInk: CGColor

    private static func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }

    /// High contrast, few layers. Roads stay well under the 7 px blue route
    /// so the route always dominates; minor roads are plain white without
    /// casing so the city grid doesn't turn into noise.
    static let light = VectorPalette(
        background: c(0xEFEBE3),
        areas: [
            .residential: c(0xE3DED5),
            .grass: c(0xCFE6B8),
            .wood: c(0xB7D8A0),
            .water: c(0x9EC7EC),
        ],
        lines: [
            .waterway: Line(fill: c(0x9EC7EC), casing: nil, width: 2.0),
            .rail: Line(fill: c(0x8E8E8E), casing: nil, width: 1.2),
            .track: Line(fill: c(0xB9A48A), casing: nil, width: 1.0),
            .service: Line(fill: c(0xFFFFFF), casing: nil, width: 1.6),
            .minor: Line(fill: c(0xFFFFFF), casing: c(0xC4BDB2), width: 2.4),
            .tertiary: Line(fill: c(0xFFFFFF), casing: c(0xA9A196), width: 3.2),
            .secondary: Line(fill: c(0xF6E89A), casing: c(0xA89A4E), width: 3.8),
            .primary: Line(fill: c(0xF9C97A), casing: c(0xA8783A), width: 4.4),
            .trunk: Line(fill: c(0xF4A462), casing: c(0x9C5A26), width: 5.0),
            .motorway: Line(fill: c(0xE98A4F), casing: c(0x8A4A1E), width: 5.6),
        ],
        casingWidth: 1.6,
        labelInk: c(0x2B2B2B),
        labelHalo: c(0xFFFFFF, 0.92),
        majorLabelInk: c(0x111111)
    )

    /// Dark: muted ground, roads lighter than the ground by importance,
    /// main roads warm. No casings (they read as glow at night).
    static let dark = VectorPalette(
        background: c(0x1C2027),
        areas: [
            .residential: c(0x232830),
            .grass: c(0x1F2D25),
            .wood: c(0x1B3024),
            .water: c(0x173450),
        ],
        lines: [
            .waterway: Line(fill: c(0x1F4466), casing: nil, width: 2.0),
            .rail: Line(fill: c(0x4C5058), casing: nil, width: 1.2),
            .track: Line(fill: c(0x4A4640), casing: nil, width: 1.0),
            .service: Line(fill: c(0x434951), casing: nil, width: 1.6),
            .minor: Line(fill: c(0x59606A), casing: nil, width: 2.4),
            .tertiary: Line(fill: c(0x737B86), casing: nil, width: 3.2),
            .secondary: Line(fill: c(0xA39556), casing: nil, width: 3.8),
            .primary: Line(fill: c(0xB98852), casing: nil, width: 4.4),
            .trunk: Line(fill: c(0xC8783F), casing: nil, width: 5.0),
            .motorway: Line(fill: c(0xD26E35), casing: nil, width: 5.6),
        ],
        casingWidth: 0,
        labelInk: c(0xE6E8EB),
        labelHalo: c(0x000000, 0.80),
        majorLabelInk: c(0xFFFFFF)
    )
}

/// Everything one frame's base map needs, captured on the main actor.
nonisolated struct VectorFrameSnapshot: @unchecked Sendable {
    /// Bitmap size: the frame (flat) or the ground buffer (3D).
    var canvasSize: CGSize
    /// Where the rider sits on the canvas.
    var anchor: CGPoint
    var headingDegrees: Double
    /// `MapViewSource.currentZoom` (z15-calibrated).
    var zoom: CGFloat
    /// Rider in z14 world units (tile index × 4096).
    var center: CGPoint
    var tiles: [VectorTile]
    var palette: VectorPalette
    var detail: VectorDetail
}

/// Level of detail, dropped under load (`RenderBudget`) and when zoomed out.
nonisolated struct VectorDetail: Sendable, Equatable {
    var minorRoads = true
    var serviceAndTracks = true
    var landcover = true
}

nonisolated enum VectorProjection {
    /// z14 world units per tile at 4096 extent.
    static let tileUnits: Double = 4096
    /// z14 world units per z15 base-layer pixel (4096 / 512).
    static let unitsPerBasePixel: Double = 8

    /// A coordinate in z14 world units (Web Mercator, y down).
    static func world(_ c: CLLocationCoordinate2D) -> CGPoint {
        let (x, y) = WebMercator.tile(for: c, zoom: VectorTileSource.sourceZoom)
        return CGPoint(x: x * tileUnits, y: y * tileUnits)
    }

    /// Canvas px per world unit at `zoom`.
    static func scale(zoom: CGFloat) -> CGFloat { zoom / CGFloat(unitsPerBasePixel) }

    /// The z14 tiles a canvas of `size` with the rider at `anchor` can
    /// show at this heading and zoom (the rotated canvas's bounding box,
    /// plus a half-tile margin for label anchors near the edge).
    static func visibleTiles(canvas size: CGSize, anchor: CGPoint, headingDegrees: Double,
                             zoom: CGFloat, center: CGPoint) -> [VectorTileKey] {
        let s = scale(zoom: zoom)
        let th = headingDegrees * .pi / 180
        let cosT = cos(th), sinT = sin(th)
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for corner in [CGPoint.zero, CGPoint(x: size.width, y: 0),
                       CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)] {
            // Canvas → world: undo translate(anchor), rotate(-heading), scale.
            let dx = Double(corner.x - anchor.x) / Double(s)
            let dy = Double(corner.y - anchor.y) / Double(s)
            let wx = dx * cosT - dy * sinT
            let wy = dx * sinT + dy * cosT
            minX = min(minX, wx); maxX = max(maxX, wx)
            minY = min(minY, wy); maxY = max(maxY, wy)
        }
        let margin = tileUnits / 2
        let n = 1 << VectorTileSource.sourceZoom
        let x0 = max(0, Int(floor((Double(center.x) + minX - margin) / tileUnits)))
        let x1 = min(n - 1, Int(floor((Double(center.x) + maxX + margin) / tileUnits)))
        let y0 = max(0, Int(floor((Double(center.y) + minY - margin) / tileUnits)))
        let y1 = min(n - 1, Int(floor((Double(center.y) + maxY + margin) / tileUnits)))
        guard x0 <= x1, y0 <= y1 else { return [] }
        var out: [VectorTileKey] = []
        for y in y0...y1 { for x in x0...x1 { out.append(VectorTileKey(z: VectorTileSource.sourceZoom, x: x, y: y)) } }
        // Nearest first, so a load request favours what's under the rider.
        let cx = Double(center.x) / tileUnits, cy = Double(center.y) / tileUnits
        return out.sorted {
            hypot(Double($0.x) + 0.5 - cx, Double($0.y) + 0.5 - cy)
                < hypot(Double($1.x) + 0.5 - cx, Double($1.y) + 0.5 - cy)
        }
    }

    /// Where a world point lands on the canvas (same transform the
    /// renderer applies to the tiles).
    static func canvasPoint(world p: CGPoint, snapshot s: VectorFrameSnapshot) -> CGPoint {
        let k = scale(zoom: s.zoom)
        let dx = Double(p.x - s.center.x) * Double(k)
        let dy = Double(p.y - s.center.y) * Double(k)
        let th = -s.headingDegrees * .pi / 180
        return CGPoint(x: Double(s.anchor.x) + dx * cos(th) - dy * sin(th),
                       y: Double(s.anchor.y) + dx * sin(th) + dy * cos(th))
    }
}

/// Owns a reusable bitmap. One render at a time (the render tick awaits
/// each one), so the context is never shared between threads.
nonisolated final class VectorMapRenderer: @unchecked Sendable {
    private var context: CGContext?

    /// Render the base map; the returned image is the canvas, top row first.
    func render(_ s: VectorFrameSnapshot) -> CGImage? {
        let w = Int(s.canvasSize.width), h = Int(s.canvasSize.height)
        if context?.width != w || context?.height != h {
            context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue |
                                            CGBitmapInfo.byteOrder32Little.rawValue)
        }
        guard let ctx = context else { return nil }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(s.palette.background)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Y-down, like the frame.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        Self.draw(s, into: ctx)
        return ctx.makeImage()
    }

    /// Draw the base map into a Y-down context (background already filled).
    static func draw(_ s: VectorFrameSnapshot, into ctx: CGContext) {
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .none
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let scale = VectorProjection.scale(zoom: s.zoom)

        // Per-tile transform: canvas ← translate(anchor) · rotate(-heading)
        // · scale · translate(tile origin − rider), in tile units.
        func withTile(_ t: VectorTile, _ body: (CGFloat) -> Void) {
            let unitScale = CGFloat(VectorProjection.tileUnits) / CGFloat(t.extent)
            ctx.saveGState()
            ctx.translateBy(x: s.anchor.x, y: s.anchor.y)
            ctx.rotate(by: -CGFloat(s.headingDegrees) * .pi / 180)
            ctx.scaleBy(x: scale * unitScale, y: scale * unitScale)
            ctx.translateBy(x: (CGFloat(t.x) * CGFloat(VectorProjection.tileUnits) - s.center.x) / unitScale,
                            y: (CGFloat(t.y) * CGFloat(VectorProjection.tileUnits) - s.center.y) / unitScale)
            body(scale * unitScale)
            ctx.restoreGState()
        }

        // Zoomed out (fast roads), road widths shrink a little and the
        // smallest classes go; zoomed in they grow a little.
        let widthFactor = min(1.25, max(0.7, 0.55 + 0.45 * s.zoom))
        let showService = s.detail.serviceAndTracks && s.zoom >= 1.0
        let showMinor = s.detail.minorRoads && s.zoom >= 0.75

        func visible(_ c: VectorFeatureClass) -> Bool {
            switch c {
            case .residential, .grass, .wood: return s.detail.landcover
            case .track, .service: return showService
            case .minor: return showMinor
            default: return true
            }
        }

        // 1. Areas, all tiles (water last so rivers sit on top of parks).
        for c in VectorFeatureClass.allCases where c.isArea && visible(c) {
            guard let color = s.palette.areas[c] else { continue }
            ctx.setFillColor(color)
            for t in s.tiles {
                guard let p = t.path(c) else { continue }
                withTile(t) { _ in
                    ctx.addPath(p)
                    // Non-zero: MVT outer rings and holes have opposite
                    // winding, and two overlapping features of one class
                    // (one path) must not cancel out as even-odd would.
                    ctx.fillPath(using: .winding)
                }
            }
        }
        let lineClasses = VectorFeatureClass.allCases.filter { !$0.isArea && visible($0) }
        // 2. Casings for every class, then fills for every class: a casing
        //    never cuts through a crossing road's fill.
        for c in lineClasses {
            guard let style = s.palette.lines[c], let casing = style.casing else { continue }
            let w = (style.width * widthFactor + s.palette.casingWidth)
            ctx.setStrokeColor(casing)
            for t in s.tiles {
                guard let p = t.path(c) else { continue }
                withTile(t) { k in
                    ctx.setLineWidth(w / k)
                    ctx.addPath(p)
                    ctx.strokePath()
                }
            }
        }
        for c in lineClasses {
            guard let style = s.palette.lines[c] else { continue }
            // Never thinner than ~1.2 px: below that a line flickers
            // between frames as it rotates.
            let w = max(1.2, style.width * widthFactor)
            ctx.setStrokeColor(style.fill)
            for t in s.tiles {
                guard let p = t.path(c) else { continue }
                withTile(t) { k in
                    ctx.setLineWidth(w / k)
                    ctx.addPath(p)
                    ctx.strokePath()
                }
            }
        }
    }
}
