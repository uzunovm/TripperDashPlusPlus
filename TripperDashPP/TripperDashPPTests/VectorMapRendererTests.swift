import CoreGraphics
import CoreLocation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import TripperDashPP

struct VectorMapRendererTests {
    /// Dense Prague fixture tile, rider at its centre.
    private func snapshot(palette: VectorPalette, heading: Double = 30, zoom: CGFloat = 1,
                          canvas: CGSize = CGSize(width: 526, height: 300),
                          anchor: CGPoint = CGPoint(x: 263, y: 195)) throws -> VectorFrameSnapshot {
        let tile = try VectorTile.build(from: MVTFixture.data(MVTFixture.pragueCentre), z: 14, x: 8848, y: 5555)
        let center = CGPoint(x: 8848.5 * 4096, y: 5555.5 * 4096)
        return VectorFrameSnapshot(canvasSize: canvas, anchor: anchor, headingDegrees: heading,
                                   zoom: zoom, center: center, tiles: [tile],
                                   palette: palette, detail: VectorDetail())
    }

    /// Distinct colours in the image (a blank canvas has one).
    private func colourCount(_ image: CGImage) -> Int {
        guard let data = image.dataProvider?.data as Data? else { return 0 }
        var seen = Set<UInt32>()
        data.withUnsafeBytes { raw in
            let px = raw.bindMemory(to: UInt32.self)
            stride(from: 0, to: px.count, by: 7).forEach { seen.insert(px[$0] & 0x00FF_FFFF) }
        }
        return seen.count
    }

    private func writePNG(_ image: CGImage, _ name: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vector_\(name).png")
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dst, image, nil)
        CGImageDestinationFinalize(dst)
        print("vector render written: \(url.path)")
    }

    @Test(arguments: ["light", "dark"])
    func rendersDenseCityFrame(_ name: String) throws {
        let s = try snapshot(palette: name == "dark" ? .dark : .light)
        let r = VectorMapRenderer()
        let t0 = Date()
        let image = try #require(r.render(s))
        let ms = Date().timeIntervalSince(t0) * 1000
        #expect(image.width == 526 && image.height == 300)
        #expect(colourCount(image) > 20, "frame looks blank")
        // Generous: simulator, debug build, first frame.
        #expect(ms < 400, "render took \(Int(ms)) ms")
        writePNG(image, name)
    }

    @Test func rendersGroundBufferFor3D() throws {
        let s = try snapshot(palette: .light, canvas: DashPerspective.groundSize,
                             anchor: DashPerspective.groundAnchor)
        let image = try #require(VectorMapRenderer().render(s))
        #expect(image.width == Int(DashPerspective.groundSize.width))
        writePNG(image, "ground")
    }

    @Test func sameInputRendersIdenticalPixels() throws {
        let s = try snapshot(palette: .light)
        let r = VectorMapRenderer()
        let a = try #require(r.render(s)?.dataProvider?.data as Data?)
        let b = try #require(r.render(s)?.dataProvider?.data as Data?)
        #expect(a == b)
    }

    @Test func visibleTilesCoverTheRotatedCanvas() {
        let center = CGPoint(x: 8848.5 * 4096, y: 5555.5 * 4096)
        let flat = VectorProjection.visibleTiles(canvas: CGSize(width: 526, height: 300),
                                                 anchor: CGPoint(x: 263, y: 195),
                                                 headingDegrees: 45, zoom: 0.8, center: center)
        #expect(flat.first == VectorTileKey(z: 14, x: 8848, y: 5555))
        #expect((1...9).contains(flat.count))
        let ground = VectorProjection.visibleTiles(canvas: DashPerspective.groundSize,
                                                   anchor: DashPerspective.groundAnchor,
                                                   headingDegrees: 45, zoom: 0.8, center: center)
        #expect(ground.count >= flat.count)
        #expect(ground.count <= 25)
    }

    @Test func canvasPointPutsTheRiderAtTheAnchor() throws {
        let s = try snapshot(palette: .light, heading: 77, zoom: 1.6)
        let p = VectorProjection.canvasPoint(world: s.center, snapshot: s)
        #expect(abs(p.x - s.anchor.x) < 1e-6 && abs(p.y - s.anchor.y) < 1e-6)
        // 8 world units = one z15 px at zoom 1; north (−y) is up when heading 0.
        var north = s
        north.headingDegrees = 0
        north.zoom = 1
        let q = VectorProjection.canvasPoint(world: CGPoint(x: s.center.x, y: s.center.y - 80), snapshot: north)
        #expect(abs(q.x - s.anchor.x) < 1e-6 && abs(q.y - (s.anchor.y - 10)) < 1e-6)
    }

    @Test func budgetStepsDownAndRecovers() {
        var b = RenderBudget()
        for _ in 0..<20 { b.record(ms: 140) }
        #expect(b.level >= 1)
        #expect(!b.labels)
        for _ in 0..<80 { b.record(ms: 10) }
        #expect(b.level == 0)
        let line = b.takeLogLine()
        #expect(line?.hasPrefix("vector render: n=100 ") == true)
        #expect(b.takeLogLine() == nil)
    }
}
