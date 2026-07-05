#!/usr/bin/env bash
#
# 截取屏幕的指定矩形区域并 OCR。
# 坐标原点在屏幕左上角(与 macOS 屏幕坐标系一致)。
#
# 用法: ./region.sh <x> <y> <width> <height>
# 示例: ./region.sh 100 200 800 600   # 截 (100,200) 起 800x600 的矩形
#
# 实用技巧:用系统截图工具 Cmd+Shift+4 拖动后看 "尺寸" 数字,
# 或者运行 `mac_ocr_cli --window-list` 查目标窗口坐标。

set -euo pipefail

if [ $# -ne 4 ]; then
  echo "用法: $0 <x> <y> <width> <height>" >&2
  echo "示例: $0 100 200 800 600" >&2
  exit 64
fi

X="$1"
Y="$2"
W="$3"
H="$4"

if command -v mac_ocr_cli >/dev/null 2>&1; then
  mac_ocr_cli --region "$X" "$Y" "$W" "$H"
else
  swift run mac_ocr_cli --region "$X" "$Y" "$W" "$H"
fi