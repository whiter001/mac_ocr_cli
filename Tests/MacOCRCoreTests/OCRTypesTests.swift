import Foundation
import Testing
@testable import MacOCRCore

@Suite("OCRTypes")
struct OCRTypesTests {
    @Test("BoundingBox preserves CGRect values")
    func boundingBoxFromCGRectPreservesValues() {
        let rect = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.05)
        let box = OCRBoundingBox(rect)
        #expect(box.x == 0.1)
        #expect(box.y == 0.2)
        #expect(box.width == 0.5)
        #expect(box.height == 0.05)
    }

    @Test("TextLine sanitizes out-of-range confidence and box")
    func textLineSanitizesConfidenceAndBox() {
        let line = OCRTextLine(
            index: 3,
            text: "hi",
            confidence: 1.5,                  // > 1
            boundingBox: OCRBoundingBox(
                x: -0.1, y: 1.2, width: -0.5, height: .infinity
            )
        )
        #expect(line.index == 3)
        #expect(line.confidence == 1.0)
        #expect(line.boundingBox.x == 0.0)
        #expect(line.boundingBox.y == 1.0)
        #expect(line.boundingBox.width == 0.5)
        #expect(line.boundingBox.height == 0.0) // inf -> 0
    }

    @Test("TextLine clamps negative index to zero")
    func textLineNegativeIndexClampsToZero() {
        let line = OCRTextLine(
            index: -5, text: "x", confidence: 0.5,
            boundingBox: OCRBoundingBox(x: 0, y: 0, width: 0, height: 0)
        )
        #expect(line.index == 0)
    }

    @Test("TextLine Codable round-trip")
    func textLineCodableRoundTrip() throws {
        let original = OCRTextLine(
            index: 2,
            text: "中文 line",
            confidence: 0.42,
            boundingBox: OCRBoundingBox(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OCRTextLine.self, from: data)
        #expect(decoded == original)
    }

    @Test("OCRReport Codable round-trip")
    func reportCodableRoundTrip() throws {
        let report = OCRReport(
            imagePath: "/tmp/x.png",
            lines: [
                OCRTextLine(index: 0, text: "a", confidence: 0.9, boundingBox: OCRBoundingBox(x: 0, y: 0, width: 0.1, height: 0.1)),
                OCRTextLine(index: 1, text: "b", confidence: 0.5, boundingBox: OCRBoundingBox(x: 0, y: 0, width: 0.2, height: 0.1))
            ]
        )
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(OCRReport.self, from: data)
        #expect(decoded == report)
    }
}
