#!/usr/bin/env bash
# 从 ngrok 本地 API 读取当前公网地址，写入 public-url.txt
# 成功返回 0 并打印 URL；隧道未建好时返回 1
set -euo pipefail
API_DIR="$HOME/workspace/task-api"
URL="$(curl -s --max-time 5 http://127.0.0.1:4040/api/tunnels 2>/dev/null | python3 -c "
import json, sys
try:
    ts = json.load(sys.stdin)['tunnels']
    https_urls = [t['public_url'] for t in ts if t.get('proto') == 'https' and t.get('public_url')]
    print(https_urls[0] if https_urls else '')
except Exception:
    print('')
" 2>/dev/null)"
if [ -n "$URL" ]; then
  echo "$URL" > "$API_DIR/public-url.txt"
  echo "$URL"
  exit 0
fi
exit 1
