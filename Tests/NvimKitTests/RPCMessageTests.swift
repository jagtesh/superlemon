import Testing

@testable import NvimKit

@Suite struct RPCMessageTests {
    @Test func requestWireShape() {
        let message = RPCMessage.request(
            msgid: 7, method: "nvim_input", params: [.string("ihello<Esc>")])
        #expect(
            message.encoded
                == .array([.uint(0), .uint(7), .string("nvim_input"), .array([.string("ihello<Esc>")])]))
    }

    @Test func responseWireShape() {
        let message = RPCMessage.response(msgid: 3, error: .nil, result: .string("ok"))
        #expect(message.encoded == .array([.uint(1), .uint(3), .nil, .string("ok")]))
    }

    @Test func notificationWireShape() {
        let message = RPCMessage.notification(method: "redraw", params: [.array([])])
        #expect(message.encoded == .array([.uint(2), .string("redraw"), .array([.array([])])]))
    }

    @Test(arguments: [
        RPCMessage.request(msgid: 0, method: "m", params: []),
        RPCMessage.request(msgid: .max, method: "nvim_eval", params: [.string("1+1"), .nil]),
        RPCMessage.response(msgid: 12, error: .array([.int(0), .string("boom")]), result: .nil),
        RPCMessage.response(msgid: 1, error: .nil, result: .map([(.string("k"), .uint(9))])),
        RPCMessage.notification(method: "redraw", params: [.array([.string("flush"), .array([])])]),
    ])
    func roundTripsThroughCodec(_ message: RPCMessage) throws {
        let bytes = MsgpackEncoder.encode(message.encoded)
        let decoded = try RPCMessage(MsgpackDecoder.decode(bytes))
        #expect(decoded == message)
    }

    @Test func rejectsUnknownMessageType() {
        #expect(throws: RPCFramingError.self) {
            try RPCMessage(.array([.uint(3), .uint(0), .string("m"), .array([])]))
        }
    }

    @Test func rejectsNonArrayPayload() {
        #expect(throws: RPCFramingError.self) { try RPCMessage(.string("redraw")) }
    }

    @Test func rejectsShortRequest() {
        #expect(throws: RPCFramingError.self) {
            try RPCMessage(.array([.uint(0), .uint(1), .string("m")]))
        }
    }
}
