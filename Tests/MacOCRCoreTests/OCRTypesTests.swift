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

    // MARK: - 1.2.0 新字段

    @Test("TextLine with word boxes round-trips")
    func textLineWithWordsRoundTrip() throws {
        let line = OCRTextLine(
            index: 0,
            text: "a b",
            confidence: 0.9,
            boundingBox: OCRBoundingBox(x: 0, y: 0, width: 0.2, height: 0.1),
            words: [OCRWordBox(text: "a", boundingBox: OCRBoundingBox(x: 0, y: 0, width: 0.08, height: 0.1))]
        )
        let decoded = try JSONDecoder().decode(OCRTextLine.self, from: JSONEncoder().encode(line))
        #expect(decoded == line)
        #expect(decoded.words?.first?.text == "a")
    }

    @Test("Report metadata fields round-trip; legacy JSON without them still decodes")
    func reportMetadataAndLegacyCompat() throws {
        let report = OCRReport(
            imagePath: "/x",
            lines: [],
            imageWidth: 100,
            imageHeight: 50,
            durationMilliseconds: 42
        )
        let decoded = try JSONDecoder().decode(OCRReport.self, from: JSONEncoder().encode(report))
        #expect(decoded == report)

        // 旧版输出没有元数据键,按可选字段解码,不能崩。
        let legacy = Data("{\"imagePath\":\"/x\",\"lines\":[]}".utf8)
        let legacyDecoded = try JSONDecoder().decode(OCRReport.self, from: legacy)
        #expect(legacyDecoded.imageWidth == nil)
        #expect(legacyDecoded.durationMilliseconds == nil)
    }

    @Test("BatchItem keywordMatches + metadata round-trip; legacy JSON decodes")
    func batchItemNewFields() throws {
        let item = OCRBatchItem(
            imagePath: "/a.png",
            status: .ok,
            lines: [],
            errorMessage: nil,
            keywordMatches: [OCRKeywordMatch(index: 0, score: 1.0, text: "登录")],
            imageWidth: 10,
            imageHeight: 20,
            durationMilliseconds: 5
        )
        let decoded = try JSONDecoder().decode(OCRBatchItem.self, from: JSONEncoder().encode(item))
        #expect(decoded == item)

        let legacy = Data("{\"imagePath\":\"/a.png\",\"status\":\"ok\",\"lines\":[]}".utf8)
        let legacyDecoded = try JSONDecoder().decode(OCRBatchItem.self, from: legacy)
        #expect(legacyDecoded.keywordMatches == nil)
        #expect(legacyDecoded.imageWidth == nil)
    }

    @Test("Barcode types round-trip")
    func barcodeTypesRoundTrip() throws {
        let batch = BarcodeBatchReport(items: [
            .success(
                imagePath: "/qr.png",
                barcodes: [OCRBarcode(symbology: "VNBarcodeSymbologyQR", payload: "p", boundingBox: OCRBoundingBox(x: 0, y: 0, width: 0.5, height: 0.5))],
                imageWidth: 100,
                imageHeight: 100,
                durationMilliseconds: 7
            ),
            .failure(imagePath: "/bad.png", error: ImageLoaderError.fileNotFound(URL(fileURLWithPath: "/bad.png")))
        ])
        let decoded = try JSONDecoder().decode(BarcodeBatchReport.self, from: JSONEncoder().encode(batch))
        #expect(decoded == batch)
        #expect(decoded.successCount == 1)
        #expect(decoded.failureCount == 1)
    }
}
