import Foundation
import Testing
import CoreGraphics
import ImageIO
@testable import MacOCRCore

@Suite("ImageCompressor")
struct ImageCompressorTests {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mac_ocr_cli_compressor_\(UUID().uuidString)")

    init() {
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    /// 生成一张 100x100 红底 RGB 图片,用作压缩测试的输入。
    /// 比 2x2 大一些是为了让有损压缩的体积差异肉眼可辨。
    private func makeTestImage() -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: 100, height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 400,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        return ctx.makeImage()!
    }

    // MARK: - resolveQuality

    @Test("resolveQuality maps preset high to 0.85")
    func resolveHighPreset() throws {
        #expect(try ImageCompressor.resolveQuality("high") == 0.85)
    }

    @Test("resolveQuality maps preset medium to 0.70")
    func resolveMediumPreset() throws {
        #expect(try ImageCompressor.resolveQuality("medium") == 0.70)
    }

    @Test("resolveQuality maps preset low to 0.50")
    func resolveLowPreset() throws {
        #expect(try ImageCompressor.resolveQuality("low") == 0.50)
    }

    @Test("resolveQuality accepts numeric value in range")
    func resolveNumericQuality() throws {
        #expect(try ImageCompressor.resolveQuality("0.42") == 0.42)
        #expect(try ImageCompressor.resolveQuality("0") == 0)
        #expect(try ImageCompressor.resolveQuality("1") == 1)
    }

    @Test("resolveQuality throws on unknown preset")
    func resolveQualityRejectsUnknownPreset() {
        #expect(throws: CLIError.self) {
            _ = try ImageCompressor.resolveQuality("foo")
        }
    }

    @Test("resolveQuality throws on out-of-range numeric")
    func resolveQualityRejectsOutOfRange() {
        #expect(throws: CLIError.self) {
            _ = try ImageCompressor.resolveQuality("2.0")
        }
        #expect(throws: CLIError.self) {
            _ = try ImageCompressor.resolveQuality("-0.1")
        }
    }

    @Test("resolveQuality throws on non-numeric garbage")
    func resolveQualityRejectsGarbage() {
        #expect(throws: CLIError.self) {
            _ = try ImageCompressor.resolveQuality("abc123")
        }
    }

    // MARK: - fileExtension

    @Test("fileExtension maps jpeg to jpg")
    func extensionJpeg() {
        #expect(ImageCompressor.fileExtension(for: .jpeg) == "jpg")
    }

    @Test("fileExtension maps webp / heic / png directly")
    func extensionOthers() {
        #expect(ImageCompressor.fileExtension(for: .webp) == "webp")
        #expect(ImageCompressor.fileExtension(for: .heic) == "heic")
        #expect(ImageCompressor.fileExtension(for: .png) == "png")
    }

    // MARK: - encode round-trips

    @Test("Encode to JPEG, reload, dimensions preserved")
    func encodeJPEGRoundTrip() throws {
        let cg = makeTestImage()
        let url = tempDir.appendingPathComponent("red.jpg")
        try ImageCompressor.encode(cg, to: url, format: .jpeg, quality: 0.5)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let loaded = try ImageLoader.loadCGImage(from: url)
        #expect(loaded.width == 100)
        #expect(loaded.height == 100)
    }

    @Test("Encode to PNG, reload, dimensions preserved (lossless)")
    func encodePNGRoundTrip() throws {
        let cg = makeTestImage()
        let url = tempDir.appendingPathComponent("red.png")
        try ImageCompressor.encode(cg, to: url, format: .png, quality: 0.5)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let loaded = try ImageLoader.loadCGImage(from: url)
        #expect(loaded.width == 100)
        #expect(loaded.height == 100)
    }

    @Test("Encode to HEIC, reload, dimensions preserved")
    func encodeHEICRoundTrip() throws {
        let cg = makeTestImage()
        let url = tempDir.appendingPathComponent("red.heic")
        try ImageCompressor.encode(cg, to: url, format: .heic, quality: 0.5)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let loaded = try ImageLoader.loadCGImage(from: url)
        #expect(loaded.width == 100)
        #expect(loaded.height == 100)
    }

    @Test("Encode to WebP (macOS 14+ with WebP encoder), reload, dimensions preserved")
    func encodeWebPRoundTrip() throws {
        guard #available(macOS 14, *) else { return }
        let cg = makeTestImage()
        let url = tempDir.appendingPathComponent("red.webp")
        // 部分 macOS 14 系统的 ImageIO 没有挂上 WebP encoder(返回 nil)。
        // 这里用 try? 容忍这种情况,只在编码成功时才校验尺寸。
        try? ImageCompressor.encode(cg, to: url, format: .webp, quality: 0.5)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let loaded = try ImageLoader.loadCGImage(from: url)
        #expect(loaded.width == 100)
        #expect(loaded.height == 100)
    }

    // MARK: - filesystem behavior

    @Test("Encode auto-creates parent directory")
    func encodeCreatesParentDir() throws {
        let cg = makeTestImage()
        let nestedDir = tempDir.appendingPathComponent("a/b/c")
        let url = nestedDir.appendingPathComponent("x.jpg")
        try ImageCompressor.encode(cg, to: url, format: .jpeg, quality: 0.7)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Encode overwrites existing file without error")
    func encodeOverwrites() throws {
        let cg = makeTestImage()
        let url = tempDir.appendingPathComponent("overwrite.jpg")
        // 先写一次
        try ImageCompressor.encode(cg, to: url, format: .jpeg, quality: 0.9)
        let firstSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        #expect(firstSize > 0)
        // 再次写(应覆盖,不抛错)
        try ImageCompressor.encode(cg, to: url, format: .jpeg, quality: 0.3)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("JPEG with low quality produces smaller file than high quality")
    func lossyQualityAffectsSize() throws {
        let cg = makeTestImage()
        let highURL = tempDir.appendingPathComponent("high.jpg")
        let lowURL = tempDir.appendingPathComponent("low.jpg")
        try ImageCompressor.encode(cg, to: highURL, format: .jpeg, quality: 0.95)
        try ImageCompressor.encode(cg, to: lowURL, format: .jpeg, quality: 0.05)
        let highSize = (try FileManager.default.attributesOfItem(atPath: highURL.path)[.size] as? Int) ?? 0
        let lowSize = (try FileManager.default.attributesOfItem(atPath: lowURL.path)[.size] as? Int) ?? 0
        #expect(highSize > 0)
        #expect(lowSize > 0)
        #expect(lowSize < highSize)
    }
}