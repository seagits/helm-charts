// HTTP client for kind_test.sh: drives a running hub through the proxy the way a developer would
// (sign-in form) and the way the platform would (REST API with a token). Node >= 22 (fetch, WebSocket).
// usage: node hub_client.mjs <command> [args...]   env: HUB (https://127.0.0.1:8443 or http://…), TOKEN
import http from 'node:http';
import https from 'node:https';
process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';
const HUB = process.env.HUB || 'https://127.0.0.1:8443';
const TOKEN = process.env.TOKEN || '';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const die = (m) => { console.error(`FAIL: ${m}`); process.exit(1); };

async function api(method, path, body) {
  const r = await fetch(`${HUB}/hub/api${path}`, {
    method,
    headers: { Authorization: `token ${TOKEN}`, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await r.text();
  let json; try { json = JSON.parse(text); } catch { json = undefined; }
  return { status: r.status, json, text };
}

// The hub's own login form: GET sets _xsrf, POST with it. Success = 302 away from /hub/login.
// node:https, not fetch: fetch (undici) forces Sec-Fetch-Mode: cors, and the hub sets the xsrf
// cookie only for a page navigation, which is what a browser sends.
function req(method, path, headers, body) {
  return new Promise((resolve, reject) => {
    const u = new URL(HUB + path);
    const mod = u.protocol === 'http:' ? http : https;
    const r = mod.request({ host: u.hostname, port: u.port, path: u.pathname + u.search, method, headers, rejectUnauthorized: false }, (res) => {
      let data = '';
      res.on('data', (d) => { data += d; });
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: data }));
    });
    r.on('error', reject);
    if (body) r.write(body);
    r.end();
  });
}

// Signs in through the form; returns the session cookies (or null when refused).
async function session(user, password) {
  const nav = { 'Sec-Fetch-Mode': 'navigate', 'Sec-Fetch-Dest': 'document', 'Sec-Fetch-Site': 'same-origin' };
  const g = await req('GET', '/hub/login', nav);
  const cookies = (g.headers['set-cookie'] || []).map((c) => c.split(';')[0]);
  const xsrf = g.body.match(/name="_xsrf"\s+value="([^"]+)"/)?.[1];
  if (!xsrf || !cookies.some((c) => c.startsWith('_xsrf='))) die(`login page has no xsrf token (HTTP ${g.status})`);
  const body = new URLSearchParams({ username: user, password, _xsrf: xsrf }).toString();
  const p = await req('POST', '/hub/login?next=', {
    ...nav, 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': Buffer.byteLength(body), Cookie: cookies.join('; '),
  }, body);
  const loc = p.headers.location || '';
  if (p.status !== 302 || loc.includes('/hub/login')) return null;
  const kv = (c) => { const i = c.indexOf('='); return [c.slice(0, i), c.slice(i + 1)]; };
  const jar = new Map(cookies.map(kv));
  (p.headers['set-cookie'] || []).forEach((c) => jar.set(...kv(c.split(';')[0])));
  return jar;
}

async function login(user, password) {
  return (await session(user, password)) !== null;
}

// What a developer does for VS Code: sign in, then "Request new API token" (cookie + xsrf header).
async function mintToken(user, password) {
  const jar = await session(user, password);
  if (!jar) die(`${user}: sign-in refused`);
  const cookie = Array.from(jar, ([k, v]) => `${k}=${v}`).join('; ');
  const body = JSON.stringify({ note: 'sg-notebooks test', expires_in: 3600 });
  const r = await req('POST', `/hub/api/users/${user}/tokens`, {
    Cookie: cookie, 'X-XSRFToken': decodeURIComponent(jar.get('_xsrf')), 'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body), Referer: `${HUB}/hub/token`,
  }, body);
  if (r.status !== 201) die(`${user}: token HTTP ${r.status} ${r.body.slice(0, 200)}`);
  return JSON.parse(r.body).token;
}

async function waitReady(user, timeoutS) {
  const until = Date.now() + timeoutS * 1000;
  for (;;) {
    const r = await api('GET', `/users/${user}`);
    const s = r.json?.servers?.[''];
    if (s?.ready) return s;
    if (!s && r.json && !r.json.pending) die(`${user}: server is gone (${r.text.slice(0, 300)})`);
    if (Date.now() > until) die(`${user}: server not ready after ${timeoutS}s (${r.text.slice(0, 300)})`);
    await sleep(5000);
  }
}

async function waitStopped(user, timeoutS) {
  const until = Date.now() + timeoutS * 1000;
  for (;;) {
    const r = await api('GET', `/users/${user}`);
    if (!r.json?.servers?.['']) return;
    if (Date.now() > until) die(`${user}: server still present after ${timeoutS}s`);
    await sleep(5000);
  }
}

const wsBase = (u) => u.replace(/^http/, 'ws'); // http→ws, https→wss

// Runs code in a fresh kernel on the user's server over the Jupyter kernel WebSocket protocol.
// idleSeconds: keep the open websocket silent that long first (an entrance's idle timeout).
async function run(user, code, idleSeconds = 0) {
  const base = `${HUB}/user/${user}/api`;
  const h = { Authorization: `token ${TOKEN}`, 'Content-Type': 'application/json' };
  const k = await (await fetch(`${base}/kernels`, { method: 'POST', headers: h, body: '{}' })).json();
  if (!k.id) die(`${user}: no kernel (${JSON.stringify(k).slice(0, 200)})`);
  const ws = new WebSocket(`${wsBase(base)}/kernels/${k.id}/channels?token=${TOKEN}`);
  const msgId = `kt-${Date.now()}`;
  const out = [];
  const done = new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error('kernel timeout')), (120 + idleSeconds) * 1000);
    ws.onmessage = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.parent_header?.msg_id !== msgId) return;
      if (m.msg_type === 'stream') out.push(m.content.text);
      if (m.msg_type === 'error') out.push(`ERROR ${m.content.ename}: ${m.content.evalue}`);
      if (m.msg_type === 'status' && m.content.execution_state === 'idle') { clearTimeout(t); resolve(); }
    };
    ws.onerror = (e) => reject(new Error(`websocket: ${e.message || 'error'}`));
  });
  await new Promise((resolve, reject) => { ws.addEventListener('open', resolve, { once: true }); ws.addEventListener('error', reject, { once: true }); });
  if (idleSeconds) await sleep(idleSeconds * 1000);
  if (ws.readyState !== WebSocket.OPEN) die(`${user}: websocket closed after ${idleSeconds}s idle`);
  ws.send(JSON.stringify({
    header: { msg_id: msgId, username: user, session: msgId, msg_type: 'execute_request', version: '5.3' },
    parent_header: {}, metadata: {}, channel: 'shell',
    content: { code, silent: false, store_history: false, user_expressions: {}, allow_stdin: false },
  }));
  await done;
  ws.close();
  await fetch(`${base}/kernels/${k.id}`, { method: 'DELETE', headers: h });
  return out.join('');
}

// A terminal round trip (Jupyter terminals API + websocket): create, run a command, read its output.
async function term(user, command) {
  const base = `${HUB}/user/${user}/api`;
  const h = { Authorization: `token ${TOKEN}`, 'Content-Type': 'application/json' };
  const t = await (await fetch(`${base}/terminals`, { method: 'POST', headers: h, body: '{}' })).json();
  if (!t.name) die(`${user}: no terminal (${JSON.stringify(t).slice(0, 200)})`);
  const ws = new WebSocket(`${wsBase(HUB)}/user/${user}/terminals/websocket/${t.name}?token=${TOKEN}`);
  let out = '';
  const done = new Promise((resolve, reject) => {
    const to = setTimeout(() => reject(new Error(`terminal timeout, got: ${out.slice(-200)}`)), 60000);
    ws.onmessage = (ev) => {
      const [kind, text] = JSON.parse(ev.data);
      if (kind === 'stdout') out += text;
      if (out.includes('term-42')) { clearTimeout(to); resolve(); } // the echoed command reads term-$((6*7))
    };
    ws.onerror = (e) => reject(new Error(`terminal websocket: ${e.message || 'error'}`));
  });
  ws.onopen = () => ws.send(JSON.stringify(['stdin', `${command}\r`]));
  await done;
  ws.close();
  await fetch(`${base}/terminals/${t.name}`, { method: 'DELETE', headers: h });
  return 'term-42';
}

const [cmd, ...a] = process.argv.slice(2);
if (cmd === 'login') {
  console.log((await login(a[0], a[1])) ? 'ok' : 'refused');
} else if (cmd === 'token') {
  console.log(await mintToken(a[0], a[1]));
} else if (cmd === 'start') {
  // user_options as the spawn form would send them: profile slug + image choice key
  const r = await api('POST', `/users/${a[0]}/server`, { profile: a[1], image: a[2] });
  if (![201, 202].includes(r.status)) die(`start ${a[0]}: HTTP ${r.status} ${r.text.slice(0, 300)}`);
  await waitReady(a[0], Number(a[3] || 900));
  console.log('ready');
} else if (cmd === 'stop') {
  const r = await api('DELETE', `/users/${a[0]}/server`);
  if (![202, 204].includes(r.status)) die(`stop ${a[0]}: HTTP ${r.status}`);
  await waitStopped(a[0], 300);
  console.log('stopped');
} else if (cmd === 'wait-stopped') {
  await waitStopped(a[0], Number(a[1] || 300));
  console.log('stopped');
} else if (cmd === 'run') {
  console.log(await run(a[0], a[1]));
} else if (cmd === 'idle') {
  // run after the kernel websocket sat idle N seconds (survives the entrance's read timeout?)
  console.log(await run(a[0], a[2] || 'print(6*7)', Number(a[1] || 90)));
} else if (cmd === 'term') {
  console.log(await term(a[0], a[1] || 'echo term-$((6*7))'));
} else if (cmd === 'upload') {
  // PUT a file of N MiB through the contents API; prints the HTTP status
  const size = Number(a[1] || 5) * 1024 * 1024;
  const r = await fetch(`${HUB}/user/${a[0]}/api/contents/upload-${size}.bin`, {
    method: 'PUT',
    headers: { Authorization: `token ${TOKEN}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ type: 'file', format: 'base64', content: Buffer.alloc(size, 7).toString('base64') }),
  });
  console.log(r.status);
} else if (cmd === 'adduser') {
  const r = await api('POST', `/users/${a[0]}`);
  if (![201, 409].includes(r.status)) die(`adduser ${a[0]}: HTTP ${r.status}`);
  console.log('ok');
} else {
  die(`unknown command ${cmd}`);
}
