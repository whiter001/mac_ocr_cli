import Foundation
import Testing
import CoreGraphics
@testable import MacOCRCore

@Suite("PDFImageLoader")
struct PDFImageLoaderTests {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mac_ocr_cli_pdf_tests_\(UUID().uuidString)")

    init() {
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    /// 用 CGPDFContext 生成 N 页空白 PDF(200x100 point)。
    private func makePDF(pages: Int, name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        var rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        guard let ctx = CGContext(url as CFURL, mediaBox: &rect, nil) else {
            Issue.record("could not create PDF context")
            throw ImageLoaderError.decodeFailed(url)
        }
        for _ in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(rect)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    @Test("pageCount reports page number; non-PDF returns 0")
    func pageCountReportsPages() throws {
        let two = try makePDF(pages: 2, name: "two.pdf")
        #expect(PDFImageLoader.pageCount(of: two) == 2)

        let one = try makePDF(pages: 1, name: "one.pdf")
        #expect(PDFImageLoader.pageCount(of: one) == 1)

        // 非 PDF / 不存在的文件返回 0,交给调用方按普通图片处理
        let txt = tempDir.appendingPathComponent("plain.txt")
        try "hello".write(to: txt, atomically: true, encoding: .utf8)
        #expect(PDFImageLoader.pageCount(of: txt) == 0)
        #expect(PDFImageLoader.pageCount(of: tempDir.appendingPathComponent("nope.pdf")) == 0)
    }

    @Test("renderPage renders at default 2x scale")
    func renderPageScale() throws {
        let url = try makePDF(pages: 1, name: "render.pdf")
        let image = try PDFImageLoader.renderPage(of: url, page: 0)
        // 200x100 point @2x → 400x200 像素
        #expect(image.width == 400)
        #expect(image.height == 200)
    }

    @Test("renderPage honors explicit scale")
    func renderPageExplicitScale() throws {
        let url = try makePDF(pages: 1, name: "render1x.pdf")
        let image = try PDFImageLoader.renderPage(of: url, page: 0, scale: 1.0)
        #expect(image.width == 200)
        #expect(image.height == 100)
    }

    @Test("renderPage with out-of-range page throws decodeFailed")
    func renderPageOutOfRange() throws {
        let url = try makePDF(pages: 1, name: "single.pdf")
        #expect(throws: ImageLoaderError.self) {
            _ = try PDFImageLoader.renderPage(of: url, page: 5)
        }
    }
}
