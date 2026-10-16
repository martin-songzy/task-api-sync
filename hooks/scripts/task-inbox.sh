#!/usr/bin/env bash
# 轮询任务收件箱：有 pending 任务时唤醒执行 agent
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

TASKS_DIR="$HOME/workspace/task-api/tasks"
mkdir -p "$TASKS_DIR"

mapfile -t files < <(grep -l '"status": "pending"' "$TASKS_DIR"/*.json 2>/dev/null || true)

if [ "${#files[@]}" -eq 0 ]; then
  silent 'no pending tasks' '{}'
  exit 0
fi

ids=$(printf '%s\n' "${files[@]}" | xargs -n1 basename 2>/dev/null | sed 's/\.json$//' | jq -R . | jq -s -c .)
count=$(printf '%s\n' "${files[@]}" | wc -l)
log 'pending tasks found' "{\"count\": $count}"
wake 'pending tasks in inbox' "{\"task_ids\": $ids}"
