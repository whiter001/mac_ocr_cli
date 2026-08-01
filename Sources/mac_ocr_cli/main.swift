import CoreGraphics
import Darwin
import Foundation
import MacOCRCore

@main
struct MacOCRCLI {
    /// 批量模式默认并发上限。Vision 在不同请求间是线程安全的,
    /// 但单张图片里 OCR 本身是串行的(没有跨核加速),
    /// 所以 N 个 worker ≈ 4x 单张速度,再往上收益递减。可用 `--concurrency` 覆盖。
    static let defaultMaxConcurrentImages = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))

    static func main() async {
        do {
            let options = try CLIParser.parse(
                Array(CommandLine.arguments.dropFirst()),
                stdinReader: { Self.readStdin() }
            )

            if options.windowList {
                try runWindowList(options: options)
                return
            }
            if options.displayList {
                try await runDisplayList(options: options)
                return
            }
            if options.langList {
                try runLangList(options: options)
                return
            }
            if let capture = options.clipboardCapture {
                try await runClipboardCapture(options: options, capture: capture)
                return
            }
            if options.pasteboardSource {
                try await runPasteboardOCR(options: options)
                return
            }
            if options.stdinImage {
                try await runStdinImageOCR(options: options)
                return
            }
            if let capture = options.screenCapture {
                try await runCaptureThenOCR(options: options, capture: capture)
                return
            }

            // 文件输入:PDF 在这里展开成逐页工作项。
            let items = expandInputs(options.imageURLs)
            if options.barcodeMode {
                try await runBarcode(options: options, items: items)
                return
            }
            try await runFileOCR(options: options, items: items)
        } catch let error as CLIError where error == .helpRequested {
            print(CLIPrinter.usage)
            exit(0)
        } catch let error as CLIError where error == .versionRequested {
            print(CLIPrinter.version)
            exit(0)
        } catch {
            fputs("错误: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    // MARK: - 输入模型

    /// 单个待处理输入。普通图片 page == nil;PDF 每页一项,displayPath 带 `#page=N`。
    struct InputItem {
        let url: URL
        let page: Int?
        let displayPath: String
    }

    /// 把文件 URL 列表展开成工作项:多页 PDF 一页一项(批量语义),
    /// 单页 PDF 保持原有单文件语义(displayPath 不带页码后缀)。
    static func expandInputs(_ urls: [URL]) -> [InputItem] {
        urls.flatMap { url -> [InputItem] in
            guard url.pathExtension.lowercased() == "pdf" else {
                return [InputItem(url: url, page: nil, displayPath: url.path)]
            }
            let pages = PDFImageLoader.pageCount(of: url)
            guard pages > 0 else {
                // 打不开/非 PDF:按普通输入走,让下游给出统一的解码错误。
                return [InputItem(url: url, page: nil, displayPath: url.path)]
            }
            if pages == 1 {
                return [InputItem(url: url, page: 0, displayPath: url.path)]
            }
            return (0..<pages).map {
                InputItem(url: url, page: $0, displayPath: "\(url.path)#page=\($0 + 1)")
            }
        }
    }

    /// 加载一个工作项为 CGImage。PDF 页走 PDFKit 渲染(默认 2x),
    /// 普通图片走 ImageIO(带解码期降采样)。
    static func loadImage(for item: InputItem, maxDimension: Int?) throws -> CGImage {
        if let page = item.page {
            return try PDFImageLoader.renderPage(of: item.url, page: page)
        }
        return try ImageLoader.loadCGImage(from: item.url, maxPixelSize: maxDimension)
    }

    // MARK: - 窗口 / 显示器 / 语言列表(不跑 OCR)

    private static func runWindowList(options: CLIOptions) throws {
        let windows = ScreenCapture.listVisibleWindows()
        let payload: String
        switch options.outputMode {
        case .text, .plain:
            payload = renderWindowListText(windows: windows)
        case .json:
            let env = WindowListEnvelope(windows: windows)
            payload = try Self.encodeJSON(env)
        }
        try emit(payload, to: options.outputPath, quiet: options.quiet)
    }

    private static func runDisplayList(options: CLIOptions) async throws {
        let displays = await ScreenCapture.listDisplays()
        let payload: String
        switch options.outputMode {
        case .text, .plain:
            payload = renderDisplayListText(displays: displays)
        case .json:
            let env = DisplayListEnvelope(displays: displays)
            payload = try Self.encodeJSON(env)
        }
        try emit(payload, to: options.outputPath, quiet: options.quiet)
    }

    private static func runLangList(options: CLIOptions) throws {
        let languages = VisionOCRRecognizer.supportedLanguages(level: options.level)
        let payload: String
        switch options.outputMode {
        case .text, .plain:
            if languages.isEmpty {
                payload = "（无法获取支持语言列表）"
            } else {
                let levelName = options.level == .fast ? "fast" : "accurate"
                var out = ["识别等级: \(levelName)", "支持语言 (\(languages.count)):"]
                out.append(contentsOf: languages.map { "  \($0)" })
                payload = out.joined(separator: "\n")
            }
        case .json:
            let env = LangListEnvelope(
                level: options.level == .fast ? "fast" : "accurate",
                languages: languages
            )
            payload = try Self.encodeJSON(env)
        }
        try emit(payload, to: options.outputPath, quiet: options.quiet)
    }

    // MARK: - 截图 + OCR

    private static func runCaptureThenOCR(options: CLIOptions, capture: ScreenCaptureOptions) async throws {
        // 全程内存:截图直接得 CGImage,不再写临时 PNG 再解码。
        let cg = try await ScreenCapture.captureImage(options: capture)
        if let savePath = capture.savePath {
            try FileManager.default.createDirectory(
                at: savePath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try ScreenCapture.writePNG(image: cg, to: savePath)
            if !options.quiet {
                fputs("截图已保存: \(savePath.path)\n", stderr)
            }
        }

        let recognizer = makeRecognizer(options: options)
        let displayPath = capture.savePath?.path ?? "<screen>"
        let result = try await processCGImage(
            cg,
            displayPath: displayPath,
            with: recognizer,
            options: options
        )
        reportSavedCopy(result.savedURL, quiet: options.quiet)

        let report = OCRReport(
            imagePath: displayPath,
            lines: result.lines,
            imageWidth: cg.width,
            imageHeight: cg.height,
            durationMilliseconds: result.durationMilliseconds
        )
        try emit(try renderReport(report, options: options), to: options.outputPath, quiet: options.quiet)
        try copyTextToClipboardIfRequested(result.lines, options: options)
    }

    // MARK: - 文件 OCR(单文件/批量)

    private static func runFileOCR(options: CLIOptions, items: [InputItem]) async throws {
        if items.count == 1 {
            try await runSingleFile(options: options, item: items[0])
        } else {
            try await runBatchFiles(options: options, items: items)
        }
    }

    private static func runSingleFile(options: CLIOptions, item: InputItem) async throws {
        let recognizer = makeRecognizer(options: options)
        let cg = try loadImage(for: item, maxDimension: options.maxDimension)
        let result = try await processCGImage(
            cg,
            displayPath: item.displayPath,
            with: recognizer,
            options: options
        )
        reportSavedCopy(result.savedURL, quiet: options.quiet)

        let report = OCRReport(
            imagePath: item.displayPath,
            lines: result.lines,
            imageWidth: cg.width,
            imageHeight: cg.height,
            durationMilliseconds: result.durationMilliseconds
        )
        if options.jsonl {
            // 单文件 + --jsonl:输出一行 JSONL(与批量同构,方便统一消费)。
            let batchItem = OCRBatchItem.success(
                imagePath: item.displayPath,
                lines: result.lines,
                imageWidth: cg.width,
                imageHeight: cg.height,
                durationMilliseconds: result.durationMilliseconds
            )
            let withMatches = attachKeywordMatches(batchItem, options: options)
            try emit(try CLIOutputRenderer.renderBatchItemJSONL(item: withMatches),
                     to: options.outputPath, quiet: options.quiet)
        } else {
            try emit(try renderReport(report, options: options), to: options.outputPath, quiet: options.quiet)
        }
        try copyTextToClipboardIfRequested(result.lines, options: options)
    }

    private static func runBatchFiles(options: CLIOptions, items: [InputItem]) async throws {
        let recognizer = makeRecognizer(options: options)
        let started = Date()
        let total = items.count
        let maxConcurrent = max(1, options.concurrency ?? defaultMaxConcurrentImages)
        var doneCount = 0
        var savedCount = 0

        // --jsonl:每完成一张立刻写一行,不攒全量(超大目录内存友好)。
        let lineWriter = try JSONLLineWriter(path: options.jsonl ? options.outputPath : nil)

        let batchItems: [OCRBatchItem] = await withTaskGroup(of: (Int, OCRBatchItem, URL?).self) { group in
            var nextIndex = 0
            var capacity = maxConcurrent
            var collected: [(Int, OCRBatchItem, URL?)] = []

            while capacity > 0, nextIndex < items.count {
                let item = items[nextIndex]
                let index = nextIndex
                nextIndex += 1
                capacity -= 1
                group.addTask {
                    let result = await processOne(item: item, with: recognizer, options: options)
                    return (index, result.item, result.savedURL)
                }
            }

            while let (index, batchItem, saved) = await group.next() {
                collected.append((index, batchItem, saved))
                if saved != nil { savedCount += 1 }
                doneCount += 1
                if !options.quiet {
                    progressLine(done: doneCount, total: total, item: batchItem)
                }
                if options.jsonl, let line = try? CLIOutputRenderer.renderBatchItemJSONL(item: batchItem) {
                    lineWriter.write(line)
                }
                if nextIndex < items.count {
                    let next = items[nextIndex]
                    let nextIdx = nextIndex
                    nextIndex += 1
                    group.addTask {
                        let result = await processOne(item: next, with: recognizer, options: options)
                        return (nextIdx, result.item, result.savedURL)
                    }
                }
            }

            return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        lineWriter.close()

        let batch = OCRBatchReport(items: batchItems)
        if !options.jsonl {
            let payload: String
            switch options.outputMode {
            case .text:
                payload = CLIOutputRenderer.renderBatchText(batch: batch, keyword: options.keyword)
            case .plain:
                payload = CLIOutputRenderer.renderBatchPlain(batch: batch, keyword: options.keyword)
            case .json:
                payload = try CLIOutputRenderer.renderBatchJSON(batch: batch)
            }
            try emit(payload, to: options.outputPath, quiet: options.quiet)
        }
        try copyTextToClipboardIfRequested(
            batch.items.flatMap { $0.lines ?? [] },
            options: options
        )

        if !options.quiet {
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
            // 仅当启用了 --compress-output 时多打印 saved 计数,避免无谓的字段。
            if options.compressionOutput != nil {
                fputs(
                    "完成: \(batch.successCount)/\(total) ok, \(savedCount) saved, \(batch.failureCount) failed, 用时 \(elapsed)s\n",
                    stderr
                )
            } else {
                fputs(
                    "完成: \(batch.successCount)/\(total) ok, \(batch.failureCount) failed, 用时 \(elapsed)s\n",
                    stderr
                )
            }
        }
        if batch.failureCount > 0 { exit(2) }
    }

    /// 在 stderr 打印一行单张完成的进度,使用 \r 原地更新。
    private static func progressLine(done: Int, total: Int, item: OCRBatchItem) {
        let name = (item.imagePath as NSString).lastPathComponent
        let status: String
        switch item.status {
        case .ok: status = "ok (\(item.lines?.count ?? 0) lines)"
        case .failed: status = "FAILED: \(item.errorMessage ?? "?")"
        }
        let prefix = total >= 10 && done < 10 ? " " : ""
        let line = "\r[\(done)/\(total)] \(prefix)\(name)  \(status)"
        fputs(line, stderr)
        if done == total { fputs("\n", stderr) }
    }

    // MARK: - 条码模式

    private static func runBarcode(options: CLIOptions, items: [InputItem]) async throws {
        let recognizer = BarcodeRecognizer()

        if items.count == 1, !options.jsonl {
            let item = items[0]
            let cg = try loadImage(for: item, maxDimension: options.maxDimension)
            let started = Date()
            let barcodes = try await recognizer.recognizeBarcodes(in: cg)
            let duration = Int(Date().timeIntervalSince(started) * 1000)
            let report = BarcodeReport(
                imagePath: item.displayPath,
                barcodes: barcodes,
                imageWidth: cg.width,
                imageHeight: cg.height,
                durationMilliseconds: duration
            )
            let payload: String
            switch options.outputMode {
            case .text: payload = CLIOutputRenderer.renderBarcodeText(report: report)
            case .plain: payload = CLIOutputRenderer.renderBarcodePlain(report: report)
            case .json: payload = try CLIOutputRenderer.renderBarcodeJSON(report: report)
            }
            try emit(payload, to: options.outputPath, quiet: options.quiet)
            try copyPayloadsToClipboardIfRequested(barcodes, options: options)
            return
        }

        // 批量(含单文件 --jsonl)
        let started = Date()
        let total = items.count
        let maxConcurrent = max(1, options.concurrency ?? defaultMaxConcurrentImages)
        var doneCount = 0
        let lineWriter = try JSONLLineWriter(path: options.jsonl ? options.outputPath : nil)

        let batchItems: [BarcodeBatchItem] = await withTaskGroup(of: (Int, BarcodeBatchItem).self) { group in
            var nextIndex = 0
            var capacity = maxConcurrent
            var collected: [(Int, BarcodeBatchItem)] = []

            while capacity > 0, nextIndex < items.count {
                let item = items[nextIndex]
                let index = nextIndex
                nextIndex += 1
                capacity -= 1
                group.addTask {
                    (index, await Self.processBarcode(item: item, with: recognizer, options: options))
                }
            }

            while let (index, batchItem) = await group.next() {
                collected.append((index, batchItem))
                doneCount += 1
                if !options.quiet {
                    let name = (batchItem.imagePath as NSString).lastPathComponent
                    let status = batchItem.status == .ok
                        ? "ok (\(batchItem.barcodes?.count ?? 0) barcodes)"
                        : "FAILED: \(batchItem.errorMessage ?? "?")"
                    fputs("\r[\(doneCount)/\(total)] \(name)  \(status)", stderr)
                    if doneCount == total { fputs("\n", stderr) }
                }
                if options.jsonl, let line = try? CLIOutputRenderer.renderBarcodeItemJSONL(item: batchItem) {
                    lineWriter.write(line)
                }
                if nextIndex < items.count {
                    let next = items[nextIndex]
                    let nextIdx = nextIndex
                    nextIndex += 1
                    group.addTask {
                        (nextIdx, await Self.processBarcode(item: next, with: recognizer, options: options))
                    }
                }
            }

            return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        lineWriter.close()

        let batch = BarcodeBatchReport(items: batchItems)
        if !options.jsonl {
            let payload: String
            switch options.outputMode {
            case .text: payload = CLIOutputRenderer.renderBarcodeBatchText(batch: batch)
            case .plain: payload = CLIOutputRenderer.renderBarcodeBatchPlain(batch: batch)
            case .json: payload = try CLIOutputRenderer.renderBarcodeBatchJSON(batch: batch)
            }
            try emit(payload, to: options.outputPath, quiet: options.quiet)
        }
        try copyPayloadsToClipboardIfRequested(
            batch.items.flatMap { $0.barcodes ?? [] },
            options: options
        )

        if !options.quiet {
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
            fputs(
                "完成: \(batch.successCount)/\(total) ok, \(batch.failureCount) failed, 用时 \(elapsed)s\n",
                stderr
            )
        }
        if batch.failureCount > 0 { exit(2) }
    }

    private static func processBarcode(
        item: InputItem,
        with recognizer: BarcodeRecognizer,
        options: CLIOptions
    ) async -> BarcodeBatchItem {
        do {
            let cg = try loadImage(for: item, maxDimension: options.maxDimension)
            let started = Date()
            let barcodes = try await recognizer.recognizeBarcodes(in: cg)
            let duration = Int(Date().timeIntervalSince(started) * 1000)
            return .success(
                imagePath: item.displayPath,
                barcodes: barcodes,
                imageWidth: cg.width,
                imageHeight: cg.height,
                durationMilliseconds: duration
            )
        } catch {
            return .failure(imagePath: item.displayPath, error: error)
        }
    }

    // MARK: - 截图到剪贴板

    private static func runClipboardCapture(options: CLIOptions, capture: ScreenCaptureOptions) async throws {
        let result = try await Clipboard.writeCapture(options: capture)
        let w = result.width
        let h = result.height
        let savePath = result.savedURL?.path

        let payload: String
        switch options.outputMode {
        case .text, .plain:
            if let savePath {
                payload = "已复制到剪贴板: \(w)x\(h)  另存: \(savePath)"
            } else {
                payload = "已复制到剪贴板: \(w)x\(h)"
            }
        case .json:
            let env = ClipboardEnvelope(clipboard: true, width: w, height: h, savePath: savePath)
            payload = try Self.encodeJSON(env)
        }
        try emit(payload, to: options.outputPath, quiet: options.quiet)
    }

    // MARK: - 从剪贴板 / stdin 读图 + OCR

    private static func runPasteboardOCR(options: CLIOptions) async throws {
        let cg = try Clipboard.readImage()
        let displayPath = "<clipboard> (\(cg.width)x\(cg.height))"
        try await runSingleCGImageOCR(cg, displayPath: displayPath, options: options)
    }

    private static func runStdinImageOCR(options: CLIOptions) async throws {
        guard let data = readStdinData(), !data.isEmpty else {
            throw CLIError.stdinRequestedButNoReader
        }
        let cg = try ImageLoader.loadCGImage(fromData: data)
        let displayPath = "<stdin> (\(cg.width)x\(cg.height))"
        try await runSingleCGImageOCR(cg, displayPath: displayPath, options: options)
    }

    /// 内存 CGImage 单图 OCR 的公共尾部(剪贴板/stdin 共用)。
    private static func runSingleCGImageOCR(
        _ cg: CGImage,
        displayPath: String,
        options: CLIOptions
    ) async throws {
        let recognizer = makeRecognizer(options: options)
        let result = try await processCGImage(
            cg,
            displayPath: displayPath,
            with: recognizer,
            options: options
        )
        let report = OCRReport(
            imagePath: displayPath,
            lines: result.lines,
            imageWidth: cg.width,
            imageHeight: cg.height,
            durationMilliseconds: result.durationMilliseconds
        )
        try emit(try renderReport(report, options: options), to: options.outputPath, quiet: options.quiet)
        try copyTextToClipboardIfRequested(result.lines, options: options)
    }

    // MARK: - 单图处理管线

    /// 单图完整流程:CGImage → (按需)降采样 → (按需)压缩预处理 → OCR(计时) → (按需)保存压缩副本。
    /// 抛错表示 OCR 不可恢复(预处理失败也归到 OCR 失败,因为没图可识)。
    /// 保存压缩副本是 best-effort,失败仅写 stderr 警告。
    static func processCGImage(
        _ cg: CGImage,
        displayPath: String,
        with recognizer: VisionOCRRecognizer,
        options: CLIOptions
    ) async throws -> (lines: [OCRTextLine], savedURL: URL?, durationMilliseconds: Int) {
        // 1. 降采样:截图/剪贴板/PDF 渲染等内存输入在这里统一处理;
        //    文件输入已在解码期降采样,这里是无操作的兜底。
        var ocrCG = cg
        if let maxDimension = options.maxDimension {
            ocrCG = ImageLoader.downsample(ocrCG, maxPixelSize: maxDimension)
        }

        // 2. 预处理:压缩到内存中的更小 CGImage,直接喂给 OCR。
        if let cfg = options.compressionInput {
            ocrCG = try ImageCompressor.compress(ocrCG, format: cfg.format, quality: cfg.quality)
        }

        // 3. OCR(计时,写进报告元数据)
        let started = Date()
        let lines = try await recognizer.recognizeText(in: ocrCG)
        let duration = Int(Date().timeIntervalSince(started) * 1000)

        // 4. 保存压缩副本(best-effort,失败不抛错)
        var savedURL: URL?
        if let cfg = options.compressionOutput, let dir = options.compressionOutputDirectory {
            let outURL = compressedOutputURL(for: displayPath, inDir: dir, format: cfg.format)
            do {
                try ImageCompressor.encode(cg, to: outURL, format: cfg.format, quality: cfg.quality)
                savedURL = outURL
            } catch {
                if !options.quiet {
                    fputs("[警告] 无法保存压缩副本 \(outURL.path): \(error.localizedDescription)\n", stderr)
                }
            }
        }

        return (lines, savedURL, duration)
    }

    /// 单文件批处理入口:加载 CGImage → processCGImage → 包装成 OCRBatchItem。
    /// OCR 失败标记 .failure(影响 batch 统计),保存失败只走 stderr 警告(不影响统计)。
    private static func processOne(
        item: InputItem,
        with recognizer: VisionOCRRecognizer,
        options: CLIOptions
    ) async -> (item: OCRBatchItem, savedURL: URL?) {
        do {
            let cg = try loadImage(for: item, maxDimension: options.maxDimension)
            let result = try await processCGImage(
                cg,
                displayPath: item.displayPath,
                with: recognizer,
                options: options
            )
            let batchItem = OCRBatchItem.success(
                imagePath: item.displayPath,
                lines: result.lines,
                imageWidth: cg.width,
                imageHeight: cg.height,
                durationMilliseconds: result.durationMilliseconds
            )
            return (attachKeywordMatches(batchItem, options: options), result.savedURL)
        } catch {
            return (.failure(imagePath: item.displayPath, error: error), nil)
        }
    }

    /// 批量 `-k`:给成功项附加命中列表(降序)。失败项/未启用关键词原样返回。
    static func attachKeywordMatches(_ item: OCRBatchItem, options: CLIOptions) -> OCRBatchItem {
        guard let keyword = options.keyword, let lines = item.lines else { return item }
        return item.addingKeywordMatches(
            CLIOutputRenderer.keywordMatches(lines: lines, keyword: keyword)
        )
    }

    /// 把原文件的 stem 拼上目标目录和压缩格式的扩展名。
    /// 例: `/a/b/photo.png` + `/out` + `.jpeg` → `/out/photo.jpg`
    private static func compressedOutputURL(
        for displayPath: String,
        inDir dir: URL,
        format: ImageFormat
    ) -> URL {
        // displayPath 是 URL.path 形式(不含 file:// 前缀),用 lastPathComponent 拿到文件名。
        // PDF 逐页项带 `#page=N` 后缀,拼文件名前去掉,再补回页码避免互相覆盖。
        let pathPart = displayPath.components(separatedBy: "#page=").first ?? displayPath
        let pageSuffix = displayPath.components(separatedBy: "#page=").count > 1
            ? "-p" + (displayPath.components(separatedBy: "#page=").last ?? "")
            : ""
        let nsPath = pathPart as NSString
        let fullName = nsPath.lastPathComponent
        let stem = (fullName as NSString).deletingPathExtension + pageSuffix
        let ext = ImageCompressor.fileExtension(for: format)
        return dir.appendingPathComponent(stem).appendingPathExtension(ext)
    }

    // MARK: - 辅助

    private struct WindowListEnvelope: Codable {
        let windows: [ScreenCaptureWindowInfo]
    }

    private struct DisplayListEnvelope: Codable {
        let displays: [DisplayInfo]
    }

    private struct LangListEnvelope: Codable {
        let level: String
        let languages: [String]
    }

    private struct ClipboardEnvelope: Codable {
        let clipboard: Bool
        let width: Int
        let height: Int
        let savePath: String?
    }

    /// --jsonl 的行写出器:有 -o 写文件,否则写 stdout。
    /// 逐行写出(而非攒全量),大目录下内存占用与输入规模无关。
    final class JSONLLineWriter {
        private let handle: FileHandle?

        init(path: URL?) throws {
            if let path {
                try FileManager.default.createDirectory(
                    at: path.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                FileManager.default.createFile(atPath: path.path, contents: nil)
                handle = try FileHandle(forWritingTo: path)
            } else {
                handle = nil
            }
        }

        func write(_ line: String) {
            guard let data = (line + "\n").data(using: .utf8) else { return }
            if let handle {
                handle.write(data)
            } else {
                FileHandle.standardOutput.write(data)
            }
        }

        func close() {
            try? handle?.close()
        }
    }

    private static func renderReport(_ report: OCRReport, options: CLIOptions) throws -> String {
        switch options.outputMode {
        case .text: return CLIOutputRenderer.renderText(report: report, options: options)
        case .plain: return CLIOutputRenderer.renderPlain(report: report)
        case .json: return try CLIOutputRenderer.renderJSON(report: report)
        }
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func renderWindowListText(windows: [ScreenCaptureWindowInfo]) -> String {
        guard !windows.isEmpty else { return "（无可用窗口——可能未授予屏幕录制权限）" }
        var lines: [String] = []
        lines.append("可见窗口: \(windows.count) 个")
        for w in windows {
            let name = w.windowName?.isEmpty == false ? w.windowName! : "（无标题）"
            let owner = w.ownerName ?? "?"
            let bounds = w.bounds.map { "(\($0.x),\($0.y),\($0.width),\($0.height))" } ?? "(no bounds)"
            lines.append("  id=\(w.windowID) layer=\(w.layer) [\(owner)] \(name)  \(bounds)")
        }
        return lines.joined(separator: "\n")
    }

    private static func renderDisplayListText(displays: [DisplayInfo]) -> String {
        guard !displays.isEmpty else { return "（无可用显示器——可能未授予屏幕录制权限）" }
        var lines: [String] = ["显示器: \(displays.count) 台"]
        for d in displays {
            let main = d.isMain ? " (主屏)" : ""
            lines.append("  [\(d.index)] id=\(d.displayID) \(d.width)x\(d.height) @\(String(format: "%.1f", d.scaleFactor))x\(main)")
        }
        return lines.joined(separator: "\n")
    }

    private static func makeRecognizer(options: CLIOptions) -> VisionOCRRecognizer {
        VisionOCRRecognizer(
            recognitionLanguages: options.languages,
            recognitionLevel: options.level,
            usesLanguageCorrection: options.languageCorrection,
            includeWordBoxes: options.wordBoxes,
            minimumConfidence: options.minConfidence ?? 0
        )
    }

    private static func reportSavedCopy(_ savedURL: URL?, quiet: Bool) {
        if let savedURL, !quiet {
            fputs("已保存压缩副本: \(savedURL.path)\n", stderr)
        }
    }

    /// `--to-clipboard`:把识别文本(每行一条)写入剪贴板。
    private static func copyTextToClipboardIfRequested(_ lines: [OCRTextLine], options: CLIOptions) throws {
        guard options.toClipboard else { return }
        try Clipboard.writeText(lines.map(\.text).joined(separator: "\n"))
        if !options.quiet {
            fputs("已复制 \(lines.count) 行文本到剪贴板\n", stderr)
        }
    }

    /// 条码模式的 `--to-clipboard`:每行一个 payload。
    private static func copyPayloadsToClipboardIfRequested(_ barcodes: [OCRBarcode], options: CLIOptions) throws {
        guard options.toClipboard else { return }
        try Clipboard.writeText(barcodes.map(\.payload).joined(separator: "\n"))
        if !options.quiet {
            fputs("已复制 \(barcodes.count) 条条码内容到剪贴板\n", stderr)
        }
    }

    private static func emit(_ payload: String, to outputPath: URL?, quiet: Bool = false) throws {
        if let outputPath {
            try FileManager.default.createDirectory(
                at: outputPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try payload.write(to: outputPath, atomically: true, encoding: .utf8)
        }
        if !quiet {
            print(payload)
        }
    }

    /// 从 stdin 读取全部 UTF-8 文本。TTY 模式下返回 nil(避免挂起)。
    private static func readStdin() -> String? {
        if isatty(STDIN_FILENO) != 0 { return nil }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    /// 从 stdin 读取原始字节(`--stdin-image`)。TTY 模式下返回 nil。
    private static func readStdinData() -> Data? {
        if isatty(STDIN_FILENO) != 0 { return nil }
        return FileHandle.standardInput.readDataToEndOfFile()
    }
}
