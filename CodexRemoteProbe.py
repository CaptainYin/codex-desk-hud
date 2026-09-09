import os, json, time
from pathlib import Path
from datetime import datetime, timezone

home = Path(os.environ.get('PROBE_CODEX_HOME') or os.environ.get('CODEX_HOME') or (Path.home()/'.codex'))
max_sessions = max(1, int(os.environ.get('PROBE_MAX_SESSIONS','8')))
stale_minutes = max(1.0, float(os.environ.get('PROBE_STALE_MINUTES','30')))

def j(line):
    try: return json.loads(line)
    except Exception: return None

def index_map():
    m={}
    p=home/'session_index.jsonl'
    if not p.exists(): return m
    try:
        for line in p.read_text('utf-8', errors='ignore').splitlines():
            o=j(line)
            if not o: continue
            i=o.get('id') or o.get('session_id') or o.get('thread_id')
            t=o.get('thread_name') or o.get('title')
            if i and t: m[str(i)] = str(t)
    except Exception: pass
    return m

def first_json(p):
    try:
        with p.open('rb') as f:
            b=f.read(128*1024)
        return j(b.decode('utf-8','ignore').splitlines()[0])
    except Exception: return None

def scan_tail(p, max_bytes=32*1024*1024):
    life=None; token=None
    try:
        size=p.stat().st_size
        with p.open('rb') as f:
            pos=size; carry=b''; scanned=0
            while pos>0 and scanned<max_bytes and (life is None or token is None):
                n=min(256*1024,pos,max_bytes-scanned); pos-=n; scanned+=n
                f.seek(pos); data=f.read(n)+carry
                parts=data.splitlines()
                carry=parts[0] if parts else b''
                for raw in reversed(parts[1:] if len(parts)>1 else []):
                    s=raw.decode('utf-8','ignore')
                    if life is None and any(x in s for x in ('task_started','task_complete','turn_aborted')):
                        o=j(s); t=((o or {}).get('payload') or {}).get('type')
                        if (o or {}).get('type')=='event_msg' and t in ('task_started','task_complete','turn_aborted'):
                            life={'type':t,'timestamp':o.get('timestamp')}
                    if token is None and 'token_count' in s:
                        o=j(s)
                        if (o or {}).get('type')=='event_msg' and ((o or {}).get('payload') or {}).get('type')=='token_count':
                            token=o['payload']
                    if life is not None and token is not None: break
    except Exception: pass
    return life, token

def leaf(s):
    if not s: return ''
    return str(s).rstrip('/\\').replace('\\','/').split('/')[-1]

titles=index_map(); sessions=[]; latest_rl=None; latest_mtime=0
root=home/'sessions'
files=[]
if root.exists():
    try:
        for p in root.rglob('rollout-*.jsonl'):
            try: files.append((p,p.stat().st_mtime))
            except Exception: pass
    except Exception: pass
files.sort(key=lambda x:x[1], reverse=True)
for p,mtime in files:
    if len(sessions)>=max_sessions: break
    meta_line=first_json(p); meta=(meta_line or {}).get('payload') if (meta_line or {}).get('type')=='session_meta' else {}
    meta=meta or {}
    if meta.get('parent_thread_id') or meta.get('parentThreadId'): continue
    sid=str(meta.get('id') or meta.get('session_id') or meta.get('sessionId') or p.stem)
    life,token=scan_tail(p)
    age=(time.time()-mtime)/60.0; lt=(life or {}).get('type')
    status='unknown'
    if lt=='task_started': status='stale' if age>stale_minutes else 'running'
    elif lt=='task_complete': status='completed'
    elif lt=='turn_aborted': status='aborted'
    info=(token or {}).get('info') or {}; last=info.get('last_token_usage') or info.get('lastTokenUsage') or {}
    total=last.get('total_tokens', last.get('totalTokens')); ctx=info.get('model_context_window', info.get('modelContextWindow'))
    pct=round(min(100,float(total)/float(ctx)*100),1) if total is not None and ctx else None
    rl=(token or {}).get('rate_limits') or (token or {}).get('rateLimits')
    if rl and mtime>latest_mtime: latest_rl=rl; latest_mtime=mtime
    cwd=str(meta.get('cwd') or '')
    sessions.append({'id':sid,'title':titles.get(sid) or leaf(cwd) or ('Session '+sid[:8]),'workspace':leaf(cwd),'source':'WSL Docker','status':status,'lifecycle':lt,'updatedAt':datetime.fromtimestamp(mtime,timezone.utc).isoformat(),'contextPercent':pct,'totalTokens':total})
print(json.dumps({'ok':True,'codexHome':str(home),'processCount':None,'sessions':sessions,'latestRateLimits':latest_rl}, ensure_ascii=False))
