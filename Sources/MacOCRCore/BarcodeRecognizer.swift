import Foundation
import Vision

public enum BarcodeRecognizerError: Error, LocalizedError {
    case visionFailure(Error)

    public var errorDescription: String? {
        switch self {
        case .visionFailure(let error):
            return "Vision 条码识别失败: \(error.localizedDescription)"
        }
    }
}

/// 条码 / 二维码识别(QR、Code128、EAN、Aztec、DataMatrix 等,
/// 具体支持集由 `VNDetectBarcodesRequest` 决定)。与 OCR 管线同构:
/// CGImage 进,结构化结果出,条码没有置信度字段。
public final class BarcodeRecognizer {
    public init() {}

    public func recognizeBarcodes(in cgImage: CGImage) async throws -> [OCRBarcode] {
        let request = VNDetectBarcodesRequest()
        let boxedRequest = UncheckedSendable(value: request)
        // Vision 的 `perform` 只有同步版本,显式挪到全局队列避免阻塞协作池线程。
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
            throw BarcodeRecognizerError.visionFailure(error)
        }

        let observations = request.results ?? []
        return observations.compactMap { observation in
            guard let payload = observation.payloadStringValue, !payload.isEmpty else {
                return nil
            }
            return OCRBarcode(
                symbology: observation.symbology.rawValue,
                payload: payload,
                boundingBox: OCRBoundingBox(observation.boundingBox)
            )
        }
    }

    public func recognizeBarcodes(in imageURL: URL) async throws -> [OCRBarcode] {
        let image = try ImageLoader.loadCGImage(from: imageURL)
        return try await recognizeBarcodes(in: image)
    }
}
