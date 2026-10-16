#!/usr/bin/env bash
# 看门狗：task-api 服务挂了就地重启；连续失败才唤醒人工介入
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

API_DIR="$HOME/workspace/task-api"
STATE_DIR="$HOME/hooks/state/task-api"
FAIL_FILE="$STATE_DIR/consecutive_failures"
mkdir -p "$STATE_DIR"
DRY="${HATCH_HOOK_DRY_RUN:-0}"

healthy() {
  curl --fail --silent --max-time 8 http://127.0.0.1:8787/health >/dev/null 2>&1
}

NGROK_BIN="$API_DIR/ngrok-bin/ngrok"

tunnel_healthy() {
  pgrep -f "^${NGROK_BIN} http 8787" >/dev/null 2>&1
}

ensure_tunnel() {
  if tunnel_healthy; then
    return 0
  fi
  if [ "$DRY" = "1" ]; then
    log 'dry-run: would start public tunnel' '{}'
    return 0
  fi
  log 'public tunnel down, starting' '{}'
  bash "$API_DIR/start-ngrok.sh" >/dev/null 2>&1 || true
  sleep 2
  if tunnel_healthy; then
    log 'public tunnel started' "{\"url\": \"$(cat "$API_DIR/public-url.txt" 2>/dev/null)\"}"
  else
    log 'public tunnel failed to start, will retry next poll' '{}'
  fi
}

# 流量级检查：隧道数据连接可能静默失效（进程活着，公网却不通）
# 每 5 次轮询检查一次公网 /health，失败则重启隧道
check_tunnel_traffic() {
  local counter_file="$STATE_DIR/traffic_check_counter"
  local n=$(( $(cat "$counter_file" 2>/dev/null || echo 0) + 1 ))
  if [ "$n" -ge 5 ]; then n=0; fi
  if [ "$DRY" != "1" ]; then echo "$n" > "$counter_file"; fi
  if [ "$n" -ne 0 ]; then return 0; fi
  if ! tunnel_healthy; then return 0; fi  # 进程都没了，ensure_tunnel 会处理
  local url; url="$(cat "$API_DIR/public-url.txt" 2>/dev/null || true)"
  if [ -z "$url" ]; then return 0; fi
  if [ "$DRY" = "1" ]; then
    log 'dry-run: would probe public tunnel' '{}'
    return 0
  fi
  if curl --fail --silent --max-time 30 "$url/health" >/dev/null 2>&1; then
    return 0
  fi
  log 'public tunnel stale (traffic check failed), restarting' "{\"url\": \"$url\"}"
  bash "$API_DIR/start-ngrok.sh" >/dev/null 2>&1 || true
  sleep 2
  if tunnel_healthy; then
    log 'stale public tunnel restarted' "{\"url\": \"$(cat "$API_DIR/public-url.txt" 2>/dev/null)\"}"
  fi
  log 'tunnel traffic check done' '{}'
}

# 地址变化检测：ngrok 免费版重启后公网地址会变，变化时唤醒一次通知用户新地址
check_url_changed() {
  local url; url="$(cat "$API_DIR/public-url.txt" 2>/dev/null || true)"
  local last_file="$STATE_DIR/last_notified_url"
  local last; last="$(cat "$last_file" 2>/dev/null || true)"
  if [ -z "$url" ]; then return 1; fi
  if [ "$url" = "$last" ]; then return 1; fi
  if [ "$DRY" = "1" ]; then
    log 'dry-run: tunnel URL changed' "{\"url\": \"$url\"}"
    return 1
  fi
  echo "$url" > "$last_file"
  log 'tunnel URL changed' "{\"url\": \"$url\"}"
  # 同步更新 Cloudflare Worker 反向代理，固定域名保持可用
  if [ -x "$API_DIR/update-cf-worker.sh" ] && [ -f "$HOME/.config/cloudflare/token" ]; then
    if bash "$API_DIR/update-cf-worker.sh" "$url" >> "$API_DIR/cf-worker-update.log" 2>&1; then
      log 'cf worker updated' "{\"url\": \"$url\"}"
    else
      log 'cf worker update FAILED' "{\"url\": \"$url\"}"
    fi
  fi
  NEW_URL="$url"
  return 0
}

if healthy; then
  if [ "$DRY" != "1" ]; then echo 0 > "$FAIL_FILE"; fi
  ensure_tunnel
  check_tunnel_traffic
  if check_url_changed; then
    wake 'public tunnel URL changed' "{\"url\": \"$NEW_URL\"}"
  else
    silent 'task-api healthy' '{}'
  fi
  exit 0
fi

if [ "$DRY" = "1" ]; then
  silent 'dry-run: would restart task-api' '{}'
  exit 0
fi

fails=$(( $(cat "$FAIL_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$fails" > "$FAIL_FILE"
log 'task-api down, restarting' "{\"attempt\": $fails}"

pkill -f "node $API_DIR/server.js" 2>/dev/null || true
# 等旧进程真正释放 8787 再起新实例，避免 EADDRINUSE 撞车（server.log 里出现过一次）
for _ in $(seq 1 10); do
  (exec 3<>/dev/tcp/127.0.0.1/8787) >/dev/null 2>&1 || break
  sleep 1
done
# setsid 彻底脱离 hook 的进程组，否则 executor 会一直等子进程导致超时
setsid nohup /usr/bin/node "$API_DIR/server.js" >> "$API_DIR/server.log" 2>&1 < /dev/null &
sleep 3

if healthy; then
  echo 0 > "$FAIL_FILE"
  log 'task-api restarted ok' '{}'
  ensure_tunnel
  if check_url_changed; then
    wake 'public tunnel URL changed' "{\"url\": \"$NEW_URL\"}"
  else
    silent 'task-api restarted ok' '{}'
  fi
else
  if [ "$fails" -ge 3 ]; then
    wake 'task-api restart failed repeatedly' "{\"consecutive_failures\": $fails}"
  else
    silent 'task-api restart failed, will retry next poll' "{\"consecutive_failures\": $fails}"
  fi
fi
