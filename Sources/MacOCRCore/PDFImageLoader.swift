import CoreGraphics
import Foundation
import PDFKit

/// 多页 PDF 支持。此前 PDF 走 `CGImageSourceCreateImageAtIndex(_, 0, _)`,
/// 只取第一页且按 72dpi 渲染(文字很小,识别率差);改用 PDFKit 按更高
/// 倍率逐页渲染,既是多页支持也是质量修复。
public enum PDFImageLoader {
    /// 渲染倍率:2.0 ≈ 144dpi。再大 OCR 提升有限但耗时和内存线性上涨。
    public static let defaultRenderScale: CGFloat = 2.0

    /// PDF 页数;非 PDF 或无法打开时返回 0(调用方按普通图片处理或报解码失败)。
    public static func pageCount(of url: URL) -> Int {
        guard url.pathExtension.lowercased() == "pdf",
              let doc = PDFDocument(url: url) else { return 0 }
        return doc.pageCount
    }

    /// 把第 `index` 页渲染成 CGImage(白底,RGB)。
    /// - Throws: `ImageLoaderError.decodeFailed`——打不开文档 / 页码越界 / 无法建上下文。
    public static func renderPage(
        of url: URL,
        page index: Int,
        scale: CGFloat = PDFImageLoader.defaultRenderScale
    ) throws -> CGImage {
        guard let doc = PDFDocument(url: url),
              let page = doc.page(at: index) else {
            throw ImageLoaderError.decodeFailed(url)
        }

        let bounds = page.bounds(for: .mediaBox)
        let pixelW = max(1, Int((bounds.width * scale).rounded()))
        let pixelH = max(1, Int((bounds.height * scale).rounded()))

        guard let ctx = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImageLoaderError.decodeFailed(url)
        }

        // PDF 页面默认透明底,黑字扫到透明底上 OCR 会变差——先铺白。
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))

        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()

        guard let image = ctx.makeImage() else {
            throw ImageLoaderError.decodeFailed(url)
        }
        return image
    }
}
