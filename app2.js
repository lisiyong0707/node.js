'use strict';
/*
 * VLESS over WebSocket 服务端（仅 TCP）。
 * TLS 由平台 / Caddy / Nginx / Cloudflare 终结，本程序只监听明文 HTTP。
 *
 * 环境变量：
 *   UUID           认证用 UUID（留空则每次启动随机生成）
 *   PORT           监听端口（托管平台会自动注入）
 *   DOMAIN         你的域名，用于生成分享链接
 *   PUBLIC_PORT    对外端口，默认 443
 *   NAME           节点名称，默认 vless-node
 *   WS_PATH        WebSocket 路径，默认 /ws
 *   SUB_PATH       订阅路径，默认 lyl（访问 https://域名/lyl 查看分享链接）
 *   ALLOW_PRIVATE  设为 1 才允许访问内网/回环地址，默认禁止
 */

const http = require('http');
const net = require('net');
const dns = require('dns').promises;
const crypto = require('crypto');
const { WebSocketServer, createWebSocketStream } = require('ws');

const PORT = process.env.PORT || 3000;
const DOMAIN = process.env.DOMAIN || 'example.com';
const PUBLIC_PORT = process.env.PUBLIC_PORT || '443';
const NAME = process.env.NAME || 'vless-node';
const WS_PATH = '/' + (process.env.WS_PATH || '/ws').replace(/^\/+/, '');
const UUID = process.env.UUID || crypto.randomUUID();
const SUB_PATH = (process.env.SUB_PATH || 'lyl').replace(/^\/+/, '');
const ALLOW_PRIVATE = process.env.ALLOW_PRIVATE === '1';

const HANDSHAKE_TIMEOUT = 10_000;
const DNS_TIMEOUT = 5_000;
const CONNECT_TIMEOUT = 10_000;
const IDLE_TIMEOUT = 5 * 60_000;

const uuidBuf = Buffer.from(UUID.replace(/-/g, ''), 'hex');
if (uuidBuf.length !== 16) {
  console.error('UUID 格式不正确');
  process.exit(1);
}

/* ---------------- 伪装站点 ---------------- */

const layout = (title, body) => `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title} · Field Notes</title>
<style>
  body{margin:0;font:17px/1.7 Georgia,serif;color:#222;background:#fafaf7}
  header{border-bottom:1px solid #e4e2da;padding:1.2rem 0}
  .w{max-width:680px;margin:0 auto;padding:0 1.2rem}
  nav a{margin-right:1.2rem;color:#555;text-decoration:none;font:15px system-ui,sans-serif}
  nav a:hover{color:#000}
  h1{font-size:1.9rem;margin:2rem 0 .3rem}
  .meta{color:#888;font:14px system-ui,sans-serif;margin-bottom:1.5rem}
  article{margin:2rem 0;padding-bottom:1.5rem;border-bottom:1px solid #eee}
  article h2{margin:0 0 .2rem;font-size:1.3rem}
  article h2 a{color:#222;text-decoration:none}
  footer{color:#999;font:13px system-ui,sans-serif;padding:2rem 0}
</style></head><body>
<header><div class="w"><nav><a href="/">Home</a><a href="/about">About</a><a href="/posts/slow-mornings">Slow mornings</a><a href="/posts/notes-on-bread">Notes on bread</a></nav></div></header>
<main class="w">${body}</main>
<footer><div class="w">© ${new Date().getFullYear()} Field Notes. All rights reserved.</div></footer>
</body></html>`;

const PAGES = {
  '/': layout('Home', `
    <h1>Field Notes</h1><p class="meta">Small essays on food, routine and quiet places.</p>
    <article><h2><a href="/posts/slow-mornings">Slow mornings</a></h2><div class="meta">March 3</div>
      <p>I used to treat the first hour of the day as a runway. Lately I treat it as a destination.</p></article>
    <article><h2><a href="/posts/notes-on-bread">Notes on bread</a></h2><div class="meta">February 11</div>
      <p>Three loaves, one oven, and a long argument with hydration percentages.</p></article>`),
  '/about': layout('About', `
    <h1>About</h1><p class="meta">A personal notebook</p>
    <p>Field Notes is a small, slow-moving blog. Posts appear when there is something worth writing down, which is less often than I would like.</p>
    <p>Thanks for reading.</p>`),
  '/posts/slow-mornings': layout('Slow mornings', `
    <h1>Slow mornings</h1><p class="meta">March 3 · 4 min read</p>
    <p>I used to treat the first hour of the day as a runway: coffee, inbox, out the door. Lately I treat it as a destination.</p>
    <p>The change was small. I stopped reaching for my phone, boiled water without hurry, and sat by the window while the street woke up. Nothing dramatic happened, which was exactly the point.</p>
    <p>By the time the day's demands arrived, I had already had one good hour that belonged to no one else.</p>`),
  '/posts/notes-on-bread': layout('Notes on bread', `
    <h1>Notes on bread</h1><p class="meta">February 11 · 6 min read</p>
    <p>Three loaves, one oven, and a long argument with hydration percentages. The first loaf was a brick. The second was a decent brick.</p>
    <p>The third rose properly, and the crust crackled as it cooled. I have been chasing that sound ever since.</p>`),
};

const NOT_FOUND = layout('Not found', '<h1>404</h1><p>That page could not be found.</p>');

/* ---------------- 工具函数 ---------------- */

// 用 BlockList 判断内网地址，自动处理 IPv6 压缩形式与 ::ffff:x.x.x.x 映射地址
const blocked = new net.BlockList();
for (const [a, p] of [
  ['0.0.0.0', 8], ['10.0.0.0', 8], ['100.64.0.0', 10], ['127.0.0.0', 8],
  ['169.254.0.0', 16], ['172.16.0.0', 12], ['192.168.0.0', 16],
  ['198.18.0.0', 15], ['224.0.0.0', 3],
]) blocked.addSubnet(a, p, 'ipv4');
for (const [a, p] of [
  ['::', 128], ['::1', 128], ['fc00::', 7], ['fe80::', 10], ['ff00::', 8],
]) blocked.addSubnet(a, p, 'ipv6');

const isPrivate = (ip) => blocked.check(ip, net.isIPv4(ip) ? 'ipv4' : 'ipv6');

const withTimeout = (p, ms) =>
  Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), ms))]);

// VLESS 请求头：版本(1) | UUID(16) | 附加长度(1) | 附加信息 | 命令(1) | 端口(2) | 地址类型(1) | 地址
function parseHeader(msg) {
  if (msg.length < 24) return null;
  const version = msg[0];
  if (!crypto.timingSafeEqual(msg.subarray(1, 17), uuidBuf)) return null;

  let i = 17;
  i += 1 + msg[i];
  if (i + 4 > msg.length) return null;

  if (msg[i++] !== 1) return null; // 仅支持 TCP
  const port = msg.readUInt16BE(i);
  i += 2;

  const atyp = msg[i++];
  let host;
  if (atyp === 1) {
    if (i + 4 > msg.length) return null;
    host = [...msg.subarray(i, i + 4)].join('.');
    i += 4;
  } else if (atyp === 2) {
    const len = msg[i++];
    if (!len || i + len > msg.length) return null;
    host = msg.toString('utf8', i, i + len);
    i += len;
  } else if (atyp === 3) {
    if (i + 16 > msg.length) return null;
    const parts = [];
    for (let k = 0; k < 8; k++) parts.push(msg.readUInt16BE(i + k * 2).toString(16));
    host = parts.join(':');
    i += 16;
  } else {
    return null;
  }
  return { version, host, port, payload: msg.subarray(i) };
}

/* ---------------- HTTP 服务 ---------------- */

const shareLink =
  `vless://${UUID}@${DOMAIN}:${PUBLIC_PORT}?encryption=none&security=tls&sni=${DOMAIN}` +
  `&fp=chrome&type=ws&host=${DOMAIN}&path=${encodeURIComponent(WS_PATH)}#${encodeURIComponent(NAME)}`;

const server = http.createServer((req, res) => {
  const url = (req.url || '/').split('?')[0];
  if (url === `/${SUB_PATH}`) {
    res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
    return res.end(shareLink + '\n');
  }
  const page = PAGES[url.replace(/\/+$/, '') || '/'];
  res.writeHead(page ? 200 : 404, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(page || NOT_FOUND);
});

/* ---------------- WebSocket / VLESS ---------------- */

const wss = new WebSocketServer({ noServer: true, maxPayload: 4 * 1024 * 1024 });

server.on('upgrade', (req, socket, head) => {
  const path = (req.url || '').split('?')[0];
  if (path !== WS_PATH) {
    // 与普通 404 保持一致，避免被探测
    const body = Buffer.from(NOT_FOUND);
    socket.on('error', () => {});
    return socket.end(Buffer.concat([
      Buffer.from(
        'HTTP/1.1 404 Not Found\r\nContent-Type: text/html; charset=utf-8\r\n' +
        `Content-Length: ${body.length}\r\nConnection: close\r\n\r\n`
      ),
      body,
    ]));
  }
  wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws, req));
});

wss.on('connection', (ws) => {
  ws.on('error', () => {});

  let sock = null;
  let duplex = null;
  let closed = false;
  let connectTimer = null;

  // 握手超时：一直不发首包的连接直接断开
  const handshakeTimer = setTimeout(() => cleanup(), HANDSHAKE_TIMEOUT);

  function cleanup() {
    if (closed) return;
    closed = true;
    clearTimeout(handshakeTimer);
    clearTimeout(connectTimer);
    if (sock) sock.destroy();
    if (duplex) duplex.destroy();
    ws.terminate();
  }

  ws.on('close', cleanup);

  ws.once('message', async (data) => {
    clearTimeout(handshakeTimer);

    // 先挂上流，避免异步解析期间到达的数据丢失
    duplex = createWebSocketStream(ws);
    duplex.on('error', () => {});

    const msg = Buffer.isBuffer(data) ? data : Buffer.from(data);
    const h = parseHeader(msg);
    if (!h) return cleanup();

    try {
      let addr = h.host;
      if (!net.isIP(addr)) {
        const list = await withTimeout(dns.lookup(addr, { all: true }), DNS_TIMEOUT);
        const ok = ALLOW_PRIVATE ? list : list.filter((r) => !isPrivate(r.address));
        if (!ok.length) return cleanup();
        addr = ok[0].address;
      } else if (!ALLOW_PRIVATE && isPrivate(addr)) {
        return cleanup();
      }

      if (closed) return; // 解析期间客户端已断开

      sock = net.connect({ host: addr, port: h.port });
      sock.on('error', cleanup);
      sock.on('close', () => {
        // 正常结束：先让剩余数据刷给客户端，再兜底清理
        if (duplex && !duplex.destroyed) duplex.end();
        setTimeout(cleanup, 3000);
      });

      connectTimer = setTimeout(cleanup, CONNECT_TIMEOUT);
      sock.once('connect', () => {
        clearTimeout(connectTimer);
        if (closed) return sock.destroy();
        sock.setTimeout(IDLE_TIMEOUT, cleanup);
        duplex.write(Buffer.from([h.version, 0])); // 连接成功后再返回响应头
        if (h.payload.length) sock.write(h.payload);
        duplex.pipe(sock);
        sock.pipe(duplex);
      });
    } catch {
      cleanup();
    }
  });
});

server.listen(PORT, () => {
  console.log(`listening on :${PORT}`);
  console.log(`订阅路径: /${SUB_PATH}`);
  console.log(`分享链接: ${shareLink}`);
  if (!process.env.UUID) console.log('提示：未设置 UUID，本次为随机生成，重启后会变化。');
});
