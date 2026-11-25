import CoreLocation
import Foundation
import Testing
@testable import TripperDashPP

struct PositionPredictorTests {
    /// A straight 5 km route due east along latitude 50.
    private let origin = CLLocationCoordinate2D(latitude: 50, longitude: 14)
    private func east(_ m: Double, north: Double = 0) -> CLLocationCoordinate2D {
        PositionPredictor.offset(origin, eastM: m, northM: north)
    }
    private var route: [CLLocationCoordinate2D] { stride(from: 0.0, through: 5000, by: 50).map { east($0) } }

    private func sample(_ m: Double, north: Double = 0, speed: Double = 10, course: Double = 90,
                        accuracy: Double = 5, t: Double) -> PositionPredictor.Sample {
        .init(coordinate: east(m, north: north), accuracy: accuracy, speed: speed, course: course, time: t)
    }

    /// Metres east of the origin (and signed north offset).
    private func metres(_ c: CLLocationCoordinate2D) -> (e: Double, n: Double) {
        PositionPredictor.offsetM(from: origin, to: c)
    }

    private func at(_ p: inout PositionPredictor, _ t: Double) throws -> PositionPredictor.Output {
        let out = p.predict(at: t)
        return try #require(out)
    }

    private func predictor() -> PositionPredictor {
        var p = PositionPredictor()
        p.setRoute(route)
        return p
    }

    @Test func snapsAndGlidesAlongTheRoute() throws {
        var p = predictor()
        p.ingest(sample(100, north: 8, t: 0))
        let a = try at(&p, 0.25)
        #expect(a.snapped)
        #expect(abs(metres(a.coordinate).n) < 0.5, "drawn on the line, not 8 m off it")
        #expect(abs(metres(a.coordinate).e - 102.5) < 0.5)
        let b = try at(&p, 0.75)
        #expect(abs(metres(b.coordinate).e - 107.5) < 0.5)
        #expect(abs(try #require(b.headingDegrees) - 90) < 1)
    }

    @Test func extrapolationIsCapped() throws {
        var p = predictor()
        p.ingest(sample(100, speed: 30, t: 0))
        let far = try at(&p, 10)
        // min(30 m/s × 1.2 s, 20 m) = 20 m.
        #expect(abs(metres(far.coordinate).e - 120) < 0.5)
        var slow = predictor()
        slow.ingest(sample(100, speed: 5, t: 0))
        // 5 m/s × 1.2 s = 6 m.
        #expect(abs(metres(try at(&slow, 10).coordinate).e - 106) < 0.5)
    }

    @Test func aFixBehindThePredictionPullsTheAnchorBack() throws {
        var p = predictor()
        p.ingest(sample(100, speed: 10, t: 0))
        for f in 1...4 { _ = p.predict(at: Double(f) * 0.25) }   // marker at ~110
        // The bike braked: the next fix is only 3 m on, and slow.
        p.ingest(sample(103, speed: 2, t: 1))
        #expect(abs(try #require(p.anchorArcM) - 103) < 0.5, "anchor = measured, never max()")
        // Residual decays: within a few frames the marker is back near 103.
        var last = 0.0
        for f in 1...8 { last = metres(try at(&p, 1 + Double(f) * 0.25).coordinate).e }
        // EMA speed (10+2)/2 = 6 m/s, extrapolation capped at 1.2 s → ≤ 110.2.
        #expect(last < 110.3 && last > 103)
        // Repeated slow fixes: no drift ahead accumulates.
        for k in 0..<20 {
            let t = 3 + Double(k)
            p.ingest(sample(103 + Double(k) * 1.6, speed: 1.6, t: t))
            for f in 1...4 { _ = p.predict(at: t + Double(f) * 0.25) }
        }
        let end = metres(try at(&p, 23).coordinate).e
        #expect(abs(end - (103 + 19 * 1.6)) < 3)
    }

    @Test func stoppedBikeStaysPut() throws {
        var p = predictor()
        p.ingest(sample(200, speed: 1.0, t: 0))
        let a = try at(&p, 1.0)
        #expect(abs(metres(a.coordinate).e - 200) < 0.1)
        #expect(a.headingDegrees == nil)
    }

    @Test func longGpsGapRecoversWithoutGliding() throws {
        var p = predictor()
        p.ingest(sample(100, t: 0))
        for f in 1...4 { _ = p.predict(at: Double(f) * 0.25) }
        // 60 s with no fix: the marker stops 12 m on, it doesn't run away.
        let stuck = metres(try at(&p, 60).coordinate).e
        #expect(abs(stuck - 112) < 0.5)
        // Next fix 1.5 km on, outside the +500 m window: not snapped yet,
        // drawn at the raw fix at once (no 1.4 km glide).
        p.ingest(sample(1600, north: 3, t: 61))
        let jump = try at(&p, 61)
        #expect(!jump.snapped)
        #expect(abs(metres(jump.coordinate).e - 1600) < 0.5)
        // The fix after re-snaps on a whole-route search.
        p.ingest(sample(1610, t: 62))
        #expect(abs(try #require(p.anchorArcM) - 1610) < 0.5)
    }

    @Test func offRouteFollowsTheGpsCourse() throws {
        var p = predictor()
        // 80 m north of the line: over the 30…60 m snap threshold.
        p.ingest(sample(500, north: 80, speed: 10, course: 0, t: 0))
        let a = try at(&p, 0.5)
        #expect(!a.snapped)
        #expect(a.headingDegrees == nil)
        #expect(abs(metres(a.coordinate).n - 85) < 0.5)
        #expect(abs(metres(a.coordinate).e - 500) < 0.5)
    }

    @Test func freeRideExtrapolatesTheRawFix() throws {
        var p = PositionPredictor()
        p.setRoute([])
        p.ingest(sample(0, speed: 8, course: 90, t: 0))
        let a = try at(&p, 1)
        #expect(!a.snapped)
        #expect(abs(metres(a.coordinate).e - 8) < 0.5)
    }

    @Test func snapThresholdFollowsAccuracy() {
        #expect(PositionPredictor.snapThreshold(accuracy: 5) == 30)
        #expect(PositionPredictor.snapThreshold(accuracy: 30) == 45)
        #expect(PositionPredictor.snapThreshold(accuracy: 100) == 60)
        #expect(PositionPredictor.snapThreshold(accuracy: -1) == 60)
    }

    @Test func headingFollowsTheRouteThroughABend() throws {
        // East 1 km, then north 1 km.
        let corner = east(1000)
        let bend = stride(from: 0.0, through: 1000, by: 50).map { east($0) }
            + stride(from: 50.0, through: 1000, by: 50).map { PositionPredictor.offset(corner, eastM: 0, northM: $0) }
        var p = PositionPredictor()
        p.setRoute(bend)
        p.ingest(.init(coordinate: PositionPredictor.offset(corner, eastM: 0, northM: 100),
                       accuracy: 5, speed: 10, course: 0, time: 0))
        let h = try #require(try at(&p, 0.1).headingDegrees)
        #expect(abs(h) < 1 || abs(h - 360) < 1)
    }

    @Test func logLineSummarisesAndResets() {
        var p = predictor()
        p.ingest(sample(100, t: 0))
        _ = p.predict(at: 0.25)
        p.ingest(sample(110, t: 1))
        let line = p.takeLogLine()
        #expect(line?.hasPrefix("position smoothing: fixes=2 snapped=100% ") == true)
        #expect(p.takeLogLine() == nil)
    }
}
