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
            try await run(options: options)
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

    // MARK: - 入口分发

    private static func run(options: CLIOptions) async throws {
        if options.isSingleImage {
            try await runSingle(options: options)
        } else {
            try await runBatch(options: options)
        }
    }

    // MARK: - 单文件(向后兼容)

    private static func runSingle(options: CLIOptions) async throws {
        let url = options.imageURLs[0]
        let recognizer = makeRecognizer(options: options)
        let lines = try await recognizer.recognizeText(in: url)
        let report = OCRReport(imagePath: url.path, lines: lines)

        let text = CLIOutputRenderer.renderText(report: report, options: options)
        let json = try CLIOutputRenderer.renderJSON(report: report)

        let payload: String
        switch options.outputMode {
        case .text: payload = text
        case .json: payload = json
        }
        try emit(payload, to: options.outputPath)
    }

    // MARK: - 批量

    private static func runBatch(options: CLIOptions) async throws {
        let recognizer = makeRecognizer(options: options)

        // TaskGroup 保持输入顺序,所以输出稳定。
        let items: [OCRBatchItem] = await withTaskGroup(of: (Int, OCRBatchItem).self) { group in
            var nextIndex = 0
            var capacity = maxConcurrentImages
            var collected: [(Int, OCRBatchItem)] = []

            // 启动前 capacity 个 worker
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

            // 任一 worker 完成就启动下一个,保持并发稳定
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

            return collected
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }

        let batch = OCRBatchReport(items: items)

        let text = CLIOutputRenderer.renderBatchText(batch: batch)
        let json = try CLIOutputRenderer.renderBatchJSON(batch: batch)

        let payload: String
        switch options.outputMode {
        case .text: payload = text
        case .json: payload = json
        }
        try emit(payload, to: options.outputPath)

        // 批量模式下,只要有失败就以非 0 退出,便于 shell 脚本判断
        if batch.failureCount > 0 {
            exit(2)
        }
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
