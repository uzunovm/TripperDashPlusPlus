import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Testing
@testable import TripperDashPP

/// Vector vs raster on the wire: renders the same 15-second ride (straight,
/// then a 90° turn) with both renderers, pushes every frame through the
/// app's unchanged `H264Encoder` (4 fps, 512 kbps, 1 s GOP) and compares
/// the encoded bytes per frame — fewer bytes per frame means fewer RTP
/// packets to lose on the bike's Wi-Fi.
///
/// Off by default: it fetches live tiles (OpenFreeMap vector, OSM raster).
/// Run it with
///
///     TEST_RUNNER_TDPP_RENDER_HARNESS=1 TEST_RUNNER_TDPP_RENDER_OUT=/abs/dir \
///       xcodebuild test … -only-testing:TripperDashPPTests/RenderHarnessTests
///
/// (xcodebuild strips the `TEST_RUNNER_` prefix). It writes `summary.md`,
/// `vector.h264` / `raster.h264` (play with ffplay / mpv) and a few PNG
/// frames into `TDPP_RENDER_OUT` (default: the simulator's tmp folder).
/// CI: `.github/workflows/render-harness.yml` (manual run).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TDPP_RENDER_HARNESS"] == "1"))
@MainActor
struct RenderHarnessTests {
    static let frame = CGSize(width: 526, height: 300)
    static let puck = CGPoint(x: 263, y: 234)
    static let fps = 4
    static let seconds = 15
    /// z14 world start: the Prague fixture tile's centre.
    static let start = CGPoint(x: 8848.5 * 4096, y: 5555.5 * 4096)
    static let speedMPS = 12.0
    static let zoom: CGFloat = 1.2

    struct Pose { var world: CGPoint; var heading: Double }

    /// Straight at 30° for half the ride, then a steady turn to 120°.
    static func poses() -> [Pose] {
        let n = fps * seconds
        // World units per metre at this latitude (z14, 4096 per tile).
        let lat = WebMercator.coordinate(forTile: Double(start.x) / 4096, y: Double(start.y) / 4096, zoom: 14).latitude
        let metresPerUnit = 40_075_016.686 * cos(lat * .pi / 180) / (Double(1 << 14) * 4096)
        var p = start, out: [Pose] = []
        for i in 0..<n {
            let heading = i < n / 2 ? 30.0 : 30 + 90 * Double(i - n / 2) / Double(n / 2)
            out.append(Pose(world: p, heading: heading))
            let step = speedMPS / Double(fps) / metresPerUnit
            let th = heading * .pi / 180
            p.x += step * sin(th)
            p.y -= step * cos(th)
        }
        return out
    }

    // MARK: Tiles

    static func fetch(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("TripperDashPP-render-harness/1.0 (https://github.com/kolaCZek/TripperDashPlusPlus)",
                     forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    static func vectorTiles(around poses: [Pose]) async throws -> [VectorTile] {
        let tj = try await fetch(VectorTileSource.defaultTileJSONURL)
        let endpoint = try #require(VectorTileEndpoint.parse(tileJSON: tj))
        var keys = Set<VectorTileKey>()
        for p in poses {
            keys.formUnion(VectorProjection.visibleTiles(canvas: frame, anchor: puck, headingDegrees: p.heading,
                                                         zoom: zoom, center: p.world))
        }
        var tiles: [VectorTile] = []
        for k in keys {
            let data = try await fetch(try #require(endpoint.url(z: k.z, x: k.x, y: k.y)))
            tiles.append(try VectorTile.build(from: data, z: k.z, x: k.x, y: k.y))
        }
        return tiles
    }

    /// OSM z15 raster mosaic covering the ride; returns the image and the
    /// world point of its top-left corner.
    static func rasterMosaic(around poses: [Pose]) async throws -> (CGImage, CGPoint) {
        // z15 tile = 2048 z14 world units; margin covers the rotated frame.
        let margin = 4096.0
        let xs = poses.map { Double($0.world.x) }, ys = poses.map { Double($0.world.y) }
        let x0 = Int(((xs.min()! - margin) / 2048).rounded(.down)), x1 = Int(((xs.max()! + margin) / 2048).rounded(.down))
        let y0 = Int(((ys.min()! - margin) / 2048).rounded(.down)), y1 = Int(((ys.max()! + margin) / 2048).rounded(.down))
        let w = (x1 - x0 + 1) * 256, h = (y1 - y0 + 1) * 256
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                             | CGBitmapInfo.byteOrder32Little.rawValue))
        for ty in y0...y1 {
            for tx in x0...x1 {
                let url = try #require(URL(string: "https://tile.openstreetmap.org/15/\(tx)/\(ty).png"))
                let data = try await fetch(url)
                let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
                let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
                // Bitmap is y-up: row 0 of the mosaic is the top.
                ctx.draw(img, in: CGRect(x: (tx - x0) * 256, y: h - (ty - y0 + 1) * 256, width: 256, height: 256))
            }
        }
        return (try #require(ctx.makeImage()), CGPoint(x: Double(x0) * 2048, y: Double(y0) * 2048))
    }

    // MARK: Frames

    static func bitmap() -> CGContext? {
        CGContext(data: nil, width: Int(frame.width), height: Int(frame.height), bitsPerComponent: 8,
                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// Raster frame the way the app composites it: rider at the puck,
    /// heading up, z15 pixels × zoom.
    static func rasterFrame(_ mosaic: CGImage, origin: CGPoint, pose: Pose) -> CGImage? {
        guard let ctx = bitmap() else { return nil }
        ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: frame))
        ctx.interpolationQuality = .high
        // Y-down drawing space.
        ctx.translateBy(x: 0, y: frame.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: puck.x, y: puck.y)
        ctx.rotate(by: -pose.heading * .pi / 180)
        ctx.scaleBy(x: zoom, y: zoom)
        // World units → z15 px: / 8.
        let rx = (pose.world.x - origin.x) / 8, ry = (pose.world.y - origin.y) / 8
        let rect = CGRect(x: -rx, y: -ry, width: CGFloat(mosaic.width), height: CGFloat(mosaic.height))
        ctx.translateBy(x: 0, y: rect.midY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: 0, y: -rect.midY)
        ctx.draw(mosaic, in: rect)
        return ctx.makeImage()
    }

    /// Vector frame: base map + placed labels, as `drawVectorFrame` does.
    static func vectorFrame(_ r: VectorMapRenderer, tiles: [VectorTile], pose: Pose,
                            placer: inout LabelPlacer, labels: LabelImageCache) -> CGImage? {
        let snap = VectorFrameSnapshot(canvasSize: frame, anchor: puck, headingDegrees: pose.heading, zoom: zoom,
                                       center: pose.world, tiles: tiles, palette: .light, detail: VectorDetail())
        guard let base = r.render(snap), let ctx = bitmap() else { return nil }
        ctx.draw(base, in: CGRect(origin: .zero, size: frame))
        var byName: [String: VectorLabel] = [:]
        let cands = LabelPlacer.candidates(
            tiles: tiles, center: pose.world, headingDegrees: pose.heading, zoom: zoom, frame: frame,
            project: { CGPoint(x: puck.x + $0.x, y: puck.y + $0.y) },
            size: { l in byName["\(l.kind.rawValue)|\(l.text)"] = l
                return labels.size(l, palette: .light, dark: false) })
        let area = LabelPlacer.Area(glassCenter: CGPoint(x: 262, y: 263), glassRadius: 264,
                                    discs: [(puck, 24)],
                                    rects: [CGRect(x: 172, y: 0, width: 180, height: 22)], clearance: 4)
        for c in placer.place(cands, in: area) {
            guard let l = byName[c.name], let img = labels.image(l, palette: .light, dark: false) else { continue }
            ctx.draw(img, in: CGRect(x: c.rect.minX, y: frame.height - c.rect.maxY,
                                     width: c.rect.width, height: c.rect.height))
        }
        return ctx.makeImage()
    }

    // MARK: Encode

    final class Collector: @unchecked Sendable {
        let lock = NSLock()
        var bytesByPTS: [Int64: (bytes: Int, key: Bool)] = [:]
        var annexB = Data()
        func add(_ nal: EncodedNAL) {
            lock.lock(); defer { lock.unlock() }
            let k = nal.timestamp.value
            var e = bytesByPTS[k] ?? (0, false)
            e.bytes += nal.bytes.count
            e.key = e.key || nal.isKeyframe
            bytesByPTS[k] = e
            annexB.append(contentsOf: [0, 0, 0, 1])
            annexB.append(nal.bytes)
        }
    }

    static func pixelBuffer(_ image: CGImage) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pb
    }

    struct Stats {
        var frames: Int, meanBytes: Double, p95Bytes: Int, maxBytes: Int, meanIDR: Double, meanP: Double
        var kbps: Double { meanBytes * 8 * Double(RenderHarnessTests.fps) / 1000 }
        var line: String {
            String(format: "%d frames, mean %.0f B, p95 %d B, max %d B, IDR mean %.0f B, P mean %.0f B, %.0f kbit/s",
                   frames, meanBytes, p95Bytes, maxBytes, meanIDR, meanP, kbps)
        }
    }

    static func encode(_ frames: [CGImage]) async throws -> (Stats, Data) {
        let enc = H264Encoder()
        let col = Collector()
        enc.onNAL = { col.add($0) }
        try enc.start()
        for (i, img) in frames.enumerated() {
            let pb = try #require(pixelBuffer(img))
            enc.encode(pixelBuffer: pb, presentationTime: CMTime(value: Int64(i) * 22_500, timescale: 90_000))
            try await Task.sleep(for: .milliseconds(20))
        }
        enc.stop()
        try await Task.sleep(for: .milliseconds(300))
        col.lock.lock(); defer { col.lock.unlock() }
        let entries = col.bytesByPTS.values
        let sizes = entries.map(\.bytes).sorted()
        let idr = entries.filter(\.key).map(\.bytes), p = entries.filter { !$0.key }.map(\.bytes)
        func mean(_ a: [Int]) -> Double { a.isEmpty ? 0 : Double(a.reduce(0, +)) / Double(a.count) }
        let stats = Stats(frames: sizes.count, meanBytes: mean(sizes),
                          p95Bytes: sizes.isEmpty ? 0 : sizes[min(sizes.count - 1, Int(Double(sizes.count) * 0.95))],
                          maxBytes: sizes.last ?? 0, meanIDR: mean(idr), meanP: mean(p))
        return (stats, col.annexB)
    }

    static func writePNG(_ image: CGImage, _ url: URL) {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, image, nil)
        CGImageDestinationFinalize(d)
    }

    // MARK: The run

    @Test func vectorVersusRasterOnTheWire() async throws {
        let env = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: env["TDPP_RENDER_OUT"] ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("render-harness").path)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let poses = Self.poses()
        let tiles = try await Self.vectorTiles(around: poses)
        let (mosaic, origin) = try await Self.rasterMosaic(around: poses)

        let renderer = VectorMapRenderer()
        var placer = LabelPlacer()
        let labels = LabelImageCache()
        var vector: [CGImage] = [], raster: [CGImage] = [], vectorMs: [Double] = []
        for pose in poses {
            let t0 = Date()
            vector.append(try #require(Self.vectorFrame(renderer, tiles: tiles, pose: pose, placer: &placer, labels: labels)))
            vectorMs.append(Date().timeIntervalSince(t0) * 1000)
            raster.append(try #require(Self.rasterFrame(mosaic, origin: origin, pose: pose)))
        }
        for i in [0, poses.count / 2, poses.count - 1] {
            Self.writePNG(vector[i], out.appendingPathComponent("vector_\(i).png"))
            Self.writePNG(raster[i], out.appendingPathComponent("raster_\(i).png"))
        }

        let (vs, vData) = try await Self.encode(vector)
        let (rs, rData) = try await Self.encode(raster)
        try vData.write(to: out.appendingPathComponent("vector.h264"))
        try rData.write(to: out.appendingPathComponent("raster.h264"))

        let sortedMs = vectorMs.sorted()
        let summary = """
        # Render harness: vector vs raster

        \(poses.count) frames at \(Self.fps) fps, 526×300, zoom \(Self.zoom), \(Int(Self.speedMPS * 3.6)) km/h, \
        straight then a 90° turn. Encoder: app `H264Encoder` defaults (512 kbit/s, 1 s GOP, baseline).

        | | per frame |
        |---|---|
        | Vector | \(vs.line) |
        | Raster | \(rs.line) |

        Vector / raster mean bytes: \(String(format: "%.2f", rs.meanBytes > 0 ? vs.meanBytes / rs.meanBytes : 0))

        Vector render (base + labels, this machine): mean \(String(format: "%.1f", vectorMs.reduce(0, +) / Double(vectorMs.count))) ms, \
        p95 \(String(format: "%.1f", sortedMs[Int(Double(sortedMs.count) * 0.95)])) ms, \(tiles.count) tiles.
        """
        try summary.write(to: out.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        print(summary)
        print("render harness output: \(out.path)")
        #expect(vs.frames == poses.count && rs.frames == poses.count)
    }
}
