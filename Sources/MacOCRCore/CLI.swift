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

    public var errorDescription: String? {
        switch self {
        case .helpRequested: return nil
        case .versionRequested: return nil
        case .missingImagePath: return "缺少图片路径"
        case .invalidArguments(let message): return message
        case .conflictingOutputModes: return "--json 和 --text 不能同时使用"
        case .conflictingKeywordWithOutput: return "--keyword 与 --output/-o 不能同时使用（关键词模式按行打印，不适合结构化文件）"
        case .invalidRegion(let message): return message
        case .invalidLevel(let value): return "--level 必须是 accurate 或 fast，收到: \(value)"
        }
    }
}

public struct CLIOptions: Equatable, Sendable {
    public let imageURL: URL
    public let languages: [String]
    public let level: VNRequestTextRecognitionLevel
    public let languageCorrection: Bool
    public let outputMode: CLIOutputMode
    public let outputPath: URL?
    public let keyword: String?

    public init(
        imageURL: URL,
        languages: [String],
        level: VNRequestTextRecognitionLevel,
        languageCorrection: Bool,
        outputMode: CLIOutputMode,
        outputPath: URL?,
        keyword: String?
    ) {
        self.imageURL = imageURL
        self.languages = languages
        self.level = level
        self.languageCorrection = languageCorrection
        self.outputMode = outputMode
        self.outputPath = outputPath
        self.keyword = keyword
    }
}

// MARK: - 参数解析

public enum CLIParser {
    public static func parse(_ arguments: [String]) throws -> CLIOptions {
        if arguments.contains("--help") || arguments.contains("-h") {
            throw CLIError.helpRequested
        }
        if arguments.contains("--version") || arguments.contains("-v") {
            throw CLIError.versionRequested
        }

        var imagePath: String?
        var languages: [String] = ["zh-Hans", "en-US"]
        var level: VNRequestTextRecognitionLevel = .accurate
        var languageCorrection = true
        var outputMode: CLIOutputMode = .text
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
                languages = parts

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

            default:
                if argument.hasPrefix("-") {
                    throw CLIError.invalidArguments("不支持的参数: \(argument)")
                }
                guard imagePath == nil else {
                    throw CLIError.invalidArguments("不支持多个位置参数: \(argument)")
                }
                imagePath = argument
            }

            index += 1
        }

        guard let imagePath else { throw CLIError.missingImagePath }

        if keyword != nil, outputPath != nil {
            throw CLIError.conflictingKeywordWithOutput
        }

        return CLIOptions(
            imageURL: URL(fileURLWithPath: imagePath),
            languages: languages,
            level: level,
            languageCorrection: languageCorrection,
            outputMode: outputMode,
            outputPath: outputPath,
            keyword: keyword
        )
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
      mac_ocr_cli <图片路径> [选项]

    选项:
      -l, --lang <list>        识别语言，逗号分隔的 BCP-47 标签
                               (默认: zh-Hans,en-US)
      --level <accurate|fast>  识别等级 (默认: accurate)
      --no-correction          关闭语言自动纠错
      -k, --keyword <kw>       在识别结果里搜索关键词并按相关度排序
      --text                   以纯文本输出 (默认)
      --json                   以 JSON 输出
      -o, --output <path>      把结果写入文件（强制 JSON）
      -v, --version            打印版本
      -h, --help               显示本帮助

    示例:
      mac_ocr_cli photo.png
      mac_ocr_cli shot.jpg -l en-US --level fast --json
      mac_ocr_cli menu.png -k "登录" --json -o result.json
    """

    public static let version = "mac_ocr_cli 1.0.0"
}
