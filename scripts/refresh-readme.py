#!/usr/bin/env python3
"""
Refresh the "current versions" block in README.md.

It rewrites the block between the <!-- current-versions:start --> and
<!-- current-versions:end --> markers, but only when there's a reason to: either
the tracked versions changed, or it has been at least --min-days since the last
refresh. That second condition is what keeps a commit landing roughly every
three weeks, which also keeps GitHub's scheduled workflows from being disabled
for inactivity (they only stay alive if there are commits).

When nothing is due, the file is left untouched, so the calling workflow simply
sees no diff and makes no commit.

Usage:
    refresh-readme.py [--readme README.md] [--min-days 18] [--images-file PATH]
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys

START = "<!-- current-versions:start -->"
END = "<!-- current-versions:end -->"
HERE = os.path.dirname(os.path.abspath(__file__))


def resolve_images(images_file):
    if images_file:
        return json.load(open(images_file))
    out = subprocess.check_output(
        [sys.executable, os.path.join(HERE, "resolve-versions.py"), "--images-only"]
    )
    return json.loads(out)


def render_block(images, mongosh, today):
    vers = [i["version"] for i in sorted(images, key=lambda i: tuple(int(x) for x in i["version"].split(".")), reverse=True)]
    ticked = [f"`{v}`" for v in vers]
    if len(ticked) > 1:
        joined = ", ".join(ticked[:-1]) + " and " + ticked[-1]
    else:
        joined = ticked[0]
    return (
        f"{START}\n"
        f"**Currently published:** MongoDB {joined}, with `mongosh {mongosh}`. "
        f"Last refreshed {today}.\n"
        f"{END}"
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--readme", default=os.path.join(os.path.dirname(HERE), "README.md"))
    ap.add_argument("--min-days", type=int, default=int(os.environ.get("REFRESH_MIN_DAYS", "18")))
    ap.add_argument("--images-file", default=None, help="precomputed images JSON (else resolve live)")
    ap.add_argument("--today", default=None, help="override today (YYYY-MM-DD), for testing")
    args = ap.parse_args()

    today = datetime.date.fromisoformat(args.today) if args.today else datetime.date.today()
    images = resolve_images(args.images_file)
    mongosh = images[0]["mongosh_version"] if images else "?"
    new_versions = {i["version"] for i in images}

    text = open(args.readme, encoding="utf-8").read()
    m = re.search(re.escape(START) + r"(.*?)" + re.escape(END), text, re.DOTALL)

    due = True
    reason = "markers missing, inserting"
    if m:
        old = m.group(1)
        old_versions = set(re.findall(r"`(\d+\.\d+\.\d+)`", old))
        dm = re.search(r"Last refreshed (\d{4}-\d{2}-\d{2})", old)
        old_date = datetime.date.fromisoformat(dm.group(1)) if dm else None
        if old_versions != new_versions:
            reason = f"versions changed {sorted(old_versions)} -> {sorted(new_versions)}"
        elif old_date is None:
            reason = "no previous date found"
        elif (today - old_date).days >= args.min_days:
            reason = f"{(today - old_date).days} days since last refresh (>= {args.min_days})"
        else:
            due = False
            reason = f"only {(today - old_date).days} days since last refresh (< {args.min_days})"

    if not due:
        print(f"refresh-readme: nothing to do ({reason})")
        return

    block = render_block(images, mongosh, today.isoformat())
    if m:
        text = text[:m.start()] + block + text[m.end():]
    else:
        # Fall back to appending if the markers aren't present yet.
        text = text.rstrip() + "\n\n" + block + "\n"
    open(args.readme, "w", encoding="utf-8").write(text)
    print(f"refresh-readme: updated ({reason})")


if __name__ == "__main__":
    main()
