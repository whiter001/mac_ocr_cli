import CoreGraphics
import Foundation
import Testing
@testable import MacOCRCore

@Suite("ScreenCapture helpers")
struct ScreenCaptureTests {
    @Test("windowMatches: exact, substring, case/unicode-insensitive")
    func windowMatching() {
        // 精确匹配(大小写不敏感)
        #expect(ScreenCapture.windowMatches(
            title: "Safari", owner: nil,
            normalizedQuery: ScreenCapture.normalize("safari")
        ))
        // 子串匹配
        #expect(ScreenCapture.windowMatches(
            title: "Documents — Pages", owner: nil,
            normalizedQuery: ScreenCapture.normalize("documents")
        ))
        // Unicode 归一化:precomposed "café" 与分解形式查询互相匹配
        #expect(ScreenCapture.windowMatches(
            title: "Café Menu", owner: nil,
            normalizedQuery: ScreenCapture.normalize("cafe")
        ))
        // owner 名也能匹配
        #expect(ScreenCapture.windowMatches(
            title: nil, owner: "Terminal",
            normalizedQuery: ScreenCapture.normalize("terminal")
        ))
        // 都不匹配
        #expect(!ScreenCapture.windowMatches(
            title: nil, owner: nil,
            normalizedQuery: ScreenCapture.normalize("x")
        ))
    }

    @Test("convertRegion flips Y from top-left to bottom-left origin")
    func regionConversion() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let converted = ScreenCapture.convertRegion(
            CGRect(x: 10, y: 20, width: 100, height: 50),
            in: display
        )
        #expect(converted.origin.x == 10)
        #expect(converted.origin.y == 730.0)  // 800 - 20 - 50
        #expect(converted.size.width == 100)
        #expect(converted.size.height == 50)
    }

    @Test("resolveDisplayID rejects an out-of-range index")
    func displayIndexOutOfRange() {
        #expect(throws: ScreenCaptureError.self) {
            _ = try ScreenCapture.resolveDisplayID(index: 9999)
        }
    }

    @Test("DisplayInfo Codable round-trip")
    func displayInfoRoundTrip() throws {
        let info = DisplayInfo(index: 0, displayID: 1, width: 1512, height: 982, scaleFactor: 2.0, isMain: true)
        let decoded = try JSONDecoder().decode(DisplayInfo.self, from: JSONEncoder().encode(info))
        #expect(decoded == info)
    }
}
