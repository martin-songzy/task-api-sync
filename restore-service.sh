#!/bin/bash
# restore-service.sh — 一键恢复本账号 task-api 服务（备用方案）
# 做的事情（顺序重要）：
#   1. 重新启用三个 hook（task-inbox / task-api-watchdog / task-api-sync）
#   2. 启动 node 服务（8787 未监听时）
#   3. 启动 ngrok 隧道（start-ngrok.sh 幂等）
#   4. 本地 + 公网健康检查
# 用法：bash ~/workspace/task-api/restore-service.sh
set -u
API_DIR="$HOME/workspace/task-api"
DOMAIN="https://muse_api.x24hrcom.dpdns.org"

echo "[1/4] 重新启用 hooks..."
python3 - "$HOME/hooks/definitions" <<'EOF'
import json, sys
for f in ['task-inbox.json', 'task-api-watchdog.json', 'task-api-sync.json']:
    p = f"{sys.argv[1]}/{f}"
    d = json.load(open(p))
    d['enabled'] = True
    json.dump(d, open(p, 'w'), ensure_ascii=False, indent=2)
    print("  enabled:", f)
EOF

echo "[2/4] 启动 node 服务..."
if (exec 3<>/dev/tcp/127.0.0.1/8787) >/dev/null 2>&1; then
  echo "  8787 已在监听，跳过启动"
else
  setsid nohup /usr/bin/node "$API_DIR/server.js" >> "$API_DIR/server.log" 2>&1 < /dev/null &
  sleep 3
  if (exec 3<>/dev/tcp/127.0.0.1/8787) >/dev/null 2>&1; then
    echo "  node 已启动"
  else
    echo "  !! node 启动失败，看 $API_DIR/server.log"; exit 1
  fi
fi

echo "[3/4] 启动 ngrok 隧道..."
bash "$API_DIR/start-ngrok.sh" >/dev/null 2>&1
sleep 5
if pgrep -f "ngrok-bin/ngrok" >/dev/null; then echo "  ngrok 运行中"; else echo "  !! ngrok 未运行"; exit 1; fi

echo "[4/4] 健康检查..."
LOCAL=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" http://127.0.0.1:8787/v1/health || echo 000)
echo "  本地 127.0.0.1:8787/v1/health -> $LOCAL"
PUB=$(curl -s --max-time 20 -o /dev/null -w "%{http_code}" "$DOMAIN/v1/health" || echo 000)
echo "  公网 $DOMAIN/v1/health -> $PUB"
[ "$LOCAL" = "200" ] && [ "$PUB" = "200" ] && echo "恢复成功" || { echo "!! 有一项检查未通过"; exit 1; }
