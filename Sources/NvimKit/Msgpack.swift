/// Hand-rolled msgpack codec for the nvim RPC boundary.
/// Encoder writes the smallest representation; decoder accepts every format
/// in the msgpack spec and supports incremental (partial-buffer) decoding.

/// Errors thrown by the msgpack codec for malformed input.
public enum MsgpackError: Error, Equatable, Sendable {
    /// The buffer ends mid-value. `MsgpackDecoder.decodeNext()` catches this
    /// internally and returns `nil` ("feed me more bytes"); it only escapes
    /// from the one-shot `decode(_:)` entry point.
    case truncated
    /// Reserved/unknown format byte (0xc1).
    case invalidFormatByte(UInt8)
    /// A single buffered value exceeded the configured wire-size ceiling.
    case messageTooLarge(limit: Int)
    /// A container declared more entries than the decoder is willing to allocate.
    case containerTooLarge(count: Int, limit: Int)
    /// Recursive containers exceeded the configured stack-depth ceiling.
    case nestingTooDeep(limit: Int)
}

/// Resource ceilings applied while decoding untrusted bytes from nvim.
///
/// The defaults are intentionally generous for redraw batches while still
/// preventing a malformed length prefix or recursively nested value from
/// consuming unbounded memory or stack space.
public struct MsgpackDecodingLimits: Sendable, Equatable {
    public var maximumMessageBytes: Int
    public var maximumContainerElements: Int
    public var maximumNestingDepth: Int

    public init(
        maximumMessageBytes: Int = 64 * 1024 * 1024,
        maximumContainerElements: Int = 1_000_000,
        maximumNestingDepth: Int = 128
    ) {
        self.maximumMessageBytes = max(1, maximumMessageBytes)
        self.maximumContainerElements = max(1, maximumContainerElements)
        self.maximumNestingDepth = max(1, maximumNestingDepth)
    }
}

// MARK: - Encoder

public enum MsgpackEncoder {
    public static func encode(_ value: Value) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        encode(value, into: &out)
        return out
    }

    public static func encode(_ value: Value, into out: inout [UInt8]) {
        switch value {
        case .nil:
            out.append(0xc0)

        case .bool(let b):
            out.append(b ? 0xc3 : 0xc2)

        case .int(let v):
            if v >= 0 {
                encodeUnsigned(UInt64(v), into: &out)
            } else if v >= -32 {
                out.append(UInt8(bitPattern: Int8(v)))
            } else if v >= Int64(Int8.min) {
                out.append(0xd0)
                out.append(UInt8(bitPattern: Int8(v)))
            } else if v >= Int64(Int16.min) {
                out.append(0xd1)
                appendBigEndian(UInt16(bitPattern: Int16(v)), into: &out)
            } else if v >= Int64(Int32.min) {
                out.append(0xd2)
                appendBigEndian(UInt32(bitPattern: Int32(v)), into: &out)
            } else {
                out.append(0xd3)
                appendBigEndian(UInt64(bitPattern: v), into: &out)
            }

        case .uint(let v):
            encodeUnsigned(v, into: &out)

        case .float(let v):
            out.append(0xcb)
            appendBigEndian(v.bitPattern, into: &out)

        case .string(let s):
            let utf8 = Array(s.utf8)
            switch utf8.count {
            case 0...31:
                out.append(0xa0 | UInt8(utf8.count))
            case 32...0xff:
                out.append(0xd9)
                out.append(UInt8(utf8.count))
            case 0x100...0xffff:
                out.append(0xda)
                appendBigEndian(UInt16(utf8.count), into: &out)
            default:
                out.append(0xdb)
                appendBigEndian(UInt32(utf8.count), into: &out)
            }
            out.append(contentsOf: utf8)

        case .binary(let bytes):
            switch bytes.count {
            case 0...0xff:
                out.append(0xc4)
                out.append(UInt8(bytes.count))
            case 0x100...0xffff:
                out.append(0xc5)
                appendBigEndian(UInt16(bytes.count), into: &out)
            default:
                out.append(0xc6)
                appendBigEndian(UInt32(bytes.count), into: &out)
            }
            out.append(contentsOf: bytes)

        case .array(let items):
            switch items.count {
            case 0...15:
                out.append(0x90 | UInt8(items.count))
            case 16...0xffff:
                out.append(0xdc)
                appendBigEndian(UInt16(items.count), into: &out)
            default:
                out.append(0xdd)
                appendBigEndian(UInt32(items.count), into: &out)
            }
            for item in items { encode(item, into: &out) }

        case .map(let pairs):
            switch pairs.count {
            case 0...15:
                out.append(0x80 | UInt8(pairs.count))
            case 16...0xffff:
                out.append(0xde)
                appendBigEndian(UInt16(pairs.count), into: &out)
            default:
                out.append(0xdf)
                appendBigEndian(UInt32(pairs.count), into: &out)
            }
            for (k, v) in pairs {
                encode(k, into: &out)
                encode(v, into: &out)
            }

        case .ext(let type, let data):
            switch data.count {
            case 1: out.append(0xd4)
            case 2: out.append(0xd5)
            case 4: out.append(0xd6)
            case 8: out.append(0xd7)
            case 16: out.append(0xd8)
            case 0...0xff:
                out.append(0xc7)
                out.append(UInt8(data.count))
            case 0x100...0xffff:
                out.append(0xc8)
                appendBigEndian(UInt16(data.count), into: &out)
            default:
                out.append(0xc9)
                appendBigEndian(UInt32(data.count), into: &out)
            }
            out.append(UInt8(bitPattern: type))
            out.append(contentsOf: data)
        }
    }

    private static func encodeUnsigned(_ v: UInt64, into out: inout [UInt8]) {
        switch v {
        case 0...0x7f:
            out.append(UInt8(v))
        case 0x80...0xff:
            out.append(0xcc)
            out.append(UInt8(v))
        case 0x100...0xffff:
            out.append(0xcd)
            appendBigEndian(UInt16(v), into: &out)
        case 0x1_0000...0xffff_ffff:
            out.append(0xce)
            appendBigEndian(UInt32(v), into: &out)
        default:
            out.append(0xcf)
            appendBigEndian(v, into: &out)
        }
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ v: T, into out: inout [UInt8]) {
        withUnsafeBytes(of: v.bigEndian) { out.append(contentsOf: $0) }
    }
}

// MARK: - Decoder

/// Incremental msgpack decoder. Feed raw pipe reads with `append(_:)`, then
/// drain complete values with `decodeNext()`, which returns `nil` when the
/// buffered bytes end mid-value (buffer more and retry).
public struct MsgpackDecoder: Sendable {
    private var buffer: [UInt8] = []
    private var readIndex = 0
    private var deferredError: MsgpackError?
    private let limits: MsgpackDecodingLimits

    public init(limits: MsgpackDecodingLimits = .init()) {
        self.limits = limits
    }

    /// Bytes buffered but not yet consumed by a completed decode.
    public var bytesPending: Int { buffer.count - readIndex }

    public mutating func append(_ bytes: some Sequence<UInt8>) {
        guard deferredError == nil else { return }

        // Do not append a giant chunk and discover the limit only after the
        // allocation. Keep at most `maximumMessageBytes` pending bytes; the
        // next byte records a sticky decoder error surfaced by decodeNext().
        for byte in bytes {
            guard bytesPending < limits.maximumMessageBytes else {
                deferredError = .messageTooLarge(limit: limits.maximumMessageBytes)
                return
            }
            buffer.append(byte)
        }
    }

    /// Decode the next complete value, or `nil` if more bytes are needed.
    /// Throws only on genuinely malformed input.
    public mutating func decodeNext() throws -> Value? {
        if let deferredError { throw deferredError }
        var cursor = readIndex
        do {
            let value = try Self.decodeValue(
                buffer, &cursor, limits: limits, depth: 0, messageStart: readIndex)
            readIndex = cursor
            compactIfNeeded()
            return value
        } catch MsgpackError.truncated {
            return nil
        }
    }

    /// One-shot decode of a self-contained buffer.
    public static func decode(
        _ bytes: [UInt8], limits: MsgpackDecodingLimits = .init()
    ) throws -> Value {
        guard bytes.count <= limits.maximumMessageBytes else {
            throw MsgpackError.messageTooLarge(limit: limits.maximumMessageBytes)
        }
        var cursor = 0
        return try decodeValue(bytes, &cursor, limits: limits, depth: 0, messageStart: 0)
    }

    private mutating func compactIfNeeded() {
        if readIndex == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readIndex = 0
        } else if readIndex > 4096, readIndex > buffer.count / 2 {
            buffer.removeFirst(readIndex)
            readIndex = 0
        }
    }

    // MARK: recursive-descent parse

    static func decodeValue(
        _ buf: [UInt8],
        _ pos: inout Int,
        limits: MsgpackDecodingLimits,
        depth: Int,
        messageStart: Int
    ) throws -> Value {
        guard pos - messageStart < limits.maximumMessageBytes else {
            throw MsgpackError.messageTooLarge(limit: limits.maximumMessageBytes)
        }
        let byte = try readByte(buf, &pos)
        switch byte {
        case 0x00...0x7f: return .uint(UInt64(byte))
        case 0x80...0x8f:
            return try decodeMap(
                buf, &pos, count: Int(byte & 0x0f), limits: limits, depth: depth,
                messageStart: messageStart)
        case 0x90...0x9f:
            return try decodeArray(
                buf, &pos, count: Int(byte & 0x0f), limits: limits, depth: depth,
                messageStart: messageStart)
        case 0xa0...0xbf:
            return try decodeString(
                buf, &pos, count: Int(byte & 0x1f), limits: limits,
                messageStart: messageStart)
        case 0xc0: return .nil
        case 0xc2: return .bool(false)
        case 0xc3: return .bool(true)
        case 0xc4:
            return try decodeBinary(
                buf, &pos, count: Int(try readByte(buf, &pos)), limits: limits,
                messageStart: messageStart)
        case 0xc5:
            return try decodeBinary(
                buf, &pos, count: Int(try readUInt(buf, &pos, 2)), limits: limits,
                messageStart: messageStart)
        case 0xc6:
            return try decodeBinary(
                buf, &pos, count: Int(try readUInt(buf, &pos, 4)), limits: limits,
                messageStart: messageStart)
        case 0xc7:
            return try decodeExt(
                buf, &pos, count: Int(try readByte(buf, &pos)), limits: limits,
                messageStart: messageStart)
        case 0xc8:
            return try decodeExt(
                buf, &pos, count: Int(try readUInt(buf, &pos, 2)), limits: limits,
                messageStart: messageStart)
        case 0xc9:
            return try decodeExt(
                buf, &pos, count: Int(try readUInt(buf, &pos, 4)), limits: limits,
                messageStart: messageStart)
        case 0xca: return .float(Double(Float(bitPattern: UInt32(try readUInt(buf, &pos, 4)))))
        case 0xcb: return .float(Double(bitPattern: try readUInt(buf, &pos, 8)))
        case 0xcc: return .uint(UInt64(try readByte(buf, &pos)))
        case 0xcd: return .uint(try readUInt(buf, &pos, 2))
        case 0xce: return .uint(try readUInt(buf, &pos, 4))
        case 0xcf: return .uint(try readUInt(buf, &pos, 8))
        case 0xd0: return .int(Int64(Int8(bitPattern: try readByte(buf, &pos))))
        case 0xd1: return .int(Int64(Int16(bitPattern: UInt16(try readUInt(buf, &pos, 2)))))
        case 0xd2: return .int(Int64(Int32(bitPattern: UInt32(try readUInt(buf, &pos, 4)))))
        case 0xd3: return .int(Int64(bitPattern: try readUInt(buf, &pos, 8)))
        case 0xd4:
            return try decodeExt(
                buf, &pos, count: 1, limits: limits, messageStart: messageStart)
        case 0xd5:
            return try decodeExt(
                buf, &pos, count: 2, limits: limits, messageStart: messageStart)
        case 0xd6:
            return try decodeExt(
                buf, &pos, count: 4, limits: limits, messageStart: messageStart)
        case 0xd7:
            return try decodeExt(
                buf, &pos, count: 8, limits: limits, messageStart: messageStart)
        case 0xd8:
            return try decodeExt(
                buf, &pos, count: 16, limits: limits, messageStart: messageStart)
        case 0xd9:
            return try decodeString(
                buf, &pos, count: Int(try readByte(buf, &pos)), limits: limits,
                messageStart: messageStart)
        case 0xda:
            return try decodeString(
                buf, &pos, count: Int(try readUInt(buf, &pos, 2)), limits: limits,
                messageStart: messageStart)
        case 0xdb:
            return try decodeString(
                buf, &pos, count: Int(try readUInt(buf, &pos, 4)), limits: limits,
                messageStart: messageStart)
        case 0xdc:
            return try decodeArray(
                buf, &pos, count: Int(try readUInt(buf, &pos, 2)), limits: limits,
                depth: depth, messageStart: messageStart)
        case 0xdd:
            return try decodeArray(
                buf, &pos, count: Int(try readUInt(buf, &pos, 4)), limits: limits,
                depth: depth, messageStart: messageStart)
        case 0xde:
            return try decodeMap(
                buf, &pos, count: Int(try readUInt(buf, &pos, 2)), limits: limits,
                depth: depth, messageStart: messageStart)
        case 0xdf:
            return try decodeMap(
                buf, &pos, count: Int(try readUInt(buf, &pos, 4)), limits: limits,
                depth: depth, messageStart: messageStart)
        case 0xe0...0xff: return .int(Int64(Int8(bitPattern: byte)))
        default: throw MsgpackError.invalidFormatByte(byte)
        }
    }

    private static func decodeString(
        _ buf: [UInt8], _ pos: inout Int, count: Int,
        limits: MsgpackDecodingLimits, messageStart: Int
    ) throws -> Value {
        try validateByteCount(count, limits: limits)
        // Lenient UTF-8: nvim can, in edge cases, emit bytes that are not
        // valid UTF-8; replacement characters beat a dead session.
        let bytes = try readBytes(buf, &pos, count)
        try validateMessageSize(pos - messageStart, limits: limits)
        return .string(String(decoding: bytes, as: UTF8.self))
    }

    private static func decodeBinary(
        _ buf: [UInt8], _ pos: inout Int, count: Int,
        limits: MsgpackDecodingLimits, messageStart: Int
    ) throws -> Value {
        try validateByteCount(count, limits: limits)
        let bytes = try readBytes(buf, &pos, count)
        try validateMessageSize(pos - messageStart, limits: limits)
        return .binary(Array(bytes))
    }

    private static func decodeArray(
        _ buf: [UInt8], _ pos: inout Int, count: Int,
        limits: MsgpackDecodingLimits, depth: Int, messageStart: Int
    ) throws -> Value {
        try validateContainer(count, limits: limits, depth: depth)
        var items: [Value] = []
        items.reserveCapacity(min(count, 4096))
        for _ in 0..<count {
            items.append(
                try decodeValue(
                    buf, &pos, limits: limits, depth: depth + 1,
                    messageStart: messageStart))
        }
        return .array(items)
    }

    private static func decodeMap(
        _ buf: [UInt8], _ pos: inout Int, count: Int,
        limits: MsgpackDecodingLimits, depth: Int, messageStart: Int
    ) throws -> Value {
        try validateContainer(count, limits: limits, depth: depth)
        var pairs: [(Value, Value)] = []
        pairs.reserveCapacity(min(count, 4096))
        for _ in 0..<count {
            let key = try decodeValue(
                buf, &pos, limits: limits, depth: depth + 1,
                messageStart: messageStart)
            let value = try decodeValue(
                buf, &pos, limits: limits, depth: depth + 1,
                messageStart: messageStart)
            pairs.append((key, value))
        }
        return .map(pairs)
    }

    private static func decodeExt(
        _ buf: [UInt8], _ pos: inout Int, count: Int,
        limits: MsgpackDecodingLimits, messageStart: Int
    ) throws -> Value {
        try validateByteCount(count, limits: limits)
        let type = Int8(bitPattern: try readByte(buf, &pos))
        let bytes = try readBytes(buf, &pos, count)
        try validateMessageSize(pos - messageStart, limits: limits)
        return .ext(type: type, data: Array(bytes))
    }

    private static func validateByteCount(
        _ count: Int, limits: MsgpackDecodingLimits
    ) throws {
        guard count <= limits.maximumMessageBytes else {
            throw MsgpackError.messageTooLarge(limit: limits.maximumMessageBytes)
        }
    }

    private static func validateContainer(
        _ count: Int, limits: MsgpackDecodingLimits, depth: Int
    ) throws {
        guard count <= limits.maximumContainerElements else {
            throw MsgpackError.containerTooLarge(
                count: count, limit: limits.maximumContainerElements)
        }
        guard depth < limits.maximumNestingDepth else {
            throw MsgpackError.nestingTooDeep(limit: limits.maximumNestingDepth)
        }
    }

    private static func validateMessageSize(
        _ count: Int, limits: MsgpackDecodingLimits
    ) throws {
        guard count <= limits.maximumMessageBytes else {
            throw MsgpackError.messageTooLarge(limit: limits.maximumMessageBytes)
        }
    }

    private static func readByte(_ buf: [UInt8], _ pos: inout Int) throws -> UInt8 {
        guard pos < buf.count else { throw MsgpackError.truncated }
        defer { pos += 1 }
        return buf[pos]
    }

    private static func readBytes(_ buf: [UInt8], _ pos: inout Int, _ n: Int) throws -> ArraySlice<UInt8> {
        guard buf.count - pos >= n else { throw MsgpackError.truncated }
        defer { pos += n }
        return buf[pos..<pos + n]
    }

    private static func readUInt(_ buf: [UInt8], _ pos: inout Int, _ n: Int) throws -> UInt64 {
        var result: UInt64 = 0
        for byte in try readBytes(buf, &pos, n) {
            result = result << 8 | UInt64(byte)
        }
        return result
    }
}
