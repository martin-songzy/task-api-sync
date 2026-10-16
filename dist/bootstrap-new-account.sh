#!/usr/bin/env bash
# task-api 新账号 bootstrap：在全新的 muse.ai 账号沙箱里复制 task-api 实现
#
# 用法：bash dist/bootstrap-new-account.sh <git-repo-url> <固定公网域名> [账号标签]
# 示例：bash dist/bootstrap-new-account.sh https://github.com/xxx/task-api.git https://taskapi-b.example.com account-b
#
# 前置（见 dist/BOOTSTRAP.md）：先建好 ~/.config 下的密钥文件再跑本脚本。
set -euo pipefail

REPO_URL="${1:?usage: bootstrap-new-account.sh <git-repo-url> <public-domain> [account-label]}"
PUBLIC_DOMAIN="${2:?usage: bootstrap-new-account.sh <git-repo-url> <public-domain> [account-label]}"
LABEL="${3:-account-b}"

API_DIR="$HOME/workspace/task-api"
[ -e "$API_DIR" ] && { echo "FATAL: $API_DIR already exists, refusing to overwrite" >&2; exit 1; }

# ---- 0) 密钥文件预检（缺失直接列清单退出，不往下走） ----
need=0
for f in "$HOME/.config/github/token" \
         "$HOME/.config/cloudflare/token" \
         "$HOME/.config/cloudflare/account_id" \
         "$HOME/.config/ngrok/ngrok.yml"; do
  if [ ! -f "$f" ]; then echo "MISSING: $f"; need=1; fi
done
if [ "$need" = 1 ]; then
  echo "先按 dist/BOOTSTRAP.md 建好上面的密钥文件（权限 600），再重跑本脚本" >&2
  exit 1
fi
chmod 600 "$HOME/.config/github/token" "$HOME/.config/cloudflare/token" \
          "$HOME/.config/cloudflare/account_id" "$HOME/.config/ngrok/ngrok.yml" 2>/dev/null || true

# ---- 1) 拉代码 ----
git clone "$REPO_URL" "$API_DIR"
cd "$API_DIR"
git config user.name "task-api-sync"
git config user.email "task-api-sync@local"
git config credential.helper "$API_DIR/git-credential-taskapi.sh"
printf '%s' "$LABEL" > .account-label
printf '%s' "$PUBLIC_DOMAIN" > .public-domain

# ---- 2) node 依赖（仅 busboy） ----
npm install --omit=dev 2>&1 | tail -2

# ---- 3) ngrok 二进制（官方 release，每次重下，不入库） ----
mkdir -p ngrok-bin
curl -fsSL -o /tmp/ngrok.tgz https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz
tar xzf /tmp/ngrok.tgz -C ngrok-bin && rm -f /tmp/ngrok.tgz
./ngrok-bin/ngrok version

# ---- 4) 本账号独立的 API token（600，永不入库） ----
if [ ! -f .token ]; then
  python3 -c "import secrets; print(secrets.token_hex(32))" > .token
  chmod 600 .token
fi

# ---- 5) 部署 hook 脚本到运行位置 ----
mkdir -p "$HOME/hooks/scripts"
cp -f hooks/scripts/*.sh "$HOME/hooks/scripts/"
chmod 644 "$HOME/hooks/scripts/"*.sh

echo "bootstrap done."
echo "next: 按 dist/BOOTSTRAP.md 创建 3 个 hooks → 起 ngrok 隧道 → 部署 Cloudflare Worker → 建 route+DNS → 起 node 服务 → 跑验证清单"
