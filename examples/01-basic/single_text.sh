#!/usr/bin/env bash
#
# 单文件 OCR,默认纯文本输出到 stdout。
# 最简单的用法:识别一张图片里的文字,直接打印到终端。
#
# 用法: ./single_text.sh <image.png>
# 示例: ./single_text.sh ~/Desktop/photo.png
#
# 前提:已经 `swift build` 或安装了 release 二进制到 PATH。

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "用法: $0 <image.png>" >&2
  exit 64
fi

IMAGE="$1"

# 用 release 二进制(优先),fallback 到 swift run
if command -v mac_ocr_cli >/dev/null 2>&1; then
  mac_ocr_cli "$IMAGE"
else
  swift run mac_ocr_cli "$IMAGE"
fi