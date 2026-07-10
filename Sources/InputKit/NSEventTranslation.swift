// Thin AppKit adapter: the only file in InputKit that touches NSEvent.
// Everything it does is convert an NSEvent into the pure `KeyInput` value
// that `KeyTranslator` operates on.

#if canImport(AppKit)
import AppKit

extension KeyInput {
    /// Snapshot the fields translation needs from a key event.
    ///
    /// Only valid for `.keyDown`/`.keyUp` events — AppKit raises for
    /// `characters` access on other event types, so callers (or the
    /// `KeyTranslator.translate(_:policy:)` overload below) must gate on type.
    public init(event: NSEvent) {
        self.init(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: Modifiers(rawValue: event.modifierFlags.rawValue),
            isARepeat: event.isARepeat
        )
    }
}

extension KeyTranslator {
    /// Translate an NSEvent. Non-`keyDown` events (including `flagsChanged`)
    /// are `.ignored`.
    public func translate(
        _ event: NSEvent,
        policy: OptionPolicy = .default
    ) -> KeyTranslation {
        guard event.type == .keyDown else { return .ignored }
        return translate(KeyInput(event: event), policy: policy)
    }
}
#endif
