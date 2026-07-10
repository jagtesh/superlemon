/// msgpack-RPC framing (https://github.com/msgpack-rpc/msgpack-rpc):
///   request      [0, msgid, method, params]
///   response     [1, msgid, error, result]
///   notification [2, method, params]

public enum RPCMessage: Sendable, Equatable {
    case request(msgid: UInt32, method: String, params: [Value])
    case response(msgid: UInt32, error: Value, result: Value)
    case notification(method: String, params: [Value])

    /// The wire representation, ready for `MsgpackEncoder.encode`.
    public var encoded: Value {
        switch self {
        case .request(let msgid, let method, let params):
            return .array([.uint(0), .uint(UInt64(msgid)), .string(method), .array(params)])
        case .response(let msgid, let error, let result):
            return .array([.uint(1), .uint(UInt64(msgid)), error, result])
        case .notification(let method, let params):
            return .array([.uint(2), .string(method), .array(params)])
        }
    }

    public init(_ value: Value) throws {
        guard let parts = value.arrayValue, let kind = parts.first?.intValue else {
            throw RPCFramingError.notAnRPCMessage(value)
        }
        switch kind {
        case 0:
            guard parts.count == 4,
                let msgid = parts[1].intValue.flatMap({ UInt32(exactly: $0) }),
                let method = parts[2].stringValue,
                let params = parts[3].arrayValue
            else { throw RPCFramingError.malformedMessage(value) }
            self = .request(msgid: msgid, method: method, params: params)
        case 1:
            guard parts.count == 4,
                let msgid = parts[1].intValue.flatMap({ UInt32(exactly: $0) })
            else { throw RPCFramingError.malformedMessage(value) }
            self = .response(msgid: msgid, error: parts[2], result: parts[3])
        case 2:
            guard parts.count == 3,
                let method = parts[1].stringValue,
                let params = parts[2].arrayValue
            else { throw RPCFramingError.malformedMessage(value) }
            self = .notification(method: method, params: params)
        default:
            throw RPCFramingError.unknownMessageType(kind)
        }
    }
}

public enum RPCFramingError: Error, Sendable {
    case notAnRPCMessage(Value)
    case malformedMessage(Value)
    case unknownMessageType(Int)
}
