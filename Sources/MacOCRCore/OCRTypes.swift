import CoreGraphics
import Foundation

/// Vision 框架 OCR 识别结果的边界框。
///
/// ⚠️ 坐标系说明（来自 `VNRecognizedTextObservation.boundingBox`）：
/// - 所有字段均为**归一化坐标**，取值范围 `[0, 1]`。
/// - 原点位于图像**左下角**，Y 轴向上增大（与 UIKit/屏幕坐标系相反）。
///
/// 若需将边界框转换为屏幕像素坐标以执行鼠标点击，需进行以下步骤：
/// 1. 乘以图像实际分辨率（宽/高）得到像素坐标；
/// 2. 翻转 Y 轴：`screenY = imageHeight - (ocrY + ocrHeight)`；
/// 3. 考虑 HiDPI 缩放因子（`NSScreen.main?.backingScaleFactor`）。
public struct OCRBoundingBox: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height
        )
    }
}

/// 词级边界框（`--word-boxes`）。行内按空白切词,逐词向 Vision 取子串框。
/// CJK 文本没有空格,一行往往就是一个词——需要更细粒度时请用行级框自行切分。
public struct OCRWordBox: Codable, Hashable, Sendable {
    public let text: String
    public let boundingBox: OCRBoundingBox

    public init(text: String, boundingBox: OCRBoundingBox) {
        self.text = text
        self.boundingBox = boundingBox
    }
}

public struct OCRTextLine: Codable, Hashable, Sendable {
    public let index: Int
    public let text: String
    public let confidence: Double
    public let boundingBox: OCRBoundingBox
    /// 词级框,仅 `--word-boxes` 时非 nil。
    public let words: [OCRWordBox]?

    public init(
        index: Int,
        text: String,
        confidence: Double,
        boundingBox: OCRBoundingBox,
        words: [OCRWordBox]? = nil
    ) {
        self.index = max(0, index)
        self.text = text
        self.confidence = Self.sanitize(confidence)
        self.boundingBox = OCRBoundingBox(
            x: Self.sanitize(boundingBox.x),
            y: Self.sanitize(boundingBox.y),
            width: Self.sanitize(abs(boundingBox.width)),
            height: Self.sanitize(abs(boundingBox.height))
        )
        self.words = words
    }

    private static func sanitize(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

/// 批量关键词模式下每张图的命中记录（`-k` 与批量组合时写入 JSON）。
public struct OCRKeywordMatch: Codable, Hashable, Sendable {
    public let index: Int
    public let score: Double
    public let text: String

    public init(index: Int, score: Double, text: String) {
        self.index = index
        self.score = score
        self.text = text
    }
}

public struct OCRReport: Codable, Hashable, Sendable {
    public let imagePath: String
    public let lines: [OCRTextLine]
    /// 可选元数据：图像尺寸(像素)与 OCR 耗时(毫秒)。旧版输出没有这些键,
    /// 解码端按可选字段处理即可向后兼容。
    public let imageWidth: Int?
    public let imageHeight: Int?
    public let durationMilliseconds: Int?

    public init(
        imagePath: String,
        lines: [OCRTextLine],
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        durationMilliseconds: Int? = nil
    ) {
        self.imagePath = imagePath
        self.lines = lines
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.durationMilliseconds = durationMilliseconds
    }
}

/// 批量模式下的单个结果。一张图片要么是 `status: .ok` 并带 `lines`,
/// 要么是 `status: .failed` 并带 `errorMessage`——二选一,永不同时为 nil。
public struct OCRBatchItem: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable {
        case ok
        case failed
    }

    public let imagePath: String
    public let status: Status
    public let lines: [OCRTextLine]?
    public let errorMessage: String?
    /// 批量 `-k` 时的命中列表(已按分数降序),未启用关键词时为 nil。
    public let keywordMatches: [OCRKeywordMatch]?
    /// 与 `OCRReport` 相同的可选元数据。
    public let imageWidth: Int?
    public let imageHeight: Int?
    public let durationMilliseconds: Int?

    public init(
        imagePath: String,
        status: Status,
        lines: [OCRTextLine]?,
        errorMessage: String?,
        keywordMatches: [OCRKeywordMatch]? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        durationMilliseconds: Int? = nil
    ) {
        self.imagePath = imagePath
        self.status = status
        self.lines = lines
        self.errorMessage = errorMessage
        self.keywordMatches = keywordMatches
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.durationMilliseconds = durationMilliseconds
    }

    public static func success(
        imagePath: String,
        lines: [OCRTextLine],
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        durationMilliseconds: Int? = nil
    ) -> OCRBatchItem {
        OCRBatchItem(
            imagePath: imagePath,
            status: .ok,
            lines: lines,
            errorMessage: nil,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            durationMilliseconds: durationMilliseconds
        )
    }

    public static func failure(imagePath: String, error: Error) -> OCRBatchItem {
        OCRBatchItem(
            imagePath: imagePath,
            status: .failed,
            lines: nil,
            errorMessage: error.localizedDescription
        )
    }

    /// 附加关键词命中(批量 `-k` 用)。失败项原样返回。
    public func addingKeywordMatches(_ matches: [OCRKeywordMatch]) -> OCRBatchItem {
        OCRBatchItem(
            imagePath: imagePath,
            status: status,
            lines: lines,
            errorMessage: errorMessage,
            keywordMatches: matches,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            durationMilliseconds: durationMilliseconds
        )
    }
}

public struct OCRBatchReport: Codable, Hashable, Sendable {
    public let items: [OCRBatchItem]

    public init(items: [OCRBatchItem]) {
        self.items = items
    }

    public var successCount: Int { items.lazy.filter { $0.status == .ok }.count }
    public var failureCount: Int { items.lazy.filter { $0.status == .failed }.count }
}

// MARK: - 条码 / 二维码

/// `VNDetectBarcodesRequest` 的单条识别结果。条码没有置信度概念,
/// 边界框与 OCR 同一坐标系(归一化,原点左下角)。
public struct OCRBarcode: Codable, Hashable, Sendable {
    /// Vision 的 symbology 原始值,如 `VNBarcodeSymbologyQR` / `VNBarcodeSymbologyCode128`。
    public let symbology: String
    public let payload: String
    public let boundingBox: OCRBoundingBox

    public init(symbology: String, payload: String, boundingBox: OCRBoundingBox) {
        self.symbology = symbology
        self.payload = payload
        self.boundingBox = boundingBox
    }
}

public struct BarcodeReport: Codable, Hashable, Sendable {
    public let imagePath: String
    public let barcodes: [OCRBarcode]
    public let imageWidth: Int?
    public let imageHeight: Int?
    public let durationMilliseconds: Int?

    public init(
        imagePath: String,
        barcodes: [OCRBarcode],
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        durationMilliseconds: Int? = nil
    ) {
        self.imagePath = imagePath
        self.barcodes = barcodes
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.durationMilliseconds = durationMilliseconds
    }
}

/// 条码批量模式的单项,与 `OCRBatchItem` 同构(ok / failed 二选一)。
public struct BarcodeBatchItem: Codable, Hashable, Sendable {
    public let imagePath: String
    public let status: OCRBatchItem.Status
    public let barcodes: [OCRBarcode]?
    public let errorMessage: String?
    public let imageWidth: Int?
    public let imageHeight: Int?
    public let durationMilliseconds: Int?

    public init(
        imagePath: String,
        status: OCRBatchItem.Status,
        barcodes: [OCRBarcode]?,
        errorMessage: String?,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        durationMilliseconds: Int? = nil
    ) {
        self.imagePath = imagePath
        self.status = status
        self.barcodes = barcodes
        self.errorMessage = errorMessage
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.durationMilliseconds = durationMilliseconds
    }

    public static func success(
        imagePath: String,
        barcodes: [OCRBarcode],
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        durationMilliseconds: Int? = nil
    ) -> BarcodeBatchItem {
        BarcodeBatchItem(
            imagePath: imagePath,
            status: .ok,
            barcodes: barcodes,
            errorMessage: nil,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            durationMilliseconds: durationMilliseconds
        )
    }

    public static func failure(imagePath: String, error: Error) -> BarcodeBatchItem {
        BarcodeBatchItem(
            imagePath: imagePath,
            status: .failed,
            barcodes: nil,
            errorMessage: error.localizedDescription
        )
    }
}

public struct BarcodeBatchReport: Codable, Hashable, Sendable {
    public let items: [BarcodeBatchItem]

    public init(items: [BarcodeBatchItem]) {
        self.items = items
    }

    public var successCount: Int { items.lazy.filter { $0.status == .ok }.count }
    public var failureCount: Int { items.lazy.filter { $0.status == .failed }.count }
}
