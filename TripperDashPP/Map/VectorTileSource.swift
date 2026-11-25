//
//  VectorTileSource.swift
//  TripperDashPP
//
//  Resolves the vector-tile URL template from a TileJSON endpoint.
//
//  OpenFreeMap (keyless, no account) publishes a dated planet build:
//  `https://tiles.openfreemap.org/planet` → TileJSON whose `tiles[0]` is
//  `https://tiles.openfreemap.org/planet/<build>/{z}/{x}/{y}.pbf`, maxzoom
//  14, OpenMapTiles schema. The build path changes every few days, so the
//  template is resolved at runtime, cached in UserDefaults, refreshed at
//  most once a day, and the last good one is reused when a refresh fails
//  (e.g. on the bike's Wi-Fi, or with no signal).
//
//  The TileJSON URL is configurable (UserDefaults key
//  `vectorTiles.tileJSONURL`) so a self-hosted OpenMapTiles server can
//  replace OpenFreeMap without a code change — OpenFreeMap is
//  donation-funded with no SLA.
//

import Foundation
import OSLog

nonisolated struct VectorTileEndpoint: Sendable, Equatable, Codable {
    /// `{z}/{x}/{y}` URL template of the `.pbf` tiles.
    var template: String
    /// Highest zoom the source serves (requests above it return nothing).
    var maxZoom: Int
    var resolvedAt: Date

    func url(z: Int, x: Int, y: Int) -> URL? {
        URL(string: template
            .replacingOccurrences(of: "{z}", with: "\(z)")
            .replacingOccurrences(of: "{x}", with: "\(x)")
            .replacingOccurrences(of: "{y}", with: "\(y)"))
    }

    /// Disk-cache namespace for this endpoint: tiles from different
    /// providers must not be read as each other. Every OpenFreeMap build
    /// shares one namespace (`ofm`) — a tile a few days older than the
    /// current build is still the same roads.
    var cacheNamespace: String {
        template.contains("openfreemap.org") ? "ofm" : "custom-\(abs(Self.stableHash(template)) % 1_000_000)"
    }

    private static func stableHash(_ s: String) -> Int {
        // FNV-1a — `hashValue` is seeded per launch, so not usable on disk.
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Int(truncatingIfNeeded: h & 0x7FFF_FFFF)
    }

    /// Parse a TileJSON document; nil if it has no usable `.pbf` template.
    static func parse(tileJSON data: Data, now: Date = Date()) -> VectorTileEndpoint? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tiles = obj["tiles"] as? [String],
              let template = tiles.first,
              template.contains("{z}"), template.contains("{x}"), template.contains("{y}")
        else { return nil }
        let maxZoom = (obj["maxzoom"] as? Int) ?? 14
        return VectorTileEndpoint(template: template, maxZoom: maxZoom, resolvedAt: now)
    }
}

/// Resolves and caches the vector-tile endpoint. Main-actor (the app's
/// default) — a handful of calls per ride.
final class VectorTileSource {
    static let shared = VectorTileSource()

    static let defaultTileJSONURL = URL(string: "https://tiles.openfreemap.org/planet")!
    static let tileJSONURLDefaultsKey = "vectorTiles.tileJSONURL"
    private static let cachedEndpointKey = "vectorTiles.endpoint.v1"
    /// Re-resolve at most this often.
    static let refreshInterval: TimeInterval = 24 * 3600
    /// The z the renderer fetches: OpenMapTiles' highest, the only one with
    /// minor / service roads.
    nonisolated static let sourceZoom = 14

    /// "© OpenMapTiles © OpenStreetMap" — the attribution OpenFreeMap asks
    /// for, short enough for the dash frame.
    nonisolated static let attribution = "© OpenMapTiles © OpenStreetMap"

    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "VectorTileSource")
    private var resolving: Task<VectorTileEndpoint?, Never>?
    private var lastFailedAttempt: Date?
    static let retryAfterFailure: TimeInterval = 60

    /// Last good endpoint (persisted), if any.
    private(set) var endpoint: VectorTileEndpoint?

    init() {
        if let raw = UserDefaults.standard.data(forKey: Self.cachedEndpointKey),
           let e = try? JSONDecoder().decode(VectorTileEndpoint.self, from: raw) {
            endpoint = e
        }
    }

    var tileJSONURL: URL {
        if let s = UserDefaults.standard.string(forKey: Self.tileJSONURLDefaultsKey),
           let u = URL(string: s), u.scheme == "https" {
            return u
        }
        return Self.defaultTileJSONURL
    }

    /// The endpoint to use now: the cached one if it's fresh, else a
    /// refresh, else the stale cached one. nil only before the first
    /// successful resolve.
    func currentEndpoint(now: Date = Date()) async -> VectorTileEndpoint? {
        if let e = endpoint, now.timeIntervalSince(e.resolvedAt) < Self.refreshInterval {
            return e
        }
        if let resolving { return await resolving.value ?? endpoint }
        // After a failure, don't re-ask on every call (prefetch runs every
        // few seconds); a stale endpoint keeps working meanwhile.
        if let failed = lastFailedAttempt, now.timeIntervalSince(failed) < Self.retryAfterFailure {
            return endpoint
        }
        let url = tileJSONURL
        let task = Task<VectorTileEndpoint?, Never> {
            do {
                let data = try await OSMTileFetcher.shared.fetch(
                    url: url, dedupeKey: "tilejson/\(url.absoluteString)", accept: "application/json")
                return VectorTileEndpoint.parse(tileJSON: data)
            } catch {
                return nil
            }
        }
        resolving = task
        let fresh = await task.value
        resolving = nil
        if let fresh {
            if fresh.template != endpoint?.template {
                log.info("vector tiles: endpoint \(fresh.template, privacy: .public) maxzoom \(fresh.maxZoom, privacy: .public)")
            }
            endpoint = fresh
            if let raw = try? JSONEncoder().encode(fresh) {
                UserDefaults.standard.set(raw, forKey: Self.cachedEndpointKey)
            }
            return fresh
        }
        lastFailedAttempt = now
        log.notice("vector tiles: TileJSON refresh failed, using \(self.endpoint == nil ? "nothing" : "the last good endpoint", privacy: .public)")
        return endpoint
    }
}
