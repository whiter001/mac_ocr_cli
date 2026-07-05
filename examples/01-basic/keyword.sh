#!/usr/bin/env bash
#
# 单文件 OCR + 关键词搜索。
# 输出按相关度排序的命中行(完全匹配 = 1.0,子串匹配 = 0.9),便于从扫描件/截图里快速定位。
#
# 用法: ./keyword.sh <image.png> <keyword>
# 示例: ./keyword.sh invoice.png "订单号"

set -euo pipefail

if [ $# -ne 2 ]; then
  echo "用法: $0 <image.png> <keyword>" >&2
  exit 64
fi

IMAGE="$1"
KEYWORD="$2"

if command -v mac_ocr_cli >/dev/null 2>&1; then
  mac_ocr_cli "$IMAGE" --keyword "$KEYWORD"
else
  swift run mac_ocr_cli "$IMAGE" --keyword "$KEYWORD"
fi