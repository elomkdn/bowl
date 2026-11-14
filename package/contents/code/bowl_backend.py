#!/usr/bin/env python3
"""Bowl's backend: talks to the Claude Code, Codex and OpenCode CLIs.

The QML side calls it through Plasma's executable data engine:
  usage                                 print quotas, token stats and recent projects as JSON
  refresh [--force]                     refresh Claude's quota from Anthropic's usage endpoint
  terminal AGENT FOLDER SESSION NOTICE  open the agent in a terminal; failures go to stderr
                                        as a code (agent, folder, terminal, invalid)
  run LAUNCH                            what that terminal runs
"""
import json
import os
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.request
from datetime import date, datetime, timedelta
from itertools import islice
from pathlib import Path

HOME = Path.home()
CACHE = Path(os.environ.get("XDG_CACHE_HOME", HOME / ".cache")) / "bowl"
USAGE = CACHE / "usage.json"        # Claude quota
CODEX_STATE = CACHE / "codex.json"  # Codex plan
TOKENS = CACHE / "tokens.json"
CLAUDE_HOME = Path(os.environ.get("CLAUDE_CONFIG_DIR", HOME / ".claude"))
CLAUDE_PROJECTS = CLAUDE_HOME / "projects"
CLAUDE_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
CODEX_SESSIONS = Path(os.environ.get("CODEX_HOME", HOME / ".codex")) / "sessions"
OPENCODE_DB = Path(os.environ.get("XDG_DATA_HOME", HOME / ".local/share")) / "opencode" / "opencode.db"

AGENTS = ("claude", "codex", "opencode")
ACTIVE_REFRESH_EVERY = 300  # seconds between two Claude quota checks while Claude Code is used
IDLE_REFRESH_EVERY = 900    # otherwise, for what is done on other devices and on the web
FORCED_REFRESH_EVERY = 15
RECENT_PROJECTS = 6
QUICK_EXIT = 10  # an agent that fails faster than this, in seconds, keeps its window open
SESSION_FORMATS = {
    "claude": re.compile(r"^[0-9a-fA-F-]{36}$"),
    "codex": re.compile(r"^[0-9a-fA-F-]{36}$"),
    "opencode": re.compile(r"^ses_[A-Za-z0-9]{8,64}$"),
}


def read_json(path, default=None):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def write_json(path, data):
    CACHE.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=CACHE, prefix=path.name)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    os.replace(tmp, path)


def claude_env():
    """Environment in which Claude Code can only use the claude.ai subscription."""
    env = os.environ.copy()
    for key in list(env):
        if key.startswith("CLAUDE_CODE_") or key in (
            "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
            "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT",
        ):
            del env[key]
    return env


def agent_bin(agent):
    return shutil.which(agent) or str(HOME / ".local/bin" / agent)


def spawn_self(*args):
    return subprocess.Popen(
        [sys.executable, os.path.abspath(__file__), *args],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
    )


def local_day(stamp):
    if isinstance(stamp, (int, float)):
        return datetime.fromtimestamp(stamp).date().isoformat()
    return datetime.fromisoformat(stamp.replace("Z", "+00:00")).astimezone().date().isoformat()


def last_7_days(per_day):
    today = date.today()
    return [per_day.get((today - timedelta(days=i)).isoformat(), 0) for i in range(6, -1, -1)]


def scan_appended(path, entry, on_line):
    """Feed on_line with what was appended to a JSON-lines file since the last scan."""
    size = path.stat().st_size
    if size < entry.get("offset", 0):
        entry.clear()
    with open(path, "rb") as f:
        f.seek(entry.get("offset", 0))
        offset = f.tell()
        for raw in f:
            if not raw.endswith(b"\n"):
                break  # line still being written: read it next time
            offset += len(raw)
            on_line(raw, entry)
    entry["offset"] = offset


def scan_tree(root, cache, on_line):
    """Incrementally scan every recent .jsonl under root. Returns the last activity time."""
    limit = time.time() - 8 * 86400
    last_activity = 0
    seen = {}
    if root.is_dir():
        for path in root.rglob("*.jsonl"):
            try:
                stat = path.stat()
            except OSError:
                continue
            last_activity = max(last_activity, stat.st_mtime)
            if stat.st_mtime < limit:
                continue
            key = str(path)
            entry = cache.get(key, {})
            if entry.get("mtime") != stat.st_mtime or entry.get("size") != stat.st_size:
                try:
                    scan_appended(path, entry, on_line)
                except OSError:
                    continue
                entry.update(mtime=stat.st_mtime, size=stat.st_size)
            seen[key] = entry
    cache.clear()
    cache.update(seen)
    return last_activity


def file_sessions(root, cache, read_session):
    """(time, folder, session id) of every transcript under root, whatever its age."""
    sessions, known = [], {}
    if root.is_dir():
        for path in root.rglob("*.jsonl"):
            key = str(path)
            try:
                mtime = path.stat().st_mtime
                info = cache.get(key) or read_session(path)
            except OSError:
                continue
            if info:
                known[key] = info
                sessions.append((mtime, *info))
    cache.clear()
    cache.update(known)
    return sessions


def recent_projects(sessions):
    """The folders worked in, newest first, each with its latest session."""
    projects, seen = [], set()
    for _, folder, session in sorted(sessions, key=lambda s: s[0], reverse=True):
        if folder in seen:
            continue
        seen.add(folder)
        path = Path(folder)
        if (
            path == HOME or path.is_relative_to(tempfile.gettempdir())
            or path.is_relative_to(CACHE) or not path.is_dir()
        ):
            continue
        projects.append({"path": folder, "name": path.name, "session": session})
        if len(projects) == RECENT_PROJECTS:
            break
    return projects


# ---- Claude ---------------------------------------------------------------------

def record_rate_limit(info):
    windows = info.get("unifiedWindows") or {}
    if not windows:
        return
    usage = read_json(USAGE, {})
    for name in ("five_hour", "seven_day"):
        if name in windows:
            usage[name] = windows[name]
    usage["updatedAt"] = time.time()
    write_json(USAGE, usage)


def claude_token():
    """Claude Code's access token, if it is still valid. Only Claude Code renews it, when it runs."""
    login = (read_json(CLAUDE_HOME / ".credentials.json", {}) or {}).get("claudeAiOauth")
    if not isinstance(login, dict):
        return ""
    expires = (login.get("expiresAt") or 0) / 1000
    if expires and expires < time.time() + 30:
        return ""
    return login.get("accessToken") or ""


def reset_time(text):
    try:
        return datetime.fromisoformat(str(text).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0


def quota_window(percent, resets_at):
    used = percent / 100
    return {"utilization": used, "resetsAt": reset_time(resets_at),
            "status": "rejected" if used >= 1 else "allowed"}


def fetch_claude_quota(token):
    """The windows Claude Code's /usage shows, read from Anthropic without spending any quota.

    The token is sent to Anthropic only. Returns None when the quota could not be read.
    """
    request = urllib.request.Request(CLAUDE_USAGE_URL, headers={
        "Authorization": "Bearer " + token,
        "anthropic-beta": "oauth-2025-04-20",
        "Accept": "application/json",
    })
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            payload = json.loads(response.read(1 << 20))
    except (OSError, ValueError):
        return None
    if not isinstance(payload, dict):
        return None
    windows = {}
    for name in ("five_hour", "seven_day"):
        w = payload.get(name)
        if isinstance(w, dict) and isinstance(w.get("utilization"), (int, float)):
            windows[name] = quota_window(w["utilization"], w.get("resets_at"))
    if not windows:
        return None
    # Some models have a window of their own on top of the account's: Fable's week, say.
    # Each one goes with the account's window of the same length.
    for name in windows:
        windows[name]["models"] = []
    for entry in payload.get("limits") or []:
        if not isinstance(entry, dict) or not isinstance(entry.get("percent"), (int, float)):
            continue
        scope = entry.get("scope") if isinstance(entry.get("scope"), dict) else {}
        model = scope.get("model") if isinstance(scope.get("model"), dict) else {}
        label = model.get("display_name") or model.get("id")
        kind = str(entry.get("kind") or "")
        parent = "five_hour" if "session" in kind or "hour" in kind else "seven_day"
        if label and parent in windows:
            windows[parent]["models"].append(
                dict(quota_window(entry["percent"], entry.get("resets_at")), name=str(label)))
    return windows


def cmd_refresh(force):
    usage = read_json(USAGE, {})
    wait = FORCED_REFRESH_EVERY if force else ACTIVE_REFRESH_EVERY
    if time.time() - usage.get("lastCheck", 0) < wait:
        return
    usage["lastCheck"] = time.time()
    write_json(USAGE, usage)
    token = claude_token()
    windows = fetch_claude_quota(token) if token else None
    if windows:
        fresh = read_json(USAGE, {})
        fresh.update(windows, updatedAt=time.time())
        write_json(USAGE, fresh)
    elif force:
        # A lapsed token is renewed by running Claude Code: a minimal Haiku request
        # does that, and reports the windows on the way.
        ping_haiku()


def ping_haiku():
    cmd = [
        agent_bin("claude"), "-p", "--model", "haiku", "--no-session-persistence",
        "--output-format", "stream-json", "--verbose", "--tools", "",
        "--system-prompt", "Reply: ok", "--setting-sources", "",
        "--strict-mcp-config", "--disable-slash-commands",
    ]
    try:
        out = subprocess.run(
            cmd, input="ok", capture_output=True, text=True, timeout=60,
            env=claude_env(), cwd=CACHE,
        ).stdout
    except (OSError, subprocess.TimeoutExpired):
        return
    for line in out.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get("type") == "system" and event.get("apiKeySource", "none") != "none":
            return
        if event.get("type") == "rate_limit_event":
            record_rate_limit(event.get("rate_limit_info") or {})


def claude_plan(usage):
    """Subscription name, refreshed once a day."""
    if usage.get("plan") and time.time() - usage.get("planAt", 0) < 86400:
        return usage["plan"]
    try:
        out = subprocess.run(
            [agent_bin("claude"), "auth", "status", "--json"], capture_output=True,
            text=True, timeout=15, env=claude_env(), cwd=CACHE,
        ).stdout
        plan = json.loads(out).get("subscriptionType") or ""
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return usage.get("plan", "")
    fresh = read_json(USAGE, {})
    fresh.update(plan=plan, planAt=time.time())
    write_json(USAGE, fresh)
    return plan


def claude_line(raw, entry):
    if b'"usage"' not in raw or b'"assistant"' not in raw:
        return
    try:
        record = json.loads(raw)
    except ValueError:
        return
    if record.get("type") != "assistant":
        return
    message = record.get("message") or {}
    usage = message.get("usage")
    if not usage or not record.get("timestamp") or not message.get("id"):
        return
    entry.setdefault("messages", {})[message["id"]] = [
        local_day(record["timestamp"]),
        (usage.get("input_tokens") or 0)
        + (usage.get("cache_creation_input_tokens") or 0)
        + (usage.get("output_tokens") or 0),
    ]


def claude_session(path):
    with open(path, "rb") as f:
        for raw in islice(f, 50):  # the first lines can be metadata without a folder
            if b'"cwd"' not in raw:
                continue
            try:
                record = json.loads(raw)
            except ValueError:
                continue
            if record.get("cwd") and record.get("sessionId"):
                return [record["cwd"], record["sessionId"]]
    return None


def claude_usage(cache):
    files = cache.setdefault("claude", {})
    last_activity = scan_tree(CLAUDE_PROJECTS, files, claude_line)
    # A resumed or forked session repeats messages: count each id once.
    messages = {}
    for entry in files.values():
        messages.update(entry.get("messages", {}))
    per_day = {}
    for day, count in messages.values():
        per_day[day] = per_day.get(day, 0) + count

    usage = read_json(USAGE, {})
    # Checking the quota costs nothing: more often while Claude Code is in use
    active = last_activity > usage.get("updatedAt", 0) + 20
    if time.time() - usage.get("lastCheck", 0) >= (ACTIVE_REFRESH_EVERY if active else IDLE_REFRESH_EVERY):
        spawn_self("refresh")

    windows = []
    for name, minutes in (("five_hour", 300), ("seven_day", 10080)):
        w = usage.get(name)
        if w:
            windows.append({"minutes": minutes, "length": minutes * 60,
                            "utilization": w.get("utilization", 0),
                            "resetsAt": w.get("resetsAt", 0), "status": w.get("status", ""),
                            "models": w.get("models", [])})
    return {
        "plan": claude_plan(usage), "windows": windows, "days": last_7_days(per_day),
        "lastActivity": last_activity, "updatedAt": usage.get("updatedAt", 0),
        "projects": recent_projects(file_sessions(
            CLAUDE_PROJECTS, cache.setdefault("claude_sessions", {}), claude_session)),
    }


# ---- Codex ----------------------------------------------------------------------

def parse_codex_limit(message):
    """'… try again at Nov 23rd, 2026 6:38 AM.' -> timestamp, or None."""
    found = re.search(r"try again at (.+?)\.?\s*$", message or "")
    if not found:
        return None
    text = re.sub(r"(\d+)(st|nd|rd|th)", r"\1", found.group(1).strip())
    for pattern in ("%b %d, %Y %I:%M %p", "%B %d, %Y %I:%M %p"):
        try:
            return datetime.strptime(text, pattern).timestamp()
        except ValueError:
            continue
    return None


def codex_line(raw, entry):
    if b'"token_count"' not in raw and b'"task_complete"' not in raw:
        return
    try:
        record = json.loads(raw)
    except ValueError:
        return
    payload = record.get("payload") or {}
    stamp = record.get("timestamp")
    if payload.get("type") == "task_complete" and stamp:
        error = (payload.get("error") or {}).get("message") or ""
        if not error or "usage limit" in error.lower():  # other failures say nothing of the quota
            entry["turn"] = {"at": stamp, "limited": bool(error), "until": parse_codex_limit(error)}
        return
    if payload.get("type") != "token_count" or not stamp:
        return
    last = (payload.get("info") or {}).get("last_token_usage") or {}
    if last:
        day = local_day(stamp)
        days = entry.setdefault("days", {})
        days[day] = days.get(day, 0) + max(0, (last.get("input_tokens") or 0)
                                           - (last.get("cached_input_tokens") or 0)) \
            + (last.get("output_tokens") or 0)
    limits = payload.get("rate_limits") or {}
    if limits.get("primary") or limits.get("secondary"):
        entry["limits"] = {"at": stamp, "primary": limits.get("primary"),
                           "secondary": limits.get("secondary")}


def codex_window(w, stamp):
    at = datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
    reset = w.get("resets_at")
    if isinstance(reset, str):
        try:
            reset = datetime.fromisoformat(reset.replace("Z", "+00:00")).timestamp()
        except ValueError:
            reset = 0
    if not reset and w.get("resets_in_seconds") is not None:
        reset = at + w["resets_in_seconds"]
    used = (w.get("used_percent") or 0) / 100
    minutes = w.get("window_minutes") or 0
    return {"minutes": minutes, "length": minutes * 60, "utilization": used,
            "resetsAt": reset or 0, "status": "rejected" if used >= 1 else "allowed"}


def codex_login():
    try:
        out = subprocess.run([agent_bin("codex"), "login", "status"], capture_output=True,
                             text=True, timeout=15, cwd=CACHE)
        return out.stdout + out.stderr
    except (OSError, subprocess.TimeoutExpired):
        return ""


def codex_plan(state):
    if state.get("plan") is not None and time.time() - state.get("planAt", 0) < 86400:
        return state["plan"]
    text = codex_login()
    if not text:
        return state.get("plan", "")  # Codex did not answer: try again next time
    plan = "ChatGPT" if "ChatGPT" in text else ""
    fresh = read_json(CODEX_STATE, {})
    fresh.update(plan=plan, planAt=time.time())
    write_json(CODEX_STATE, fresh)
    return plan


def codex_session(path):
    with open(path, encoding="utf-8") as f:
        try:
            payload = json.loads(f.readline()).get("payload") or {}
        except ValueError:
            return None
    return [payload["cwd"], payload["id"]] if payload.get("cwd") and payload.get("id") else None


def codex_usage(cache):
    files = cache.setdefault("codex", {})
    last_activity = scan_tree(CODEX_SESSIONS, files, codex_line)
    per_day = {}
    newest = None
    for entry in files.values():
        for day, count in entry.get("days", {}).items():
            per_day[day] = per_day.get(day, 0) + count
        limits = entry.get("limits")
        if limits and (newest is None or limits["at"] > newest["at"]):
            newest = limits
    windows = []
    if newest:
        for key in ("primary", "secondary"):
            if newest.get(key):
                windows.append(codex_window(newest[key], newest["at"]))
    # Kept in the state file: a limit can outlast the days of sessions that are scanned.
    state = read_json(CODEX_STATE, {})
    turn = max((e["turn"] for e in files.values() if e.get("turn")), key=lambda t: t["at"], default=None)
    if turn and turn["at"] > state.get("turnAt", ""):
        state.update(turnAt=turn["at"], limitedUntil=(turn["limited"] and turn["until"]) or 0)
        write_json(CODEX_STATE, state)
    until = state.get("limitedUntil") or 0
    if until > time.time() and not any(w["status"] == "rejected" for w in windows):
        windows.insert(0, {"minutes": 0, "length": 0, "utilization": 1, "resetsAt": until,
                           "status": "rejected"})
    sessions = file_sessions(CODEX_SESSIONS, cache.setdefault("codex_sessions", {}), codex_session)
    return {"plan": codex_plan(state), "windows": windows, "days": last_7_days(per_day),
            "lastActivity": last_activity, "projects": recent_projects(sessions)}


# ---- OpenCode -------------------------------------------------------------------

def opencode_usage():
    per_day, cost_today, last_activity = {}, 0.0, 0
    sessions = []
    try:
        db = sqlite3.connect(f"file:{OPENCODE_DB}?mode=ro", uri=True, timeout=2)
        try:
            since = (time.time() - 8 * 86400) * 1000
            last = db.execute("select max(time_created) from session_message").fetchone()[0]
            last_activity = (last or 0) / 1000
            today = date.today().isoformat()
            rows = db.execute(
                "select time_created, data from session_message where type = 'assistant' and time_created >= ?",
                (since,))
            for created, data in rows:
                try:
                    message = json.loads(data)
                except ValueError:
                    continue
                tokens = message.get("tokens") or {}
                count = (tokens.get("input") or 0) + (tokens.get("output") or 0) \
                    + (tokens.get("reasoning") or 0) + ((tokens.get("cache") or {}).get("write") or 0)
                day = local_day(created / 1000)
                per_day[day] = per_day.get(day, 0) + count
                if day == today:
                    cost_today += message.get("cost") or 0
            sessions = [(updated, folder, session) for session, folder, updated in db.execute(
                "select id, directory, time_updated from session_v2 "
                "where parent_id is null and time_archived is null "
                "order by time_updated desc limit 500")]
        finally:
            db.close()
    except sqlite3.Error:
        pass
    return {"plan": "", "windows": [], "days": last_7_days(per_day),
            "lastActivity": last_activity, "costToday": round(cost_today, 4),
            "projects": recent_projects(sessions)}


# ---- Usage command ----------------------------------------------------------------

def cmd_usage():
    cache = read_json(TOKENS, {})
    agents = {}
    for agent in AGENTS:
        installed = bool(shutil.which(agent))
        data = {"installed": installed}
        if installed:
            try:
                if agent == "claude":
                    data.update(claude_usage(cache))
                elif agent == "codex":
                    data.update(codex_usage(cache))
                else:
                    data.update(opencode_usage())
            except Exception as err:  # one broken agent must not hide the others
                data.update(windows=[], days=[0] * 7, lastActivity=0, error=str(err))
        agents[agent] = data
    write_json(TOKENS, cache)
    print(json.dumps({"agents": agents, "now": time.time()}))


def cmd_terminal(agent, folder, session, notice):
    if agent not in AGENTS or (session and not SESSION_FORMATS[agent].match(session)):
        sys.exit("invalid")
    folder = folder or str(HOME)
    if not os.path.isdir(folder):
        sys.exit("folder")
    if not os.path.exists(agent_bin(agent)):
        sys.exit("agent")
    try:
        term = subprocess.run(
            ["kreadconfig6", "--group", "General", "--key", "TerminalApplication"],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        term = ""
    term = term.split()[0] if term else "konsole"
    if not shutil.which(term):
        term = "konsole"
    # Terminals differ in how they pass arguments on: the details travel in a file.
    fd, launch = tempfile.mkstemp(dir=CACHE, prefix="launch-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump({"agent": agent, "folder": folder, "session": session, "notice": notice}, f)
    try:
        subprocess.Popen(
            [term, "-e", sys.executable, os.path.abspath(__file__), "run", launch], cwd=folder,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
        )
    except OSError:
        os.unlink(launch)
        sys.exit("terminal")


def cmd_run(launch):
    """Run the agent inside the terminal, and keep the window open if it fails at once."""
    spec = read_json(Path(launch), {})
    Path(launch).unlink(missing_ok=True)
    agent, session = spec["agent"], spec["session"]
    command = [agent_bin(agent)]
    if session:
        command += {"claude": ["--resume", session], "codex": ["resume", session],
                    "opencode": ["--session", session]}[agent]
    signal.signal(signal.SIGINT, lambda *_: None)  # Ctrl+C is for the agent
    started = time.monotonic()
    try:
        code = subprocess.call(command, cwd=spec["folder"],
                               env=claude_env() if agent == "claude" else os.environ.copy())
    except OSError as err:
        print(err)
        code = 127
    if code != 0 and time.monotonic() - started < QUICK_EXIT:
        print("\n" + spec["notice"])
        signal.signal(signal.SIGINT, signal.default_int_handler)
        try:
            input()
        except (EOFError, KeyboardInterrupt):
            pass


def main():
    CACHE.mkdir(mode=0o700, parents=True, exist_ok=True)  # also the Haiku request's working directory
    CACHE.chmod(0o700)
    args = sys.argv[1:]
    command = args[0] if args else ""
    if command == "usage":
        cmd_usage()
    elif command == "refresh":
        cmd_refresh("--force" in args)
    elif command == "terminal" and len(args) == 5:
        cmd_terminal(*args[1:])
    elif command == "run" and len(args) == 2:
        cmd_run(args[1])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
