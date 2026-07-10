/// Additive conveniences on `Value`. Kept out of Value.swift so the core
/// wire type stays a stable, minimal contract.

extension Value {
    /// Numeric value as Double: floats directly, integers converted.
    /// nvim sends `anchor_row`/`anchor_col` as floats but other numerics
    /// as integers, so accept both.
    public var doubleValue: Double? {
        switch self {
        case .float(let v): return v
        case .int(let v): return Double(v)
        case .uint(let v): return Double(v)
        default: return nil
        }
    }

    /// Look up a string key in a `.map` value (linear scan; nvim maps are small).
    public subscript(key: String) -> Value? {
        guard case .map(let pairs) = self else { return nil }
        return pairs.first { $0.0 == .string(key) }?.1
    }
}
