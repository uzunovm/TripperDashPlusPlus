import Foundation
import Testing
@testable import TripperDashPP

/// Fixture tiles live in `Fixtures/` (OpenFreeMap planet, z14, fetched
/// 2026-11-24). Expected counts are pinned by the Python mirror
/// (`tools/fake_dash/tests/test_mvt_mirror.py`), which decodes the same files.
enum MVTFixture {
    private final class Token {}

    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: Token.self)
        let url = try #require(bundle.url(forResource: name, withExtension: nil),
                               "fixture \(name) missing from the test bundle")
        return try Data(contentsOf: url)
    }

    static let pragueCentre = "mvt_14_8848_5555_prague.pbf"
    static let rural = "mvt_14_8874_5591_rural.pbf"
    static let pragueGzipped = "mvt_14_8846_5552_prague.pbf.gz"
}

struct MVTDecoderTests {
    private func counts(_ layers: [MVTLayer]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: layers.map { ($0.name, $0.features.count) })
    }

    @Test func denseCityTileLayersAndCounts() throws {
        let layers = try MVTDecoder.decode(MVTFixture.data(MVTFixture.pragueCentre))
        #expect(counts(layers) == [
            "boundary": 1, "building": 21, "housenumber": 765, "landcover": 336,
            "landuse": 75, "mountain_peak": 2, "park": 4, "place": 9, "poi": 1154,
            "transportation": 179, "transportation_name": 95, "water": 10,
            "water_name": 11, "waterway": 24,
        ])
        let roads = try #require(layers.first { $0.name == "transportation" })
        #expect(roads.extent == 4096)
        #expect(roads.version == 2)
        #expect(roads.features.reduce(0) { $0 + $1.parts.reduce(0) { $0 + $1.count } } == 6171)
        let names = try #require(layers.first { $0.name == "transportation_name" })
        #expect(names.features.contains { $0["name"]?.stringValue == "Andělova" })
    }

    @Test func ruralTileLayersAndCounts() throws {
        let layers = try MVTDecoder.decode(MVTFixture.data(MVTFixture.rural))
        #expect(counts(layers) == [
            "boundary": 1, "building": 3, "housenumber": 3, "landcover": 57,
            "landuse": 2, "place": 7, "poi": 2, "transportation": 11,
            "transportation_name": 3, "water": 2, "water_name": 4, "waterway": 14,
        ])
        let roads = try #require(layers.first { $0.name == "transportation" })
        #expect(roads.features.contains { $0["class"]?.stringValue == "secondary" })
    }

    @Test func gzippedTileIsInflated() throws {
        let data = try MVTFixture.data(MVTFixture.pragueGzipped)
        #expect(data.prefix(2) == Data([0x1F, 0x8B]))
        let layers = try MVTDecoder.decode(data)
        #expect(counts(layers)["transportation"] == 198)
        #expect(counts(layers)["housenumber"] == 887)
    }

    @Test func layerFilterSkipsOtherLayers() throws {
        let keep: Set = ["transportation", "water"]
        let layers = try MVTDecoder.decode(MVTFixture.data(MVTFixture.pragueCentre), keepLayers: keep)
        #expect(Set(layers.map(\.name)) == keep)
        #expect(counts(layers)["transportation"] == 179)
    }

    @Test(arguments: [MVTFixture.pragueCentre, MVTFixture.rural, MVTFixture.pragueGzipped])
    func geometryIsSaneAndRingsClosed(_ fixture: String) throws {
        let layers = try MVTDecoder.decode(MVTFixture.data(fixture))
        for layer in layers {
            // Lines and polygons are clipped to the 64-unit tile buffer (128
            // for the label lines); label POINTS are not clipped — OpenMapTiles
            // repeats a place / water name in every tile its label could
            // touch, up to ~2 extents away. `mountain_peak` ridge lines are
            // not clipped either (and not drawn).
            for f in layer.features {
                let unclipped = f.type == .point || layer.name == "mountain_peak"
                let reach = Int32(unclipped ? 2 * layer.extent : 128)
                let lo = -reach, hi = Int32(layer.extent) + reach
                #expect(!f.parts.isEmpty, "\(layer.name): empty geometry")
                for part in f.parts {
                    for p in part {
                        #expect((lo...hi).contains(p.x) && (lo...hi).contains(p.y),
                                "\(layer.name): point \(p) outside the extent")
                    }
                    switch f.type {
                    case .polygon:
                        #expect(part.count >= 4 && part.first == part.last, "\(layer.name): open ring")
                    case .lineString:
                        #expect(part.count >= 2, "\(layer.name): one-point line")
                    case .point:
                        #expect(part.count == 1)
                    case .unknown:
                        Issue.record("\(layer.name): unknown geometry type")
                    }
                }
            }
        }
    }

    @Test func geometryCommandsFollowSpec() {
        // Spec example: MoveTo(2,2) LineTo(2,10) LineTo(10,10), a line.
        let line: [UInt32] = [9, 4, 4, 18, 0, 16, 16, 0]
        #expect(MVTDecoder.decodeGeometry(line, type: .lineString)
                == [[MVTPoint(x: 2, y: 2), MVTPoint(x: 2, y: 10), MVTPoint(x: 10, y: 10)]])
        // Spec example polygon: MoveTo(3,6) LineTo(8,12) LineTo(20,34) ClosePath.
        let poly: [UInt32] = [9, 6, 12, 18, 10, 12, 24, 44, 15]
        #expect(MVTDecoder.decodeGeometry(poly, type: .polygon)
                == [[MVTPoint(x: 3, y: 6), MVTPoint(x: 8, y: 12), MVTPoint(x: 20, y: 34), MVTPoint(x: 3, y: 6)]])
        // Truncated parameters: keep what decoded, don't trap.
        #expect(MVTDecoder.decodeGeometry([9, 4], type: .lineString).isEmpty)
    }

    @Test func protobufPrimitives() throws {
        var r = ProtobufReader([0xAC, 0x02, 0x01])
        #expect(try r.readVarint() == 300)
        #expect(try r.readVarint() == 1)
        #expect(r.isAtEnd)
        #expect(ProtobufReader.zigzag(0) == 0)
        #expect(ProtobufReader.zigzag(1) == -1)
        #expect(ProtobufReader.zigzag(4) == 2)
        #expect(ProtobufReader.zigzag32(UInt32.max) == Int32.min)
        var t = ProtobufReader([0x80])
        #expect(throws: ProtobufReader.Failure.truncated) { try t.readVarint() }
    }
}
