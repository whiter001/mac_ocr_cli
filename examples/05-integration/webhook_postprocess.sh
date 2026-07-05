#!/usr/bin/env bash
#
# OCR + HTTP POST demo:把识别结果以 JSON 推送到一个 webhook(本地 echo server 或 Slack/Notion 等)。
# 把 WEBHOOK_URL 改成你自己的 endpoint 即可。
#
# 这个脚本是个 stub —— 用 Python 的 http.server 起一个本地的 echo server 验证流程:
#   python3 -m http.server 8765
# 然后在另一个终端:
#   WEBHOOK_URL=http://localhost:8765/ocr ./webhook_postprocess.sh shot.png
# 你会在 Python server 的输出里看到 POST 请求体。
#
# 用法: WEBHOOK_URL=<url> ./webhook_postprocess.sh <image_or_dir>
# 示例: WEBHOOK_URL=https://hooks.slack.com/services/XXX ./webhook_postprocess.sh shot.png

set -euo pipefail

if [ -z "${WEBHOOK_URL:-}" ]; then
  echo "错误: 需要设置 WEBHOOK_URL 环境变量" >&2
  echo "示例: WEBHOOK_URL=https://example.com/ocr ./webhook_postprocess.sh shot.png" >&2
  exit 1
fi

if [ $# -ne 1 ]; then
  echo "用法: WEBHOOK_URL=<url> $0 <image_or_dir>" >&2
  exit 64
fi

INPUT="$1"

# OCR 输出 JSON,再用 curl POST
if [ -d "$INPUT" ]; then
  JSON=$(mac_ocr_cli --dir "$INPUT" --json --quiet 2>/dev/null \
    || swift run mac_ocr_cli --dir "$INPUT" --json --quiet 2>/dev/null)
else
  JSON=$(mac_ocr_cli --json --quiet "$INPUT" 2>/dev/null \
    || swift run mac_ocr_cli --json --quiet "$INPUT" 2>/dev/null)
fi

# 推送。如果失败仅 stderr 警告,不影响主流程。
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  --data "$JSON" \
  "$WEBHOOK_URL" || echo "000")

if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
  echo "✓ Webhook 推送成功 (HTTP $HTTP_CODE): $INPUT" >&2
else
  echo "[警告] Webhook 推送失败 (HTTP $HTTP_CODE): $INPUT" >&2
fi

# 把原始 JSON 仍然输出到 stdout,方便管道后续处理
echo "$JSON"