#!/usr/bin/env python3
"""Adds one compatibility-report issue to engine/compat-reports.json (run by .github/workflows/compat-reports.yml).

The issue body is untrusted text from a GitHub issue form: only the known fields are read, each is checked against
what it may contain, and nothing from it is ever executed or put on a command line.
usage: compat-report.py <event.json> <compat-reports.json>"""
import json, re, sys
from datetime import datetime, timezone

RESULTS = {"Works great": "great", "Playable with issues": "playable",
           "Starts but isn't playable": "unplayable", "Doesn't start": "broken"}
FIELDS = {"Game id": "game_id", "Game": "game_title", "How does it run?": "result", "Graphics backend": "backend",
          "Engine version": "engine", "Mac": "mac", "macOS": "macos", "UniveGame version": "app_version"}

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

def main(event_path, db_path):
    event = json.load(open(event_path))
    issue = event["issue"]
    fields = parse(issue.get("body"))
    game_id = fields.get("game_id", "")
    if not re.fullmatch(r"(steam|epic|gog|ubisoft|ea|custom):[A-Za-z0-9._-]{1,100}", game_id):
        print("no valid game id"); return 1
    result = RESULTS.get(fields.get("result", ""))
    if not result:
        print("no valid result"); return 1
    def clean(key, pattern=r"[\w .,()+-]{0,60}"):
        value = fields.get(key, "")
        return value if re.fullmatch(pattern, value) else ""
    try:
        db = json.load(open(db_path))
    except FileNotFoundError:
        db = {"games": {}}
    entry = db["games"].setdefault(game_id, {"title": "", "counts": {}, "recent": []})
    entry["title"] = clean("game_title", r"[^\n<>]{1,100}") or entry["title"]
    number = issue["number"]
    if any(r.get("issue") == number for r in entry["recent"]):
        print("already counted"); return 0
    entry["counts"][result] = entry["counts"].get(result, 0) + 1
    entry["recent"].insert(0, {"issue": number, "result": result, "backend": clean("backend"), "engine": clean("engine"),
                               "mac": clean("mac"), "macos": clean("macos"), "app": clean("app_version"),
                               "date": datetime.now(timezone.utc).strftime("%Y-%m-%d")})
    entry["recent"] = entry["recent"][:10]
    with open(db_path, "w") as f:
        json.dump(db, f, indent=2, sort_keys=True, ensure_ascii=False)
        f.write("\n")
    print(f"{game_id}: {result}")
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
