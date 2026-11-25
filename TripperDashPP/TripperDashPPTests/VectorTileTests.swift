import CoreLocation
import Foundation
import Testing
@testable import TripperDashPP

struct VectorTileBuildTests {
    private func build(_ fixture: String, x: Int, y: Int) throws -> VectorTile {
        try VectorTile.build(from: MVTFixture.data(fixture), z: 14, x: x, y: y)
    }

    @Test func denseTileHasRoadsAreasAndLabels() throws {
        let t = try build(MVTFixture.pragueCentre, x: 8848, y: 5555)
        for c in [VectorFeatureClass.minor, .tertiary, .service] {
            #expect(t.path(c) != nil, "\(c) missing")
        }
        // Paths are dropped at build time.
        #expect(t.labels.contains { $0.kind == .road && $0.text == "Andělova" })
        for l in t.labels {
            #expect(VectorTile.owns(l.point, extent: CGFloat(t.extent)), "\(l.text) outside its tile")
            #expect(!l.text.isEmpty)
        }
    }

    @Test func ruralTileHasSecondaryRoad() throws {
        let t = try build(MVTFixture.rural, x: 8874, y: 5591)
        #expect(t.path(.secondary) != nil)
        #expect(t.path(.motorway) == nil)
    }

    @Test func paintOrderIsAreasThenRoadsByImportance() {
        let all = VectorFeatureClass.allCases
        #expect(all.filter(\.isArea) == [.residential, .grass, .wood, .water])
        #expect(all.last == .motorway)
        #expect(VectorFeatureClass.minor.rawValue < VectorFeatureClass.primary.rawValue)
    }

    @Test func roadClassMapping() {
        func f(_ props: [String: MVTValue]) -> MVTFeature {
            MVTFeature(id: nil, type: .lineString, properties: props, parts: [])
        }
        #expect(VectorTile.roadClass(f(["class": .string("primary")])) == .primary)
        #expect(VectorTile.roadClass(f(["class": .string("primary"), "brunnel": .string("tunnel")])) == nil)
        #expect(VectorTile.roadClass(f(["class": .string("path")])) == nil)
        #expect(VectorTile.roadClass(f(["class": .string("rail"), "subclass": .string("tram")])) == nil)
        #expect(VectorTile.roadClass(f(["class": .string("rail")])) == .rail)
        #expect(VectorTile.roadClass(f(["class": .string("minor_construction")])) == nil)
    }

    @Test func labelPointsOutsideTheTileBelongToTheNeighbour() {
        let ext: CGFloat = 4096
        #expect(VectorTile.owns(CGPoint(x: 0, y: 0), extent: ext))
        #expect(!VectorTile.owns(CGPoint(x: 4096, y: 10), extent: ext))
        #expect(!VectorTile.owns(CGPoint(x: -1, y: 10), extent: ext))
    }

    @Test func simplifyKeepsEndsAndCorners() {
        let straight = (0...10).map { CGPoint(x: CGFloat($0) * 10, y: 0) }
        #expect(VectorTile.simplify(straight, tolerance: 1) == [straight.first!, straight.last!])
        let corner = [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0.5), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)]
        #expect(VectorTile.simplify(corner, tolerance: 1)
                == [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)])
    }

    @Test func midpointOfLongestPart() {
        let parts = [[MVTPoint(x: 0, y: 0), MVTPoint(x: 10, y: 0)],
                     [MVTPoint(x: 0, y: 100), MVTPoint(x: 100, y: 100)]]
        #expect(VectorTile.midpoint(ofLongest: parts) == CGPoint(x: 50, y: 100))
    }
}

struct VectorTileSetTests {
    let prague = CLLocationCoordinate2D(latitude: 50.0755, longitude: 14.4378)

    @Test func riderTileComesFirst() {
        let keys = VectorTileStore.tiles(around: prague, radiusM: 2000)
        #expect(keys.first == VectorTileStore.key(for: prague))
        // ±2 km at z14 (~1.57 km tiles at 50°N) is 3–4 tiles a side.
        #expect((9...16).contains(keys.count))
        #expect(Set(keys).count == keys.count)
    }

    /// A straight 20 km route due east; the rider at its start.
    private var eastRoute: [CLLocationCoordinate2D] {
        let mPerDegLon = 111_320 * cos(prague.latitude * .pi / 180)
        return (0...20).map {
            CLLocationCoordinate2D(latitude: prague.latitude,
                                   longitude: prague.longitude + Double($0) * 1000 / mPerDegLon)
        }
    }

    @Test func corridorCoversTheBandAheadOnly() {
        let keys = VectorTileStore.corridorTiles(route: eastRoute, rider: prague,
                                                 behindM: 1000, aheadM: 10_000, radiusM: 2500)
        #expect(keys.first == VectorTileStore.key(for: prague))
        #expect(Set(keys).count == keys.count)
        let start = VectorTileStore.key(for: prague)
        let end = VectorTileStore.key(for: eastRoute[10])
        let beyond = VectorTileStore.key(for: eastRoute[16])
        #expect(keys.contains(end))
        #expect(!keys.contains(beyond))
        // ~10 km ≈ 6.4 tiles along, 4 tiles across: low tens, not hundreds.
        #expect((20...60).contains(keys.count))
        // Every tile is within ±3 rows of the route (it runs along one row).
        #expect(keys.allSatisfy { abs($0.y - start.y) <= 3 })
    }

    @Test func corridorOrdersAheadByDistance() {
        let keys = VectorTileStore.corridorTiles(route: eastRoute, rider: eastRoute[5],
                                                 behindM: 1000, aheadM: 5000, radiusM: 500)
        #expect(keys.first == VectorTileStore.key(for: eastRoute[5]))
        // 5 km ahead and 1 km behind are both in; 8 km ahead is not.
        #expect(keys.contains(VectorTileStore.key(for: eastRoute[10])))
        #expect(keys.contains(VectorTileStore.key(for: eastRoute[4])))
        #expect(!keys.contains(VectorTileStore.key(for: eastRoute[13])))
        // Going east, ahead tiles come in non-decreasing x until the
        // behind band starts (the first tile west of the rider's).
        let riderX = VectorTileStore.key(for: eastRoute[5]).x
        let aheadXs = keys.prefix { $0.x >= riderX }.map(\.x)
        #expect(aheadXs == aheadXs.sorted())
    }

    @Test func emptyOrSinglePointRouteHasNoCorridor() {
        #expect(VectorTileStore.corridorTiles(route: [prague], rider: prague,
                                              behindM: 1000, aheadM: 10_000, radiusM: 2500).isEmpty)
    }
}

struct VectorTileEndpointTests {
    @Test func parsesOpenFreeMapTileJSON() throws {
        let json = #"{"tiles":["https://tiles.openfreemap.org/planet/20261122_124456_pt/{z}/{x}/{y}.pbf"],"maxzoom":14}"#
        let e = try #require(VectorTileEndpoint.parse(tileJSON: Data(json.utf8)))
        #expect(e.maxZoom == 14)
        #expect(e.cacheNamespace == "ofm")
        #expect(e.url(z: 14, x: 8848, y: 5555)?.absoluteString
                == "https://tiles.openfreemap.org/planet/20261122_124456_pt/14/8848/5555.pbf")
    }

    @Test func rejectsTileJSONWithoutTemplate() {
        #expect(VectorTileEndpoint.parse(tileJSON: Data(#"{"tiles":[]}"#.utf8)) == nil)
        #expect(VectorTileEndpoint.parse(tileJSON: Data("nope".utf8)) == nil)
    }

    @Test func customEndpointGetsItsOwnStableNamespace() {
        let a = VectorTileEndpoint(template: "https://example.test/t/{z}/{x}/{y}.pbf", maxZoom: 14, resolvedAt: .now)
        let b = VectorTileEndpoint(template: "https://example.test/t/{z}/{x}/{y}.pbf", maxZoom: 14, resolvedAt: .distantPast)
        #expect(a.cacheNamespace == b.cacheNamespace)
        #expect(a.cacheNamespace.hasPrefix("custom-"))
    }
}
