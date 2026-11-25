import Foundation

/// Minimal protobuf wire-format reader — just what the Mapbox Vector Tile
/// decoder needs: varints, zigzag, fixed32/64, length-delimited fields,
/// packed repeated varints, and skipping unknown fields.
///
/// A reader is a window `[pos, end)` over one shared byte array; nested
/// messages are sub-readers over the same storage (no copying).
/// `nonisolated` + value type: decoding runs off the main actor.
nonisolated struct ProtobufReader: Sendable {
    enum Failure: Error, Equatable {
        case truncated
        case malformedVarint
        case unsupportedWireType(Int)
    }

    enum WireType: Int {
        case varint = 0, fixed64 = 1, lengthDelimited = 2, fixed32 = 5
    }

    private let bytes: [UInt8]
    private(set) var pos: Int
    let end: Int

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.pos = 0
        self.end = bytes.count
    }

    init(_ data: Data) { self.init([UInt8](data)) }

    private init(bytes: [UInt8], pos: Int, end: Int) {
        self.bytes = bytes
        self.pos = pos
        self.end = end
    }

    var isAtEnd: Bool { pos >= end }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard pos < end else { throw Failure.truncated }
            let b = bytes[pos]
            pos += 1
            guard shift < 64 else { throw Failure.malformedVarint }
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
        }
    }

    /// Field number + wire type of the next field.
    mutating func readTag() throws -> (field: Int, wire: Int) {
        let key = try readVarint()
        return (Int(key >> 3), Int(key & 0x7))
    }

    mutating func readFixed32() throws -> UInt32 {
        guard end - pos >= 4 else { throw Failure.truncated }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[pos + i]) << (8 * UInt32(i)) }
        pos += 4
        return v
    }

    mutating func readFixed64() throws -> UInt64 {
        guard end - pos >= 8 else { throw Failure.truncated }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[pos + i]) << (8 * UInt64(i)) }
        pos += 8
        return v
    }

    /// A sub-reader over the next length-delimited field's payload.
    mutating func readLengthDelimited() throws -> ProtobufReader {
        let len = try readVarint()
        guard len <= UInt64(end - pos) else { throw Failure.truncated }
        let sub = ProtobufReader(bytes: bytes, pos: pos, end: pos + Int(len))
        pos += Int(len)
        return sub
    }

    mutating func readString() throws -> String {
        let sub = try readLengthDelimited()
        return String(decoding: bytes[sub.pos..<sub.end], as: UTF8.self)
    }

    /// Packed repeated uint32 (MVT `tags` and `geometry`).
    mutating func readPackedUInt32() throws -> [UInt32] {
        var sub = try readLengthDelimited()
        var out: [UInt32] = []
        out.reserveCapacity(sub.end - sub.pos)
        while !sub.isAtEnd { out.append(UInt32(truncatingIfNeeded: try sub.readVarint())) }
        return out
    }

    /// Skip a field's payload of the given wire type.
    mutating func skip(wire: Int) throws {
        switch WireType(rawValue: wire) {
        case .varint: _ = try readVarint()
        case .fixed64:
            guard end - pos >= 8 else { throw Failure.truncated }
            pos += 8
        case .lengthDelimited: _ = try readLengthDelimited()
        case .fixed32:
            guard end - pos >= 4 else { throw Failure.truncated }
            pos += 4
        case nil: throw Failure.unsupportedWireType(wire)
        }
    }

    static func zigzag(_ v: UInt64) -> Int64 {
        Int64(bitPattern: v >> 1) ^ -Int64(bitPattern: v & 1)
    }

    static func zigzag32(_ v: UInt32) -> Int32 {
        Int32(bitPattern: v >> 1) ^ -Int32(bitPattern: v & 1)
    }
}
