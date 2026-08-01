import CoreImage
import CoreGraphics
import Foundation
import Testing
@testable import MacOCRCore

@Suite("BarcodeRecognizer")
struct BarcodeRecognizerTests {
    /// 用 CoreImage 生成带白边的 QR 码 CGImage(Vision 需要静区)。
    private func makeQR(payload: String) throws -> CGImage {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            Issue.record("CIQRCodeGenerator unavailable")
            throw BarcodeRecognizerError.visionFailure(NSError(domain: "test", code: 1))
        }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ciImage = filter.outputImage else {
            Issue.record("QR filter produced no image")
            throw BarcodeRecognizerError.visionFailure(NSError(domain: "test", code: 2))
        }

        let scale: CGFloat = 12
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let qr = context.createCGImage(scaled, from: scaled.extent) else {
            Issue.record("could not rasterize QR")
            throw BarcodeRecognizerError.visionFailure(NSError(domain: "test", code: 3))
        }

        // 铺白底 + 静区(quiet zone),贴边的 QR 识别率很差。
        let margin = 40
        let size = qr.width + margin * 2
        guard let ctx = CGContext(
            data: nil,
            width: size, height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            Issue.record("could not create canvas")
            throw BarcodeRecognizerError.visionFailure(NSError(domain: "test", code: 4))
        }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.draw(qr, in: CGRect(x: margin, y: margin, width: qr.width, height: qr.height))
        guard let result = ctx.makeImage() else {
            Issue.record("could not compose canvas")
            throw BarcodeRecognizerError.visionFailure(NSError(domain: "test", code: 5))
        }
        return result
    }

    @Test("QR payload round-trips through Vision")
    func qrPayloadRoundTrip() async throws {
        let cg = try makeQR(payload: "hello-mac-ocr")
        let results = try await BarcodeRecognizer().recognizeBarcodes(in: cg)
        #expect(results.count == 1)
        #expect(results.first?.payload == "hello-mac-ocr")
        #expect(results.first?.symbology.contains("QR") == true)
        // 边界框在归一化范围内
        if let box = results.first?.boundingBox {
            #expect(box.width > 0 && box.width <= 1)
            #expect(box.height > 0 && box.height <= 1)
        }
    }

    @Test("Blank image yields zero barcodes, not an error")
    func blankImageNoBarcodes() async throws {
        let ctx = CGContext(
            data: nil, width: 100, height: 100,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let results = try await BarcodeRecognizer().recognizeBarcodes(in: ctx.makeImage()!)
        #expect(results.isEmpty)
    }
}
