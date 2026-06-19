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
}

/// 把 Vision 的原始识别结果整理成稳定、可测试的 `OCRTextLine` 列表。
public final class VisionOCRRecognizer: OCRRecognizing {
    private let recognitionLanguages: [String]
    private let recognitionLevel: VNRequestTextRecognitionLevel
    private let usesLanguageCorrection: Bool

    public init(
        recognitionLanguages: [String] = ["zh-Hans", "en-US"],
        recognitionLevel: VNRequestTextRecognitionLevel = .accurate,
        usesLanguageCorrection: Bool = true
    ) {
        self.recognitionLanguages = recognitionLanguages
        self.recognitionLevel = recognitionLevel
        self.usesLanguageCorrection = usesLanguageCorrection
    }

    public func recognizeText(in imageURL: URL) async throws -> [OCRTextLine] {
        // 先把图片载入成 CGImage，再交给 Vision 做文字识别。
        let image = try ImageLoader.loadCGImage(from: imageURL)

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false

            func finish(_ result: Result<[OCRTextLine], Error>) {
                guard !didResume else { return }
                didResume = true
                switch result {
                case .success(let lines):
                    continuation.resume(returning: lines)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    finish(.failure(OCRRecognizerError.visionFailure(error)))
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines: [OCRTextLine] = observations.enumerated().compactMap { index, observation in
                    guard let bestCandidate = observation.topCandidates(1).first else {
                        return nil
                    }
                    return OCRTextLine(
                        index: index,
                        text: bestCandidate.string,
                        confidence: Double(bestCandidate.confidence),
                        boundingBox: OCRBoundingBox(observation.boundingBox)
                    )
                }

                finish(.success(lines))
            }

            request.recognitionLanguages = recognitionLanguages
            request.recognitionLevel = recognitionLevel
            request.usesLanguageCorrection = usesLanguageCorrection

            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                finish(.failure(OCRRecognizerError.visionFailure(error)))
            }
        }
    }
}
