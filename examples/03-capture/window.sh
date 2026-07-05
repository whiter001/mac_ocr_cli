#!/usr/bin/env bash
#
# 截取特定窗口并 OCR。
# 通过窗口标题/应用名匹配,例如 "Safari"、"Terminal"、"微信"。
#
# 用法: ./window.sh <window_query>
# 示例: ./window.sh Safari
#       ./window.sh "Visual Studio Code"

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "用法: $0 <window_query>" >&2
  echo "示例: $0 Safari" >&2
  exit 64
fi

WINDOW="$1"

if command -v mac_ocr_cli >/dev/null 2>&1; then
  mac_ocr_cli --window "$WINDOW"
else
  swift run mac_ocr_cli --window "$WINDOW"
fi