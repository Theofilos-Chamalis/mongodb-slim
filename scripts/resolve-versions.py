#!/usr/bin/env python3
"""
Resolve the exact MongoDB Community + mongosh artifacts mongodb-slim should build.

By default it tracks the newest supported LTS major lines automatically: it keeps
the newest N major numbers (N defaults to 2), and a brand-new major is only
adopted once its x.0.0 GA release is at least 21 days old. That gives a rolling
window, for example 8.0 + 7.0 today, then 9.0 + 8.0 about three weeks after 9.0
ships, with 7.0 dropping out of the builds at that point. You can override the
set explicitly with --majors "8.0 7.0" (used for manual builds).

For each tracked major it finds the latest production, non-release-candidate
version, picks a glibc + OpenSSL-3 "targeted" tarball that exists for BOTH
x86_64 and aarch64, and records the official sha256 for each arch. It also
resolves the latest mongosh (the OpenSSL-3 Linux build) and its checksums.

Output is a single JSON document on stdout (see --images-only for just the list).

Usage:
    resolve-versions.py [--majors "8.0 7.0"] [--keep-majors 2]
                        [--new-major-min-age-days 21] [--full-json PATH]
                        [--images-only] [--today YYYY-MM-DD]
"""
import argparse
import datetime
import json
import os
import re
import sys
import urllib.request

FULL_JSON_URL = "https://downloads.mongodb.org/full.json"
MONGOSH_API = "https://api.github.com/repos/mongodb-js/mongosh/releases/latest"

# All of these ship glibc binaries linked against OpenSSL 3, which matches
# Wolfi. First target (in order) that has both x86_64 and aarch64 wins.
TARGET_PRIORITY = ["ubuntu2404", "ubuntu2204", "rhel93", "rhel90", "debian12"]


def _get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "mongodb-slim-resolver"})
    token = os.environ.get("GITHUB_TOKEN")
    if token and "api.github.com" in url:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def load_full_json(path):
    data = open(path, "rb").read() if path else _get(FULL_JSON_URL)
    return json.loads(data)


def ver_tuple(v):
    return tuple(int(x) for x in v.split("."))


def parse_feed_date(s):
    # MongoDB's feed uses MM/DD/YYYY
    return datetime.datetime.strptime(s, "%m/%d/%Y").date()


def latest_for_major(feed, major):
    """major like '8.0' -> highest production, non-rc x.y.z with that prefix."""
    prefix = major + "."
    cands = [
        e["version"]
        for e in feed["versions"]
        if e.get("production_release") and not e.get("release_candidate")
        and e["version"].startswith(prefix)
    ]
    return max(cands, key=ver_tuple) if cands else None


def major_ga_date(feed, major_int):
    """GA date of {major}.0.0, else the earliest GA date in the {major}.0.x line."""
    dot0 = f"{major_int}.0.0"
    dates = []
    for e in feed["versions"]:
        v = e["version"]
        if not e.get("production_release") or e.get("release_candidate") or not e.get("date"):
            continue
        if not v.startswith(f"{major_int}.0."):
            continue
        try:
            d = parse_feed_date(e["date"])
        except ValueError:
            continue
        if v == dot0:
            return d
        dates.append(d)
    return min(dates) if dates else None


def auto_tracked_majors(feed, keep, min_age_days, today):
    """The newest `keep` LTS major lines, holding back a too-new newest major."""
    majors = set()
    for e in feed["versions"]:
        v = e["version"]
        if e.get("production_release") and not e.get("release_candidate") and re.match(r"^\d+\.0\.\d+$", v):
            majors.add(int(v.split(".")[0]))
    desc = sorted(majors, reverse=True)
    if not desc:
        return []
    newest = desc[0]
    ga = major_ga_date(feed, newest)
    if ga is not None and (today - ga).days < min_age_days:
        # Not adopted yet; keep tracking the previous lines until it matures.
        desc = desc[1:]
    return [f"{m}.0" for m in desc[:keep]]


def archives_for_version(feed, version):
    entry = next((e for e in feed["versions"] if e["version"] == version), None)
    if not entry:
        return {}
    # target -> {arch -> sha256} for community ("targeted") builds
    out = {}
    for d in entry.get("downloads", []):
        if d.get("edition") != "targeted":
            continue
        arch = d.get("arch")
        if arch not in ("x86_64", "aarch64"):
            continue
        sha = d.get("archive", {}).get("sha256")
        if not sha:
            continue
        out.setdefault(d.get("target"), {})[arch] = sha
    return out


def pick_target(archives):
    for t in TARGET_PRIORITY:
        a = archives.get(t, {})
        if "x86_64" in a and "aarch64" in a:
            return t, a["x86_64"], a["aarch64"]
    return None, None, None


def resolve_mongosh():
    rel = json.loads(_get(MONGOSH_API))
    version = rel["tag_name"].lstrip("v")
    shas = {}
    for asset in rel.get("assets", []):
        name = asset["name"]
        digest = (asset.get("digest") or "").removeprefix("sha256:")
        if name == f"mongosh-{version}-linux-x64-openssl3.tgz":
            shas["amd64"] = digest
        elif name == f"mongosh-{version}-linux-arm64-openssl3.tgz":
            shas["arm64"] = digest
    if "amd64" not in shas or "arm64" not in shas:
        raise SystemExit(f"could not resolve mongosh {version} openssl3 checksums")
    return version, shas["amd64"], shas["arm64"]


def compute_tags(images):
    """Assign version, X.Y, X and 'latest' tags across the resolved set."""
    all_versions = [ver_tuple(i["version"]) for i in images]
    global_max = max(all_versions)
    # highest version per leading component (holds the "8"/"7"/"9" tag)
    top_by_first = {}
    for i in images:
        first = i["version"].split(".")[0]
        vt = ver_tuple(i["version"])
        if first not in top_by_first or vt > top_by_first[first]:
            top_by_first[first] = vt
    for i in images:
        vt = ver_tuple(i["version"])
        first = i["version"].split(".")[0]
        tags = [i["version"], i["major"]]
        if vt == top_by_first[first]:
            tags.append(first)
        if vt == global_max:
            tags.append("latest")
        i["tags"] = list(dict.fromkeys(tags))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--majors", default=os.environ.get("TRACKED_MAJORS", ""),
                    help="explicit space-separated majors; blank means auto-select")
    ap.add_argument("--keep-majors", type=int, default=int(os.environ.get("KEEP_MAJORS", "2")))
    ap.add_argument("--new-major-min-age-days", type=int,
                    default=int(os.environ.get("NEW_MAJOR_MIN_AGE_DAYS", "21")))
    ap.add_argument("--full-json", default=None, help="local full.json (else download)")
    ap.add_argument("--images-only", action="store_true", help="print only the images array")
    ap.add_argument("--today", default=None, help="override today (YYYY-MM-DD), for testing")
    args = ap.parse_args()

    feed = load_full_json(args.full_json)

    if args.majors.strip():
        majors = args.majors.split()
    else:
        today = datetime.date.fromisoformat(args.today) if args.today else datetime.date.today()
        majors = auto_tracked_majors(feed, args.keep_majors, args.new_major_min_age_days, today)
        if not majors:
            raise SystemExit("could not determine tracked majors automatically")
    print(f"tracked majors: {' '.join(majors)}", file=sys.stderr)

    msh_ver, msh_amd64, msh_arm64 = resolve_mongosh()

    images = []
    for major in majors:
        version = latest_for_major(feed, major)
        if not version:
            print(f"warning: no production release found for major {major}", file=sys.stderr)
            continue
        target, sha_amd64, sha_arm64 = pick_target(archives_for_version(feed, version))
        if not target:
            print(f"warning: no dual-arch OpenSSL-3 target for {version}", file=sys.stderr)
            continue
        images.append({
            "version": version,
            "major": major,
            "target": target,
            "sha256_amd64": sha_amd64,
            "sha256_arm64": sha_arm64,
            "mongosh_version": msh_ver,
            "mongosh_sha256_amd64": msh_amd64,
            "mongosh_sha256_arm64": msh_arm64,
        })

    if not images:
        raise SystemExit("resolved no images")

    compute_tags(images)

    if args.images_only:
        print(json.dumps(images))
    else:
        print(json.dumps({
            "mongosh_version": msh_ver,
            "mongosh_sha256_amd64": msh_amd64,
            "mongosh_sha256_arm64": msh_arm64,
            "images": images,
        }, indent=2))


if __name__ == "__main__":
    main()
