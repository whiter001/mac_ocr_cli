import Foundation
import Testing
import CoreGraphics
import ImageIO
@testable import MacOCRCore

@Suite("ImageLoader")
struct ImageLoaderTests {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mac_ocr_cli_tests_\(UUID().uuidString)")

    init() {
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    @Test("Missing file throws .fileNotFound")
    func missingFileThrowsFileNotFound() {
        let url = tempDir.appendingPathComponent("does_not_exist.png")
        #expect(throws: ImageLoaderError.self) {
            _ = try ImageLoader.loadCGImage(from: url)
        }
    }

    @Test("Text file with .png extension throws .decodeFailed")
    func textFileThrowsNotAnImage() throws {
        let url = tempDir.appendingPathComponent("not_image.png")
        try "this is not a png".write(to: url, atomically: true, encoding: .utf8)
        do {
            _ = try ImageLoader.loadCGImage(from: url)
            Issue.record("expected error")
        } catch let error as ImageLoaderError {
            // CGImageSourceCreateWithURL accepts the URL but cannot decode — surfaces as .decodeFailed.
            switch error {
            case .decodeFailed: break
            default: Issue.record("expected .decodeFailed, got \(error)")
            }
        } catch {
            Issue.record("expected ImageLoaderError, got \(error)")
        }
    }

    @Test("Corrupted PNG bytes throw .decodeFailed")
    func corruptedImageBytesThrowDecodeFailed() throws {
        let url = tempDir.appendingPathComponent("corrupt.png")
        // 8-byte PNG signature followed by garbage — ImageIO will fail to decode.
        let bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00]
        try Data(bytes).write(to: url)
        do {
            _ = try ImageLoader.loadCGImage(from: url)
            Issue.record("expected error")
        } catch let error as ImageLoaderError {
            switch error {
            case .decodeFailed: break
            default: Issue.record("expected .decodeFailed, got \(error)")
            }
        } catch {
            Issue.record("expected ImageLoaderError, got \(error)")
        }
    }

    @Test("Valid 2x2 PNG round-trips through ImageLoader")
    func validPNGRoundTrips() throws {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: 2, height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let cg = ctx.makeImage()!

        let url = tempDir.appendingPathComponent("white.png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            Issue.record("could not create PNG destination"); return
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            Issue.record("could not finalize PNG"); return
        }

        let loaded = try ImageLoader.loadCGImage(from: url)
        #expect(loaded.width == 2)
        #expect(loaded.height == 2)
    }

    // MARK: - 1.2.0:降采样 / data 解码

    /// 生成指定尺寸的纯色 PNG 到临时目录。
    private func writePNG(width: Int, height: Int, name: String) throws -> URL {
        let ctx = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = ctx.makeImage()!

        let url = tempDir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            Issue.record("could not finalize PNG")
            throw ImageLoaderError.decodeFailed(url)
        }
        return url
    }

    @Test("maxPixelSize decodes a thumbnail bounded by the long edge")
    func maxPixelSizeThumbnail() throws {
        let url = try writePNG(width: 100, height: 50, name: "wide.png")
        let image = try ImageLoader.loadCGImage(from: url, maxPixelSize: 50)
        #expect(image.width == 50)
        #expect(image.height == 25)
    }

    @Test("maxPixelSize never upscales small images")
    func maxPixelSizeNoUpscale() throws {
        let url = try writePNG(width: 40, height: 30, name: "small.png")
        let image = try ImageLoader.loadCGImage(from: url, maxPixelSize: 200)
        #expect(image.width == 40)
        #expect(image.height == 30)
    }

    @Test("downsample shrinks proportionally, keeps small images as-is")
    func downsampleBehavior() throws {
        let url = try writePNG(width: 200, height: 100, name: "big.png")
        let big = try ImageLoader.loadCGImage(from: url)

        let shrunk = ImageLoader.downsample(big, maxPixelSize: 50)
        #expect(shrunk.width == 50)
        #expect(shrunk.height == 25)

        // 已经小于上限:原样返回(同一个 CGImage)
        let kept = ImageLoader.downsample(big, maxPixelSize: 500)
        #expect(kept.width == 200)
        #expect(kept.height == 100)
    }

    @Test("loadCGImage(fromData:) decodes PNG bytes; empty data throws")
    func fromDataDecoding() throws {
        let url = try writePNG(width: 8, height: 6, name: "bytes.png")
        let data = try Data(contentsOf: url)
        let image = try ImageLoader.loadCGImage(fromData: data)
        #expect(image.width == 8)
        #expect(image.height == 6)

        #expect(throws: ImageLoaderError.self) {
            _ = try ImageLoader.loadCGImage(fromData: Data())
        }
    }
}
