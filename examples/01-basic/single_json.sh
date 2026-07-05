#!/usr/bin/env bash
#
# 单文件 OCR,以 JSON 格式输出。
# 适合管道给 jq / 写入数据库 / HTTP POST 等场景。
#
# 用法: ./single_json.sh <image.png>
# 示例: ./single_json.sh shot.png | jq '.lines[].text'

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "用法: $0 <image.png>" >&2
  exit 64
fi

IMAGE="$1"

if command -v mac_ocr_cli >/dev/null 2>&1; then
  mac_ocr_cli --json "$IMAGE"
else
  swift run mac_ocr_cli --json "$IMAGE"
fi