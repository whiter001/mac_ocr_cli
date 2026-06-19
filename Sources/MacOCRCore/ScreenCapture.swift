import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum ScreenCaptureError: Error, LocalizedError {
    case unableToCaptureScreen
    case unableToCaptureWindow
    case unableToWriteScreenshot
    case invalidRegion
    case unableToFindWindow(String)
    case permissionDenied(String)

    public var errorDescription: String? {
        switch self {
        case .unableToCaptureScreen:
            return "无法截取当前屏幕。"
        case .unableToCaptureWindow:
            return "无法截取指定窗口（窗口可能已关闭或被遮挡）。"
        case .unableToWriteScreenshot:
            return "无法把截图保存为 PNG 文件。"
        case .invalidRegion:
            return "截图区域无效：宽高必须 > 0 且落在主屏幕范围内。"
        case .unableToFindWindow(let query):
            return "无法找到匹配的窗口: \(query)"
        case .permissionDenied(let hint):
            return "缺少屏幕录制权限。\(hint)"
        }
    }
}

public struct ScreenCaptureOptions: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case mainDisplay
        case windowID(UInt32)
        case windowQuery(String)
        case region(CGRect)
    }

    public let source: Source
    /// nil → 写到 `FileManager.default.temporaryDirectory`,调用方负责清理;
    /// 非 nil → 用户显式指定,不会被清理。
    public let savePath: URL?

    public init(source: Source, savePath: URL? = nil) {
        self.source = source
        self.savePath = savePath
    }
}

public struct WindowBounds: Codable, Hashable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(_ rect: CGRect) {
        self.x = Int(rect.origin.x.rounded())
        self.y = Int(rect.origin.y.rounded())
        self.width = Int(rect.size.width.rounded())
        self.height = Int(rect.size.height.rounded())
    }
}

public struct ScreenCaptureWindowInfo: Codable, Hashable, Sendable {
    public let windowID: UInt32
    public let ownerName: String?
    public let windowName: String?
    public let layer: Int
    public let bounds: WindowBounds?

    public init(windowID: UInt32, ownerName: String?, windowName: String?, layer: Int, bounds: WindowBounds?) {
        self.windowID = windowID
        self.ownerName = ownerName
        self.windowName = windowName
        self.layer = layer
        self.bounds = bounds
    }
}

/// 把指定区域 / 窗口 / 主屏幕导出为 PNG 文件并返回路径。
/// 调用方拿到 URL 后,可以把它喂给现有的文件型 OCR 管线;
/// `savePath == nil` 时写到临时目录,由调用方决定是否删除。
public enum ScreenCapture {
    public static func capturePNG(options: ScreenCaptureOptions) throws -> URL {
        let image: CGImage
        switch options.source {
        case .mainDisplay:
            image = try captureMainDisplay()
        case .windowID(let id):
            image = try captureWindow(id: id)
        case .windowQuery(let query):
            image = try captureWindow(matching: query)
        case .region(let rect):
            image = try captureRegion(rect: rect)
        }

        let url = try resolveScreenshotURL(savePath: options.savePath)
        try writePNG(image: image, to: url)
        return url
    }

    public static func listVisibleWindows() -> [ScreenCaptureWindowInfo] {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        return raw.compactMap { dict in
            guard let number = dict[kCGWindowNumber as String] as? NSNumber else { return nil }
            return ScreenCaptureWindowInfo(
                windowID: number.uint32Value,
                ownerName: dict[kCGWindowOwnerName as String] as? String,
                windowName: dict[kCGWindowName as String] as? String,
                layer: (dict[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                bounds: parseBounds(dict[kCGWindowBounds as String])
            )
        }
    }

    // MARK: - 私有实现

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
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { throw ScreenCaptureError.unableToFindWindow(query) }

        let info = listVisibleWindows().first { win in
            let candidates = [win.windowName, win.ownerName]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            return candidates.contains(normalized) || candidates.contains(where: { $0.contains(normalized) })
        }
        guard let info else { throw ScreenCaptureError.unableToFindWindow(query) }
        return try captureWindow(id: info.windowID)
    }

    private static func captureRegion(rect: CGRect) throws -> CGImage {
        guard rect.width > 0, rect.height > 0 else {
            throw ScreenCaptureError.invalidRegion
        }
        let displayID = CGMainDisplayID()
        let displayBounds = CGDisplayBounds(displayID)
        // Vision/截图工具约定屏幕坐标原点在左上角;CoreGraphics 原点在左下角,
        // 需要做一次翻转,并把区域对齐到主屏。
        let converted = convertRegion(rect, in: displayBounds).intersection(displayBounds)
        guard !converted.isNull, !converted.isEmpty else {
            throw ScreenCaptureError.invalidRegion
        }

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

    /// 把「原点在左上角」的 `region` 转成 CoreGraphics 用的「原点在左下角」坐标。
    static func convertRegion(_ region: CGRect, in displayBounds: CGRect) -> CGRect {
        CGRect(
            x: displayBounds.origin.x + region.origin.x,
            // y 翻转：原点在左上角 → 左下角,需要按主屏高度取镜像
            y: displayBounds.origin.y + displayBounds.height - region.origin.y - region.size.height,
            width: region.size.width,
            height: region.size.height
        )
    }

    private static func parseBounds(_ raw: Any?) -> WindowBounds? {
        guard let dict = raw as? [String: Any],
              let x = dict["X"] as? CGFloat,
              let y = dict["Y"] as? CGFloat,
              let w = dict["Width"] as? CGFloat,
              let h = dict["Height"] as? CGFloat
        else { return nil }
        return WindowBounds(CGRect(x: x, y: y, width: w, height: h))
    }

    private static func resolveScreenshotURL(savePath: URL?) throws -> URL {
        if let savePath {
            try FileManager.default.createDirectory(
                at: savePath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return savePath
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("mac_ocr_cli-shot-\(UUID().uuidString)")
            .appendingPathExtension("png")
    }

    private static func writePNG(image: CGImage, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ScreenCaptureError.unableToWriteScreenshot
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ScreenCaptureError.unableToWriteScreenshot
        }
    }
}
