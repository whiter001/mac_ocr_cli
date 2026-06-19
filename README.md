# mac_ocr_cli

基于 [Apple Vision](https://developer.apple.com/documentation/vision) 的 macOS 命令行 OCR 工具。结构和 OCR 实现参考 [whiter001/yangkeduo-swift](https://github.com/whiter001/yangkeduo-swift)。

## 功能

- 读取 PNG / JPEG / HEIC / TIFF / GIF / WebP / PDF 单帧 等常见图片
- 调用 `VNRecognizeTextRequest` 做文字识别，默认简/繁/英三种语言同时识别
- `--cjk` 预设额外增加粤语（香港书面语），覆盖港版 UI
- 输出每行文字、置信度与**归一化**边界框（Vision 原生坐标系，原点在左下角）
- 可选 JSON / 纯文本输出，可写入文件
- 可选关键词搜索并按相关度排序
- **批量**：多张图片、目录递归扫描、stdin 路径列表，并发处理，单张失败不影响其他
- **屏幕截图**：截主屏幕、按窗口标题/ID 截、截屏幕区域;另含 `--window-list` 列出可见窗口
- **剪贴板**：截图到剪贴板(`--clipboard`)、识别剪贴板里的图片(`--from-clipboard`,配合 `Cmd+Shift+Ctrl+4` 使用)

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

# 切换到 CJK 预设（简/繁/港/英）
mac_ocr_cli menu.png --cjk

# 在识别结果里搜索关键词
mac_ocr_cli page.png -k "登录"

# 批量：多张图片（位置参数任意数量）
mac_ocr_cli a.png b.png c.png

# 批量：递归扫描目录
mac_ocr_cli --dir ./shots

# 批量：写到 JSON 文件
mac_ocr_cli --dir ./shots --json -o all.json

# 批量：stdin 路径列表（`find` 风格）
find . -name "*.png" | mac_ocr_cli - --json -o all.json

# stdin 支持注释（#）和空行
cat list.txt | mac_ocr_cli - -l en-US
# list.txt 格式：
#   # 截图
#   /Users/me/Desktop/a.png
#
#   /Users/me/Desktop/b.png

# 截主屏幕并 OCR
mac_ocr_cli --screen

# 截特定窗口（按标题或 app 名匹配）
mac_ocr_cli --window "Safari" --save-screenshot ~/Desktop/shot.png

# 截屏幕区域（左上角原点）
mac_ocr_cli --region 0 0 1200 800

# 列出所有可见窗口（用于查找要截的窗口）
mac_ocr_cli --window-list

# 截图到剪贴板（不跑 OCR,粘到聊天/邮件直接用）
mac_ocr_cli --clipboard
mac_ocr_cli --clipboard --region 0 0 1200 800    # 截区域
mac_ocr_cli --clipboard --window "Safari"        # 截特定窗口

# 识别剪贴板里的图片（先用系统截图快捷键 Cmd+Shift+Ctrl+4 截到剪贴板）
mac_ocr_cli --from-clipboard
mac_ocr_cli --from-clipboard -k "订单号"          # 边识别边搜关键词
```

> **剪贴板权限**：剪贴板读写**不需要**任何额外权限（TCC 不管这个）。`--clipboard` 仍需要「屏幕录制」权限,因为内部还是先截图再写入。

> **截图权限**：macOS 10.15+ 需要「屏幕录制」权限（系统设置 → 隐私与安全性）。首次运行 Terminal / iTerm / 其他调用本工具的程序时会被提示授权,或在隐私设置中手动允许。授权后 `CGWindowListCreateImage` 即可工作;未授权时 `--window-list` 返回空,`--screen` 等会返回 nil。

## 输出结构（JSON）

**单文件模式**（输入只有 1 张图，schema 保持向后兼容）：

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

**批量模式**（≥ 2 张图或 `--dir`）：

```json
{
  "items": [
    {
      "imagePath": "/abs/path/to/a.png",
      "status": "ok",
      "lines": [ { "index": 0, "text": "...", "confidence": 0.9, "boundingBox": {...} } ]
    },
    {
      "imagePath": "/abs/path/to/b.png",
      "status": "failed",
      "errorMessage": "图片解码失败（文件可能已损坏）: ..."
    }
  ]
}
```

- 每项的 `status` 为 `ok` 或 `failed`；失败时 `lines` 为 `null`、有 `errorMessage`。
- 批量模式并发上限为 `min(4, 核数)`,输出顺序与输入一致。
- 批量模式在任一项失败时以 exit code **2** 退出,便于 shell 脚本判断。

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
