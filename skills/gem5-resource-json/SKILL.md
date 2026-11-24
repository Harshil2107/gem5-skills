---
name: gem5-resource-json
description: Make and check gem5-resources JSON entries for resources that were built or changed (binaries such as asmtests, kernels, bootloaders, disk images, directories, workloads) - find which IDs are new or changed against the resources database, copy the format of an existing entry, compute md5sums with gem5's own md5 code, write the upload JSON and a file:// copy for testing, check it, and optionally build and test the resources in gem5 first. Use when a gem5-resources PR adds or changes resources that need database entries, or when the user asks for resources JSON for files they built. Never uploads or publishes.
argument-hint: "[PR number | source dir | list of IDs]"
---

# gem5-resource-json: entries for new or changed resources

You work out what's new, write the JSON, check it, and (if asked) build and
test the resources. **Publishing is the user's job.** Never upload to Azure,
never write to MongoDB, and never run `tools/publish-resources.py --publish`
(it refuses without a terminal anyway). You may run that tool without
`--publish`: it's a read-only dry run.

Scripts are in `scripts/`. `resjson.py` does the JSON work; run
`python3 -I scripts/resjson.py <cmd> --help` for options. It only reads from
the public API (`api.gem5.org`).

Read `reference/fields.md` before writing entries for a kind of resource you
haven't done in this session.

## General steps, per-source notes

Steps 1, 2, 4 and 6 below are the same for every category and source.
Building (3) and testing (5) depend on the source, so each source that has
been done before has a folder `sources/<source>/` with a `README.md` (how to
list its IDs, the template, the URL folder, how to build and test, and
gotchas) and any helper scripts. Before starting, check for
`sources/<source>/`:

| Source folder | For |
|---|---|
| `sources/asmtest/` | `src/asmtest` riscv-tests binaries (build wrapper, SE sweep on all CPUs) |

For a source with no folder yet, follow the general steps and use the
source's own README and build scripts. When done, offer to add a
`sources/<source>/README.md` with what you learned, in the same layout as
`sources/asmtest/README.md`, so the next time is quicker. Disk images already
have their own skill (`gem5-disk-images`). Use it to build and validate them,
and use this skill for the JSON if the user wants the publish flow.

## Task folder and settings

Work in a task folder made by `gem5-branch` (type `resources`, or a PR
checkout): `gem5-resources/` holds the PR, `gem5/` is the gem5 to compute md5s
and test with, and `notes.md` gets the decisions. Write the JSON to
`<task>/resources/<name>.json` (its manifest goes beside it). Never commit it
to gem5-resources unless the user says so.

Confirm these with the user in one question at the start, unless the request
or memory already gives them:

| Setting | Default |
|---|---|
| Which resources | the ones the PR adds or changes (step 1 finds them) |
| Template entry | the newest version of an existing resource of the same kind and source |
| `resource_version` | `1.0.0` for new IDs; changed IDs: ask (never reuse a version) |
| `gem5_versions` | ask; look at the template's and at the newest gem5 release |
| URL folder | the template's folder under `https://dist.gem5.org/dist/`, unless that folder is for an older version set (ask) |
| Build the resources? | only if asked (step 3) |
| Test them in gem5? | only if asked (step 5) |

## Workflow

### 1. Find what's new or changed

- List the IDs the source can build: `sources/<source>/README.md` says how
  if it exists. Otherwise, look at the PR's diff and the source's README.
- `resjson.py query --ids-file ids.txt --out existing.json`: says per ID whether
  it exists and which versions.
- Check the PR diff for changes to sources of IDs that **already exist**
  (`git diff <base>... --stat -- <source dir>`). A rebuilt existing resource
  gets a new md5, so it needs a new `resource_version`, or no entry at all.
  Ask the user which; don't upload it silently under the old version.
- Write the lists (new / changed / unchanged) and the decisions into `notes.md`.

### 2. Pick the template

`resjson.py template <sibling-id> [--version V]`: show the user the entry you
want to copy (description, tags, license, author, source, URL folder). The
template's quirks are copied as they are (asmtests have `license: " BSD-3-Clause"`
with a leading space), so the new entries match the old ones. Change a
field only if the user says to (`--set`).

### 3. Build (optional)

Only when asked. Use the source's own build (see `sources/<source>/` if
there is one); for disk images use the `gem5-disk-images` skill. Build
only the IDs from step 1 into a separate output folder, not the repo's
`bin/`. Check the build log for errors; don't trust the exit code alone.

### 4. Write and check the JSON

```
resjson.py new --template <id>:<ver> --ids-file new.txt --files-dir <out> \
    --url-prefix https://dist.gem5.org/dist/<folder> --version 1.0.0 \
    --gem5-versions <v>[,<v>...] [--set field=value]... [--pack-dir <dir>] \
    --out <task>/resources/<name>.json
resjson.py check <task>/resources/<name>.json --for-upload \
    --gem5-binary <gem5>/build/ALL/gem5.opt
```

- `new` writes the upload JSON (dist URLs) and `<name>.manifest.json`, which
  maps each entry to its local file. It computes `md5sum` with gem5's
  `md5_utils` (as gem5 checks downloads), and `size`. For `is_zipped` or
  `is_tar_archive` templates it packs the upload files into `--pack-dir`.
- Rerunning `new` replaces entries with the same id and version, so you can
  add resources in several runs. Entries with no files (workloads, suites)
  work the same; give their fields with `--set`.
- `check` finds: duplicate entries, missing fields, `file://` URLs, md5s that
  don't match the files, id+version already in the database, and anything
  gem5's own validator rejects (with `--gem5-binary`). It must end with
  `0 errors` before you hand off. Explain each warning to the user.

### 5. Test in gem5 (optional)

Only when asked. `resjson.py local <json> --out <task>/resources/<name>-local.json`
writes a copy with `file://` URLs. Run with
`GEM5_RESOURCE_JSON_APPEND=<that file>`:

- the source's own test, if `sources/<source>/` has one (asmtests:
  `sources/asmtest/sweep.sh --gem5 <gem5> --ids-file ids.txt --json <local json> --out <task>/runs/<name>`).
- otherwise, run what uses the resource: gem5's example config or test config
  for it, through the `gem5-run` skill (`run.sh --json`). For a static SE
  binary, `gem5-debug`'s `se-all-cpus.sh` runs it on every CPU model. For a
  kernel, bootloader or disk image, a full-system boot of the workload that
  uses it.
- a resource used by a gem5 test suite: the `gem5-testlib` skill.
- something fails in gem5: the `gem5-debug` skill.

Report which failures are expected (gem5 doesn't implement the instruction or
feature yet) and which aren't, and give the evidence (the panic line).
The local JSON only works for resources that aren't in the database yet:
with the same id and version in both, gem5 stops with "multiple resources
with the same version".

### 6. Hand off

Tell the user:

- the JSON and manifest paths, the number of entries, and the URL folder
- the test results, if any
- how to publish, which they run themselves from a terminal: first
  `~/gem5-skills/tools/publish-resources.py <json>` (dry run), then the same
  with `--publish`. See `tools/README.md` in the gem5-skills repo.

After the user says it's published, you can check it read-only: the dry run
should say `Nothing to do: everything is already published`, and
the same gem5 test run **without** `--json` should give the same
results as the local test.
