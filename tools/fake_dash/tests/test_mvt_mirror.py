"""MVT decoder mirror (`mvt_mirror.py`) against the same fixture tiles the
Swift `MVTDecoderTests` use, plus drift guards on the Swift decoder.

The pinned counts here and in `MVTDecoderTests.swift` must agree: both
decoders read the same files, so a mismatch means one of them drifted.
"""

from __future__ import annotations

import gzip
import pathlib

import pytest

from tests.mvt_mirror import decode, decode_geometry
from tests.swift_source import decl_body, strip_comments

APP = pathlib.Path(__file__).resolve().parents[3] / "TripperDashPP"
FIXTURES = APP / "TripperDashPPTests" / "Fixtures"


def _counts(name: str, **kw) -> dict[str, int]:
    return {l["name"]: len(l["features"]) for l in decode((FIXTURES / name).read_bytes(), **kw)}


def test_dense_city_counts():
    assert _counts("mvt_14_8848_5555_prague.pbf") == {
        "boundary": 1, "building": 21, "housenumber": 765, "landcover": 336,
        "landuse": 75, "mountain_peak": 2, "park": 4, "place": 9, "poi": 1154,
        "transportation": 179, "transportation_name": 95, "water": 10,
        "water_name": 11, "waterway": 24,
    }


def test_rural_counts():
    assert _counts("mvt_14_8874_5591_rural.pbf") == {
        "boundary": 1, "building": 3, "housenumber": 3, "landcover": 57,
        "landuse": 2, "place": 7, "poi": 2, "transportation": 11,
        "transportation_name": 3, "water": 2, "water_name": 4, "waterway": 14,
    }


def test_gzipped_fixture_matches_raw_decode():
    data = (FIXTURES / "mvt_14_8846_5552_prague.pbf.gz").read_bytes()
    assert data[:2] == b"\x1f\x8b"
    assert decode(data) == decode(gzip.decompress(data))
    assert _counts("mvt_14_8846_5552_prague.pbf.gz")["transportation"] == 198


def test_layer_filter():
    keep = {"transportation", "water"}
    assert set(_counts("mvt_14_8848_5555_prague.pbf", keep_layers=keep)) == keep


@pytest.mark.parametrize("cmds,gtype,expected", [
    ([9, 4, 4, 18, 0, 16, 16, 0], 2, [[(2, 2), (2, 10), (10, 10)]]),
    ([9, 6, 12, 18, 10, 12, 24, 44, 15], 3, [[(3, 6), (8, 12), (20, 34), (3, 6)]]),
    ([17, 10, 14, 3, 9], 1, [[(5, 7)], [(3, 2)]]),
    ([9, 4], 2, []),
])
def test_geometry_spec_examples(cmds, gtype, expected):
    assert decode_geometry(cmds, gtype) == expected


def test_swift_decoder_shape_matches_mirror():
    src = strip_comments((APP / "Map/MVTDecoder.swift").read_text(encoding="utf-8"))
    geom = decl_body(src, "static func decodeGeometry(")
    # MoveTo / LineTo share the parameter loop, ClosePath repeats the first point.
    assert "case 1, 2:" in geom
    assert "case 7:" in geom
    assert "current.append(first)" in geom
    # Gzip sniffing happens before the protobuf read.
    assert "inflateIfGzipped(data)" in decl_body(src, "static func decode(")
    layer = decl_body(src, "private static func decodeLayer(")
    for field in ("case 1:", "case 2:", "case 3:", "case 4:", "case 5:", "case 15:"):
        assert field in layer
