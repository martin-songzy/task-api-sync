#!/usr/bin/env bash
# task-api 双向同步核心：提交本地实现变更 → 变基拉取 → 推送
# 由 hook 脚本 task-api-sync-hook.sh 每 15 分钟调用一次。
#
# 同步范围（git 仓库 = 本目录）：
#   server.js / API.md / *.sh / cf-worker/ / hooks/ / dist/ 等实现文件
# 永不同步：.token（API 密钥）、tasks/ files/ logs/ context.jsonl（运行状态）、
#   ngrok-bin/ node_modules/（二进制与依赖，各账号自行获取）
#
# 退出码：0=成功或未配置 remote（调用方静默）；2=合并冲突需人工处理；
#         3=推送失败；1=其他致命错误。
set -euo pipefail

API_DIR="$HOME/workspace/task-api"
HOOK_LIVE="$HOME/hooks/scripts"
HOOK_REPO="$API_DIR/hooks/scripts"
LABEL="${TASK_API_ACCOUNT_LABEL:-$(cat "$API_DIR/.account-label" 2>/dev/null || hostname 2>/dev/null || echo unknown)}"
BRANCH="main"
cd "$API_DIR"

# 错误输出进 /tmp，不进仓库（否则下次 add -A 会把它们误提交）
ERR_DIR="$(mktemp -d /tmp/task-api-sync-XXXXXX)"
trap 'rm -rf "$ERR_DIR"' EXIT

# 未配置同步目标：静默退出（bootstrap 完成前是正常状态）
git remote get-url origin >/dev/null 2>&1 || { echo "no origin remote configured"; exit 0; }

# 安全断言：密钥文件绝不能进入版本库
git check-ignore -q .token || { echo "FATAL: .token is not git-ignored; refusing to sync" >&2; exit 1; }

# 1) 把运行中 hook 脚本的本地修改收进仓库（仓库是唯一可信源）
mkdir -p "$HOOK_REPO"
for f in task-inbox.sh task-api-watchdog.sh task-api-sync-hook.sh; do
  [ -f "$HOOK_LIVE/$f" ] && cp -f "$HOOK_LIVE/$f" "$HOOK_REPO/$f"
done

# 2) 有未解决的合并冲突：停下，交由 agent 处理，不自动解
if git status --porcelain | grep -q '^UU'; then
  echo "CONFLICT: unmerged paths present, manual resolution required" >&2
  git status --porcelain | grep '^UU' >&2
  exit 2
fi

# 3) 提交本地实现变更（若有）
git add -A
if ! git diff --cached --quiet; then
  git commit -qm "sync(${LABEL}): implementation changes $(date -u +%Y%m%dT%H%M%SZ)"
  echo "committed local changes"
fi

# 4) 变基拉取远端（保持线性历史，避免无意义的 merge commit）
BEFORE="$(git rev-parse HEAD)"
if ! git pull --rebase --autostash origin "$BRANCH" 2>"$ERR_DIR/pull.err"; then
  git rebase --abort 2>/dev/null || true
  echo "PULL FAILED (rebase aborted, workdir clean):" >&2
  cat "$ERR_DIR/pull.err" >&2
  exit 2
fi
AFTER="$(git rev-parse HEAD)"

# 本次拉取带入的文件清单（调用方据此判断 hook 定义是否变化）
CHANGED=""
if [ "$BEFORE" != "$AFTER" ]; then
  CHANGED="$(git diff --name-only "$BEFORE" "$AFTER" | tr '\n' ' ')"
fi

# 5) 把仓库中的 hook 脚本部署到运行位置
for f in task-inbox.sh task-api-watchdog.sh task-api-sync-hook.sh; do
  [ -f "$HOOK_REPO/$f" ] && cp -f "$HOOK_REPO/$f" "$HOOK_LIVE/$f" && chmod 644 "$HOOK_LIVE/$f"
done

# 6) 推送
if ! git push origin "$BRANCH" 2>"$ERR_DIR/push.err"; then
  echo "PUSH FAILED:" >&2
  cat "$ERR_DIR/push.err" >&2
  exit 3
fi

echo "sync OK: $BEFORE -> $AFTER"
[ -n "$CHANGED" ] && echo "changed: $CHANGED"
