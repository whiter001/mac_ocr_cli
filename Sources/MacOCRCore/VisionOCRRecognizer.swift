import Foundation
import Vision

public enum OCRRecognizerError: Error, LocalizedError {
    case visionFailure(Error)
    case invalidLevel(String)

    public var errorDescription: String? {
        switch self {
        case .visionFailure(let error):
            return "Vision 识别失败: \(error.localizedDescription)"
        case .invalidLevel(let value):
            return "未知的识别等级: \(value)（应为 accurate 或 fast）"
        }
    }
}

public protocol OCRRecognizing {
    func recognizeText(in imageURL: URL) async throws -> [OCRTextLine]
    /// CGImage 重载,给预处理(压缩后再 OCR)路径用,避免重复解码。
    func recognizeText(in cgImage: CGImage) async throws -> [OCRTextLine]
}

/// 把非 Sendable 值显式带进 @Sendable 闭包。Vision 的 request 对象跨线程使用
/// 是安全的(只写一次、之后只读,且 continuation 提供了 happens-before),
/// 用这个 wrapper 把"我确认过"写在代码里,而不是全局压制告警。
struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
}

/// 把 Vision 的原始识别结果整理成稳定、可测试的 `OCRTextLine` 列表。
public final class VisionOCRRecognizer: OCRRecognizing {
    private let recognitionLanguages: [String]
    private let recognitionLevel: VNRequestTextRecognitionLevel
    private let usesLanguageCorrection: Bool
    private let includeWordBoxes: Bool
    private let minimumConfidence: Float

    public init(
        recognitionLanguages: [String] = ["zh-Hans", "en-US"],
        recognitionLevel: VNRequestTextRecognitionLevel = .accurate,
        usesLanguageCorrection: Bool = true,
        includeWordBoxes: Bool = false,
        minimumConfidence: Double = 0
    ) {
        self.recognitionLanguages = recognitionLanguages
        self.recognitionLevel = recognitionLevel
        self.usesLanguageCorrection = usesLanguageCorrection
        self.includeWordBoxes = includeWordBoxes
        // CLI 层已校验 0..1,这里再做一次钳制,库调用方传越界值也不会崩。
        self.minimumConfidence = Float(min(max(minimumConfidence, 0), 1))
    }

    public func recognizeText(in imageURL: URL) async throws -> [OCRTextLine] {
        // URL 版本:先解码成 CGImage,再委托给 CGImage 重载,避免逻辑重复。
        let image = try ImageLoader.loadCGImage(from: imageURL)
        return try await recognizeText(in: image)
    }

    public func recognizeText(in cgImage: CGImage) async throws -> [OCRTextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = recognitionLanguages
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = usesLanguageCorrection

        // Vision 的 `perform` 只有同步版本。同步调用会阻塞当前线程——直接在
        // async 上下文里调会把 Swift 并发协作池的线程占住(批量 4 并发时占满),
        // 所以显式挪到全局队列执行,再用 continuation 接回 async 世界。
        // perform 同步返回,continuation 保证恰好 resume 一次。
        let boxedRequest = UncheckedSendable(value: request)
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([boxedRequest.value])
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            throw OCRRecognizerError.visionFailure(error)
        }

        let observations = request.results ?? []
        // 先过滤(空候选 + 置信度门槛),再重新编号,保证 index 始终稠密 0..n。
        let kept: [(VNRecognizedTextObservation, VNRecognizedText)] = observations.compactMap { observation in
            guard let best = observation.topCandidates(1).first,
                  best.confidence >= minimumConfidence else { return nil }
            return (observation, best)
        }
        return kept.enumerated().map { index, pair in
            OCRTextLine(
                index: index,
                text: pair.1.string,
                confidence: Double(pair.1.confidence),
                boundingBox: OCRBoundingBox(pair.0.boundingBox),
                words: includeWordBoxes ? Self.wordBoxes(for: pair.1) : nil
            )
        }
    }

    /// 把一行文本按空白切成词,逐词向 Vision 取子串边界框。
    /// 取不到框的词(罕见,如合成字符)直接跳过,不让单个词拖垮整行。
    static func wordBoxes(for candidate: VNRecognizedText) -> [OCRWordBox] {
        let text = candidate.string
        var boxes: [OCRWordBox] = []
        var wordStart = text.startIndex
        var i = text.startIndex

        func flush(end: String.Index) {
            guard wordStart < end else { return }
            let range = wordStart..<end
            if let obs = try? candidate.boundingBox(for: range) {
                boxes.append(OCRWordBox(
                    text: String(text[range]),
                    boundingBox: OCRBoundingBox(obs.boundingBox)
                ))
            }
        }

        while i < text.endIndex {
            if text[i].isWhitespace {
                flush(end: i)
                wordStart = text.index(after: i)
            }
            i = text.index(after: i)
        }
        flush(end: text.endIndex)
        return boxes
    }

    /// 指定识别等级在当前系统上支持的语言(BCP-47)。
    /// 用于 `--lang-list` 和 `-l` 的启动校验;API 失败时返回空数组,
    /// 调用方应把空数组视为"无法校验"而不是"不支持任何语言"。
    public static func supportedLanguages(level: VNRequestTextRecognitionLevel) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        return (try? request.supportedRecognitionLanguages()) ?? []
    }
}
