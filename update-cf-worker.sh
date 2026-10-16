#!/usr/bin/env bash
# 用新的 ngrok 公网地址重新部署 Cloudflare Worker（反向代理）
# 用法：update-cf-worker.sh <new-ngrok-url>
# token/account 读自 ~/.config/cloudflare/（权限 600）
set -euo pipefail

NEW_URL="${1:?usage: update-cf-worker.sh <new-ngrok-url>}"
CFG="$HOME/.config/cloudflare"
TOKEN_FILE="$CFG/token"
ACCT_FILE="$CFG/account_id"
# Worker 脚本名：默认 task-api-proxy。若两账号共用同一个 Cloudflare 账号，
# 在 ~/.config/task-api/worker_name 里写不同名字（如 task-api-proxy-b），避免部署时互相覆盖。
# 优先级：环境变量 TASK_API_WORKER_NAME > 配置文件 > 默认值。
CFG_NAME="$(cat "$HOME/.config/task-api/worker_name" 2>/dev/null || true)"
SCRIPT="${TASK_API_WORKER_NAME:-${CFG_NAME:-task-api-proxy}}"
TEMPLATE="$HOME/workspace/task-api/cf-worker/worker.js"

[ -f "$TOKEN_FILE" ] || { echo "missing $TOKEN_FILE" >&2; exit 1; }
[ -f "$ACCT_FILE" ] || { echo "missing $ACCT_FILE" >&2; exit 1; }
TOKEN="$(cat "$TOKEN_FILE")"
ACCOUNT_ID="$(cat "$ACCT_FILE")"

TMP="$(mktemp -d)"
trap "rm -rf '$TMP'" EXIT
NEW_URL="$NEW_URL" TEMPLATE="$TEMPLATE" OUT="$TMP/worker.js" python3 - << 'PYEOF'
import os
src = open(os.environ['TEMPLATE'], encoding='utf-8').read()
src = src.replace('__UPSTREAM__', os.environ['NEW_URL'])
open(os.environ['OUT'], 'w', encoding='utf-8').write(src)
PYEOF

# 校验占位符确实被替换：模板漂移时直接失败，不部署坏 worker
grep -q '__UPSTREAM__' "$TMP/worker.js" && { echo "FATAL: __UPSTREAM__ not replaced in built worker; refusing to deploy" >&2; exit 1; }
grep -qF "$NEW_URL" "$TMP/worker.js" || { echo "FATAL: new URL missing from built worker; refusing to deploy" >&2; exit 1; }

RESP="$(curl -s --max-time 60 -X PUT \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/workers/scripts/${SCRIPT}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -F 'metadata={"main_module":"worker.js"};type=application/json' \
  -F "worker.js=@${TMP}/worker.js;type=application/javascript+module")"
echo "$RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
if d.get('success'):
    print('worker deployed OK')
else:
    print('worker deploy FAILED:', json.dumps(d.get('errors', d), ensure_ascii=False)[:500])
    sys.exit(1)
"

# 开启 Worker Issues 错误监控（observability.issues.enabled）。
# 注意：该开关是部署配置的一部分，dashboard 上单独点开会被下一次部署覆盖，
# 因此每次部署后都用 API 重新应用，保证开关一直生效。
# PATCH 要求 multipart/form-data（settings 字段），JSON body 会被拒绝。
ISSUES_RESP="$(curl -s --max-time 30 -X PATCH \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/workers/scripts/${SCRIPT}/settings" \
  -H "Authorization: Bearer ${TOKEN}" \
  -F 'settings={"observability":{"issues":{"enabled":true}}};type=application/json')"
echo "$ISSUES_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
if d.get('success'):
    print('worker issues monitoring enabled OK')
else:
    print('issues enable FAILED:', json.dumps(d.get('errors', d), ensure_ascii=False)[:500])
    sys.exit(1)
"
