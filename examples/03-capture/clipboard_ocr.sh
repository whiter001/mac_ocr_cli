#!/usr/bin/env bash
#
# 识别剪贴板里已有的图片。
# 典型流程:
#   1. 用系统自带截图快捷键 Cmd+Shift+Ctrl+4 截到剪贴板
#   2. 运行本脚本
#
# 也可以组合 Cmd+Shift+4 截到桌面 + 这个脚本读剪贴板,流程不变。
# 提示:剪贴板读写不需要额外权限(TCC 不管这个)。

set -euo pipefail

if command -v mac_ocr_cli >/dev/null 2>&1; then
  mac_ocr_cli --from-clipboard
else
  swift run mac_ocr_cli --from-clipboard
fi