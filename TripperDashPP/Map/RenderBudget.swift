//
//  RenderBudget.swift
//  TripperDashPP
//
//  Frame-time bookkeeping for the vector renderer: a rolling mean that
//  steps the level of detail down when frames get slow and back up (with
//  hysteresis) when they recover, plus the once-a-minute log line. The
//  render loop never skips a frame for it — it only draws less.
//
//  Budget: a 4 fps slot is 250 ms; the base map should stay well under
//  that so overlays, encode and send fit too. Over ~90 ms average the
//  detail drops one step; under ~45 ms it climbs back one step.
//

import Foundation

nonisolated struct RenderBudget: Sendable {
    /// 0 = everything; 1 = no labels; 2 = also no minor roads; 3 = also no
    /// landcover (water and main roads only).
    private(set) var level = 0
    static let maxLevel = 3

    static let degradeAboveMs: Double = 90
    static let recoverBelowMs: Double = 45
    /// A single frame this slow is logged at once.
    static let slowFrameMs: Double = 150

    /// Exponential moving average of frame time.
    private(set) var meanMs: Double = 0
    private var samples = 0
    /// Frames since the last level change (don't flap).
    private var sinceChange = 0
    private static let alpha = 0.2
    private static let settleFrames = 8

    // Per-log-window stats.
    private var windowTimes: [Double] = []
    private var windowDrops = 0

    var detail: VectorDetail {
        VectorDetail(minorRoads: level < 2, serviceAndTracks: level < 2, landcover: level < 3)
    }

    var labels: Bool { level < 1 }

    /// Record one frame. Returns true when the level changed.
    @discardableResult
    mutating func record(ms: Double) -> Bool {
        meanMs = samples == 0 ? ms : meanMs + Self.alpha * (ms - meanMs)
        samples += 1
        sinceChange += 1
        windowTimes.append(ms)
        guard sinceChange >= Self.settleFrames else { return false }
        if meanMs > Self.degradeAboveMs, level < Self.maxLevel {
            level += 1
            windowDrops += 1
            sinceChange = 0
            return true
        }
        if meanMs < Self.recoverBelowMs, level > 0 {
            level -= 1
            sinceChange = 0
            return true
        }
        return false
    }

    /// `vector render: n=240 mean 21 ms p95 34 ms max 48 ms lod=0 drops=0`,
    /// then resets the window. nil when no frames were recorded.
    mutating func takeLogLine(label: String = "vector render") -> String? {
        guard !windowTimes.isEmpty else { return nil }
        let sorted = windowTimes.sorted()
        let n = sorted.count
        let mean = sorted.reduce(0, +) / Double(n)
        let p95 = sorted[min(n - 1, Int(Double(n) * 0.95))]
        let line = "\(label): n=\(n) mean \(Int(mean.rounded())) ms p95 \(Int(p95.rounded())) ms max \(Int(sorted[n - 1].rounded())) ms lod=\(level) drops=\(windowDrops)"
        windowTimes.removeAll(keepingCapacity: true)
        windowDrops = 0
        return line
    }
}
