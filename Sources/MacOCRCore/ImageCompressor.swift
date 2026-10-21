import Foundation
import CoreGraphics
import Darwin
import ImageIO
import UniformTypeIdentifiers

// MARK: - 公共模型

/// 压缩输出格式。`png` 是无损(忽略 quality 参数),
/// `jpeg` / `webp` / `heic` 是有损。
public enum ImageFormat: String, CaseIterable, Sendable {
    case jpeg
    case webp
    case heic
    case png
}

/// 高/中/低三档预设,转成数字质量:
/// - `high`   → 0.85 (OCR 仍能清晰识别,体积约为原 PNG 的 20-40%)
/// - `medium` → 0.70 (肉眼几乎无差别,体积约为 10-25%)
/// - `low`    → 0.50 (明显压缩痕迹,但 OCR 对中英文字符仍可用)
public enum QualityPreset: String, CaseIterable, Sendable {
    case high
    case medium
    case low

    /// 预设 → 数字质量 (0.0 - 1.0)。PNG 模式下仍返回这个值,
    /// 但 `ImageCompressor.encode` 在 PNG 路径下会忽略它。
    public var numericDefault: Double {
        switch self {
        case .high:   return 0.85
        case .medium: return 0.70
        case .low:    return 0.50
        }
    }
}

/// 已解析的压缩配置,parser 把原始字符串解析完后传入。
/// `quality` 是 0..1 的 Double,`png` 模式下会被忽略。
public struct CompressionConfig: Equatable, Sendable {
    public let format: ImageFormat
    public let quality: Double

    public init(format: ImageFormat, quality: Double) {
        self.format = format
        self.quality = quality
    }
}

public enum ImageCompressorError: Error, LocalizedError {
    case encodingFailed(URL, String)
    case directoryCreationFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed(let url, let reason):
            return "图片编码失败 (\(url.path)): \(reason)"
        case .directoryCreationFailed(let url):
            return "无法创建目录: \(url.path)"
        }
    }
}

// MARK: - 编码器

public enum ImageCompressor {

    /// 把 `high` / `medium` / `low` / 数字 0..1 解析成 `Double`。
    /// - 预设走预设表(`QualityPreset.numericDefault`)。
    /// - 数字必须是有限的且在 [0, 1] 区间内,否则抛 `.invalidCompressionQuality`。
    /// - PNG 路径下这个值会被忽略,仍返回数字本身(便于上层统一处理)。
    public static func resolveQuality(_ raw: String) throws -> Double {
        let lower = raw.lowercased()
        if let preset = QualityPreset(rawValue: lower) {
            return preset.numericDefault
        }
        guard let d = Double(lower), d.isFinite, d >= 0, d <= 1 else {
            throw CLIError.invalidCompressionQuality(raw)
        }
        return d
    }

    /// 文件扩展名(小写,不含 `.`)。
    public static func fileExtension(for format: ImageFormat) -> String {
        switch format {
        case .jpeg: return "jpg"
        case .webp: return "webp"
        case .heic: return "heic"
        case .png:  return "png"
        }
    }

    /// UTI 字符串,传给 `CGImageDestinationCreateWithURL`。
    /// `UTType.webP` 是 macOS 14+,在 macOS 13 上回落到字符串字面量。
    public static func utType(for format: ImageFormat) -> CFString {
        switch format {
        case .jpeg:
            return UTType.jpeg.identifier as CFString
        case .webp:
            if #available(macOS 14, *) {
                return UTType.webP.identifier as CFString
            } else {
                return "org.webmproject.webp" as CFString
            }
        case .heic:
            return UTType.heic.identifier as CFString
        case .png:
            return UTType.png.identifier as CFString
        }
    }

    /// 把 `CGImage` 按指定格式/质量写到磁盘。会覆盖已存在文件,会自动创建父目录。
    /// PNG 路径下 `quality` 被忽略(走无损)。
    /// 先写同目录临时文件再原子 `rename` 覆盖目标:中途失败不会留下半截文件,
    /// 同名并发写也不会互相删掉对方的文件。
    public static func encode(
        _ image: CGImage,
        to url: URL,
        format: ImageFormat,
        quality: Double
    ) throws {
        let parent = url.deletingLastPathComponent()
        // createDirectory 在目录已存在时不会报错,符合"幂等创建"语义。
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw ImageCompressorError.directoryCreationFailed(parent)
        }

        let tempURL = parent
            .appendingPathComponent(".mac_ocr_cli-tmp-\(UUID().uuidString)")
            .appendingPathExtension(Self.fileExtension(for: format))
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let dest = CGImageDestinationCreateWithURL(
            tempURL as CFURL,
            Self.utType(for: format),
            1,
            nil
        ) else {
            throw ImageCompressorError.encodingFailed(url, "无法创建 ImageIO destination")
        }

        let effectiveQuality = Self.effectiveQuality(for: format, requested: quality)
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: effectiveQuality
        ]

        CGImageDestinationAddImage(dest, image, props as CFDictionary)

        guard CGImageDestinationFinalize(dest) else {
            throw ImageCompressorError.encodingFailed(url, "CGImageDestinationFinalize 返回 false")
        }

        // rename(2) 原子替换:目标已存在时直接覆盖,不存在"先删后写"的空窗。
        guard rename(tempURL.path, url.path) == 0 else {
            throw ImageCompressorError.encodingFailed(
                url,
                "无法写入目标文件 (\(String(cString: strerror(errno))))"
            )
        }
    }

    /// 内存里的压缩 round-trip:把 `CGImage` 按指定格式/质量重新编码,再解码回新的 `CGImage`。
    /// 用于 OCR 预处理路径——避免临时文件 I/O 和二次解码原文件。
    /// PNG 路径下 `quality` 被忽略。
    public static func compress(
        _ image: CGImage,
        format: ImageFormat,
        quality: Double
    ) throws -> CGImage {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData,
            Self.utType(for: format),
            1,
            nil
        ) else {
            throw ImageCompressorError.encodingFailed(
                URL(fileURLWithPath: "/in-memory"),
                "无法创建内存 ImageIO destination"
            )
        }

        let effectiveQuality = Self.effectiveQuality(for: format, requested: quality)
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: effectiveQuality
        ]

        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ImageCompressorError.encodingFailed(
                URL(fileURLWithPath: "/in-memory"),
                "CGImageDestinationFinalize 返回 false"
            )
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let result = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageCompressorError.encodingFailed(
                URL(fileURLWithPath: "/in-memory"),
                "压缩后重新解码失败"
            )
        }
        return result
    }

    /// PNG 是无损格式,ImageIO 的 quality 参数对它无效。统一通过这个 helper 返回 effective 值。
    private static func effectiveQuality(for format: ImageFormat, requested: Double) -> Double {
        format == .png ? 1.0 : requested
    }
}