"""Make and check gem5-resources JSON entries for resources you built.

Subcommands (run `resjson.py <cmd> --help` for the options):

  query     Which IDs already exist in the gem5 resources database, and
            their versions.
  template  Print an existing entry from the database, to copy the format of.
  new       Make entries for built files from a template entry. Writes the
            upload JSON (dist.gem5.org URLs) and a manifest of local files.
  local     Make a copy of a JSON with file:// URLs from its manifest, for
            testing with GEM5_RESOURCE_JSON_APPEND.
  check     Check a JSON (and its manifest) before testing or uploading.

md5sums are computed with gem5's own src/python/gem5/resources/md5_utils.py
(the same code gem5 checks downloads with), from the gem5 checkout given by
--gem5, the task folder's gem5/, or GEM5_CLONE in ~/.config/gem5-skills/config.

This script only reads from the public resources API. It never uploads or
writes to the database.
"""

import argparse
import copy
import fcntl
import gzip
import importlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://api.gem5.org/api/resources"
DIST = "https://dist.gem5.org/dist/"
BATCH = 20  # more IDs per request than this gives HTTP 414
HERE = Path(__file__).resolve().parent


# ---------------------------------------------------------------- settings


def settings():
    """KEY=VALUE lines of ~/.config/gem5-skills/config, with $VARS expanded."""
    path = os.environ.get(
        "GEM5_SKILLS_CONFIG", os.path.expanduser("~/.config/gem5-skills/config")
    )
    out = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.split("#", 1)[0].strip()
                if "=" in line:
                    k, v = line.split("=", 1)
                    out[k.strip()] = os.path.expandvars(v.strip().strip("\"'"))
    except OSError:
        pass
    return out


def task_dir():
    d = Path.cwd()
    while d != d.parent:
        if (d / "notes.md").is_file():
            return d
        d = d.parent
    return None


def gem5_dir(arg):
    if arg:
        return Path(arg).resolve()
    t = task_dir()
    if t and (t / "gem5").is_dir():
        return (t / "gem5").resolve()
    clone = settings().get("GEM5_CLONE")
    if clone:
        return Path(clone)
    sys.exit("No gem5 checkout: pass --gem5 DIR.")


def md5_utils(gem5):
    src = gem5 / "src/python"
    if not (src / "gem5/resources/md5_utils.py").is_file():
        sys.exit(f"{src}/gem5/resources/md5_utils.py not found; pass --gem5 DIR.")
    sys.path.insert(0, str(src))
    return importlib.import_module("gem5.resources.md5_utils")


# --------------------------------------------------------------------- API


def api_find(ids, version=None):
    """All entries for these IDs (every version unless `version` is given)."""
    found = []
    ids = list(dict.fromkeys(ids))
    for i in range(0, len(ids), BATCH):
        q = []
        for rid in ids[i : i + BATCH]:
            q += [("id", rid), ("resource_version", version or "None")]
        url = f"{API}/find-resources-in-batch?" + urllib.parse.urlencode(q)
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                found += json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 404:  # none of this batch exists
                continue
            raise
    return found


def vkey(v):
    return tuple(int(x) if x.isdigit() else x for x in str(v).split("."))


def by_id(entries):
    out = {}
    for e in entries:
        out.setdefault(e["id"], []).append(e)
    for v in out.values():
        v.sort(key=lambda e: vkey(e["resource_version"]))
    return out


def read_ids(a):
    ids = list(a.ids or [])
    if a.ids_file:
        with open(a.ids_file) as f:
            ids += [l.split()[0] for l in f if l.strip() and not l.startswith("#")]
    if not ids:
        sys.exit("No IDs: give them as arguments or with --ids-file.")
    return ids


# ---------------------------------------------------------- JSON file I/O


def load(path, default=None):
    if default is not None and not os.path.exists(path):
        return default
    with open(path) as f:
        return json.load(f)


def save(path, data):
    tmp = f"{path}.tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=4, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)


def manifest_path(json_path):
    p = Path(json_path)
    return str(p.with_name(p.stem + ".manifest.json"))


def merge(old, new):
    """Replace entries of `old` with the same (id, version) as one in `new`."""
    keys = {(e["id"], e["resource_version"]) for e in new}
    return [e for e in old if (e["id"], e["resource_version"]) not in keys] + new


# ------------------------------------------------------------- commands


def cmd_query(a):
    ids = read_ids(a)
    found = by_id(api_find(ids))
    new = [i for i in ids if i not in found]
    for rid in ids:
        if rid in found:
            vs = ", ".join(e["resource_version"] for e in found[rid])
            print(f"exists  {rid}  versions: {vs}  ({found[rid][-1]['category']})")
        else:
            print(f"new     {rid}")
    print(f"\n{len(ids)} IDs: {len(new)} new, {len(ids) - len(new)} already exist.")
    if a.out:
        save(a.out, [e for v in found.values() for e in v])
        print(f"Existing entries saved to {a.out}")


def cmd_template(a):
    found = by_id(api_find([a.id], a.version))
    if a.id not in found:
        sys.exit(f"{a.id} {a.version or ''} is not in the resources database.")
    e = found[a.id][-1]
    if a.out:
        save(a.out, e)
        print(f"Saved {a.id} {e['resource_version']} to {a.out}")
    else:
        print(json.dumps(e, indent=4, ensure_ascii=False))


def parse_set(items):
    out = {}
    for s in items or []:
        k, _, v = s.partition("=")
        try:
            out[k] = json.loads(v)
        except json.JSONDecodeError:
            out[k] = v
    return out


def pack(content, entry, pack_dir):
    """Make the file to upload for a zipped and/or tar-archive entry."""
    if not (entry.get("is_tar_archive") or entry.get("is_zipped")):
        return content
    if not pack_dir:
        sys.exit(
            f"{entry['id']} is is_zipped/is_tar_archive: pass --pack-dir for "
            "the packed files to upload."
        )
    pack_dir.mkdir(parents=True, exist_ok=True)
    cur = content
    if entry.get("is_tar_archive"):
        out = pack_dir / (content.name + ".tar")
        with tarfile.open(out, "w") as t:
            for p in sorted(content.iterdir()):
                t.add(p, arcname=p.name)
        cur = out
    if entry.get("is_zipped"):
        out = pack_dir / (cur.name + ".gz")
        with open(cur, "rb") as fi, gzip.open(out, "wb") as fo:
            shutil.copyfileobj(fi, fo, 1 << 24)
        if cur != content:
            cur.unlink()
        cur = out
    return cur


def content_size(path):
    if path.is_file():
        return path.stat().st_size
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file())


def cmd_new(a):
    if os.path.isfile(a.template):
        tmpl = load(a.template)
    else:
        rid, _, ver = a.template.partition(":")
        found = by_id(api_find([rid], ver or None))
        if rid not in found:
            sys.exit(f"Template {a.template} is not a file or a resource in the database.")
        tmpl = found[rid][-1]
    tmpl.pop("_id", None)
    has_file = "url" in tmpl
    if has_file and not a.url_prefix:
        sys.exit("The template has a url: pass --url-prefix (the dist.gem5.org folder).")
    if a.url_prefix and not a.url_prefix.startswith(DIST):
        sys.exit(f"--url-prefix must start with {DIST}")
    md5 = md5_utils(gem5_dir(a.gem5)) if has_file else None
    pack_dir = Path(a.pack_dir).resolve() if a.pack_dir else None
    overrides = parse_set(a.set)

    entries, files = [], []
    for rid in read_ids(a):
        e = copy.deepcopy(tmpl)
        e["id"] = rid
        e["resource_version"] = a.version
        if a.gem5_versions:
            e["gem5_versions"] = a.gem5_versions.split(",")
        if isinstance(e.get("example_usage"), str):
            e["example_usage"] = e["example_usage"].replace(tmpl["id"], rid)
        e.update(overrides)
        if has_file:
            content = Path(a.files_dir, a.file_pattern.format(id=rid)).resolve()
            if not content.exists():
                sys.exit(f"{rid}: {content} not found.")
            upload = pack(content, e, pack_dir)
            e["md5sum"] = md5.md5(content)
            e["size"] = content_size(content)
            e["url"] = a.url_prefix.rstrip("/") + "/" + upload.name
            files.append(
                {
                    "id": rid,
                    "resource_version": a.version,
                    "content": str(content),
                    "upload": str(upload),
                    "url": e["url"],
                    "md5sum": e["md5sum"],
                }
            )
        entries.append(e)

    with open(a.out + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        save(a.out, merge(load(a.out, []), entries))
        if files:
            m = manifest_path(a.out)
            save(m, merge(load(m, []), files))
    os.unlink(a.out + ".lock")

    print(f"Wrote {len(entries)} entries to {a.out}")
    if files:
        print(f"Wrote the local file list to {manifest_path(a.out)}")
    # Fields that may still describe the template resource rather than these.
    stale = [
        k
        for k, v in tmpl.items()
        if isinstance(v, str)
        and k not in ("id", "example_usage", "url")
        and tmpl["id"] in v
    ]
    if stale:
        print(f"Check these fields, they mention the template id: {', '.join(stale)}")


def cmd_local(a):
    data = load(a.json)
    files = {(f["id"], f["resource_version"]): f for f in load(a.manifest or manifest_path(a.json))}
    n = 0
    for e in data:
        f = files.get((e["id"], e["resource_version"]))
        if f:
            e["url"] = "file://" + f["upload"]
            n += 1
    save(a.out, data)
    print(f"Wrote {a.out}: {n} of {len(data)} entries now use file:// URLs.")
    print(f"Use it with: GEM5_RESOURCE_JSON_APPEND={os.path.abspath(a.out)}")


def cmd_check(a):
    data = load(a.json)
    errors, warnings = [], []
    if not isinstance(data, list):
        sys.exit("The JSON must be a list of entries.")

    seen = set()
    for e in data:
        name = f"{e.get('id')} {e.get('resource_version')}"
        for k in ("id", "resource_version", "category", "gem5_versions"):
            if k not in e:
                errors.append(f"{name}: no '{k}' field")
        if not isinstance(e.get("gem5_versions", []), list):
            errors.append(f"{name}: gem5_versions is not a list")
        key = (e.get("id"), e.get("resource_version"))
        if key in seen:
            errors.append(f"{name}: appears more than once")
        seen.add(key)
        url = e.get("url")
        if url is not None:
            if url.startswith("file://"):
                (errors if a.for_upload else warnings).append(f"{name}: file:// URL")
            elif not url.startswith(DIST):
                warnings.append(f"{name}: URL is not under {DIST}: {url}")
            if "md5sum" not in e:
                errors.append(f"{name}: has a url but no md5sum")

    mpath = a.manifest or manifest_path(a.json)
    if os.path.exists(mpath):
        md5 = md5_utils(gem5_dir(a.gem5))
        files = {(f["id"], f["resource_version"]): f for f in load(mpath)}
        for e in data:
            if "url" not in e:
                continue
            name = f"{e['id']} {e['resource_version']}"
            f = files.get((e["id"], e["resource_version"]))
            if not f:
                (errors if a.for_upload else warnings).append(f"{name}: not in the manifest")
                continue
            content, upload = Path(f["content"]), Path(f["upload"])
            if not content.exists() or not upload.exists():
                errors.append(f"{name}: local file missing ({content} / {upload})")
                continue
            if md5.md5(content) != e.get("md5sum"):
                errors.append(f"{name}: md5sum does not match {content}")
            if not e["url"].startswith("file://") and e["url"].rsplit("/", 1)[-1] != upload.name:
                errors.append(f"{name}: URL file name differs from {upload.name}")
    elif a.for_upload:
        errors.append(f"No manifest ({mpath}); it says which local file goes where.")

    if not a.no_api:
        ids = [e["id"] for e in data if "id" in e]
        existing = by_id(api_find(ids))
        for e in data:
            versions = [x["resource_version"] for x in existing.get(e.get("id"), [])]
            name = f"{e.get('id')} {e.get('resource_version')}"
            if e.get("resource_version") in versions:
                errors.append(f"{name}: this id and version is already in the database")
            elif versions:
                newest = max(versions, key=vkey)
                if vkey(e["resource_version"]) < vkey(newest):
                    warnings.append(f"{name}: older than the newest version in the database ({newest})")
                else:
                    warnings.append(f"{name}: new version of an existing resource (has {', '.join(versions)})")

    # Workloads and suites refer to other resources: each one must be in this
    # JSON or in the database.
    refs = []
    for e in data:
        name = f"{e.get('id')} {e.get('resource_version')}"
        if e.get("category") == "workload":
            refs += [(name, r) for r in (e.get("resources") or {}).values()]
        elif e.get("category") == "suite":
            refs += [(name, w) for w in e.get("workloads") or []]
    if refs:
        here = {(e.get("id"), e.get("resource_version")) for e in data}
        known = by_id(api_find([r.get("id") for _, r in refs])) if not a.no_api else {}
        for name, r in refs:
            rid, ver = r.get("id"), r.get("resource_version")
            versions = [x["resource_version"] for x in known.get(rid, [])]
            if (rid, ver) in here or (ver and ver in versions) or (not ver and versions):
                continue
            if a.no_api and not (rid, ver) in here:
                warnings.append(f"{name}: refers to {rid} {ver or ''} (not checked: --no-api)")
            else:
                errors.append(f"{name}: refers to {rid} {ver or ''}, which is not in this JSON or the database")

    if a.gem5_binary:
        r = subprocess.run(
            [a.gem5_binary, "-q", str(HERE / "validate_with_gem5.py"), os.path.abspath(a.json)],
            capture_output=True, text=True,
        )
        for line in r.stdout.splitlines():
            if line.startswith("INVALID "):
                errors.append("gem5 validator: " + line[8:])
        if r.returncode not in (0, 1):
            errors.append(f"gem5 validator did not run (exit {r.returncode}): {r.stderr[-500:]}")

    for w in warnings:
        print("warning:", w)
    for err in errors:
        print("ERROR:", err)
    print(f"\n{len(data)} entries: {len(errors)} errors, {len(warnings)} warnings.")
    sys.exit(1 if errors else 0)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    q = sub.add_parser("query", help="which IDs already exist")
    q.add_argument("ids", nargs="*")
    q.add_argument("--ids-file")
    q.add_argument("--out", help="save the existing entries here")
    q.set_defaults(fn=cmd_query)

    t = sub.add_parser("template", help="print an existing entry")
    t.add_argument("id")
    t.add_argument("--version", help="default: the newest")
    t.add_argument("--out")
    t.set_defaults(fn=cmd_template)

    n = sub.add_parser("new", help="make entries from a template")
    n.add_argument("--template", required=True, help="a JSON file with one entry, or ID[:VERSION] from the database")
    n.add_argument("ids", nargs="*")
    n.add_argument("--ids-file")
    n.add_argument("--files-dir", default=".", help="where the built files are")
    n.add_argument("--file-pattern", default="{id}", help="file (or directory) name for an id, default '{id}'")
    n.add_argument("--url-prefix", help=f"dist folder the files will be uploaded to, under {DIST}")
    n.add_argument("--version", default="1.0.0", help="resource_version (default 1.0.0)")
    n.add_argument("--gem5-versions", help="comma-separated, for example 25.0,25.1")
    n.add_argument("--set", action="append", metavar="FIELD=VALUE", help="override a field; VALUE is JSON or a string")
    n.add_argument("--pack-dir", help="where to put .gz/.tar files for is_zipped/is_tar_archive entries")
    n.add_argument("--gem5", help="gem5 checkout (for md5_utils)")
    n.add_argument("--out", required=True, help="JSON to write; entries with the same id and version are replaced")
    n.set_defaults(fn=cmd_new)

    l = sub.add_parser("local", help="file:// copy for testing")
    l.add_argument("json")
    l.add_argument("--manifest")
    l.add_argument("--out", required=True)
    l.set_defaults(fn=cmd_local)

    c = sub.add_parser("check", help="check a JSON before testing or uploading")
    c.add_argument("json")
    c.add_argument("--manifest")
    c.add_argument("--for-upload", action="store_true", help="file:// URLs and files missing from the manifest are errors")
    c.add_argument("--no-api", action="store_true", help="don't check against the resources database")
    c.add_argument("--gem5-binary", help="also run gem5's own resource validator with this gem5 binary")
    c.add_argument("--gem5", help="gem5 checkout (for md5_utils)")
    c.set_defaults(fn=cmd_check)

    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
