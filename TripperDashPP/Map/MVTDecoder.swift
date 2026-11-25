import Foundation

// Mapbox Vector Tile 2.x decoder (https://github.com/mapbox/vector-tile-spec).
//
//   Tile    { repeated Layer layers = 3; }
//   Layer   { uint32 version = 15; string name = 1; repeated Feature features = 2;
//             repeated string keys = 3; repeated Value values = 4; uint32 extent = 5 [4096]; }
//   Feature { uint64 id = 1; packed uint32 tags = 2; GeomType type = 3; packed uint32 geometry = 4; }
//   Value   { string = 1; float = 2; double = 3; int64 = 4; uint64 = 5; sint64 = 6; bool = 7; }
//
// Geometry: command ints `(id & 7) | (count << 3)` — MoveTo 1, LineTo 2,
// ClosePath 7 — each MoveTo/LineTo followed by `count` zigzag (dx, dy)
// pairs relative to the cursor. Tile coords are y-down in [0, extent]
// (features may overshoot into the buffer zone).

nonisolated enum MVTValue: Sendable, Equatable {
    case string(String)
    case double(Double)
    case int(Int64)
    case uint(UInt64)
    case bool(Bool)

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var numberValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .uint(let u): return Double(u)
        case .bool(let b): return b ? 1 : 0
        case .string: return nil
        }
    }
}

nonisolated enum MVTGeomType: Int, Sendable {
    case unknown = 0, point = 1, lineString = 2, polygon = 3
}

nonisolated struct MVTPoint: Sendable, Equatable {
    var x: Int32
    var y: Int32
}

nonisolated struct MVTFeature: Sendable {
    var id: UInt64?
    var type: MVTGeomType
    var properties: [String: MVTValue]
    /// Points: one part per point. Lines: one part per MoveTo.
    /// Polygons: one ring per part, closed (last point == first point).
    var parts: [[MVTPoint]]

    subscript(key: String) -> MVTValue? { properties[key] }
}

nonisolated struct MVTLayer: Sendable {
    var name: String
    var version: Int
    var extent: Int
    var features: [MVTFeature]
}

nonisolated enum MVTDecoder {
    enum Failure: Error, Equatable {
        case badGzip
        case inflateFailed
    }

    /// Decode a tile. `keepLayers` = nil keeps every layer; otherwise layers
    /// not named in it are skipped without decoding their features.
    /// A gzip body (1f 8b) is inflated first.
    static func decode(_ data: Data, keepLayers: Set<String>? = nil) throws -> [MVTLayer] {
        let raw = try inflateIfGzipped(data)
        var r = ProtobufReader(raw)
        var layers: [MVTLayer] = []
        while !r.isAtEnd {
            let (field, wire) = try r.readTag()
            if field == 3, wire == ProtobufReader.WireType.lengthDelimited.rawValue {
                let sub = try r.readLengthDelimited()
                if let keep = keepLayers {
                    guard let name = try layerName(sub), keep.contains(name) else { continue }
                }
                layers.append(try decodeLayer(sub))
            } else {
                try r.skip(wire: wire)
            }
        }
        return layers
    }

    /// The layer's name without decoding its features.
    private static func layerName(_ layer: ProtobufReader) throws -> String? {
        var r = layer
        while !r.isAtEnd {
            let (field, wire) = try r.readTag()
            if field == 1 { return try r.readString() }
            try r.skip(wire: wire)
        }
        return nil
    }

    private static func decodeLayer(_ layer: ProtobufReader) throws -> MVTLayer {
        var r = layer
        var name = ""
        var version = 1
        var extent = 4096
        var keys: [String] = []
        var values: [MVTValue] = []
        var rawFeatures: [ProtobufReader] = []
        while !r.isAtEnd {
            let (field, wire) = try r.readTag()
            switch field {
            case 1: name = try r.readString()
            case 2: rawFeatures.append(try r.readLengthDelimited())
            case 3: keys.append(try r.readString())
            case 4: values.append(try decodeValue(try r.readLengthDelimited()))
            case 5: extent = Int(try r.readVarint())
            case 15: version = Int(try r.readVarint())
            default: try r.skip(wire: wire)
            }
        }
        // Keys and values may come after the features in the stream, so
        // features are decoded once the whole layer has been read.
        var features: [MVTFeature] = []
        features.reserveCapacity(rawFeatures.count)
        for f in rawFeatures {
            features.append(try decodeFeature(f, keys: keys, values: values))
        }
        return MVTLayer(name: name, version: version, extent: extent, features: features)
    }

    private static func decodeValue(_ value: ProtobufReader) throws -> MVTValue {
        var r = value
        var out: MVTValue = .string("")
        while !r.isAtEnd {
            let (field, wire) = try r.readTag()
            switch field {
            case 1: out = .string(try r.readString())
            case 2: out = .double(Double(Float(bitPattern: try r.readFixed32())))
            case 3: out = .double(Double(bitPattern: try r.readFixed64()))
            case 4: out = .int(Int64(bitPattern: try r.readVarint()))
            case 5: out = .uint(try r.readVarint())
            case 6: out = .int(ProtobufReader.zigzag(try r.readVarint()))
            case 7: out = .bool(try r.readVarint() != 0)
            default: try r.skip(wire: wire)
            }
        }
        return out
    }

    private static func decodeFeature(_ feature: ProtobufReader,
                                      keys: [String], values: [MVTValue]) throws -> MVTFeature {
        var r = feature
        var id: UInt64?
        var type = MVTGeomType.unknown
        var tags: [UInt32] = []
        var geometry: [UInt32] = []
        while !r.isAtEnd {
            let (field, wire) = try r.readTag()
            switch field {
            case 1: id = try r.readVarint()
            case 2: tags = try r.readPackedUInt32()
            case 3: type = MVTGeomType(rawValue: Int(try r.readVarint())) ?? .unknown
            case 4: geometry = try r.readPackedUInt32()
            default: try r.skip(wire: wire)
            }
        }
        var props: [String: MVTValue] = [:]
        props.reserveCapacity(tags.count / 2)
        var i = 0
        while i + 1 < tags.count {
            let k = Int(tags[i]), v = Int(tags[i + 1])
            if k < keys.count, v < values.count { props[keys[k]] = values[v] }
            i += 2
        }
        return MVTFeature(id: id, type: type, properties: props,
                          parts: decodeGeometry(geometry, type: type))
    }

    /// Command stream → parts. Malformed streams are truncated, not thrown:
    /// one bad feature shouldn't cost the whole tile.
    static func decodeGeometry(_ cmds: [UInt32], type: MVTGeomType) -> [[MVTPoint]] {
        var parts: [[MVTPoint]] = []
        var current: [MVTPoint] = []
        var x: Int32 = 0, y: Int32 = 0
        var i = 0
        func flush() {
            if !current.isEmpty { parts.append(current) }
            current = []
        }
        while i < cmds.count {
            let cmd = cmds[i] & 0x7
            let count = Int(cmds[i] >> 3)
            i += 1
            switch cmd {
            case 1, 2:  // MoveTo, LineTo
                guard i + 2 * count <= cmds.count else { flush(); return parts }
                for _ in 0..<count {
                    x &+= ProtobufReader.zigzag32(cmds[i])
                    y &+= ProtobufReader.zigzag32(cmds[i + 1])
                    i += 2
                    if cmd == 1, type != .point { flush() }
                    if type == .point {
                        parts.append([MVTPoint(x: x, y: y)])
                    } else {
                        current.append(MVTPoint(x: x, y: y))
                    }
                }
            case 7:  // ClosePath
                if let first = current.first, current.last != first { current.append(first) }
                flush()
            default:
                flush()
                return parts
            }
        }
        flush()
        return parts
    }

    /// Inflate a gzip member (RFC 1952) if `data` starts with 1f 8b;
    /// otherwise return it unchanged. URLSession already strips a
    /// `Content-Encoding: gzip` body, so this only catches a body served
    /// gzipped without that header (or a gzipped file on disk).
    static func inflateIfGzipped(_ data: Data) throws -> Data {
        let b = [UInt8](data.prefix(10))
        guard b.count >= 2, b[0] == 0x1F, b[1] == 0x8B else { return data }
        guard data.count >= 18, b[2] == 8 else { throw Failure.badGzip }
        let flags = b[3]
        let bytes = [UInt8](data)
        var p = 10
        if flags & 0x04 != 0 {  // FEXTRA
            guard p + 2 <= bytes.count else { throw Failure.badGzip }
            p += 2 + (Int(bytes[p]) | (Int(bytes[p + 1]) << 8))
        }
        if flags & 0x08 != 0 {  // FNAME
            while p < bytes.count, bytes[p] != 0 { p += 1 }
            p += 1
        }
        if flags & 0x10 != 0 {  // FCOMMENT
            while p < bytes.count, bytes[p] != 0 { p += 1 }
            p += 1
        }
        if flags & 0x02 != 0 { p += 2 }  // FHCRC
        let deflateEnd = bytes.count - 8
        guard p < deflateEnd else { throw Failure.badGzip }
        let deflated = Data(bytes[p..<deflateEnd])
        // `.zlib` here is raw DEFLATE (RFC 1951) — the Compression
        // framework's COMPRESSION_ZLIB — which is exactly a gzip body.
        guard let out = try? (deflated as NSData).decompressed(using: .zlib) else {
            throw Failure.inflateFailed
        }
        return out as Data
    }
}
