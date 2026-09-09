'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const cp = require('child_process');

const codexHome = process.env.PROBE_CODEX_HOME || process.env.CODEX_HOME || path.join(os.homedir(), '.codex');
const maxSessions = Math.max(1, Number.parseInt(process.env.PROBE_MAX_SESSIONS || '8', 10) || 8);
const staleMinutes = Math.max(1, Number.parseFloat(process.env.PROBE_STALE_MINUTES || '30') || 30);
const maxScanBytes = 32 * 1024 * 1024;
const chunkSize = 256 * 1024;

function parseJson(line) {
  try { return JSON.parse(line); } catch { return null; }
}

function readIndex() {
  const map = new Map();
  const p = path.join(codexHome, 'session_index.jsonl');
  if (!fs.existsSync(p)) return map;
  const text = fs.readFileSync(p, 'utf8');
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim()) continue;
    const obj = parseJson(line);
    if (!obj) continue;
    const id = obj.id || obj.session_id || obj.thread_id;
    const title = obj.thread_name || obj.title;
    if (id && title) map.set(String(id), String(title));
  }
  return map;
}

function listRollouts(root) {
  const out = [];
  if (!fs.existsSync(root)) return out;
  const stack = [{ dir: root, depth: 0 }];
  while (stack.length) {
    const { dir, depth } = stack.pop();
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { continue; }
    for (const e of entries) {
      const p = path.join(dir, e.name);
      if (e.isDirectory() && depth < 5) stack.push({ dir: p, depth: depth + 1 });
      else if (e.isFile() && /^rollout-.*\.jsonl$/i.test(e.name)) {
        try {
          const st = fs.statSync(p);
          out.push({ path: p, mtimeMs: st.mtimeMs, size: st.size });
        } catch {}
      }
    }
  }
  out.sort((a, b) => b.mtimeMs - a.mtimeMs);
  return out;
}

function readFirstJsonLine(file) {
  const fd = fs.openSync(file, 'r');
  try {
    const buf = Buffer.alloc(128 * 1024);
    const n = fs.readSync(fd, buf, 0, buf.length, 0);
    const text = buf.subarray(0, n).toString('utf8');
    const first = text.split(/\r?\n/, 1)[0];
    return parseJson(first);
  } finally {
    fs.closeSync(fd);
  }
}

function scanTail(file, size) {
  const fd = fs.openSync(file, 'r');
  let pos = size;
  let scanned = 0;
  let carry = '';
  let lifecycle = null;
  let token = null;
  try {
    while (pos > 0 && scanned < maxScanBytes && (!lifecycle || !token)) {
      const len = Math.min(chunkSize, pos, maxScanBytes - scanned);
      pos -= len;
      scanned += len;
      const buf = Buffer.allocUnsafe(len);
      fs.readSync(fd, buf, 0, len, pos);
      const text = buf.toString('utf8') + carry;
      const lines = text.split(/\r?\n/);
      carry = lines.shift() || '';
      for (let i = lines.length - 1; i >= 0; i--) {
        const line = lines[i];
        if (!line) continue;
        if (!lifecycle && (line.includes('task_started') || line.includes('task_complete') || line.includes('turn_aborted'))) {
          const obj = parseJson(line);
          const t = obj && obj.type === 'event_msg' && obj.payload && obj.payload.type;
          if (t === 'task_started' || t === 'task_complete' || t === 'turn_aborted') {
            lifecycle = { type: t, timestamp: obj.timestamp || null, turnId: obj.payload.turn_id || null };
          }
        }
        if (!token && line.includes('token_count')) {
          const obj = parseJson(line);
          if (obj && obj.type === 'event_msg' && obj.payload && obj.payload.type === 'token_count') {
            token = obj.payload;
          }
        }
        if (lifecycle && token) break;
      }
    }
    if ((!lifecycle || !token) && carry) {
      const obj = parseJson(carry);
      if (obj && obj.type === 'event_msg' && obj.payload) {
        const t = obj.payload.type;
        if (!lifecycle && (t === 'task_started' || t === 'task_complete' || t === 'turn_aborted')) {
          lifecycle = { type: t, timestamp: obj.timestamp || null, turnId: obj.payload.turn_id || null };
        }
        if (!token && t === 'token_count') token = obj.payload;
      }
    }
  } finally {
    fs.closeSync(fd);
  }
  return { lifecycle, token };
}

function leaf(p) {
  if (!p) return '';
  const clean = String(p).replace(/[\\/]+$/, '');
  const parts = clean.split(/[\\/]/);
  return parts[parts.length - 1] || clean;
}

function processCount() {
  try {
    const txt = cp.execSync('ps -eo pid=,args=', { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
    return txt.split(/\r?\n/).filter(line => {
      const s = line.toLowerCase();
      return s.includes('codex') && !s.includes('codexremoteprobe') && !s.includes('grep codex');
    }).length;
  } catch { return null; }
}

const titles = readIndex();
const files = listRollouts(path.join(codexHome, 'sessions'));
const sessions = [];
let newestRateLimits = null;
let newestRateLimitsMtime = 0;

for (const f of files) {
  if (sessions.length >= maxSessions) break;
  let metaLine;
  try { metaLine = readFirstJsonLine(f.path); } catch { continue; }
  const meta = metaLine && metaLine.type === 'session_meta' ? (metaLine.payload || {}) : {};
  if (meta.parent_thread_id || meta.parentThreadId) continue;
  const id = String(meta.id || meta.session_id || meta.sessionId || path.basename(f.path).replace(/^rollout-.*-([0-9a-f-]{16,})\.jsonl$/i, '$1'));
  let scan;
  try { scan = scanTail(f.path, f.size); } catch { scan = { lifecycle: null, token: null }; }
  const ageMinutes = (Date.now() - f.mtimeMs) / 60000;
  let status = 'unknown';
  const life = scan.lifecycle && scan.lifecycle.type;
  if (life === 'task_started') status = ageMinutes > staleMinutes ? 'stale' : 'running';
  else if (life === 'task_complete') status = 'completed';
  else if (life === 'turn_aborted') status = 'aborted';

  const info = scan.token && scan.token.info;
  const lastUsage = info && info.last_token_usage;
  const totalTokens = lastUsage && (lastUsage.total_tokens ?? lastUsage.totalTokens);
  const contextWindow = info && (info.model_context_window ?? info.modelContextWindow);
  const contextPercent = (Number.isFinite(Number(totalTokens)) && Number(contextWindow) > 0)
    ? Math.min(100, Math.round((Number(totalTokens) / Number(contextWindow)) * 1000) / 10)
    : null;

  const rateLimits = scan.token && scan.token.rate_limits;
  if (rateLimits && f.mtimeMs > newestRateLimitsMtime) {
    newestRateLimits = rateLimits;
    newestRateLimitsMtime = f.mtimeMs;
  }

  const cwd = meta.cwd ? String(meta.cwd) : '';
  sessions.push({
    id,
    title: titles.get(id) || leaf(cwd) || `Session ${id.slice(0, 8)}`,
    workspace: leaf(cwd),
    source: 'WSL Docker',
    originator: meta.originator || null,
    status,
    lifecycle: life || null,
    updatedAt: new Date(f.mtimeMs).toISOString(),
    contextPercent,
    totalTokens: totalTokens == null ? null : Number(totalTokens)
  });
}

process.stdout.write(JSON.stringify({
  ok: true,
  codexHome,
  processCount: processCount(),
  sessions,
  latestRateLimits: newestRateLimits
}));
