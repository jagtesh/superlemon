/// Aggregates each participant's answer to "may termination proceed?" into
/// one overall verdict, so an app-quit coordinator can require every
/// participant (each remote session, then the local one) to consent before
/// termination actually goes through — the first decline cancels the whole
/// thing. Plain, `AppKit`-free value type so the decision logic is
/// unit-testable independent of the windows/controllers that drive it.
public struct TerminationAggregate: Equatable {
    public enum Status: Equatable, Sendable {
        case waiting
        case cancelled
        case approved
    }

    private var remaining: Int
    public private(set) var status: Status

    /// `participants` is how many replies are expected before the
    /// aggregate can approve; zero approves immediately (nothing to wait
    /// on).
    public init(participants: Int) {
        remaining = max(participants, 0)
        status = remaining == 0 ? .approved : .waiting
    }

    /// Record one participant's reply. Once the aggregate has settled
    /// (`.cancelled` or `.approved`), further replies are ignored and the
    /// status is simply returned unchanged.
    @discardableResult
    public mutating func add(reply: Bool) -> Status {
        guard status == .waiting else { return status }
        guard reply else {
            status = .cancelled
            return status
        }
        remaining -= 1
        status = remaining <= 0 ? .approved : .waiting
        return status
    }
}
