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
        try emit(payload, to: options.outputPath)
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

        // 把截图后的 PNG 当作单文件 OCR 输入
        let singleOptions = CLIOptions(
            imageURLs: [pngURL],
            languages: options.languages,
            level: options.level,
            languageCorrection: options.languageCorrection,
            outputMode: options.outputMode,
            outputPath: options.outputPath,
            keyword: nil
        )
        let recognizer = makeRecognizer(options: singleOptions)
        let lines = try await recognizer.recognizeText(in: pngURL)
        let report = OCRReport(imagePath: pngURL.path, lines: lines)

        let text = CLIOutputRenderer.renderText(report: report, options: singleOptions)
        let json = try CLIOutputRenderer.renderJSON(report: report)
        let payload = (singleOptions.outputMode == .text) ? text : json
        try emit(payload, to: singleOptions.outputPath)
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
        let lines = try await recognizer.recognizeText(in: url)
        let report = OCRReport(imagePath: url.path, lines: lines)

        let text = CLIOutputRenderer.renderText(report: report, options: options)
        let json = try CLIOutputRenderer.renderJSON(report: report)
        let payload = (options.outputMode == .text) ? text : json
        try emit(payload, to: options.outputPath)
    }

    private static func runBatchFiles(options: CLIOptions) async throws {
        let recognizer = makeRecognizer(options: options)

        let items: [OCRBatchItem] = await withTaskGroup(of: (Int, OCRBatchItem).self) { group in
            var nextIndex = 0
            var capacity = maxConcurrentImages
            var collected: [(Int, OCRBatchItem)] = []

            while capacity > 0, nextIndex < options.imageURLs.count {
                let url = options.imageURLs[nextIndex]
                let index = nextIndex
                nextIndex += 1
                capacity -= 1
                group.addTask {
                    let item = await recognizeOne(url: url, with: recognizer)
                    return (index, item)
                }
            }

            while let (index, item) = await group.next() {
                collected.append((index, item))
                if nextIndex < options.imageURLs.count {
                    let url = options.imageURLs[nextIndex]
                    let next = nextIndex
                    nextIndex += 1
                    group.addTask {
                        let item = await recognizeOne(url: url, with: recognizer)
                        return (next, item)
                    }
                }
            }

            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }

        let batch = OCRBatchReport(items: items)
        let text = CLIOutputRenderer.renderBatchText(batch: batch)
        let json = try CLIOutputRenderer.renderBatchJSON(batch: batch)
        let payload = (options.outputMode == .text) ? text : json
        try emit(payload, to: options.outputPath)

        if batch.failureCount > 0 { exit(2) }
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
        let (w, h) = try Clipboard.writeCapture(options: capture)
        let savePath = capture.savePath?.path

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
        try emit(payload, to: options.outputPath)
    }

    // MARK: - 从剪贴板读图 + OCR

    private static func runPasteboardOCR(options: CLIOptions) async throws {
        let cg = try Clipboard.readImage()

        // CGImage → Data → 临时 PNG → Vision 走标准管线
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let pngData = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
            throw ClipboardError.readDecodeFailed("无法把剪贴板图片编码为 PNG")
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac_ocr_cli-pasteboard-\(UUID().uuidString)")
            .appendingPathExtension("png")
        try pngData.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let recognizer = makeRecognizer(options: options)
        let lines = try await recognizer.recognizeText(in: tmp)
        let report = OCRReport(imagePath: "<clipboard> (\(cg.width)x\(cg.height))", lines: lines)

        let text = CLIOutputRenderer.renderText(report: report, options: options)
        let json = try CLIOutputRenderer.renderJSON(report: report)
        let payload = (options.outputMode == .text) ? text : json
        try emit(payload, to: options.outputPath)
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

    private static func recognizeOne(url: URL, with recognizer: VisionOCRRecognizer) async -> OCRBatchItem {
        do {
            let lines = try await recognizer.recognizeText(in: url)
            return .success(imagePath: url.path, lines: lines)
        } catch {
            return .failure(imagePath: url.path, error: error)
        }
    }

    private static func makeRecognizer(options: CLIOptions) -> VisionOCRRecognizer {
        VisionOCRRecognizer(
            recognitionLanguages: options.languages,
            recognitionLevel: options.level,
            usesLanguageCorrection: options.languageCorrection
        )
    }

    private static func emit(_ payload: String, to outputPath: URL?) throws {
        if let outputPath {
            try FileManager.default.createDirectory(
                at: outputPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try payload.write(to: outputPath, atomically: true, encoding: .utf8)
        }
        print(payload)
    }

    /// 从 stdin 读取全部 UTF-8 文本。TTY 模式下返回 nil(避免挂起)。
    private static func readStdin() -> String? {
        if isatty(STDIN_FILENO) != 0 { return nil }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
