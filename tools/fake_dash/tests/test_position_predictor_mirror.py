"""PositionPredictor: no one-way drift, capped extrapolation, Swift constants pinned."""

from __future__ import annotations

import pathlib
import re

from tests import predictor_mirror as pm
from tests.swift_source import strip_comments

SWIFT = pathlib.Path(__file__).resolve().parents[3] / "TripperDashPP/Map/PositionPredictor.swift"
ORIGIN = (50.0, 14.0)


def east(m, north=0.0):
    return pm.offset(ORIGIN, m, north)


def metres(c):
    return pm.offset_m(ORIGIN, c)


def route():
    return [east(m) for m in range(0, 5001, 50)]


def s(m, north=0.0, speed=10.0, course=90.0, t=0.0, acc=5.0):
    return pm.Sample(east(m, north), acc, speed, course, t)


def test_glides_along_the_route():
    p = pm.PositionPredictor(route())
    p.ingest(s(100, north=8))
    c, h, snapped = p.predict(0.25)
    assert snapped and abs(metres(c)[1]) < 0.5 and abs(metres(c)[0] - 102.5) < 0.5
    assert abs(p.predict(0.75)[1] - 90) < 1


def test_extrapolation_capped():
    p = pm.PositionPredictor(route())
    p.ingest(s(100, speed=30))
    assert abs(metres(p.predict(10)[0])[0] - 120) < 0.5


def test_slow_fixes_never_build_a_lead():
    """The 2026-09-02 drift: the marker must not run ahead of slow fixes."""
    p = pm.PositionPredictor(route())
    t = 0.0
    for k in range(300):  # 5 minutes at 1 Hz, crawling at 1.6 m/s
        p.ingest(s(100 + k * 1.6, speed=1.6, t=t))
        for f in range(1, 5):
            c = p.predict(t + f * 0.25)[0]
        lead = metres(c)[0] - (100 + k * 1.6)
        assert lead < 1.6 * pm.MAX_EXTRAPOLATION_S + 0.5
        t += 1.0
    assert abs(p.anchor - (100 + 299 * 1.6)) < 0.5


def test_fix_behind_prediction_resets_anchor():
    p = pm.PositionPredictor(route())
    p.ingest(s(100))
    for f in range(1, 5):
        p.predict(f * 0.25)
    p.ingest(s(103, speed=2, t=1))
    assert abs(p.anchor - 103) < 0.5


def test_long_gap_jumps_then_resnaps():
    p = pm.PositionPredictor(route())
    p.ingest(s(100))
    p.predict(0.25)
    assert abs(metres(p.predict(60)[0])[0] - 112) < 0.5
    p.ingest(s(1600, north=3, t=61))
    c, _, snapped = p.predict(61)
    assert not snapped and abs(metres(c)[0] - 1600) < 0.5
    p.ingest(s(1610, t=62))
    assert abs(p.anchor - 1610) < 0.5


def test_snap_threshold():
    assert [pm.snap_threshold(a) for a in (5, 30, 100, -1)] == [30, 45, 60, 60]


def test_swift_constants_match_the_mirror():
    src = strip_comments(SWIFT.read_text(encoding="utf-8"))
    pins = {
        "windowBehindM": pm.WINDOW_BEHIND_M, "windowAheadM": pm.WINDOW_AHEAD_M,
        "maxExtrapolationS": pm.MAX_EXTRAPOLATION_S, "maxExtrapolationM": pm.MAX_EXTRAPOLATION_M,
        "stopSpeedMPS": pm.STOP_SPEED_MPS, "speedAlpha": pm.SPEED_ALPHA,
        "residualDecay": pm.RESIDUAL_DECAY, "snapResidualM": pm.SNAP_RESIDUAL_M,
        "tangentBehindM": pm.TANGENT_BEHIND_M, "tangentAheadM": pm.TANGENT_AHEAD_M,
    }
    for name, value in pins.items():
        m = re.search(rf"static let {name} = ([0-9.]+)", src)
        assert m, name
        assert float(m.group(1)) == value, name
    # The anchor is always the measured arc — no max() re-anchor.
    assert "anchorArcM = newAnchor" in src
    assert not re.search(r"anchorArcM\s*=\s*max\(", src)


def test_only_the_rendered_position_is_smoothed():
    mvs = strip_comments((SWIFT.parent / "MapViewSource.swift").read_text(encoding="utf-8"))
    assert "predictor.predict(at:" in mvs
    # Route following / alerts still read the raw fix.
    assert "recomputeSpeedLimit(for: fix)" in mvs
