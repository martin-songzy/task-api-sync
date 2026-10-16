#!/usr/bin/env bash
# 任务执行日志：记录执行器的分步过程（持久化，不淘汰）
# 用法：
#   task-step.sh <task-id> "做了什么"        # 单行步骤
#   task-step.sh <task-id> < step.txt        # 多行从 stdin/文件读
# 日志落盘：~/workspace/task-api/logs/<task-uuid>.jsonl
# 查看：bash ~/workspace/task-api/task-log.sh <task-id>
set -euo pipefail

ID="${1:?usage: task-step.sh <task-id> [message]}"
MSG_SRC="${2:-/dev/stdin}"

# 防路径穿越：只接受标准 uuid
if ! [[ "$ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  echo "error: 非法 task-id" >&2; exit 1
fi

LOGS_DIR="$HOME/workspace/task-api/logs"
mkdir -p "$LOGS_DIR"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
if [ -n "${2:-}" ]; then
  printf '%s' "$2" > "$TMP"
else
  cat > "$TMP"
fi
[ -s "$TMP" ] || { echo "error: 步骤内容为空" >&2; exit 1; }

ID="$ID" MSG_FILE="$TMP" python3 - << 'PYEOF'
import json, os, datetime
tid = os.environ['ID']
msg = open(os.environ['MSG_FILE'], encoding='utf-8').read()
dest = os.path.expanduser('~/workspace/task-api/logs') + f'/{tid}.jsonl'
event = {
    'ts': datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z'),
    'type': 'step',
    'task_id': tid,
    'message': msg,
}
with open(dest, 'a', encoding='utf-8') as f:
    f.write(json.dumps(event, ensure_ascii=False) + '\n')
print(f'step logged for {tid} ({len(msg)} chars)')
PYEOF

# 顺手做保留策略（节流：最多每小时跑一次）
bash "$HOME/workspace/task-api/prune-task-logs.sh" 2>/dev/null || true
