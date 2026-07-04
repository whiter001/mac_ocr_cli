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
    public static func writeCapture(options: ScreenCaptureOptions) throws -> (width: Int, height: Int, savedURL: URL?) {
        let image = try captureForClipboard(options: options)
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

    private static func captureForClipboard(options: ScreenCaptureOptions) throws -> CGImage {
        switch options.source {
        case .mainDisplay:
            return try captureMainDisplay()
        case .windowID(let id):
            return try captureWindow(id: id)
        case .windowQuery(let query):
            return try captureWindow(matching: query)
        case .region(let rect):
            return try captureRegion(rect: rect)
        }
    }

    // 复用 ScreenCapture 的私有实现不便,这里独立拷一份最小集合。
    // 保持与 ScreenCapture 的行为一致:区域用左上角原点,主屏基准,CG 坐标 Y 翻转。

    private static func captureMainDisplay() throws -> CGImage {
        let displayID = CGMainDisplayID()
        guard let image = CGDisplayCreateImage(displayID) else {
            throw ScreenCaptureError.permissionDenied(
                "请在 系统设置 → 隐私与安全性 → 屏幕录制 中允许此程序,再重试。"
            )
        }
        return image
    }

    private static func captureWindow(id: UInt32) throws -> CGImage {
        guard let image = CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(id), [.bestResolution]
        ) else {
            throw ScreenCaptureError.permissionDenied(
                "请在 系统设置 → 隐私与安全性 → 屏幕录制 中允许此程序,再重试。"
            )
        }
        return image
    }

    private static func captureWindow(matching query: String) throws -> CGImage {
        let normalized = ScreenCapture.normalize(query)
        guard !normalized.isEmpty else { throw ScreenCaptureError.unableToFindWindow(query) }
        let info = ScreenCapture.listVisibleWindows().first { win in
            let candidates = [win.windowName, win.ownerName]
                .compactMap { $0.map(ScreenCapture.normalize) }
                .filter { !$0.isEmpty }
            return candidates.contains(normalized) || candidates.contains(where: { $0.contains(normalized) })
        }
        guard let info else { throw ScreenCaptureError.unableToFindWindow(query) }
        return try captureWindow(id: info.windowID)
    }

    private static func captureRegion(rect: CGRect) throws -> CGImage {
        guard rect.width > 0, rect.height > 0 else { throw ScreenCaptureError.invalidRegion }
        let displayID = CGMainDisplayID()
        let displayBounds = CGDisplayBounds(displayID)
        let converted = ScreenCapture.convertRegion(rect, in: displayBounds).intersection(displayBounds)
        guard !converted.isNull, !converted.isEmpty else { throw ScreenCaptureError.invalidRegion }

        // 与 ScreenCapture.captureRegion 保持一致:区域被屏幕边界裁掉时给 stderr 提示。
        if abs(converted.width - rect.width) > 0.5 || abs(converted.height - rect.height) > 0.5 {
            fputs(
                "[警告] 截图区域超出主屏幕边界,实际尺寸: \(Int(converted.width))x\(Int(converted.height))（期望: \(Int(rect.width))x\(Int(rect.height))）\n",
                stderr
            )
        }

        guard let image = CGDisplayCreateImage(displayID, rect: converted) else {
            throw ScreenCaptureError.permissionDenied(
                "请在 系统设置 → 隐私与安全性 → 屏幕录制 中允许此程序,再重试。"
            )
        }
        return image
    }

    private static func decode(data: Data, format: String) throws -> CGImage {
        if let rep = NSBitmapImageRep(data: data), let cg = rep.cgImage {
            return cg
        }
        if let src = CGImageSourceCreateWithData(data as CFData, nil),
           let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            return cg
        }
        throw ClipboardError.readDecodeFailed("无法解码 \(format) 数据 (bytes=\(data.count))")
    }
}
