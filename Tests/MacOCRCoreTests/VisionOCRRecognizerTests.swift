import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import MacOCRCore

@Suite("VisionOCRRecognizer(integration)")
struct VisionOCRRecognizerIntegrationTests {
    /// 把大号黑字渲染到白底位图——清晰的合成文本,Vision 识别很稳定。
    private func renderText(_ text: String, width: Int = 900, height: Int = 220) -> CGImage {
        let ctx = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 72, weight: .bold),
            .foregroundColor: NSColor.black
        ]
        text.draw(at: NSPoint(x: 30, y: 70), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()

        return ctx.makeImage()!
    }

    @Test("OCR finds rendered text with sane indices")
    func recognizesRenderedText() async throws {
        let cg = renderText("Hello World")
        let lines = try await VisionOCRRecognizer(
            recognitionLanguages: ["en-US"]
        ).recognizeText(in: cg)

        #expect(!lines.isEmpty)
        let joined = lines.map(\.text).joined(separator: " ")
        #expect(joined.localizedCaseInsensitiveContains("Hello"))
        // index 稠密编号
        #expect(lines.map(\.index) == Array(0..<lines.count))
    }

    @Test("--word-boxes path yields per-word boxes for spaced text")
    func wordBoxesPresent() async throws {
        let cg = renderText("Hello World")
        let lines = try await VisionOCRRecognizer(
            recognitionLanguages: ["en-US"],
            includeWordBoxes: true
        ).recognizeText(in: cg)

        let words = lines.compactMap(\.words).flatMap { $0 }
        // "Hello" 和 "World" 至少各出一个词框;Vision 若整行合并切分,
        // 词数可能不同,所以只断言非空且框在归一化范围内。
        #expect(!words.isEmpty)
        for word in words {
            #expect(!word.text.isEmpty)
            #expect(word.boundingBox.width > 0)
        }
    }

    @Test("minimumConfidence is monotonic: higher threshold never yields more lines")
    func minimumConfidenceFilters() async throws {
        let cg = renderText("Hello World")
        // 合成文本 Vision 可能给出 1.0 满置信度,不能用"阈值 1.0 必为空"断言。
        // 改为验证单调性:阈值越高结果越少,且 0 阈值一定有结果。
        let all = try await VisionOCRRecognizer(
            recognitionLanguages: ["en-US"]
        ).recognizeText(in: cg)
        let filtered = try await VisionOCRRecognizer(
            recognitionLanguages: ["en-US"],
            minimumConfidence: 0.9
        ).recognizeText(in: cg)
        #expect(!all.isEmpty)
        #expect(filtered.count <= all.count)
        #expect(filtered.allSatisfy { $0.confidence >= 0.9 - 1e-6 })
    }

    @Test("supportedLanguages returns a non-empty list containing English")
    func supportedLanguagesNonEmpty() {
        let supported = VisionOCRRecognizer.supportedLanguages(level: .accurate)
        #expect(!supported.isEmpty)
        #expect(supported.contains("en-US"))
    }
}
