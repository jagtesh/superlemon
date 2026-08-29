import Testing

@testable import NvimKit

// MARK: - Round trips

private let boundaryValues: [Value] = [
    .nil,
    .bool(true),
    .bool(false),
    // unsigned boundaries: fixint / uint8 / uint16 / uint32 / uint64
    .uint(0), .uint(1), .uint(127), .uint(128), .uint(255), .uint(256),
    .uint(65535), .uint(65536), .uint(0xFFFF_FFFF), .uint(0x1_0000_0000),
    .uint(UInt64.max),
    // signed boundaries: negative fixint / int8 / int16 / int32 / int64
    .int(0), .int(127), .int(128), .int(-1), .int(-32), .int(-33),
    .int(-128), .int(-129), .int(-32768), .int(-32769),
    .int(-2_147_483_648), .int(-2_147_483_649), .int(Int64.min), .int(Int64.max),
    // floats
    .float(0.0), .float(1.5), .float(-3.25), .float(.pi),
    .float(.greatestFiniteMagnitude), .float(-.infinity),
    // strings: fixstr(0/31) / str8(32, 255) / str16(256)
    .string(""), .string("a"), .string(String(repeating: "x", count: 31)),
    .string(String(repeating: "x", count: 32)),
    .string(String(repeating: "x", count: 255)),
    .string(String(repeating: "x", count: 256)),
    .string("héllo 🍋 んにちは"),
    // binary: bin8 / bin16
    .binary([]), .binary([0xde, 0xad]), .binary(Array(repeating: 7, count: 255)),
    .binary(Array(repeating: 7, count: 256)),
    // arrays: fixarray(0/15) / array16(16)
    .array([]), .array(Array(repeating: .int(9), count: 15)),
    .array(Array(repeating: .int(9), count: 16)),
    // maps: fixmap(0/15) / map16(16)
    .map([]), .map([(.string("k"), .uint(1))]),
    .map((0..<15).map { (.uint(UInt64($0)), .bool(true)) }),
    .map((0..<16).map { (.uint(UInt64($0)), .bool(true)) }),
    // ext: fixext 1/2/4/8/16, ext8 (0, 3, 17, 255), ext16 (256)
    .ext(type: 1, data: [0xaa]),
    .ext(type: -1, data: [1, 2]),
    .ext(type: 42, data: [1, 2, 3, 4]),
    .ext(type: 0, data: Array(repeating: 1, count: 8)),
    .ext(type: 127, data: Array(repeating: 2, count: 16)),
    .ext(type: -128, data: []),
    .ext(type: 5, data: [1, 2, 3]),
    .ext(type: 5, data: Array(repeating: 3, count: 17)),
    .ext(type: 5, data: Array(repeating: 3, count: 255)),
    .ext(type: 5, data: Array(repeating: 3, count: 256)),
    // nesting
    .array([
        .map([(.string("grid"), .uint(1)), (.string("cells"), .array([.string("~"), .nil]))]),
        .ext(type: 1, data: [0x01]),
        .float(2.5),
    ]),
]

@Suite struct MsgpackRoundTripTests {
    @Test(arguments: boundaryValues)
    func roundTrip(_ value: Value) throws {
        let encoded = MsgpackEncoder.encode(value)
        let decoded = try MsgpackDecoder.decode(encoded)
        #expect(decoded == value)
    }

    @Test func roundTripLargeCollections() throws {
        // str32 / bin32 / array32 / map32 territory
        let big: [Value] = [
            .string(String(repeating: "y", count: 65536)),
            .binary(Array(repeating: 1, count: 65536)),
            .array(Array(repeating: .uint(0), count: 65536)),
            .ext(type: 9, data: Array(repeating: 4, count: 65536)),
        ]
        for value in big {
            #expect(try MsgpackDecoder.decode(MsgpackEncoder.encode(value)) == value)
        }
    }
}

// MARK: - Exact wire bytes

@Suite struct MsgpackWireFormatTests {
    @Test func scalarEncodings() {
        #expect(MsgpackEncoder.encode(.nil) == [0xc0])
        #expect(MsgpackEncoder.encode(.bool(false)) == [0xc2])
        #expect(MsgpackEncoder.encode(.bool(true)) == [0xc3])
        #expect(MsgpackEncoder.encode(.uint(127)) == [0x7f])
        #expect(MsgpackEncoder.encode(.uint(128)) == [0xcc, 0x80])
        #expect(MsgpackEncoder.encode(.uint(255)) == [0xcc, 0xff])
        #expect(MsgpackEncoder.encode(.uint(256)) == [0xcd, 0x01, 0x00])
        #expect(MsgpackEncoder.encode(.uint(65535)) == [0xcd, 0xff, 0xff])
        #expect(MsgpackEncoder.encode(.uint(65536)) == [0xce, 0x00, 0x01, 0x00, 0x00])
        #expect(MsgpackEncoder.encode(.int(-1)) == [0xff])
        #expect(MsgpackEncoder.encode(.int(-32)) == [0xe0])
        #expect(MsgpackEncoder.encode(.int(-33)) == [0xd0, 0xdf])
        #expect(MsgpackEncoder.encode(.int(-129)) == [0xd1, 0xff, 0x7f])
        // positive .int uses the compact unsigned families
        #expect(MsgpackEncoder.encode(.int(5)) == [0x05])
        #expect(MsgpackEncoder.encode(.int(128)) == [0xcc, 0x80])
        #expect(MsgpackEncoder.encode(.float(1.0)) == [0xcb, 0x3f, 0xf0, 0, 0, 0, 0, 0, 0])
        #expect(MsgpackEncoder.encode(.string("abc")) == [0xa3, 0x61, 0x62, 0x63])
        #expect(MsgpackEncoder.encode(.array([.nil])) == [0x91, 0xc0])
        #expect(MsgpackEncoder.encode(.map([(.string("a"), .uint(1))])) == [0x81, 0xa1, 0x61, 0x01])
        #expect(MsgpackEncoder.encode(.binary([0xff])) == [0xc4, 0x01, 0xff])
        #expect(MsgpackEncoder.encode(.ext(type: 1, data: [0x2a])) == [0xd4, 0x01, 0x2a])
    }

    @Test func decodesFloat32() throws {
        // 1.5 as IEEE-754 single precision
        #expect(try MsgpackDecoder.decode([0xca, 0x3f, 0xc0, 0x00, 0x00]) == .float(1.5))
    }

    @Test func decodesAllIntWidthsToOneNumberSpace() throws {
        // int/uint compare equal across the enum cases (Value's ==)
        #expect(try MsgpackDecoder.decode([0xcc, 0x2a]) == .int(42))
        #expect(try MsgpackDecoder.decode([0xd0, 0x2a]) == .uint(42))
    }

    @Test func rejectsReservedFormatByte() {
        #expect(throws: MsgpackError.invalidFormatByte(0xc1)) {
            try MsgpackDecoder.decode([0xc1])
        }
    }
}

// MARK: - Incremental decoding

@Suite struct MsgpackIncrementalTests {
    @Test func byteAtATime() throws {
        let message = Value.array([
            .string("redraw"), .uint(300), .float(2.5), .map([(.string("k"), .bool(true))]),
        ])
        let bytes = MsgpackEncoder.encode(message)

        var decoder = MsgpackDecoder()
        var decoded: [Value] = []
        for (index, byte) in bytes.enumerated() {
            decoder.append([byte])
            while let value = try decoder.decodeNext() {
                decoded.append(value)
            }
            if index < bytes.count - 1 {
                #expect(decoded.isEmpty, "decoded early at byte \(index)")
            }
        }
        #expect(decoded == [message])
        #expect(decoder.bytesPending == 0)
    }

    @Test func multipleMessagesInOneChunk() throws {
        let first = Value.string("one")
        let second = Value.array([.uint(2)])
        let third = Value.nil
        var decoder = MsgpackDecoder()
        decoder.append(
            MsgpackEncoder.encode(first) + MsgpackEncoder.encode(second)
                + MsgpackEncoder.encode(third))
        #expect(try decoder.decodeNext() == first)
        #expect(try decoder.decodeNext() == second)
        #expect(try decoder.decodeNext() == third)
        #expect(try decoder.decodeNext() == nil)
    }

    @Test func partialMessageAcrossAppends() throws {
        let message = Value.string(String(repeating: "z", count: 100))
        let bytes = MsgpackEncoder.encode(message)
        var decoder = MsgpackDecoder()

        decoder.append(bytes[0..<40])
        #expect(try decoder.decodeNext() == nil)
        #expect(decoder.bytesPending == 40)

        decoder.append(bytes[40...])
        #expect(try decoder.decodeNext() == message)
        #expect(try decoder.decodeNext() == nil)
    }

    @Test func completeMessageFollowedByPartial() throws {
        let first = Value.uint(65536)
        let second = Value.string("tail")
        let secondBytes = MsgpackEncoder.encode(second)
        var decoder = MsgpackDecoder()
        decoder.append(MsgpackEncoder.encode(first) + secondBytes.dropLast(2))
        #expect(try decoder.decodeNext() == first)
        #expect(try decoder.decodeNext() == nil)
        decoder.append(secondBytes.suffix(2))
        #expect(try decoder.decodeNext() == second)
    }

    @Test func truncatedNestedContainerNeedsMoreData() throws {
        // fixarray(2) with only one element present
        var decoder = MsgpackDecoder()
        decoder.append([0x92, 0xc0])
        #expect(try decoder.decodeNext() == nil)
        decoder.append([0xc3])
        #expect(try decoder.decodeNext() == .array([.nil, .bool(true)]))
    }

    @Test func rejectsBufferedMessageBeyondWireLimit() {
        let limits = MsgpackDecodingLimits(
            maximumMessageBytes: 8,
            maximumContainerElements: 100,
            maximumNestingDepth: 10)
        var decoder = MsgpackDecoder(limits: limits)
        // str8 declaring a 20-byte payload, all of it buffered up front.
        decoder.append([0xd9, 20] + Array(repeating: 0x61, count: 20))

        #expect(throws: MsgpackError.messageTooLarge(limit: 8)) {
            try decoder.decodeNext()
        }
    }

    @Test func messageExactlyAtWireLimitDoesNotPoisonTheNextMessage() throws {
        let limits = MsgpackDecodingLimits(
            maximumMessageBytes: 8,
            maximumContainerElements: 100,
            maximumNestingDepth: 10)
        var decoder = MsgpackDecoder(limits: limits)
        // fixstr(7): 1-byte header + 7-byte payload == 8 bytes, exactly at
        // the limit. The next message's leading byte (0xc0 == nil) arrives
        // in the very same append call, which used to make `append` count
        // both messages' bytes against the single-message limit and fail
        // the whole buffer with `.messageTooLarge` even though neither
        // message individually exceeds it.
        let sevenByteString: [UInt8] = [0xa7] + Array("abcdefg".utf8)
        decoder.append(sevenByteString + [0xc0])

        #expect(try decoder.decodeNext() == .string("abcdefg"))
        #expect(try decoder.decodeNext() == .nil)
    }

    @Test func rejectsOversizedDeclaredStringBeforePayloadArrives() {
        let limits = MsgpackDecodingLimits(
            maximumMessageBytes: 32,
            maximumContainerElements: 100,
            maximumNestingDepth: 10)
        var decoder = MsgpackDecoder(limits: limits)
        // str32 declaring 256 bytes, with no body. This is a limit violation,
        // not an indefinitely incomplete message.
        decoder.append([0xdb, 0, 0, 1, 0])

        #expect(throws: MsgpackError.messageTooLarge(limit: 32)) {
            try decoder.decodeNext()
        }
    }

    @Test func rejectsOversizedDeclaredContainerBeforeAllocation() {
        let limits = MsgpackDecodingLimits(
            maximumMessageBytes: 1024,
            maximumContainerElements: 4,
            maximumNestingDepth: 10)
        // array32 declaring one million entries and no body.
        let bytes: [UInt8] = [0xdd, 0, 0x0f, 0x42, 0x40]

        #expect(throws: MsgpackError.containerTooLarge(count: 1_000_000, limit: 4)) {
            try MsgpackDecoder.decode(bytes, limits: limits)
        }
    }

    @Test func rejectsNestingBeyondConfiguredDepth() {
        let limits = MsgpackDecodingLimits(
            maximumMessageBytes: 1024,
            maximumContainerElements: 100,
            maximumNestingDepth: 4)
        // Five single-element arrays around nil; four are allowed.
        let bytes = Array(repeating: UInt8(0x91), count: 5) + [0xc0]

        #expect(throws: MsgpackError.nestingTooDeep(limit: 4)) {
            try MsgpackDecoder.decode(bytes, limits: limits)
        }
    }
}
