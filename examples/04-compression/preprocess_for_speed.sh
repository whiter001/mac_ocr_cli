#!/usr/bin/env bash
#
# OCR 之前先压缩大图,加速批量处理 + 降低内存峰值。
# 适合几百张高分辨率扫描件/截图(每张 5-30 MB)的批量任务。
#
# 用法: ./preprocess_for_speed.sh <input_dir>
# 示例: ./preprocess_for_speed.sh ~/Downloads/big_screenshots

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "用法: $0 <input_dir>" >&2
  exit 64
fi

INPUT_DIR="$1"

if [ ! -d "$INPUT_DIR" ]; then
  echo "错误: 输入目录不存在: $INPUT_DIR" >&2
  exit 1
fi

# 0.5 是有损质量,OCR 对中英文清晰文本识别率几乎不变,
# 但内存占用和单张耗时都会显著下降。
# 想更高精度改成 --compress-input high(0.85) 或 0.7
if command -v mac_ocr_cli >/dev/null 2>&1; then
  mac_ocr_cli --dir "$INPUT_DIR" --compress-input 0.5
else
  swift run mac_ocr_cli --dir "$INPUT_DIR" --compress-input 0.5
fi