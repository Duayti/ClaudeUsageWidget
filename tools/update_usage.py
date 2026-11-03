#!/usr/bin/env python3
"""Compute Claude Code token usage from its session transcripts and write it for the widget.

Reads <projects-dir>/**/*.jsonl (default ~/.claude/projects) and writes ~/.claude/usage-widget.json
with the same schema as ~/.claude/stats-cache.json (which Claude Code only regenerates when you open /stats).

- Counts like /stats: sums message.usage of EVERY "assistant" line (except the '<synthetic>' model),
  without de-duplicating. Claude Code writes one line per content block and repeats the usage on each
  one; /stats sums them all, and so does this script.
- Groups by local day (the timestamp of each line) and by model, subagents included.
- Incremental: stores per file (inode, mtime, size, offset and what it contributed) in
  usage-widget-state.json and only reads the new bytes. If a file is replaced or truncated, its old
  contribution is subtracted and it is re-read from the start; if it is deleted, its history is kept.
- Atomic writes (temp file + rename) with 0600 permissions.

Usage:
  python3 -I update_usage.py [--claude-dir DIR] [--projects-dir DIR] [--output FILE] [--state FILE] [--full]

Standard library only; works with the Python 3.9 that ships with macOS. The script is portable: it can
also run on Linux or Windows (use --projects-dir / --output there), but the widget itself is macOS-only.
"""
import argparse
import json
import os
import re
import sys
import tempfile
import time
from datetime import date, datetime, timezone

STATE_VERSION = 2   # 2: no de-duplication, per-file contributions
OUTPUT_VERSION = 5  # same as stats-cache.json
FIELDS = ("input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")
# Cheap filter before json.loads: most lines (attachments, blobs) are irrelevant.
INTERESTING = re.compile(rb'"type"\s*:\s*"(?:assistant|user)"')


# --------------------------------------------------------------------------- state

def empty_state(root):
    return {
        "version": STATE_VERSION,
        "root": root,
        "files": {},      # path -> {ino, mtime, size, offset, tokens, activity} (what it contributed)
        "tokens": {},     # day -> model -> [in, out, cache_creation, cache_read, web_searches]
        "activity": {},   # day -> [messages, tool calls]
        "sessions": {},   # sessionId -> ISO timestamp of the first line (main files only)
    }


def load_state(path, root):
    try:
        with open(path) as f:
            st = json.load(f)
        if st.get("version") == STATE_VERSION and st.get("root") == root and all(
                isinstance(st.get(k), dict) for k in ("files", "tokens", "activity", "sessions")):
            return st, False
        reason = "different version or folder"
    except FileNotFoundError:
        return empty_state(root), True
    except (OSError, ValueError) as err:
        reason = str(err)
    print(f"usage-widget: invalid state ({reason}); recomputing from scratch", file=sys.stderr)
    return empty_state(root), True


# --------------------------------------------------------------------------- dates

class Clock:
    """Converts UTC timestamps to (local day, local hour), cached per minute."""

    def __init__(self, tz=None):
        self.tz = tz
        self.cache = {}

    def day_hour(self, ts):
        if not isinstance(ts, str) or len(ts) < 16:
            return None
        key = ts[:16] if ts.endswith("Z") else None
        if key is not None and key in self.cache:
            return self.cache[key]
        try:
            if key is not None:
                dt = datetime.strptime(key, "%Y-%m-%dT%H:%M").replace(tzinfo=timezone.utc)
            else:
                dt = datetime.fromisoformat(ts)
                if dt.tzinfo is None:
                    dt = dt.replace(tzinfo=timezone.utc)
        except ValueError:
            return None
        local = dt.astimezone(self.tz) if self.tz is not None else dt.astimezone()
        result = (local.strftime("%Y-%m-%d"), local.hour)
        if key is not None:
            self.cache[key] = result
        return result


# --------------------------------------------------------------------------- reading

def to_int(v):
    return v if isinstance(v, int) and v > 0 else 0


def add(target, source, sign=1):
    """Adds (or subtracts) contributions {day: {model: [5]}} and {day: [2]} of a file to the totals."""
    for day, v in source.items():
        if isinstance(v, dict):
            per_day = target.setdefault(day, {})
            for model, n in v.items():
                acc = per_day.setdefault(model, [0] * len(n))
                for i, x in enumerate(n):
                    acc[i] += sign * x
        else:
            acc = target.setdefault(day, [0] * len(v))
            for i, x in enumerate(v):
                acc[i] += sign * x


def process_line(st, contribution, o, is_main, clock):
    kind = o.get("type")
    if kind not in ("assistant", "user"):
        return
    dh = clock.day_hour(o.get("timestamp"))
    if dh is None:
        return
    day = dh[0]
    act = contribution["activity"].setdefault(day, [0, 0])

    sid = o.get("sessionId")
    if is_main and isinstance(sid, str):
        previous = st["sessions"].get(sid)
        if previous is None or o["timestamp"] < previous:
            st["sessions"][sid] = o["timestamp"]

    if kind == "user":
        act[0] += 1
        return

    msg = o.get("message")
    if not isinstance(msg, dict):
        return
    content = msg.get("content")
    if isinstance(content, list):
        act[1] += sum(1 for b in content if isinstance(b, dict) and b.get("type") == "tool_use")
    usage, model = msg.get("usage"), msg.get("model")
    if not isinstance(usage, dict) or not isinstance(model, str) or not model or model == "<synthetic>":
        return
    stu = usage.get("server_tool_use")
    values = [to_int(usage.get(c)) for c in FIELDS] + [to_int(stu.get("web_search_requests")) if isinstance(stu, dict) else 0]
    act[0] += 1
    acc = contribution["tokens"].setdefault(day, {}).setdefault(model, [0, 0, 0, 0, 0])
    for i, v in enumerate(values):
        acc[i] += v


def read_from(st, contribution, path, offset, is_main, clock):
    """Reads whole lines from `offset` and adds them to the file's `contribution`.
    Returns the new offset (excluding a half-written last line)."""
    with open(path, "rb") as f:
        f.seek(offset)
        for line in f:
            if not line.endswith(b"\n"):
                break  # Claude Code is still writing it; it is read on the next run
            offset += len(line)
            if not INTERESTING.search(line):
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if isinstance(o, dict):
                process_line(st, contribution, o, is_main, clock)
    return offset


def transcripts(projects):
    for folder, subfolders, files in os.walk(projects):
        subfolders.sort()
        for name in sorted(files):
            if name.endswith(".jsonl"):
                yield os.path.join(folder, name)


# --------------------------------------------------------------------------- output

def build_output(st, today, clock):
    per_model = {}
    daily, breakdown = [], []
    for day in sorted(st["tokens"]):
        by_model, usage_by_model = {}, {}
        for model, v in sorted(st["tokens"][day].items()):
            total = v[0] + v[1] + v[2] + v[3]
            if total > 0:
                by_model[model] = total
                usage_by_model[model] = {"inputTokens": v[0], "outputTokens": v[1],
                                         "cacheReadInputTokens": v[3], "cacheCreationInputTokens": v[2]}
            acc = per_model.setdefault(model, [0, 0, 0, 0, 0])
            for i in range(5):
                acc[i] += v[i]
        if by_model:
            daily.append({"date": day, "tokensByModel": by_model})
            breakdown.append({"date": day, "usageByModel": usage_by_model})

    starts_per_day, hours = {}, {}
    for ts in st["sessions"].values():
        dh = clock.day_hour(ts)
        if dh:
            starts_per_day[dh[0]] = starts_per_day.get(dh[0], 0) + 1
            hours[str(dh[1])] = hours.get(str(dh[1]), 0) + 1

    activity_days = sorted(set(st["activity"]) | set(starts_per_day))
    activity = []
    for day in activity_days:
        m, t = st["activity"].get(day, [0, 0])
        if not (m or t or starts_per_day.get(day)):
            continue
        activity.append({"date": day, "messageCount": m, "sessionCount": starts_per_day.get(day, 0), "toolCallCount": t})

    output = {
        "version": OUTPUT_VERSION,
        "lastComputedDate": today.isoformat(),
        "dailyActivity": activity,
        "dailyModelTokens": daily,
        "dailyModelTokensVersion": OUTPUT_VERSION,
        # Extra (not in stats-cache.json): token type per day and model, for the per-range table.
        "dailyModelUsage": breakdown,
        "modelUsage": {
            model: {"inputTokens": v[0], "outputTokens": v[1], "cacheReadInputTokens": v[3],
                    "cacheCreationInputTokens": v[2], "webSearchRequests": v[4], "costUSD": 0,
                    "contextWindow": 0, "maxOutputTokens": 0}
            for model, v in sorted(per_model.items()) if v[0] + v[1] + v[2] + v[3] > 0
        },
        "totalSessions": len(st["sessions"]),
        "totalMessages": sum(a[0] for a in st["activity"].values()),
        "hourCounts": {h: hours[h] for h in sorted(hours, key=int)},
    }
    if st["sessions"]:
        output["firstSessionDate"] = min(st["sessions"].values())
    return output


def write_atomic(path, obj):
    folder = os.path.dirname(path) or "."
    os.makedirs(folder, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=folder, prefix=os.path.basename(path) + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(obj, f, separators=(",", ":"))
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# --------------------------------------------------------------------------- main

def update(projects, output, state_path, tz=None, today=None, full=False):
    """Reads the transcripts under `projects`, writes `output` and `state_path`, returns run statistics."""
    started = time.monotonic()
    root = os.path.realpath(projects)
    if full:
        st, from_scratch = empty_state(root), True
    else:
        st, from_scratch = load_state(state_path, root)
    clock = Clock(tz)

    seen, files_read, bytes_read = set(), 0, 0
    for path in transcripts(projects):
        try:
            info = os.stat(path)
        except OSError:
            continue
        seen.add(path)
        previous = st["files"].get(path)
        if previous and previous.get("ino") == info.st_ino and info.st_size >= previous.get("offset", 0):
            offset = previous["offset"]
            if info.st_size == offset:
                previous["mtime"] = info.st_mtime
                continue
            contribution = {"tokens": previous.get("tokens", {}), "activity": previous.get("activity", {})}
        else:
            offset = 0  # new, replaced or truncated file: re-read from the start
            contribution = {"tokens": {}, "activity": {}}
        is_main = "subagents" not in os.path.relpath(path, projects).split(os.sep)
        fresh = {"tokens": {}, "activity": {}}
        try:
            new_offset = read_from(st, fresh, path, offset, is_main, clock)
        except OSError as err:
            print(f"usage-widget: could not read {path}: {err}", file=sys.stderr)
            continue
        if offset == 0 and previous:
            # What the file contributed before is subtracted; otherwise re-reading it would count it twice.
            add(st["tokens"], previous.get("tokens", {}), -1)
            add(st["activity"], previous.get("activity", {}), -1)
        add(st["tokens"], fresh["tokens"])
        add(st["activity"], fresh["activity"])
        add(contribution["tokens"], fresh["tokens"])
        add(contribution["activity"], fresh["activity"])
        if new_offset > offset or previous is None:
            files_read += 1
        bytes_read += new_offset - offset
        st["files"][path] = {"ino": info.st_ino, "mtime": info.st_mtime, "size": info.st_size, "offset": new_offset,
                             "tokens": contribution["tokens"], "activity": contribution["activity"]}

    # Deleted files (Claude Code cleans up old transcripts): the file is forgotten, its history is not.
    for path in list(st["files"]):
        if path not in seen:
            del st["files"][path]

    data = build_output(st, today or date.today(), clock)
    write_atomic(output, data)        # output first: if anything fails afterwards, the old state is still
    write_atomic(state_path, st)      # consistent and the next run re-reads the same bytes
    return {
        "seconds": round(time.monotonic() - started, 2),
        "files": len(seen),
        "files_read": files_read,
        "bytes_read": bytes_read,
        "from_scratch": from_scratch,
        "days": len(data["dailyModelTokens"]),
    }


def default_state_path(output):
    base, ext = os.path.splitext(output)
    return f"{base}-state{ext or '.json'}"


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--claude-dir", default=os.path.join("~", ".claude"),
                   help="Claude Code data folder; the other paths default to locations inside it (default: ~/.claude)")
    p.add_argument("--projects-dir", help="folder with the *.jsonl transcripts (default: <claude-dir>/projects)")
    p.add_argument("--output", help="JSON file to write (default: <claude-dir>/usage-widget.json)")
    p.add_argument("--state", help="incremental state file (default: next to --output, '<name>-state.json')")
    p.add_argument("--full", action="store_true", help="ignore the saved state and recompute everything")
    a = p.parse_args(argv)
    claude_dir = os.path.expanduser(a.claude_dir)
    projects = os.path.expanduser(a.projects_dir) if a.projects_dir else os.path.join(claude_dir, "projects")
    output = os.path.expanduser(a.output) if a.output else os.path.join(claude_dir, "usage-widget.json")
    state = os.path.expanduser(a.state) if a.state else default_state_path(output)
    r = update(projects, output, state, full=a.full)
    print(f"{datetime.now().isoformat(timespec='seconds')} usage-widget: {r['files_read']}/{r['files']} files, "
          f"{r['bytes_read'] / 1e6:.1f} MB read, {r['days']} days, {r['seconds']} s"
          + (" (from scratch)" if r["from_scratch"] else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
