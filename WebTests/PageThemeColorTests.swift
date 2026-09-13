import AppKit
import Testing
@testable import Web

struct PageThemeColorTests {
    @Test func acceptsOpaqueSRGBPixels() {
        let color = PageThemeColor.color(from: [32, 96, 192, 255])
        #expect(color != nil)
        #expect(abs((color?.redComponent ?? 0) - 32.0 / 255) < 0.0001)
        #expect(PageThemeColor.usable(color) != nil)
    }

    @Test func rejectsInvalidOrTransparentPixels() {
        let invalid: [Any] = [
            [0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 254],
            [-1, 0, 0, 255], [256, 0, 0, 255], [0.5, 0, 0, 255],
            [Double.nan, 0, 0, 255], [Double.infinity, 0, 0, 255],
            ["red", "green", "blue", "alpha"]
        ]
        for pixels in invalid { #expect(PageThemeColor.color(from: pixels) == nil) }
        #expect(PageThemeColor.color(from: nil) == nil)
    }

    @Test func absentOrTransparentColorsUseTheNeutralFallback() {
        #expect(PageThemeColor.usable(nil) == nil)
        #expect(PageThemeColor.usable(.clear) == nil)
        #expect(PageThemeColor.usable(.red)?.alphaComponent == 1)
    }

    @Test func sharedTopEdgeOverridesContrastingMetadata() {
        let black = [0, 0, 0, 255]
        let white = [255, 255, 255, 255]
        let control = [200, 30, 30, 255]
        let result: [String: Any] = ["edges": [black, black, control, black, NSNull()], "fallback": white]
        #expect(PageThemeColor.color(from: result)?.redComponent == 0)
    }

    @Test func mixedTopEdgeUsesPageFallback() {
        let black = [0, 0, 0, 255]
        let white = [255, 255, 255, 255]
        let fallback = [32, 96, 192, 255]
        let result: [String: Any] = ["edges": [black, white, black, white, NSNull()], "fallback": fallback]
        #expect(PageThemeColor.color(from: result) == PageThemeColor.color(from: fallback))
    }

    @Test func missingAndInvalidSamplesCannotCreateAMajority() {
        let black = [0, 0, 0, 255]
        let white = [255, 255, 255, 255]
        let result: [String: Any] = [
            "edges": [black, black, [0, 0, 0, 0], [Double.nan, 0, 0, 255], NSNull()],
            "fallback": white
        ]
        #expect(PageThemeColor.color(from: result)?.redComponent == 1)
    }

}
