import Foundation

/// UserDefaults adapter for the smooth-scrolling choice (View ▸ Smooth
/// Scrolling). A GUI-side rendering preference like `AppearancePreferences`:
/// it selects the surface's `ScrollMotionStyle` — display-linked motion when
/// on, every authoritative Neovim frame presented as-is when off — and must
/// exist before any Vim file has run.
public enum ScrollPreferences {
    static let smoothKey = "SmoothScrolling"

    /// Defaults to OFF: Neovim's native scrolling is the standard feel;
    /// smooth motion is opt-in while its tuning is evaluated.
    public static func loadSmoothScrolling(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: smoothKey) as? Bool ?? false
    }

    public static func save(
        smoothScrolling: Bool, to defaults: UserDefaults = .standard
    ) {
        defaults.set(smoothScrolling, forKey: smoothKey)
    }
}
