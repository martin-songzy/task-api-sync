#!/usr/bin/env bash
# 任务上下文管理：~/workspace/task-api/context.jsonl（JSONL，每行一条事件）
# 只保留最近 KEEP 条（默认 30），超限时整理。
# 用法：
#   context-log.sh add < event.json        # 追加一条事件（JSON 从 stdin 读，自动补 ts）
#   context-log.sh note <task_id> < summary.txt  # 记一条执行过程摘要（文本从 stdin/文件读）
#   context-log.sh tail [n] [conversation_id]  # 输出最近 n 条（默认 10），JSONL；
#                                             # 给 conversation_id 则只输出该会话的事件
set -euo pipefail

CTX_DIR="$HOME/workspace/task-api"
CTX_FILE="$CTX_DIR/context.jsonl"
KEEP=30
TRIM_AT=45
mkdir -p "$CTX_DIR"

trim_if_needed() {
  local n
  n=$(wc -l < "$CTX_FILE" 2>/dev/null || echo 0)
  if [ "$n" -gt "$TRIM_AT" ]; then
    local tmp
    tmp=$(mktemp)
    tail -n "$KEEP" "$CTX_FILE" > "$tmp"
    mv "$tmp" "$CTX_FILE"
  fi
}

cmd_add() {
  # stdin: JSON 事件；自动补 ts 字段
  local tmp
  tmp=$(mktemp)
  trap "rm -f '$tmp'" EXIT
  cat > "$tmp"
  python3 - "$tmp" "$CTX_FILE" << 'PYEOF'
import json, sys, datetime
src, dest = sys.argv[1], sys.argv[2]
raw = open(src, encoding='utf-8').read().strip()
event = json.loads(raw) if raw else {}
event.setdefault('ts', datetime.datetime.now(datetime.timezone.utc).isoformat())
with open(dest, 'a', encoding='utf-8') as f:
    f.write(json.dumps(event, ensure_ascii=False) + '\n')
PYEOF
  trim_if_needed
}

cmd_note() {
  # $1: task_id；stdin/文件: 摘要文本
  local task_id="${1:?usage: context-log.sh note <task_id> [summary-file]}"
  local src="${2:-/dev/stdin}"
  local tmp
  tmp=$(mktemp)
  trap "rm -f '$tmp'" EXIT
  cat "$src" > "$tmp"
  python3 - "$tmp" "$CTX_FILE" "$task_id" << 'PYEOF'
import json, sys, datetime
src, dest, tid = sys.argv[1], sys.argv[2], sys.argv[3]
summary = open(src, encoding='utf-8').read()
event = {
    'ts': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'type': 'execution_notes',
    'task_id': tid,
    'summary': summary,
}
with open(dest, 'a', encoding='utf-8') as f:
    f.write(json.dumps(event, ensure_ascii=False) + '\n')
PYEOF
  trim_if_needed
}

cmd_tail() {
  local n="${1:-10}"
  local conv="${2:-}"
  [ -f "$CTX_FILE" ] || exit 0
  if [ -z "$conv" ]; then
    tail -n "$n" "$CTX_FILE"
  else
    python3 - "$CTX_FILE" "$n" "$conv" << 'PYEOF'
import json, sys
path, n, conv = sys.argv[1], int(sys.argv[2]), sys.argv[3]
matched = []
with open(path, encoding='utf-8') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except Exception:
            continue
        if e.get('conversation_id') == conv:
            matched.append(line)
for line in matched[-n:]:
    print(line)
PYEOF
  fi
}

CMD="${1:?usage: context-log.sh add|note|tail}"
case "$CMD" in
  add)  cmd_add ;;
  note) shift; cmd_note "$@" ;;
  tail) shift; cmd_tail "$@" ;;
  *) echo "unknown command: $1" >&2; exit 1 ;;
esac
