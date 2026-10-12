#!/usr/bin/env python3
"""
NetCmd - send CLI commands to several network devices over SSH or Telnet.

Device list : LibreNMS API (/api/v0/devices), filtered by OS.
Execution   : Netmiko, one thread per device (bounded pool).
History     : SQLite, one row per run and one row per device result,
              including the full device output. Passwords are never stored.
"""

import os
import re
import sqlite3
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from urllib.parse import quote

import requests
from flask import Flask, Response, abort, jsonify, redirect, render_template_string, request, url_for

try:
    from netmiko import ConnectHandler
    from netmiko.exceptions import (
        NetmikoAuthenticationException,
        NetmikoTimeoutException,
        ReadTimeout,
    )
except ImportError:  # allows syntax checks without netmiko installed
    ConnectHandler = None

    class NetmikoAuthenticationException(Exception):
        pass

    class NetmikoTimeoutException(Exception):
        pass

    class ReadTimeout(Exception):
        pass


# ---------------------------------------------------------------------------
# Configuration (environment variables, see /etc/netcmd/netcmd.env)
# ---------------------------------------------------------------------------
LIBRENMS_URL = os.environ.get("NETCMD_LIBRENMS_URL", "http://127.0.0.1").rstrip("/")
LIBRENMS_TOKEN = os.environ.get("NETCMD_LIBRENMS_TOKEN", "")
OS_FILTER = [o.strip() for o in os.environ.get("NETCMD_OS_FILTER", "ios,iosxe").split(",") if o.strip()]
DB_PATH = os.environ.get("NETCMD_DB", "/var/lib/netcmd/history.db")
LISTEN = os.environ.get("NETCMD_LISTEN", "0.0.0.0")
PORT = int(os.environ.get("NETCMD_PORT", "8090"))
WORKERS = int(os.environ.get("NETCMD_WORKERS", "10"))
CONN_TIMEOUT = int(os.environ.get("NETCMD_CONN_TIMEOUT", "20"))
CMD_TIMEOUT = int(os.environ.get("NETCMD_CMD_TIMEOUT", "60"))
CACHE_SECONDS = 60

ERR_MARKERS = (
    "% Invalid input",
    "% Incomplete command",
    "% Ambiguous command",
    "% Unknown command",
    "% Bad IP address",
    "% Unrecognized command",
)

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 2 * 1024 * 1024  # logo upload, Run form
db_lock = threading.Lock()
executor = ThreadPoolExecutor(max_workers=WORKERS)
_cache = {"time": 0.0, "devices": [], "error": "", "groups": []}


# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------
def db():
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    return conn


def db_init():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    with db_lock, db() as conn:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                started TEXT NOT NULL,
                finished TEXT,
                client_ip TEXT,
                login TEXT,
                protocol TEXT,
                commands TEXT,
                device_count INTEGER,
                status TEXT
            );
            CREATE TABLE IF NOT EXISTS results (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                run_id INTEGER NOT NULL REFERENCES runs(id),
                ip TEXT NOT NULL,
                name TEXT,
                status TEXT,
                error TEXT,
                protocol_used TEXT,
                output TEXT,
                started TEXT,
                duration REAL
            );
            CREATE INDEX IF NOT EXISTS idx_results_ip ON results(ip);
            CREATE INDEX IF NOT EXISTS idx_results_run ON results(run_id);
            CREATE TABLE IF NOT EXISTS settings (
                k TEXT PRIMARY KEY,
                v TEXT
            );
            """
        )
        cols = [r[1] for r in conn.execute("PRAGMA table_info(runs)").fetchall()]
        if "enable_mode" not in cols:
            conn.execute("ALTER TABLE runs ADD COLUMN enable_mode INTEGER DEFAULT 1")


def now():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


# ---------------------------------------------------------------------------
# Settings (Settings page, stored in the settings table)
# ---------------------------------------------------------------------------
DEFAULT_SETTINGS = {
    "link_librenms": "1",      # device name = link to the device in LibreNMS
    "librenms_web_url": "",    # empty = http://<host used to reach NetCmd>/
    "link_telnet": "1",        # telnet:// link right of the IP
    "link_ssh": "1",           # ssh:// link right of the IP
    "show_groups": "1",        # group (tag) badges in the device list
    "logo_ext": "",            # uploaded logo extension, empty = built-in logo
    "logo_ver": "0",           # changes on each upload (browser cache)
}

LOGO_TYPES = {
    "png": "image/png",
    "jpg": "image/jpeg",
    "jpeg": "image/jpeg",
    "gif": "image/gif",
    "webp": "image/webp",
    "ico": "image/x-icon",
    "svg": "image/svg+xml",
}
LOGO_MAX_BYTES = 512 * 1024

DEFAULT_LOGO_SVG = (
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">'
    '<rect width="64" height="64" rx="12" fill="#1f5fbf"/>'
    '<path d="M14 20l14 12-14 12" fill="none" stroke="#fff" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/>'
    '<path d="M32 46h18" stroke="#fff" stroke-width="6" stroke-linecap="round"/></svg>'
)


def get_settings():
    st = dict(DEFAULT_SETTINGS)
    try:
        with db() as conn:
            for r in conn.execute("SELECT k, v FROM settings").fetchall():
                st[r["k"]] = r["v"]
    except sqlite3.Error:
        pass
    return st


def save_settings(values):
    with db_lock, db() as conn:
        for k, v in values.items():
            conn.execute("INSERT INTO settings(k, v) VALUES(?, ?) ON CONFLICT(k) DO UPDATE SET v=excluded.v", (k, str(v)))


def logo_path(ext):
    return os.path.join(os.path.dirname(DB_PATH), "logo." + ext)


def librenms_web_url(st):
    url = (st.get("librenms_web_url") or "").strip()
    if not url:
        url = "http://" + request.host.split(":")[0] + "/"
    return url.rstrip("/") + "/"


# ---------------------------------------------------------------------------
# LibreNMS device list
# ---------------------------------------------------------------------------
def get_devices(force=False):
    if not force and time.time() - _cache["time"] < CACHE_SECONDS and _cache["devices"]:
        return _cache["devices"], _cache["error"]
    try:
        r = requests.get(
            LIBRENMS_URL + "/api/v0/devices",
            headers={"X-Auth-Token": LIBRENMS_TOKEN},
            timeout=15,
        )
        r.raise_for_status()
        items = r.json().get("devices", [])
        devices = []
        for d in items:
            if OS_FILTER and d.get("os") not in OS_FILTER:
                continue
            if str(d.get("disabled", 0)) == "1":
                continue
            ip = d.get("ip") or d.get("hostname")
            devices.append(
                {
                    "id": str(d.get("device_id", "")),
                    "ip": ip,
                    "name": d.get("sysName") or d.get("hostname") or ip,
                    "os": d.get("os", ""),
                    "hardware": d.get("hardware") or "",
                    "up": str(d.get("status", 0)) == "1",
                }
            )
        devices.sort(key=lambda x: (x["name"] or "").lower())
        groups, gerr = get_groups()
        for dev in devices:
            dev["groups"] = [g["name"] for g in groups if dev["id"] in g["ids"]]
        _cache.update(time=time.time(), devices=devices, error=gerr,
                      groups=[g["name"] for g in groups])
    except Exception as exc:  # keep last known list on error
        _cache["error"] = "LibreNMS API error: %s" % exc
    return _cache["devices"], _cache["error"]


def get_groups():
    """LibreNMS device groups (used as tags): [{name, ids:set(device_id)}]."""
    headers = {"X-Auth-Token": LIBRENMS_TOKEN}
    groups = []
    try:
        r = requests.get(LIBRENMS_URL + "/api/v0/devicegroups", headers=headers, timeout=15)
        if r.status_code == 404:  # no group defined yet
            return [], ""
        r.raise_for_status()
        for g in r.json().get("groups", []):
            name = g.get("name")
            if not name:
                continue
            r2 = requests.get(LIBRENMS_URL + "/api/v0/devicegroups/" + quote(name, safe=""),
                              headers=headers, timeout=15)
            ids = set()
            if r2.status_code == 200:
                ids = {str(x.get("device_id")) for x in r2.json().get("devices", [])}
            groups.append({"name": name, "ids": ids})
        groups.sort(key=lambda x: x["name"].lower())
        return groups, ""
    except Exception as exc:
        return groups, "LibreNMS device groups error: %s" % exc


# ---------------------------------------------------------------------------
# Device execution
# ---------------------------------------------------------------------------
def _connect(ip, user, password, proto):
    dtype = "cisco_ios" if proto == "ssh" else "cisco_ios_telnet"
    return ConnectHandler(
        device_type=dtype,
        host=ip,
        username=user,
        password=password,
        timeout=CONN_TIMEOUT,
        auth_timeout=CONN_TIMEOUT,
        banner_timeout=CONN_TIMEOUT,
        fast_cli=False,
    )


PROMPT_END_RE = r"[>#:]\s*$"


def enter_enable(conn, auth, transcript):
    """
    Prompt ending:
      '#'  -> already privileged, nothing to do
      '>'  -> enable mode unchecked: stay in user mode
              enable mode checked  : send 'enable'
                 reply ending ':' -> send enable password (or login password if empty)
                 final prompt must end with '#', otherwise 'enable failed'
    Return an error string, or "" when commands may be sent.
    """
    prompt = conn.find_prompt().strip()
    if prompt.endswith("#"):
        return ""
    if not prompt.endswith(">"):
        return "Unexpected prompt after login: %s" % prompt
    if not auth["enable_mode"]:
        return ""
    conn.write_channel("enable" + conn.RETURN)
    out = conn.read_until_pattern(pattern=PROMPT_END_RE, read_timeout=CONN_TIMEOUT)
    transcript.append(prompt + "enable")
    if out.rstrip().endswith(":"):
        secret = auth["enable_password"] or auth["password"]
        conn.write_channel(secret + conn.RETURN)
        out = conn.read_until_pattern(pattern=r"[>#]\s*$", read_timeout=CONN_TIMEOUT)
        transcript.append("Password: ********")
    final = conn.find_prompt().strip()
    if not final.endswith("#"):
        detail = " ".join(l.strip() for l in out.splitlines() if l.strip().startswith("%"))
        return "Enable failed" + (": " + detail if detail else "")
    return ""


def device_only_prompt_re(conn):
    """Regex of the device prompt only (no confirmation question)."""
    base = (getattr(conn, "base_prompt", "") or "").strip()
    if not base:
        return r"[>#]\s*$"
    return re.escape(base[:16]) + r"[^\r\n]*[>#]\s*$"


def device_prompt_re(conn):
    """
    Regex matching any prompt of the connected device at the end of the output:
    HOST>  HOST#  HOST(config)#  HOST(config-ext-nacl)#  ...
    Cisco IOS may truncate long hostnames in config mode: only the first 16 characters
    of the base prompt are required.
    """
    prompt = device_only_prompt_re(conn)
    # confirmation questions also end a command; an empty line in the command list
    # (sent as a single carriage return) answers them with the default value
    return "(?:" + prompt + ")|(?:" + CONFIRM_RE + ")"


# Cisco confirmation questions, at the very end of the output:
#   "Do you want to continue? [confirm]"        "Proceed with reload? [confirm]"
#   "... [yes/no]:"                              "Destination filename [startup-config]?"
#   "Delete filename [x]? " / "Erase ...? [confirm]" / "Are you sure? [y/n]"
CONFIRM_RE = (
    r"(?i:\[confirm\]\s*$"
    r"|\[yes/no\]\s*:?\s*$"
    r"|\?\s*\[[^\]\r\n]{1,40}\]\s*:?\s*$"
    r"|\[[^\]\r\n]{0,80}\]\?\s*$)"
)


def run_on_device(ip, auth, commands, protocol):
    """Return dict(status, error, protocol_used, output)."""
    order = ["ssh", "telnet"] if protocol == "auto" else [protocol]
    conn = None
    proto_used = ""
    last_error = ""
    for proto in order:
        try:
            conn = _connect(ip, auth["user"], auth["password"], proto)
            proto_used = proto
            break
        except NetmikoAuthenticationException:
            return {"status": "conn_error", "error": "Authentication failed (%s)" % proto,
                    "protocol_used": proto, "output": ""}
        except NetmikoTimeoutException:
            last_error = "Timeout / unreachable (%s)" % proto
        except Exception as exc:
            last_error = "%s (%s)" % (str(exc).splitlines()[0] if str(exc) else type(exc).__name__, proto)
    if conn is None:
        return {"status": "conn_error", "error": last_error, "protocol_used": "", "output": ""}

    status, error = "ok", ""
    parts = []
    try:
        try:
            err = enter_enable(conn, auth, parts)
        except ReadTimeout:
            err = "Enable failed: no prompt received"
        if err:
            return {"status": "conn_error", "error": err, "protocol_used": proto_used, "output": "\n".join(parts)}
        prompt = conn.find_prompt()
        prompt_re = device_prompt_re(conn)
        prompt_only_re = device_only_prompt_re(conn)
        for cmd in commands:
            try:
                # expect any prompt of this device (exec, config, config-xxx), not only the
                # prompt seen before the command: 'conf t', 'interface ...', 'end' change it
                out = conn.send_command(cmd, expect_string=prompt_re, read_timeout=CMD_TIMEOUT,
                                        strip_prompt=False, strip_command=False)
            except ReadTimeout:
                out = "!!! no prompt received within %ss" % CMD_TIMEOUT
                if status == "ok":
                    status, error = "cmd_error", "Timeout on: " + cmd
            echoed = out.lstrip().startswith(cmd.strip()) if cmd.strip() else False
            parts.append("%s%s" % (prompt, out.lstrip()) if echoed else "%s%s\n%s" % (prompt, cmd, out))
            if status in ("ok", "potential_error") and any(m in out for m in ERR_MARKERS):
                status, error = "cmd_error", "Rejected: " + cmd
            elif status in ("ok", "potential_error"):
                # any other line starting with '%' is reported as a potential error
                msgs = [l.strip() for l in out.splitlines() if l.lstrip().startswith("%")]
                if msgs:
                    item = "%s: %s" % (cmd.strip(), " | ".join(msgs))
                    if status == "ok":
                        status, error = "potential_error", "Potential error on " + item
                    else:
                        error = (error + " / " + item)[:1000]
            # next prompt taken from the end of the output: find_prompt() would send
            # an Enter and silently answer a pending "[confirm]" question
            tail = out.rstrip("\r\n").splitlines()[-1] if out.strip() else ""
            if re.search(prompt_only_re, tail):
                prompt = tail.strip()
            elif re.search(CONFIRM_RE, tail):
                prompt = ""
    except Exception as exc:
        status, error = "conn_error", "Session error: %s" % exc
    finally:
        try:
            conn.disconnect()
        except Exception:
            pass
    return {"status": status, "error": error, "protocol_used": proto_used, "output": "\n".join(parts)}


def worker(result_id, ip, auth, commands, protocol):
    t0 = time.time()
    with db_lock, db() as conn:
        conn.execute("UPDATE results SET status='running', started=? WHERE id=?", (now(), result_id))
    try:
        res = run_on_device(ip, auth, commands, protocol)
    except Exception as exc:
        res = {"status": "conn_error", "error": "Internal error: %s" % exc, "protocol_used": "", "output": ""}
    with db_lock, db() as conn:
        conn.execute(
            "UPDATE results SET status=?, error=?, protocol_used=?, output=?, duration=? WHERE id=?",
            (res["status"], res["error"], res["protocol_used"], res["output"], round(time.time() - t0, 1), result_id),
        )


def run_job(run_id, jobs, auth, commands, protocol):
    futures = [executor.submit(worker, rid, ip, auth, commands, protocol) for rid, ip in jobs]
    for f in futures:
        f.result()
    with db_lock, db() as conn:
        conn.execute("UPDATE runs SET finished=?, status='done' WHERE id=?", (now(), run_id))


# ---------------------------------------------------------------------------
# Templates
# ---------------------------------------------------------------------------
BASE = """<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>NetCmd - {{ title }}</title>
<link rel="icon" href="{{ url_for('logo', v=logo_ver) }}">
<style>
:root{--bg:#f6f7f9;--fg:#1d2330;--mut:#667085;--card:#fff;--line:#d9dde3;--ok:#1a7f37;--warn:#b26b00;--err:#c62828;--acc:#1f5fbf}
*{box-sizing:border-box}body{margin:0;font:14px/1.45 system-ui,Segoe UI,Arial,sans-serif;background:var(--bg);color:var(--fg)}
header{background:#1d2330;color:#fff;padding:10px 16px;display:flex;gap:18px;align-items:center}
header a{color:#cfd8e6;text-decoration:none}header a:hover{color:#fff}header b{font-size:16px}
header .brand{display:flex;align-items:center;gap:8px}header .brand img{width:26px;height:26px;object-fit:contain;border-radius:4px}
header .right{margin-left:auto}
.cli{font-size:11px;border:1px solid var(--line);border-radius:3px;padding:0 4px;color:var(--acc);text-decoration:none}
.cli:hover{background:#e3ecfb}.dname{color:inherit}
main{padding:16px;max-width:1400px;margin:0 auto}
.card{background:var(--card);border:1px solid var(--line);border-radius:6px;padding:14px;margin-bottom:14px}
.grid{display:grid;grid-template-columns:minmax(320px,1fr) minmax(320px,1fr);gap:14px}
@media(max-width:900px){.grid{grid-template-columns:1fr}}
label{display:block;font-weight:600;margin:8px 0 4px}
input[type=text],input[type=password],select,textarea{width:100%;padding:7px;border:1px solid var(--line);border-radius:4px;font:inherit}
textarea{font-family:Consolas,monospace;min-height:220px}
.devlist{max-height:430px;overflow:auto;border:1px solid var(--line);border-radius:4px}
.devlist label{font-weight:400;margin:0;padding:4px 8px;border-bottom:1px solid #eef0f3;display:flex;gap:8px;align-items:center}
.devlist label:hover{background:#f0f4fb}.ip{color:var(--mut);font-family:Consolas,monospace;margin-left:auto}
button,.btn{background:var(--acc);color:#fff;border:0;border-radius:4px;padding:8px 14px;font:inherit;cursor:pointer;text-decoration:none;display:inline-block}
button.sec,.btn.sec{background:#e8ecf2;color:var(--fg)}
table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:6px 8px;border-bottom:1px solid #eef0f3;vertical-align:top}
th{background:#f0f2f5;font-weight:600}
.s-ok{color:var(--ok);font-weight:600}.s-cmd_error{color:var(--warn);font-weight:600}.s-conn_error{color:var(--err);font-weight:600}
.s-potential_error{color:#8e44ad;font-weight:600}
.s-pending,.s-running{color:var(--mut);font-weight:600}
pre{background:#11161f;color:#d8dee9;padding:10px;border-radius:4px;overflow:auto;max-height:520px;margin:6px 0 0;font:12.5px/1.4 Consolas,monospace;white-space:pre}
details summary{cursor:pointer}.mut{color:var(--mut)}.err{color:var(--err)}
.bar{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin:6px 0}
.tag{background:#e3ecfb;color:#1f4f99;border-radius:10px;padding:0 7px;font-size:12px}
</style></head><body>
<header><span class="brand"><img src="{{ url_for('logo', v=logo_ver) }}" alt=""><b>NetCmd</b></span><a href="{{ url_for('index') }}">New run</a><a href="{{ url_for('history') }}">History</a><a href="{{ url_for('devices_page') }}">Devices</a><a class="right" href="{{ url_for('settings_page') }}">Settings</a></header>
<main>{{ body|safe }}</main></body></html>"""

INDEX = """
{% if error %}<div class="card err">{{ error }}</div>{% endif %}
<form method="post" action="{{ url_for('start_run') }}" class="grid" autocomplete="off">
 <div class="card">
  <div class="bar"><b>Devices</b><span class="mut">({{ devices|length }}, OS: {{ os_filter }})</span>
   <span id="cnt" class="mut"></span></div>
  <input type="text" id="flt" placeholder="Filter by name or IP">
  <div class="bar"><select id="grp" style="width:auto">
   <option value="">All groups (tags)</option>
   {% for g in groups %}<option value="{{ g }}">{{ g }}</option>{% endfor %}</select>
   <select id="srt" style="width:auto"><option value="name">Sort by name</option><option value="ip">Sort by IP</option></select></div>
  <div class="bar">
   <button type="button" class="sec" onclick="sel(true)">Select visible</button>
   <button type="button" class="sec" onclick="sel(false)">Clear visible</button>
   <a class="btn sec" href="{{ url_for('index', refresh=1) }}">Reload list</a></div>
  <div class="devlist" id="dl">
   {% for d in devices %}
   <label data-k="{{ (d.name ~ ' ' ~ d.ip)|lower }}" data-n="{{ d.name|lower }}" data-ip="{{ d.ip }}" data-g="|{{ d.groups|join('|') }}|"><input type="checkbox" name="dev" value="{{ d.ip }}|{{ d.name }}">
    {% if st.link_librenms == '1' and d.id %}<a class="dname" href="{{ lnms_url }}device/{{ d.id }}" target="_blank" rel="noopener" title="Open in LibreNMS">{{ d.name }}</a>{% else %}<span>{{ d.name }}</span>{% endif %}
    {% if st.show_groups == '1' %}{% for g in d.groups %}<span class="tag">{{ g }}</span>{% endfor %}{% endif %}{% if not d.up %}<span class="err">down</span>{% endif %}<span class="ip">{{ d.ip }}</span>
    {% if st.link_telnet == '1' %}<a class="cli" href="telnet://{{ d.ip }}" title="Telnet {{ d.ip }}">Telnet</a>{% endif %}{% if st.link_ssh == '1' %}<a class="cli" href="ssh://{{ d.ip }}" title="SSH {{ d.ip }}">SSH</a>{% endif %}</label>
   {% endfor %}
  </div>
 </div>
 <div class="card">
  <label>Login</label><input type="text" name="login" required>
  <label>Password</label><input type="password" name="password" required>
  <label style="font-weight:400"><input type="checkbox" name="enable_mode" value="1" checked> Enable mode (send 'enable' when the prompt ends with '&gt;')</label>
  <label>Enable password (if empty, the login password is used)</label><input type="password" name="enable_password">
  <label>Protocol</label>
  <select name="protocol"><option value="auto">SSH, then Telnet if SSH fails</option>
   <option value="ssh">SSH only</option><option value="telnet">Telnet only</option></select>
  <label>Commands (one per line, sent as typed, in enable mode - an empty line sends Enter, e.g. to answer a [confirm] question)</label>
  <textarea name="commands" required placeholder="show clock&#10;show version | include uptime"></textarea>
  <div class="bar"><button type="submit">Run</button><span class="mut">Passwords are not stored.</span></div>
 </div>
</form>
<script>
const f=document.getElementById('flt'),g=document.getElementById('grp'),rows=[...document.querySelectorAll('#dl label')],c=document.getElementById('cnt');
function upd(){c.textContent=document.querySelectorAll('#dl input:checked').length+' selected'}
function vis(){const q=f.value.toLowerCase(),gv=g.value;rows.forEach(r=>r.style.display=(r.dataset.k.includes(q)&&(!gv||r.dataset.g.includes('|'+gv+'|')))?'':'none')}
f.addEventListener('input',vis);g.addEventListener('change',vis);
const s=document.getElementById('srt'),dl=document.getElementById('dl');
function ipk(v){const p=v.split('.');return p.length===4&&p.every(x=>/^\\d+$/.test(x))?p.map(x=>x.padStart(3,'0')).join('.'):'~'+v}
function srt(){const by=s.value;rows.sort((a,b)=>{const ka=by==='ip'?ipk(a.dataset.ip):a.dataset.n,kb=by==='ip'?ipk(b.dataset.ip):b.dataset.n;return ka<kb?-1:ka>kb?1:0});
 rows.forEach(r=>dl.appendChild(r));try{localStorage.setItem('netcmd_sort',by)}catch(e){}}
s.addEventListener('change',srt);try{const v=localStorage.getItem('netcmd_sort');if(v){s.value=v;srt()}}catch(e){}
function sel(v){rows.forEach(r=>{if(r.style.display!=='none')r.querySelector('input').checked=v});upd()}
document.getElementById('dl').addEventListener('change',upd);upd();
// preselection from a link: /?ip=192.0.2.10 (repeatable), e.g. from the LibreNMS device page
try{const pre=new URLSearchParams(location.search).getAll('ip');if(pre.length){let first=null;
 rows.forEach(r=>{if(pre.includes(r.dataset.ip)){r.querySelector('input').checked=true;if(!first)first=r}});upd();
 if(first)first.scrollIntoView({block:'center'})}}catch(e){}
</script>"""

RUN = """
<div class="card">
 <div class="bar"><b>Run #{{ run.id }}</b><span class="mut">{{ run.started }} - login {{ run.login }} - {{ run.protocol }} - enable {{ 'on' if run.enable_mode else 'off' }} - from {{ run.client_ip }}</span>
  <span id="state" class="mut"></span>
  <a class="btn sec" href="{{ url_for('export_run', run_id=run.id) }}">Export .txt</a></div>
 <details><summary>Commands</summary><pre>{{ run.commands }}</pre></details>
</div>
<div class="card"><div id="sum" class="bar"></div><table><thead><tr><th>Device</th><th>IP</th><th>Status</th><th>Detail</th><th>Proto</th><th>Time</th></tr></thead>
<tbody id="tb"></tbody></table></div>
<script>
const rid={{ run.id }};const open=new Set();
function esc(s){return (s||'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
function draw(d){
 const cnt={ok:0,potential_error:0,cmd_error:0,conn_error:0,pending:0,running:0};
 let h='';d.results.forEach(r=>{cnt[r.status]=(cnt[r.status]||0)+1;
  const o=open.has(r.id)?' open':'';
  h+='<tr><td><a href="{{ url_for("devices_page") }}?ip='+encodeURIComponent(r.ip)+'">'+esc(r.name)+'</a></td><td class="mut">'+esc(r.ip)+'</td>'+
   '<td class="s-'+r.status+'">'+r.status.replace('_',' ')+'</td><td>'+
   (r.output?'<details data-id="'+r.id+'"'+o+'><summary>'+(esc(r.error)||'output')+'</summary><pre>'+esc(r.output)+'</pre></details>':esc(r.error))+
   '</td><td>'+esc(r.protocol_used)+'</td><td>'+(r.duration!=null?r.duration+'s':'')+'</td></tr>'});
 document.getElementById('tb').innerHTML=h;
 document.querySelectorAll('#tb details').forEach(e=>e.addEventListener('toggle',()=>{const i=+e.dataset.id;e.open?open.add(i):open.delete(i)}));
 document.getElementById('sum').innerHTML='<span class="s-ok">'+cnt.ok+' ok</span><span class="s-potential_error">'+cnt.potential_error+' potential error</span><span class="s-cmd_error">'+cnt.cmd_error+' command error</span>'+
  '<span class="s-conn_error">'+cnt.conn_error+' connection error</span><span class="mut">'+(cnt.pending+cnt.running)+' pending</span>';
 document.getElementById('state').textContent=d.run.status==='done'?'finished '+d.run.finished:'running...';
 return d.run.status==='done';
}
async function poll(){const r=await fetch('{{ url_for("api_run", run_id=run.id) }}');const d=await r.json();if(!draw(d))setTimeout(poll,2000)}
poll();
</script>"""

HISTORY = """
<div class="card"><div class="bar"><b>Runs</b><span class="mut">(last {{ runs|length }})</span></div>
<table><thead><tr><th>#</th><th>Started</th><th>Login</th><th>From</th><th>Proto</th><th>Devices</th><th title="ok / potential error / command error / connection error">Results</th><th>Commands</th></tr></thead><tbody>
{% for r in runs %}<tr><td><a href="{{ url_for('show_run', run_id=r.id) }}">{{ r.id }}</a></td><td>{{ r.started }}</td><td>{{ r.login }}</td>
<td class="mut">{{ r.client_ip }}</td><td>{{ r.protocol }}</td><td>{{ r.device_count }}</td>
<td><span class="s-ok">{{ r.ok }}</span> / <span class="s-potential_error">{{ r.pot }}</span> / <span class="s-cmd_error">{{ r.cmd }}</span> / <span class="s-conn_error">{{ r.conn }}</span>{% if r.status != 'done' %} <span class="mut">running</span>{% endif %}</td>
<td><code>{{ r.commands.splitlines()[0] if r.commands else '' }}{% if r.commands and r.commands.splitlines()|length > 1 %} (+{{ r.commands.splitlines()|length - 1 }}){% endif %}</code></td></tr>
{% endfor %}</tbody></table></div>"""

DEVICES = """
<div class="card"><form class="bar" method="get"><b>Device history</b>
<select name="ip" onchange="this.form.submit()"><option value="">-- choose a device --</option>
{% for d in known %}<option value="{{ d.ip }}" {% if d.ip == ip %}selected{% endif %}>{{ d.name }} ({{ d.ip }})</option>{% endfor %}</select></form></div>
{% if ip %}<div class="card"><div class="bar"><b>{{ name }}</b><span class="mut">{{ ip }} - {{ rows|length }} execution(s)</span></div>
<table><thead><tr><th>Run</th><th>Date</th><th>Login</th><th>Status</th><th>Output</th></tr></thead><tbody>
{% for r in rows %}<tr><td><a href="{{ url_for('show_run', run_id=r.run_id) }}">#{{ r.run_id }}</a></td><td>{{ r.started or r.run_started }}</td><td>{{ r.login }}</td>
<td class="s-{{ r.status }}">{{ r.status|replace('_', ' ') }}</td>
<td><details><summary>{{ r.error or 'output' }}</summary><pre>{{ r.output or '' }}</pre></details></td></tr>
{% endfor %}</tbody></table></div>{% endif %}"""


SETTINGS = """
{% if msg %}<div class="card {{ 'err' if err else '' }}">{{ msg }}</div>{% endif %}
<form method="post" action="{{ url_for('settings_page') }}" enctype="multipart/form-data" class="card" style="max-width:760px">
 <div class="bar"><b>Settings</b></div>
 <label style="font-weight:400"><input type="checkbox" name="link_librenms" value="1" {{ 'checked' if st.link_librenms == '1' }}> Device names are links to the device in LibreNMS</label>
 <label>LibreNMS URL (as seen from the browser)</label>
 <input type="text" name="librenms_web_url" value="{{ st.librenms_web_url }}" placeholder="{{ default_lnms }}">
 <div class="mut">Empty = {{ default_lnms }}</div>
 <label style="font-weight:400"><input type="checkbox" name="link_telnet" value="1" {{ 'checked' if st.link_telnet == '1' }}> Telnet link right of the device IP (telnet://)</label>
 <label style="font-weight:400"><input type="checkbox" name="link_ssh" value="1" {{ 'checked' if st.link_ssh == '1' }}> SSH link right of the device IP (ssh://)</label>
 <label style="font-weight:400"><input type="checkbox" name="show_groups" value="1" {{ 'checked' if st.show_groups == '1' }}> Display group in device list</label>
 <label>Logo (square image, shown in the browser tab and left of the NetCmd title)</label>
 <div class="bar"><img src="{{ url_for('logo', v=logo_ver) }}" alt="" style="width:48px;height:48px;object-fit:contain;border:1px solid var(--line);border-radius:6px">
  <span class="mut">{{ 'Custom logo' if st.logo_ext else 'Built-in logo' }}</span></div>
 <input type="file" name="logo" accept=".png,.jpg,.jpeg,.gif,.webp,.ico,.svg">
 <div class="mut">PNG, JPG, GIF, WEBP, ICO or SVG, 512 KB max. A square image (e.g. 64x64 or 128x128) displays best.</div>
 {% if st.logo_ext %}<label style="font-weight:400"><input type="checkbox" name="logo_reset" value="1"> Remove the custom logo (back to the built-in logo)</label>{% endif %}
 <div class="bar" style="margin-top:12px"><button type="submit">Save</button></div>
</form>"""


def page(title, tpl, **ctx):
    st = ctx.get("st") or get_settings()
    body = render_template_string(tpl, **ctx)
    return render_template_string(BASE, title=title, body=body, logo_ver=st.get("logo_ver", "0"))


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------
@app.route("/")
def index():
    devices, error = get_devices(force=bool(request.args.get("refresh")))
    st = get_settings()
    return page("New run", INDEX, devices=devices, error=error, os_filter=", ".join(OS_FILTER),
                groups=_cache.get("groups", []), st=st, lnms_url=librenms_web_url(st))


@app.route("/logo")
def logo():
    st = get_settings()
    ext = st.get("logo_ext", "")
    headers = {
        "X-Content-Type-Options": "nosniff",
        # an uploaded SVG must never run scripts, even when opened directly
        "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; img-src data:",
        "Cache-Control": "public, max-age=86400",
    }
    if ext in LOGO_TYPES and os.path.isfile(logo_path(ext)):
        with open(logo_path(ext), "rb") as fh:
            return Response(fh.read(), mimetype=LOGO_TYPES[ext], headers=headers)
    return Response(DEFAULT_LOGO_SVG, mimetype="image/svg+xml", headers=headers)


@app.route("/settings", methods=["GET", "POST"])
def settings_page():
    msg, err = "", False
    if request.method == "POST":
        values = {k: ("1" if request.form.get(k) == "1" else "0")
                  for k in ("link_librenms", "link_telnet", "link_ssh", "show_groups")}
        values["librenms_web_url"] = request.form.get("librenms_web_url", "").strip()
        st = get_settings()
        if request.form.get("logo_reset") == "1" and st.get("logo_ext"):
            try:
                os.remove(logo_path(st["logo_ext"]))
            except OSError:
                pass
            values["logo_ext"] = ""
            values["logo_ver"] = str(int(time.time()))
        up = request.files.get("logo")
        if up is not None and up.filename:
            ext = up.filename.rsplit(".", 1)[-1].lower() if "." in up.filename else ""
            data = up.read(LOGO_MAX_BYTES + 1)
            if ext not in LOGO_TYPES:
                msg, err = "Logo not saved: unsupported file type (.%s)." % ext, True
            elif len(data) > LOGO_MAX_BYTES:
                msg, err = "Logo not saved: file larger than 512 KB.", True
            elif not data:
                msg, err = "Logo not saved: empty file.", True
            else:
                if st.get("logo_ext") and st["logo_ext"] != ext:
                    try:
                        os.remove(logo_path(st["logo_ext"]))
                    except OSError:
                        pass
                with open(logo_path(ext), "wb") as fh:
                    fh.write(data)
                values["logo_ext"] = ext
                values["logo_ver"] = str(int(time.time()))
        save_settings(values)
        if not err:
            return redirect(url_for("settings_page", saved=1))
    elif request.args.get("saved"):
        msg = "Settings saved."
    st = get_settings()
    default_lnms = "http://" + request.host.split(":")[0] + "/"
    return page("Settings", SETTINGS, st=st, msg=msg, err=err, default_lnms=default_lnms,
                logo_ver=st.get("logo_ver", "0"))


@app.route("/run", methods=["POST"])
def start_run():
    selected = request.form.getlist("dev")
    login = request.form.get("login", "").strip()
    password = request.form.get("password", "")
    enable_mode = request.form.get("enable_mode") == "1"
    enable_password = request.form.get("enable_password", "")
    protocol = request.form.get("protocol", "auto")
    # empty lines inside the list are kept: each one is sent as a single carriage
    # return (answer to "[confirm]" style questions); leading/trailing ones are dropped
    lines = [c.rstrip() for c in request.form.get("commands", "").splitlines()]
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    commands = [c if c.strip() else "" for c in lines]
    if protocol not in ("auto", "ssh", "telnet"):
        protocol = "auto"
    if not selected or not login or not password or not commands:
        return page("Error", "<div class='card err'>Select at least one device and fill login, password and commands.</div>"), 400

    targets = []
    for s in selected:
        ip, _, name = s.partition("|")
        targets.append((ip.strip(), name.strip() or ip.strip()))

    with db_lock, db() as conn:
        cur = conn.execute(
            "INSERT INTO runs(started, client_ip, login, protocol, commands, device_count, status, enable_mode) VALUES(?,?,?,?,?,?,?,?)",
            (now(), request.remote_addr, login, protocol, "\n".join(commands), len(targets), "running", 1 if enable_mode else 0),
        )
        run_id = cur.lastrowid
        jobs = []
        for ip, name in targets:
            c2 = conn.execute("INSERT INTO results(run_id, ip, name, status) VALUES(?,?,?,'pending')", (run_id, ip, name))
            jobs.append((c2.lastrowid, ip))

    auth = {"user": login, "password": password, "enable_mode": enable_mode, "enable_password": enable_password}
    threading.Thread(target=run_job, args=(run_id, jobs, auth, commands, protocol), daemon=True).start()
    return redirect(url_for("show_run", run_id=run_id))


def _load_run(run_id):
    with db() as conn:
        run = conn.execute("SELECT * FROM runs WHERE id=?", (run_id,)).fetchone()
        if run is None:
            abort(404)
        results = conn.execute("SELECT * FROM results WHERE run_id=? ORDER BY name", (run_id,)).fetchall()
    return dict(run), [dict(r) for r in results]


@app.route("/run/<int:run_id>")
def show_run(run_id):
    run, _ = _load_run(run_id)
    return page("Run %d" % run_id, RUN, run=run)


@app.route("/api/run/<int:run_id>")
def api_run(run_id):
    run, results = _load_run(run_id)
    return jsonify(run=run, results=results)


@app.route("/export/run/<int:run_id>.txt")
def export_run(run_id):
    run, results = _load_run(run_id)
    lines = [
        "NetCmd run #%d - %s - login %s - protocol %s - from %s" % (run["id"], run["started"], run["login"], run["protocol"], run["client_ip"]),
        "Commands:",
    ] + ["  " + c for c in (run["commands"] or "").splitlines()] + [""]
    for r in results:
        lines.append("=" * 78)
        lines.append("%s (%s) - %s %s - %s" % (r["name"], r["ip"], r["status"], ("- " + r["error"]) if r["error"] else "", r["protocol_used"] or ""))
        lines.append("=" * 78)
        lines.append(r["output"] or "")
        lines.append("")
    return Response("\n".join(lines), mimetype="text/plain",
                    headers={"Content-Disposition": "attachment; filename=netcmd-run-%d.txt" % run_id})


@app.route("/history")
def history():
    with db() as conn:
        runs = conn.execute(
            """SELECT r.*,
                 SUM(CASE WHEN s.status='ok' THEN 1 ELSE 0 END) AS ok,
                 SUM(CASE WHEN s.status='potential_error' THEN 1 ELSE 0 END) AS pot,
                 SUM(CASE WHEN s.status='cmd_error' THEN 1 ELSE 0 END) AS cmd,
                 SUM(CASE WHEN s.status='conn_error' THEN 1 ELSE 0 END) AS conn
               FROM runs r LEFT JOIN results s ON s.run_id=r.id
               GROUP BY r.id ORDER BY r.id DESC LIMIT 300"""
        ).fetchall()
    return page("History", HISTORY, runs=[dict(r) for r in runs])


@app.route("/devices")
def devices_page():
    ip = request.args.get("ip", "").strip()
    with db() as conn:
        known = conn.execute(
            "SELECT ip, MAX(name) AS name FROM results GROUP BY ip ORDER BY LOWER(MAX(name))"
        ).fetchall()
        rows = []
        if ip:
            rows = conn.execute(
                """SELECT s.*, r.login, r.started AS run_started FROM results s JOIN runs r ON r.id=s.run_id
                   WHERE s.ip=? ORDER BY s.id DESC LIMIT 500""",
                (ip,),
            ).fetchall()
    name = rows[0]["name"] if rows else ip
    return page("Devices", DEVICES, known=[dict(k) for k in known], ip=ip, name=name, rows=[dict(r) for r in rows])


def mark_interrupted_runs():
    """Runs still 'running' at startup were interrupted by a service restart."""
    with db_lock, db() as conn:
        conn.execute("UPDATE results SET status='conn_error', error='Interrupted (service restart)' "
                     "WHERE status IN ('pending','running')")
        conn.execute("UPDATE runs SET status='done', finished=? WHERE status='running'", (now(),))


if __name__ == "__main__":
    db_init()
    mark_interrupted_runs()
    from waitress import serve

    serve(app, host=LISTEN, port=PORT, threads=8)
