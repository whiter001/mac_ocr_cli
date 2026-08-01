import Foundation
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

public enum ScreenCaptureError: Error, LocalizedError {
    case unableToCaptureScreen
    case unableToCaptureWindow
    case unableToWriteScreenshot
    case invalidRegion
    case unableToFindWindow(String)
    case permissionDenied(String)
    case displayNotFound(Int)
    case captureFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unableToCaptureScreen:
            return "无法截取当前屏幕。"
        case .unableToCaptureWindow:
            return "无法截取指定窗口（窗口可能已关闭或被遮挡）。"
        case .unableToWriteScreenshot:
            return "无法把截图保存为 PNG 文件。"
        case .invalidRegion:
            return "截图区域无效：宽高必须 > 0 且落在目标屏幕范围内。"
        case .unableToFindWindow(let query):
            return "无法找到匹配的窗口: \(query)"
        case .permissionDenied(let hint):
            return "缺少屏幕录制权限。\(hint)"
        case .displayNotFound(let index):
            return "显示器不存在: --display \(index)（用 --display-list 查看可用显示器）"
        case .captureFailed(let reason):
            return "截图失败: \(reason)"
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
    /// 目标显示器序号(0 = 主屏,与 `--display-list` 输出一致)。
    /// 仅作用于 `.mainDisplay` 和 `.region`;窗口截图跨屏无需指定。
    public let displayIndex: Int

    public init(source: Source, savePath: URL? = nil, displayIndex: Int = 0) {
        self.source = source
        self.savePath = savePath
        self.displayIndex = displayIndex
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

/// 一台显示器的描述(`--display-list` 输出)。序号与 `--display` 参数一致:
/// 0 永远是主屏。
public struct DisplayInfo: Codable, Hashable, Sendable {
    public let index: Int
    public let displayID: UInt32
    /// 逻辑尺寸(point)。像素尺寸 ≈ point × scaleFactor。
    public let width: Int
    public let height: Int
    public let scaleFactor: Double
    public let isMain: Bool

    public init(index: Int, displayID: UInt32, width: Int, height: Int, scaleFactor: Double, isMain: Bool) {
        self.index = index
        self.displayID = displayID
        self.width = width
        self.height = height
        self.scaleFactor = scaleFactor
        self.isMain = isMain
    }
}

/// 屏幕 / 窗口 / 区域截图。
///
/// 实现分两代:macOS 14+ 走 ScreenCaptureKit(`SCScreenshotManager`),
/// 旧系统回落到 `CGWindowListCreateImage` 系列(该 API 在 macOS 15 已标记
/// deprecated,新代码不应再依赖它)。两条路径对调用方语义一致。
public enum ScreenCapture {

    // MARK: - 截图

    /// 截图并直接返回内存中的 `CGImage`。不落盘、不解码,是 OCR 管线的首选入口。
    public static func captureImage(options: ScreenCaptureOptions) async throws -> CGImage {
        if #available(macOS 14.0, *) {
            return try await captureImageModern(options: options)
        }
        return try captureImageLegacy(options: options)
    }

    /// 截图并导出为 PNG 文件。需要文件产物(--save-screenshot)时使用。
    public static func capturePNG(options: ScreenCaptureOptions) async throws -> URL {
        let image = try await captureImage(options: options)
        let url = try resolveScreenshotURL(savePath: options.savePath)
        try writePNG(image: image, to: url)
        return url
    }

    // MARK: - 枚举

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

    /// 列出活动显示器,主屏排在 index 0。无屏幕录制权限时返回空数组。
    public static func listDisplays() async -> [DisplayInfo] {
        if #available(macOS 14.0, *) {
            return await listDisplaysModern()
        }
        return listDisplaysLegacy()
    }

    // MARK: - 共享辅助

    /// 归一化窗口匹配字符串:trim → lowercase → NFD(分解)。
    /// 用 NFD 形式让 `"café"`(U+00E9)和 `"cafe\u{0301}"`(NFD)能互相匹配。
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .decomposedStringWithCanonicalMapping
    }

    /// 窗口标题 / 应用名与归一化查询串的匹配规则,legacy 与现代路径共用,
    /// 避免两套实现行为漂移。
    /// 子串匹配用 `localizedStandardContains`(大小写 + 音调符号不敏感):
    /// 普通 `contains` 按字素簇匹配,NFD 拆出的组合字符会让 "cafe"
    /// 匹配不到 "café"——查询里没敲重音符号时不该因此漏窗口。
    static func windowMatches(title: String?, owner: String?, normalizedQuery: String) -> Bool {
        [title, owner]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .contains { candidate in
                normalize(candidate) == normalizedQuery
                    || candidate.localizedStandardContains(normalizedQuery)
            }
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

    /// 把 `CGImage` 写成 PNG 文件。会覆盖已存在的文件。
    public static func writePNG(image: CGImage, to url: URL) throws {
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

    private static func parseBounds(_ raw: Any?) -> WindowBounds? {
        guard let dict = raw as? [String: Any],
              let x = dict["X"] as? CGFloat,
              let y = dict["Y"] as? CGFloat,
              let w = dict["Width"] as? CGFloat,
              let h = dict["Height"] as? CGFloat
        else { return nil }
        return WindowBounds(CGRect(x: x, y: y, width: w, height: h))
    }

    private static func warnRegionClipped(expected: CGRect, actual: CGSize) {
        fputs(
            "[警告] 截图区域超出屏幕边界,实际尺寸: \(Int(actual.width))x\(Int(actual.height))（期望: \(Int(expected.width))x\(Int(expected.height))）\n",
            stderr
        )
    }

    // MARK: - 显示器枚举(legacy)

    /// 活动显示器 ID 列表,主屏排在第一位。`--display n` 的序号就是这里的位置。
    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        ids = Array(ids.prefix(Int(count)))
        // 主屏优先,其余按 ID 排序保证序号稳定。
        return ids.sorted { a, b in
            (a == CGMainDisplayID() && b != CGMainDisplayID())
                || (a != CGMainDisplayID() && b != CGMainDisplayID() && a < b)
        }
    }

    static func resolveDisplayID(index: Int) throws -> CGDirectDisplayID {
        let ids = activeDisplayIDs()
        guard index >= 0, index < ids.count else {
            throw ScreenCaptureError.displayNotFound(index)
        }
        return ids[index]
    }

    static func listDisplaysLegacy() -> [DisplayInfo] {
        activeDisplayIDs().enumerated().map { index, id in
            let bounds = CGDisplayBounds(id)
            let pixelW = CGFloat(CGDisplayPixelsWide(id))
            let scale = bounds.width > 0 ? Double(pixelW / bounds.width) : 1
            return DisplayInfo(
                index: index,
                displayID: id,
                width: Int(bounds.width.rounded()),
                height: Int(bounds.height.rounded()),
                scaleFactor: scale,
                isMain: id == CGMainDisplayID()
            )
        }
    }

    // MARK: - 截图实现(legacy,macOS 13)

    static func captureImageLegacy(options: ScreenCaptureOptions) throws -> CGImage {
        switch options.source {
        case .mainDisplay:
            return try captureDisplayLegacy(displayID: resolveDisplayID(index: options.displayIndex))
        case .windowID(let id):
            return try captureWindowLegacy(id: id)
        case .windowQuery(let query):
            let normalized = Self.normalize(query)
            guard !normalized.isEmpty else { throw ScreenCaptureError.unableToFindWindow(query) }
            let info = listVisibleWindows().first {
                windowMatches(title: $0.windowName, owner: $0.ownerName, normalizedQuery: normalized)
            }
            guard let info else { throw ScreenCaptureError.unableToFindWindow(query) }
            return try captureWindowLegacy(id: info.windowID)
        case .region(let rect):
            return try captureRegionLegacy(rect: rect, displayIndex: options.displayIndex)
        }
    }

    private static func captureDisplayLegacy(displayID: CGDirectDisplayID) throws -> CGImage {
        guard let image = CGDisplayCreateImage(displayID) else {
            throw ScreenCaptureError.permissionDenied(
                "请在 系统设置 → 隐私与安全性 → 屏幕录制 中允许此程序,再重试。"
            )
        }
        return image
    }

    private static func captureWindowLegacy(id: UInt32) throws -> CGImage {
        guard let image = CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(id), [.bestResolution]
        ) else {
            throw ScreenCaptureError.permissionDenied(
                "请在 系统设置 → 隐私与安全性 → 屏幕录制 中允许此程序,再重试。"
            )
        }
        return image
    }

    private static func captureRegionLegacy(rect: CGRect, displayIndex: Int) throws -> CGImage {
        guard rect.width > 0, rect.height > 0 else {
            throw ScreenCaptureError.invalidRegion
        }
        let displayID = try resolveDisplayID(index: displayIndex)
        let displayBounds = CGDisplayBounds(displayID)
        // Vision/截图工具约定屏幕坐标原点在左上角;CoreGraphics 原点在左下角,
        // 需要做一次翻转,并把区域对齐到目标屏。
        let converted = convertRegion(rect, in: displayBounds).intersection(displayBounds)
        guard !converted.isNull, !converted.isEmpty else {
            throw ScreenCaptureError.invalidRegion
        }

        if abs(converted.width - rect.width) > 0.5 || abs(converted.height - rect.height) > 0.5 {
            warnRegionClipped(expected: rect, actual: converted.size)
        }

        guard let image = CGDisplayCreateImage(displayID, rect: converted) else {
            throw ScreenCaptureError.permissionDenied(
                "请在 系统设置 → 隐私与安全性 → 屏幕录制 中允许此程序,再重试。"
            )
        }
        return image
    }

    // MARK: - 截图实现(ScreenCaptureKit,macOS 14+)

    @available(macOS 14.0, *)
    private static func shareableContent() async throws -> SCShareableContent {
        // macOS 26 上 `SCContentFilter(desktopIndependentWindow:)` 内部有
        // CGS_REQUIRE_INIT 断言:进程若还没建立 CoreGraphics 会话就直接 Abort。
        // 整屏/区域路径会先调 CGMainDisplayID()(选屏)碰巧完成了初始化,
        // 窗口路径则必崩。在这里显式触发一次,代价可忽略。
        _ = CGMainDisplayID()
        // 未授予屏幕录制权限时 SCShareableContent 不抛错,而是返回空列表。
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard !content.displays.isEmpty else {
            throw ScreenCaptureError.permissionDenied(
                "请在 系统设置 → 隐私与安全性 → 屏幕录制 中允许此程序,再重试。"
            )
        }
        return content
    }

    /// SCDisplay 列表排序成与 legacy 一致的序号:主屏(index 0)优先。
    @available(macOS 14.0, *)
    private static func orderedDisplays(_ displays: [SCDisplay]) -> [SCDisplay] {
        displays.sorted { a, b in
            (a.displayID == CGMainDisplayID() && b.displayID != CGMainDisplayID())
                || (a.displayID != CGMainDisplayID() && b.displayID != CGMainDisplayID() && a.displayID < b.displayID)
        }
    }

    @available(macOS 14.0, *)
    private static func listDisplaysModern() async -> [DisplayInfo] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        ) else { return [] }
        return orderedDisplays(content.displays).enumerated().map { index, display in
            // SCDisplay.width/height 是像素尺寸,frame 是 point 尺寸。
            let scale = display.frame.width > 0
                ? Double(CGFloat(display.width) / display.frame.width)
                : 1
            return DisplayInfo(
                index: index,
                displayID: display.displayID,
                width: Int(display.frame.width.rounded()),
                height: Int(display.frame.height.rounded()),
                scaleFactor: scale,
                isMain: display.displayID == CGMainDisplayID()
            )
        }
    }

    @available(macOS 14.0, *)
    private static func captureImageModern(options: ScreenCaptureOptions) async throws -> CGImage {
        let content = try await shareableContent()
        switch options.source {
        case .mainDisplay:
            let display = try pickDisplay(content.displays, index: options.displayIndex)
            return try await screenshot(filter: SCContentFilter(display: display, excludingWindows: []))
        case .windowID(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw ScreenCaptureError.unableToFindWindow("window-id \(id)")
            }
            return try await screenshot(filter: SCContentFilter(desktopIndependentWindow: window))
        case .windowQuery(let query):
            let normalized = Self.normalize(query)
            guard !normalized.isEmpty else { throw ScreenCaptureError.unableToFindWindow(query) }
            let window = content.windows.first {
                windowMatches(
                    title: $0.title,
                    owner: $0.owningApplication?.applicationName,
                    normalizedQuery: normalized
                )
            }
            guard let window else { throw ScreenCaptureError.unableToFindWindow(query) }
            return try await screenshot(filter: SCContentFilter(desktopIndependentWindow: window))
        case .region(let rect):
            guard rect.width > 0, rect.height > 0 else {
                throw ScreenCaptureError.invalidRegion
            }
            let display = try pickDisplay(content.displays, index: options.displayIndex)
            let full = try await screenshot(filter: SCContentFilter(display: display, excludingWindows: []))
            return try cropRegion(rect, from: full, displayFrame: display.frame)
        }
    }

    @available(macOS 14.0, *)
    private static func pickDisplay(_ displays: [SCDisplay], index: Int) throws -> SCDisplay {
        let ordered = orderedDisplays(displays)
        guard index >= 0, index < ordered.count else {
            throw ScreenCaptureError.displayNotFound(index)
        }
        return ordered[index]
    }

    @available(macOS 14.0, *)
    private static func screenshot(filter: SCContentFilter) async throws -> CGImage {
        let config = SCStreamConfiguration()
        config.showsCursor = false
        // 显式按过滤器的物理像素设置输出尺寸,拿到原生分辨率(默认会缩到 point 尺寸)。
        let contentSize = filter.contentRect.size
        let scale = CGFloat(filter.pointPixelScale)
        if scale > 0, contentSize.width > 0, contentSize.height > 0 {
            config.width = Int((contentSize.width * scale).rounded())
            config.height = Int((contentSize.height * scale).rounded())
        }
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw ScreenCaptureError.captureFailed(error.localizedDescription)
        }
    }

    /// 把左上角原点、point 单位的 region 换算成像素 rect 后从整屏截图里裁出来。
    @available(macOS 14.0, *)
    private static func cropRegion(_ rect: CGRect, from image: CGImage, displayFrame: CGRect) throws -> CGImage {
        let scale = displayFrame.width > 0 ? CGFloat(image.width) / displayFrame.width : 1
        let pixelRect = CGRect(
            x: rect.origin.x * scale,
            y: rect.origin.y * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = pixelRect.intersection(imageBounds).integral
        guard !clipped.isNull, clipped.width > 0.5, clipped.height > 0.5 else {
            throw ScreenCaptureError.invalidRegion
        }
        if abs(clipped.width - pixelRect.width) > 1 || abs(clipped.height - pixelRect.height) > 1 {
            warnRegionClipped(expected: rect, actual: CGSize(
                width: clipped.width / scale,
                height: clipped.height / scale
            ))
        }
        guard let cropped = image.cropping(to: clipped) else {
            throw ScreenCaptureError.invalidRegion
        }
        return cropped
    }
}
