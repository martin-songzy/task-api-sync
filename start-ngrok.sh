#!/usr/bin/env bash
# 启动 ngrok 公网隧道（幂等），公网地址写入 public-url.txt
# ngrok 免费版每次重启地址会变，看门狗会重建并刷新 public-url.txt
set -euo pipefail

API_DIR="$HOME/workspace/task-api"
NGROK="$API_DIR/ngrok-bin/ngrok"

# 文件锁：防止看门狗和手动重启并发互杀
exec 9>"$API_DIR/.ngrok.lock"
flock -n 9 || { echo "another ngrok launcher is running, exiting"; exit 0; }

# 已在运行则刷新 URL 后直接退出（锚定到行首，避免误伤自己）
if pgrep -f "^${NGROK} http 8787" >/dev/null 2>&1; then
  "$API_DIR/refresh-ngrok-url.sh" 2>/dev/null || true
  exit 0
fi

pkill -f "^${NGROK} http" 2>/dev/null || true
sleep 1

cd "$API_DIR"
# 免费账号不支持经 HTTP 代理运行；本机直连可达 ngrok 服务器，去掉代理变量
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy
setsid nohup "$NGROK" http 8787 --log "$API_DIR/ngrok.log" >> "$API_DIR/ngrok.log" 2>&1 < /dev/null &
disown 2>/dev/null || true

# 等隧道建好，从本地 API 读取公网地址（最多 ~2 分钟）
for _ in $(seq 1 24); do
  if "$API_DIR/refresh-ngrok-url.sh" 2>/dev/null; then
    echo "ngrok up: $(cat "$API_DIR/public-url.txt")"
    exit 0
  fi
  sleep 5
done
echo "ngrok did not come up" >&2
exit 1
