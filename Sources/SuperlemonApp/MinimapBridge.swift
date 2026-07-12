// MinimapBridge — strict app-side translation between the runtime provider
// protocol and SurfaceKit's typed minimap model.

import NvimKit
import SurfaceKit

/// Owns minimap provider identity at the app boundary. Neovim remains the
/// source of buffer data, while SurfaceKit receives only typed, current
/// topologies and chunks.
@MainActor
final class MinimapBridge {
    typealias Notify = (_ method: String, _ params: [Value]) -> Void

    private static let providerMethod = "superlemon.minimap"
    private static let maximumRequestLines = 384
    private static let maximumColumns = 256
    private static let maximumSpansPerLine = 1_024
    private static let requestLua =
        "return require('superlemon.minimap').request(...)"

    private struct PendingRequest {
        var surfaceRequest: MinimapContentRangeRequest
        var wireRange: Range<Int>
        var maxColumns: Int
        var nextLine: Int
    }

    private struct Fields {
        private let values: [String: Value]

        init?(_ value: Value) {
            guard let pairs = value.mapValue else { return nil }
            var decoded: [String: Value] = [:]
            decoded.reserveCapacity(pairs.count)
            for (rawKey, fieldValue) in pairs {
                guard let key = rawKey.stringValue, decoded[key] == nil else {
                    return nil
                }
                decoded[key] = fieldValue
            }
            values = decoded
        }

        subscript(_ key: String) -> Value? { values[key] }
    }

    private let notify: Notify
    private var pendingByWindow: [Int: PendingRequest] = [:]

    private(set) weak var surface: GridSurfaceView?
    private(set) var topologiesByWindow: [Int: MinimapBufferTopology] = [:]

    init(surface: GridSurfaceView? = nil, notify: @escaping Notify) {
        self.notify = notify
        attach(to: surface)
    }

    /// Rebinds the SurfaceKit endpoint without retaining the view. Requests
    /// belong to the surface that originated them, so replacing it cancels
    /// every outstanding identity before the new surface can request data.
    func attach(to nextSurface: GridSurfaceView?) {
        if surface === nextSurface {
            nextSurface?.onMinimapContentRangeRequest = { [weak self] request in
                self?.requestContent(request)
            }
            publishAllTopologies()
            return
        }

        surface?.onMinimapContentRangeRequest = nil
        pendingByWindow.removeAll(keepingCapacity: true)
        surface = nextSurface
        nextSurface?.onMinimapContentRangeRequest = { [weak self] request in
            self?.requestContent(request)
        }
        publishAllTopologies()
    }

    /// Returns true when the method belongs to this bridge. Malformed minimap
    /// traffic is consumed but does not mutate state.
    @discardableResult
    func handleNotification(_ method: String, params: [Value]) -> Bool {
        guard method == Self.providerMethod else { return false }
        guard params.count == 1 else { return true }
        _ = handlePayload(params[0])
        return true
    }

    /// Decodes one `superlemon.minimap` payload. This result reports whether
    /// the payload was valid and current, which is useful to diagnostics and
    /// focused bridge tests.
    @discardableResult
    func handlePayload(_ payload: Value) -> Bool {
        guard let fields = Fields(payload), let kind = fields["kind"]?.stringValue else {
            return false
        }
        switch kind {
        case "windows":
            return applyWindows(fields)
        case "invalidate":
            return applyInvalidation(fields)
        case "content":
            return applyContent(fields)
        default:
            return false
        }
    }

    func topology(for windowHandle: Int) -> MinimapBufferTopology? {
        topologiesByWindow[windowHandle]
    }

    func reset() {
        pendingByWindow.removeAll(keepingCapacity: true)
        topologiesByWindow.removeAll(keepingCapacity: true)
        surface?.setMinimapTopologies([])
    }

    // MARK: - Surface requests

    private func requestContent(_ request: MinimapContentRangeRequest) {
        guard request.requestID > 0, request.gridID > 0,
            let current = topologiesByWindow[request.topology.windowHandle],
            current == request.topology,
            request.topology.windowHandle > 0,
            request.topology.bufferHandle > 0,
            request.lineRange.lowerBound >= 0
        else { return }

        let total = current.totalLineCount
        let firstLine = min(request.lineRange.lowerBound, total)
        let requestedLastLine = min(max(firstLine, request.lineRange.upperBound), total)
        let lastLine: Int
        if requestedLastLine - firstLine > Self.maximumRequestLines {
            lastLine = firstLine + Self.maximumRequestLines
        } else {
            lastLine = requestedLastLine
        }
        let maxColumns = max(1, min(Self.maximumColumns, request.maxColumns))
        let wireRange = firstLine..<lastLine

        pendingByWindow[current.windowHandle] = PendingRequest(
            surfaceRequest: request,
            wireRange: wireRange,
            maxColumns: maxColumns,
            nextLine: firstLine)

        let options: Value = .map([
            (.string("request_id"), .string(String(request.requestID))),
            (.string("winid"), .int(Int64(current.windowHandle))),
            (.string("bufnr"), .int(Int64(current.bufferHandle))),
            (.string("firstline"), .int(Int64(firstLine))),
            (.string("lastline"), .int(Int64(lastLine))),
            (.string("max_columns"), .int(Int64(maxColumns))),
        ])
        notify(
            "nvim_exec_lua",
            [.string(Self.requestLua), .array([options])])
    }

    // MARK: - Topology

    private func applyWindows(_ fields: Fields) -> Bool {
        guard let entries = fields["windows"]?.arrayValue else { return false }
        var decoded: [Int: MinimapBufferTopology] = [:]
        decoded.reserveCapacity(entries.count)

        for value in entries {
            guard let topology = Self.decodeTopology(value),
                decoded[topology.windowHandle] == nil
            else { return false }

            if let existing = topologiesByWindow[topology.windowHandle],
                existing.bufferHandle == topology.bufferHandle
            {
                // Buffer ticks and highlight epochs are monotonic. Never let
                // an older scheduled windows snapshot roll either one back.
                guard topology.changedTick >= existing.changedTick,
                    topology.highlightGeneration >= existing.highlightGeneration
                else { return false }
                if topology.changedTick == existing.changedTick,
                    topology.totalLineCount != existing.totalLineCount
                {
                    return false
                }
            }
            decoded[topology.windowHandle] = topology
        }

        pendingByWindow = pendingByWindow.filter { window, pending in
            decoded[window] == pending.surfaceRequest.topology
        }
        topologiesByWindow = decoded
        publishAllTopologies()
        return true
    }

    private func applyInvalidation(_ fields: Fields) -> Bool {
        guard let buffer = Self.exactInt(fields["bufnr"]), buffer > 0,
            let changedTick = Self.exactInt64(fields["changedtick"]),
            let lineCount = Self.exactInt(fields["line_count"]), lineCount >= 0,
            let highlightGeneration = Self.exactUInt64(fields["highlight_generation"]),
            let firstLine = Self.exactInt(fields["firstline"]), firstLine >= 0,
            let oldLastLine = Self.exactInt(fields["lastline"]), oldLastLine >= -1,
            let newLastLine = Self.exactInt(fields["new_lastline"]), newLastLine >= -1,
            (oldLastLine == -1 || oldLastLine >= firstLine),
            (newLastLine == -1 || newLastLine >= firstLine),
            let detached = Self.boolean(fields, key: "detached", or: false),
            Self.boolean(fields, key: "reload", or: false) != nil,
            Self.boolean(fields, key: "highlights", or: false) != nil
        else { return false }

        let matchingWindows = topologiesByWindow.values
            .filter { $0.bufferHandle == buffer }
            .map(\.windowHandle)
            .sorted()
        guard !matchingWindows.isEmpty else { return true }

        if detached {
            guard changedTick < 0 else { return false }
            for window in matchingWindows {
                pendingByWindow.removeValue(forKey: window)
                topologiesByWindow.removeValue(forKey: window)
                surface?.removeMinimapTopology(windowHandle: window)
            }
            return true
        }

        guard changedTick >= 0 else { return false }
        var replacements: [MinimapBufferTopology] = []
        replacements.reserveCapacity(matchingWindows.count)
        for window in matchingWindows {
            guard let current = topologiesByWindow[window] else { continue }
            guard changedTick >= current.changedTick,
                highlightGeneration >= current.highlightGeneration
            else { return false }
            if changedTick == current.changedTick,
                lineCount != current.totalLineCount
            {
                return false
            }

            let next = MinimapBufferTopology(
                windowHandle: current.windowHandle,
                bufferHandle: current.bufferHandle,
                changedTick: changedTick,
                totalLineCount: lineCount,
                highlightGeneration: highlightGeneration,
                tabstop: current.tabstop,
                bufferLabel: current.bufferLabel,
                filetype: current.filetype)
            if next != current { replacements.append(next) }
        }

        for next in replacements {
            pendingByWindow.removeValue(forKey: next.windowHandle)
            topologiesByWindow[next.windowHandle] = next
            surface?.updateMinimapTopology(next)
        }
        return true
    }

    private static func decodeTopology(_ value: Value) -> MinimapBufferTopology? {
        guard let fields = Fields(value),
            let window = exactInt(fields["winid"]), window > 0,
            let buffer = exactInt(fields["bufnr"]), buffer > 0,
            let changedTick = exactInt64(fields["changedtick"]), changedTick >= 0,
            let lineCount = exactInt(fields["line_count"]), lineCount >= 0,
            let highlightGeneration = exactUInt64(fields["highlight_generation"]),
            let tabstop = exactInt(fields["tabstop"]), tabstop > 0,
            let filetype = fields["filetype"]?.stringValue,
            filetype.utf8.count <= 1_024
        else { return nil }

        let labelValue = fields["buffer_name"]
            ?? fields["buffer_label"]
            ?? fields["bufname"]
        let label: String
        if let labelValue {
            guard let decoded = labelValue.stringValue, decoded.utf8.count <= 4_096 else {
                return nil
            }
            label = decoded
        } else {
            label = ""
        }

        return MinimapBufferTopology(
            windowHandle: window,
            bufferHandle: buffer,
            changedTick: changedTick,
            totalLineCount: lineCount,
            highlightGeneration: highlightGeneration,
            tabstop: tabstop,
            bufferLabel: label,
            filetype: filetype)
    }

    private func publishAllTopologies() {
        surface?.setMinimapTopologies(
            topologiesByWindow.values.sorted { $0.windowHandle < $1.windowHandle })
    }

    // MARK: - Content

    private func applyContent(_ fields: Fields) -> Bool {
        guard let requestID = Self.requestID(fields["request_id"]),
            let window = Self.exactInt(fields["winid"]), window > 0,
            let buffer = Self.exactInt(fields["bufnr"]), buffer > 0,
            let changedTick = Self.exactInt64(fields["changedtick"]), changedTick >= 0,
            let lineCount = Self.exactInt(fields["line_count"]), lineCount >= 0,
            let highlightGeneration = Self.exactUInt64(fields["highlight_generation"]),
            let firstLine = Self.exactInt(fields["firstline"]), firstLine >= 0,
            let lastLine = Self.exactInt(fields["lastline"]), lastLine >= firstLine,
            let complete = fields["complete"]?.boolValue,
            let rawLines = fields["lines"]?.arrayValue,
            let pending = pendingByWindow[window],
            pending.surfaceRequest.requestID == requestID,
            pending.surfaceRequest.topology.windowHandle == window,
            pending.surfaceRequest.topology.bufferHandle == buffer,
            pending.surfaceRequest.topology.changedTick == changedTick,
            pending.surfaceRequest.topology.totalLineCount == lineCount,
            pending.surfaceRequest.topology.highlightGeneration == highlightGeneration,
            topologiesByWindow[window] == pending.surfaceRequest.topology,
            firstLine == pending.nextLine,
            firstLine >= pending.wireRange.lowerBound,
            lastLine <= pending.wireRange.upperBound,
            lastLine - firstLine <= Self.maximumRequestLines,
            rawLines.count == lastLine - firstLine,
            complete ? lastLine == pending.wireRange.upperBound
                : (lastLine > firstLine && lastLine < pending.wireRange.upperBound)
        else { return false }

        var lines: [MinimapLine] = []
        lines.reserveCapacity(rawLines.count)
        for (offset, rawLine) in rawLines.enumerated() {
            guard let line = Self.decodeLine(
                rawLine,
                expectedLine: firstLine + offset,
                maxColumns: pending.maxColumns)
            else { return false }
            lines.append(line)
        }

        let chunk = MinimapContentChunk(
            requestID: requestID,
            gridID: pending.surfaceRequest.gridID,
            topology: pending.surfaceRequest.topology,
            firstLine: firstLine,
            lastLine: lastLine,
            complete: complete,
            lines: lines)

        if complete {
            pendingByWindow.removeValue(forKey: window)
        } else {
            var advanced = pending
            advanced.nextLine = lastLine
            pendingByWindow[window] = advanced
        }
        surface?.provideMinimapContent(chunk)
        return true
    }

    private static func decodeLine(
        _ value: Value, expectedLine: Int, maxColumns: Int
    ) -> MinimapLine? {
        guard let fields = Fields(value),
            exactInt(fields["line"]) == expectedLine,
            let text = fields["text"]?.stringValue,
            text.utf8.count <= maxColumns * 4,
            let rawSpans = fields["spans"]?.arrayValue,
            rawSpans.count <= maximumSpansPerLine
        else { return nil }

        if let byteLengthValue = fields["byte_length"] {
            guard let byteLength = exactInt(byteLengthValue), byteLength >= text.utf8.count else {
                return nil
            }
        }
        if fields["truncated"] != nil, fields["truncated"]?.boolValue == nil {
            return nil
        }

        guard let spans = decodeSpans(rawSpans, textByteCount: text.utf8.count) else {
            return nil
        }
        return MinimapLine(text: text, spans: spans)
    }

    private static func decodeSpans(
        _ values: [Value], textByteCount: Int
    ) -> [MinimapHighlightSpan]? {
        var decoded: [MinimapHighlightSpan] = []
        decoded.reserveCapacity(values.count)

        for value in values {
            guard let fields = Fields(value),
                let start = exactInt(fields["start_col"]), start >= 0,
                let end = exactInt(fields["end_col"]), end > start,
                end <= textByteCount,
                let source = fields["source"]?.stringValue,
                source.utf8.count <= 64,
                let priority = exactInt(fields["priority"]), priority >= 0,
                let order = exactInt(fields["order"]), order >= 0,
                let styleFields = Fields(fields["style"] ?? .nil),
                let style = decodeTextStyle(styleFields),
                let foreground = optionalRGB(styleFields["fg"]),
                let background = optionalRGB(styleFields["bg"]),
                let reverse = boolean(styleFields, key: "reverse", or: false),
                let standout = boolean(styleFields, key: "standout", or: false)
            else { return nil }

            _ = priority
            _ = order
            let byteRange = start..<end
            let directColor = (reverse || standout) ? (background ?? foreground) : foreground
            let inheritedColor = decoded.reversed().first {
                $0.byteRange.lowerBound <= start && $0.byteRange.upperBound >= end
            }?.foregroundRGB
            guard let color = directColor ?? inheritedColor else {
                // A colorless span with no containing resolved run simply
                // inherits SurfaceKit's default foreground and can be omitted.
                continue
            }
            decoded.append(MinimapHighlightSpan(
                byteRange: byteRange,
                foregroundRGB: color,
                style: style))
        }
        return decoded
    }

    private static func decodeTextStyle(_ fields: Fields) -> MinimapTextStyle? {
        guard let bold = boolean(fields, key: "bold", or: false),
            let italic = boolean(fields, key: "italic", or: false),
            let underline = boolean(fields, key: "underline", or: false),
            let undercurl = boolean(fields, key: "undercurl", or: false),
            let underdouble = boolean(fields, key: "underdouble", or: false),
            let underdotted = boolean(fields, key: "underdotted", or: false),
            let underdashed = boolean(fields, key: "underdashed", or: false)
        else { return nil }

        var result: MinimapTextStyle = []
        if bold { result.insert(.bold) }
        if italic { result.insert(.italic) }
        if underline || undercurl || underdouble || underdotted || underdashed {
            result.insert(.underline)
        }
        return result
    }

    /// The outer optional reports validity; its wrapped optional is nil when
    /// the style deliberately omits a color and should inherit it.
    private static func optionalRGB(_ value: Value?) -> UInt32?? {
        guard let value else { return .some(nil) }
        guard let raw = exactUInt64(value), raw <= 0x00FF_FFFF else { return nil }
        return .some(UInt32(raw))
    }

    // MARK: - Exact wire numerics

    private static func exactInt(_ value: Value?) -> Int? {
        guard let value else { return nil }
        switch value {
        case .int(let number): return Int(exactly: number)
        case .uint(let number): return Int(exactly: number)
        default: return nil
        }
    }

    private static func exactInt64(_ value: Value?) -> Int64? {
        guard let value else { return nil }
        switch value {
        case .int(let number): return number
        case .uint(let number): return Int64(exactly: number)
        default: return nil
        }
    }

    private static func exactUInt64(_ value: Value?) -> UInt64? {
        guard let value else { return nil }
        switch value {
        case .int(let number): return number >= 0 ? UInt64(number) : nil
        case .uint(let number): return number
        default: return nil
        }
    }

    private static func requestID(_ value: Value?) -> UInt64? {
        if let numeric = exactUInt64(value) { return numeric }
        guard let text = value?.stringValue, !text.isEmpty,
            text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
            let parsed = UInt64(text), String(parsed) == text
        else { return nil }
        return parsed
    }

    private static func boolean(
        _ fields: Fields, key: String, or defaultValue: Bool
    ) -> Bool? {
        guard let value = fields[key] else { return defaultValue }
        return value.boolValue
    }
}
