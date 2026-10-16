#!/usr/bin/env bash
# 任务执行日志保留策略：logs/*.jsonl 保留 30 天，总量超过 200MB 时删最旧的
# 节流：通过 logs/.last-prune 标记，最多每小时执行一次
set -euo pipefail

LOGS_DIR="$HOME/workspace/task-api/logs"
MARK="$LOGS_DIR/.last-prune"
KEEP_DAYS=30
MAX_BYTES=$((200 * 1024 * 1024))

[ -d "$LOGS_DIR" ] || exit 0
now=$(date +%s)
if [ -f "$MARK" ]; then
  last=$(cat "$MARK" 2>/dev/null || echo 0)
  [ $((now - last)) -lt 3600 ] && exit 0
fi
date +%s > "$MARK"

# 1) 删 30 天前的
find "$LOGS_DIR" -maxdepth 1 -name '*.jsonl' -mtime +$KEEP_DAYS -delete 2>/dev/null || true
# 2) 总量超限时从最旧的开始删
total=$(du -sb "$LOGS_DIR" 2>/dev/null | cut -f1)
total=${total:-0}
if [ "$total" -gt "$MAX_BYTES" ]; then
  find "$LOGS_DIR" -maxdepth 1 -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null | sort -n | \
  while read -r _ f; do
    total=$(du -sb "$LOGS_DIR" 2>/dev/null | cut -f1); total=${total:-0}
    [ "$total" -le "$MAX_BYTES" ] && break
    rm -f "$f"
  done
fi
