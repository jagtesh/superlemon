import Foundation
import Testing

@testable import EditorHostKit

@Suite("Smooth-scrolling preference")
struct ScrollPreferencesTests {

    @Test func defaultsToOffAndRoundTrips() {
        let defaults = UserDefaults(suiteName: "scroll-tests-\(UUID().uuidString)")!
        #expect(!ScrollPreferences.loadSmoothScrolling(from: defaults))

        ScrollPreferences.save(smoothScrolling: true, to: defaults)
        #expect(ScrollPreferences.loadSmoothScrolling(from: defaults))

        ScrollPreferences.save(smoothScrolling: false, to: defaults)
        #expect(!ScrollPreferences.loadSmoothScrolling(from: defaults))
    }
}
