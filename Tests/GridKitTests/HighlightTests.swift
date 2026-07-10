import Testing
import NvimKit
@testable import GridKit

@Suite struct HighlightTableTests {
    func makeTable() -> HighlightTable {
        var table = HighlightTable()
        table.setDefaults(foreground: rgb(0x112233), background: rgb(0x445566), special: rgb(0x778899))
        return table
    }

    @Test func unknownAndZeroIDsResolveToDefaults() {
        let table = makeTable()
        for id in [0, 999] {
            let r = table.resolved(id: id)
            #expect(r.foreground == rgb(0x112233))
            #expect(r.background == rgb(0x445566))
            #expect(r.special == rgb(0x778899))
            #expect(!r.bold && !r.italic && !r.underline && !r.undercurl)
        }
    }

    @Test func definedAttrsOverrideOnlySetFields() {
        var table = makeTable()
        var attrs = HlAttrs()
        attrs.foreground = rgb(0xFF0000)
        attrs.bold = true
        attrs.undercurl = true
        table.define(id: 1, attrs: attrs)
        let r = table.resolved(id: 1)
        #expect(r.foreground == rgb(0xFF0000))
        #expect(r.background == rgb(0x445566)) // fell back to default
        #expect(r.special == rgb(0x778899))    // fell back to default
        #expect(r.bold && r.undercurl && !r.italic)
    }

    @Test func reverseSwapsResolvedColors() {
        var table = makeTable()
        var attrs = HlAttrs()
        attrs.reverse = true
        table.define(id: 2, attrs: attrs)
        let r = table.resolved(id: 2)
        #expect(r.foreground == rgb(0x445566))
        #expect(r.background == rgb(0x112233))

        // Reverse applies after explicit colors, too.
        var explicit = HlAttrs()
        explicit.foreground = rgb(0x0000FF)
        explicit.background = rgb(0x00FF00)
        explicit.reverse = true
        table.define(id: 3, attrs: explicit)
        let e = table.resolved(id: 3)
        #expect(e.foreground == rgb(0x00FF00))
        #expect(e.background == rgb(0x0000FF))
    }

    @Test func defaultColorsSetChangesResolutionOfExistingIDs() {
        var table = makeTable()
        var attrs = HlAttrs()
        attrs.italic = true
        table.define(id: 4, attrs: attrs)
        table.setDefaults(foreground: rgb(0xAAAAAA), background: rgb(0x000000), special: rgb(0x123456))
        let r = table.resolved(id: 4)
        #expect(r.foreground == rgb(0xAAAAAA))
        #expect(r.background == rgb(0x000000))
        #expect(r.special == rgb(0x123456))
        #expect(r.italic)
    }

    @Test func groupNameMapsToID() {
        var table = makeTable()
        table.setGroup(name: "Normal", id: 1)
        table.setGroup(name: "PMenu", id: 7)
        table.setGroup(name: "PMenu", id: 8) // redefinition wins
        #expect(table.id(forGroup: "Normal") == 1)
        #expect(table.id(forGroup: "PMenu") == 8)
        #expect(table.id(forGroup: "Missing") == nil)
    }
}

@MainActor
@Suite struct HighlightStoreTests {
    @Test func storeAppliesHighlightEvents() {
        let store = makeStore()
        var bold = HlAttrs()
        bold.bold = true
        store.apply(batch(
            .defaultColorsSet(fg: rgb(0xEEEEEE), bg: rgb(0x111111), special: rgb(0xFF00FF)),
            .hlAttrDefine(id: 1, attrs: bold),
            .hlGroupSet(name: "StatusLine", id: 1)
        ))
        let r = store.highlights.resolved(id: 1)
        #expect(r.bold)
        #expect(r.foreground == rgb(0xEEEEEE))
        #expect(store.highlights.id(forGroup: "StatusLine") == 1)
    }

    @Test func defaultColorsSetDamagesAllGrids() {
        let store = makeStore()
        _ = store.apply(batch(.gridResize(grid: 2, width: 4, height: 2), .flush))
        store.apply(batch(.defaultColorsSet(fg: rgb(0), bg: rgb(0xFFFFFF), special: rgb(0))))
        #expect(store.grids[1]!.damage.rowSpans == fullDamage(rows: 10, cols: 20))
        #expect(store.grids[2]!.damage.rowSpans == fullDamage(rows: 2, cols: 4))
    }
}
