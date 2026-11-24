"""
Python mirror of `TripperDashPP/Map/ProtobufReader.swift` + `MVTDecoder.swift`.

Mapbox Vector Tile 2.x decoder, stdlib only. Keep it equivalent to the Swift:
same layer filter, same geometry parts (polygon rings closed by repeating the
first point, one part per point for point features), same gzip sniffing.
"""

from __future__ import annotations

import gzip
import struct


class _Reader:
    def __init__(self, buf: bytes, pos: int = 0, end: int | None = None):
        self.buf = buf
        self.pos = pos
        self.end = len(buf) if end is None else end

    def at_end(self) -> bool:
        return self.pos >= self.end

    def varint(self) -> int:
        result = shift = 0
        while True:
            if self.pos >= self.end:
                raise ValueError("truncated")
            b = self.buf[self.pos]
            self.pos += 1
            result |= (b & 0x7F) << shift
            if not b & 0x80:
                return result
            shift += 7
            if shift >= 64:
                raise ValueError("malformed varint")

    def tag(self) -> tuple[int, int]:
        k = self.varint()
        return k >> 3, k & 7

    def sub(self) -> "_Reader":
        n = self.varint()
        if n > self.end - self.pos:
            raise ValueError("truncated")
        r = _Reader(self.buf, self.pos, self.pos + n)
        self.pos += n
        return r

    def string(self) -> str:
        r = self.sub()
        return self.buf[r.pos:r.end].decode("utf-8", "replace")

    def packed(self) -> list[int]:
        r = self.sub()
        out = []
        while not r.at_end():
            out.append(r.varint() & 0xFFFFFFFF)
        return out

    def fixed(self, n: int) -> bytes:
        if self.end - self.pos < n:
            raise ValueError("truncated")
        b = self.buf[self.pos:self.pos + n]
        self.pos += n
        return b

    def skip(self, wire: int) -> None:
        if wire == 0:
            self.varint()
        elif wire == 1:
            self.fixed(8)
        elif wire == 2:
            self.sub()
        elif wire == 5:
            self.fixed(4)
        else:
            raise ValueError(f"unsupported wire type {wire}")


def zigzag(v: int) -> int:
    return (v >> 1) ^ -(v & 1)


def decode_geometry(cmds: list[int], gtype: int) -> list[list[tuple[int, int]]]:
    parts: list[list[tuple[int, int]]] = []
    cur: list[tuple[int, int]] = []
    x = y = 0
    i = 0

    def flush():
        nonlocal cur
        if cur:
            parts.append(cur)
        cur = []

    while i < len(cmds):
        cmd, count = cmds[i] & 7, cmds[i] >> 3
        i += 1
        if cmd in (1, 2):
            if i + 2 * count > len(cmds):
                flush()
                return parts
            for _ in range(count):
                x += zigzag(cmds[i])
                y += zigzag(cmds[i + 1])
                i += 2
                if cmd == 1 and gtype != 1:
                    flush()
                if gtype == 1:
                    parts.append([(x, y)])
                else:
                    cur.append((x, y))
        elif cmd == 7:
            if cur and cur[-1] != cur[0]:
                cur.append(cur[0])
            flush()
        else:
            flush()
            return parts
    flush()
    return parts


def _value(r: _Reader):
    out = ""
    while not r.at_end():
        f, w = r.tag()
        if f == 1:
            out = r.string()
        elif f == 2:
            out = struct.unpack("<f", r.fixed(4))[0]
        elif f == 3:
            out = struct.unpack("<d", r.fixed(8))[0]
        elif f == 4:
            v = r.varint()
            out = v - (1 << 64) if v >= 1 << 63 else v
        elif f == 5:
            out = r.varint()
        elif f == 6:
            out = zigzag(r.varint())
        elif f == 7:
            out = r.varint() != 0
        else:
            r.skip(w)
    return out


def _layer_name(r: _Reader) -> str | None:
    r = _Reader(r.buf, r.pos, r.end)
    while not r.at_end():
        f, w = r.tag()
        if f == 1:
            return r.string()
        r.skip(w)
    return None


def _layer(r: _Reader) -> dict:
    name, version, extent = "", 1, 4096
    keys: list[str] = []
    values: list = []
    raw: list[_Reader] = []
    while not r.at_end():
        f, w = r.tag()
        if f == 1:
            name = r.string()
        elif f == 2:
            raw.append(r.sub())
        elif f == 3:
            keys.append(r.string())
        elif f == 4:
            values.append(_value(r.sub()))
        elif f == 5:
            extent = r.varint()
        elif f == 15:
            version = r.varint()
        else:
            r.skip(w)
    features = []
    for fr in raw:
        fid, gtype, tags, geom = None, 0, [], []
        while not fr.at_end():
            f, w = fr.tag()
            if f == 1:
                fid = fr.varint()
            elif f == 2:
                tags = fr.packed()
            elif f == 3:
                gtype = fr.varint()
            elif f == 4:
                geom = fr.packed()
            else:
                fr.skip(w)
        props = {}
        for k, v in zip(tags[0::2], tags[1::2]):
            if k < len(keys) and v < len(values):
                props[keys[k]] = values[v]
        features.append({"id": fid, "type": gtype, "properties": props,
                         "parts": decode_geometry(geom, gtype)})
    return {"name": name, "version": version, "extent": extent, "features": features}


def inflate_if_gzipped(data: bytes) -> bytes:
    if data[:2] == b"\x1f\x8b":
        return gzip.decompress(data)
    return data


def decode(data: bytes, keep_layers: set[str] | None = None) -> list[dict]:
    r = _Reader(inflate_if_gzipped(data))
    layers = []
    while not r.at_end():
        f, w = r.tag()
        if f == 3 and w == 2:
            sub = r.sub()
            if keep_layers is not None and _layer_name(sub) not in keep_layers:
                continue
            layers.append(_layer(sub))
        else:
            r.skip(w)
    return layers
