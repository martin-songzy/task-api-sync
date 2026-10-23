# Task API 调用文档

给 Muse 下发任务的 HTTP 接口，**接口风格对齐 Dify Agent 应用的 Chat API**。
提交任务后由后台执行器异步处理，可选 blocking（等执行完一次性返回）或 streaming（SSE 实时推送进度）。

## 基础信息

| 项目 | 说明 |
|------|------|
| 本地地址 | `http://127.0.0.1:8787`（服务仅监听本机） |
| 公网地址（固定） | `https://muse_api.x24hrcom.dpdns.org`（Cloudflare Worker 反向代理，长期有效） |
| 公网地址（临时） | 见 `~/workspace/task-api/public-url.txt`（ngrok 隧道，免费版重启后地址会变） |
| 鉴权 | `Authorization: Bearer <token>` 请求头（`/health` 除外；图片/视频文件下载免鉴权，见图片/视频结果规范） |
| 数据格式 | 请求/响应均为 JSON，`Content-Type: application/json` |
| 错误格式 | Dify 风格：`{"status": <http状态码>, "code": "<snake_case>", "message": "<原因>"}` |

Token 保管在服务器 `~/workspace/task-api/.token`（权限 600）。调用方需持有该 token。

## 接口一览

| 方法 | 路径 | 鉴权 | 说明 |
|------|------|------|------|
| `GET` | `/health` | 否 | 健康检查 |
| `POST` | `/v1/chat-messages` | 是 | 发送消息（下发任务），blocking / streaming |
| `POST` | `/v1/chat-messages/:task_id/stop` | 是 | 停止尚未被领取的任务 |
| `GET` | `/v1/conversations` | 是 | 会话列表 |
| `GET` | `/v1/messages` | 是 | 按会话查询历史消息 |
| `POST` | `/v1/messages/:message_id/feedbacks` | 是 | 对某条结果打分（like/dislike，null 撤销） |
| `GET` | `/v1/messages/:message_id/suggested` | 是 | 推荐问题（当前返回空列表） |
| `POST` | `/v1/conversations/:conversation_id/name` | 是 | 重命名会话 |
| `DELETE` | `/v1/conversations/:conversation_id` | 是 | 删除会话（204） |
| `GET` | `/v1/parameters` | 是 | 应用能力参数 |
| `GET` | `/v1/meta` | 是 | 应用 meta |
| `GET` | `/v1/info` | 是 | 应用信息 |
| `GET` | `/v1/files/:name` | 图片/视频否，其他文件是 | 文件下载（图片/视频/其他文件结果规范） |
| `POST` | `/v1/files/upload` | 是 | 图片上传（multipart，仅图片 ≤10MB，Dify 兼容） |

## 发送消息（下发任务）

`POST /v1/chat-messages`

请求 Body：

```json
{
  "query": "帮我查一下明天北京的天气",
  "inputs": {},
  "response_mode": "blocking",
  "conversation_id": "可选，不传则自动新建会话",
  "user": "可选，调用方标识"
}
```

- `query`（必填）：任务描述，执行器会按此内容执行。
- `inputs`（选填，对象）：附加输入变量，原样保存并在历史消息中回显。
- `response_mode`（选填，`blocking` | `streaming`，缺省 `blocking`）。
- `conversation_id`（选填）：传入则加入该会话（多轮连续任务），不传则新建会话并返回其 ID。执行器读取上下文时会优先读同一会话的最近记录。
- `user`（选填）：调用方标识。Dify 中为必填，本接口为兼容现有调用方保持选填；**传入后会话列表与历史消息会按该用户过滤隔离**。
- `files`（选填，数组）：图片附件，Dify 风格，引用**已上传**的文件。单项格式：

```json
{ "type": "image", "transfer_method": "local_file", "upload_file_id": "<POST /v1/files/upload 返回的 id>" }
```

  约束：`type` 仅支持 `image`，`transfer_method` 仅支持 `local_file`（先经 `/v1/files/upload` 上传），单个任务最多 5 个；`upload_file_id` 必须对应服务端已存在的图片，否则 `400 invalid_param`（`upload_file_id not found`）。空数组会被忽略。合法附件会存入任务并回显在历史消息的 `message_files` 中，执行器按 id 精确读取对应图片处理。

### blocking 模式

等待执行器完成后一次性返回（最长等待 20 分钟，超时返回 `504`，可改用 `GET /v1/messages` 轮询）：

```json
{
  "event": "message",
  "task_id": "07b62300-1b6c-43ed-a7a6-86420a055409",
  "message_id": "4c12af30-1ea2-47ab-a95b-fb65638ec549",
  "id": "4c12af30-1ea2-47ab-a95b-fb65638ec549",
  "conversation_id": "ddd58bf9-0f1e-48b0-8506-f05fe4165199",
  "mode": "chat",
  "answer": "北京明天（10月2日，周五）：晴，最高 24℃、最低 11℃……",
  "metadata": {"usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}, "retriever_resources": []},
  "created_at": 1790848974,
  "data": {
    "id": "4c12af30-1ea2-47ab-a95b-fb65638ec549",
    "message_id": "4c12af30-1ea2-47ab-a95b-fb65638ec549",
    "conversation_id": "ddd58bf9-0f1e-48b0-8506-f05fe4165199",
    "mode": "chat",
    "answer": "北京明天（10月2日，周五）：晴，最高 24℃、最低 11℃……",
    "metadata": {"usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}, "retriever_resources": []},
    "created_at": 1790848974
  }
}
```

- 按 Dify 规范读取请用 `data.answer` / `data.message_id` / `data.conversation_id`；顶层平铺字段保留，仅为向后兼容。

- `task_id`：执行控制 ID，用于 `stop` 接口。
- `message_id`：消息（任务）ID，用于 `feedbacks` 接口和历史查询。
- 任务失败时返回 `500 {"status":500,"code":"agent_failed","message":"<失败原因>"}`；任务被停止时返回 `409 {"code":"task_stopped",…}`。

### streaming 模式

`Content-Type: text/event-stream`，事件序列为（每个事件都带独立的 `event:` 名称行，符合 SSE 规范，可用 `addEventListener('agent_message')` 订阅）：

```
event: ping                          ← 约每 15 秒一次保活
event: message
data: {"event":"message",            ← 流首个事件（answer 为空），Dify 客户端由此取 id
       "task_id":"…","id":"…","message_id":"…","conversation_id":"…",
       "answer":"","created_at":…}

event: agent_thought
data: {"event":"agent_thought",      ← 任务已提交 / 执行器开始执行 / 执行进度更新
       "task_id":"…","id":"…","message_id":"…","conversation_id":"…",
       "position":1,"thought":"已收到任务，等待执行器领取",
       "observation":"","tool":"","tool_labels":{},"tool_input":"",…}

event: agent_message
data: {"event":"agent_message",      ← 执行完成，一次性给出完整 answer
       "task_id":"…","id":"…","message_id":"…","conversation_id":"…",
       "answer":"北京明天……"}

event: message_end
data: {"event":"message_end",        ← 结束
       "task_id":"…","id":"…","message_id":"…","conversation_id":"…",
       "metadata":{"usage":{…},"retriever_resources":[]},"files":[]}
```

- 所有事件均带 Dify 主键 `id`（值同 `message_id`，后者保留做兼容）。

失败时以 `data: {"event":"error","status":500,"code":"agent_failed","message":"<原因>"}` 结束流；
等待超过 20 分钟则 `code` 为 `run_timeout`（`status` 504）。

curl 示例：

```bash
TOKEN="<你的token>"; BASE="https://muse_api.x24hrcom.dpdns.org"
curl -N -X POST "$BASE/v1/chat-messages" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"query":"帮我查一下明天北京的天气","response_mode":"streaming"}'
```

Python（blocking）：

```python
import requests
TOKEN = "<你的token>"
BASE = "https://muse_api.x24hrcom.dpdns.org"  # 或 http://127.0.0.1:8787
H = {"Authorization": f"Bearer {TOKEN}"}

r = requests.post(f"{BASE}/v1/chat-messages", headers=H, json={
    "query": "帮我查一下明天北京的天气",
    "response_mode": "blocking",
    "user": "n8n",
}).json()
print(r["answer"])              # 执行结果
print(r["conversation_id"])     # 后续同主题任务可复用此会话 ID
```

n8n：
1. HTTP Request 节点 → `POST` → `https://muse_api.x24hrcom.dpdns.org/v1/chat-messages`，
   Header `Authorization: Bearer <token>`，JSON Body `{"query": "...", "response_mode": "blocking"}`，
   直接取返回的 `answer` 即结果（无需轮询）。
2. 如需实时进度，改用 `response_mode: "streaming"` 并解析 SSE 事件。

## 停止任务

`POST /v1/chat-messages/:task_id/stop`

只能停止**尚未被执行器领取**（`pending`）的任务；`task_id` 取自发送消息接口的返回。

```bash
curl -X POST "$BASE/v1/chat-messages/<task_id>/stop" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}'
# → {"result":"success"}
```

已在执行/已完成的任务返回 `400 {"code":"cannot_stop",…}`。

## 会话列表

`GET /v1/conversations?limit=20&last_id=<可选>&sort_by=-updated_at&user=<可选>`

- `limit`：1–100，缺省 20。超出范围或非整数时返回 `400 invalid_param`。
- `last_id`：上一页最后一条会话的 `id`，用于向后翻页。
- `sort_by`：`created_at` / `-created_at` / `updated_at` / `-updated_at`（`-` 表示倒序），缺省 `-updated_at`；非法值返回 `400 invalid_param`。
- `user`：传入则只返回该用户的会话（用户隔离）。

```json
{
  "limit": 20, "has_more": false,
  "data": [
    {"id": "ddd58bf9-…", "name": "帮我查一下明天北京的天气", "inputs": {},
     "introduction": "", "status": "normal",
     "created_at": 1790848974, "updated_at": 1790849002}
  ]
}
```

`name` 取该会话第一条任务的前 40 字；可用下面的重命名接口修改（保存在 `conversations.json`）。

## 会话重命名

`POST /v1/conversations/:conversation_id/name`

```json
{"name": "新会话名"}
```

成功返回 `{"result":"success"}`；会话不存在返回 `404`。

## 会话删除

`DELETE /v1/conversations/:conversation_id`

删除该会话及其全部任务记录，成功返回 `204`（无 body）；会话不存在返回 `404`。

## 历史消息

`GET /v1/messages?conversation_id=<id>&limit=20&first_id=<可选>&user=<可选>`

`limit` 规则同会话列表（1–100，缺省 20；非法值返回 `400 invalid_param`）。`first_id` 为翻页游标：传入某条消息的 `id` 后，返回它之后的消息。

```json
{
  "limit": 20, "has_more": false,
  "data": [
    {
      "id": "4c12af30-…",
      "conversation_id": "ddd58bf9-…",
      "inputs": {},
      "query": "帮我查一下明天北京的天气",
      "message_files": [],
      "agent_thoughts": [
        {"id": "4c12af30-…:thought:1", "message_id": "4c12af30-…", "position": 1,
         "thought": "步骤1: 查天气接口；步骤2: 整理结果", "observation": "",
         "tool": "", "tool_input": "", "created_at": 1790848990}
      ],
      "answer": "北京明天（10月2日，周五）：晴……",
      "feedback": null,
      "retriever_resources": [],
      "status": "normal",
      "created_at": 1790848974
    }
  ]
}
```

- `agent_thoughts`：执行器写入的执行过程摘要（`execution_notes` 上下文事件）。
- `status`：`normal` / `error`（任务失败时为 `error`，`answer` 为失败原因）。
- `first_id`：传当前页第一条的 `id` 可向前翻页取更早的消息。
- `user`：传入则只返回该用户的消息（用户隔离）。

## 推荐问题

`GET /v1/messages/:message_id/suggested`

当前不支持生成推荐问题，返回 `{"data": []}` 以保持接口形状兼容；消息不存在返回 `404`。

## 消息反馈

`POST /v1/messages/:message_id/feedbacks`

```json
{"rating": "like", "user": "可选", "content": "可选备注"}
```

- `rating`：`like` | `dislike`；传 `null` 表示撤销已有反馈（Dify 语义）。
- 成功返回 `{"result":"success"}`，反馈保存在任务记录中，可通过 `GET /v1/messages` 查看。

## 应用元信息

- `GET /v1/parameters`：应用能力参数。本执行器为纯文本任务型，无多模态/语音/检索/表单能力，各项均为关闭或空。
- `GET /v1/meta`：返回 `{"tool_icons": {}}`。
- `GET /v1/info`：返回 `{"name":"muse","description":"…","tags":["chatbot"]}`。

## 文件上传

`POST /v1/files/upload`（Dify 兼容，需 Bearer 鉴权），`Content-Type: multipart/form-data`：

- 表单字段：`file`（必填，单文件）、`user`（选填，调用方标识）。
- 仅接受图片：png / jpeg / gif / webp，单文件 ≤10MB。服务端按文件头魔数识别真实类型，不信任客户端上报的扩展名/MIME；非图片或超限分别返回 `400` / `413`。
- 成功返回 `201`（Dify 风格）：

```json
{
  "id": "85fb6a95-…",
  "name": "t.png",
  "size": 80,
  "extension": "png",
  "mime_type": "image/png",
  "created_by": "n8n",
  "created_at": 1790860447
}
```

- 文件名按 UTF-8 还原：multipart 的 `filename` 头按 latin-1 传输，服务端会按 UTF-8 解码后再返回（如 `控制台.png` 不会再乱码）。
- 上传的图片存入服务端 `files/` 目录，文件名为 `<id>.<extension>`，可直接用 `GET /v1/files/:name` 下载（图片下载免鉴权、同样 `no-store`）。下载地址：`https://muse_api.x24hrcom.dpdns.org/v1/files/<id>.<extension>`。

curl 示例：

```bash
TOKEN="<你的token>"; BASE="https://muse_api.x24hrcom.dpdns.org"
curl -X POST "$BASE/v1/files/upload" \
  -H "Authorization: Bearer $TOKEN" \
  -F "file=@/path/to/pic.png;type=image/png" -F "user=n8n"
```

完整闭环（上传 → 任务消费）：上传成功后拿到 `id`，在 `POST /v1/chat-messages` 的 `files` 参数中引用，执行器会精确读取该图片并按 `query` 处理：

```bash
ID="<上传返回的 id>"
curl -X POST "$BASE/v1/chat-messages" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"query\":\"请描述这张图片\",\"files\":[{\"type\":\"image\",\"transfer_method\":\"local_file\",\"upload_file_id\":\"$ID\"}]}"
```

注意：`files` 只接受已上传文件的 `id`（服务端校验存在性，`type` 仅 `image`、`transfer_method` 仅 `local_file`，单个任务最多 5 个）；引用不存在的 id 直接返回 `400`，不会把"附件已送达"的假象传给执行器。

## 图片结果规范

当任务产出图片内容（截图、生成的图片等）时，接口统一用以下**固定格式**返回，方便下游程序识别：

```
图片文件(<url>)
```

规则：

- `图片文件` 三个字固定不变，后跟半角括号，括号内是图片文件的公网 `https` 绝对地址。
- 适用于所有返回答案的位置：blocking 响应的 `data.answer`、streaming 的 `agent_message` 事件 `answer`、历史消息的 `answer`。
- 一张图片占一行；多张图片用多行，每行都是严格的 `图片文件(<url>)`。
- 允许文字说明与图片混排，但图片行必须独占一行、以 `图片文件(` 开头。
- 下游识别正则（按行匹配）：`^图片文件\((https?://[^)\s]+)\)$`
- 图片文件由执行器保存到服务端的 `files/` 目录，文件名规范为 `<任务uuid>-<序号>.<扩展名>`（如 `4c12af30-…-1.png`），仅允许字母、数字、点、下划线、连字符。
- 图片通过 `GET /v1/files/:name` 下载（**免 Bearer 鉴权**，知道链接即可下载，方便浏览器、`<img>` 标签与下游程序直接取用），公网地址形如 `https://muse_api.x24hrcom.dpdns.org/v1/files/<文件名>`；按扩展名返回 `Content-Type`（png/jpeg/gif/webp），文件名非法返回 `400`，文件不存在返回 `404`。
- 安全注意：图片下载免鉴权，凭链接即可获取；文件名含任务 UUID、不可猜测，但**不要把链接扩散给无关人员**。下载响应带 `Cache-Control: no-store`，Cloudflare 边缘及任何中间缓存都不会留存（`CF-Cache-Status: BYPASS`）。

示例（任务返回两张截图）：

```text
已按移动端版式截取整页，共 2 张：
图片文件(https://muse_api.x24hrcom.dpdns.org/v1/files/4c12af30-9e16-1.png)
图片文件(https://muse_api.x24hrcom.dpdns.org/v1/files/4c12af30-9e16-2.png)
```

## 视频结果规范

当任务产出视频内容时，接口统一用以下**固定格式**返回，方便下游程序识别：

```
视频文件(<url>)
```

规则：

- `视频文件` 三个字固定不变，后跟半角括号，括号内是视频文件的公网 `https` 绝对地址。
- 适用于所有返回答案的位置：blocking 响应的 `data.answer`、streaming 的 `agent_message` 事件 `answer`、历史消息的 `answer`。
- 一个视频占一行；多个视频用多行，每行都是严格的 `视频文件(<url>)`。
- 允许文字说明与视频混排，但视频行必须独占一行、以 `视频文件(` 开头。
- 下游识别正则（按行匹配）：`^视频文件\((https?://[^)\s]+)\)$`
- 视频文件由执行器保存到服务端的 `files/` 目录，文件名规范为 `<任务uuid>-<序号>.mp4`（或 `.webm`)，仅允许字母、数字、点、下划线、连字符。
- 视频通过 `GET /v1/files/:name` 下载（**免 Bearer 鉴权**，知道链接即可下载，方便浏览器、`<video>` 标签与下游程序直接取用），公网地址形如 `https://muse_api.x24hrcom.dpdns.org/v1/files/<文件名>`；按扩展名返回 `Content-Type`（mp4/webm），文件名非法返回 `400`，文件不存在返回 `404`。
- 安全注意：视频下载免鉴权，凭链接即可获取；文件名含任务 UUID、不可猜测，但**不要把链接扩散给无关人员**。下载响应带 `Cache-Control: no-store`，Cloudflare 边缘及任何中间缓存都不会留存。
- 本规范是 muse 自有约定（Dify 官方 API 无视频结果标准）。

示例：

```text
已生成变身动画：
视频文件(https://muse_api.x24hrcom.dpdns.org/v1/files/4c12af30-9e16-1.mp4)
```

### 如何下发视频生成任务

视频生成没有专用接口参数，统一通过 `query` 自然语言下发，支持文生视频与图生视频：

- **文生视频**：在 `query` 中描述画面（主体、动作、镜头运动、氛围）即可，如「生成一段视频：海边日落，海浪轻拍沙滩，镜头缓慢推进，配轻快的音乐」。
- **图生视频**：先调 `POST /v1/files/upload` 上传图片（见「文件上传」一节），再在 `POST /v1/chat-messages` 的 `files` 参数中引用 `upload_file_id`，并在 `query` 中说明动画要求（如「用这张图生成视频：人物缓缓转头微笑，镜头逐渐推进」）。`files` 最多 5 张；引用多张时须在 `query` 中指明每张的用途。任务文本要求用图生成但未传 `files` 的，按附件防线直接判失败（见「与 Dify 的已知差异」）。

限制（由底层视频生成管线决定，执行器无法突破）：

- 单个片段固定约 10 秒，时长不可指定；需要更长时执行器会生成多个片段拼接，单个任务最多 6 个片段。
- 片段自带合成音效/配乐，可在 `query` 中描述氛围（如「轻快的电子乐」「安静的钢琴」）；生成工具不接受音频输入，不支持用调用方提供的音频文件配乐。
- 生成耗时较长，`blocking` 模式可能触发 20 分钟超时（`run_timeout`），建议用 `streaming` 或提交后轮询 `GET /v1/messages`。
- 生成失败（工具报错、内容策略拒绝、超时）时任务标记 `failed`，生成工具返回的原始错误经错误体 `message` 原样透出（见「错误码」）。

## 其他文件结果规范

当任务产出图片/视频之外的文件内容（如 PDF 报告、CSV 表格、压缩包等）时，接口统一用以下**固定格式**返回，方便下游程序识别：

```
其他文件(<url>)
```

规则：

- `其他文件` 四个字固定不变，后跟半角括号，括号内是文件的公网 `https` 绝对地址。
- 适用于所有返回答案的位置：blocking 响应的 `data.answer`、streaming 的 `agent_message` 事件 `answer`、历史消息的 `answer`。
- 一个文件占一行；多个文件用多行，每行都是严格的 `其他文件(<url>)`。
- 允许文字说明与文件混排，但文件行必须独占一行、以 `其他文件(` 开头。
- 下游识别正则（按行匹配）：`^其他文件\((https?://[^)\s]+)\)$`
- 文件由执行器保存到服务端的 `files/` 目录，文件名规范为 `<任务uuid>-<序号>.<扩展名>`（如 `4c12af30-…-1.pdf`），仅允许字母、数字、点、下划线、连字符。
- 文件通过 `GET /v1/files/:name` 下载（**仍需 Bearer 鉴权**，与图片/视频免鉴权不同），公网地址形如 `https://muse_api.x24hrcom.dpdns.org/v1/files/<文件名>`；按扩展名返回 `Content-Type`（常见文档/压缩包类型已映射，未知类型回 `application/octet-stream`），文件名非法返回 `400`，文件不存在返回 `404`。
- 安全注意：文件可能含私密内容，下载响应带 `Cache-Control: no-store`，Cloudflare 边缘及任何中间缓存都不会留存，每次下载都重新鉴权。不要另行把这类文件放到公开免鉴权路径。
- 本规范是 muse 自有约定（Dify 官方 API 无通用文件结果标准）。

示例（任务返回一份 PDF 报告和一个 CSV）：

```text
已生成本月销售汇总报告：
其他文件(https://muse_api.x24hrcom.dpdns.org/v1/files/4c12af30-9e16-1.pdf)
其他文件(https://muse_api.x24hrcom.dpdns.org/v1/files/4c12af30-9e16-2.csv)
```

## 错误码

v1 错误体为 `{"status":<HTTP>,"code":"<snake_case>","message":"<原因>"}`。
其中 `status` 是 Dify 之外的附加字段（超集，Dify 客户端可忽略）；`code` 命名是 muse
**任务执行器语义**的方言（Dify 是应用编排语义），不硬凑 Dify 的 code：

| HTTP | `code` | 含义 |
|------|--------|------|
| `400` | `invalid_param` | Body 不是合法 JSON / 缺 `query` / `response_mode` 非法 / `rating` 非法等 |
| `400` | `cannot_stop` | 任务已不在 pending 状态，无法停止 |
| `401` | `unauthorized` | token 缺失或错误 |
| `404` | `not_found` | 任务 / 消息 / 会话 / 文件不存在，或路径不存在 |
| `409` | `task_stopped` | blocking 等待期间任务被停止 |
| `500` | `agent_failed` | 执行器任务失败（`message` 为失败原因，原样透出执行器写入的原因，文生图/文生视频失败时会带上生成工具返回的具体错误）；服务端异常为 `internal_error` |
| `413` | `file_too_large` | 上传文件超过大小上限（图片 ≤10MB） |
| `504` | `run_timeout` | 等待超过 20 分钟未完成，改用 `GET /v1/messages` 轮询 |

## 与 Dify 的已知差异

- `user` 在 Dify 中多处必填；本接口为兼容现有调用方保持选填，传入后按用户隔离过滤会话/消息。
- `metadata.usage` 的 token 计数恒为 0（自研执行器，无模型计费统计），不要用于成本核算。
- 文件上传与附件：支持 `POST /v1/files/upload`（仅图片 ≤10MB，Dify 兼容；见「文件上传」一节），上传后可在 `POST /v1/chat-messages` 的 `files` 参数中按 `upload_file_id` 引用（`type` 仅 `image`、`transfer_method` 仅 `local_file`，单个任务最多 5 个，服务端校验 id 真实存在，否则 `400`）。执行器按 id 精确读取 `files/` 下对应图片处理；若任务文本要求处理上传图片但未传 `files`，执行器会直接标记失败，**严禁**按「最新上传文件」猜测（猜错会产出看似正确实则错误的答案，比报错危害大）。`GET /v1/parameters` 中文件上传能力声明为图片 `local_file` 可用。另见「图片结果规范」「视频结果规范」：`GET /v1/files/:name` 是 muse 自有的图片/视频/其他文件结果下载接口（非 Dify 标准），其中图片/视频下载免鉴权、其他文件仍需鉴权。
- 不支持 `POST /v1/completion-messages`（文本补全模式）；本接口定位为 Agent 任务执行。
- 不支持会话变量（`GET/PUT /v1/conversations/:id/variables`）、应用反馈列表（`GET /v1/app/feedbacks`）。
- 推荐问题接口存在但返回空列表（暂不生成推荐追问）。

## 数据保存说明

- 每个任务自动落盘为 `tasks/<id>.json`（即 `message_id`），包含 query、会话 ID、控制 ID（`task_id`）、状态、结果、反馈和时间戳，持久保存。另含 `conversation_id_provided` 布尔字段：调用方显式传入 `conversation_id` 时为 `true`，未传（服务端自动生成新会话）时为 `false`——服务端落盘的会话 ID 本身无法区分这两种情况，归档等下游逻辑靠此字段分组。
- 任务上下文自动记入 `context.jsonl`（JSONL，每行一条事件），只保留最近 30 条，超出自动淘汰最旧记录。事件带 `conversation_id`，执行器处理新任务前优先读同一会话的最近 8 条。
- 上下文三类事件：`task_created`（提交时）、`task_status`（状态流转时）、`execution_notes`（执行器写入的执行过程摘要；流式模式下以 `agent_thought` 实时推送）。
- 查看执行情况：`GET /v1/messages` 看问答与执行摘要；服务器 `server.log` 看请求日志；`~/hooks/logs/task-inbox.jsonl` 看执行器取走任务的记录。
- 已完成的旧任务文件可自行清理。

## 任务执行日志（持久化）

每个任务的完整执行过程记入 `logs/<任务id>.jsonl`（JSONL，每行一条事件，**不淘汰**），包括：

- `task_created`：服务端在任务提交时写入（query 全文、会话 ID、用户、附件清单）
- `task_running` / `task_done` / `task_failed` / `task_stopped`：状态流转时写入；`done`/`failed` 的 `result` 为**全量**（含失败原因原文，不截断）
- `step`：执行器在关键节点写入（执行计划、主要步骤、调用的工具/接口、关键结果、失败时的完整错误）

查看某任务的完整时间线：

```bash
bash ~/workspace/task-api/task-log.sh <任务id>          # 美化时间线输出
bash ~/workspace/task-api/task-log.sh <任务id> --raw    # 原始 JSONL
```

保留策略：日志保留 30 天，总量超过 200MB 时从最旧的开始删（`prune-task-logs.sh` 自动执行，每小时最多一次）。`context.jsonl` 的 30 条滚动窗口不受影响，继续作为执行器的短期工作记忆。

## 公网调用

固定域名（推荐，长期有效）：

```
https://muse_api.x24hrcom.dpdns.org
```

这是 Cloudflare Worker 反向代理到 ngrok 隧道的固定入口。n8n / 任何公网机器用这个地址调用即可，
鉴权方式不变（`Authorization: Bearer <token>`）。ngrok 免费版隧道地址变化时，看门狗会自动重新
部署 Worker 同步新地址（`update-cf-worker.sh`，日志 `cf-worker-update.log`），调用方无需改动。

ngrok 隧道直连地址（备用，以 `public-url.txt` 为准）：

```
https://translate-tumbling-lankiness.ngrok-free.dev
```

把调用示例里的 `http://127.0.0.1:8787` 换成这个 https 地址即可。注意：
- ngrok 免费版地址在浏览器访问会有一次性拦截页，API 调用（n8n / curl）不受影响
- 隧道进程由 `task-api-watchdog` 一并看护：掉了 60 秒内自动重建并刷新 `public-url.txt`
- 隧道日志：`ngrok.log`；当前地址也会写入 `public-url.txt`
- authtoken 保存在 `~/.config/ngrok/ngrok.yml`（权限 600）；ngrok 免费账号不支持经 HTTP 代理运行，
  所以 `start-ngrok.sh` 启动时会去掉代理环境变量（本机可直连 ngrok 服务器）
- 长连接（blocking 最长等待 20 分钟、SSE 流）经过代理一般可正常保持

## 运行机制

- 服务代码：`server.js`（纯 Node 内置模块，零依赖），以后台进程运行，日志：`server.log`
- `task-api-watchdog` hook 每 60 秒检查 `/health`，挂了自动重启；连续 3 次重启失败会唤醒 agent 人工介入
- `task-inbox` hook 每 30 秒扫描 `tasks/` 目录，有 `pending` 任务即唤醒执行 agent，
  执行完把结果写回任务 JSON 的 `result` 字段
- 执行器回写必须用 `complete-task.sh <id> <running|done|failed>`（result 从 stdin/文件读，
  经 python json 安全转义，原子写盘），禁止手工编辑任务 JSON——之前因此出过文件损坏导致查询失败
- 上下文管理：`context.jsonl` 自动记录最近 30 条交互（任务提交/状态流转/执行过程摘要），
  `context-log.sh` 负责追加与裁剪（`tail [n] [conversation_id]` 可按会话过滤），
  上下文事件带 `conversation_id`（`complete-task.sh` 回写时自动从任务文件提取）
- VM 重启/替换后，hook 由平台自动恢复轮询，看门狗会把服务拉起来（自愈）

## 安全与运维

- 只监听本机回环地址（`127.0.0.1:8787`），公网流量经 ngrok 隧道进入（隧道只做转发，不改变鉴权）。
  不要把 8787 直接暴露到公网（无 TLS 且 token 是唯一的保护层）
- 旧的 localtunnel 方案（https://martin-taskapi.loca.lt）已废弃：其数据通道在此网络下不可靠；
  相关文件（start-tunnel.sh、tunnel-pkg/）仍保留在 task-api 目录，但不再被看门狗管理
- token 泄露时：替换 `.token` 内容并重启服务（`pkill -f 'task-api/server.js'`，
  看门狗 60 秒内会自动拉起新实例）
- 任务文件保留在 `tasks/` 目录，可自行清理已完成的旧任务

## 注意事项

- 公网调用请使用固定域名 `https://muse_api.x24hrcom.dpdns.org`，n8n 等调用方无需跟随隧道地址改动。
- Token 是主要的鉴权凭证，请妥善保管（例外：生成的图片/视频凭下载链接免鉴权获取，链接不要扩散给无关人员）。
- `answer` / `result` 字段为纯文本，执行器会把关键结果、文件路径、链接写在里面。
