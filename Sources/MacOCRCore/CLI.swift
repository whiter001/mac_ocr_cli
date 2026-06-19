import Foundation
import Vision

// MARK: - 公共 CLI 模型

public enum CLIOutputMode: String, Sendable {
    case text
    case json
}

public enum CLIError: Error, LocalizedError, Equatable {
    case helpRequested
    case versionRequested
    case missingImagePath
    case invalidArguments(String)
    case conflictingOutputModes
    case conflictingKeywordWithOutput
    case invalidRegion(String)
    case invalidLevel(String)
    case conflictingLanguageAndCJK
    case directoryNotFound(URL)
    case directoryUnreadable(URL)
    case duplicateInput(String)

    public var errorDescription: String? {
        switch self {
        case .helpRequested: return nil
        case .versionRequested: return nil
        case .missingImagePath: return "缺少图片路径（位置参数或 --dir）"
        case .invalidArguments(let message): return message
        case .conflictingOutputModes: return "--json 和 --text 不能同时使用"
        case .conflictingKeywordWithOutput: return "--keyword 与 --output/-o 不能同时使用（关键词模式按行打印，不适合结构化文件）"
        case .invalidRegion(let message): return message
        case .invalidLevel(let value): return "--level 必须是 accurate 或 fast，收到: \(value)"
        case .conflictingLanguageAndCJK: return "--cjk 与 --lang/-l 不能同时使用"
        case .directoryNotFound(let url): return "目录不存在: \(url.path)"
        case .directoryUnreadable(let url): return "无法读取目录: \(url.path)"
        case .duplicateInput(let path): return "重复的输入: \(path)"
        }
    }
}

public struct CLIOptions: Equatable, Sendable {
    public let imageURLs: [URL]
    public let languages: [String]
    public let level: VNRequestTextRecognitionLevel
    public let languageCorrection: Bool
    public let outputMode: CLIOutputMode
    public let outputPath: URL?
    public let keyword: String?

    public init(
        imageURLs: [URL],
        languages: [String],
        level: VNRequestTextRecognitionLevel,
        languageCorrection: Bool,
        outputMode: CLIOutputMode,
        outputPath: URL?,
        keyword: String?
    ) {
        self.imageURLs = imageURLs
        self.languages = languages
        self.level = level
        self.languageCorrection = languageCorrection
        self.outputMode = outputMode
        self.outputPath = outputPath
        self.keyword = keyword
    }

    /// 单文件输入（向后兼容入口）
    public var isSingleImage: Bool { imageURLs.count == 1 }
}

// MARK: - 参数解析

public enum CLIParser {
    /// 兜底识别集：简体 / 繁体 / 英文。Vision 会按图片内容自动挑选最合适的，
    /// 列出多个候选几乎不增加耗时,但能避免混合语种截图里漏识别。
    public static let defaultLanguages: [String] = ["zh-Hans", "zh-Hant", "en-US"]

    /// `--cjk` 预设：增加粤语（香港书面语）以覆盖港版 UI。
    public static let cjkLanguages: [String] = ["zh-Hans", "zh-Hant", "zh-HK", "en-US"]

    public static func parse(_ arguments: [String]) throws -> CLIOptions {
        if arguments.contains("--help") || arguments.contains("-h") {
            throw CLIError.helpRequested
        }
        if arguments.contains("--version") || arguments.contains("-v") {
            throw CLIError.versionRequested
        }

        var imagePaths: [String] = []
        var inputDirs: [URL] = []
        var languages: [String] = defaultLanguages
        var level: VNRequestTextRecognitionLevel = .accurate
        var languageCorrection = true
        var outputMode: CLIOutputMode = .text
        var cjkPreset = false
        var explicitOutputMode = false
        var outputPath: URL?
        var keyword: String?

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]

            switch argument {
            case "--lang", "-l":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArguments("--lang 需要一个值（逗号分隔的 BCP-47 标签）")
                }
                let parts = arguments[index]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                guard !parts.isEmpty else {
                    throw CLIError.invalidArguments("--lang 至少需要一种语言")
                }
                if cjkPreset { throw CLIError.conflictingLanguageAndCJK }
                languages = parts

            case "--cjk":
                if cjkPreset == false, languages != defaultLanguages {
                    // 用户已经显式设置了 --lang
                    throw CLIError.conflictingLanguageAndCJK
                }
                languages = cjkLanguages
                cjkPreset = true

            case "--level":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArguments("--level 需要一个值: accurate 或 fast")
                }
                switch arguments[index].lowercased() {
                case "accurate": level = .accurate
                case "fast": level = .fast
                default: throw CLIError.invalidLevel(arguments[index])
                }

            case "--no-correction":
                languageCorrection = false

            case "--json":
                if explicitOutputMode, outputMode != .json { throw CLIError.conflictingOutputModes }
                outputMode = .json
                explicitOutputMode = true

            case "--text":
                if explicitOutputMode, outputMode != .text { throw CLIError.conflictingOutputModes }
                outputMode = .text
                explicitOutputMode = true

            case "--output", "-o":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArguments("--output 需要一个文件路径")
                }
                outputPath = URL(fileURLWithPath: arguments[index])
                if explicitOutputMode, outputMode != .json { throw CLIError.conflictingOutputModes }
                outputMode = .json
                explicitOutputMode = true

            case "--keyword", "-k":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArguments("--keyword 需要一个值")
                }
                keyword = arguments[index]

            case "--dir":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArguments("--dir 需要一个目录路径")
                }
                let dirURL = URL(fileURLWithPath: arguments[index])
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDir) else {
                    throw CLIError.directoryNotFound(dirURL)
                }
                if !isDir.boolValue {
                    throw CLIError.directoryNotFound(dirURL)
                }
                inputDirs.append(dirURL)

            default:
                if argument.hasPrefix("-") {
                    throw CLIError.invalidArguments("不支持的参数: \(argument)")
                }
                imagePaths.append(argument)
            }

            index += 1
        }

        guard !imagePaths.isEmpty || !inputDirs.isEmpty else { throw CLIError.missingImagePath }

        if keyword != nil, outputPath != nil {
            throw CLIError.conflictingKeywordWithOutput
        }

        // 合并位置参数和 --dir 扫描结果；按出现顺序去重。
        var seen = Set<String>()
        var urls: [URL] = []
        for raw in imagePaths {
            let url = URL(fileURLWithPath: raw).standardizedFileURL
            let key = url.path
            if seen.insert(key).inserted {
                urls.append(url)
            } else {
                throw CLIError.duplicateInput(key)
            }
        }
        for dir in inputDirs {
            let scanned = try Self.scanDirectory(dir)
            for url in scanned {
                let key = url.path
                if seen.insert(key).inserted {
                    urls.append(url)
                }
            }
        }

        return CLIOptions(
            imageURLs: urls,
            languages: languages,
            level: level,
            languageCorrection: languageCorrection,
            outputMode: outputMode,
            outputPath: outputPath,
            keyword: keyword
        )
    }

    /// ImageIO 支持的扩展名（小写、含 `.`）。
    public static let supportedExtensions: Set<String> = [
        ".png", ".jpg", ".jpeg", ".heic", ".heif", ".tiff", ".tif",
        ".gif", ".webp", ".bmp", ".pdf", ".ico", ".icns"
    ]

    /// 递归扫描目录,返回按相对路径排序的图片 URL。
    public static func scanDirectory(_ dir: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw CLIError.directoryUnreadable(dir)
        }

        var found: [(relative: String, url: URL)] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard supportedExtensions.contains(".\(ext)") || supportedExtensions.contains(ext) else { continue }
            let rel = relativize(url: url, base: dir)
            found.append((rel, url))
        }
        found.sort { $0.relative.localizedStandardCompare($1.relative) == .orderedAscending }
        return found.map(\.url)
    }

    private static func relativize(url: URL, base: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(basePath + "/") {
            return String(path.dropFirst(basePath.count + 1))
        }
        return path
    }
}

// MARK: - 输出渲染

public enum CLIOutputRenderer {
    public static func renderText(report: OCRReport, options: CLIOptions) -> String {
        var lines: [String] = []
        lines.append("图片: \(report.imagePath)")
        lines.append("识别行数: \(report.lines.count)")

        if let keyword = options.keyword {
            let scored = report.lines
                .enumerated()
                .map { (idx, line) -> (Int, OCRTextLine, Double) in
                    (idx, line, score(line: line, keyword: keyword))
                }
                .filter { $0.2 > 0 }
                .sorted { $0.2 > $1.2 }

            lines.append("关键词: \(keyword)")
            if scored.isEmpty {
                lines.append("命中: 无")
            } else {
                lines.append("命中（按相关度排序）:")
                for (idx, line, s) in scored {
                    let preview = line.text.replacingOccurrences(of: "\n", with: " ")
                    lines.append(String(format: "- [%d] %.2f  %@", idx, s, preview))
                }
            }
            return lines.joined(separator: "\n")
        }

        lines.append("结果:")
        for line in report.lines {
            let preview = line.text.replacingOccurrences(of: "\n", with: " ")
            lines.append(String(
                format: "- [%d] conf=%.2f box=(%.2f,%.2f,%.2f,%.2f)  %@",
                line.index,
                line.confidence,
                line.boundingBox.x,
                line.boundingBox.y,
                line.boundingBox.width,
                line.boundingBox.height,
                preview
            ))
        }
        return lines.joined(separator: "\n")
    }

    public static func renderJSON(report: OCRReport) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        return String(decoding: data, as: UTF8.self)
    }

    public static func renderBatchText(batch: OCRBatchReport) -> String {
        var out: [String] = []
        out.append("批量识别: 共 \(batch.items.count) 个 (成功 \(batch.successCount), 失败 \(batch.failureCount))")
        for (i, item) in batch.items.enumerated() {
            out.append("")
            out.append("===== [\(i + 1)/\(batch.items.count)] \(item.imagePath) =====")
            switch item.status {
            case .ok:
                let lines = item.lines ?? []
                out.append("识别行数: \(lines.count)")
                for line in lines {
                    let preview = line.text.replacingOccurrences(of: "\n", with: " ")
                    out.append(String(
                        format: "- [%d] conf=%.2f box=(%.2f,%.2f,%.2f,%.2f)  %@",
                        line.index,
                        line.confidence,
                        line.boundingBox.x,
                        line.boundingBox.y,
                        line.boundingBox.width,
                        line.boundingBox.height,
                        preview
                    ))
                }
            case .failed:
                out.append("失败: \(item.errorMessage ?? "未知错误")")
            }
        }
        return out.joined(separator: "\n")
    }

    public static func renderBatchJSON(batch: OCRBatchReport) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(batch)
        return String(decoding: data, as: UTF8.self)
    }

    /// 简单的子串匹配打分：完全相等 1.0，标准化包含 0.9，否则 0。
    /// （`localizedStandardContains` 本身就处理大小写和区域设置，所以不需要独立的大小写分支。）
    static func score(line: OCRTextLine, keyword: String) -> Double {
        if line.text == keyword { return 1.0 }
        if line.text.localizedStandardContains(keyword) { return 0.9 }
        return 0
    }
}

// MARK: - 使用说明

public enum CLIPrinter {
    public static let usage = """
    mac_ocr_cli — 基于 Apple Vision 的命令行 OCR 工具

    用法:
      mac_ocr_cli <图片路径>... [选项]
      mac_ocr_cli --dir <目录> [选项]

    选项:
      -l, --lang <list>        识别语言，逗号分隔的 BCP-47 标签
                               (默认: zh-Hans,zh-Hant,en-US)
      --cjk                    切换到 CJK 预设 (zh-Hans,zh-Hant,zh-HK,en-US)
                               与 --lang 互斥
      --level <accurate|fast>  识别等级 (默认: accurate)
      --no-correction          关闭语言自动纠错
      --dir <目录>             递归扫描目录中的图片（可与位置参数叠加）
      -k, --keyword <kw>       在识别结果里搜索关键词（单文件模式）
      --text                   以纯文本输出 (默认)
      --json                   以 JSON 输出
      -o, --output <path>      把结果写入文件（强制 JSON）
      -v, --version            打印版本
      -h, --help               显示本帮助

    示例:
      mac_ocr_cli photo.png
      mac_ocr_cli shot.jpg -l en-US --level fast --json
      mac_ocr_cli *.png --cjk
      mac_ocr_cli --dir ./shots --json -o result.json
    """

    public static let version = "mac_ocr_cli 1.0.0"
}
