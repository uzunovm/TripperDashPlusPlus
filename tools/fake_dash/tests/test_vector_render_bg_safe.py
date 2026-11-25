"""The vector map must stay background-safe (CLAUDE.md guidelines 4 and 6).

The phone is locked in a pocket for the whole ride, so the per-frame vector
draw may only use CoreGraphics / CoreText on the CPU — no Metal, CoreImage,
MapKit snapshotting or map SDK — and runs off the main actor so a dense
city frame can't stall the main actor. Swift can't be compiled here, so
pin both in source.
"""

from __future__ import annotations

import pathlib
import re

from tests.swift_source import decl_body, strip_comments

APP = pathlib.Path(__file__).resolve().parents[3] / "TripperDashPP"

VECTOR_FILES = [
    "Map/VectorMapRenderer.swift",
    "Map/VectorTile.swift",
    "Map/VectorTileStore.swift",
    "Map/VectorTileSource.swift",
    "Map/MVTDecoder.swift",
    "Map/ProtobufReader.swift",
    "Map/RenderBudget.swift",
]

FORBIDDEN_IMPORTS = {"Metal", "MetalKit", "CoreImage", "MapKit", "SpriteKit", "SceneKit"}


def _src(rel: str) -> str:
    return strip_comments((APP / rel).read_text(encoding="utf-8"))


def test_vector_files_import_no_gpu_or_map_framework():
    for rel in VECTOR_FILES:
        imports = set(re.findall(r"^\s*import\s+(\w+)", _src(rel), re.M))
        assert not imports & FORBIDDEN_IMPORTS, f"{rel} imports {imports & FORBIDDEN_IMPORTS}"


def test_vector_base_renders_off_the_main_actor():
    src = _src("Map/MapViewSource.swift")
    assert "@concurrent nonisolated private static func renderVector(" in src
    prepare = decl_body(src, "fileprivate func prepareVectorBase()")
    assert "await Self.renderVector(" in prepare
    # The tick awaits the base map before the synchronous frame draw.
    tick = decl_body(src, "private func tickOnMain()")
    assert tick.index("await prepareVectorBase()") < tick.index("renderMapViewToPixelBuffer()")


def test_tile_decode_runs_off_the_main_actor():
    src = _src("Map/VectorTileStore.swift")
    assert "@concurrent nonisolated private static func decode(" in src


def test_vector_mode_bakes_no_raster_corridor():
    picker = _src("UI/MapPickerView.swift")
    body = decl_body(picker, "private func prerenderRouteTiles(")
    assert "usesVectorRenderer" in body
    mvs = _src("Map/MapViewSource.swift")
    assert "usesVectorRenderer" in decl_body(mvs, "func scheduleTileCacheRebuild(")
    assert "usesVectorRenderer" in decl_body(mvs, "func extendTileCache(")
