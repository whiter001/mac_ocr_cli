import Foundation
import Testing
@testable import MacOCRCore

@Suite("CLIOutputRenderer")
struct CLIOutputRendererTests {
    private func makeReport() -> OCRReport {
        OCRReport(
            imagePath: "/tmp/sample.png",
            lines: [
                OCRTextLine(index: 0, text: "Hello World",     confidence: 0.95, boundingBox: OCRBoundingBox(x: 0.1, y: 0.8, width: 0.5, height: 0.05)),
                OCRTextLine(index: 1, text: "Vision OCR 测试", confidence: 0.80, boundingBox: OCRBoundingBox(x: 0.1, y: 0.6, width: 0.4, height: 0.05)),
                OCRTextLine(index: 2, text: "Goodbye",         confidence: 0.50, boundingBox: OCRBoundingBox(x: 0.1, y: 0.4, width: 0.3, height: 0.05))
            ]
        )
    }

    private func baseOptions(keyword: String? = nil) -> CLIOptions {
        CLIOptions(
            imageURL: URL(fileURLWithPath: "/tmp/sample.png"),
            languages: ["en-US"],
            level: .accurate,
            languageCorrection: true,
            outputMode: .text,
            outputPath: nil,
            keyword: keyword
        )
    }

    @Test("JSON output contains all expected fields")
    func renderJSONContainsAllFields() throws {
        let json = try CLIOutputRenderer.renderJSON(report: makeReport())
        #expect(json.contains("\"imagePath\""))
        #expect(json.contains("/tmp/sample.png"))
        #expect(json.contains("Hello World"))
        #expect(json.contains("\"boundingBox\""))
        #expect(json.contains("\"confidence\""))
    }

    @Test("JSON output is pretty-printed and key-sorted")
    func renderJSONUsesSortedKeysAndPrettyPrinted() throws {
        let json = try CLIOutputRenderer.renderJSON(report: makeReport())
        #expect(json.contains("\n  "))
        let imgIdx = json.range(of: "\"imagePath\"")?.lowerBound
        let linesIdx = json.range(of: "\"lines\"")?.lowerBound
        #expect(imgIdx != nil)
        #expect(linesIdx != nil)
        #expect(imgIdx! < linesIdx!)
    }

    @Test("Text mode without keyword lists all lines")
    func renderTextNoKeywordShowsAllLines() {
        let out = CLIOutputRenderer.renderText(report: makeReport(), options: baseOptions())
        #expect(out.contains("图片: /tmp/sample.png"))
        #expect(out.contains("识别行数: 3"))
        #expect(out.contains("Hello World"))
        #expect(out.contains("Vision OCR 测试"))
    }

    @Test("Text mode with keyword ranks and filters hits")
    func renderTextWithKeywordRanksByScore() {
        let out = CLIOutputRenderer.renderText(
            report: makeReport(),
            options: baseOptions(keyword: "OCR")
        )
        #expect(out.contains("关键词: OCR"))
        #expect(out.contains("Vision OCR 测试"))
        // "Hello World" and "Goodbye" should not appear in the hit section.
        #expect(!out.contains("- [0] 0.90  Hello World"))
        #expect(!out.contains("Goodbye"))
    }

    @Test("Keyword with no matches shows '命中: 无'")
    func renderTextWithKeywordMissesShowNoMatch() {
        let out = CLIOutputRenderer.renderText(
            report: makeReport(),
            options: baseOptions(keyword: "nonexistent")
        )
        #expect(out.contains("命中: 无"))
    }

    @Test("Score: exact match -> 1.0")
    func scoreExactMatch() {
        let line = OCRTextLine(
            index: 0, text: "Login", confidence: 0.5,
            boundingBox: OCRBoundingBox(x: 0, y: 0, width: 0, height: 0)
        )
        #expect(CLIOutputRenderer.score(line: line, keyword: "Login") == 1.0)
    }

    @Test("Score: localizedStandardContains -> 0.9")
    func scoreStandardContains() {
        let line = OCRTextLine(
            index: 0, text: "Sign in with Apple", confidence: 0.5,
            boundingBox: OCRBoundingBox(x: 0, y: 0, width: 0, height: 0)
        )
        #expect(CLIOutputRenderer.score(line: line, keyword: "Sign") == 0.9)
    }

    @Test("Score: case-insensitive match (handled by localizedStandardContains) -> 0.9")
    func scoreCaseInsensitiveOnlyMatch() {
        let line = OCRTextLine(
            index: 0, text: "BRASIL", confidence: 0.5,
            boundingBox: OCRBoundingBox(x: 0, y: 0, width: 0, height: 0)
        )
        #expect(CLIOutputRenderer.score(line: line, keyword: "brasil") == 0.9)
    }

    @Test("Score: no match -> 0.0")
    func scoreNoMatch() {
        let line = OCRTextLine(
            index: 0, text: "alpha", confidence: 0.5,
            boundingBox: OCRBoundingBox(x: 0, y: 0, width: 0, height: 0)
        )
        #expect(CLIOutputRenderer.score(line: line, keyword: "beta") == 0.0)
    }
}
