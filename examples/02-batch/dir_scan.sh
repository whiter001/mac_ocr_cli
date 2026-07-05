#!/usr/bin/env bash
#
# 批量 OCR:扫描整个目录的图片,JSON 输出到文件。
# 适合一次性处理一批截图/扫描件,例如收据归档。
#
# 用法: ./dir_scan.sh <input_dir> <output.json>
# 示例: ./dir_scan.sh ~/Desktop/receipts ~/receipts.json

set -euo pipefail

if [ $# -ne 2 ]; then
  echo "用法: $0 <input_dir> <output.json>" >&2
  exit 64
fi

INPUT_DIR="$1"
OUTPUT_JSON="$2"

if [ ! -d "$INPUT_DIR" ]; then
  echo "错误: 输入目录不存在: $INPUT_DIR" >&2
  exit 1
fi

if command -v mac_ocr_cli >/dev/null 2>&1; then
  mac_ocr_cli --dir "$INPUT_DIR" --json -o "$OUTPUT_JSON"
else
  swift run mac_ocr_cli --dir "$INPUT_DIR" --json -o "$OUTPUT_JSON"
fi

# 提示用户:失败计数和退出码
echo ""
echo "✓ JSON 已写入: $OUTPUT_JSON"
echo "  用 jq 提取全部命中行: jq '.items[].lines[].text' \"$OUTPUT_JSON\""