#!/usr/bin/env bash
#
# 批量 OCR 后,把每张输入图另存为 WebP 压缩副本。
# WebP 在 macOS 11+ 原生支持,压缩率比 JPEG 更高,适合现代归档。
#
# 用法: ./archive_to_webp.sh <input_dir> <output_dir>
# 示例: ./archive_to_webp.sh ./original ~/Documents/ocr_archive

set -euo pipefail

if [ $# -ne 2 ]; then
  echo "用法: $0 <input_dir> <output_dir>" >&2
  exit 64
fi

INPUT_DIR="$1"
OUTPUT_DIR="$2"

if [ ! -d "$INPUT_DIR" ]; then
  echo "错误: 输入目录不存在: $INPUT_DIR" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

# --compress-output 自动覆盖同名文件,适合"原图压缩归档"场景
if command -v mac_ocr_cli >/dev/null 2>&1; then
  mac_ocr_cli --dir "$INPUT_DIR" \
    --compress-output "$OUTPUT_DIR" \
    --compress-output-format webp \
    --compress-quality 0.7
else
  swift run mac_ocr_cli --dir "$INPUT_DIR" \
    --compress-output "$OUTPUT_DIR" \
    --compress-output-format webp \
    --compress-quality 0.7
fi

echo ""
echo "✓ WebP 副本已写入: $OUTPUT_DIR"