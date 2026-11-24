# Run gem5's own resource-entry validator on every entry of a resources JSON.
# Run it with a gem5 binary, not python:
#   build/ALL/gem5.opt -q validate_with_gem5.py /abs/path/resources.json
# Prints "INVALID <id> <version>: <reason>" for each bad entry. Exit 1 if any.

import json
import sys

from gem5.resources import resource

check = getattr(resource, "_resources_schema_validator", None)
if check is None:
    print("This gem5 has no _resources_schema_validator; use a newer gem5.")
    sys.exit(2)

with open(sys.argv[-1]) as f:
    data = json.load(f)

bad = 0
for e in data:
    # gem5 turns workload and suite entries into objects (resolving the
    # resources they refer to) before validating them, so their raw JSON
    # can't be validated here. resjson.py check checks their references.
    if e.get("category") in ("workload", "suite"):
        continue
    try:
        check(e)
    except Exception as ex:  # the validator raises plain Exceptions
        bad += 1
        msg = " ".join(str(ex).split())
        print(f"INVALID {e.get('id')} {e.get('resource_version')}: {msg}")
print(f"{bad} invalid of {len(data)} entries (workloads and suites not checked here)")
sys.exit(1 if bad else 0)
