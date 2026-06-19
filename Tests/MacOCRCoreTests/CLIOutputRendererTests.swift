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
            imageURLs: [URL(fileURLWithPath: "/tmp/sample.png")],
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

    // MARK: - 批量输出

    @Test("Batch JSON contains ok and failed items with status field")
    func batchJSONHasStatusField() throws {
        let batch = OCRBatchReport(items: [
            .success(imagePath: "/a.png", lines: [
                OCRTextLine(index: 0, text: "ok", confidence: 0.9, boundingBox: OCRBoundingBox(x: 0, y: 0, width: 0.1, height: 0.1))
            ]),
            .failure(imagePath: "/b.png", error: ImageLoaderError.fileNotFound(URL(fileURLWithPath: "/b.png")))
        ])
        let json = try CLIOutputRenderer.renderBatchJSON(batch: batch)
        #expect(json.contains("\"items\""))
        #expect(json.contains("\"status\""))
        #expect(json.contains("\"ok\""))
        #expect(json.contains("\"failed\""))
        #expect(json.contains("/a.png"))
        #expect(json.contains("/b.png"))
        #expect(json.contains("errorMessage"))
    }

    @Test("Batch text mode shows per-image header and failure line")
    func batchTextShowsHeadersAndFailures() {
        let batch = OCRBatchReport(items: [
            .success(imagePath: "/a.png", lines: [
                OCRTextLine(index: 0, text: "hello", confidence: 0.8, boundingBox: OCRBoundingBox(x: 0, y: 0, width: 0.1, height: 0.1))
            ]),
            .failure(imagePath: "/b.png", error: ImageLoaderError.fileNotFound(URL(fileURLWithPath: "/b.png")))
        ])
        let out = CLIOutputRenderer.renderBatchText(batch: batch)
        #expect(out.contains("批量识别: 共 2 个 (成功 1, 失败 1)"))
        #expect(out.contains("===== [1/2] /a.png ====="))
        #expect(out.contains("===== [2/2] /b.png ====="))
        #expect(out.contains("失败:"))
    }

    @Test("BatchItem.success and .failure set the right status")
    func batchItemFactories() {
        let ok = OCRBatchItem.success(imagePath: "/x", lines: [])
        #expect(ok.status == .ok)
        #expect(ok.lines != nil)
        #expect(ok.errorMessage == nil)

        let fail = OCRBatchItem.failure(imagePath: "/x", error: ImageLoaderError.fileNotFound(URL(fileURLWithPath: "/x")))
        #expect(fail.status == .failed)
        #expect(fail.lines == nil)
        #expect(fail.errorMessage?.isEmpty == false)
    }
}
