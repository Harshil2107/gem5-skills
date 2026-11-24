#!/usr/bin/env python3
"""Publish gem5 resources: upload their files to Azure blob storage (served at
dist.gem5.org) and insert their entries into the gem5 resources MongoDB.

This writes to public, shared infrastructure. It is a tool for a person, not
for Claude, and is deliberately not a skill:

  * Without --publish it is a dry run: it checks everything and prints the
    plan, using only public read-only endpoints and no credentials.
  * --publish needs an interactive terminal and asks you to type the number
    of entries. It refuses to run otherwise (so it can't run from a script or
    an agent's shell).
  * Files are uploaded first and checked through dist.gem5.org; entries are
    inserted into MongoDB only after every file is in place. Nothing is ever
    overwritten: an existing blob or entry that differs stops the run, and one
    that is identical is skipped (so a run that stopped half-way can be rerun).

Usage:
  publish-resources.py JSON [--manifest M] [--gem5 DIR]           # dry run
  publish-resources.py JSON [--manifest M] [--gem5 DIR] --publish

JSON and its manifest (JSON-stem.manifest.json) are made by the
gem5-resource-json skill (resjson.py new). Settings are read from
~/.config/gem5-skills/config (see skills/gem5-branch/config.example):

  RESOURCES_MONGO_URI_FILE   file holding the write-access MongoDB URI (chmod 600)
                             (or set GEM5_RESOURCES_MONGO_URI in the environment)
  RESOURCES_MONGO_DB         default gem5-vision
  RESOURCES_MONGO_COLLECTION default resources
  RESOURCES_AZURE_ACCOUNT    default gem5dist
  RESOURCES_AZURE_CONTAINER  default dist
  RESOURCES_AZURE_SUBSCRIPTION  optional; the run stops if `az` is logged in to
                             another subscription

Needs: az (logged in with `az login`, with write access to the storage
account) and pymongo, for --publish only.
"""

import argparse
import base64
import copy
import datetime
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RESJSON = REPO / "skills/gem5-resource-json/scripts/resjson.py"
API = "https://api.gem5.org/api/resources"
DIST = "https://dist.gem5.org/dist/"
BATCH = 20


def settings():
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


def die(msg):
    print(f"\nSTOPPED: {msg}", flush=True)
    sys.exit(1)


def md5_b64(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 24), b""):
            h.update(chunk)
    return base64.b64encode(h.digest()).decode()


def head(url):
    """(status, Content-MD5 or None, Content-Length or None)."""
    req = urllib.request.Request(url, method="HEAD")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.headers.get("Content-MD5"), r.headers.get("Content-Length")
    except urllib.error.HTTPError as e:
        return e.code, None, None


def api_find(ids):
    found = []
    ids = list(dict.fromkeys(ids))
    for i in range(0, len(ids), BATCH):
        q = []
        for rid in ids[i : i + BATCH]:
            q += [("id", rid), ("resource_version", "None")]
        url = f"{API}/find-resources-in-batch?" + urllib.parse.urlencode(q)
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                found += json.load(r)
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
    return {(e["id"], e["resource_version"]): e for e in found}


def strip_id(doc):
    doc = dict(doc)
    doc.pop("_id", None)
    return doc


def main():
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("json")
    p.add_argument("--manifest")
    p.add_argument("--gem5", help="gem5 checkout, for md5_utils (see resjson.py)")
    p.add_argument("--publish", action="store_true", help="really upload and insert")
    a = p.parse_args()

    cfg = settings()
    account = cfg.get("RESOURCES_AZURE_ACCOUNT", "gem5dist")
    container = cfg.get("RESOURCES_AZURE_CONTAINER", "dist")
    subscription = cfg.get("RESOURCES_AZURE_SUBSCRIPTION", "")
    db_name = cfg.get("RESOURCES_MONGO_DB", "gem5-vision")
    coll_name = cfg.get("RESOURCES_MONGO_COLLECTION", "resources")
    blob_base = f"https://{account}.blob.core.windows.net/{container}/"

    if a.publish and not (sys.stdin.isatty() and sys.stdout.isatty()):
        die("--publish needs an interactive terminal. Run it yourself, by hand.")

    json_path = Path(a.json).resolve()
    manifest = Path(a.manifest or json_path.with_name(json_path.stem + ".manifest.json"))
    entries = json.loads(json_path.read_text())
    files = {
        (f["id"], f["resource_version"]): f for f in json.loads(manifest.read_text())
    }

    # 1. The same checks the skill runs: fields, duplicates, no file:// URLs,
    #    local files present and md5sums matching. The database check is done
    #    below instead, because entries already published identically are fine.
    print(f"== Checking {json_path.name} ({len(entries)} entries)", flush=True)
    cmd = [sys.executable, "-I", str(RESJSON), "check", str(json_path),
           "--manifest", str(manifest), "--for-upload", "--no-api"]
    if a.gem5:
        cmd += ["--gem5", a.gem5]
    if subprocess.run(cmd).returncode != 0:
        die("the JSON check failed (above).")

    # 2. Plan the uploads: a blob that is missing is uploaded; one that is
    #    there with the same md5 is skipped; anything else stops the run.
    #    Checked on the storage account directly, not through the CDN, so no
    #    404 is cached at dist.gem5.org for a file about to be uploaded.
    print(f"\n== Files (storage account {account}, container {container})")
    uploads, blob_errors = [], []
    for e in entries:
        if "url" not in e:
            continue
        f = files[(e["id"], e["resource_version"])]
        path = e["url"][len(DIST):]
        local_md5 = md5_b64(f["upload"])
        status, remote_md5, _ = head(blob_base + urllib.parse.quote(path))
        if status == 404:
            uploads.append((e, f["upload"], path, local_md5))
        elif status == 200 and remote_md5 == local_md5:
            print(f"  already there, same file: {path}")
        elif status == 200:
            blob_errors.append(f"{path} exists with a different (or unknown) MD5")
        else:
            blob_errors.append(f"{path}: HTTP {status} from the storage account")
    for err in blob_errors:
        print("  ERROR:", err)
    total = sum(os.path.getsize(u[1]) for u in uploads)
    print(f"  {len(uploads)} to upload ({total / 1e6:.1f} MB)")

    # 3. Plan the inserts, from the public API (same data as the database).
    print(f"\n== Database entries (db {db_name}, collection {coll_name})")
    existing = api_find([e["id"] for e in entries])
    inserts, db_errors = [], []
    for e in entries:
        key = (e["id"], e["resource_version"])
        if key not in existing:
            inserts.append(e)
        elif strip_id(existing[key]) == e:
            print(f"  already there, identical: {key[0]} {key[1]}")
        else:
            db_errors.append(f"{key[0]} {key[1]} is in the database with different fields")
    for err in db_errors:
        print("  ERROR:", err)
    print(f"  {len(inserts)} to insert")

    if blob_errors or db_errors:
        die("fix the errors above (bump resource_version for changed resources).")
    if not uploads and not inserts:
        print("\nNothing to do: everything is already published.")
        return
    if not a.publish:
        print("\nDry run: nothing was uploaded or inserted. Add --publish to do it.")
        return

    # 4. Confirm, with credentials and accounts shown.
    uri = os.environ.get("GEM5_RESOURCES_MONGO_URI")
    uri_file = cfg.get("RESOURCES_MONGO_URI_FILE")
    if not uri and inserts:
        if not uri_file or not os.path.isfile(uri_file):
            die("set RESOURCES_MONGO_URI_FILE in the settings (or GEM5_RESOURCES_MONGO_URI).")
        uri = Path(uri_file).read_text().strip()
    acct = {}
    if uploads:
        r = subprocess.run(["az", "account", "show", "-o", "json"], capture_output=True, text=True)
        if r.returncode != 0:
            die("az is not logged in: run `az login`.")
        acct = json.loads(r.stdout)
        if subscription and subscription not in (acct.get("name"), acct.get("id")):
            die(f"az is on subscription '{acct.get('name')}', not '{subscription}': "
                f"run `az account set --subscription {subscription}`.")
    print("\n== About to publish")
    if uploads:
        print(f"  upload {len(uploads)} files to {account}/{container} "
              f"(az subscription: {acct.get('name')}, user: {acct.get('user', {}).get('name')})")
    if inserts:
        print(f"  insert {len(inserts)} entries into {db_name}.{coll_name}")
    answer = input(f"Type {len(entries)} (the number of entries) to go ahead: ").strip()
    if answer != str(len(entries)):
        die("not confirmed; nothing was changed.")

    log = {
        "time": datetime.datetime.now().isoformat(timespec="seconds"),
        "json": str(json_path),
        "uploaded": [],
        "inserted": [],
    }
    log_path = json_path.with_name(json_path.stem + ".publish-log.json")

    def write_log():
        old = json.loads(log_path.read_text()) if log_path.exists() else []
        log_path.write_text(json.dumps(old + [log], indent=4) + "\n")

    # 5. Upload. --overwrite false: Azure refuses if the blob appeared since.
    try:
        for i, (e, local, path, md5) in enumerate(uploads, 1):
            print(f"  [{i}/{len(uploads)}] {path}")
            r = subprocess.run(
                ["az", "storage", "blob", "upload", "--auth-mode", "login",
                 "--account-name", account, "--container-name", container,
                 "--name", path, "--file", local, "--content-md5", md5,
                 "--overwrite", "false", "--no-progress", "--only-show-errors"],
                capture_output=True, text=True,
            )
            if r.returncode != 0:
                die(f"upload of {path} failed:\n{r.stderr}")
            log["uploaded"].append(path)

        # 6. Every file must come back through dist.gem5.org with its MD5
        #    before anything goes into the database.
        print("\n== Checking the files through dist.gem5.org")
        for e, local, path, md5 in uploads:
            for attempt in range(5):
                status, remote_md5, _ = head(e["url"])
                if status == 200 and remote_md5 == md5:
                    break
                time.sleep(10)
            else:
                die(f"{e['url']} gives HTTP {status}, MD5 {remote_md5} (want {md5}). "
                    "Nothing was inserted into the database.")
        print(f"  all {len(uploads)} files OK")

        # 7. Insert. Re-check the database itself first, in case it changed.
        if inserts:
            import pymongo

            coll = pymongo.MongoClient(uri)[db_name][coll_name]
            for e in inserts:
                if coll.find_one({"id": e["id"], "resource_version": e["resource_version"]}):
                    die(f"{e['id']} {e['resource_version']} appeared in the database "
                        "since the check; nothing more was inserted.")
            coll.insert_many([copy.deepcopy(e) for e in inserts], ordered=True)
            log["inserted"] = [f"{e['id']} {e['resource_version']}" for e in inserts]
            print(f"\n== Inserted {len(inserts)} entries")
    finally:
        write_log()

    # 8. Check that the API serves every entry as we wrote it.
    print("\n== Checking the entries through the resources API")
    existing = api_find([e["id"] for e in entries])
    bad = [f"{e['id']} {e['resource_version']}" for e in entries
           if strip_id(existing.get((e["id"], e["resource_version"]), {})) != e]
    if bad:
        print(f"  {len(bad)} entries not served as written (may be API caching; "
              f"rerun the dry run to recheck): {', '.join(bad[:10])}")
    else:
        print(f"  all {len(entries)} entries OK")
    print(f"\nDone. Log: {log_path}")


if __name__ == "__main__":
    main()
