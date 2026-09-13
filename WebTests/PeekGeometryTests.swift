import AppKit
import Testing
@testable import Web

struct PeekGeometryTests {
    @Test func expansionKeepsTheScreenCorner() {
        for screen in [NSRect(x: 0, y: 30, width: 1440, height: 870), NSRect(x: -1280, y: 200, width: 1280, height: 700)] {
            let compact = PeekGeometry.frame(in: screen, expanded: false)
            let expanded = PeekGeometry.frame(in: screen, expanded: true)
            #expect(compact.maxX == expanded.maxX)
            #expect(compact.minY == expanded.minY)
            #expect(screen.contains(expanded))
            #expect(expanded.maxX == screen.maxX - 16)
        }
    }

    @Test func fitsSmallDisplays() {
        let screen = NSRect(x: 100, y: -600, width: 480, height: 400)
        #expect(screen.contains(PeekGeometry.frame(in: screen, expanded: true)))
    }
}
