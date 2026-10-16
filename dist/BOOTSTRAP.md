# task-api 新账号复制 + 双向同步：交接文档

> 阅读对象：新 muse.ai 账号里的助手 agent（或 Martin 本人）。
> 目标：在这个全新账号的沙箱里完整复制 task-api 实现，并接入与主账号的双向同步。

---

## 1. 架构总览（先读懂再动手）

- **唯一可信源**：一个 GitHub 私有仓库。两账号的 `~/workspace/task-api` 都是它的克隆。
- **同步机制**：每账号各跑一个 `task-api-sync` hook（15 分钟轮询），自动做：提交本地实现变更 → `git pull --rebase` → `git push`。冲突或失败时唤醒 agent 人工处理，常规成功静默。
- **同步范围**：`server.js`、`API.md`、全部 `.sh` 脚本、`cf-worker/`、`hooks/`（脚本+定义模板）、`dist/`。即"功能实现"。
- **永不同步**（各账号独立，`.gitignore` 已隔离）：
  - `.token`（本账号 API Bearer 密钥）
  - `tasks/`、`files/`、`logs/`、`context.jsonl`、`conversations.json`（运行状态与任务数据）
  - `ngrok-bin/`、`node_modules/`（二进制与依赖，各账号自行获取）
  - `~/.config/` 下的一切（GitHub PAT、Cloudflare token、ngrok authtoken）
- **各账号独立的东西**：公网域名、ngrok 隧道、Cloudflare Worker（名可相同也可不同）、API token、任务数据、n8n 指向。

---

## 2. 前置条件（Martin 手动，只做一次）

1. 在 GitHub 建一个**私有**仓库（例如 `task-api-sync`），拿到仓库 URL。
2. 在**主账号**执行（主账号的助手已备好一切，只差这两条命令）：
   ```bash
   cd ~/workspace/task-api
   git remote add origin <仓库URL>
   git push -u origin main
   ```
3. 建一个 GitHub PAT（Settings → Developer settings → Personal access tokens，`repo` 权限即可），
   分别写入**两账号**的 `~/.config/github/token`（权限 600，单行、无换行）。
4. 准备新账号的：ngrok authtoken（ngrok dashboard）、Cloudflare API token
   （权限：Workers Scripts Edit、Workers Routes Edit、对应 zone 的 DNS Edit）、
   Cloudflare account_id、zone_id，以及给新账号用的固定公网域名
   （如 `https://taskapi-b.example.com`，必须是该 Cloudflare zone 下的子域名）。

---

## 3. 密钥文件（新账号，权限全部 600）

```bash
mkdir -p ~/.config/github ~/.config/cloudflare ~/.config/ngrok ~/.config/task-api

# GitHub PAT（第 2 步第 3 条建的那个）
printf '%s' '<PAT>' > ~/.config/github/token

# Cloudflare
printf '%s' '<cf-token>'     > ~/.config/cloudflare/token
printf '%s' '<account_id>'   > ~/.config/cloudflare/account_id
printf '%s' '<zone_id>'      > ~/.config/cloudflare/zone_id   # 建 route/DNS 用

# ngrok（该账号自己的 authtoken）
printf 'version: "2"\nauthtoken: <ngrok-authtoken>\n' > ~/.config/ngrok/ngrok.yml

chmod 600 ~/.config/github/token ~/.config/cloudflare/* ~/.config/ngrok/ngrok.yml

# 可选：若两账号共用同一个 Cloudflare 账号，Worker 名必须不同，否则互相覆盖部署
# printf 'task-api-proxy-b' > ~/.config/task-api/worker_name
```

---

## 4. 运行 bootstrap 脚本

仓库里 `dist/bootstrap-new-account.sh` 已随代码同步过来。**先**在主账号确认第 2 步的 push 已完成，**再**在新账号执行：

```bash
bash ~/workspace/task-api/dist/bootstrap-new-account.sh <仓库URL> <固定公网域名> <账号标签>
# 示例：
# bash ~/workspace/task-api/dist/bootstrap-new-account.sh \
#   https://github.com/xxx/task-api-sync.git https://taskapi-b.example.com account-b
```

脚本会：clone 代码 → 配 git 身份/credential helper → 记账号标签与公网域名（`.account-label`、`.public-domain`，均不入库）→ `npm install` → 下载 ngrok → 生成本账号独立 `.token`（600）→ 部署 hook 脚本到 `~/hooks/scripts/`。密钥缺失会直接列清单退出。

---

## 5. 创建 3 个 hooks

定义模板在 `~/workspace/task-api/hooks/definitions/*.json`（prompt 中的 `__PUBLIC_DOMAIN__`
替换为本账号公网域名）。用下面命令生成建 hook 所需字段：

```bash
cd ~/workspace/task-api
python3 - << 'PYEOF'
import json
domain = open('.public-domain').read().strip()
for hid in ['task-inbox', 'task-api-watchdog', 'task-api-sync']:
    d = json.load(open(f'hooks/definitions/{hid}.json'))
    print('=== ', hid)
    print('script_path:', d['script_path'])
    print('poll_interval_secs:', d['poll_interval_secs'])
    print('--- prompt (domain substituted) ---')
    print(d['prompt'].replace('__PUBLIC_DOMAIN__', domain))
    print()
PYEOF
```

对每个 hook 调用 `hooks.add`（id / script_path / poll_interval_secs / prompt 如上），
然后 `hooks.dry_run` 验证（task-inbox、task-api-watchdog 应 silent；task-api-sync 在 remote
已配好时会做一次真实同步），最后 `hooks.enable`。三个 hook 全部启用后才算就绪。

说明：
- `task-inbox`：任务执行器（30 秒轮询）。
- `task-api-watchdog`：服务+隧道看门狗（60 秒轮询），服务挂了会自动重启。
- `task-api-sync`：双向同步（15 分钟轮询），成功静默，冲突/失败或对端改了 hook 定义时才唤醒 agent。

---

## 6. Cloudflare：Worker + Route + DNS（新账号）

```bash
cd ~/workspace/task-api
TOKEN="$(cat ~/.config/cloudflare/token)"
ACCT="$(cat ~/.config/cloudflare/account_id)"
ZONE="$(cat ~/.config/cloudflare/zone_id)"
DOMAIN="$(cat .public-domain | sed 's#https://##')"          # 如 taskapi-b.example.com
WORKER="$(cat ~/.config/task-api/worker_name 2>/dev/null || echo task-api-proxy)"

# 1) 起 ngrok 隧道，拿到公网地址
bash start-ngrok.sh
NGROK_URL="$(cat public-url.txt)" && echo "$NGROK_URL"

# 2) 部署 Worker（反向代理到 ngrok 地址；脚本内 __UPSTREAM__ 会被替换）
bash update-cf-worker.sh "$NGROK_URL"     # 看到 worker deployed OK

# 3) 建 Worker Route（pattern 不带 scheme）
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE}/workers/routes" \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  --data "{\"pattern\":\"${DOMAIN}/*\",\"script\":\"${WORKER}\"}"; echo

# 4) 建 DNS（proxied 占位 A 记录，流量实际由 Worker Route 接管）
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE}/dns_records" \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  --data "{\"type\":\"A\",\"name\":\"${DOMAIN}\",\"content\":\"192.0.2.1\",\"proxied\":true,\"comment\":\"task-api worker route placeholder\"}"; echo
```

---

## 7. 启动服务

```bash
cd ~/workspace/task-api
# node 服务（看门狗会保活，手动起一次即可）
(nohup /usr/bin/node server.js >> server.log 2>&1 &)
sleep 2
curl -s http://127.0.0.1:8787/health; echo
```

---

## 8. 验证清单（全部通过才算复制成功）

- [ ] `curl -s http://127.0.0.1:8787/health` → 200（本地服务）
- [ ] `curl -s https://<公网域名>/v1/meta`（无 token）→ 401（公网链路+鉴权链正常）
- [ ] 带 `Authorization: Bearer $(cat .token)` 调 `/v1/meta` → 200
- [ ] `public-url.txt` 有 ngrok 地址；`hooks.list` 显示 3 个 hook 均为 enabled
- [ ] `git remote -v` 有 origin；`git status` 干净；`git ls-files | grep -c token` → 0（无密钥入库）
- [ ] 下发一个测试任务（query 写"返回 hello"），`task-log.sh <id>` 看到 created→running→done
- [ ] 等 15 分钟，`hooks.logs task-api-sync` 看到一次 silent 的 sync ok（或在主账号改一行注释，
      15 分钟内在新账号 `git log --oneline -3` 看到同步过来的提交）

---

## 9. 日常同步行为（无需干预）

- 任一账号改了实现（server.js、脚本、hook prompt 模板、API.md 等），15 分钟内自动提交并推送；
  另一账号 15 分钟内拉取生效。hook 脚本变更会自动部署到 `~/hooks/scripts/`。
- 若有人改了 `hooks/definitions/*.json`（hook prompt），对端同步后会唤醒 agent，
  agent 用本账号域名替换 `__PUBLIC_DOMAIN__` 后 `hooks.update` 应用并 dry_run 验证。
- 两边 15 分钟内改了**同一文件同一位置** → 同步 hook 报冲突并唤醒 agent，人工合并后再跑
  `bash task-api-sync.sh` 验证。不要强行 `--force` 推送。
- 密钥轮换、token 更换只在各账号本地做，永不经过 git。

## 10. 退役 / 断开某账号

在该账号执行：`hooks.disable task-api-sync`（或 `hooks.remove`），再 `git remote remove origin`。
仓库保留，该账号的本地实现不受影响。
