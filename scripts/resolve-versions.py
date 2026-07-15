#!/usr/bin/env python3
"""
Resolve the exact MongoDB Community + mongosh artifacts mongodb-slim should build.

For each tracked major (e.g. 8.0, 7.0) it finds the latest production,
non-release-candidate version from MongoDB's release feed, then picks a
glibc + OpenSSL-3 "targeted" tarball that exists for BOTH x86_64 and aarch64,
and records the official sha256 for each arch. It also resolves the latest
mongosh (the OpenSSL-3 Linux build) and its checksums.

Output is a single JSON document on stdout, e.g.:

    {
      "mongosh_version": "2.9.2",
      "mongosh_sha256_amd64": "...",
      "mongosh_sha256_arm64": "...",
      "images": [
        {
          "version": "8.0.26", "major": "8.0", "target": "ubuntu2404",
          "sha256_amd64": "...", "sha256_arm64": "...",
          "mongosh_version": "2.9.2",
          "mongosh_sha256_amd64": "...", "mongosh_sha256_arm64": "...",
          "tags": ["8.0.26", "8.0", "8", "latest"]
        },
        ...
      ]
    }

Usage:
    resolve-versions.py [--majors "8.0 7.0"] [--full-json PATH] [--images-only]
"""
import argparse
import json
import os
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
    # highest version per leading component (the "8"/"7"/"6" tag holder)
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
        # de-dup, keep order
        i["tags"] = list(dict.fromkeys(tags))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--majors", default=os.environ.get("TRACKED_MAJORS", "8.0 7.0"))
    ap.add_argument("--full-json", default=None, help="local full.json (else download)")
    ap.add_argument("--images-only", action="store_true", help="print only the images array")
    args = ap.parse_args()

    feed = load_full_json(args.full_json)
    msh_ver, msh_amd64, msh_arm64 = resolve_mongosh()

    images = []
    for major in args.majors.split():
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
