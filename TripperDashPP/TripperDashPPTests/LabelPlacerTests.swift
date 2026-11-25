import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import TripperDashPP

struct LabelPlacerTests {
    /// The dash: glass circle, turn-card disc while navigating, puck.
    private let area = LabelPlacer.Area(
        glassCenter: CGPoint(x: 262, y: 263), glassRadius: 264,
        discs: [(CGPoint(x: 79, y: 228), 68), (CGPoint(x: 263, y: 195), 24)],
        rects: [CGRect(x: 172, y: 0, width: 180, height: 22)],
        clearance: 4)

    private func c(_ id: String, _ x: CGFloat, _ y: CGFloat, priority: Int = 30,
                   w: CGFloat = 60, h: CGFloat = 16) -> LabelPlacer.Candidate {
        LabelPlacer.Candidate(id: id, name: id, priority: priority,
                              center: CGPoint(x: x, y: y), size: CGSize(width: w, height: h))
    }

    private func spread() -> [LabelPlacer.Candidate] {
        [c("a", 200, 80), c("b", 330, 80), c("c", 160, 130), c("d", 380, 130),
         c("e", 300, 250), c("f", 420, 240), c("g", 220, 260), c("h", 260, 130)]
    }

    @Test func addsAtMostOneNewLabelPerFrameUpToSix() {
        var p = LabelPlacer()
        var counts: [Int] = []
        for _ in 0..<10 { counts.append(p.place(spread(), in: area).count) }
        #expect(counts == [1, 2, 3, 4, 5, 6, 6, 6, 6, 6])
    }

    @Test func placementIsStableUnderASmallPan() {
        var p = LabelPlacer()
        for _ in 0..<8 { _ = p.place(spread(), in: area) }
        let before = Set(p.shown)
        for step in 1...6 {
            let panned = spread().map { var m = $0; m.center.x += CGFloat(step); m.center.y += CGFloat(step); return m }
            _ = p.place(panned, in: area)
            #expect(Set(p.shown) == before)
        }
    }

    @Test func neverOnTheTurnCardTheGlassEdgeOrThePuck() {
        var p = LabelPlacer()
        let bad = [c("card", 79, 228, priority: 99), c("corner", 20, 10, priority: 99),
                   c("puck", 263, 195, priority: 99), c("attr", 262, 8, priority: 99),
                   c("offRight", 520, 120, priority: 99)]
        for _ in 0..<10 {
            let placed = p.place(bad + [c("ok", 300, 100)], in: area)
            #expect(placed.map(\.id).allSatisfy { $0 == "ok" })
        }
        #expect(p.shown == ["ok"])
    }

    @Test func aLabelPannedIntoTheCardIsDropped() {
        var p = LabelPlacer()
        _ = p.place([c("x", 200, 150)], in: area)
        #expect(p.shown == ["x"])
        _ = p.place([c("x", 100, 220)], in: area)
        #expect(p.shown.isEmpty)
    }

    @Test func higherPriorityWinsWhenKeptLabelsCollide() {
        var p = LabelPlacer()
        _ = p.place([c("lo", 200, 100, priority: 20)], in: area)
        _ = p.place([c("lo", 200, 100, priority: 20), c("hi", 350, 100, priority: 80)], in: area)
        #expect(Set(p.shown) == ["lo", "hi"])
        // The map turns and the two now overlap: the town name stays.
        _ = p.place([c("lo", 300, 100, priority: 20), c("hi", 320, 100, priority: 80)], in: area)
        #expect(p.shown == ["hi"])
    }

    @Test func aNameShowsOnce() {
        var p = LabelPlacer()
        var a = c("street|1", 200, 100), b = c("street|2", 350, 100)
        a.name = "road|Main"; b.name = "road|Main"
        for _ in 0..<4 { _ = p.place([a, b], in: area) }
        #expect(p.shown.count == 1)
    }

    @Test func candidatesFromTheFixtureLandOnTheFrame() throws {
        let tile = try VectorTile.build(from: MVTFixture.data(MVTFixture.pragueCentre), z: 14, x: 8848, y: 5555)
        let center = CGPoint(x: 8848.5 * 4096, y: 5555.5 * 4096)
        let puck = CGPoint(x: 263, y: 195)
        let frame = CGSize(width: 526, height: 300)
        let cands = LabelPlacer.candidates(
            tiles: [tile], center: center, headingDegrees: 30, zoom: 1, frame: frame,
            project: { CGPoint(x: puck.x + $0.x, y: puck.y + $0.y) },
            size: { CGSize(width: CGFloat($0.text.count) * 6, height: 15) })
        #expect(!cands.isEmpty)
        #expect(cands.allSatisfy { CGRect(origin: .zero, size: frame).contains($0.center) })
        #expect(Set(cands.map(\.id)).count == cands.count)
        var p = LabelPlacer()
        for _ in 0..<8 { _ = p.place(cands, in: area) }
        #expect((1...LabelPlacer.maxLabels).contains(p.shown.count))
    }

    /// Base map + placed labels, written to the simulator's tmp folder
    /// for a visual check (`labelled_<palette>.png`).
    @Test(arguments: ["light", "dark"]) @MainActor
    func rendersALabelledFrame(_ name: String) throws {
        let palette: VectorPalette = name == "dark" ? .dark : .light
        let tile = try VectorTile.build(from: MVTFixture.data(MVTFixture.pragueCentre), z: 14, x: 8848, y: 5555)
        let center = CGPoint(x: 8848.5 * 4096, y: 5555.5 * 4096)
        let frame = CGSize(width: 526, height: 300)
        let puck = CGPoint(x: 263, y: 195)
        let snap = VectorFrameSnapshot(canvasSize: frame, anchor: puck, headingDegrees: 30, zoom: 1,
                                       center: center, tiles: [tile], palette: palette, detail: VectorDetail())
        let base = try #require(VectorMapRenderer().render(snap))
        let cache = LabelImageCache()
        var labels: [String: VectorLabel] = [:]
        let cands = LabelPlacer.candidates(
            tiles: [tile], center: center, headingDegrees: 30, zoom: 1, frame: frame,
            project: { CGPoint(x: puck.x + $0.x, y: puck.y + $0.y) },
            size: { l in labels["\(l.kind.rawValue)|\(l.text)"] = l; return cache.size(l, palette: palette, dark: name == "dark") })
        var p = LabelPlacer()
        var placed: [LabelPlacer.Candidate] = []
        for _ in 0..<8 { placed = p.place(cands, in: area) }
        let ctx = try #require(CGContext(data: nil, width: 526, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        ctx.draw(base, in: CGRect(origin: .zero, size: frame))
        for c in placed {
            let label = try #require(labels[c.name])
            let img = try #require(cache.image(label, palette: palette, dark: name == "dark"))
            // Bitmap is y-up; candidate rects are y-down.
            ctx.draw(img, in: CGRect(x: c.rect.minX, y: 300 - c.rect.maxY, width: c.rect.width, height: c.rect.height))
        }
        let out = try #require(ctx.makeImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("labelled_\(name).png")
        if let dst = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dst, out, nil)
            CGImageDestinationFinalize(dst)
            print("labelled render written: \(url.path)")
        }
        #expect(placed.count >= 3)
    }

    @Test @MainActor func labelImageHasHaloAndInk() throws {
        let cache = LabelImageCache()
        let l = VectorLabel(text: "Andělova", kind: .road, priority: 30, point: .zero)
        let size = try #require(cache.size(l, palette: .light, dark: false))
        let img = try #require(cache.image(l, palette: .light, dark: false))
        #expect(CGFloat(img.width) == size.width && CGFloat(img.height) == size.height)
        #expect(size.height >= 14 && size.width > 40)
        // Some opaque pixels (ink) and some transparent ones.
        let data = try #require(img.dataProvider?.data as Data?)
        let alphas = stride(from: 3, to: data.count, by: 4).map { data[$0] }
        #expect(alphas.contains(255) && alphas.contains(0))
        // Cached: same object.
        #expect(cache.image(l, palette: .light, dark: false) === img)
    }
}
