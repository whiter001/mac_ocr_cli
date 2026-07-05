#!/usr/bin/env bash
#
# OCR + jq 后处理:从 JSON 输出里提取所有识别行,去重后输出。
# 演示 mac_ocr_cli 的 JSON 输出怎么和标准 Unix 工具组合。
#
# 前置:需要 `brew install jq` (jq 不在本仓库,需要外部安装)
#
# 用法: ./with_jq.sh <image_or_dir>
# 示例: ./with_jq.sh shot.png
#       ./with_jq.sh ~/Desktop/receipts

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "用法: $0 <image_or_dir>" >&2
  exit 64
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "错误: 需要安装 jq (brew install jq)" >&2
  exit 1
fi

INPUT="$1"

# 先把结果输出成 JSON,再交给 jq 提取所有识别行
if [ -d "$INPUT" ]; then
  # 目录:用 --dir 批量
  if command -v mac_ocr_cli >/dev/null 2>&1; then
    mac_ocr_cli --dir "$INPUT" --json --quiet
  else
    swift run mac_ocr_cli --dir "$INPUT" --json --quiet
  fi | jq -r '
    if .items then
      # batch 模式:扁平化所有 item 的 lines
      [.items[].lines[]?.text] | unique[]
    else
      # 单文件模式:直接读 .lines
      [.lines[]?.text] | unique[]
    end
  '
else
  # 单文件
  if command -v mac_ocr_cli >/dev/null 2>&1; then
    mac_ocr_cli --json --quiet "$INPUT"
  else
    swift run mac_ocr_cli --json --quiet "$INPUT"
  fi | jq -r '[.lines[]?.text] | unique[]'
fi