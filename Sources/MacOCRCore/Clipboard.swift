import AppKit
import CoreGraphics
import Foundation
import ImageIO

public enum ClipboardError: Error, LocalizedError {
    case writeFailed
    case readEmpty
    case readDecodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .writeFailed:
            return "无法写入系统剪贴板"
        case .readEmpty:
            return "剪贴板中没有图片（先复制一张图片再试）"
        case .readDecodeFailed(let hint):
            return "剪贴板中的图片数据无法解码: \(hint)"
        }
    }
}

/// 截图到剪贴板 / 从剪贴板读图片的薄包装。
/// 全部依赖 AppKit 的 NSPasteboard,不需要额外权限。
public enum Clipboard {
    /// 截图并把 PNG 写入剪贴板。返回图片尺寸 + 真实落盘位置:
    /// - `options.savePath == nil` 时 `savedURL == nil`(只写剪贴板)
    /// - `options.savePath != nil` 时同时落盘到该路径,`savedURL` 等于它
    @discardableResult
    public static func writeCapture(options: ScreenCaptureOptions) async throws -> (width: Int, height: Int, savedURL: URL?) {
        let image = try await ScreenCapture.captureImage(options: options)
        try writeCGImage(image)
        if let savePath = options.savePath {
            try FileManager.default.createDirectory(
                at: savePath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try ScreenCapture.writePNG(image: image, to: savePath)
            return (image.width, image.height, savePath)
        }
        return (image.width, image.height, nil)
    }

    /// 把任意 CGImage 当作 PNG 写入剪贴板。
    public static func writeCGImage(_ image: CGImage) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw ClipboardError.writeFailed
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.setData(data, forType: .png) else {
            throw ClipboardError.writeFailed
        }
    }

    /// 把纯文本写入剪贴板(`--to-clipboard` 用)。
    public static func writeText(_ text: String) throws {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.setString(text, forType: .string) else {
            throw ClipboardError.writeFailed
        }
    }

    /// 从剪贴板读取图片（PNG 优先,其次 TIFF）。
    /// 剪贴板里只有文字时抛 `.readEmpty`;有图片但解码失败抛 `.readDecodeFailed`。
    public static func readImage() throws -> CGImage {
        let pb = NSPasteboard.general
        let types = pb.types ?? []

        if let data = pb.data(forType: .png) {
            return try decode(data: data, format: "PNG")
        }
        if let data = pb.data(forType: .tiff) {
            return try decode(data: data, format: "TIFF")
        }
        if types.isEmpty || (!types.contains(.png) && !types.contains(.tiff)) {
            throw ClipboardError.readEmpty
        }
        throw ClipboardError.readEmpty
    }

    // MARK: - 私有

    private static func decode(data: Data, format: String) throws -> CGImage {
        if let rep = NSBitmapImageRep(data: data), let cg = rep.cgImage {
            return cg
        }
        if let cg = try? ImageLoader.loadCGImage(fromData: data) {
            return cg
        }
        throw ClipboardError.readDecodeFailed("无法解码 \(format) 数据 (bytes=\(data.count))")
    }
}
