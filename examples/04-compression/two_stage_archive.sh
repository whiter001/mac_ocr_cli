#!/usr/bin/env bash
#
# 双模式叠加:预处理加速 + 另存归档(独立格式/独立质量)。
# 演示 --compress-input-* 和 --compress-output-* 可以完全独立配置。
#
# 用法: ./two_stage_archive.sh <input_dir> <output_dir>
# 示例: ./two_stage_archive.sh ./screenshots ~/archive
#
# 这个例子的配置:
#   - 输入预处理: JPEG @ medium (0.7)  → 喂给 OCR,纯内存,不落盘
#   - 输出另存:   HEIC @ low (0.5)     → 写到 output_dir,最小体积

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

if command -v mac_ocr_cli >/dev/null 2>&1; then
  mac_ocr_cli --dir "$INPUT_DIR" \
    --compress-input medium --compress-input-format jpeg \
    --compress-output "$OUTPUT_DIR" --compress-output-format heic \
    --compress-quality low
else
  swift run mac_ocr_cli --dir "$INPUT_DIR" \
    --compress-input medium --compress-input-format jpeg \
    --compress-output "$OUTPUT_DIR" --compress-output-format heic \
    --compress-quality low
fi