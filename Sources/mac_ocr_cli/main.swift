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
        // 压缩副本的命名来源:有 --save-screenshot 就沿用它的 stem,否则用 "screen"
        // (报告里的 imagePath 仍然是 "<screen>")。
        let outputStemSource = capture.savePath?.path ?? "screen"
        let plannedOutputURL: URL? = {
            guard let dir = options.compressionOutputDirectory,
                  let cfg = options.compressionOutput else { return nil }
            return CompressedOutputPlanner(displayPaths: [outputStemSource])
                .url(for: outputStemSource, in: dir, format: cfg.format)
        }()
        let result = try await processCGImage(
            cg,
            displayPath: displayPath,
            with: recognizer,
            options: options,
            plannedOutputURL: plannedOutputURL
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

        let report = attachKeywordMatches(
            OCRReport(
                imagePath: item.displayPath,
                lines: result.lines,
                imageWidth: cg.width,
                imageHeight: cg.height,
                durationMilliseconds: result.durationMilliseconds
            ),
            options: options
        )
        if options.jsonl {
            // 单文件 + --jsonl:输出一行 JSONL(与批量同构,方便统一消费)。
            // 走 JSONLLineWriter 而不是 emit:保证「-o 只写文件、--quiet 静音 stdout、
            // 每行带换行」三条规则与批量路径完全一致。
            let batchItem = OCRBatchItem.success(
                imagePath: item.displayPath,
                lines: result.lines,
                imageWidth: cg.width,
                imageHeight: cg.height,
                durationMilliseconds: result.durationMilliseconds
            )
            let withMatches = attachKeywordMatches(batchItem, options: options)
            let writer = try JSONLLineWriter(path: options.outputPath, quiet: options.quiet)
            try writer.write(try CLIOutputRenderer.renderBatchItemJSONL(item: withMatches))
            try writer.close()
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

        // 压缩副本的输出名在并发开始前一次性算好:输出目录是扁平的,不同来源目录的
        // 同名输入会撞名(后写的直接覆盖先写的,批量模式下还会并发写同一路径)。
        let plannedOutputs = plannedCompressedOutputs(items: items, options: options)

        // --jsonl:每完成一张立刻写一行,不攒全量(超大目录内存友好)。
        let lineWriter = try JSONLLineWriter(
            path: options.jsonl ? options.outputPath : nil,
            quiet: options.quiet
        )

        // 用 throwing 版本的 task group:JSONL 写失败要往上传,
        // 不能在并发收集的闭包里被吞掉(闭包本身是 async throwing 上下文)。
        let batchItems: [OCRBatchItem] = try await withThrowingTaskGroup(
            of: (Int, OCRBatchItem, URL?).self
        ) { group in
            var nextIndex = 0
            var capacity = maxConcurrent
            var collected: [(Int, OCRBatchItem, URL?)] = []

            while capacity > 0, nextIndex < items.count {
                let item = items[nextIndex]
                let index = nextIndex
                nextIndex += 1
                capacity -= 1
                group.addTask {
                    let result = await processOne(
                        item: item,
                        with: recognizer,
                        options: options,
                        plannedOutputURL: plannedOutputs[item.displayPath]
                    )
                    return (index, result.item, result.savedURL)
                }
            }

            while let (index, batchItem, saved) = try await group.next() {
                collected.append((index, batchItem, saved))
                if saved != nil { savedCount += 1 }
                doneCount += 1
                if !options.quiet {
                    progressLine(done: doneCount, total: total, item: batchItem)
                }
                if options.jsonl {
                    // 序列化失败必须往上传:静默跳过一行等于悄悄丢数据。
                    let line = try CLIOutputRenderer.renderBatchItemJSONL(item: batchItem)
                    try lineWriter.write(line)
                }
                if nextIndex < items.count {
                    let next = items[nextIndex]
                    let nextIdx = nextIndex
                    nextIndex += 1
                    group.addTask {
                        let result = await processOne(
                            item: next,
                            with: recognizer,
                            options: options,
                            plannedOutputURL: plannedOutputs[next.displayPath]
                        )
                        return (nextIdx, result.item, result.savedURL)
                    }
                }
            }

            return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        try lineWriter.close()

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
        let lineWriter = try JSONLLineWriter(
            path: options.jsonl ? options.outputPath : nil,
            quiet: options.quiet
        )

        // 用 throwing 版本的 task group:JSONL 写失败要往上传,不能在闭包里被吞掉。
        let batchItems: [BarcodeBatchItem] = try await withThrowingTaskGroup(
            of: (Int, BarcodeBatchItem).self
        ) { group in
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

            while let (index, batchItem) = try await group.next() {
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
                if options.jsonl {
                    // 序列化失败必须往上传:静默跳过一行等于悄悄丢数据。
                    let line = try CLIOutputRenderer.renderBarcodeItemJSONL(item: batchItem)
                    try lineWriter.write(line)
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
        try lineWriter.close()

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
        let report = attachKeywordMatches(
            OCRReport(
                imagePath: displayPath,
                lines: result.lines,
                imageWidth: cg.width,
                imageHeight: cg.height,
                durationMilliseconds: result.durationMilliseconds
            ),
            options: options
        )
        try emit(try renderReport(report, options: options), to: options.outputPath, quiet: options.quiet)
        try copyTextToClipboardIfRequested(result.lines, options: options)
    }

    // MARK: - 单图处理管线

    /// 单图完整流程:CGImage → (按需)降采样 → (按需)压缩预处理 → OCR(计时) → (按需)保存压缩副本。
    /// 抛错表示 OCR 不可恢复(预处理失败也归到 OCR 失败,因为没图可识)。
    /// 保存压缩副本是 best-effort,失败仅写 stderr 警告。
    /// - Parameter plannedOutputURL: 压缩副本的目标路径。批量模式下由
    ///   `CompressedOutputPlanner` 预先算好(避免同名输入互相覆盖);
    ///   nil 时按单文件规则即时推导。
    static func processCGImage(
        _ cg: CGImage,
        displayPath: String,
        with recognizer: VisionOCRRecognizer,
        options: CLIOptions,
        plannedOutputURL: URL? = nil
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
            let outURL = plannedOutputURL
                ?? compressedOutputURL(for: displayPath, inDir: dir, format: cfg.format)
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
        options: CLIOptions,
        plannedOutputURL: URL? = nil
    ) async -> (item: OCRBatchItem, savedURL: URL?) {
        do {
            let cg = try loadImage(for: item, maxDimension: options.maxDimension)
            let result = try await processCGImage(
                cg,
                displayPath: item.displayPath,
                with: recognizer,
                options: options,
                plannedOutputURL: plannedOutputURL
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

    /// 单文件 `-k`:给报告附加命中列表(降序)。未启用关键词时原样返回。
    /// `--json` 会带上 `keywordMatches` 字段,`--plain` 按命中过滤输出。
    static func attachKeywordMatches(_ report: OCRReport, options: CLIOptions) -> OCRReport {
        guard let keyword = options.keyword else { return report }
        return report.addingKeywordMatches(
            CLIOutputRenderer.keywordMatches(lines: report.lines, keyword: keyword)
        )
    }

    /// 把原文件的 stem 拼上目标目录和压缩格式的扩展名。
    /// 例: `/a/b/photo.png` + `/out` + `.jpeg` → `/out/photo.jpg`
    /// 命名规则统一由 `CompressedOutputPlanner` 负责(同名输入会按相对路径消歧)。
    private static func compressedOutputURL(
        for displayPath: String,
        inDir dir: URL,
        format: ImageFormat
    ) -> URL {
        let planner = CompressedOutputPlanner(displayPaths: [displayPath])
        return planner.url(for: displayPath, in: dir, format: format)
            ?? dir.appendingPathComponent("image")
                .appendingPathExtension(ImageCompressor.fileExtension(for: format))
    }

    /// 批量模式下预先算出每个输入的压缩副本目标路径。
    /// 输出目录是扁平的,不同来源目录的同名输入会撞名——用
    /// `CompressedOutputPlanner` 按相对路径消歧,保证一个输入对应一个输出文件。
    private static func plannedCompressedOutputs(
        items: [InputItem],
        options: CLIOptions
    ) -> [String: URL] {
        guard let dir = options.compressionOutputDirectory,
              let cfg = options.compressionOutput else { return [:] }
        let planner = CompressedOutputPlanner(displayPaths: items.map(\.displayPath))
        var map: [String: URL] = [:]
        for item in items {
            if let url = planner.url(for: item.displayPath, in: dir, format: cfg.format) {
                map[item.displayPath] = url
            }
        }
        return map
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
    /// - 有 `-o`:只写文件,不再往 stdout 重复输出一份。
    ///   内容先写同目录下的临时文件,写入期间旧目标文件保持原样;
    ///   close 时关闭句柄并用 rename(2) 原子替换目标路径,
    ///   避免复用旧文件时残留旧尾巴,也避免中途失败留下半个文件。
    ///   目标已存在且是普通文件时,临时文件沿用目标原有的权限位,
    ///   避免原子替换把目标的 mode 变成默认权限。
    ///   目标已经是符号链接时直接拒绝(不替换链接本身,链接与其目标都原样保留);
    ///   提交前还会再复核一次目标(写入期间目标可能变成符号链接)。
    /// - 无 `-o`:写 stdout,`--quiet` 时不写
    final class JSONLLineWriter {
        /// 写出/落盘失败时抛出的错误。
        enum WriteError: LocalizedError, Equatable {
            case destinationIsSymbolicLink(path: String)
            case cannotOpenOutputDirectory(path: String, code: Int32)
            case cannotCreateTemporaryFile(path: String, code: Int32)
            case cannotApplyPermissions(path: String, code: Int32)
            case cannotWriteTemporaryFile(path: String, reason: String)
            case cannotWriteToStdout(reason: String)
            case cannotCloseTemporaryFile(path: String)
            case cannotInspectDestination(path: String, code: Int32)
            case cannotCommitTemporaryFile(temporary: String, destination: String, code: Int32)

            var errorDescription: String? {
                switch self {
                case .destinationIsSymbolicLink(let path):
                    return "输出路径 \(path) 是符号链接:为避免替换链接本身,拒绝写入"
                case .cannotOpenOutputDirectory(let path, let code):
                    return "无法打开输出目录 \(path)(errno \(code))"
                case .cannotCreateTemporaryFile(let path, let code):
                    return "无法创建临时文件 \(path)(errno \(code))"
                case .cannotApplyPermissions(let path, let code):
                    return "无法设置临时文件 \(path) 的权限位(errno \(code))"
                case .cannotWriteTemporaryFile(let path, let reason):
                    return "无法写入临时文件 \(path)(\(reason))"
                case .cannotWriteToStdout(let reason):
                    return "无法写入 stdout(\(reason))"
                case .cannotCloseTemporaryFile(let path):
                    return "无法关闭临时文件 \(path)"
                case .cannotInspectDestination(let path, let code):
                    return "无法检查输出路径 \(path)(errno \(code))"
                case .cannotCommitTemporaryFile(let temporary, let destination, let code):
                    return "无法把临时文件 \(temporary) 原子替换为 \(destination)(errno \(code))"
                }
            }
        }

        /// 临时文件名前缀:与目标同目录,隐藏文件,方便失败时清理。
        private static let temporaryFilePrefix = ".mac_ocr_cli-jsonl-"

        private var handle: FileHandle?
        private let writesToStdout: Bool
        /// 目标路径;非 nil 表示文件模式。
        private let destination: URL?
        /// 临时文件在输出目录里的名字(unlinkat / renameat 用)。
        private var temporaryName: String?
        /// 临时文件的完整路径(仅用于报错信息)。
        private var temporaryPath: String?
        /// 输出目录的文件描述符:清理与提交都走 fd,不再按路径二次解析。
        private var directoryDescriptor: Int32?
        /// 写失败后记住的错误:之后的 write 直接重复抛出,不再静默丢数据。
        private var writeFailure: WriteError?

        init(path: URL?, quiet: Bool) throws {
            if let path {
                let directory = path.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                // 目标已经是符号链接:直接拒绝。
                // 原子 rename 只会替换链接本身(不会写进链接指向的文件),
                // 那等于悄悄丢掉用户的链接结构;这里明确报错,链接与其目标都原样保留。
                if Self.isSymbolicLink(at: path) {
                    throw WriteError.destinationIsSymbolicLink(path: path.path)
                }
                // 目标已存在且是普通文件时,先记下它的权限位:
                // 临时文件是按 0600 建的,直接 rename 过去会把目标权限改成 0600。
                let destinationMode = Self.posixPermissionMode(ofRegularFileAt: path)

                let directoryFD = directory.path.withCString {
                    open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                }
                guard directoryFD >= 0 else {
                    throw WriteError.cannotOpenOutputDirectory(path: directory.path, code: errno)
                }

                let name = "\(Self.temporaryFilePrefix)\(UUID().uuidString).tmp"
                // 完整路径只用于报错信息;文件本身在目录 fd 下相对创建,
                // 避免「按路径二次解析」带来的 TOCTOU(路径被替换就写到别处)。
                let temporary = directory.appendingPathComponent(name).path
                let creation = Self.createTemporaryFile(directoryDescriptor: directoryFD, name: name)
                guard creation.fd >= 0 else {
                    let code = creation.errorCode
                    _ = unistd.close(directoryFD)
                    throw WriteError.cannotCreateTemporaryFile(path: temporary, code: code)
                }
                let temporaryFD = creation.fd

                // 权限用 fd 设置(fchmod):目标可能是只读的(如 0400),
                // 按路径 chmod 之后再打开会因为没有写权限而失败;
                // 而且这里失败必须报错,不能悄悄放行一个权限不对的临时文件。
                let desiredMode = destinationMode ?? Self.defaultCreationMode()
                if fchmod(temporaryFD, desiredMode) != 0 {
                    let code = errno
                    _ = unistd.close(temporaryFD)
                    _ = name.withCString { unlinkat(directoryFD, $0, 0) }
                    _ = unistd.close(directoryFD)
                    throw WriteError.cannotApplyPermissions(path: temporary, code: code)
                }

                handle = FileHandle(fileDescriptor: temporaryFD, closeOnDealloc: true)
                writesToStdout = false
                destination = path
                temporaryName = name
                temporaryPath = temporary
                directoryDescriptor = directoryFD
            } else {
                handle = nil
                writesToStdout = !quiet
                destination = nil
            }
        }

        /// 写出一行(自动补换行)。写失败时抛错:
        /// 文件模式下会关闭句柄并删除临时文件,目标文件保持原样。
        func write(_ line: String) throws {
            if let failure = writeFailure { throw failure }
            guard let data = (line + "\n").data(using: .utf8) else { return }
            if let handle {
                do {
                    try handle.write(contentsOf: data)
                } catch {
                    let path = temporaryPath ?? ""
                    let failure = WriteError.cannotWriteTemporaryFile(
                        path: path,
                        reason: error.localizedDescription
                    )
                    // 写失败:关句柄 + 删临时文件,目标文件保持原样。
                    abortTemporaryFile()
                    writeFailure = failure
                    throw failure
                }
            } else if writesToStdout {
                do {
                    try FileHandle.standardOutput.write(contentsOf: data)
                } catch {
                    throw WriteError.cannotWriteToStdout(reason: error.localizedDescription)
                }
            }
        }

        /// 结束写出。文件模式下:先复核目标路径,再关闭临时文件句柄,
        /// 最后用 rename(2) 原子替换目标路径。
        /// 失败时抛错(临时文件会被清理,目标文件保持原样)。
        func close() throws {
            guard let handle else { return }  // stdout 模式(或已关闭):无事可做
            self.handle = nil
            // 提交前复核目标:init 时的符号链接检查与真正提交之间存在时间窗口,
            // 期间目标可能已被换成符号链接。这里再查一次:
            // 目标是符号链接就拒绝(既不跟随,也不替换),目标不存在就照常提交。
            do {
                try revalidateDestinationBeforeCommit()
            } catch {
                try? handle.close()
                cleanupTemporaryFile()
                throw error
            }
            do {
                try handle.close()
            } catch {
                let path = temporaryPath ?? ""
                cleanupTemporaryFile()
                throw WriteError.cannotCloseTemporaryFile(path: path)
            }
            guard let name = temporaryName,
                  let destination,
                  let directoryFD = directoryDescriptor else { return }
            // 用 renameat 提交:目标与临时文件在同一个目录 fd 下解析,不再按路径重解析。
            let destinationName = destination.lastPathComponent
            let result = name.withCString { temporary in
                destinationName.withCString { target in
                    renameat(directoryFD, temporary, directoryFD, target)
                }
            }
            if result != 0 {
                let code = errno
                cleanupTemporaryFile()
                throw WriteError.cannotCommitTemporaryFile(
                    temporary: temporaryPath ?? name,
                    destination: destination.path,
                    code: code
                )
            }
            // 提交成功:临时文件已经变成目标文件,只剩关目录 fd。
            temporaryName = nil
            temporaryPath = nil
            closeDirectoryDescriptor()
        }

        deinit {
            // 未 close(或 close 失败)时兜底清理临时文件。
            cleanupTemporaryFile()
        }

        /// 新建文件的默认权限:0666 & ~umask(与 open(..., 0o666) 的结果一致)。
        /// 读取 umask 时先临时收紧再立刻恢复,避免读 umask 的窗口里
        /// 意外放宽其他线程创建文件的权限。
        private static func defaultCreationMode() -> mode_t {
            let mask = umask(0o077)
            _ = umask(mask)
            return 0o666 & ~mask
        }

        /// 路径存在且是符号链接时返回 true。
        /// 用 lstat:stat 会跟随链接,看不到链接本身。
        private static func isSymbolicLink(at url: URL) -> Bool {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return false }
            return (info.st_mode & S_IFMT) == S_IFLNK
        }

        /// 路径已存在且是普通文件时,返回它的 POSIX 权限位(否则 nil)。
        /// 用 lstat:软链接本身不是普通文件,不能按链接目标的权限来建临时文件。
        private static func posixPermissionMode(ofRegularFileAt url: URL) -> mode_t? {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            guard (info.st_mode & S_IFMT) == S_IFREG else { return nil }
            return info.st_mode & 0o7777
        }

        /// 在已打开的目录 fd 下用 openat(2) 相对创建临时文件。
        /// O_EXCL 保证不会复用已存在的名字,O_NOFOLLOW 保证不会跟随符号链接,
        /// O_CREAT 用 0600 建文件:写入期间只有本人可读写。
        /// 名字相对目录 fd 解析,不再按路径二次解析,避免路径 TOCTOU。
        /// 失败时返回 (-1, errno),由调用方决定错误语义。
        static func createTemporaryFile(
            directoryDescriptor: Int32,
            name: String
        ) -> (fd: Int32, errorCode: Int32) {
            let fd = name.withCString {
                openat(
                    directoryDescriptor,
                    $0,
                    O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(0o600)
                )
            }
            if fd < 0 { return (-1, errno) }
            return (fd, 0)
        }

        /// 写失败时的兜底:关闭临时句柄并删除临时文件,目标文件保持原样。
        private func abortTemporaryFile() {
            if let handle {
                self.handle = nil
                try? handle.close()
            }
            cleanupTemporaryFile()
        }

        /// 测试钩子:提前关闭底层句柄,让下一次写入必然失败,
        /// 用来验证「写失败 → 清理临时文件 → 目标文件保持原样」这条路径。
        func invalidateHandleForTesting() throws {
            try handle?.close()
        }

        /// 提交前复核目标路径(在目录 fd 下用 fstatat,AT_SYMLINK_NOFOLLOW):
        /// - 目标是符号链接:拒绝(不跟随、不替换),沿用 init 阶段的同款错误。
        /// - 目标不存在:正常,照常提交(rename 的覆盖语义由内核决定)。
        /// - 目标仍是普通文件:沿用它当前的权限位,免得原子替换把目标的 mode 改掉
        ///   (init 时读到的权限位可能已经过时)。
        /// - 其他 stat 错误:当作失败,调用方负责清理临时文件。
        private func revalidateDestinationBeforeCommit() throws {
            guard let destination, let directoryFD = directoryDescriptor else { return }
            let destinationName = destination.lastPathComponent
            var info = stat()
            let result = destinationName.withCString {
                fstatat(directoryFD, $0, &info, AT_SYMLINK_NOFOLLOW)
            }
            if result != 0 {
                let code = errno
                // 目标不存在:正常路径,继续提交。
                if code == ENOENT { return }
                throw WriteError.cannotInspectDestination(path: destination.path, code: code)
            }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFLNK {
                throw WriteError.destinationIsSymbolicLink(path: destination.path)
            }
            if kind == S_IFREG, let name = temporaryName {
                // 目标还是普通文件:用 fchmodat(目录 fd 相对)把临时文件的权限位对齐,
                // 保持「原子替换不改变目标权限」的行为。
                let mode = info.st_mode & 0o7777
                let chmodResult = name.withCString {
                    fchmodat(directoryFD, $0, mode, AT_SYMLINK_NOFOLLOW)
                }
                if chmodResult != 0 {
                    let code = errno
                    throw WriteError.cannotApplyPermissions(
                        path: temporaryPath ?? name,
                        code: code
                    )
                }
            }
        }

        /// 清理临时文件:按目录 fd 调 unlinkat,再关掉目录 fd。
        /// 清理是 best-effort:失败只影响残留的临时文件,不掩盖调用方的主错误。
        private func cleanupTemporaryFile() {
            if let name = temporaryName, let directoryFD = directoryDescriptor {
                _ = name.withCString { unlinkat(directoryFD, $0, 0) }
            }
            temporaryName = nil
            temporaryPath = nil
            closeDirectoryDescriptor()
        }

        private func closeDirectoryDescriptor() {
            if let fd = directoryDescriptor {
                directoryDescriptor = nil
                _ = unistd.close(fd)
            }
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
