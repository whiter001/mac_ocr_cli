import CoreGraphics
import Foundation
import ImageIO

public enum ImageLoaderError: Error, LocalizedError {
    case fileNotFound(URL)
    case notAnImage(URL)
    case decodeFailed(URL)
    case fileTooLarge(URL, Int)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "图片文件不存在或无法访问: \(url.path)"
        case .notAnImage(let url):
            return "文件不是受支持的图片格式: \(url.path)"
        case .decodeFailed(let url):
            return "图片解码失败（文件可能已损坏）: \(url.path)"
        case .fileTooLarge(let url, let bytes):
            let mb = Double(bytes) / 1024 / 1024
            return "图片文件过大（\(String(format: "%.1f", mb)) MB,上限 \(Self.sizeLimitMB) MB）: \(url.path)"
        }
    }

    /// 单张图片上限,超过直接拒绝(避免 ImageIO 把多 GB 文件整段读到内存 OOM)。
    static let sizeLimitMB = 200
}

public enum ImageLoader {
    /// 从文件解码 CGImage。
    /// - Parameter maxPixelSize: 非 nil 时在 ImageIO 层做缩略图解码(长边不超过该值),
    ///   避免大图全尺寸解码的内存峰值。小于该值的图不会被放大。
    public static func loadCGImage(from url: URL, maxPixelSize: Int? = nil) throws -> CGImage {
        // 大小检查在前,避免多 GB 文件被 ImageIO 整段解码。`attributesOfItem`
        // 返回 nil 通常意味着文件不存在(竞态删除场景)——也映射成 fileNotFound,
        // 避免再做一个 `fileExists` 前置检查引入 TOCTOU。
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int,
           size > ImageLoaderError.sizeLimitMB * 1024 * 1024 {
            throw ImageLoaderError.fileTooLarge(url, size)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            // CGImageSourceCreateWithURL 对不存在的路径也会返回 nil;
            // 通过 attributesOfItem 已经区分了"太大",这里剩下的 nil
            // 要么是路径不存在,要么不是受支持格式——用 fileNotFound 兜底,
            // 调用方拿到该错误至少知道是路径问题。
            throw ImageLoaderError.fileNotFound(url)
        }

        if let maxPixelSize, maxPixelSize > 0 {
            // 缩略图路径:解码阶段直接降采样,大图(5K 截图/扫描件)的内存和
            // OCR 耗时都能成倍下降。`CreateThumbnailFromImageAlways` 保证按原图
            // 内容重采样而不是取内嵌缩略图;小图不会被放大。
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw ImageLoaderError.decodeFailed(url)
            }
            return image
        }

        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageLoaderError.decodeFailed(url)
        }
        return image
    }

    /// 从内存数据解码(stdin 管道输入用)。
    public static func loadCGImage(fromData data: Data) throws -> CGImage {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageLoaderError.decodeFailed(URL(fileURLWithPath: "/stdin"))
        }
        return image
    }

    /// 内存中的等比降采样(长边 ≤ maxPixelSize)。已经小于上限时原样返回,
    /// 不会放大。截图 / 剪贴板 / PDF 渲染这些"已经是 CGImage"的输入走这里。
    public static func downsample(_ image: CGImage, maxPixelSize: Int) -> CGImage {
        guard maxPixelSize > 0 else { return image }
        let w = image.width, h = image.height
        let longEdge = max(w, h)
        guard longEdge > maxPixelSize else { return image }

        let scale = CGFloat(maxPixelSize) / CGFloat(longEdge)
        let newW = max(1, Int((CGFloat(w) * scale).rounded()))
        let newH = max(1, Int((CGFloat(h) * scale).rounded()))

        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? image
    }
}
