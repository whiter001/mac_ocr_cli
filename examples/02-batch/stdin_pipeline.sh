#!/usr/bin/env bash
#
# stdin 管道批量 OCR。
# 适合和 find / fd / ripgrep 等工具组合,只处理匹配条件的图片。
#
# 用法: ./stdin_pipeline.sh <output.json>
# 示例: ./stdin_pipeline.sh only_recent.json
#       (内部用 find 找最近 7 天修改过的 png)

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "用法: $0 <output.json>" >&2
  exit 64
fi

OUTPUT_JSON="$1"

# find 找出最近 7 天修改过的 .png/.jpg 文件,逐行通过 stdin 喂给 mac_ocr_cli
# 想换条件改这里即可,例如:只在 ./shots 目录里找 .heic
find . -type f \( -name "*.png" -o -name "*.jpg" -o -name "*.heic" \) \
  -mtime -7 | \
if command -v mac_ocr_cli >/dev/null 2>&1; then
  mac_ocr_cli - --json -o "$OUTPUT_JSON"
else
  swift run mac_ocr_cli - --json -o "$OUTPUT_JSON"
fi

echo "✓ 处理完成,JSON 写入: $OUTPUT_JSON"