import Foundation

/// Minimal protobuf writer, enough to build migration payloads (tests and future export).
public struct ProtoWriter {
    public private(set) var output: [UInt8] = []

    public init() {}

    public mutating func varint(_ field: Int, _ value: UInt64) {
        if value == 0 { return }
        key(field, wire: 0)
        raw(value)
    }

    public mutating func bool(_ field: Int, _ value: Bool) {
        if value { varint(field, 1) }
    }

    public mutating func bytes(_ field: Int, _ value: [UInt8]) {
        if value.isEmpty { return }
        key(field, wire: 2)
        raw(UInt64(value.count))
        output.append(contentsOf: value)
    }

    public mutating func string(_ field: Int, _ value: String) {
        bytes(field, Array(value.utf8))
    }

    public mutating func message(_ field: Int, _ payload: [UInt8]) {
        key(field, wire: 2)
        raw(UInt64(payload.count))
        output.append(contentsOf: payload)
    }

    private mutating func key(_ field: Int, wire: Int) {
        raw(UInt64(field) << 3 | UInt64(wire))
    }

    private mutating func raw(_ value: UInt64) {
        var n = value
        while n & ~UInt64(0x7F) != 0 {
            output.append(UInt8(n & 0x7F) | 0x80)
            n >>= 7
        }
        output.append(UInt8(n))
    }
}

public enum ProtoValue: Equatable {
    case varint(UInt64)
    case bytes([UInt8])

    var uint: UInt64? {
        if case let .varint(value) = self { return value }
        return nil
    }

    var data: [UInt8]? {
        if case let .bytes(value) = self { return value }
        return nil
    }

    var text: String? {
        data.map { String(decoding: $0, as: UTF8.self) }
    }
}

public enum ProtoError: Error {
    case truncated
    case badWireType(Int)
}

/// Flat list of (field, value) pairs; fixed32/fixed64 fields are skipped.
public func protoFields(_ data: [UInt8]) throws -> [(Int, ProtoValue)] {
    var fields: [(Int, ProtoValue)] = []
    var pos = 0

    func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while shift < 64 {
            guard pos < data.count else { throw ProtoError.truncated }
            let byte = data[pos]
            pos += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw ProtoError.truncated
    }

    while pos < data.count {
        let key = try varint()
        let field = Int(truncatingIfNeeded: key >> 3)
        let wire = Int(key & 7)
        switch wire {
        case 0:
            let value = try varint()
            fields.append((field, .varint(value)))
        case 1:
            guard pos + 8 <= data.count else { throw ProtoError.truncated }
            pos += 8
        case 2:
            let length = try varint()
            guard length <= UInt64(data.count - pos) else { throw ProtoError.truncated }
            let end = pos + Int(length)
            fields.append((field, .bytes(Array(data[pos..<end]))))
            pos = end
        case 5:
            guard pos + 4 <= data.count else { throw ProtoError.truncated }
            pos += 4
        default:
            throw ProtoError.badWireType(wire)
        }
    }
    return fields
}
