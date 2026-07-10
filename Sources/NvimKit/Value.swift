/// A msgpack value. The wire type of everything crossing the nvim RPC boundary.
public enum Value: Sendable, Equatable {
    case `nil`
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case float(Double)
    case string(String)
    case binary([UInt8])
    case array([Value])
    case map([(Value, Value)])
    case ext(type: Int8, data: [UInt8])
}

extension Value {
    public var intValue: Int? {
        switch self {
        case .int(let v): return Int(exactly: v)
        case .uint(let v): return Int(exactly: v)
        default: return nil
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [Value]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var mapValue: [(Value, Value)]? {
        if case .map(let m) = self { return m }
        return nil
    }

    public static func == (lhs: Value, rhs: Value) -> Bool {
        switch (lhs, rhs) {
        case (.nil, .nil): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.uint(let a), .uint(let b)): return a == b
        case (.int(let a), .uint(let b)), (.uint(let b), .int(let a)):
            return a >= 0 && UInt64(a) == b
        case (.float(let a), .float(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.binary(let a), .binary(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.map(let a), .map(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case (.ext(let t1, let d1), .ext(let t2, let d2)): return t1 == t2 && d1 == d2
        default: return false
        }
    }
}
