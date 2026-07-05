#!/usr/bin/env bash
#
# 监控文件夹 + 新文件自动 OCR 的 demo。
# 用 macOS 自带的 fswatch(可通过 brew install fswatch 安装,或写一个简易轮询版本)。
#
# 这个脚本不会真的永久运行 —— 演示 fswatch 怎么和 mac_ocr_cli 配合。
# 实际部署推荐用 launchd(~/Library/LaunchAgents/)做成开机自启。
#
# 用法: ./watch_folder.sh <watch_dir>
# 示例: ./watch_folder.sh ~/Dropbox/inbox

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "用法: $0 <watch_dir>" >&2
  exit 64
fi

WATCH_DIR="$1"

if [ ! -d "$WATCH_DIR" ]; then
  echo "错误: 监控目录不存在: $WATCH_DIR" >&2
  exit 1
fi

if ! command -v fswatch >/dev/null 2>&1; then
  echo "错误: 需要 fswatch (brew install fswatch)" >&2
  echo "  或者改用 polling:while true; do inotifywait ...; done" >&2
  exit 1
fi

echo "👀 监控 $WATCH_DIR,新图片会自动 OCR (Ctrl-C 退出)"
echo ""

# fswatch 输出新建/修改的图片路径,逐行喂给 stdin
fswatch -e ".*" -i "\\.(png|jpg|jpeg|heic|webp|tiff)$" "$WATCH_DIR" | while read -r FILE; do
  # 文件可能还在写入,等一下再处理
  sleep 1

  # 只处理单文件,OCR 后打印到 stderr 供观察
  if command -v mac_ocr_cli >/dev/null 2>&1; then
    mac_ocr_cli --quiet "$FILE" >&2 || echo "[警告] OCR 失败: $FILE" >&2
  else
    swift run mac_ocr_cli --quiet "$FILE" >&2 || echo "[警告] OCR 失败: $FILE" >&2
  fi

  echo "[$(date '+%H:%M:%S')] ✓ OCR 完成: $FILE" >&2
done