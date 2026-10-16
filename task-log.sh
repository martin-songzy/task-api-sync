#!/usr/bin/env bash
# 查看任务执行日志（持久化全量记录）
# 用法：
#   task-log.sh <task-id>          # 时间线美化输出
#   task-log.sh <task-id> --raw    # 原始 JSONL
set -euo pipefail

ID="${1:?usage: task-log.sh <task-id> [--raw]}"
RAW="${2:-}"

if ! [[ "$ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  echo "error: 非法 task-id" >&2; exit 1
fi

F="$HOME/workspace/task-api/logs/$ID.jsonl"
[ -f "$F" ] || { echo "no log for task $ID" >&2; exit 1; }

if [ "$RAW" = "--raw" ]; then
  cat "$F"
  exit 0
fi

python3 - "$F" << 'PYEOF'
import json, sys
path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    events = [json.loads(l) for l in f if l.strip()]
print(f"任务 {events[0].get('task_id')} 共 {len(events)} 条事件")
print('=' * 60)
for e in events:
    ts = e.get('ts', '')
    t = e.get('type', '')
    if t == 'task_created':
        print(f"[{ts}] CREATED 会话={e.get('conversation_id')} 用户={e.get('user')}")
        print(f"  query: {e.get('query', '')[:200]}")
        files = e.get('files') or []
        if files:
            print(f"  附件: {', '.join(x.get('stored_name','') for x in files)}")
    elif t == 'task_running':
        print(f"[{ts}] RUNNING 开始执行")
    elif t == 'step':
        print(f"[{ts}] STEP")
        for line in e.get('message', '').split('\n'):
            print(f"  {line}")
    elif t in ('task_done', 'task_failed'):
        print(f"[{ts}] {t.upper().replace('TASK_', '')}")
        print(e.get('result', ''))
    elif t == 'task_stopped':
        print(f"[{ts}] STOPPED 被调用方停止")
    else:
        print(f"[{ts}] {t.upper()} {json.dumps(e, ensure_ascii=False)[:200]}")
PYEOF
