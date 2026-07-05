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
    case stdinRequestedButNoReader
    case stdinEmpty
    case conflictingCaptureModes
    case captureWithImageInput
    case windowListWithOther
    case saveScreenshotWithoutCapture
    case clipboardWithImageInput
    case clipboardAndPasteboard
    case pasteboardWithImageInput
    case pasteboardRequiresClipboard
    case invalidCompressionFormat(String)
    case invalidCompressionQuality(String)
    case compressionOutputInPasteboardMode
    case compressionOutputRequiresDirectory
    case compressionRequiresOCR

    public var errorDescription: String? {
        switch self {
        case .helpRequested: return nil
        case .versionRequested: return nil
        case .missingImagePath: return "缺少图片路径（位置参数、--dir、stdin `-`、--screen/--window/--region、--clipboard、--from-clipboard）"
        case .invalidArguments(let message): return message
        case .conflictingOutputModes: return "--json 和 --text 不能同时使用"
        case .conflictingKeywordWithOutput: return "--keyword 与 --output/-o 不能同时使用（关键词模式按行打印，不适合结构化文件）"
        case .invalidRegion(let message): return message
        case .invalidLevel(let value): return "--level 必须是 accurate 或 fast，收到: \(value)"
        case .conflictingLanguageAndCJK: return "--cjk 与 --lang/-l 不能同时使用"
        case .directoryNotFound(let url): return "目录不存在: \(url.path)"
        case .directoryUnreadable(let url): return "无法读取目录: \(url.path)"
        case .duplicateInput(let path): return "重复的输入: \(path)"
        case .stdinRequestedButNoReader: return "位置参数 `-` 要求从 stdin 读取路径列表，但当前没有可用的 stdin"
        case .stdinEmpty: return "stdin 中没有可读取的路径（每行一个，空行与 # 注释会被跳过）"
        case .conflictingCaptureModes: return "--screen / --window / --window-id / --region 只能选一个"
        case .captureWithImageInput: return "截图模式（--screen/--window/--region）不能与位置参数 / --dir / stdin `-` 同时使用"
        case .windowListWithOther: return "--window-list 不能与任何截图或输入参数同时使用"
        case .saveScreenshotWithoutCapture: return "--save-screenshot 必须与 --screen/--window/--window-id/--region 同时使用"
        case .clipboardWithImageInput: return "--clipboard 是截图模式,不能与位置参数 / --dir / stdin `-` / --from-clipboard 同时使用"
        case .clipboardAndPasteboard: return "--clipboard 与 --from-clipboard 互斥"
        case .pasteboardWithImageInput: return "--from-clipboard 不能与位置参数 / --dir / stdin `-` 同时使用"
        case .pasteboardRequiresClipboard: return "--from-clipboard 必须单独使用，不能与 --screen/--window/--region/--clipboard/--window-list 组合"
        case .invalidCompressionFormat(let value): return "不支持的压缩格式: \(value)（应为 jpeg / webp / heic / png）"
        case .invalidCompressionQuality(let value): return "无效的压缩质量: \(value)（应为 high / medium / low 或 0..1 之间的数字）"
        case .compressionOutputInPasteboardMode: return "--compress-output 不能与 --from-clipboard 同时使用（剪贴板图片没有可推导的文件名）"
        case .compressionOutputRequiresDirectory: return "--compress-output 需要一个已存在的目录路径"
        case .compressionRequiresOCR: return "--compress-input / --compress-output 不能与 --window-list 或 --clipboard 同时使用（这些模式不跑 OCR）"
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
    public let quiet: Bool

    /// 截图模式：非 nil 时由调用方先截图,再把产物作为单文件 OCR 输入。
    public let screenCapture: ScreenCaptureOptions?
    /// 仅列出可见窗口（不跑 OCR）。
    public let windowList: Bool
    /// 截图到剪贴板：非 nil 时调用方先截图并把 PNG 写入 NSPasteboard.general。
    public let clipboardCapture: ScreenCaptureOptions?
    /// 从剪贴板读取图片并 OCR。
    public let pasteboardSource: Bool

    /// OCR 之前把每张输入图重编码成更小/更省内存的格式。非 nil 时启用预处理。
    public let compressionInput: CompressionConfig?
    /// OCR 完成后把每张输入图的压缩副本写到 `compressionOutputDirectory`。
    public let compressionOutput: CompressionConfig?
    public let compressionOutputDirectory: URL?

    public init(
        imageURLs: [URL],
        languages: [String],
        level: VNRequestTextRecognitionLevel,
        languageCorrection: Bool,
        outputMode: CLIOutputMode,
        outputPath: URL?,
        keyword: String?,
        quiet: Bool = false,
        screenCapture: ScreenCaptureOptions? = nil,
        windowList: Bool = false,
        clipboardCapture: ScreenCaptureOptions? = nil,
        pasteboardSource: Bool = false,
        compressionInput: CompressionConfig? = nil,
        compressionOutput: CompressionConfig? = nil,
        compressionOutputDirectory: URL? = nil
    ) {
        self.imageURLs = imageURLs
        self.languages = languages
        self.level = level
        self.languageCorrection = languageCorrection
        self.outputMode = outputMode
        self.outputPath = outputPath
        self.keyword = keyword
        self.quiet = quiet
        self.screenCapture = screenCapture
        self.windowList = windowList
        self.clipboardCapture = clipboardCapture
        self.pasteboardSource = pasteboardSource
        self.compressionInput = compressionInput
        self.compressionOutput = compressionOutput
        self.compressionOutputDirectory = compressionOutputDirectory
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

    /// 共享校验:`--keyword` 与 `--output` 互斥。在 file-input / pasteboard 两个分支都要触发。
    static func validateKeywordOutput(keyword: String?, outputPath: URL?) throws {
        if keyword != nil, outputPath != nil {
            throw CLIError.conflictingKeywordWithOutput
        }
    }

    /// 把 `~` 展开成 `$HOME`。`URL(fileURLWithPath:)` 不做这件事,
    /// 不展开会让 `--output ~/foo.json` 落到字面 `~` 文件名,而不是用户的家目录。
    static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// 把压缩相关的 5 个原始字符串解析成两个 `CompressionConfig`。
    /// - 格式默认 jpeg,质量默认 high。
    /// - 输入/输出都未启用时返回 (nil, nil),节省一次空检查。
    static func resolveCompressionOptions(
        inputRaw: String?, inputFormatRaw: String?,
        outputDir: URL?, outputFormatRaw: String?,
        qualityRaw: String?
    ) throws -> (input: CompressionConfig?, output: CompressionConfig?, outputDir: URL?) {
        let inputFormat = try inputFormatRaw.map { raw -> ImageFormat in
            guard let f = ImageFormat(rawValue: raw.lowercased()) else {
                throw CLIError.invalidCompressionFormat(raw)
            }
            return f
        } ?? .jpeg
        let outputFormat = try outputFormatRaw.map { raw -> ImageFormat in
            guard let f = ImageFormat(rawValue: raw.lowercased()) else {
                throw CLIError.invalidCompressionFormat(raw)
            }
            return f
        } ?? .jpeg

        let inputConfig = try inputRaw.map { raw -> CompressionConfig in
            CompressionConfig(format: inputFormat, quality: try ImageCompressor.resolveQuality(raw))
        }

        let outputConfig: CompressionConfig? = outputDir != nil
            ? CompressionConfig(format: outputFormat, quality: try ImageCompressor.resolveQuality(qualityRaw ?? "high"))
            : nil

        return (inputConfig, outputConfig, outputDir)
    }

    /// 检测值参数 flag 是否重复。重复时抛 `invalidArguments`,
    /// 避免 `-o a.json -o b.json` 这种 last-wins 默默吞掉第一个值。
    static func requireOnce(seen: inout Set<String>, flag: String) throws {
        if !seen.insert(flag).inserted {
            throw CLIError.invalidArguments("重复的参数: \(flag)")
        }
    }

    /// 解析命令行参数。
    /// - Parameter stdinReader: 注入 stdin 读取逻辑（每行一个路径）,
    ///   传入 nil 时若位置参数出现 `-` 会抛 `.stdinRequestedButNoReader`。
    ///   `main.swift` 注入真实 stdin 读取,测试时可注入受控字符串。
    public static func parse(
        _ arguments: [String],
        stdinReader: (() -> String?)? = nil
    ) throws -> CLIOptions {
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
        var quiet = false
        var captureSource: ScreenCaptureOptions.Source?
        var saveScreenshotPath: URL?
        var windowListRequested = false
        var clipboardRequested = false
        var pasteboardRequested = false
        var userSetLang = false

        // 压缩相关原始字符串,在所有分支结束后由 resolveCompressionOptions 统一解析。
        // 拆分输入/输出两个独立的 format 标志,允许两种模式用不同格式。
        var compressionInputRaw: String?
        var compressionInputFormatRaw: String?
        var compressionOutputDir: URL?
        var compressionOutputFormatRaw: String?
        var compressionQualityRaw: String?

        var index = 0
        var seenFlags = Set<String>()
        while index < arguments.count {
            let argument = arguments[index]

            switch argument {
            case "--lang", "-l":
                try Self.requireOnce(seen: &seenFlags, flag: argument)
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
                userSetLang = true

            case "--cjk":
                try Self.requireOnce(seen: &seenFlags, flag: argument)
                if userSetLang { throw CLIError.conflictingLanguageAndCJK }
                languages = cjkLanguages
                cjkPreset = true

            case "--level":
                try Self.requireOnce(seen: &seenFlags, flag: argument)
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
                try Self.requireOnce(seen: &seenFlags, flag: argument)
                languageCorrection = false

            case "--compress-input":
                try Self.requireOnce(seen: &seenFlags, flag: argument)
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("-") else {
                    throw CLIError.invalidArguments("--compress-input 需要一个值: high | medium | low | 0..1")
                }
                compressionInputRaw = arguments[index]

            case "--compress-input-format":
                try Self.requireOnce(seen: &seenFlags, flag: argument)
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArguments("--compress-input-format 需要一个格式: jpeg | webp | heic | png")
                }
                compressionInputFormatRaw = arguments[index]

            case "--compress-output":
                try Self.requireOnce(seen: &seenFlags, flag: argument)
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArguments("--compress-output 需要一个目录路径")
                }
                compressionOutputDir = URL(fileURLWithPath: Self.expandTilde(arguments[index]))

            case "--compress-output-format":
                try Self.requireOnce(seen: &seenFlags, flag: argument)
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArguments("--compress-output-format 需要一个格式: jpeg | webp | heic | png")
                }
                compressionOutputFormatRaw = arguments[index]

            case "--compress-quality":
                try Self.requireOnce(seen: &seenFlags, flag: argument)
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("-") else {
                    throw CLIError.invalidArguments("--compress-quality 需要一个值: high | medium | low | 0..1")
                }
                compressionQualityRaw = arguments[index]

            case "--quiet", "-q":
                try Self.requireOnce(seen: &seenFlags, flag: argument)
                quiet = true

            case "--json":
                try Self.requireOnce(seen: &seenFlags, flag: argument)
                if explicitOutputMode, outputMode != .json { throw CLIError.conflictingOutputModes }
                outputMode = .json
                explicitOutputMode = true

            case "--text":
                try Self.requireOnce(seen: &seenFlags, flag: argument)
                if explicitOutputMode, outputMode != .text { throw CLIError.conflictingOutputModes }
                outputMode = .text
                explicitOutputMode = true

            case "--output", "-o":
                try Self.requireOnce(seen: &seenFlags, flag: argument)
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArguments("--output 需要一个文件路径")
                }
                outputPath = URL(fileURLWithPath: Self.expandTilde(arguments[index]))
                if explicitOutputMode, outputMode != .json { throw CLIError.conflictingOutputModes }
                outputMode = .json
                explicitOutputMode = true

            case "--keyword", "-k":
                try Self.requireOnce(seen: &seenFlags, flag: argument)
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArguments("--keyword 需要一个值")
                }
                keyword = arguments[index]

            case "--dir":
                try Self.requireOnce(seen: &seenFlags, flag: argument)
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArguments("--dir 需要一个目录路径")
                }
                let dirURL = URL(fileURLWithPath: Self.expandTilde(arguments[index]))
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDir) else {
                    throw CLIError.directoryNotFound(dirURL)
                }
                if !isDir.boolValue {
                    throw CLIError.directoryNotFound(dirURL)
                }
                inputDirs.append(dirURL)

            case "--screen":
                try Self.requireOnce(seen: &seenFlags, flag: argument)
                if captureSource != nil { throw CLIError.conflictingCaptureModes }
                captureSource = .mainDisplay

            case "--window":
                try Self.requireOnce(seen: &seenFlags, flag: argument)
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArguments("--window 需要一个窗口标题或应用名称")
                }
                if captureSource != nil { throw CLIError.conflictingCaptureModes }
                captureSource = .windowQuery(arguments[index])

            case "--window-id":
                try Self.requireOnce(seen: &seenFlags, flag: argument)
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArguments("--window-id 需要一个窗口编号")
                }
                guard let parsed = UInt32(arguments[index]), parsed > 0 else {
                    throw CLIError.invalidArguments("--window-id 必须是大于 0 的数字")
                }
                if captureSource != nil { throw CLIError.conflictingCaptureModes }
                captureSource = .windowID(parsed)

            case "--region":
                try Self.requireOnce(seen: &seenFlags, flag: argument)
                guard index + 4 < arguments.count,
                      let x = Double(arguments[index + 1]),
                      let y = Double(arguments[index + 2]),
                      let w = Double(arguments[index + 3]),
                      let h = Double(arguments[index + 4]),
                      x.isFinite, y.isFinite, w.isFinite, h.isFinite,
                      w > 0, h > 0
                else {
                    throw CLIError.invalidRegion("--region 需要 4 个有限的正数: x y width height（不允许 NaN/Infinity）")
                }
                if captureSource != nil { throw CLIError.conflictingCaptureModes }
                captureSource = .region(CGRect(x: x, y: y, width: w, height: h))
                index += 4

            case "--save-screenshot":
                try Self.requireOnce(seen: &seenFlags, flag: argument)
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArguments("--save-screenshot 需要一个值")
                }
                saveScreenshotPath = URL(fileURLWithPath: Self.expandTilde(arguments[index]))

            case "--window-list":
                windowListRequested = true

            case "--clipboard":
                clipboardRequested = true

            case "--from-clipboard":
                pasteboardRequested = true

            default:
                if argument == "-" {
                    // 从 stdin 读取路径列表
                    guard let reader = stdinReader else {
                        throw CLIError.stdinRequestedButNoReader
                    }
                    guard let raw = reader() else {
                        throw CLIError.stdinEmpty
                    }
                    let fromStdin = parseStdinPaths(raw)
                    guard !fromStdin.isEmpty else {
                        throw CLIError.stdinEmpty
                    }
                    imagePaths.append(contentsOf: fromStdin)
                } else if argument.hasPrefix("-") {
                    throw CLIError.invalidArguments("不支持的参数: \(argument)")
                } else {
                    imagePaths.append(argument)
                }
            }

            index += 1
        }

        // 压缩相关校验 + 解析。放在分支分发之前,这样所有 5 个 init 站点都能拿到一致的值。
        // 顺序:先做格式/质量合法性,再做跨模式的互斥检查。
        let (compressionInputConfig, compressionOutputConfig, compressionOutputDirResolved) =
            try Self.resolveCompressionOptions(
                inputRaw: compressionInputRaw,
                inputFormatRaw: compressionInputFormatRaw,
                outputDir: compressionOutputDir,
                outputFormatRaw: compressionOutputFormatRaw,
                qualityRaw: compressionQualityRaw
            )
        if compressionInputConfig != nil || compressionOutputConfig != nil {
            if windowListRequested || clipboardRequested {
                throw CLIError.compressionRequiresOCR
            }
        }
        if compressionOutputDir != nil, pasteboardRequested {
            throw CLIError.compressionOutputInPasteboardMode
        }
        if let outDir = compressionOutputDir {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: outDir.path, isDirectory: &isDir),
                  isDir.boolValue else {
                throw CLIError.compressionOutputRequiresDirectory
            }
        }

        // 模式互斥：--window-list / --clipboard / 截图(--screen/--window/--window-id/--region)
        //          / --from-clipboard / 文件输入(位置参数/--dir/stdin `-`)

        if windowListRequested {
            if captureSource != nil || saveScreenshotPath != nil
                || clipboardRequested || pasteboardRequested
                || !imagePaths.isEmpty || !inputDirs.isEmpty {
                throw CLIError.windowListWithOther
            }
            if keyword != nil {
                throw CLIError.invalidArguments("--keyword 不能与 --window-list 同时使用")
            }
            if outputPath != nil { outputMode = .json }
            return CLIOptions(
                imageURLs: [],
                languages: languages,
                level: level,
                languageCorrection: languageCorrection,
                outputMode: outputMode,
                outputPath: outputPath,
                keyword: nil,
                quiet: quiet,
                screenCapture: nil,
                windowList: true,
                compressionInput: compressionInputConfig,
                compressionOutput: compressionOutputConfig,
                compressionOutputDirectory: compressionOutputDirResolved
            )
        }

        if clipboardRequested {
            if pasteboardRequested { throw CLIError.clipboardAndPasteboard }
            if !imagePaths.isEmpty || !inputDirs.isEmpty { throw CLIError.clipboardWithImageInput }
            if keyword != nil {
                throw CLIError.invalidArguments("--keyword 不能与 --clipboard 同时使用")
            }
            if captureSource == nil {
                captureSource = .mainDisplay
            }
            if outputPath != nil { outputMode = .json }
            return CLIOptions(
                imageURLs: [],
                languages: languages,
                level: level,
                languageCorrection: languageCorrection,
                outputMode: outputMode,
                outputPath: outputPath,
                keyword: nil,
                quiet: quiet,
                screenCapture: nil,
                windowList: false,
                clipboardCapture: ScreenCaptureOptions(
                    source: captureSource ?? .mainDisplay,
                    savePath: saveScreenshotPath
                ),
                pasteboardSource: false,
                compressionInput: compressionInputConfig,
                compressionOutput: compressionOutputConfig,
                compressionOutputDirectory: compressionOutputDirResolved
            )
        }

        if pasteboardRequested {
            if captureSource != nil || saveScreenshotPath != nil {
                throw CLIError.pasteboardRequiresClipboard
            }
            if !imagePaths.isEmpty || !inputDirs.isEmpty {
                throw CLIError.pasteboardWithImageInput
            }
            try Self.validateKeywordOutput(keyword: keyword, outputPath: outputPath)
            if keyword == nil, outputPath != nil { outputMode = .json }
            return CLIOptions(
                imageURLs: [],
                languages: languages,
                level: level,
                languageCorrection: languageCorrection,
                outputMode: outputMode,
                outputPath: outputPath,
                keyword: keyword,
                quiet: quiet,
                screenCapture: nil,
                windowList: false,
                clipboardCapture: nil,
                pasteboardSource: true,
                compressionInput: compressionInputConfig,
                compressionOutput: compressionOutputConfig,
                compressionOutputDirectory: compressionOutputDirResolved
            )
        }

        if let source = captureSource {
            if !imagePaths.isEmpty || !inputDirs.isEmpty {
                throw CLIError.captureWithImageInput
            }
            if keyword != nil {
                throw CLIError.invalidArguments("--keyword 不能与截图模式同时使用")
            }
            if outputPath != nil {
                outputMode = .json
            }
            return CLIOptions(
                imageURLs: [],
                languages: languages,
                level: level,
                languageCorrection: languageCorrection,
                outputMode: outputMode,
                outputPath: outputPath,
                keyword: nil,
                quiet: quiet,
                screenCapture: ScreenCaptureOptions(source: source, savePath: saveScreenshotPath),
                windowList: false,
                compressionInput: compressionInputConfig,
                compressionOutput: compressionOutputConfig,
                compressionOutputDirectory: compressionOutputDirResolved
            )
        }

        // 文件输入分支
        if saveScreenshotPath != nil {
            throw CLIError.saveScreenshotWithoutCapture
        }
        guard !imagePaths.isEmpty || !inputDirs.isEmpty else { throw CLIError.missingImagePath }

        try Self.validateKeywordOutput(keyword: keyword, outputPath: outputPath)

        // 合并位置参数和 --dir 扫描结果;按出现顺序去重。
        var seen = Set<String>()
        var urls: [URL] = []
        for raw in imagePaths {
            let url = URL(fileURLWithPath: Self.expandTilde(raw)).standardizedFileURL
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

        // F3 + F4: 批量 keyword 与空 --dir 都是用户意图不明的状态,显式报错。
        if !urls.isEmpty, urls.count > 1, keyword != nil {
            throw CLIError.invalidArguments("--keyword 仅在单文件模式生效（批量请先筛选路径）")
        }
        if urls.isEmpty, !inputDirs.isEmpty {
            throw CLIError.invalidArguments("--dir 指定的目录中没有受支持的图片")
        }

        return CLIOptions(
            imageURLs: urls,
            languages: languages,
            level: level,
            languageCorrection: languageCorrection,
            outputMode: outputMode,
            outputPath: outputPath,
            keyword: keyword,
                quiet: quiet,
            screenCapture: nil,
            windowList: false,
            clipboardCapture: nil,
            pasteboardSource: false,
            compressionInput: compressionInputConfig,
            compressionOutput: compressionOutputConfig,
            compressionOutputDirectory: compressionOutputDirResolved
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

    /// 把 stdin 文本拆成路径列表。规则:
    /// - 一行一个,自动 trim 空白
    /// - 空行与以 `#` 开头的行作为注释跳过
    /// - 不做去重(去重由上层统一处理,避免与位置参数合并时漏报重复)
    static func parseStdinPaths(_ raw: String) -> [String] {
        raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
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
      mac_ocr_cli <图片路径>... [选项]                 # 文件输入
      mac_ocr_cli --dir <目录> [选项]
      find . -name "*.png" | mac_ocr_cli - [选项]      # stdin
      mac_ocr_cli --screen [选项]                       # 截主屏幕 + OCR
      mac_ocr_cli --window <查询> [选项]                # 截匹配窗口
      mac_ocr_cli --window-id <id> [选项]
      mac_ocr_cli --region x y w h [选项]               # 截屏幕区域
      mac_ocr_cli --clipboard [--screen|--window|--window-id|--region]  # 截图到剪贴板
      mac_ocr_cli --from-clipboard [选项]               # 识别剪贴板里的图片
      mac_ocr_cli --window-list                         # 列出可见窗口

    输入源（仅可选其一,不可叠加）:
      <位置参数>...          一张或多张图片路径
      --dir <目录>           递归扫描目录中的图片
      -                      从 stdin 读路径列表（每行一个，# 开头是注释）
      --screen/--window/--window-id/--region  截图后直接 OCR
      --clipboard            截图后写入剪贴板（不跑 OCR）
      --from-clipboard       从剪贴板读取图片并 OCR

    选项:
      -l, --lang <list>        识别语言，逗号分隔的 BCP-47 标签
                               (默认: zh-Hans,zh-Hant,en-US)
      --cjk                    切换到 CJK 预设 (zh-Hans,zh-Hant,zh-HK,en-US)
                               与 --lang 互斥
      --level <accurate|fast>  识别等级 (默认: accurate)
      --no-correction          关闭语言自动纠错
      -k, --keyword <kw>       在识别结果里搜索关键词（单文件模式）
      --save-screenshot <p>    把截图另存到 p(--clipboard 时也支持)
      -q, --quiet              抑制 stdout 报告和 stderr 进度；错误仍到 stderr
      --text                   以纯文本输出 (默认)
      --json                   以 JSON 输出
      -o, --output <path>      把结果写入文件（强制 JSON）
      --compress-input <high|medium|low|0..1>
                               OCR 之前把图压缩成更小格式再识别
                               (节省内存/加速批量)
      --compress-input-format <jpeg|webp|heic|png>
                               预处理输出格式 (默认 jpeg)
      --compress-output <dir>  OCR 完成后把每张输入图的压缩副本写到 dir
      --compress-output-format <jpeg|webp|heic|png>
                               输出副本格式 (默认 jpeg)
      --compress-quality <high|medium|low|0..1>
                               覆盖两个模式的默认质量 (默认 high)
      -v, --version            打印版本
      -h, --help               显示本帮助

    注意:
      截图功能需要「屏幕录制」权限 (系统设置 → 隐私与安全性)。
      首次运行会被提示授权,或手动在隐私设置中允许本程序。
      剪贴板读写无需额外权限。

    示例:
      mac_ocr_cli photo.png
      mac_ocr_cli --dir ./shots --json -o result.json
      find . -name "*.png" | mac_ocr_cli - --json -o all.json
      mac_ocr_cli --screen --cjk
      mac_ocr_cli --window "Safari" --save-screenshot ~/shot.png
      mac_ocr_cli --region 0 0 800 600
      mac_ocr_cli --window-list
      # 截主屏幕到剪贴板,粘到 Slack / 微信 直接用
      mac_ocr_cli --clipboard
      # 系统自带截图快捷键 Cmd+Shift+Ctrl+4 截到剪贴板后,识别内容
      mac_ocr_cli --from-clipboard
      # 批量 OCR + 压缩副本(默认 JPEG high)
      mac_ocr_cli --dir ./shots --compress-output ~/compressed
      # 高压缩比预处理(快 3-5x,适合大截图)
      mac_ocr_cli photo.png --compress-input 0.5
    """

    public static let version = "mac_ocr_cli 1.1.0"
}
