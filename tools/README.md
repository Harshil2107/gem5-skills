# tools

Scripts that are **not** skills: they are for you to run by hand, and are not
linked into `~/.claude/skills/`.

## publish-resources.py

Publishes resources to gem5's public resources: uploads the files to Azure
blob storage (served at `dist.gem5.org`) and inserts the entries into the
resources MongoDB. It takes the JSON and manifest that the
[`gem5-resource-json`](../skills/gem5-resource-json/SKILL.md) skill writes.

```sh
~/gem5-skills/tools/publish-resources.py <task>/resources/<name>.json --gem5 <gem5 checkout>            # dry run
~/gem5-skills/tools/publish-resources.py <task>/resources/<name>.json --gem5 <gem5 checkout> --publish
```

What it does:

1. Checks the JSON with `resjson.py check --for-upload`: fields, duplicates,
   no `file://` URLs, and every local file's md5 matching.
2. For each file, checks the storage account directly (not through the CDN):
   - missing: it will be uploaded
   - there with the same MD5: it's skipped
   - anything else: the run stops
3. For each entry, checks the API:
   - missing: it will be inserted
   - there and identical: it's skipped
   - there with different fields: the run stops (bump `resource_version`)
4. Without `--publish` it stops here (dry run, no credentials used).
5. With `--publish` it continues:
   - It needs an interactive terminal and shows the `az` subscription and
     account, the database and collection, and the counts. You then type
     the number of entries to go ahead.
   - It uploads with `az storage blob upload --auth-mode login --overwrite false --content-md5 ...`.
   - It checks every file through `dist.gem5.org`, with HTTP 200 and the
     right MD5. Nothing is inserted until all files pass.
   - It re-checks the database itself, inserts the new entries
     (`insert_many`, never update or replace), and checks them through the API.
   - It appends what it did to `<name>.publish-log.json`.

A run that stopped half-way can be rerun: what's already published
identically is skipped.

### Setup

- `az login`, with write access to the storage account. If you have several
  subscriptions, set `RESOURCES_AZURE_SUBSCRIPTION` so the tool stops when
  `az` is on the wrong one.
- `pip install pymongo` (only `--publish` needs it).
- Put the write-access MongoDB URI in a file only you can read, and point
  the settings at it:

  ```sh
  install -m 600 /dev/null ~/.config/gem5-skills/mongo-uri
  $EDITOR ~/.config/gem5-skills/mongo-uri
  ```

  You can also set `GEM5_RESOURCES_MONGO_URI` in the environment for one run.
- Settings in `~/.config/gem5-skills/config` (defaults in brackets):
  `RESOURCES_MONGO_URI_FILE`, `RESOURCES_MONGO_DB` [`gem5-vision`],
  `RESOURCES_MONGO_COLLECTION` [`resources`], `RESOURCES_AZURE_ACCOUNT`
  [`gem5dist`], `RESOURCES_AZURE_CONTAINER` [`dist`],
  `RESOURCES_AZURE_SUBSCRIPTION`.

### Trying it out safely

Before the first real run, point it at a test target: a scratch collection
(`RESOURCES_MONGO_COLLECTION=versions_test` or similar) and a JSON whose URLs
are under a test folder. Note that the dry run's database check uses the
public API (the real collection), whatever the collection setting is.

### Keeping Claude away from it

The skills never run `--publish`, and the tool refuses to run without a
terminal. Claude's shell has no terminal. To be stricter still, add a deny
rule to `~/.claude/settings.json`:

```json
{ "permissions": { "deny": ["Bash(*publish-resources.py*--publish*)"] } }
```
