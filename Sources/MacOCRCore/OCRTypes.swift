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

public struct OCRTextLine: Codable, Hashable, Sendable {
    public let index: Int
    public let text: String
    public let confidence: Double
    public let boundingBox: OCRBoundingBox

    public init(index: Int, text: String, confidence: Double, boundingBox: OCRBoundingBox) {
        self.index = max(0, index)
        self.text = text
        self.confidence = Self.sanitize(confidence)
        self.boundingBox = OCRBoundingBox(
            x: Self.sanitize(boundingBox.x),
            y: Self.sanitize(boundingBox.y),
            width: Self.sanitize(abs(boundingBox.width)),
            height: Self.sanitize(abs(boundingBox.height))
        )
    }

    private static func sanitize(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public struct OCRReport: Codable, Hashable, Sendable {
    public let imagePath: String
    public let lines: [OCRTextLine]

    public init(imagePath: String, lines: [OCRTextLine]) {
        self.imagePath = imagePath
        self.lines = lines
    }
}
