#!/usr/bin/env bash
#
# 截取整个主屏幕并 OCR。
# 适合快速识别屏幕上的文字(对话框、错误信息、网页截图)。
#
# 注意:首次运行会被 macOS 提示授予「屏幕录制」权限。

set -euo pipefail

if command -v mac_ocr_cli >/dev/null 2>&1; then
  mac_ocr_cli --screen
else
  swift run mac_ocr_cli --screen
fi