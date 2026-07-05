import AppKit
import Darwin
import Foundation
import MacOCRCore

@main
struct MacOCRCLI {
    /// 批量模式并发上限。Vision 在不同请求间是线程安全的,
    /// 但单张图片里 OCR 本身是串行的(没有跨核加速),
    /// 所以 N 个 worker ≈ 4x 单张速度,再往上收益递减。
    static let maxConcurrentImages = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))

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
            if let capture = options.clipboardCapture {
                try runClipboardCapture(options: options, capture: capture)
                return
            }
            if options.pasteboardSource {
                try await runPasteboardOCR(options: options)
                return
            }
            if let capture = options.screenCapture {
                try await runCaptureThenOCR(options: options, capture: capture)
                return
            }
            try await runFileOCR(options: options)
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

    // MARK: - 窗口列表（不跑 OCR）

    private static func runWindowList(options: CLIOptions) throws {
        let windows = ScreenCapture.listVisibleWindows()
        let payload: String
        switch options.outputMode {
        case .text:
            payload = renderWindowListText(windows: windows)
        case .json:
            let env = WindowListEnvelope(windows: windows)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            payload = String(decoding: try encoder.encode(env), as: UTF8.self)
        }
        try emit(payload, to: options.outputPath, quiet: options.quiet)
    }

    // MARK: - 截图 + OCR

    private static func runCaptureThenOCR(options: CLIOptions, capture: ScreenCaptureOptions) async throws {
        let pngURL: URL
        let isTemp: Bool
        if capture.savePath != nil {
            pngURL = try ScreenCapture.capturePNG(options: capture)
            isTemp = false
        } else {
            pngURL = try ScreenCapture.capturePNG(options: capture)
            isTemp = true
        }
        defer { if isTemp { try? FileManager.default.removeItem(at: pngURL) } }

        let recognizer = makeRecognizer(options: options)
        let cg = try ImageLoader.loadCGImage(from: pngURL)
        let displayPath = capture.savePath?.path ?? pngURL.path
        let (lines, savedURL) = try await processCGImage(
            cg,
            displayPath: displayPath,
            with: recognizer,
            options: options
        )
        if let savedURL, !options.quiet {
            fputs("已保存压缩副本: \(savedURL.path)\n", stderr)
        }

        let report = OCRReport(imagePath: displayPath, lines: lines)
        let text = CLIOutputRenderer.renderText(report: report, options: options)
        let json = try CLIOutputRenderer.renderJSON(report: report)
        let payload = (options.outputMode == .text) ? text : json
        try emit(payload, to: options.outputPath, quiet: options.quiet)
    }

    // MARK: - 文件 OCR(单文件/批量)

    private static func runFileOCR(options: CLIOptions) async throws {
        if options.isSingleImage {
            try await runSingleFile(options: options)
        } else {
            try await runBatchFiles(options: options)
        }
    }

    private static func runSingleFile(options: CLIOptions) async throws {
        let url = options.imageURLs[0]
        let recognizer = makeRecognizer(options: options)
        let cg = try ImageLoader.loadCGImage(from: url)
        let (lines, savedURL) = try await processCGImage(
            cg,
            displayPath: url.path,
            with: recognizer,
            options: options
        )
        if let savedURL, !options.quiet {
            fputs("已保存压缩副本: \(savedURL.path)\n", stderr)
        }
        let report = OCRReport(imagePath: url.path, lines: lines)

        let text = CLIOutputRenderer.renderText(report: report, options: options)
        let json = try CLIOutputRenderer.renderJSON(report: report)
        let payload = (options.outputMode == .text) ? text : json
        try emit(payload, to: options.outputPath, quiet: options.quiet)
    }

    private static func runBatchFiles(options: CLIOptions) async throws {
        let recognizer = makeRecognizer(options: options)
        let started = Date()
        let total = options.imageURLs.count
        var doneCount = 0
        var savedCount = 0

        let items: [OCRBatchItem] = await withTaskGroup(of: (Int, OCRBatchItem, URL?).self) { group in
            var nextIndex = 0
            var capacity = maxConcurrentImages
            var collected: [(Int, OCRBatchItem, URL?)] = []

            while capacity > 0, nextIndex < options.imageURLs.count {
                let url = options.imageURLs[nextIndex]
                let index = nextIndex
                nextIndex += 1
                capacity -= 1
                group.addTask {
                    let result = await processOne(url: url, with: recognizer, options: options)
                    return (index, result.item, result.savedURL)
                }
            }

            while let (index, item, saved) = await group.next() {
                collected.append((index, item, saved))
                if saved != nil { savedCount += 1 }
                doneCount += 1
                if !options.quiet {
                    progressLine(done: doneCount, total: total, item: item)
                }
                if nextIndex < options.imageURLs.count {
                    let url = options.imageURLs[nextIndex]
                    let next = nextIndex
                    nextIndex += 1
                    group.addTask {
                        let result = await processOne(url: url, with: recognizer, options: options)
                        return (next, result.item, result.savedURL)
                    }
                }
            }

            return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
        }

        let batch = OCRBatchReport(items: items)
        let text = CLIOutputRenderer.renderBatchText(batch: batch)
        let json = try CLIOutputRenderer.renderBatchJSON(batch: batch)
        let payload = (options.outputMode == .text) ? text : json
        try emit(payload, to: options.outputPath, quiet: options.quiet)

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

    // MARK: - 辅助

    private struct WindowListEnvelope: Codable {
        let windows: [ScreenCaptureWindowInfo]
    }

    private struct ClipboardEnvelope: Codable {
        let clipboard: Bool
        let width: Int
        let height: Int
        let savePath: String?
    }

    // MARK: - 截图到剪贴板

    private static func runClipboardCapture(options: CLIOptions, capture: ScreenCaptureOptions) throws {
        let result = try Clipboard.writeCapture(options: capture)
        let w = result.width
        let h = result.height
        let savePath = result.savedURL?.path

        let payload: String
        switch options.outputMode {
        case .text:
            if let savePath {
                payload = "已复制到剪贴板: \(w)x\(h)  另存: \(savePath)"
            } else {
                payload = "已复制到剪贴板: \(w)x\(h)"
            }
        case .json:
            let env = ClipboardEnvelope(clipboard: true, width: w, height: h, savePath: savePath)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            payload = String(decoding: try encoder.encode(env), as: UTF8.self)
        }
        try emit(payload, to: options.outputPath, quiet: options.quiet)
    }

    // MARK: - 从剪贴板读图 + OCR

    private static func runPasteboardOCR(options: CLIOptions) async throws {
        let cg = try Clipboard.readImage()
        let recognizer = makeRecognizer(options: options)
        let displayPath = "<clipboard> (\(cg.width)x\(cg.height))"
        let (lines, _) = try await processCGImage(
            cg,
            displayPath: displayPath,
            with: recognizer,
            options: options
        )
        let report = OCRReport(imagePath: displayPath, lines: lines)

        let text = CLIOutputRenderer.renderText(report: report, options: options)
        let json = try CLIOutputRenderer.renderJSON(report: report)
        let payload = (options.outputMode == .text) ? text : json
        try emit(payload, to: options.outputPath, quiet: options.quiet)
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

    /// 单文件批处理入口:加载 CGImage → processCGImage → 包装成 OCRBatchItem。
    /// OCR 失败标记 .failure(影响 batch 统计),保存失败只走 stderr 警告(不影响统计)。
    private static func processOne(
        url: URL,
        with recognizer: VisionOCRRecognizer,
        options: CLIOptions
    ) async -> (item: OCRBatchItem, savedURL: URL?) {
        do {
            let cg = try ImageLoader.loadCGImage(from: url)
            let (lines, savedURL) = try await processCGImage(
                cg,
                displayPath: url.path,
                with: recognizer,
                options: options
            )
            return (.success(imagePath: url.path, lines: lines), savedURL)
        } catch {
            return (.failure(imagePath: url.path, error: error), nil)
        }
    }

    /// 单图完整流程:解码出来的 CGImage → (按需)压缩预处理 → OCR → (按需)保存压缩副本。
    /// 抛错表示 OCR 不可恢复(预处理失败也归到 OCR 失败,因为没图可识)。
    /// 保存压缩副本是 best-effort,失败仅写 stderr 警告。
    private static func processCGImage(
        _ cg: CGImage,
        displayPath: String,
        with recognizer: VisionOCRRecognizer,
        options: CLIOptions
    ) async throws -> (lines: [OCRTextLine], savedURL: URL?) {
        // 1. 预处理:压缩到内存中的更小 CGImage,直接喂给 OCR。
        let ocrCG: CGImage
        if let cfg = options.compressionInput {
            ocrCG = try ImageCompressor.compress(cg, format: cfg.format, quality: cfg.quality)
        } else {
            ocrCG = cg
        }

        // 2. OCR
        let lines = try await recognizer.recognizeText(in: ocrCG)

        // 3. 保存压缩副本(best-effort,失败不抛错)
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

        return (lines, savedURL)
    }

    /// 把原文件的 stem 拼上目标目录和压缩格式的扩展名。
    /// 例: `/a/b/photo.png` + `/out` + `.jpeg` → `/out/photo.jpg`
    private static func compressedOutputURL(
        for displayPath: String,
        inDir dir: URL,
        format: ImageFormat
    ) -> URL {
        // displayPath 是 URL.path 形式(不含 file:// 前缀),用 lastPathComponent 拿到文件名。
        let nsPath = displayPath as NSString
        let fullName = nsPath.lastPathComponent
        let stem = (fullName as NSString).deletingPathExtension
        let ext = ImageCompressor.fileExtension(for: format)
        return dir.appendingPathComponent(stem).appendingPathExtension(ext)
    }

    private static func makeRecognizer(options: CLIOptions) -> VisionOCRRecognizer {
        VisionOCRRecognizer(
            recognitionLanguages: options.languages,
            recognitionLevel: options.level,
            usesLanguageCorrection: options.languageCorrection
        )
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
}
