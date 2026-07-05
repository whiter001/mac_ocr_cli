#!/usr/bin/env bash
#
# 截屏到剪贴板(不跑 OCR)。
# 适合"截图 → 粘到 Slack/微信/邮件"的快速流程。
# 可以加 --region/--window 指定范围,不传则截主屏幕。
#
# 用法: ./clipboard_write.sh                  # 截整个主屏幕
#       ./clipboard_write.sh --region 0 0 800 600

set -euo pipefail

if command -v mac_ocr_cli >/dev/null 2>&1; then
  mac_ocr_cli --clipboard "$@"
else
  swift run mac_ocr_cli --clipboard "$@"
fi