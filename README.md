# mac_ocr_cli

基于 [Apple Vision](https://developer.apple.com/documentation/vision) 的 macOS 命令行 OCR 工具。

## 功能

- 读取 PNG / JPEG / HEIC / TIFF / GIF / WebP / BMP / **PDF(逐页)** 等常见图片
- 调用 `VNRecognizeTextRequest` 做文字识别，默认简/繁/英三种语言同时识别
- `--cjk` 预设额外增加粤语（香港书面语），覆盖港版 UI
- `-l` 语言标签在启动时按系统支持列表校验, typo 直接报错;`--lang-list` 可查看全部支持语言
- 输出每行文字、置信度与**归一化**边界框（Vision 原生坐标系，原点在左下角）
- `--word-boxes` 附加词级边界框(按空白切词),支撑 UI 自动化点击场景
- `--min-confidence` 按置信度过滤低质量行
- 可选 JSON / 纯文本 / `--plain`(裸文本,grep 友好) 输出，可写入文件
- 可选关键词搜索并按相关度排序,**单文件和批量均可**;`--plain` 只输出命中行,`--json` 附带 `keywordMatches` 字段
- **批量**：多张图片、目录递归扫描、stdin 路径列表，并发处理(`--concurrency` 可调)，单张失败不影响其他
- **`--jsonl` 流式输出**:批量模式每完成一张写一行 JSON,大目录下内存占用与规模无关;配 `-o` 时只写文件(不再往 stdout 重复输出)
- **`--barcode` 条码/二维码识别**(QR、Code128、EAN 等),单张/批量/JSONL 同构
- **`--max-dimension` 解码期降采样**:大图(5K 截图、扫描件)内存和耗时成倍下降
- **屏幕截图**：截屏(支持 `--display` 选副屏)、按窗口标题/ID 截、截屏幕区域;另含 `--window-list` / `--display-list`;macOS 14+ 走 ScreenCaptureKit
- **剪贴板**：截图到剪贴板(`--clipboard`)、识别剪贴板里的图片(`--from-clipboard`)、识别结果写回剪贴板(`--to-clipboard`)
- **`--stdin-image`**:从 stdin 直接读图片字节,嵌入 Unix 管道
- **进度** + **`--quiet`**:批量模式默认在 stderr 打印每张完成进度(`[2/5] a.png  ok  3 lines`)和汇总;`--quiet` 抑制所有非错误输出,适合脚本和管道

## 编译

需要 macOS 13+ 与 Swift 5.9+（或 Xcode 15+）：

```bash
swift build -c release
```

可执行文件位于 `.build/release/mac_ocr_cli`。

## 安装(从 release)

```bash
# 下载预编译的 universal binary
curl -L -o mac_ocr_cli.zip \
  https://github.com/whiter001/mac_ocr_cli/releases/latest/download/mac_ocr_cli-darwin-universal.zip
unzip mac_ocr_cli.zip

# 移除 macOS 隔离标记(因为二进制未签名)
xattr -d com.apple.quarantine mac_ocr_cli-darwin-universal/mac_ocr_cli

# 放到 PATH
sudo mv mac_ocr_cli-darwin-universal/mac_ocr_cli /usr/local/bin/

# 验证
mac_ocr_cli --version
```

## 安装(用 install 脚本 + Claude Code skill)

`scripts/install.sh` 是单文件安装器,默认下载最新 release,顺带把 [Claude Code skill](skill/SKILL.md) 装到 `~/.claude/skills/mac-ocr-cli/`(让 Claude 知道怎么用这个工具)。

```bash
# 默认:下载最新 release,装到 ~/.local/bin,装 skill 到 ~/.claude/skills/mac-ocr-cli
./scripts/install.sh

# 从当前 checkout 编译安装(给开发者用)
./scripts/install.sh --from-source

# 装到 /usr/local 而不是 ~/.local(需要 sudo)
sudo PREFIX=/usr/local ./scripts/install.sh

# 装特定版本
./scripts/install.sh --version v0.1.0

# 卸载(同时移除 binary 和 skill)
./scripts/install.sh --uninstall
```

## 发布流程

`.github/workflows/release.yml` 在每次推送 `v*` tag 时自动:

1. 在 `macos-15` 上跑 `swift build` + `swift test`(164 个用例)
2. 用 tag 版本号注入 `--version` 输出
3. 分别编译 arm64 和 x86_64 release binary
4. 用 `lipo -create` 合成 universal binary
5. 冒烟测试(`--version` / `--help` / `--window-list` / `--display-list` / `--lang-list`)
6. 把 `mac_ocr_cli-darwin-universal.zip` 上传到 GitHub Release
7. 自动生成 release notes(包含安装指令和 quarantine 提示)

发版:

```bash
git tag v0.1.0
git push origin v0.1.0
```

## 用法

```bash
# 识别一张图（默认输出纯文本）
mac_ocr_cli photo.png

# 用 JSON 输出并写入文件
mac_ocr_cli shot.jpg --json -o result.json

# 改识别语言(启动时校验,typo 会报错并提示 --lang-list)
mac_ocr_cli menu.png -l en-US

# 查看当前系统支持的识别语言
mac_ocr_cli --lang-list

# 用 fast 模式（更快但精度略低）
mac_ocr_cli menu.png --level fast

# 关闭语言纠错（适合代码 / 编号）
mac_ocr_cli code.png --no-correction

# 只保留置信度 >= 0.8 的行
mac_ocr_cli page.png --min-confidence 0.8

# 切换到 CJK 预设（简/繁/港/英）
mac_ocr_cli menu.png --cjk

# 在识别结果里搜索关键词(单文件和批量均可)
mac_ocr_cli page.png -k "登录"
mac_ocr_cli --dir ./shots -k "订单号"

# 大图降采样:长边压到 2048px 再识别,显著降低内存和耗时
mac_ocr_cli big_scan.png --max-dimension 2048

# 词级边界框(UI 自动化点击用)
mac_ocr_cli ui.png --word-boxes --json

# 条码 / 二维码识别
mac_ocr_cli qr.png --barcode
mac_ocr_cli --dir ./labels --barcode --json

# 批量：多张图片（位置参数任意数量）
mac_ocr_cli a.png b.png c.png

# 批量：递归扫描目录
mac_ocr_cli --dir ./shots

# 批量：写到 JSON 文件
mac_ocr_cli --dir ./shots --json -o all.json

# 批量:流式 JSONL,每完成一张写一行(大目录内存友好)
# 配 -o 时只写文件,stdout 不重复输出
mac_ocr_cli --dir ./shots --jsonl -o all.jsonl

# 批量：stdin 路径列表（`find` 风格）
find . -name "*.png" | mac_ocr_cli - --json -o all.json

# 多页 PDF:逐页展开,每页一项
mac_ocr_cli doc.pdf --json -o pages.json
mac_ocr_cli doc.pdf --jsonl -o pages.jsonl

# stdin 直接喂图片字节(管道友好)
cat shot.png | mac_ocr_cli --stdin-image
cat shot.png | mac_ocr_cli --stdin-image --plain

# 裸文本输出(grep 友好) + 结果直接进剪贴板
mac_ocr_cli photo.png --plain --to-clipboard

# stdin 支持注释（#）和空行
cat list.txt | mac_ocr_cli - -l en-US
# list.txt 格式：
#   # 截图
#   /Users/me/Desktop/a.png
#
#   /Users/me/Desktop/b.png

# 截主屏幕并 OCR
mac_ocr_cli --screen

# 截副屏(序号见 --display-list)
mac_ocr_cli --display-list
mac_ocr_cli --screen --display 1

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

## 进度与静默

- **默认**:批量模式每张图完成时在 stderr 打印 `[\r2/5] a.png  ok (3 lines)`,最后一行汇总 `完成: 3/5 ok, 2 failed, 用时 1.20s`。
- **`--quiet` / `-q`**:抑制所有非错误输出(stdout 报告 + stderr 进度都静音)。适合 `... | jq`、CI 脚本、定时任务。错误仍然到 stderr,exit code 不变(批量有失败仍为 2)。
- **`--output` 与 `--quiet` 正交**:`--quiet --json -o result.json batch/` 会把 JSON 写到文件,stdout 完全干净。

```bash
# 静默 + 写到文件 + shell 友好
mac_ocr_cli --quiet --json --dir ./shots -o all.json
if [ $? -eq 2 ]; then echo "some images failed"; fi
```

> **截图实现与权限**：macOS 14+ 走 ScreenCaptureKit,旧系统回落到 `CGWindowListCreateImage` 系列。macOS 10.15+ 需要「屏幕录制」权限（系统设置 → 隐私与安全性）。首次运行 Terminal / iTerm / 其他调用本工具的程序时会被提示授权,或在隐私设置中手动允许。授权后即可工作;未授权时 `--window-list` / `--display-list` 返回空,`--screen` 等会报权限错误。多显示器用 `--display-list` 查序号、`--display <n>` 选屏(0 = 主屏)。

> **剪贴板权限**：剪贴板读写**不需要**任何额外权限（TCC 不管这个）。`--clipboard` 仍需要「屏幕录制」权限,因为内部还是先截图再写入。

## 图片压缩（可选）

把 Vision 跑 OCR 之前先重编码成更小格式(预处理),或者 OCR 完成后另存压缩副本(归档)。两个模式独立,可以只用其一,也可以叠加。

**预处理 (`--compress-input`)**：内存里把大 PNG 重编码成 JPEG/HEIC/WebP,再喂给 OCR。可以降低解码后位图的内存占用;但如果目标是**提速**,优先用 `--max-dimension` 降采样——重编码不改变分辨率,Vision 的计算量不变,真正的加速来自更少的像素。

**另存副本 (`--compress-output <dir>`)**：OCR 完成后,把每张输入图按新格式写入指定目录。文件名沿用输入 stem,扩展名换成目标格式(多页 PDF 会带 `-p<N>` 后缀避免互相覆盖)。同名输入(不同目录下的同名文件,`--dir` 递归扫描时很常见)会用相对路径消歧(`a/photo.png` → `a__photo.jpg`),不会互相覆盖。保存失败仅写 stderr 警告,**不会**标记 batch item 失败(OCR 已经成功了)。

```bash
# 大图提速的正确姿势:解码期降采样(可叠加 --compress-input 省内存)
mac_ocr_cli --dir ./shots --max-dimension 2048

# 预处理省内存(大批量截图)
mac_ocr_cli --dir ./shots --compress-input 0.5

# 批量 OCR + 全部压缩成 WebP 到 ~/compressed
mac_ocr_cli --dir ./shots --compress-output ~/compressed --compress-output-format webp

# 两个模式叠加:预处理加速 + 另存归档(独立格式 + 独立质量)
mac_ocr_cli --dir ./shots \
  --compress-input medium --compress-input-format jpeg \
  --compress-output ~/compressed --compress-output-format heic \
  --compress-quality low

# 单文件 + 仅另存为 HEIC
mac_ocr_cli photo.png --compress-output ~/compressed --compress-output-format heic
```

质量取值：预设档位 `high`(默认,0.85)/ `medium`(0.70)/ `low`(0.50),或数字 `0.0..1.0`(仅作用于有损格式;`png` 永远走无损)。`--compress-input` 自带质量参数(预处理质量),`--compress-quality` 只作用于 `--compress-output`(另存副本的质量)。

注意：`--compress-output` 不能与 `--from-clipboard` / `--stdin-image` 同时使用(没有可推导的文件名)。`--compress-input` / `--compress-output` 不能与 `--window-list` / `--display-list` / `--lang-list` / `--clipboard` 同时使用(这些模式不跑 OCR);截图模式(`--screen` / `--window` / `--window-id` / `--region`)可以正常使用,另存副本的 stem 沿用 `--save-screenshot` 的文件名,没给就用 `screen`。

## 输出结构（JSON）

**单文件模式**（输入只有 1 张图，schema 保持向后兼容）：

```json
{
  "imagePath": "/abs/path/to.png",
  "imageWidth": 1512,
  "imageHeight": 982,
  "durationMilliseconds": 87,
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

`imageWidth` / `imageHeight` / `durationMilliseconds` 是 1.2.0 新增的可选元数据(图像像素尺寸与 OCR 耗时),旧版本输出没有这些键,消费端按可选字段处理。`--word-boxes` 时每行还会多一个 `words: [{text, boundingBox}]` 字段。单文件用 `-k` 时还会多一个 `keywordMatches: [{index, score, text}]` 字段(与批量同构,按分数降序)。

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
- 批量模式并发上限默认为 `min(4, 核数)`,可用 `--concurrency <n>` 覆盖;输出顺序与输入一致。
- 批量 `-k` 时每项会多一个 `keywordMatches: [{index, score, text}]` 字段(按分数降序)。
- 批量模式在任一项失败时以 exit code **2** 退出,便于 shell 脚本判断。
- `--jsonl` 时不再有顶层 `items` 结构:每完成一张输出一行独立的 item JSON(顺序 = 完成顺序),适合 `jq -c` / 逐行消费。单张和批量行为一致:配 `-o` 时只写文件(不往 stdout 重复输出),每行以换行结尾;`--quiet` 时不写 stdout。

**多页 PDF**：每页展开为一个批量项,`imagePath` 形如 `doc.pdf#page=2`。单页 PDF 保持单文件 schema。

**条码模式 (`--barcode`)**：结构同构,`lines` 换成 `barcodes`:

```json
{
  "imagePath": "/abs/qr.png",
  "barcodes": [
    {
      "symbology": "VNBarcodeSymbologyQR",
      "payload": "https://example.com",
      "boundingBox": { "x": 0.1, "y": 0.1, "width": 0.8, "height": 0.8 }
    }
  ]
}
```

条码没有置信度字段;`--min-confidence` / `--word-boxes` 在条码模式下不生效。

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
