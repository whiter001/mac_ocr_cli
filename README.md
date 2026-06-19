# mac_ocr_cli

基于 [Apple Vision](https://developer.apple.com/documentation/vision) 的 macOS 命令行 OCR 工具。结构和 OCR 实现参考 [whiter001/yangkeduo-swift](https://github.com/whiter001/yangkeduo-swift)。

## 功能

- 读取 PNG / JPEG / HEIC / TIFF / GIF / WebP / PDF 单帧 等常见图片
- 调用 `VNRecognizeTextRequest` 做文字识别，支持中英文混排
- 输出每行文字、置信度与**归一化**边界框（Vision 原生坐标系，原点在左下角）
- 可选 JSON / 纯文本输出，可写入文件
- 可选关键词搜索并按相关度排序

## 编译

需要 macOS 13+ 与 Swift 5.9+（或 Xcode 15+）：

```bash
swift build -c release
```

可执行文件位于 `.build/release/mac_ocr_cli`。

## 用法

```bash
# 识别一张图（默认输出纯文本）
mac_ocr_cli photo.png

# 用 JSON 输出并写入文件
mac_ocr_cli shot.jpg --json -o result.json

# 改识别语言
mac_ocr_cli menu.png -l en-US

# 用 fast 模式（更快但精度略低）
mac_ocr_cli menu.png --level fast

# 关闭语言纠错（适合代码 / 编号）
mac_ocr_cli code.png --no-correction

# 在识别结果里搜索关键词
mac_ocr_cli page.png -k "登录"
```

## 输出结构（JSON）

```json
{
  "imagePath": "/abs/path/to.png",
  "lines": [
    {
      "index": 0,
      "text": "示例文本",
      "confidence": 0.87,
      "boundingBox": { "x": 0.1, "y": 0.2, "width": 0.5, "height": 0.05 }
    }
  ]
}
```

`boundingBox` 字段均为 `[0, 1]` 归一化值，原点在图像**左下角**（Vision 的 `VNRecognizedTextObservation` 默认行为）。需要屏幕像素坐标时：

1. 乘以图像实际宽高；
2. 翻转 Y 轴：`screenY = imageHeight - (ocrY + ocrHeight)`；
3. 考虑 `NSScreen.main?.backingScaleFactor`。

## 依赖

零运行时依赖 —— 仅使用系统框架：

- `Foundation`
- `CoreGraphics`
- `ImageIO`
- `Vision`
