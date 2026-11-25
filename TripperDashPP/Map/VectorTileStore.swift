//
//  VectorTileStore.swift
//  TripperDashPP
//
//  Fetch → disk → decode → memory pipeline for the vector map's z14 tiles.
//
//  Same model as the raster path: tiles are fetched (cellular) along the
//  route corridor ahead of the rider and around the rider, kept on disk,
//  and decoded into `VectorTile`s off the main actor. The renderer only
//  ever reads the in-memory cache — a missing tile draws as background
//  and asks for a load, it never waits for one. Everything here is
//  URLSession + file I/O + CPU decode, so it runs on the locked screen
//  under the CoreLocation wakelock like the raster bakes do.
//
//  Disk layout: Caches/VectorTiles/<namespace>/<z>/<x>/<y>.pbf
//  (raw, uncompressed protobuf; an empty file = a tile with no data).
//  Eviction: 30 days since last read, then LRU down to 150 MB — a z14
//  tile averages ~30–60 KB, so that is ~3000+ tiles (~7000 km² of map).
//

import CoreLocation
import Foundation
import OSLog

nonisolated struct VectorTileKey: Hashable, Sendable, CustomStringConvertible {
    var z: Int
    var x: Int
    var y: Int

    var description: String { "\(z)/\(x)/\(y)" }
}

/// Decoded tiles shared by the store (writer) and the off-main renderer
/// (reader). NSCache is thread-safe.
nonisolated final class VectorTileMemoryCache: @unchecked Sendable {
    /// A 5×5 view block plus ~10 km of corridor ahead, with headroom.
    static let maxTiles = 96
    /// Dense city tiles cost ~0.5–1 MB of paths each.
    static let maxCost = 64 * 1024 * 1024

    private let cache = NSCache<NSString, VectorTile>()

    init() {
        cache.countLimit = Self.maxTiles
        cache.totalCostLimit = Self.maxCost
    }

    func tile(_ k: VectorTileKey) -> VectorTile? {
        cache.object(forKey: k.description as NSString)
    }

    func insert(_ t: VectorTile) {
        cache.setObject(t, forKey: VectorTileKey(z: t.z, x: t.x, y: t.y).description as NSString,
                        cost: t.cost)
    }

    func removeAll() { cache.removeAllObjects() }
}

/// On-disk `.pbf` cache. Separate from `TileDiskCache` (PNG only, its own
/// size cap) so the two pipelines can't evict each other's tiles.
actor VectorTileDiskCache {
    static let shared = VectorTileDiskCache()

    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "VectorTileDiskCache")
    private let maxAgeDays: TimeInterval = 30
    private let maxBytesOnDisk = 150 * 1024 * 1024

    private lazy var baseDir: URL = {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("VectorTiles", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func url(_ ns: String, _ k: VectorTileKey) -> URL {
        baseDir.appendingPathComponent(ns, isDirectory: true)
            .appendingPathComponent("\(k.z)", isDirectory: true)
            .appendingPathComponent("\(k.x)", isDirectory: true)
            .appendingPathComponent("\(k.y).pbf", isDirectory: false)
    }

    /// Raw tile bytes, or nil when not cached. Empty `Data` = a cached
    /// tile with no features (open sea). Bumps the mtime for LRU.
    func read(namespace ns: String, _ k: VectorTileKey) -> Data? {
        let u = url(ns, k)
        guard let data = try? Data(contentsOf: u, options: .mappedIfSafe) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path)
        return data
    }

    func write(namespace ns: String, _ k: VectorTileKey, data: Data) {
        let u = url(ns, k)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do {
            try data.write(to: u, options: .atomic)
        } catch {
            log.warning("vector tile write failed \(k.description, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func stats() -> (count: Int, bytes: Int) {
        guard let it = FileManager.default.enumerator(at: baseDir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return (0, 0)
        }
        var count = 0, total = 0
        for case let u as URL in it where u.pathExtension == "pbf" {
            count += 1
            total += (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        }
        return (count, total)
    }

    func clearAll() {
        let fm = FileManager.default
        try? fm.removeItem(at: baseDir)
        try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        log.info("vector tile cache cleared")
    }

    /// Age purge, then LRU down to the size cap. Once per launch.
    func evictIfNeeded() {
        let fm = FileManager.default
        guard let it = fm.enumerator(at: baseDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return
        }
        var entries: [(url: URL, size: Int, mtime: Date)] = []
        let now = Date()
        let cutoff = now.addingTimeInterval(-maxAgeDays * 86400)
        var aged = 0
        for case let u as URL in it where u.pathExtension == "pbf" {
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let mtime = v?.contentModificationDate ?? now
            if mtime < cutoff {
                try? fm.removeItem(at: u)
                aged += 1
                continue
            }
            entries.append((u, v?.fileSize ?? 0, mtime))
        }
        var total = entries.reduce(0) { $0 + $1.size }
        var sized = 0
        if total > maxBytesOnDisk {
            for e in entries.sorted(by: { $0.mtime < $1.mtime }) where total > maxBytesOnDisk {
                try? fm.removeItem(at: e.url)
                total -= e.size
                sized += 1
            }
        }
        if aged + sized > 0 {
            log.info("vector tile eviction: age=\(aged, privacy: .public) size=\(sized, privacy: .public) remaining=\(total / 1024, privacy: .public) KiB")
        }
    }
}

/// Main-actor coordinator: which tiles are wanted, which are loading.
final class VectorTileStore {
    static let shared = VectorTileStore()

    let memory = VectorTileMemoryCache()
    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "VectorTileStore")

    /// Wanted, not yet started, in priority order.
    private var queue: [VectorTileKey] = []
    private var queued: Set<VectorTileKey> = []
    private var loading: Set<VectorTileKey> = []
    /// Failed loads, retried after `retryAfter`.
    private var failedAt: [VectorTileKey: Date] = [:]
    /// Loads at once: the fetcher's own gate is 4; decode is CPU-bound.
    private let maxLoading = 4
    static let retryAfter: TimeInterval = 30

    /// Prefetch window. z14 tiles are ~1.6 km at 50°N, so ±2.5 km is a
    /// 4–5 tile wide band: enough for the tilted view's far edge.
    static let corridorAheadM: CLLocationDistance = 10_000
    static let corridorBehindM: CLLocationDistance = 1_000
    static let corridorRadiusM: CLLocationDistance = 2_500
    /// Around the rider (free ride, off-route, and the view itself).
    static let neighbourhoodRadiusM: CLLocationDistance = 2_000

    private(set) var stats = (fetched: 0, fromDisk: 0, failed: 0)

    // MARK: Read side (renderer)

    func tile(_ k: VectorTileKey) -> VectorTile? { memory.tile(k) }

    // MARK: Requests

    /// Ask for the tiles around the rider and along the route ahead.
    /// Cheap and idempotent: keys already cached / loading are skipped.
    /// The caller throttles (every few seconds).
    func prefetch(rider: CLLocationCoordinate2D, route: [CLLocationCoordinate2D]) {
        var keys = Self.tiles(around: rider, radiusM: Self.neighbourhoodRadiusM)
        if route.count >= 2 {
            keys += Self.corridorTiles(route: route, rider: rider,
                                       behindM: Self.corridorBehindM,
                                       aheadM: Self.corridorAheadM,
                                       radiusM: Self.corridorRadiusM)
        }
        request(keys)
    }

    /// Queue `keys` in the given priority order (first = most urgent).
    /// Keys requested again move to the front of the queue.
    func request(_ keys: [VectorTileKey]) {
        let now = Date()
        var fresh: [VectorTileKey] = []
        var seen = Set<VectorTileKey>()
        for k in keys where seen.insert(k).inserted {
            if memory.tile(k) != nil || loading.contains(k) { continue }
            if let f = failedAt[k], now.timeIntervalSince(f) < Self.retryAfter { continue }
            fresh.append(k)
        }
        guard !fresh.isEmpty else { return }
        let freshSet = Set(fresh)
        queue = fresh + queue.filter { !freshSet.contains($0) }
        queued.formUnion(freshSet)
        pump()
    }

    private func pump() {
        while loading.count < maxLoading, !queue.isEmpty {
            let k = queue.removeFirst()
            queued.remove(k)
            guard memory.tile(k) == nil else { continue }
            loading.insert(k)
            Task { @MainActor in
                let ok = await self.load(k)
                self.loading.remove(k)
                if ok { self.failedAt[k] = nil } else { self.failedAt[k] = Date() }
                self.pump()
            }
        }
    }

    private func load(_ k: VectorTileKey) async -> Bool {
        guard let endpoint = await VectorTileSource.shared.currentEndpoint() else {
            stats.failed += 1
            return false
        }
        let ns = endpoint.cacheNamespace
        var data = await VectorTileDiskCache.shared.read(namespace: ns, k)
        if data != nil {
            stats.fromDisk += 1
        } else {
            guard let url = endpoint.url(z: k.z, x: k.x, y: k.y) else { return false }
            do {
                let fetched = try await OSMTileFetcher.shared.fetch(
                    url: url, dedupeKey: "\(ns)/\(k.description).pbf",
                    accept: "application/x-protobuf,application/vnd.mapbox-vector-tile")
                await VectorTileDiskCache.shared.write(namespace: ns, k, data: fetched)
                data = fetched
                stats.fetched += 1
            } catch {
                stats.failed += 1
                log.notice("vector tile \(k.description, privacy: .public) fetch failed: \(String(describing: error), privacy: .public)")
                return false
            }
        }
        guard let data, let tile = await Self.decode(data, k) else {
            stats.failed += 1
            return false
        }
        memory.insert(tile)
        return true
    }

    /// Protobuf decode + path building, off the main actor.
    @concurrent nonisolated private static func decode(_ data: Data, _ k: VectorTileKey) async -> VectorTile? {
        if data.isEmpty {
            return VectorTile.build(layers: [], z: k.z, x: k.x, y: k.y)
        }
        return try? VectorTile.build(from: data, z: k.z, x: k.x, y: k.y)
    }

    func clearMemory() { memory.removeAll() }

    // MARK: Tile sets (pure)

    nonisolated static func key(for c: CLLocationCoordinate2D, zoom: Int = VectorTileSource.sourceZoom) -> VectorTileKey {
        let (fx, fy) = WebMercator.tile(for: c, zoom: zoom)
        let n = 1 << zoom
        return VectorTileKey(z: zoom, x: min(n - 1, max(0, Int(floor(fx)))), y: min(n - 1, max(0, Int(floor(fy)))))
    }

    /// Tiles intersecting the square of half-side `radiusM` around `c`,
    /// nearest first.
    nonisolated static func tiles(around c: CLLocationCoordinate2D, radiusM: CLLocationDistance,
                                  zoom: Int = VectorTileSource.sourceZoom) -> [VectorTileKey] {
        let box = WebMercator.tileBox(around: c, radiusMeters: radiusM, zoom: zoom)
        let n = 1 << zoom
        let (cx, cy) = WebMercator.tile(for: c, zoom: zoom)
        var out: [(VectorTileKey, Double)] = []
        for y in max(0, box.minY)...min(n - 1, box.maxY) {
            for x in max(0, box.minX)...min(n - 1, box.maxX) {
                let d = hypot(Double(x) + 0.5 - cx, Double(y) + 0.5 - cy)
                out.append((VectorTileKey(z: zoom, x: x, y: y), d))
            }
        }
        return out.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// Tiles within `radiusM` of the route from `behindM` before the
    /// rider's nearest route point to `aheadM` after it, ordered by
    /// distance along the route (ahead before behind). The route is
    /// sampled every ≤ 400 m, well under a z14 tile, so no tile on the
    /// band is skipped.
    nonisolated static func corridorTiles(route: [CLLocationCoordinate2D],
                                          rider: CLLocationCoordinate2D,
                                          behindM: CLLocationDistance,
                                          aheadM: CLLocationDistance,
                                          radiusM: CLLocationDistance,
                                          zoom: Int = VectorTileSource.sourceZoom) -> [VectorTileKey] {
        guard route.count >= 2 else { return [] }
        // Nearest vertex (planar metres around the rider — fine at this scale).
        let mLat = 111_320.0, mLon = 111_320.0 * cos(rider.latitude * .pi / 180)
        func d2(_ c: CLLocationCoordinate2D) -> Double {
            let dx = (c.longitude - rider.longitude) * mLon, dy = (c.latitude - rider.latitude) * mLat
            return dx * dx + dy * dy
        }
        var nearest = 0
        var best = Double.greatestFiniteMagnitude
        for (i, c) in route.enumerated() {
            let d = d2(c)
            if d < best { best = d; nearest = i }
        }
        func haversine(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
            let r = 6_371_000.0, rad = Double.pi / 180
            let dLat = (b.latitude - a.latitude) * rad, dLon = (b.longitude - a.longitude) * rad
            let h = sin(dLat / 2) * sin(dLat / 2)
                + cos(a.latitude * rad) * cos(b.latitude * rad) * sin(dLon / 2) * sin(dLon / 2)
            return 2 * r * asin(min(1, sqrt(h)))
        }
        let step: CLLocationDistance = 400
        var samples: [(CLLocationCoordinate2D, Double)] = [(route[nearest], 0)]
        // Walk one direction, emitting a sample every `step` metres.
        func walk(_ dir: Int, limit: CLLocationDistance) {
            var i = nearest
            var along: CLLocationDistance = 0
            var sinceSample: CLLocationDistance = 0
            while along < limit, route.indices.contains(i + dir) {
                let a = route[i], b = route[i + dir]
                let seg = haversine(a, b)
                var t: CLLocationDistance = step - sinceSample
                while t <= seg, along + t <= limit {
                    let f = seg > 0 ? t / seg : 0
                    let p = CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * f,
                                                   longitude: a.longitude + (b.longitude - a.longitude) * f)
                    samples.append((p, Double(dir) * (along + t)))
                    t += step
                }
                sinceSample = (sinceSample + seg).truncatingRemainder(dividingBy: step)
                along += seg
                i += dir
            }
            samples.append((route[i], Double(dir) * along))
        }
        walk(1, limit: aheadM)
        walk(-1, limit: behindM)
        // Ahead first by distance, then behind.
        samples.sort { a, b in
            (a.1 < 0 ? 1 : 0, abs(a.1)) < (b.1 < 0 ? 1 : 0, abs(b.1))
        }
        var out: [VectorTileKey] = []
        var seen = Set<VectorTileKey>()
        for (c, _) in samples {
            for k in tiles(around: c, radiusM: radiusM, zoom: zoom) where seen.insert(k).inserted {
                out.append(k)
            }
        }
        return out
    }
}
