import NvimKit

/// GUI-owned buffer mirror, independent of the child process. No file writes.
struct SessionRecovery {
    private(set) var buffers: [Int: Value] = [:]
    private(set) var workspace: Value = .nil

    var snapshot: Value {
        .map([(.string("buffers"), .array(buffers.keys.sorted().compactMap { buffers[$0] })),
              (.string("workspace"), workspace)])
    }

    mutating func consume(_ params: [Value]) {
        guard params.count >= 2, let kind = params[0].stringValue else { return }
        let data = params[1]
        if kind == "workspace" { workspace = data; return }
        guard let id = data["id"]?.intValue else { return }
        if kind == "remove" { buffers.removeValue(forKey: id); return }
        if kind == "buffer" { buffers[id] = data; return }
        guard case .map(var fields) = buffers[id] else { return }
        func set(_ name: String, _ value: Value) {
            fields.removeAll { $0.0.stringValue == name }
            fields.append((.string(name), value))
        }
        if kind == "metadata" {
            if let name = data["name"] { set("name", name) }
            if let modified = data["modified"] { set("modified", modified) }
        } else if kind == "lines",
            case .array(var lines) = buffers[id]?["lines"],
            let first = data["first"]?.intValue, let last = data["last"]?.intValue,
            case .array(let replacement) = data["lines"],
            first >= 0, last >= first, last <= lines.count
        {
            lines.replaceSubrange(first..<last, with: replacement)
            set("lines", .array(lines))
            set("modified", .bool(true))
        }
        buffers[id] = .map(fields)
    }
}
