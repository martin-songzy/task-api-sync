// Muse Task API —— 给个人助手下发任务的 HTTP 接口
// 只监听 127.0.0.1，需 Bearer Token 鉴权。零第三方依赖，仅用 Node 内置模块。
//
// 接口风格对齐 Dify Agent 应用的 Chat API（/v1/chat-messages）：
//   POST /v1/chat-messages                 发送消息（即下发任务）
//     Body: {"query": "任务描述", "inputs": {...}, "response_mode": "blocking"|"streaming",
//            "conversation_id": "可选，不传则新建会话", "user": "可选"}
//     blocking: 等执行完成后一次性返回；Dify 结构 {task_id, data:{id,message_id,...}}，
//               另保留平铺字段向后兼容
//     streaming: SSE 事件流 message -> agent_thought -> agent_message -> message_end（或 error）
//   POST /v1/chat-messages/:task_id/stop   停止一个尚未被领取的任务
//   GET  /v1/conversations                 会话列表（?user=&limit=&last_id=&sort_by=）
//   POST /v1/conversations/:conversation_id/name  重命名会话
//   DELETE /v1/conversations/:conversation_id     删除会话（204）
//   GET  /v1/messages?conversation_id=...  按会话查历史消息（?user=&first_id=&limit=）
//   GET  /v1/messages/:message_id/suggested  推荐问题（暂返回空列表）
//   POST /v1/messages/:message_id/feedbacks  对结果打分（like/dislike，null 撤销）
//   GET  /v1/parameters  /v1/meta  /v1/info  应用元信息
//   GET  /v1/files/:name  文件下载（图片/视频免鉴权，其他文件需鉴权）
//   POST /v1/files/upload  图片上传（multipart/form-data，仅图片 ≤10MB，Dify 兼容，需鉴权）
//   错误格式统一为 Dify 风格：{"status": <http>, "code": "<snake>", "message": "<原因>"}
//   （多了 status 字段；code 命名为 muse 方言，见 API.md）
//
//   GET  /health       健康检查（免鉴权）
//
// 任务落盘为 tasks/<uuid>.json，由 hook 轮询执行并回写 result。

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const Busboy = require('busboy'); // multipart 解析（POST /v1/files/upload）

const PORT = Number(process.env.TASK_API_PORT || 8787);
const DIR = __dirname;
const TASKS_DIR = path.join(DIR, 'tasks');
const FILES_DIR = path.join(DIR, 'files'); // 图片/视频结果规范：执行器产出的图片和视频统一存放于此，经 GET /v1/files/:name 对外提供
const TOKEN_FILE = path.join(DIR, '.token');
// blocking / streaming 模式下等待任务完成的最长时长（默认 20 分钟），超时返回 504
const MAX_WAIT_MS = Number(process.env.TASK_API_MAX_WAIT_MS || 20 * 60 * 1000);
const POLL_MS = 2000;

const TOKEN = fs.readFileSync(TOKEN_FILE, 'utf8').trim();
if (!TOKEN) {
  console.error('.token 为空，拒绝启动');
  process.exit(1);
}
fs.mkdirSync(TASKS_DIR, { recursive: true });
fs.mkdirSync(FILES_DIR, { recursive: true });

// 结果文件名白名单：字母数字开头，仅含字母/数字/点/下划线/连字符（防路径穿越）
const FILE_NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const FILE_CT = {
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.gif': 'image/gif', '.webp': 'image/webp',
  '.mp4': 'video/mp4', '.webm': 'video/webm',
  '.pdf': 'application/pdf', '.txt': 'text/plain; charset=utf-8',
  '.md': 'text/markdown; charset=utf-8', '.csv': 'text/csv; charset=utf-8',
  '.json': 'application/json', '.xml': 'application/xml',
  '.zip': 'application/zip', '.gz': 'application/gzip', '.tar': 'application/x-tar',
  '.7z': 'application/x-7z-compressed', '.rar': 'application/vnd.rar',
  '.doc': 'application/msword',
  '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.xls': 'application/vnd.ms-excel',
  '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.ppt': 'application/vnd.ms-powerpoint',
  '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  '.epub': 'application/epub+zip',
};

// 生成的图片/视频下载免鉴权（知道链接即可下载，方便浏览器/<img>/<video>/下游程序直接取用）。
// 文件名含任务 UUID、不可猜测；其他类型文件（pdf/zip/json 等）仍需 Bearer 鉴权。
const PUBLIC_MEDIA_EXTS = new Set(['.png', '.jpg', '.jpeg', '.gif', '.webp', '.mp4', '.webm']);

// 上传限制：仅图片，单文件 ≤10MB
const UPLOAD_MAX_MB = 10;
const UPLOAD_MAX_BYTES = UPLOAD_MAX_MB * 1024 * 1024;
// 每个任务最多携带的附件数
const MAX_FILES_PER_TASK = 5;

// multipart 的 filename 头按 latin-1 传输：若客户端按 RFC 7578 实际发送了 UTF-8 字节，
// 这里按 UTF-8 还原（中文文件名乱码修复）；非合法 UTF-8 则原样返回，避免破坏真正的 latin-1 文件名
function decodeFilename(s) {
  if (!s) return '';
  const buf = Buffer.from(s, 'latin1');
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(buf);
  } catch {
    return s;
  }
}

// 按 upload_file_id 定位已上传的图片：只匹配 files/<id>.<ext>（扩展名白名单），
// id 字符集校验 + 目录枚举匹配，不直接拼接路径，防路径穿越
function resolveUploadedFile(fid) {
  if (!fid || typeof fid !== 'string' || !/^[0-9a-fA-F-]{1,64}$/.test(fid)) return null;
  let entries;
  try { entries = fs.readdirSync(FILES_DIR); } catch { return null; }
  for (const e of entries) {
    if (!e.startsWith(fid + '.')) continue;
    const mime = FILE_CT['.' + e.slice(fid.length + 1).toLowerCase()];
    if (!mime) continue;
    try {
      const st = fs.statSync(path.join(FILES_DIR, e));
      if (!st.isFile()) continue;
      return { name: e, mime, size: st.size };
    } catch { continue; }
  }
  return null;
}

// 按文件头魔数识别真实图片类型（不信任客户端上报的扩展名/MIME）
function sniffImage(buf) {
  if (buf.length >= 8 && buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4E && buf[3] === 0x47) {
    return { ext: 'png', mime: 'image/png' };
  }
  if (buf.length >= 3 && buf[0] === 0xFF && buf[1] === 0xD8 && buf[2] === 0xFF) {
    return { ext: 'jpg', mime: 'image/jpeg' };
  }
  if (buf.length >= 6 && buf[0] === 0x47 && buf[1] === 0x49 && buf[2] === 0x46 && buf[3] === 0x38) {
    return { ext: 'gif', mime: 'image/gif' };
  }
  if (buf.length >= 12 && buf.toString('ascii', 0, 4) === 'RIFF' && buf.toString('ascii', 8, 12) === 'WEBP') {
    return { ext: 'webp', mime: 'image/webp' };
  }
  return null;
}

// ---- 任务上下文：context.jsonl（JSONL，每行一条事件），只保留最近 KEEP 条 ----
const CONTEXT_FILE = path.join(DIR, 'context.jsonl');
const CONTEXT_KEEP = 30;
const CONTEXT_TRIM_AT = 45;

function contextAdd(event) {
  try {
    const line = JSON.stringify({ ts: new Date().toISOString(), ...event }) + '\n';
    fs.appendFileSync(CONTEXT_FILE, line);
    const lines = fs.readFileSync(CONTEXT_FILE, 'utf8').split('\n').filter((l) => l.trim() !== '');
    if (lines.length > CONTEXT_TRIM_AT) {
      fs.writeFileSync(CONTEXT_FILE, lines.slice(-CONTEXT_KEEP).join('\n') + '\n');
    }
  } catch (e) {
    console.error('context log error:', e.message);
  }
}

function contextRead() {
  try {
    if (!fs.existsSync(CONTEXT_FILE)) return [];
    return fs.readFileSync(CONTEXT_FILE, 'utf8')
      .split('\n').filter((l) => l.trim() !== '')
      .slice(-CONTEXT_KEEP).map((l) => JSON.parse(l));
  } catch (e) {
    console.error('context read error:', e.message);
    return [];
  }
}

// ---- 任务执行日志：logs/<task-uuid>.jsonl（持久化，不淘汰） ----
// context.jsonl 只保留最近 30 条供执行器找连续性；这里记全量审计日志：
// 任务生命周期（created/running/done/failed，result 全量）+ 执行器分步记录。
// 查看：bash task-log.sh <task-uuid>；保留策略：30 天 + 总量 200MB（见 prune-task-logs.sh）
const LOGS_DIR = path.join(DIR, 'logs');
const TASK_ID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function taskLog(taskId, event) {
  try {
    if (!TASK_ID_RE.test(taskId)) return; // 防路径穿越：只接受标准 uuid
    fs.mkdirSync(LOGS_DIR, { recursive: true });
    const line = JSON.stringify({ ts: new Date().toISOString(), task_id: taskId, ...event }) + '\n';
    fs.appendFileSync(path.join(LOGS_DIR, `${taskId}.jsonl`), line);
  } catch (e) {
    console.error('task log error:', e.message);
  }
}

// ---- 会话元信息（重命名）：conversations.json ----
const CONV_META_FILE = path.join(DIR, 'conversations.json');
function readConvMeta() {
  try {
    if (!fs.existsSync(CONV_META_FILE)) return {};
    const m = JSON.parse(fs.readFileSync(CONV_META_FILE, 'utf8'));
    return m && typeof m === 'object' ? m : {};
  } catch {
    return {};
  }
}
function writeConvMeta(meta) {
  const tmp = CONV_META_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(meta, null, 2));
  fs.renameSync(tmp, CONV_META_FILE);
}

// ---- 任务存储 ----
const TASK_FILE_RE = /^[0-9a-f-]{36}\.json$/;

function taskPath(id) {
  return path.join(TASKS_DIR, id + '.json');
}

// 原子写：先写临时文件再 rename，避免执行器回写时读到半截 JSON
function atomicWrite(task) {
  const f = taskPath(task.id);
  const tmp = f + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(task, null, 2));
  fs.renameSync(tmp, f);
}

function loadTaskById(id) {
  try {
    if (!/^[0-9a-f-]{36}$/.test(id)) return null;
    const f = taskPath(id);
    if (!fs.existsSync(f)) return null;
    return JSON.parse(fs.readFileSync(f, 'utf8'));
  } catch {
    return null; // 执行器正在回写时可能读到半截文件，调用方重试即可
  }
}

function listTasks() {
  let files = [];
  try {
    files = fs.readdirSync(TASKS_DIR).filter((f) => TASK_FILE_RE.test(f));
  } catch {
    return [];
  }
  const tasks = [];
  for (const f of files) {
    try {
      tasks.push(JSON.parse(fs.readFileSync(path.join(TASKS_DIR, f), 'utf8')));
    } catch { /* 跳过损坏文件 */ }
  }
  tasks.sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
  return tasks;
}

// 按 task_id（执行控制 ID）查找任务；老任务没有 task_id 字段时用 id 兜底
function findTaskByTaskId(taskId) {
  for (const t of listTasks()) {
    if (t.task_id === taskId || (!t.task_id && t.id === taskId)) return t;
  }
  return null;
}

// Dify 风格 helpers ----
function parseLimit(url) {
  const raw = url.searchParams.get('limit');
  if (raw === null) return { ok: true, limit: 20 };
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 1 || n > 100) return { ok: false };
  return { ok: true, limit: n };
}
const CONV_SORTS = new Set(['created_at', '-created_at', 'updated_at', '-updated_at']);
function conversationComparator(sortBy) {
  const desc = sortBy.startsWith('-');
  const key = desc ? sortBy.slice(1) : sortBy;
  const k = key === 'created_at' ? 'created_at' : 'updated_at';
  return (a, b) => (desc ? b[k] - a[k] : a[k] - b[k]);
}
function send(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
  });
  res.end(body);
}

// Dify 错误格式：{"status": <http>, "code": "<snake_case>", "message": "<人类可读原因>"}
function difyErr(res, status, code, message) {
  return send(res, status, { status, code, message });
}

const toSec = (iso) => Math.floor(new Date(iso).getTime() / 1000);
const nowIso = () => new Date().toISOString();
const ZERO_USAGE = { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 };

function authorized(req) {
  const h = req.headers['authorization'] || '';
  // 固定时间比较，防时序攻击
  const a = Buffer.from(h);
  const b = Buffer.from(`Bearer ${TOKEN}`);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

// 文件下载：文件名白名单校验 + 仅读 files/ 目录；调用方决定是否先过鉴权闸门
// （图片/视频免鉴权直达，其他文件鉴权后才走到这里）
function serveDownload(res, name) {
  if (!FILE_NAME_RE.test(name)) {
    return difyErr(res, 400, 'invalid_param', 'Invalid file name.');
  }
  const fp = path.join(FILES_DIR, name);
  let st = null;
  try { st = fs.statSync(fp); } catch { /* 不存在 */ }
  if (!st || !st.isFile()) return difyErr(res, 404, 'not_found', 'File not found.');
  const ct = FILE_CT[path.extname(name).toLowerCase()] || 'application/octet-stream';
  // no-store：禁止 Cloudflare 边缘及任何中间缓存留存，每次下载都回源取最新文件
  res.writeHead(200, { 'Content-Type': ct, 'Content-Length': st.size, 'Cache-Control': 'no-store' });
  return fs.createReadStream(fp).pipe(res);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', (c) => {
      data += c;
      if (data.length > 1e6) {
        req.destroy();
        reject(new Error('body too large'));
      }
    });
    req.on('end', () => resolve(data));
    req.on('error', reject);
  });
}

// ---- 任务创建（Dify chat-messages） ----
function createChatTask({ query, inputs, conversation_id, user, files }) {
  const id = crypto.randomUUID();       // message_id，也是任务文件名
  const taskId = crypto.randomUUID();   // task_id，执行控制用（stop 接口）
  const convId = conversation_id || crypto.randomUUID();
  const now = nowIso();
  const task = {
    id,
    task_id: taskId,
    query,
    inputs: inputs || {},
    conversation_id: convId,
    user: user || null,
    files: files || [], // 经校验的附件（upload_file_id + stored_name），执行器按 stored_name 精确读取
    status: 'pending', // pending -> running -> done | failed；pending 可被 stop 为 stopped
    result: null,
    feedback: null,
    created_at: now,
    updated_at: now,
  };
  atomicWrite(task);
  contextAdd({
    type: 'task_created',
    task_id: id,
    conversation_id: convId,
    task: query.slice(0, 500),
  });
  taskLog(id, {
    type: 'task_created',
    conversation_id: convId,
    user: user || null,
    query, // 全量
    files: (files || []).map((f) => ({ upload_file_id: f.upload_file_id, stored_name: f.stored_name, mime_type: f.mime_type })),
  });
  return task;
}

// 等待任务进入终态（done/failed/stopped），超时抛 RUN_TIMEOUT 错误
function waitForTerminal(id, timeoutMs) {
  return new Promise((resolve, reject) => {
    const started = Date.now();
    const check = () => {
      const t = loadTaskById(id);
      if (t && (t.status === 'done' || t.status === 'failed' || t.status === 'stopped')) {
        clearInterval(timer);
        resolve(t);
        return true;
      }
      return false;
    };
    if (check()) return;
    const timer = setInterval(() => {
      if (check()) return;
      if (Date.now() - started > timeoutMs) {
        clearInterval(timer);
        const e = new Error('run timeout');
        e.code = 'RUN_TIMEOUT';
        reject(e);
      }
    }, POLL_MS);
  });
}

// 从上下文中提取某任务的执行摘要，转成 Dify agent_thoughts
function thoughtsFor(task, events) {
  const notes = events.filter((e) => e.type === 'execution_notes' && e.task_id === task.id);
  return notes.map((n, i) => ({
    id: `${task.id}:thought:${i + 1}`,
    message_id: task.id,
    position: i + 1,
    thought: String(n.summary || '').slice(0, 2000),
    observation: '',
    tool: '',
    tool_input: '',
    created_at: toSec(n.ts),
  }));
}

function toDifyMessage(task, events) {
  const failed = task.status === 'failed';
  return {
    id: task.id,
    conversation_id: task.conversation_id || null,
    inputs: task.inputs || {},
    query: task.query || task.task || '',
    message_files: (task.files || []).map((f) => ({
      id: f.upload_file_id,
      type: f.type,
      filename: f.stored_name,
      mime_type: f.mime_type,
      size: f.size,
    })),
    agent_thoughts: thoughtsFor(task, events || []),
    answer: task.result || '',
    feedback: task.feedback || null,
    retriever_resources: [],
    status: failed ? 'error' : 'normal',
    created_at: toSec(task.created_at),
  };
}

// ---- SSE 流式推送（Dify agent 事件：agent_thought -> agent_message -> message_end） ----
function streamChat(task, req, res) {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive',
    'X-Accel-Buffering': 'no',
  });
  const base = {
    task_id: task.task_id,
    id: task.id, // Dify 事件主键；message_id 保留做兼容
    message_id: task.id,
    conversation_id: task.conversation_id,
  };
  const write = (obj) => {
    // SSE 规范：每个事件都带独立的 event: 名称行（Dify 亦如此）
    try { res.write(`event: ${obj.event}\ndata: ${JSON.stringify(obj)}\n\n`); } catch { /* 客户端已断开 */ }
  };
  let pos = 0;
  let finished = false;
  const finish = () => {
    if (finished) return;
    finished = true;
    clearInterval(poll);
    clearInterval(ping);
    try { res.end(); } catch { /* ignore */ }
  };
  const thought = (text, observation = '') => write({
    event: 'agent_thought',
    ...base,
    position: ++pos,
    thought: text,
    observation,
    tool: '',
    tool_labels: {},
    tool_input: '',
    message_files: [],
    created_at: Math.floor(Date.now() / 1000),
  });

  // Dify 兼容：流的第一个事件是 message（answer 为空），让客户端立刻拿到 id
  write({ event: 'message', ...base, answer: '', created_at: Math.floor(Date.now() / 1000) });
  res.write('event: ping\n\n');
  thought('已收到任务，等待执行器领取');

  let sawRunning = false;
  let seenNotes = 0;
  const started = Date.now();

  const poll = setInterval(() => {
    if (finished) return;
    const t = loadTaskById(task.id);
    if (!t) return;
    if (!sawRunning && t.status === 'running') {
      sawRunning = true;
      thought('执行器开始执行任务');
    }
    // 执行中途写入的 execution_notes 转成 agent_thought 实时推送
    const notes = contextRead().filter((e) => e.type === 'execution_notes' && e.task_id === task.id);
    while (seenNotes < notes.length) {
      const n = notes[seenNotes++];
      thought('执行进度更新', String(n.summary || '').slice(0, 2000));
    }
    if (t.status === 'done' || t.status === 'failed' || t.status === 'stopped') {
      if (t.status === 'done') {
        write({ event: 'agent_message', ...base, answer: t.result, created_at: Math.floor(Date.now() / 1000) });
        write({
          event: 'message_end', ...base,
          metadata: { usage: ZERO_USAGE, retriever_resources: [] },
          files: [],
          created_at: Math.floor(Date.now() / 1000),
        });
      } else if (t.status === 'stopped') {
        write({ event: 'error', status: 409, code: 'task_stopped', message: 'The task was stopped before completion.' });
      } else {
        write({ event: 'error', status: 500, code: 'agent_failed', message: String(t.result || 'Task failed.').slice(0, 2000) });
      }
      finish();
    } else if (Date.now() - started > MAX_WAIT_MS) {
      write({ event: 'error', status: 504, code: 'run_timeout', message: 'Task did not finish within the server wait limit; poll GET /v1/messages for the result.' });
      finish();
    }
  }, POLL_MS);

  const ping = setInterval(() => {
    try { res.write('event: ping\n\n'); } catch { /* ignore */ }
  }, 15000);

  req.on('close', finish);
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');

    if (url.pathname === '/health' && req.method === 'GET') {
      return send(res, 200, { ok: true, time: new Date().toISOString() });
    }

    // 图片/视频下载免鉴权：先于鉴权闸门处理；其他扩展名不匹配则落到闸门后按鉴权下载
    if (req.method === 'GET' && url.pathname.startsWith('/v1/files/')) {
      let pubName = null;
      try { pubName = decodeURIComponent(url.pathname.slice('/v1/files/'.length)); } catch { pubName = null; }
      if (pubName && PUBLIC_MEDIA_EXTS.has(path.extname(pubName).toLowerCase())) {
        return serveDownload(res, pubName);
      }
    }

    if (!authorized(req)) {
      // /v1 用 Dify 错误格式
      if (url.pathname.startsWith('/v1/')) {
        return difyErr(res, 401, 'unauthorized', 'Invalid API key.');
      }
      return send(res, 401, { error: 'unauthorized' });
    }

    // ============ Dify Chat API ============

    // 发送消息（下发任务）
    if (req.method === 'POST' && url.pathname === '/v1/chat-messages') {
      let body;
      try {
        body = JSON.parse((await readBody(req)) || '{}');
      } catch {
        return difyErr(res, 400, 'invalid_param', 'Request body must be valid JSON.');
      }
      const query = body.query;
      if (!query || typeof query !== 'string' || !query.trim()) {
        return difyErr(res, 400, 'invalid_param', 'Field "query" (string) is required.');
      }
      const responseMode = body.response_mode || 'blocking'; // Dify 要求必填；缺省按 blocking 处理
      if (responseMode !== 'blocking' && responseMode !== 'streaming') {
        return difyErr(res, 400, 'invalid_param', 'Field "response_mode" must be "blocking" or "streaming".');
      }
      if (body.inputs !== undefined && (typeof body.inputs !== 'object' || body.inputs === null || Array.isArray(body.inputs))) {
        return difyErr(res, 400, 'invalid_param', 'Field "inputs" must be an object.');
      }
      // files 参数：图片附件（Dify 风格），引用经 POST /v1/files/upload 上传的文件。
      // 逐项校验类型与存在性，解析为执行器可直接读取的本地文件名；非法直接 400，
      // 不让"附件已送达"的假象传到执行器（曾导致执行器猜测文件产出错误答案）。
      let taskFiles = [];
      if (body.files !== undefined && body.files !== null) {
        if (!Array.isArray(body.files)) {
          return difyErr(res, 400, 'invalid_param', 'Field "files" must be an array.');
        }
        if (body.files.length > MAX_FILES_PER_TASK) {
          return difyErr(res, 400, 'invalid_param', `Field "files" accepts at most ${MAX_FILES_PER_TASK} files.`);
        }
        for (const f of body.files) {
          if (!f || typeof f !== 'object' || Array.isArray(f)) {
            return difyErr(res, 400, 'invalid_param', 'Each entry in "files" must be an object.');
          }
          if (f.type !== 'image') {
            return difyErr(res, 400, 'invalid_param', 'Only "image" type is supported in "files".');
          }
          if (f.transfer_method !== 'local_file') {
            return difyErr(res, 400, 'invalid_param', 'Only "local_file" transfer_method is supported in "files"; upload via POST /v1/files/upload first.');
          }
          const fid = f.upload_file_id;
          if (!fid || typeof fid !== 'string') {
            return difyErr(res, 400, 'invalid_param', 'Each entry in "files" must include "upload_file_id".');
          }
          const resolved = resolveUploadedFile(fid);
          if (!resolved) {
            return difyErr(res, 400, 'invalid_param', `upload_file_id not found: ${String(fid).slice(0, 64)}`);
          }
          taskFiles.push({
            type: 'image',
            transfer_method: 'local_file',
            upload_file_id: fid,
            stored_name: resolved.name,
            mime_type: resolved.mime,
            size: resolved.size,
          });
        }
      }
      if (body.conversation_id !== undefined && typeof body.conversation_id !== 'string') {
        return difyErr(res, 400, 'invalid_param', 'Field "conversation_id" must be a string.');
      }
      const task = createChatTask({
        query,
        inputs: body.inputs,
        conversation_id: body.conversation_id || null,
        user: body.user,
        files: taskFiles,
      });

      if (responseMode === 'streaming') {
        return streamChat(task, req, res);
      }

      // blocking：等执行完成再返回
      try {
        const final = await waitForTerminal(task.id, MAX_WAIT_MS);
        if (final.status === 'done') {
          // Dify 结构：内容包在 data 里；平铺字段保留做向后兼容
          const data = {
            id: final.id,
            message_id: final.id,
            conversation_id: final.conversation_id,
            mode: 'chat',
            answer: final.result,
            metadata: { usage: ZERO_USAGE, retriever_resources: [] },
            created_at: toSec(final.created_at),
          };
          return send(res, 200, {
            event: 'message',
            task_id: final.task_id,
            ...data,
            data,
          });
        }
        if (final.status === 'stopped') {
          return difyErr(res, 409, 'task_stopped', 'The task was stopped before completion.');
        }
        return difyErr(res, 500, 'agent_failed', String(final.result || 'Task failed.').slice(0, 2000));
      } catch (e) {
        if (e && e.code === 'RUN_TIMEOUT') {
          return difyErr(res, 504, 'run_timeout', 'Task did not finish within the server wait limit; poll GET /v1/messages for the result.');
        }
        throw e;
      }
    }

    // 停止任务（仅 pending 可停止）
    const mStop = url.pathname.match(/^\/v1\/chat-messages\/([0-9a-f-]{36})\/stop$/);
    if (req.method === 'POST' && mStop) {
      const t = findTaskByTaskId(mStop[1]);
      if (!t) return difyErr(res, 404, 'not_found', 'Task not found.');
      if (t.status !== 'pending') {
        return difyErr(res, 400, 'cannot_stop', `Only pending tasks can be stopped (current status: ${t.status}).`);
      }
      t.status = 'stopped';
      t.updated_at = nowIso();
      atomicWrite(t);
      contextAdd({ type: 'task_status', task_id: t.id, conversation_id: t.conversation_id || null, status: 'stopped', result_excerpt: '' });
      taskLog(t.id, { type: 'task_stopped', conversation_id: t.conversation_id || null });
      return send(res, 200, { result: 'success' });
    }

    // 会话列表（Dify 兼容：user / last_id / sort_by）
    if (req.method === 'GET' && url.pathname === '/v1/conversations') {
      const user = url.searchParams.get('user') || null;
      const parsed = parseLimit(url);
      if (!parsed.ok) return difyErr(res, 400, 'invalid_param', 'Field "limit" must be an integer between 1 and 100.');
      const limit = parsed.limit;
      const lastId = url.searchParams.get('last_id') || null;
      const sortBy = url.searchParams.get('sort_by') || '-updated_at';
      if (!CONV_SORTS.has(sortBy)) {
        return difyErr(res, 400, 'invalid_param', 'Field "sort_by" must be one of: created_at, -created_at, updated_at, -updated_at.');
      }
      const convMeta = readConvMeta();
      const convs = new Map();
      for (const t of listTasks()) {
        const cid = t.conversation_id;
        if (!cid) continue; // Dify 风格改造前的老任务不计入
        if (user && t.user !== user) continue; // 传了 user 则按用户隔离
        const cSec = toSec(t.created_at);
        const uSec = toSec(t.updated_at);
        if (!convs.has(cid)) {
          convs.set(cid, {
            id: cid,
            name: (convMeta[cid] && convMeta[cid].name) || (t.query || t.task || '').slice(0, 40) || '未命名会话',
            inputs: t.inputs || {},
            introduction: '',
            status: 'normal',
            created_at: cSec,
            updated_at: uSec,
          });
        } else {
          const c = convs.get(cid);
          c.created_at = Math.min(c.created_at, cSec);
          c.updated_at = Math.max(c.updated_at, uSec);
        }
      }
      const all = [...convs.values()].sort(conversationComparator(sortBy));
      let start = 0;
      if (lastId) {
        const idx = all.findIndex((c) => c.id === lastId);
        if (idx >= 0) start = idx + 1;
      }
      const page = all.slice(start, start + limit);
      return send(res, 200, { limit, has_more: start + page.length < all.length, data: page });
    }

    // 会话重命名
    const mRename = url.pathname.match(/^\/v1\/conversations\/([0-9a-f-]{36})\/name$/);
    if (req.method === 'POST' && mRename) {
      let body;
      try {
        body = JSON.parse((await readBody(req)) || '{}');
      } catch {
        return difyErr(res, 400, 'invalid_param', 'Request body must be valid JSON.');
      }
      const name = body.name;
      if (!name || typeof name !== 'string' || !name.trim()) {
        return difyErr(res, 400, 'invalid_param', 'Field "name" (string) is required.');
      }
      const exists = listTasks().some((t) => t.conversation_id === mRename[1]);
      if (!exists) return difyErr(res, 404, 'not_found', 'Conversation not found.');
      const meta = readConvMeta();
      meta[mRename[1]] = { ...(meta[mRename[1]] || {}), name: name.trim().slice(0, 100) };
      writeConvMeta(meta);
      return send(res, 200, { result: 'success' });
    }

    // 会话删除（204）
    const mDelConv = url.pathname.match(/^\/v1\/conversations\/([0-9a-f-]{36})$/);
    if (req.method === 'DELETE' && mDelConv) {
      const cid = mDelConv[1];
      const targets = listTasks().filter((t) => t.conversation_id === cid);
      if (!targets.length) return difyErr(res, 404, 'not_found', 'Conversation not found.');
      for (const t of targets) {
        try { fs.unlinkSync(taskPath(t.id)); } catch { /* ignore */ }
      }
      const meta = readConvMeta();
      if (meta[cid]) {
        delete meta[cid];
        writeConvMeta(meta);
      }
      res.writeHead(204);
      return res.end();
    }

    // 历史消息
    if (req.method === 'GET' && url.pathname === '/v1/messages') {
      const parsed = parseLimit(url);
      if (!parsed.ok) return difyErr(res, 400, 'invalid_param', 'Field "limit" must be an integer between 1 and 100.');
      const limit = parsed.limit;
      const conv = url.searchParams.get('conversation_id');
      const firstId = url.searchParams.get('first_id');
      const user = url.searchParams.get('user') || null;
      let tasks = listTasks().filter((t) => !conv || t.conversation_id === conv);
      if (user) tasks = tasks.filter((t) => t.user === user); // 传了 user 则按用户隔离
      if (firstId) {
        const idx = tasks.findIndex((t) => t.id === firstId);
        if (idx >= 0) tasks = tasks.slice(idx + 1);
      }
      const events = contextRead();
      const data = tasks.slice(0, limit).map((t) => toDifyMessage(t, events));
      return send(res, 200, { limit, has_more: tasks.length > limit, data });
    }

    // 消息反馈
    const mFb = url.pathname.match(/^\/v1\/messages\/([0-9a-f-]{36})\/feedbacks$/);
    if (req.method === 'POST' && mFb) {
      let body;
      try {
        body = JSON.parse((await readBody(req)) || '{}');
      } catch {
        return difyErr(res, 400, 'invalid_param', 'Request body must be valid JSON.');
      }
      const t = loadTaskById(mFb[1]);
      if (!t) return difyErr(res, 404, 'not_found', 'Message not found.');
      if (body.rating === null || body.rating === undefined) {
        t.feedback = null; // Dify 语义：rating 为 null 表示撤销反馈
      } else {
        if (body.rating !== 'like' && body.rating !== 'dislike') {
          return difyErr(res, 400, 'invalid_param', 'Field "rating" must be "like", "dislike" or null.');
        }
        t.feedback = {
          rating: body.rating,
          user: body.user || null,
          content: typeof body.content === 'string' ? body.content : null,
          created_at: nowIso(),
        };
      }
      t.updated_at = nowIso();
      atomicWrite(t);
      return send(res, 200, { result: 'success' });
    }

    // 推荐问题（暂不支持生成，返回空列表以保持接口形状兼容）
    const mSug = url.pathname.match(/^\/v1\/messages\/([0-9a-f-]{36})\/suggested$/);
    if (req.method === 'GET' && mSug) {
      const t = loadTaskById(mSug[1]);
      if (!t) return difyErr(res, 404, 'not_found', 'Message not found.');
      return send(res, 200, { data: [] });
    }

    // 应用参数（能力声明：本执行器为纯文本任务型，无多模态/语音/检索）
    if (req.method === 'GET' && url.pathname === '/v1/parameters') {
      return send(res, 200, {
        opening_statement: '',
        suggested_questions: [],
        suggested_questions_after_answer: { enabled: false },
        speech_to_text: { enabled: false },
        text_to_speech: { enabled: false, voice: '', language: '' },
        retriever_resource: { enabled: false },
        annotation_reply: { enabled: false },
        user_input_form: [],
        sensitive_word_avoidance: { enabled: false },
        file_upload: {
          image: { enabled: true, number_limits: MAX_FILES_PER_TASK, transfer_methods: ['local_file'] },
        },
      });
    }

    // 应用 meta
    if (req.method === 'GET' && url.pathname === '/v1/meta') {
      return send(res, 200, { tool_icons: {} });
    }

    // 应用信息
    if (req.method === 'GET' && url.pathname === '/v1/info') {
      return send(res, 200, {
        name: 'muse',
        description: 'Muse task dispatch API — Dify Chat API compatible',
        tags: ['chatbot'],
      });
    }

    // 文件上传（Dify 兼容：仅图片；multipart/form-data，字段 file 必填、user 选填）
    if (req.method === 'POST' && url.pathname === '/v1/files/upload') {
      const ctype = req.headers['content-type'] || '';
      if (!ctype.startsWith('multipart/form-data')) {
        return difyErr(res, 400, 'invalid_param', 'Content-Type must be multipart/form-data.');
      }
      let busboy;
      try {
        busboy = Busboy({ headers: req.headers, limits: { files: 1, fields: 10, fileSize: UPLOAD_MAX_BYTES } });
      } catch {
        return difyErr(res, 400, 'invalid_param', 'Invalid multipart body.');
      }
      let responded = false;
      const fail = (status, code, message) => {
        if (responded) return;
        responded = true;
        try { req.unpipe(busboy); } catch { /* 忽略 */ }
        req.resume(); // 排空请求体，避免连接挂起
        difyErr(res, status, code, message);
      };
      let fileCount = 0;
      let fileInfo = null;
      const chunks = [];
      let truncated = false;
      let fieldUser = null;
      busboy.on('file', (name, file, info) => {
        fileCount++;
        if (name !== 'file' || fileCount > 1) {
          file.resume();
          fail(400, 'invalid_param', 'Only one file field named "file" is accepted.');
          return;
        }
        fileInfo = info;
        file.on('data', (d) => { chunks.push(d); });
        file.on('limit', () => { truncated = true; });
      });
      busboy.on('field', (name, val) => { if (name === 'user') fieldUser = String(val); });
      busboy.on('error', () => fail(400, 'invalid_param', 'Invalid multipart body.'));
      busboy.on('finish', () => {
        if (responded) return;
        if (!fileInfo || chunks.length === 0) {
          fail(400, 'invalid_param', 'Field "file" is required.');
          return;
        }
        if (truncated) {
          fail(413, 'file_too_large', `File too large (max ${UPLOAD_MAX_MB}MB).`);
          return;
        }
        const buf = Buffer.concat(chunks);
        const kind = sniffImage(buf);
        if (!kind) {
          fail(400, 'invalid_param', 'Only image files are accepted (png/jpeg/gif/webp).');
          return;
        }
        const id = crypto.randomUUID();
        const stored = `${id}.${kind.ext}`;
        try {
          fs.writeFileSync(path.join(FILES_DIR, stored), buf);
        } catch {
          fail(500, 'internal_error', 'Failed to store uploaded file.');
          return;
        }
        responded = true;
        send(res, 201, {
          id,
          name: decodeFilename(fileInfo.filename || stored).slice(0, 200),
          size: buf.length,
          extension: kind.ext,
          mime_type: kind.mime,
          created_by: fieldUser || null,
          created_at: Math.floor(Date.now() / 1000),
        });
      });
      req.pipe(busboy);
      return; // 响应在 finish/fail 回调中发出
    }

    // 文件下载（鉴权后到达此处的是其他文件；图片/视频已在鉴权闸门前免鉴权处理）
    if (req.method === 'GET' && url.pathname.startsWith('/v1/files/')) {
      const name = decodeURIComponent(url.pathname.slice('/v1/files/'.length));
      return serveDownload(res, name);
    }

    // ============ 未知路径 ============

    if (url.pathname.startsWith('/v1/')) {
      return difyErr(res, 404, 'not_found', 'Endpoint not found.');
    }
    return send(res, 404, { error: 'not found' });
  } catch (e) {
    console.error('request error:', e.message);
    if (req.url && req.url.startsWith('/v1/')) {
      return difyErr(res, 500, 'internal_error', 'Internal server error.');
    }
    return send(res, 500, { error: 'internal error' });
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`task-api listening on 127.0.0.1:${PORT}`);
});
