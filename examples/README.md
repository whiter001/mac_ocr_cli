# mac_ocr_cli — Examples

一组可运行的 demo 脚本,展示 mac_ocr_cli 的常见用法。所有脚本都用 `set -euo pipefail`、自带 `--help`-like 用法提示,优先调用 PATH 里的 `mac_ocr_cli`(没有就 `swift run`,方便本地直接试)。

## 前置条件

```bash
# 方式 A:release 二进制(推荐,启动快)
swift build -c release
cp .build/release/mac_ocr_cli /usr/local/bin/

# 方式 B:用 swift run(每个 demo 都自动 fallback)
# 无需任何操作

# 可选工具
brew install jq        # 用于 05-integration/with_jq.sh
brew install fswatch   # 用于 05-integration/watch_folder.sh
```

> 所有 demo 首次运行都会被 macOS 提示授予「屏幕录制」权限(只对 `03-capture/` 里的脚本)。

## 目录索引

### [01-basic/](01-basic/) — 单文件基础 OCR

| 脚本 | 用途 |
|---|---|
| [`single_text.sh`](01-basic/single_text.sh) | 单文件 → 默认纯文本输出 |
| [`single_json.sh`](01-basic/single_json.sh) | 单文件 → JSON 输出(管道友好) |
| [`keyword.sh`](01-basic/keyword.sh) | 单文件 + 关键词搜索(按相关度排序) |

### [02-batch/](02-batch/) — 批量处理

| 脚本 | 用途 |
|---|---|
| [`dir_scan.sh`](02-batch/dir_scan.sh) | 扫描整个目录,JSON 写到文件 |
| [`stdin_pipeline.sh`](02-batch/stdin_pipeline.sh) | 通过 `find` 管道喂文件路径 |

### [03-capture/](03-capture/) — 截图 + OCR

| 脚本 | 用途 |
|---|---|
| [`full_screen.sh`](03-capture/full_screen.sh) | 截主屏幕并 OCR |
| [`window.sh`](03-capture/window.sh) | 截指定窗口并 OCR |
| [`region.sh`](03-capture/region.sh) | 截矩形区域并 OCR |
| [`clipboard_ocr.sh`](03-capture/clipboard_ocr.sh) | 识别剪贴板里已有的图片 |
| [`clipboard_write.sh`](03-capture/clipboard_write.sh) | 截屏到剪贴板(不跑 OCR) |

### [04-compression/](04-compression/) — 图片压缩(新功能)

| 脚本 | 用途 |
|---|---|
| [`preprocess_for_speed.sh`](04-compression/preprocess_for_speed.sh) | OCR 前压缩,加速批量 |
| [`archive_to_webp.sh`](04-compression/archive_to_webp.sh) | 另存 WebP 压缩副本归档 |
| [`two_stage_archive.sh`](04-compression/two_stage_archive.sh) | 预处理 + 另存,格式/质量独立 |

### [05-integration/](05-integration/) — 真实场景集成

| 脚本 | 用途 | 依赖 |
|---|---|---|
| [`with_jq.sh`](05-integration/with_jq.sh) | JSON → jq 提取去重 | `jq` |
| [`watch_folder.sh`](05-integration/watch_folder.sh) | 监控文件夹,新文件自动 OCR | `fswatch` |
| [`webhook_postprocess.sh`](05-integration/webhook_postprocess.sh) | OCR 结果 POST 到 webhook | `curl` |

### [samples/](samples/) — 测试用样本

占位目录。放你想试的截图/扫描件,跑上面的 demo 时用。详见 [samples/README.md](samples/README.md)。

## 5 分钟快速体验

```bash
# 1. 找一个测试图(或者用任何 png/jpg)
cp ~/Desktop/some_screenshot.png ./samples/

# 2. 跑基础 OCR
./01-basic/single_text.sh ./samples/some_screenshot.png

# 3. 转 JSON 然后提取每行文字
./01-basic/single_json.sh ./samples/some_screenshot.png | jq -r '.lines[].text'

# 4. 搜关键词
./01-basic/keyword.sh ./samples/some_screenshot.png "Error"
```

## 常见场景

### 归档一堆截图

```bash
# 把 ~/Desktop/screenshots 里所有 png 转成 jpeg 存到 ~/Documents/ocr_archive
./04-compression/archive_to_webp.sh ~/Desktop/screenshots ~/Documents/ocr_archive
```

### 配合 Slack / Notion

```bash
# 见 05-integration/webhook_postprocess.sh,把识别结果推到任意 HTTP endpoint
WEBHOOK_URL=https://hooks.slack.com/services/XXX \
  ./05-integration/webhook_postprocess.sh shot.png
```

### 持续监控下载目录

```bash
# 见 05-integration/watch_folder.sh,新文件落地就自动 OCR
brew install fswatch
./05-integration/watch_folder.sh ~/Downloads
```

## 怎么跑某个 demo

每个脚本都支持直接执行 + 用法提示(出错时会打印)。例如:

```bash
$ ./01-basic/keyword.sh
用法: ./keyword.sh <image.png> <keyword>

$ ./03-capture/window.sh Safari
图片: <window: Safari> ...
识别行数: 12
结果:
- [0] conf=0.95 box=(...)  Welcome to Safari
- ...
```

## 注意事项

- **权限**:首次跑 `03-capture/` 时 macOS 会弹窗要「屏幕录制」权限,在系统设置 → 隐私与安全性 → 屏幕录制 里给 Terminal/iTerm 授权。
- **首次编译**:`swift run` 第一次会编译 30-60 秒,之后秒开。
- **WebP**:macOS 14 部分系统的 ImageIO 没挂 WebP encoder,跑 WebP 相关 demo 时可能报"无法创建 destination",这是系统限制,改用 JPEG/HEIC 即可。
- **CJK 字符**:默认识别中/繁/英三种,识别纯英文场景可以加 `--lang en-US` 让结果更聚焦(更快)。