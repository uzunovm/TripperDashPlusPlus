//
//  PositionPredictor.swift
//  TripperDashPP
//
//  Smooths the rendered rider position between the ~1 Hz GPS fixes, so
//  the map glides at the 4 fps render rate instead of stepping once a
//  second.
//
//  Learned from the removed MotionInterpolator (see `MapViewSource
//  .handleFix`): its anchor was `max(anchor, measured)`, so whenever the
//  bike slowed the marker ran ahead and kept that lead — kilometres of
//  one-way drift over a ride. Here every fix RESETS the anchor to the
//  measured arc length, ahead or behind, and the extrapolation is capped
//  at 1.2 s / 20 m past the last fix, so the error can never exceed one
//  fix interval's worth of travel.
//
//  Per fix:
//    - project onto the route within −200…+500 m of the last anchor (the
//      whole route when there was none); snapped when the lateral offset
//      is under clamp(1.5 × accuracy, 30, 60) m;
//    - speed: EMA (α 0.5) of the GPS speed, treated as 0 below 1.5 m/s.
//  Per frame:
//    - snapped: advance along the route by v × dt; heading = the route's
//      bearing from 5 m behind to 15 m ahead;
//    - free ride / off route: extrapolate the raw fix along its GPS course;
//    - the jump a new fix causes is spread out: the residual halves every
//      frame, and one over 25 m is dropped (snap at once).
//
//  Only the rendered position uses this. Route following, alerts, ride
//  stats and tile prefetch keep the raw fix. Pure value type.
//

import CoreLocation
import Foundation

nonisolated struct PositionPredictor: Sendable {
    struct Sample: Sendable {
        var coordinate: CLLocationCoordinate2D
        /// m; < 0 = unknown.
        var accuracy: Double
        /// m/s; < 0 = unknown.
        var speed: Double
        /// degrees; < 0 = unknown.
        var course: Double
        /// Monotonic seconds (when the fix arrived).
        var time: Double
    }

    struct Output: Equatable, Sendable {
        var coordinate: CLLocationCoordinate2D
        /// Route bearing at the rider when snapped and moving; nil = keep
        /// the GPS-course / compass heading.
        var headingDegrees: Double?
        var snapped: Bool

        static func == (a: Output, b: Output) -> Bool {
            a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
                && a.headingDegrees == b.headingDegrees && a.snapped == b.snapped
        }
    }

    // Tuning (see header).
    static let windowBehindM = 200.0
    static let windowAheadM = 500.0
    static let maxExtrapolationS = 1.2
    static let maxExtrapolationM = 20.0
    static let stopSpeedMPS = 1.5
    static let speedAlpha = 0.5
    static let residualDecay = 0.5
    static let snapResidualM = 25.0
    static let tangentBehindM = 5.0
    static let tangentAheadM = 15.0

    static func snapThreshold(accuracy: Double) -> Double {
        let acc = accuracy >= 0 ? accuracy : 40
        return min(60, max(30, 1.5 * acc))
    }

    // Route.
    private var route: [CLLocationCoordinate2D] = []
    /// Cumulative metres at each vertex.
    private var cum: [Double] = []
    private var routeSignature: (Int, Double, Double, Double, Double)?

    // Last fix.
    private var fix: Sample?
    private var speedEMA: Double?
    /// Route arc length of the last fix, when it snapped.
    private(set) var anchorArcM: Double?

    // Rendered position = model + residual (east, north metres).
    private var residual = (e: 0.0, n: 0.0)
    private var lastOutput: Output?

    // Once-a-minute stats.
    private var statFixes = 0
    private var statSnapped = 0
    private var statCorrSum = 0.0
    private var statCorrMax = 0.0
    private var statHardSnaps = 0

    var isSnapped: Bool { anchorArcM != nil }

    // MARK: Route

    /// Set the route (empty = free ride). Cheap when unchanged.
    mutating func setRoute(_ coords: [CLLocationCoordinate2D]) {
        let sig = coords.isEmpty ? nil : (coords.count, coords[0].latitude, coords[0].longitude,
                                          coords[coords.count - 1].latitude, coords[coords.count - 1].longitude)
        if let a = sig, let b = routeSignature, a == b { return }
        if sig == nil && routeSignature == nil { return }
        routeSignature = sig
        route = coords
        cum = []
        cum.reserveCapacity(coords.count)
        var d = 0.0
        for i in coords.indices {
            if i > 0 { d += Self.haversine(coords[i - 1], coords[i]) }
            cum.append(d)
        }
        anchorArcM = nil
    }

    mutating func reset() {
        fix = nil
        speedEMA = nil
        anchorArcM = nil
        residual = (0, 0)
        lastOutput = nil
    }

    // MARK: Fixes

    mutating func ingest(_ s: Sample) {
        if s.speed >= 0 {
            speedEMA = speedEMA.map { Self.speedAlpha * s.speed + (1 - Self.speedAlpha) * $0 } ?? s.speed
        }
        // Snap against the route, windowed around the previous anchor.
        var newAnchor: Double?
        if route.count >= 2 {
            let range: ClosedRange<Double>? = anchorArcM.map {
                ($0 - Self.windowBehindM)...($0 + Self.windowAheadM)
            }
            if let p = project(s.coordinate, arcRange: range),
               p.lateralM < Self.snapThreshold(accuracy: s.accuracy) {
                newAnchor = p.arcM
            }
        }
        fix = s
        // ALWAYS the measured arc: ahead or behind the prediction.
        anchorArcM = newAnchor

        // Carry the on-screen position over as a decaying residual.
        statFixes += 1
        if newAnchor != nil { statSnapped += 1 }
        if let shown = lastOutput {
            let target = model(at: s.time).coordinate
            let (e, n) = Self.offsetM(from: target, to: shown.coordinate)
            let d = hypot(e, n)
            statCorrSum += d
            statCorrMax = max(statCorrMax, d)
            if d > Self.snapResidualM {
                residual = (0, 0)
                statHardSnaps += 1
            } else {
                residual = (e, n)
            }
        }
    }

    // MARK: Frames

    /// The position to draw at `time` (monotonic seconds); nil before the
    /// first fix. Call once per rendered frame (the residual decays per call).
    mutating func predict(at time: Double) -> Output? {
        guard fix != nil else { return nil }
        var out = model(at: time)
        residual = (residual.e * Self.residualDecay, residual.n * Self.residualDecay)
        if abs(residual.e) < 0.05 && abs(residual.n) < 0.05 { residual = (0, 0) }
        out.coordinate = Self.offset(out.coordinate, eastM: residual.e, northM: residual.n)
        lastOutput = out
        return out
    }

    /// Where the model puts the rider at `time`, without the residual.
    private func model(at time: Double) -> Output {
        guard let f = fix else { return Output(coordinate: CLLocationCoordinate2D(), headingDegrees: nil, snapped: false) }
        let v = (speedEMA ?? 0) < Self.stopSpeedMPS ? 0 : (speedEMA ?? 0)
        let dt = min(max(0, time - f.time), Self.maxExtrapolationS)
        let dist = min(v * dt, Self.maxExtrapolationM)
        if let arc = anchorArcM {
            let a = min(arc + dist, cum.last ?? arc)
            let heading = v > 0 ? Self.bearing(point(atArc: a - Self.tangentBehindM),
                                               point(atArc: a + Self.tangentAheadM)) : nil
            return Output(coordinate: point(atArc: a), headingDegrees: heading, snapped: true)
        }
        guard dist > 0, f.course >= 0 else {
            return Output(coordinate: f.coordinate, headingDegrees: nil, snapped: false)
        }
        let th = f.course * .pi / 180
        return Output(coordinate: Self.offset(f.coordinate, eastM: dist * sin(th), northM: dist * cos(th)),
                      headingDegrees: nil, snapped: false)
    }

    // MARK: Log

    /// "position smoothing: fixes=.. snapped=..% corr mean .. m max .. m hard=..",
    /// then the counters reset. nil when no fix came in.
    mutating func takeLogLine() -> String? {
        guard statFixes > 0 else { return nil }
        let line = String(format: "position smoothing: fixes=%d snapped=%d%% corr mean %.1f m max %.1f m hard=%d",
                          statFixes, Int((Double(statSnapped) / Double(statFixes) * 100).rounded()),
                          statCorrSum / Double(statFixes), statCorrMax, statHardSnaps)
        statFixes = 0; statSnapped = 0; statCorrSum = 0; statCorrMax = 0; statHardSnaps = 0
        return line
    }

    // MARK: Geometry

    /// Nearest point of the route (optionally only within `arcRange`).
    func project(_ c: CLLocationCoordinate2D, arcRange: ClosedRange<Double>?) -> (arcM: Double, lateralM: Double)? {
        guard route.count >= 2 else { return nil }
        var lo = 0, hi = route.count - 1
        if let r = arcRange {
            lo = max(0, Self.segmentIndex(cum, r.lowerBound))
            hi = min(route.count - 1, Self.segmentIndex(cum, r.upperBound) + 1)
        }
        guard lo < hi else { return nil }
        let kx = cos(c.latitude * .pi / 180) * Self.metresPerDegree, ky = Self.metresPerDegree
        var best: (arcM: Double, lateralM: Double)?
        for i in lo..<hi {
            let a = route[i], b = route[i + 1]
            let ax = (a.longitude - c.longitude) * kx, ay = (a.latitude - c.latitude) * ky
            let bx = (b.longitude - c.longitude) * kx, by = (b.latitude - c.latitude) * ky
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? min(1, max(0, -(ax * dx + ay * dy) / len2)) : 0
            let d = hypot(ax + t * dx, ay + t * dy)
            if best == nil || d < best!.lateralM {
                best = (cum[i] + t * (cum[i + 1] - cum[i]), d)
            }
        }
        return best
    }

    /// The route point `arc` metres from its start (clamped to the ends).
    func point(atArc arc: Double) -> CLLocationCoordinate2D {
        guard let first = route.first else { return CLLocationCoordinate2D() }
        guard route.count >= 2 else { return first }
        let total = cum[cum.count - 1]
        let a = min(max(0, arc), total)
        let i = min(Self.segmentIndex(cum, a), route.count - 2)
        let seg = cum[i + 1] - cum[i]
        let t = seg > 0 ? (a - cum[i]) / seg : 0
        let p = route[i], q = route[i + 1]
        return CLLocationCoordinate2D(latitude: p.latitude + t * (q.latitude - p.latitude),
                                      longitude: p.longitude + t * (q.longitude - p.longitude))
    }

    /// Index of the segment containing arc `a` (last i with cum[i] <= a).
    private static func segmentIndex(_ cum: [Double], _ a: Double) -> Int {
        var lo = 0, hi = cum.count - 1
        if a <= 0 { return 0 }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if cum[mid] <= a { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// On the same 6371 km sphere as `haversine`, so arc lengths and
    /// local offsets agree.
    static let metresPerDegree = 6_371_000.0 * .pi / 180

    static func haversine(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let r = 6_371_000.0
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dp = p2 - p1, dl = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dl = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        let deg = atan2(y, x) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }

    static func offset(_ c: CLLocationCoordinate2D, eastM: Double, northM: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: c.latitude + northM / Self.metresPerDegree,
                               longitude: c.longitude + eastM / (Self.metresPerDegree * cos(c.latitude * .pi / 180)))
    }

    static func offsetM(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> (Double, Double) {
        ((b.longitude - a.longitude) * Self.metresPerDegree * cos(a.latitude * .pi / 180),
         (b.latitude - a.latitude) * Self.metresPerDegree)
    }
}
