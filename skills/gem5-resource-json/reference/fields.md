# gem5 resource entries: fields and rules

What the fields mean, and the things that aren't obvious. When unsure, copy
an existing entry of the same kind (`resjson.py template`) and change as
little as possible.

## Identity and versions

- An entry is identified by `id` + `resource_version`. A published pair is
  never changed or reused. A resource whose file changes gets a new
  `resource_version`.
- New IDs start at `1.0.0`. In practice the database mostly uses major bumps
  (`2.0.0`) for changed resources, for example the asmtest rv32 fixes. Ask
  the user.
- gem5 picks the newest version that lists a compatible `gem5_versions`,
  unless a config asks for one with `resource_version=`.

## Files

| Field | Meaning |
|---|---|
| `url` | where gem5 downloads it from: `https://dist.gem5.org/dist/<path>`. `<path>` is the blob name in container `dist` of storage account `gem5dist`. |
| `md5sum` | md5 of what gem5 ends up with **after** unpacking: the plain file for `is_zipped`, or gem5's `md5_dir` of the extracted folder for `is_tar_archive`. Not the md5 of the download. `resjson.py` uses gem5's `md5_utils`, so it's always right. |
| `size` | informational, not checked by gem5. Most entries give the unpacked size (a few give the download size). `resjson.py` writes the unpacked size. |
| `is_zipped` | the download is gzipped; gem5 gunzips it. Disk images usually are. |
| `is_tar_archive` | the download is a tar of a directory; gem5 extracts it. Used by `directory` and similar categories. |

- The md5 must come from the exact file that gets uploaded. Rebuilds are not
  byte-identical (for example, asmtest ELFs record temporary `.o` file names),
  so never reuse an md5 from another build.
- `file://` URLs are for local testing only (`resjson.py local`). The upload
  JSON must have dist URLs.

## Category-specific fields

Check gem5's resource classes in `src/python/gem5/resources/resource.py` for
the full list; `resjson.py check --gem5-binary` runs gem5's own validator.

| Category | Notable fields |
|---|---|
| `binary`, `kernel`, `bootloader`, `file`, `checkpoint` | `url`, `md5sum`, `architecture` (binaries/kernels) |
| `disk-image` | also `root_partition` (string) |
| `directory` | `is_tar_archive: true` |
| `workload` | no file; `function`, `resources` (`{name: {id, resource_version}}`), `additional_params` |
| `suite` | no file; `workloads` list of `{id, resource_version}` |

gem5 resolves a workload's `resources` and a suite's `workloads` before it
validates them, so gem5's validator can't check them raw (it says a suite's
`workloads` should be a dict; that's about the resolved object).
`resjson.py check` skips them in the validator and checks instead that every
resource they refer to is in the same JSON or in the database.

## Common fields

- `description`, `tags`, `license`, `author`, `source`, `source_url`,
  `code_examples`, `example_usage`: copy them from a sibling. `resjson.py new`
  puts the new id into `example_usage` and lists any other field that still
  mentions the template's id.
- `gem5_versions`: a list of release strings (`"25.0"`, `"27.0"`).
- `architecture`: `RISCV`, `X86`, `ARM`, ...

## The resources API

- `https://api.gem5.org/api/resources/find-resources-in-batch?id=X&resource_version=None&...`
  returns every version of each ID. Send at most about 20 IDs per request;
  more gives HTTP 414.
- `list-all-resources` returns 404 (as of 2026-11), so there's no way to list
  everything. Query known IDs instead.
- What the API returns is what is stored in MongoDB (database `gem5-vision`,
  collection `resources`), without `_id`.
