"""Tests for tools/update_usage.py using synthetic .jsonl transcripts.

Run:  /usr/bin/python3 -I -m unittest discover -s tools -p 'test_*.py' -v
"""
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from datetime import date, timedelta, timezone

import update_usage as uu

# Fixed UTC-6 with no daylight saving: keeps the local-day boundaries deterministic.
UTC6 = timezone(timedelta(hours=-6))
SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "update_usage.py")


def assistant_line(mid, rid, ts, model="claude-opus-5-5", i=0, o=0, cc=0, cr=0, uuid=None, session="s1", web=0):
    usage = {"input_tokens": i, "output_tokens": o, "cache_creation_input_tokens": cc, "cache_read_input_tokens": cr}
    if web:
        usage["server_tool_use"] = {"web_search_requests": web, "web_fetch_requests": 0}
    msg = {"model": model, "role": "assistant", "type": "message", "content": [{"type": "text", "text": "hello"}], "usage": usage}
    if mid is not None:
        msg["id"] = mid
    line = {"parentUuid": None, "isSidechain": False, "type": "assistant", "message": msg,
            "uuid": uuid or f"u-{mid}-{rid}-{o}", "timestamp": ts, "sessionId": session}
    if rid is not None:
        line["requestId"] = rid
    return json.dumps(line, separators=(",", ":"))


def user_line(ts, session="s1", text="hello"):
    return json.dumps({"parentUuid": None, "isSidechain": False, "type": "user",
                       "message": {"role": "user", "content": text}, "uuid": "uu-" + ts,
                       "timestamp": ts, "sessionId": session}, separators=(",", ":"))


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.claude = os.path.join(self.tmp.name, ".claude")
        self.projects = os.path.join(self.claude, "projects")
        os.makedirs(os.path.join(self.projects, "-home-x-project"))
        self.output = os.path.join(self.claude, "usage-widget.json")
        self.state = os.path.join(self.claude, "usage-widget-state.json")

    def tearDown(self):
        self.tmp.cleanup()

    def path(self, name):
        return os.path.join(self.projects, "-home-x-project", name)

    def write(self, name, lines, mode="w", end="\n"):
        p = self.path(name)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, mode) as f:
            f.write("\n".join(lines) + end)
        return p

    def run_update(self, today=date(2026, 11, 3)):
        r = uu.update(self.projects, self.output, self.state, tz=UTC6, today=today)
        with open(self.output) as f:
            return r, json.load(f)

    @staticmethod
    def day(output, day):
        for d in output["dailyModelTokens"]:
            if d["date"] == day:
                return d["tokensByModel"]
        return {}


class CountsLikeStats(Base):
    """Same rule as /stats (stats-cache.json): every line with usage counts, nothing is de-duplicated."""

    def test_every_line_of_the_same_message_counts(self):
        # Claude Code writes one line per content block and repeats the usage; /stats sums them all.
        self.write("s1.jsonl", [
            assistant_line("m1", "r1", "2026-10-20T15:00:00.000Z", i=2, o=8, cc=100, cr=1000),
            assistant_line("m1", "r1", "2026-10-20T15:00:01.000Z", i=2, o=8, cc=100, cr=1000),
            assistant_line("m1", "r1", "2026-10-20T15:00:02.000Z", i=2, o=592, cc=100, cr=1000),
        ])
        _, s = self.run_update()
        u = s["modelUsage"]["claude-opus-5-5"]
        self.assertEqual((u["inputTokens"], u["outputTokens"], u["cacheCreationInputTokens"], u["cacheReadInputTokens"]),
                         (6, 608, 300, 3000))
        self.assertEqual(self.day(s, "2026-10-20"), {"claude-opus-5-5": 6 + 608 + 300 + 3000})

    def test_copy_in_another_file_also_counts(self):
        # Forking a session copies its history into another file; /stats counts both copies.
        a = assistant_line("m1", "r1", "2026-10-20T15:00:00.000Z", o=50, cr=500)
        self.write("s1.jsonl", [a])
        self.write("s2.jsonl", [a, assistant_line("m2", "r2", "2026-10-20T16:00:00.000Z", o=1)])
        _, s = self.run_update()
        self.assertEqual(self.day(s, "2026-10-20")["claude-opus-5-5"], 550 * 2 + 1)

    def test_synthetic_and_broken_lines_are_ignored(self):
        self.write("s1.jsonl", [
            assistant_line("m1", "r1", "2026-10-20T15:00:00.000Z", model="<synthetic>", o=999),
            "{this is not json",
            json.dumps({"type": "assistant", "message": "text"}),
            assistant_line("m2", "r2", "2026-10-20T15:00:00.000Z", o=5),
        ])
        _, s = self.run_update()
        self.assertEqual(set(s["modelUsage"]), {"claude-opus-5-5"})
        self.assertEqual(s["modelUsage"]["claude-opus-5-5"]["outputTokens"], 5)

    def test_replaced_file_is_reread_without_double_counting(self):
        no_id = assistant_line(None, None, "2026-10-20T15:00:00.000Z", o=7, uuid="abc")
        p = self.write("s1.jsonl", [no_id])
        self.run_update()
        # Replacing the file (new inode) forces a re-read from the start.
        new = p + ".new"
        with open(new, "w") as f:
            f.write(no_id + "\n" + assistant_line("m2", "r2", "2026-10-20T15:00:00.000Z", o=1) + "\n")
        os.replace(new, p)
        r, s = self.run_update()
        self.assertEqual(r["files_read"], 1)
        self.assertEqual(s["modelUsage"]["claude-opus-5-5"]["outputTokens"], 8)


class DaysAndModels(Base):
    def test_groups_by_local_day_and_model(self):
        self.write("s1.jsonl", [
            # 03:00 UTC on the 21st = 21:00 on the 20th at UTC-6.
            assistant_line("m1", "r1", "2026-10-21T03:00:00.000Z", model="claude-opus-5-5", o=10),
            assistant_line("m2", "r2", "2026-10-21T07:00:00.000Z", model="claude-sonnet-5-5", o=20),
            assistant_line("m3", "r3", "2026-10-21T18:00:00.000Z", model="claude-opus-5-5", i=1, o=30),
        ])
        _, s = self.run_update()
        self.assertEqual(self.day(s, "2026-10-20"), {"claude-opus-5-5": 10})
        self.assertEqual(self.day(s, "2026-10-21"), {"claude-sonnet-5-5": 20, "claude-opus-5-5": 31})
        self.assertEqual([d["date"] for d in s["dailyModelTokens"]], ["2026-10-20", "2026-10-21"], "sorted")
        self.assertEqual(s["modelUsage"]["claude-sonnet-5-5"]["outputTokens"], 20)
        self.assertEqual(s["modelUsage"]["claude-opus-5-5"]["inputTokens"], 1)

    def test_schema_matches_stats_cache(self):
        self.write("s1.jsonl", [
            user_line("2026-10-20T14:59:00.000Z"),
            assistant_line("m1", "r1", "2026-10-20T15:00:00.000Z", o=1, web=2),
        ])
        self.write("s2.jsonl", [user_line("2026-10-21T20:00:00.000Z", session="s2")])
        # A subagent shares its parent's sessionId: it is not another session.
        self.write("s1/subagents/agent-1.jsonl", [assistant_line("m9", "r9", "2026-10-20T15:30:00.000Z", o=4)])
        _, s = self.run_update(today=date(2026, 11, 3))
        for key in ("version", "lastComputedDate", "dailyActivity", "dailyModelTokens", "modelUsage",
                    "totalSessions", "totalMessages", "firstSessionDate", "hourCounts"):
            self.assertIn(key, s)
        self.assertEqual(s["lastComputedDate"], "2026-11-03")
        self.assertEqual(s["totalSessions"], 2)
        self.assertEqual(s["firstSessionDate"], "2026-10-20T14:59:00.000Z")
        self.assertEqual(s["hourCounts"], {"8": 1, "14": 1}, "local start hour of each session")
        self.assertEqual(s["totalMessages"], 4, "2 user lines + 2 assistant lines")
        self.assertEqual(s["modelUsage"]["claude-opus-5-5"]["webSearchRequests"], 2)
        act = {d["date"]: d for d in s["dailyActivity"]}
        self.assertEqual(act["2026-10-20"]["sessionCount"], 1)
        self.assertEqual(act["2026-10-20"]["messageCount"], 3)
        for u in s["modelUsage"].values():
            for k in ("inputTokens", "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens"):
                self.assertIsInstance(u[k], int)

    def test_breakdown_by_day_model_and_type(self):
        """dailyModelUsage (optional extra field): the app window uses it for the per-range table."""
        self.write("s1.jsonl", [
            assistant_line("m1", "r1", "2026-10-20T15:00:00.000Z", model="claude-opus-5-5", i=1, o=2, cc=3, cr=4),
            assistant_line("m2", "r2", "2026-10-21T15:00:00.000Z", model="claude-opus-5-5", i=10, o=20, cc=30, cr=40),
            assistant_line("m3", "r3", "2026-10-21T16:00:00.000Z", model="claude-sonnet-5-5", o=7),
        ])
        _, s = self.run_update()
        usage = {d["date"]: d["usageByModel"] for d in s["dailyModelUsage"]}
        self.assertEqual(sorted(usage), ["2026-10-20", "2026-10-21"])
        self.assertEqual(usage["2026-10-21"]["claude-opus-5-5"],
                         {"inputTokens": 10, "outputTokens": 20, "cacheReadInputTokens": 40, "cacheCreationInputTokens": 30})
        self.assertEqual(usage["2026-10-21"]["claude-sonnet-5-5"]["outputTokens"], 7)
        # Consistent with dailyModelTokens and modelUsage.
        for d in s["dailyModelUsage"]:
            for model, u in d["usageByModel"].items():
                self.assertEqual(sum(u.values()), self.day(s, d["date"])[model])
        self.assertEqual(s["modelUsage"]["claude-opus-5-5"]["cacheReadInputTokens"], 44)


class Incremental(Base):
    def test_second_run_reads_only_new_bytes_and_matches_a_full_run(self):
        p = self.write("s1.jsonl", [
            assistant_line("m1", "r1", "2026-10-20T15:00:00.000Z", o=8, cr=100),
            assistant_line("m2", "r2", "2026-10-20T15:01:00.000Z", o=3),
        ])
        r1, _ = self.run_update()
        size1 = os.path.getsize(p)
        self.assertEqual(r1["bytes_read"], size1)

        new = "\n".join([
            assistant_line("m1", "r1", "2026-10-20T15:00:05.000Z", o=600, cr=100),  # another block of the same message
            assistant_line("m3", "r3", "2026-10-22T15:00:00.000Z", model="claude-sonnet-5-5", o=40),
        ]) + "\n"
        with open(p, "a") as f:
            f.write(new)
        r2, inc = self.run_update()
        self.assertEqual(r2["bytes_read"], len(new.encode()), "reads only what was appended")
        self.assertEqual(self.day(inc, "2026-10-20"), {"claude-opus-5-5": 108 + 3 + 700})
        self.assertEqual(r2["files_read"], 1)

        r3, _ = self.run_update()
        self.assertEqual((r3["bytes_read"], r3["files_read"]), (0, 0), "nothing changed, nothing read")

        os.remove(self.state)
        _, full = self.run_update()
        self.assertEqual(inc["modelUsage"], full["modelUsage"])
        self.assertEqual(inc["dailyModelTokens"], full["dailyModelTokens"])

    def test_half_written_line_waits_until_complete(self):
        p = self.write("s1.jsonl", [assistant_line("m1", "r1", "2026-10-20T15:00:00.000Z", o=5)])
        rest = assistant_line("m2", "r2", "2026-10-20T15:00:00.000Z", o=7)
        with open(p, "a") as f:
            f.write(rest[:20])
        _, s = self.run_update()
        self.assertEqual(s["modelUsage"]["claude-opus-5-5"]["outputTokens"], 5)
        with open(p, "a") as f:
            f.write(rest[20:] + "\n")
        _, s = self.run_update()
        self.assertEqual(s["modelUsage"]["claude-opus-5-5"]["outputTokens"], 12)

    def test_file_rewritten_shorter_counts_what_it_has_now(self):
        a = assistant_line("m1", "r1", "2026-10-20T15:00:00.000Z", o=5)
        self.write("s1.jsonl", [a, assistant_line("m2", "r2", "2026-10-20T15:00:00.000Z", o=7)])
        self.run_update()
        self.write("s1.jsonl", [a])  # shorter than the saved offset
        r, s = self.run_update()
        self.assertEqual(r["files_read"], 1)
        self.assertEqual(s["modelUsage"]["claude-opus-5-5"]["outputTokens"], 5, "subtracts what it contributed before")

    def test_deleted_file_keeps_its_history(self):
        p = self.write("s1.jsonl", [assistant_line("m1", "r1", "2026-10-20T15:00:00.000Z", o=5)])
        self.run_update()
        os.remove(p)
        _, s = self.run_update()
        self.assertEqual(s["modelUsage"]["claude-opus-5-5"]["outputTokens"], 5)

    def test_corrupt_state_rebuilds_from_scratch(self):
        self.write("s1.jsonl", [assistant_line("m1", "r1", "2026-10-20T15:00:00.000Z", o=5)])
        self.run_update()
        with open(self.state, "w") as f:
            f.write("{broken")
        _, s = self.run_update()
        self.assertEqual(s["modelUsage"]["claude-opus-5-5"]["outputTokens"], 5)


class Writing(Base):
    def test_permissions_0600_and_no_leftover_temp_files(self):
        self.write("s1.jsonl", [assistant_line("m1", "r1", "2026-10-20T15:00:00.000Z", o=5)])
        self.run_update()
        for p in (self.output, self.state):
            self.assertEqual(stat.S_IMODE(os.stat(p).st_mode), 0o600, p)
        leftovers = [n for n in os.listdir(self.claude) if n.endswith(".tmp")]
        self.assertEqual(leftovers, [])

    def test_no_transcripts_writes_a_valid_empty_file(self):
        _, s = self.run_update()
        self.assertEqual(s["dailyModelTokens"], [])
        self.assertEqual(s["modelUsage"], {})
        self.assertEqual(s["totalSessions"], 0)
        self.assertNotIn("firstSessionDate", s)

    def test_creates_the_output_folder_when_missing(self):
        out = os.path.join(self.tmp.name, "does", "not", "exist", "usage.json")
        uu.update(self.projects, out, os.path.join(self.tmp.name, "does", "state.json"), tz=UTC6, today=date(2026, 11, 3))
        self.assertTrue(os.path.isfile(out))


class CommandLine(Base):
    """--projects-dir and --output make the script usable on any OS and any folder layout."""

    def setUp(self):
        super().setUp()
        self.write("s1.jsonl", [
            user_line("2026-10-20T14:59:00.000Z"),
            assistant_line("m1", "r1", "2026-10-20T15:00:00.000Z", o=5, cr=95),
        ])

    def test_custom_projects_dir_and_output(self):
        other = os.path.join(self.tmp.name, "elsewhere")
        out = os.path.join(other, "result.json")
        code = uu.main(["--projects-dir", self.projects, "--output", out])
        self.assertEqual(code, 0)
        with open(out) as f:
            data = json.load(f)
        self.assertEqual(data["modelUsage"]["claude-opus-5-5"]["outputTokens"], 5)
        # The state file lives next to the output and nothing is written to ~/.claude.
        self.assertTrue(os.path.isfile(os.path.join(other, "result-state.json")))
        self.assertFalse(os.path.exists(self.output), "default output untouched")

    def test_explicit_state_path(self):
        out = os.path.join(self.tmp.name, "o.json")
        st = os.path.join(self.tmp.name, "custom-state.json")
        self.assertEqual(uu.main(["--projects-dir", self.projects, "--output", out, "--state", st]), 0)
        self.assertTrue(os.path.isfile(st))

    def test_defaults_come_from_home(self):
        home = os.path.join(self.tmp.name, "home")
        os.makedirs(os.path.join(home, ".claude"))
        os.symlink(self.projects, os.path.join(home, ".claude", "projects"))
        env = {**os.environ, "HOME": home, "USERPROFILE": home}
        r = subprocess.run([sys.executable, "-I", SCRIPT], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(os.path.join(home, ".claude", "usage-widget.json")) as f:
            self.assertEqual(json.load(f)["modelUsage"]["claude-opus-5-5"]["outputTokens"], 5)
        self.assertIn("usage-widget:", r.stdout)

    def test_missing_projects_dir_is_not_an_error(self):
        out = os.path.join(self.tmp.name, "empty.json")
        self.assertEqual(uu.main(["--projects-dir", os.path.join(self.tmp.name, "nope"), "--output", out]), 0)
        with open(out) as f:
            self.assertEqual(json.load(f)["dailyModelTokens"], [])

    def test_full_flag_ignores_saved_state(self):
        out = os.path.join(self.tmp.name, "o.json")
        args = ["--projects-dir", self.projects, "--output", out]
        uu.main(args)
        self.assertEqual(uu.main(args + ["--full"]), 0)


class NoPersonalPaths(unittest.TestCase):
    """The installer and its template must work for any user: no absolute home paths baked in."""

    TOOLS = os.path.dirname(os.path.abspath(__file__))

    def read(self, name):
        with open(os.path.join(self.TOOLS, name), encoding="utf-8") as f:
            return f.read()

    def test_template_uses_placeholders_not_absolute_paths(self):
        text = self.read("updater.plist.template")
        self.assertIn("__HOME__", text)
        self.assertIn("__LABEL__", text)
        self.assertNotIn("/Users/", text)

    def test_installer_and_script_have_no_absolute_home_path(self):
        for name in ("install_updater.sh", "update_usage.py", "generate_project.py"):
            self.assertNotIn("/Users/", self.read(name), name)

    def test_default_bundle_prefix_is_generic(self):
        text = self.read("install_updater.sh")
        self.assertIn("com.example.ClaudeUsageWidget", text)


if __name__ == "__main__":
    unittest.main()
