// Cloudflare Worker：把固定域名反向代理到 ngrok 隧道
// 部署时 __UPSTREAM__ 会被替换为当前 ngrok 公网地址
const UPSTREAM = "__UPSTREAM__";

export default {
  async fetch(request) {
    const incoming = new URL(request.url);
    const target = new URL(UPSTREAM + incoming.pathname + incoming.search);
    const headers = new Headers(request.headers);
    headers.set("Host", target.host);
    return fetch(target.toString(), {
      method: request.method,
      headers,
      body: request.method === "GET" || request.method === "HEAD" ? undefined : request.body,
      redirect: "manual",
      duplex: "half",
    });
  },
};
