#!/usr/bin/env bash
# 安全回写任务状态与结果，绝不手写 JSON（手写容易产生非法转义，写坏任务文件）
# 用法：
#   complete-task.sh <task-id> running            # 开始执行：pending -> running
#   complete-task.sh <task-id> done < result.txt  # 完成：result 从 stdin 读取
#   complete-task.sh <task-id> failed < err.txt   # 失败同理
#   printf '%s' '结果文本' | NOTES='执行摘要' bash complete-task.sh <task-id> done
#     # 附带执行摘要记入上下文。注意 NOTES 必须写在管道右侧的 bash 之前，
#     # 写在 printf 之前只会传给 printf，complete-task.sh 收不到。
# 机械防护：done / failed 的 result 为空会被直接拒绝（exit 1），必须写真实结果或失败原因
set -euo pipefail

ID="${1:?usage: complete-task.sh <task-id> <status> [result-file]}"
STATUS="${2:?usage: complete-task.sh <task-id> <status> [result-file]}"
RESULT_FILE="${3:-/dev/stdin}"

TASKS_DIR="$HOME/workspace/task-api/tasks"
F="$TASKS_DIR/$ID.json"
[ -f "$F" ] || { echo "task not found: $ID" >&2; exit 1; }

# heredoc 会占用 python 的 stdin，所以先把管道内容存成临时文件
if [ "$RESULT_FILE" = "/dev/stdin" ]; then
  TMP="$(mktemp)"
  trap 'rm -f "$TMP"' EXIT
  cat > "$TMP"
  RESULT_FILE="$TMP"
fi

# 机械防护：done / failed 必须带非空 result，空结果直接拒绝（防"无产出却标记完成"事故）
if { [ "$STATUS" = "done" ] || [ "$STATUS" = "failed" ]; } && [ ! -s "$RESULT_FILE" ]; then
  echo "error: result 为空，禁止标记 $STATUS。如无结果请标记 failed 并在 result 中写清原因。" >&2
  exit 1
fi

python3 - "$F" "$STATUS" "$RESULT_FILE" << 'PYEOF'
import json, sys, datetime, os
p, status, rf = sys.argv[1], sys.argv[2], sys.argv[3]
result = open(rf, encoding='utf-8').read()
with open(p, encoding='utf-8') as f:
    d = json.load(f)
d['status'] = status
d['result'] = result
d['updated_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
# 原子写：先写临时文件再替换，避免 server 读取时碰到半截 JSON
tmp = p + '.tmp'
with open(tmp, 'w', encoding='utf-8') as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
os.replace(tmp, p)
print(f'task {d["id"]} -> {status}, result {len(result)} chars')
PYEOF

# 持久化执行日志：logs/<task-uuid>.jsonl（不淘汰，保留 30 天/200MB）
# running/done/failed 全记录；done/failed 的 result 全量写入（含失败原因原文）
if [[ "$ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  TASK_ID="$ID" TASK_STATUS="$STATUS" RESULT_FILE="$RESULT_FILE" python3 - << 'PYEOF' 2>/dev/null || true
import json, os, datetime
tid = os.environ['TASK_ID']
status = os.environ['TASK_STATUS']
result = open(os.environ['RESULT_FILE'], encoding='utf-8').read() if status in ('done', 'failed') else ''
event = {
    'ts': datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z'),
    'type': f'task_{status}',
    'task_id': tid,
}
if result:
    event['result'] = result
dest = os.path.expanduser('~/workspace/task-api/logs') + f'/{tid}.jsonl'
os.makedirs(os.path.dirname(dest), exist_ok=True)
with open(dest, 'a', encoding='utf-8') as f:
    f.write(json.dumps(event, ensure_ascii=False) + '\n')
PYEOF
  bash "$HOME/workspace/task-api/prune-task-logs.sh" 2>/dev/null || true
fi

# 上下文记录：context.jsonl（保留最近 30 条）
CTX_LOG="$HOME/workspace/task-api/context-log.sh"
# 从任务文件取 conversation_id，事件带上会话标识（老任务可能没有该字段）
CONV_ID=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('conversation_id') or '')" "$F" 2>/dev/null || echo "")
if [ -x "$CTX_LOG" ]; then
  # 状态流转事件（result 只记前 500 字）
  TASK_ID="$ID" TASK_STATUS="$STATUS" RESULT_FILE="$RESULT_FILE" CONV_ID="$CONV_ID" python3 - << 'PYEOF' 2>/dev/null | bash "$CTX_LOG" add 2>/dev/null || true
import json, os
result = open(os.environ['RESULT_FILE'], encoding='utf-8').read()[:500]
event = {
    'type': 'task_status',
    'task_id': os.environ['TASK_ID'],
    'status': os.environ['TASK_STATUS'],
    'result_excerpt': result,
}
if os.environ.get('CONV_ID'):
    event['conversation_id'] = os.environ['CONV_ID']
print(json.dumps(event, ensure_ascii=False))
PYEOF
  # 执行摘要（可选）：NOTES 环境变量非空时一并记入，省掉单独调 context-log.sh note
  # 注意：NOTES 必须放在 bash 之前（管道右侧），否则环境变量传不到 complete-task.sh
  if [ -n "${NOTES:-}" ]; then
    TASK_ID="$ID" NOTE="$NOTES" CONV_ID="$CONV_ID" python3 - << 'PYEOF' 2>/dev/null | bash "$CTX_LOG" add 2>/dev/null || true
import json, os
event = {'type': 'execution_notes', 'task_id': os.environ['TASK_ID'],
         'summary': os.environ['NOTE']}
if os.environ.get('CONV_ID'):
    event['conversation_id'] = os.environ['CONV_ID']
print(json.dumps(event, ensure_ascii=False))
PYEOF
  fi
fi
