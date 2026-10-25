#!/usr/bin/env python3
"""Counts compatibility-report issues into engine/compat-reports.json (run by .github/workflows/compat-reports.yml).

The issue body is untrusted text from a GitHub issue form: only the known fields are read, each is checked against
what it may contain, and nothing from it is ever executed or put on a command line.

Against spam: each GitHub account has one vote per game (a new report replaces its earlier one), accounts younger
than MIN_ACCOUNT_DAYS and more than MAX_PER_DAY reports a day aren't counted, and a report labelled "spam" by a
maintainer is taken out again.

usage: compat-report.py add <event.json> <compat-reports.json> <reporter account created_at (ISO 8601)>
       compat-report.py remove <event.json> <compat-reports.json>
exit status: 0 counted (or removed), 3 not counted (invalid or refused); anything else is a failure.

Running it again for the same issue changes nothing, so the workflow can retry on a newer copy of the file."""
import json, re, sys
from collections import Counter
from datetime import datetime, timezone

RESULTS = {"Works great": "great", "Playable with issues": "playable",
           "Starts but isn't playable": "unplayable", "Doesn't start": "broken"}
FIELDS = {"Game id": "game_id", "Game": "game_title", "How does it run?": "result", "Graphics backend": "backend",
          "Engine version": "engine", "Mac": "mac", "macOS": "macos", "UniveGame version": "app_version"}
MIN_ACCOUNT_DAYS = 14
MAX_PER_DAY = 10
RECENT = 10
NOT_COUNTED = 3


def parse(body):
    out, current = {}, None
    for line in (body or "").splitlines():
        m = re.match(r"^### (.+?)\s*$", line)
        if m:
            current = FIELDS.get(m.group(1))
            continue
        if current and line.strip() and line.strip() != "_No response_" and current not in out:
            out[current] = line.strip()[:120]
    return out


def load(db_path):
    try:
        return json.load(open(db_path))
    except FileNotFoundError:
        return {"games": {}}


def save(db, db_path):
    with open(db_path, "w") as f:
        json.dump(db, f, indent=2, sort_keys=True, ensure_ascii=False)
        f.write("\n")


def recount(entry):
    """`counts` and `recent` (what UniveGame reads) from the per-account votes."""
    votes = sorted(entry.get("votes", {}).values(), key=lambda v: (v["date"], v["issue"]), reverse=True)
    entry["counts"] = dict(Counter(v["result"] for v in votes))
    entry["recent"] = [{k: v for k, v in vote.items()} for vote in votes[:RECENT]]


def add(event, db_path, created_at):
    issue = event["issue"]
    reporter = str(issue["user"]["id"])
    now = datetime.now(timezone.utc)
    try:
        created = datetime.fromisoformat(created_at.replace("Z", "+00:00"))
    except ValueError:
        print("unknown account age"); return NOT_COUNTED
    if (now - created).days < MIN_ACCOUNT_DAYS:
        print("account too new"); return NOT_COUNTED

    fields = parse(issue.get("body"))
    game_id = fields.get("game_id", "")
    if not re.fullmatch(r"(steam|epic|gog|ubisoft|ea|custom):[A-Za-z0-9._-]{1,100}", game_id):
        print("no valid game id"); return NOT_COUNTED
    result = RESULTS.get(fields.get("result", ""))
    if not result:
        print("no valid result"); return NOT_COUNTED

    def clean(key, pattern=r"[\w .,()+-]{0,60}"):
        value = fields.get(key, "")
        return value if re.fullmatch(pattern, value) else ""

    db = load(db_path)
    today = now.strftime("%Y-%m-%d")
    number = issue["number"]
    votes_today = sum(1 for e in db["games"].values() for r, v in e.get("votes", {}).items()
                      if r == reporter and v["date"] == today and v["issue"] != number)
    if votes_today >= MAX_PER_DAY:
        print("too many reports today"); return NOT_COUNTED

    entry = db["games"].setdefault(game_id, {"title": "", "counts": {}, "recent": [], "votes": {}})
    entry.setdefault("votes", {})
    entry["title"] = clean("game_title", r"[^\n<>]{1,100}") or entry["title"]
    entry["votes"][reporter] = {"issue": number, "result": result, "backend": clean("backend"), "engine": clean("engine"),
                                "mac": clean("mac"), "macos": clean("macos"), "app": clean("app_version"), "date": today}
    recount(entry)
    save(db, db_path)
    print(f"{game_id}: {result}")
    return 0


def remove(event, db_path):
    number = event["issue"]["number"]
    db = load(db_path)
    removed = False
    for entry in db["games"].values():
        votes = entry.get("votes", {})
        for reporter in [r for r, v in votes.items() if v["issue"] == number]:
            del votes[reporter]
            removed = True
        recount(entry)
    db["games"] = {k: e for k, e in db["games"].items() if e.get("votes")}
    save(db, db_path)
    print("removed" if removed else "not counted")
    return 0


if __name__ == "__main__":
    action, event_path, db_path = sys.argv[1:4]
    event = json.load(open(event_path))
    sys.exit(add(event, db_path, sys.argv[4]) if action == "add" else remove(event, db_path))
