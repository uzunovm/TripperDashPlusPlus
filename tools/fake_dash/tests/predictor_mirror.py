"""Python mirror of TripperDashPP/Map/PositionPredictor.swift.

Same constants and maths, so the smoothing behaviour (re-anchor on every
fix, capped extrapolation, decaying residual) can be exercised here and
the Swift constants are pinned by a drift guard.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

WINDOW_BEHIND_M = 200.0
WINDOW_AHEAD_M = 500.0
MAX_EXTRAPOLATION_S = 1.2
MAX_EXTRAPOLATION_M = 20.0
STOP_SPEED_MPS = 1.5
SPEED_ALPHA = 0.5
RESIDUAL_DECAY = 0.5
SNAP_RESIDUAL_M = 25.0
TANGENT_BEHIND_M = 5.0
TANGENT_AHEAD_M = 15.0
METRES_PER_DEGREE = 6_371_000.0 * math.pi / 180


def snap_threshold(accuracy: float) -> float:
    acc = accuracy if accuracy >= 0 else 40
    return min(60.0, max(30.0, 1.5 * acc))


def haversine(a, b) -> float:
    r = 6_371_000.0
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = p2 - p1, math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(min(1.0, math.sqrt(h)))


def offset(c, east_m: float, north_m: float):
    return (c[0] + north_m / METRES_PER_DEGREE,
            c[1] + east_m / (METRES_PER_DEGREE * math.cos(math.radians(c[0]))))


def offset_m(a, b):
    return ((b[1] - a[1]) * METRES_PER_DEGREE * math.cos(math.radians(a[0])),
            (b[0] - a[0]) * METRES_PER_DEGREE)


def bearing(a, b) -> float:
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dl = math.radians(b[1] - a[1])
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    d = math.degrees(math.atan2(y, x))
    return d + 360 if d < 0 else d


@dataclass
class Sample:
    coord: tuple
    accuracy: float
    speed: float
    course: float
    time: float


class PositionPredictor:
    def __init__(self, route=()):
        self.route = list(route)
        self.cum = []
        d = 0.0
        for i, c in enumerate(self.route):
            if i:
                d += haversine(self.route[i - 1], c)
            self.cum.append(d)
        self.fix = None
        self.speed_ema = None
        self.anchor = None
        self.residual = (0.0, 0.0)
        self.last_output = None

    def _seg(self, a: float) -> int:
        lo, hi = 0, len(self.cum) - 1
        if a <= 0:
            return 0
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if self.cum[mid] <= a:
                lo = mid
            else:
                hi = mid - 1
        return lo

    def project(self, c, arc_range=None):
        if len(self.route) < 2:
            return None
        lo, hi = 0, len(self.route) - 1
        if arc_range:
            lo = max(0, self._seg(arc_range[0]))
            hi = min(len(self.route) - 1, self._seg(arc_range[1]) + 1)
        if lo >= hi:
            return None
        kx, ky = math.cos(math.radians(c[0])) * METRES_PER_DEGREE, METRES_PER_DEGREE
        best = None
        for i in range(lo, hi):
            a, b = self.route[i], self.route[i + 1]
            ax, ay = (a[1] - c[1]) * kx, (a[0] - c[0]) * ky
            bx, by = (b[1] - c[1]) * kx, (b[0] - c[0]) * ky
            dx, dy = bx - ax, by - ay
            l2 = dx * dx + dy * dy
            t = min(1.0, max(0.0, -(ax * dx + ay * dy) / l2)) if l2 > 0 else 0.0
            d = math.hypot(ax + t * dx, ay + t * dy)
            if best is None or d < best[1]:
                best = (self.cum[i] + t * (self.cum[i + 1] - self.cum[i]), d)
        return best

    def point_at(self, arc: float):
        a = min(max(0.0, arc), self.cum[-1])
        i = min(self._seg(a), len(self.route) - 2)
        seg = self.cum[i + 1] - self.cum[i]
        t = (a - self.cum[i]) / seg if seg > 0 else 0.0
        p, q = self.route[i], self.route[i + 1]
        return (p[0] + t * (q[0] - p[0]), p[1] + t * (q[1] - p[1]))

    def _model(self, time: float):
        f = self.fix
        v = self.speed_ema or 0.0
        v = 0.0 if v < STOP_SPEED_MPS else v
        dt = min(max(0.0, time - f.time), MAX_EXTRAPOLATION_S)
        dist = min(v * dt, MAX_EXTRAPOLATION_M)
        if self.anchor is not None:
            a = min(self.anchor + dist, self.cum[-1])
            h = bearing(self.point_at(a - TANGENT_BEHIND_M), self.point_at(a + TANGENT_AHEAD_M)) if v > 0 else None
            return self.point_at(a), h, True
        if dist <= 0 or f.course < 0:
            return f.coord, None, False
        th = math.radians(f.course)
        return offset(f.coord, dist * math.sin(th), dist * math.cos(th)), None, False

    def ingest(self, s: Sample):
        if s.speed >= 0:
            self.speed_ema = s.speed if self.speed_ema is None else SPEED_ALPHA * s.speed + (1 - SPEED_ALPHA) * self.speed_ema
        new_anchor = None
        if len(self.route) >= 2:
            rng = None if self.anchor is None else (self.anchor - WINDOW_BEHIND_M, self.anchor + WINDOW_AHEAD_M)
            p = self.project(s.coord, rng)
            if p and p[1] < snap_threshold(s.accuracy):
                new_anchor = p[0]
        self.fix = s
        self.anchor = new_anchor  # ALWAYS the measured arc, never max()
        if self.last_output is not None:
            target = self._model(s.time)[0]
            e, n = offset_m(target, self.last_output[0])
            self.residual = (0.0, 0.0) if math.hypot(e, n) > SNAP_RESIDUAL_M else (e, n)

    def predict(self, time: float):
        if self.fix is None:
            return None
        c, h, snapped = self._model(time)
        e, n = self.residual[0] * RESIDUAL_DECAY, self.residual[1] * RESIDUAL_DECAY
        self.residual = (0.0, 0.0) if abs(e) < 0.05 and abs(n) < 0.05 else (e, n)
        out = (offset(c, *self.residual), h, snapped)
        self.last_output = out
        return out
