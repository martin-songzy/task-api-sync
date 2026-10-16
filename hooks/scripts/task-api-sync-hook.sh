#!/usr/bin/env bash
# hook 轮询脚本：task-api 双向同步（15 分钟一次）
# 常规成功 → silent；冲突/推送失败/拉取失败 → wake agent 处理；
# 若本次拉取带入了 hooks/definitions/ 变更 → wake agent 按本账号域名应用新定义。
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

CORE="$HOME/workspace/task-api/task-api-sync.sh"

set +e
OUT="$(bash "$CORE" 2>&1)"
CODE=$?
set -e

tail20="$(printf '%s' "$OUT" | tail -20 | jq -Rs .)"

case $CODE in
  0)
    if printf '%s' "$OUT" | grep -q 'hooks/definitions/'; then
      log 'sync ok, hook definitions changed' "{\"output\": $tail20}"
      wake 'task-api hook definitions updated from peer; apply with this account public domain' \
        "{\"changed\": $(printf '%s' "$OUT" | grep 'changed:' | jq -Rs .)}"
      exit 0
    fi
    silent 'task-api sync ok' "{\"detail\": $tail20}"
    ;;
  *)
    log 'task-api sync failed' "{\"exit\": $CODE, \"output\": $tail20}"
    wake 'task-api sync needs attention' "{\"exit\": $CODE, \"output\": $tail20}"
    ;;
esac
