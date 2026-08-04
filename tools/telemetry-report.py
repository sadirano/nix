#!/usr/bin/env python3
"""Turn ~/.nix/telemetry.jsonl into a self-contained HTML report.

BRANCH-ONLY, alongside src/telemetry.zig - neither belongs on main.

    python tools/telemetry-report.py [--log PATH] [--out PATH] [--days N]

Reads the JSONL one invocation per line, and answers four questions in order:
what was I doing, how, when, and where did nix help or get in the way. No
third-party packages: stdlib only, so it runs wherever python does.
"""

import argparse
import html
import json
import os
import re
from collections import Counter, defaultdict
from datetime import datetime, timedelta
from pathlib import Path

# ---- palette (dataviz reference instance) -----------------------------------

SEQ = ["#cde2fb", "#b7d3f6", "#9ec5f4", "#86b6ef", "#6da7ec", "#5598e7",
       "#3987e5", "#2a78d6", "#256abf", "#1c5cab", "#184f95", "#104281", "#0d366b"]
SEQ_DARK = list(SEQ)
STATUS = {"good": "#0ca30c", "warning": "#fab219", "serious": "#ec835a", "critical": "#d03b3b"}

WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

# Every public command the grammar defines, so the report can name what was
# NEVER reached - the whole point of collecting this for a month.
KNOWN_VERBS = [
    "navigate", "run", "edit", "explore", "yank", "paste", "grep", "find",
    "resolve", "resolve-or-add", "add", "remove", "note", "notes", "env",
    "list", "list_names", "which", "prune", "sweep", "picker_check", "doctor",
    "groups", "contexts", "actions", "log_list", "time", "init", "sync",
    "sync_bin", "secret", "trust", "export", "import", "agent", "quit",
    "version", "help", "group-ref", "group-add",
]


def load(path, days):
    rows = []
    cutoff = None
    if days:
        cutoff = datetime.now() - timedelta(days=days)
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            try:
                r["_dt"] = datetime.strptime(r["ts"][:23], "%Y-%m-%dT%H:%M:%S.%f")
            except (KeyError, ValueError):
                continue
            if cutoff and r["_dt"] < cutoff:
                continue
            rows.append(r)
    rows.sort(key=lambda r: r["_dt"])
    return rows


def alias_map(nix_home):
    """alias -> path, so a cwd can be attributed to the project it sits in."""
    out = {}
    p = Path(nix_home) / "aliases.toml"
    if not p.exists():
        return out
    name = None
    for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        m = re.match(r"^\[([^\]]+)\]$", line)
        if m:
            name = m.group(1)
            continue
        m = re.match(r"^path\s*=\s*['\"](.+)['\"]$", line)
        if m and name:
            out[name] = m.group(1).replace("\\", "/").rstrip("/").lower()
    return out


def cwd_alias(cwd, amap):
    if not cwd:
        return ""
    c = cwd.replace("\\", "/").rstrip("/").lower()
    best, best_len = "", -1
    for name, path in amap.items():
        if (c == path or c.startswith(path + "/")) and len(path) > best_len:
            best, best_len = name, len(path)
    return best


def pct(values, q):
    if not values:
        return 0
    s = sorted(values)
    i = min(len(s) - 1, int(round(q * (len(s) - 1))))
    return s[i]


def human_ms(ms):
    if ms is None:
        return "-"
    if ms < 1000:
        return f"{ms} ms"
    s = ms / 1000
    if s < 60:
        return f"{s:.1f} s"
    m = s / 60
    if m < 60:
        return f"{m:.1f} min"
    return f"{m/60:.1f} h"


def esc(s):
    return html.escape(str(s), quote=True)


# ---- analysis ---------------------------------------------------------------

def analyze(rows, amap):
    a = {}
    a["n"] = len(rows)
    a["first"] = rows[0]["_dt"] if rows else None
    a["last"] = rows[-1]["_dt"] if rows else None

    a["verbs"] = Counter(r.get("verb", "") or "(none)" for r in rows)
    a["hows"] = Counter(r.get("how", "") for r in rows)
    a["typed_in"] = Counter(r.get("typed_in", "") or "(unknown)" for r in rows)
    a["aliases"] = Counter(r["alias"] for r in rows if r.get("alias"))
    a["actions"] = Counter(f'{r.get("alias","?")}:{r["action"]}' for r in rows if r.get("action"))
    a["segments"] = Counter(r["seg"] for r in rows if r.get("seg"))
    a["groups"] = Counter(r["group"] for r in rows if r.get("group"))
    a["resolved"] = Counter(r["resolved"] for r in rows if r.get("resolved"))

    a["self_us"] = [r.get("us", 0) for r in rows]
    a["child_ms"] = [r["child_ms"] for r in rows if r.get("child_ms", -1) >= 0]

    heat = defaultdict(int)
    for r in rows:
        heat[(r["_dt"].weekday(), r["_dt"].hour)] += 1
    a["heat"] = heat

    # Sessions: consecutive invocations sharing a sid, split on a >2h gap so a
    # console reused the next morning is a new piece of work, not one long one.
    sessions = []
    by_sid = defaultdict(list)
    for r in rows:
        by_sid[r.get("sid", "")].append(r)
    for sid, items in by_sid.items():
        cur = []
        for r in items:
            if cur and (r["_dt"] - cur[-1]["_dt"]) > timedelta(hours=2):
                sessions.append(cur)
                cur = []
            cur.append(r)
        if cur:
            sessions.append(cur)
    sessions.sort(key=lambda s: s[0]["_dt"], reverse=True)
    a["sessions"] = sessions

    # cwd attribution: where you were STANDING when you typed it, which is not
    # the same question as which alias the command named.
    a["from"] = Counter(cwd_alias(r.get("cwd", ""), amap) or "(elsewhere)" for r in rows)

    # ---- friction ----
    fr = []

    def add(kind, level, what, count, detail=""):
        fr.append({"kind": kind, "level": level, "what": what, "n": count, "detail": detail})

    unknown = [r for r in rows if r.get("resolved") == "unknown"]
    if unknown:
        names = Counter(r.get("alias", "") for r in unknown)
        add("unknown alias", "serious",
            "a name nix did not know, with no picker offered",
            len(unknown), ", ".join(f"{k} x{v}" for k, v in names.most_common(5)))

    cancels = [r for r in rows if r.get("resolved") == "picker-cancel"]
    if cancels:
        names = Counter(r.get("alias", "") for r in cancels)
        add("picker abandoned", "serious",
            "the directory picker opened and nothing was picked",
            len(cancels), ", ".join(f"{k} x{v}" for k, v in names.most_common(5)))

    scancel = [r for r in rows if any(s.get("e") == "search.cancel" for s in r.get("steps", []))]
    if scancel:
        pats = Counter(s["d"] for r in scancel for s in r.get("steps", [])
                       if s.get("e") == "search.cancel" and s.get("d"))
        add("search abandoned", "warning",
            "a pattern worth typing, and nothing in the results worth opening",
            len(scancel), ", ".join(f'"{k}" x{v}' for k, v in pats.most_common(5)))

    failed = [r for r in rows if r.get("child_exit", 0) not in (0, None)]
    if failed:
        what = Counter((r.get("action") or r.get("cmd", ""))[:60] for r in failed)
        add("command failed", "warning",
            "the thing nix ran came back non-zero",
            len(failed), ", ".join(f"{k} x{v}" for k, v in what.most_common(5)))

    nixfail = [r for r in rows if r.get("exit", 0) != 0 and r.get("child_exit", 0) in (0, None)]
    if nixfail:
        add("nix refused", "serious",
            "nix itself failed before running anything",
            len(nixfail), ", ".join(f"{k} x{v}" for k, v in
                                    Counter(r.get("verb", "?") for r in nixfail).most_common(5)))

    rejects = Counter(s["d"] for r in rows for s in r.get("steps", [])
                      if s.get("e") == "grammar.reject")
    if rejects:
        add("flag not understood", "warning",
            "a spelling nix has no row for - a habit from another tool",
            sum(rejects.values()), ", ".join(f"{k} x{v}" for k, v in rejects.most_common(5)))

    trust = Counter(s["d"] for r in rows for s in r.get("steps", [])
                    if s.get("e") == "trust.decide" and s.get("d") != "allow")
    if trust:
        add("trust prompt", "warning",
            "the provenance gate stopped to ask before running",
            sum(trust.values()), ", ".join(f"{k} x{v}" for k, v in trust.most_common(5)))

    # A literal command typed repeatedly is an action waiting to be declared.
    lit = Counter()
    for r in rows:
        if r.get("cmd") and not r.get("action"):
            lit[(r.get("alias", ""), r["cmd"][:70])] += 1
    repeats = [(k, v) for k, v in lit.items() if v >= 3]
    if repeats:
        repeats.sort(key=lambda kv: -kv[1])
        add("literal command repeated", "warning",
            "typed 3+ times and never declared as an action",
            sum(v for _, v in repeats),
            "; ".join(f'x{v} `x {al} {c}`' for (al, c), v in repeats[:5]))

    slow = [r for r in rows if r.get("us", 0) > 50000]
    if slow:
        add("nix itself was slow", "warning",
            "over 50 ms in nix's own code, before anything was run",
            len(slow), ", ".join(f'{r.get("verb","?")} {r["us"]/1000:.0f}ms' for r in slow[:5]))

    fr.sort(key=lambda f: (-{"critical": 3, "serious": 2, "warning": 1, "good": 0}[f["level"]], -f["n"]))
    a["friction"] = fr

    # ---- where it helped ----
    a["hits"] = sum(v for k, v in a["resolved"].items() if k in ("hit", "builtin", "segment"))
    a["registers"] = a["resolved"].get("picker-register", 0) + a["resolved"].get("registered", 0)
    a["action_runs"] = sum(1 for r in rows if r.get("action"))
    a["child_total"] = sum(a["child_ms"])

    a["unused"] = [v for v in KNOWN_VERBS if v not in a["verbs"]]

    # ---- retyping cost ----
    # An exact-repeat command line, counted separately for the shell it was
    # typed in. In a FRESH shell history is cold and every repetition is
    # retyped in full, so frequency x characters is the real keystroke bill.
    # Inside an `o` session the same line is an arrow key away, so it is
    # tallied but never billed.
    typed = defaultdict(lambda: {"fresh": 0, "session": 0, "chars": 0})
    for r in rows:
        words = r.get("argv", [])[1:]
        if not words:
            continue
        line = f'{r.get("how","nix")} {" ".join(words)}'
        e = typed[line]
        e["chars"] = len(line)
        if r.get("typed_in") == "session":
            e["session"] += 1
        else:
            e["fresh"] += 1
    billed = []
    for line, e in typed.items():
        total = e["fresh"] + e["session"]
        if total < 3:
            continue
        billed.append({
            "line": line, "fresh": e["fresh"], "session": e["session"],
            "chars": e["chars"], "cost": e["fresh"] * e["chars"],
        })
    billed.sort(key=lambda b: -b["cost"])
    a["retyped"] = billed
    return a


# ---- rendering --------------------------------------------------------------

def bar_rows(counter, top=12):
    items = counter.most_common(top)
    if not items:
        return "<p class='empty'>nothing recorded</p>"
    mx = max(v for _, v in items)
    out = ["<div class='bars'>"]
    for k, v in items:
        w = max(1.5, v / mx * 100)
        out.append(
            f"<div class='bar-row' title='{esc(k)}: {v}'>"
            f"<span class='bar-label'>{esc(k)}</span>"
            f"<span class='bar-track'><span class='bar-fill' style='width:{w:.1f}%'></span></span>"
            f"<span class='bar-val'>{v}</span></div>")
    out.append("</div>")
    return "".join(out)


def heatmap(heat):
    if not heat:
        return "<p class='empty'>nothing recorded</p>"
    mx = max(heat.values())
    cells = []
    cells.append("<div class='heat'>")
    cells.append("<div class='heat-corner'></div>")
    for h in range(24):
        label = f"{h:02d}" if h % 3 == 0 else ""
        cells.append(f"<div class='heat-hour'>{label}</div>")
    for d in range(7):
        cells.append(f"<div class='heat-day'>{WEEKDAYS[d]}</div>")
        for h in range(24):
            n = heat.get((d, h), 0)
            if n == 0:
                cells.append("<div class='heat-cell heat-zero' title='%s %02d:00 - none'></div>"
                             % (WEEKDAYS[d], h))
            else:
                idx = min(len(SEQ) - 1, int((n / mx) ** 0.6 * (len(SEQ) - 1)))
                ink = "#fff" if idx >= 7 else "#0b0b0b"
                cells.append(
                    f"<div class='heat-cell' style='background:{SEQ[idx]};color:{ink}' "
                    f"title='{WEEKDAYS[d]} {h:02d}:00 - {n} command{"" if n==1 else "s"}'>"
                    f"{n if n < 100 else "99+"}</div>")
    cells.append("</div>")
    legend = ("<div class='heat-legend'><span>less</span>"
              + "".join(f"<i style='background:{c}'></i>" for c in SEQ[::2])
              + f"<span>more (max {mx}/h)</span></div>")
    return "".join(cells) + legend


def session_block(sessions, limit=25):
    if not sessions:
        return "<p class='empty'>nothing recorded</p>"
    out = []
    for s in sessions[:limit]:
        start, end = s[0]["_dt"], s[-1]["_dt"]
        span = int((end - start).total_seconds())
        aliases = [a for a, _ in Counter(r.get("alias", "") for r in s if r.get("alias")).most_common(3)]
        head = (f"{start:%a %d %b %H:%M}  -  {len(s)} command{'' if len(s)==1 else 's'}"
                f" over {human_ms(span*1000)}"
                + (f"  -  {', '.join(aliases)}" if aliases else ""))
        rows = []
        prev = None
        for r in s:
            gap = "" if prev is None else f"+{int((r['_dt']-prev).total_seconds())}s"
            prev = r["_dt"]
            words = " ".join(r.get("argv", [])[1:])[:110]
            bits = []
            if r.get("child_ms", -1) >= 0:
                bits.append(human_ms(r["child_ms"]))
            if r.get("exit", 0) != 0 or r.get("child_exit", 0) not in (0, None):
                bits.append("FAILED")
            if r.get("resolved") in ("picker-cancel", "unknown"):
                bits.append(r["resolved"])
            meta = " ".join(bits)
            cls = " fail" if "FAILED" in bits else ""
            rows.append(
                f"<tr class='{cls.strip()}'><td class='t'>{r['_dt']:%H:%M:%S}</td>"
                f"<td class='g'>{esc(gap)}</td>"
                f"<td class='c'><code>{esc(r.get('how',''))} {esc(words)}</code></td>"
                f"<td class='m'>{esc(meta)}</td></tr>")
        out.append(
            "<details class='sess'><summary>" + esc(head) + "</summary>"
            "<table class='sesstbl'>" + "".join(rows) + "</table></details>")
    return "".join(out)


def retyped_table(billed):
    """Exact repeats, billed only for the fresh-shell half.

    A `[bin]` export is the fix nix already has: `xc = ":claude"` under [bin]
    in ~/.nix/actions/<alias>.toml makes `xc` a global command.
    """
    if not billed:
        return "<p class='empty'>nothing typed three or more times yet</p>"
    rows = []
    for b in billed[:20]:
        note = ""
        if b["session"] and not b["fresh"]:
            note = "<span class='sub'>only inside sessions - history covers it</span>"
        elif b["session"]:
            note = f"<span class='sub'>{b['session']} of them inside a session (not billed)</span>"
        rows.append(
            f"<tr><td class='n'>{b['cost']}</td>"
            f"<td><code>{esc(b['line'][:90])}</code><br>{note}</td>"
            f"<td class='n'>{b['fresh']}</td>"
            f"<td class='n'>{b['chars']}</td></tr>")
    return ("<p class='sub'>Ranked by keystrokes actually spent: "
            "<strong>fresh-shell repeats &times; characters</strong>. Repeats inside an "
            "<code>o</code> session are counted but not billed - history reaches them. "
            "The fix for a top row is a <code>[bin]</code> export "
            "(<code>xc = \":claude\"</code>).</p>"
            "<table class='ftable'><thead><tr><th>keystrokes</th><th>command</th>"
            "<th>fresh</th><th>chars</th></tr></thead><tbody>"
            + "".join(rows) + "</tbody></table>")


def friction_table(fr):
    if not fr:
        return "<p class='empty'>nothing to report - no failures, no abandoned pickers, no repeats</p>"
    rows = []
    for f in fr:
        rows.append(
            f"<tr><td><span class='pill {f['level']}'>{esc(f['level'])}</span></td>"
            f"<td class='n'>{f['n']}</td>"
            f"<td><strong>{esc(f['kind'])}</strong><br><span class='sub'>{esc(f['what'])}</span></td>"
            f"<td class='detail'>{esc(f['detail'])}</td></tr>")
    return ("<table class='ftable'><thead><tr><th>level</th><th>n</th>"
            "<th>what happened</th><th>detail</th></tr></thead><tbody>"
            + "".join(rows) + "</tbody></table>")


def render(a, log_path):
    period = "no data"
    if a["first"]:
        period = f"{a['first']:%a %d %b %H:%M} to {a['last']:%a %d %b %H:%M}"
    p50 = pct(a["self_us"], 0.50)
    p95 = pct(a["self_us"], 0.95)

    tiles = [
        ("invocations", f"{a['n']}", period),
        ("sessions", f"{len(a['sessions'])}", "a console's worth of work, split on a 2h gap"),
        ("nix's own time", f"{p50/1000:.1f} ms", f"median; p95 {p95/1000:.1f} ms"),
        ("time in commands nix ran", human_ms(a["child_total"]), f"{len(a['child_ms'])} foreground children"),
        ("resolutions that just hit", f"{a['hits']}", f"{a['registers']} needed the picker"),
        ("named actions run", f"{a['action_runs']}", "vs literal commands typed out"),
    ]
    tile_html = "".join(
        f"<div class='tile'><div class='tile-k'>{esc(k)}</div>"
        f"<div class='tile-v'>{esc(v)}</div><div class='tile-s'>{esc(s)}</div></div>"
        for k, v, s in tiles)

    unused = a["unused"]
    unused_html = ("<p class='empty'>every known command was used at least once</p>"
                   if not unused else
                   "<p class='sub'>Never reached in this window - the cut list, if it stays empty:</p>"
                   "<p class='chips'>" + "".join(f"<span class='chip'>{esc(v)}</span>" for v in unused) + "</p>")

    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>nix telemetry - {esc(period)}</title>
<style>
:root {{
  color-scheme: light;
  --surface-1:#fcfcfb; --plane:#f9f9f7; --ink:#0b0b0b; --ink-2:#52514e;
  --muted:#898781; --grid:#e1e0d9; --axis:#c3c2b7; --border:rgba(11,11,11,0.10);
  --series-1:#2a78d6;
  --good:{STATUS['good']}; --warning:{STATUS['warning']};
  --serious:{STATUS['serious']}; --critical:{STATUS['critical']};
}}
@media (prefers-color-scheme: dark) {{
  :root:where(:not([data-theme="light"])) {{
    color-scheme: dark;
    --surface-1:#1a1a19; --plane:#0d0d0d; --ink:#fff; --ink-2:#c3c2b7;
    --muted:#898781; --grid:#2c2c2a; --axis:#383835; --border:rgba(255,255,255,0.10);
    --series-1:#3987e5;
  }}
}}
:root[data-theme="dark"] {{
  color-scheme: dark;
  --surface-1:#1a1a19; --plane:#0d0d0d; --ink:#fff; --ink-2:#c3c2b7;
  --muted:#898781; --grid:#2c2c2a; --axis:#383835; --border:rgba(255,255,255,0.10);
  --series-1:#3987e5;
}}
* {{ box-sizing:border-box; }}
body {{ margin:0; background:var(--plane); color:var(--ink);
  font:14px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif; }}
.wrap {{ max-width:1100px; margin:0 auto; padding:32px 20px 80px; }}
h1 {{ font-size:22px; margin:0 0 4px; letter-spacing:-0.01em; }}
h2 {{ font-size:15px; margin:36px 0 12px; letter-spacing:0.02em;
  text-transform:uppercase; color:var(--ink-2); }}
.sub {{ color:var(--ink-2); margin:0 0 12px; }}
.empty {{ color:var(--muted); font-style:italic; }}
.card {{ background:var(--surface-1); border:1px solid var(--border);
  border-radius:10px; padding:16px 18px; overflow-x:auto; }}
.tiles {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(190px,1fr)); gap:10px; }}
.tile {{ background:var(--surface-1); border:1px solid var(--border);
  border-radius:10px; padding:14px 16px; }}
.tile-k {{ color:var(--muted); font-size:12px; text-transform:uppercase; letter-spacing:0.04em; }}
.tile-v {{ font-size:26px; font-weight:650; margin:2px 0; letter-spacing:-0.02em; }}
.tile-s {{ color:var(--ink-2); font-size:12px; }}
.cols {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(320px,1fr)); gap:16px; }}
.bars {{ display:flex; flex-direction:column; gap:6px; }}
.bar-row {{ display:grid; grid-template-columns:150px 1fr 44px; align-items:center; gap:10px; }}
.bar-label {{ color:var(--ink-2); font-size:13px; overflow:hidden;
  text-overflow:ellipsis; white-space:nowrap; }}
.bar-track {{ background:var(--grid); height:10px; border-radius:5px; }}
.bar-fill {{ display:block; height:10px; background:var(--series-1);
  border-radius:0 4px 4px 0; }}
.bar-val {{ text-align:right; color:var(--ink-2); font-variant-numeric:tabular-nums; }}
.heat {{ display:grid; grid-template-columns:38px repeat(24,1fr); gap:2px; min-width:640px; }}
.heat-hour, .heat-day {{ color:var(--muted); font-size:11px; text-align:center; }}
.heat-day {{ text-align:right; padding-right:6px; line-height:22px; }}
.heat-cell {{ height:22px; border-radius:4px; background:var(--grid);
  font-size:10px; text-align:center; line-height:22px;
  font-variant-numeric:tabular-nums; }}
.heat-zero {{ background:var(--grid); opacity:0.45; }}
.heat-legend {{ display:flex; align-items:center; gap:4px; margin-top:10px;
  color:var(--muted); font-size:11px; }}
.heat-legend i {{ width:16px; height:10px; border-radius:2px; display:inline-block; }}
table {{ border-collapse:collapse; width:100%; font-size:13px; }}
th {{ text-align:left; color:var(--muted); font-weight:600; font-size:11px;
  text-transform:uppercase; letter-spacing:0.04em; padding:0 10px 8px 0;
  border-bottom:1px solid var(--grid); }}
td {{ padding:9px 10px 9px 0; border-bottom:1px solid var(--grid);
  vertical-align:top; }}
td.n {{ font-variant-numeric:tabular-nums; font-weight:650; }}
td.detail, .sub {{ color:var(--ink-2); }}
.pill {{ display:inline-block; padding:2px 8px; border-radius:999px;
  font-size:11px; font-weight:650; color:#0b0b0b; }}
.pill.good {{ background:var(--good); color:#fff; }}
.pill.warning {{ background:var(--warning); }}
.pill.serious {{ background:var(--serious); }}
.pill.critical {{ background:var(--critical); color:#fff; }}
.chips {{ display:flex; flex-wrap:wrap; gap:6px; }}
.chip {{ border:1px solid var(--axis); color:var(--ink-2); border-radius:999px;
  padding:2px 10px; font-size:12px; }}
details.sess {{ border-bottom:1px solid var(--grid); }}
details.sess summary {{ cursor:pointer; padding:9px 0; font-size:13px; }}
details.sess[open] summary {{ font-weight:650; }}
.sesstbl td {{ border:0; padding:3px 10px 3px 0; font-size:12.5px; }}
.sesstbl td.t {{ color:var(--muted); font-variant-numeric:tabular-nums; width:74px; }}
.sesstbl td.g {{ color:var(--muted); width:56px; font-variant-numeric:tabular-nums; }}
.sesstbl td.m {{ color:var(--ink-2); white-space:nowrap; }}
.sesstbl tr.fail td.m {{ color:var(--critical); font-weight:650; }}
code {{ font:12.5px/1.4 ui-monospace,"Cascadia Code",Consolas,monospace; }}
footer {{ margin-top:40px; color:var(--muted); font-size:12px; }}
</style></head><body><div class="wrap">

<h1>nix telemetry</h1>
<p class="sub">{esc(period)} &middot; {esc(log_path)}</p>

<div class="tiles">{tile_html}</div>

<h2>When</h2>
<div class="card">{heatmap(a['heat'])}</div>

<h2>What</h2>
<div class="cols">
  <div class="card"><p class="sub">Commands, by verb</p>{bar_rows(a['verbs'])}</div>
  <div class="card"><p class="sub">Projects, by how often named</p>{bar_rows(a['aliases'])}</div>
  <div class="card"><p class="sub">How it was typed (wrapper vs `nix`)</p>{bar_rows(a['hows'])}</div>
  <div class="card"><p class="sub">Which shell it was typed in</p>{bar_rows(a['typed_in'])}</div>
  <div class="card"><p class="sub">Named actions run</p>{bar_rows(a['actions'])}</div>
  <div class="card"><p class="sub">Where you were standing (cwd)</p>{bar_rows(a['from'])}</div>
  <div class="card"><p class="sub">How the alias resolved</p>{bar_rows(a['resolved'])}</div>
</div>

<h2>Retyped - what a shortcut would save</h2>
<div class="card">{retyped_table(a['retyped'])}</div>

<h2>Friction - where nix was in the way</h2>
<div class="card">{friction_table(a['friction'])}</div>

<h2>Coverage</h2>
<div class="card">{unused_html}</div>

<h2>Sessions</h2>
<div class="card">{session_block(a['sessions'])}</div>

<footer>Generated from {esc(a['n'])} invocations. Local file, never uploaded.</footer>
</div></body></html>
"""


def main():
    home = os.environ.get("NIX_HOME") or str(Path.home() / ".nix")
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", default=str(Path(home) / "telemetry.jsonl"))
    ap.add_argument("--out", default=str(Path(home) / "telemetry-report.html"))
    ap.add_argument("--days", type=int, default=0, help="only the last N days")
    ap.add_argument("--nix-home", default=home)
    args = ap.parse_args()

    if not Path(args.log).exists():
        raise SystemExit(f"no telemetry log at {args.log}")
    rows = load(args.log, args.days)
    a = analyze(rows, alias_map(args.nix_home))
    Path(args.out).write_text(render(a, args.log), encoding="utf-8")
    print(f"{len(rows)} invocations -> {args.out}")


if __name__ == "__main__":
    main()
