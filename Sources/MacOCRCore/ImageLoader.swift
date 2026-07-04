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
    public static func loadCGImage(from url: URL) throws -> CGImage {
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

        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageLoaderError.decodeFailed(url)
        }

        return image
    }
}
