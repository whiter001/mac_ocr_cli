import CoreGraphics
import Foundation
import ImageIO

public enum ImageLoaderError: Error, LocalizedError {
    case fileNotFound(URL)
    case notAnImage(URL)
    case decodeFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "图片文件不存在或无法访问: \(url.path)"
        case .notAnImage(let url):
            return "文件不是受支持的图片格式: \(url.path)"
        case .decodeFailed(let url):
            return "图片解码失败（文件可能已损坏）: \(url.path)"
        }
    }
}

public enum ImageLoader {
    public static func loadCGImage(from url: URL) throws -> CGImage {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ImageLoaderError.fileNotFound(url)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageLoaderError.notAnImage(url)
        }

        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageLoaderError.decodeFailed(url)
        }

        return image
    }
}
