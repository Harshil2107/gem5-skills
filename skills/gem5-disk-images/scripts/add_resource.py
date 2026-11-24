"""Add the disk-image entry and its workload for a finished build to a
gem5-resources JSON file. Earlier entries with the same id and version are
replaced, and the file is locked so parallel builds can register safely.

Usage: python3 -I add_resource.py --json <json> --isa <x86|arm|riscv>
           --kind <base|npb|gapbs> --ubuntu <ver> --image <path>
           --kernel <id>[:<version>] [options]
Prints the workload id that was added.
"""

import argparse
import fcntl
import hashlib
import json
import os
import subprocess

ARCH = {"x86": "X86", "arm": "ARM", "riscv": "RISCV"}
ROOT_PARTITION = {"x86": "1", "arm": "2", "riscv": "1"}
BOOTLOADER = {
    "arm": "arm64-bootloader-foundation:2.0.0",
    "riscv": "riscv-bootloader-opensbi-1.3.1:1.0.0",
}
HYPERCALLS = (
    "It has 3 m5 hypercall calls that occur when the Kernel is booted "
    "(hypercall id 1), when the after_boot.sh script is run (hypercall id 2), "
    "and after the runscript is done running (hypercall id 3)."
)
ROI = (
    " The benchmark also has ROI begin (hypercall id 4) and ROI end "
    "(hypercall id 5) hypercalls in the region of interest."
)


def id_version(s):
    rid, _, ver = s.partition(":")
    return {"id": rid, "resource_version": ver or "1.0.0"}


def git_user():
    try:
        return subprocess.run(
            ["git", "config", "user.name"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
p.add_argument("--json", required=True)
p.add_argument("--isa", required=True, choices=ARCH)
p.add_argument("--kind", required=True, choices=["base", "npb", "gapbs"])
p.add_argument("--ubuntu", required=True, help="for example 26.04")
p.add_argument("--image", required=True)
p.add_argument("--kernel", required=True, help="kernel resource id[:version]")
p.add_argument("--bootloader", help="id[:version]; defaults per ISA")
p.add_argument("--version", default="1.0.0", help="resource_version of both")
p.add_argument("--disk-id")
p.add_argument("--workload-id")
p.add_argument("--author", default=git_user())
p.add_argument("--gem5-versions", default="25.0,25.1")
p.add_argument("--readfile", help="override the workload's readfile_contents")
a = p.parse_args()

image = os.path.realpath(a.image)
ver, isa = a.ubuntu, a.isa
gem5_versions = a.gem5_versions.split(",")

if a.kind == "base":
    disk_id = a.disk_id or f"{isa}-ubuntu-{ver}-img"
    workload_id = a.workload_id or f"{isa}-ubuntu-{ver}-boot-with-systemd"
    source = (
        "src/riscv-fs/riscv-ubuntu-22.04-24.04"
        if isa == "riscv"
        else "src/ubuntu-generic-diskimages"
    )
    disk_desc = f"Ubuntu {ver} for {isa}"
    workload_desc = f"A workload that boots Ubuntu {ver} with systemd. " + HYPERCALLS
    readfile = None
    tags = []
elif a.kind == "npb":
    disk_id = a.disk_id or f"{isa}-ubuntu-{ver}-npb-img"
    workload_id = a.workload_id or f"{isa}-ubuntu-{ver}-npb-bt-s"
    source = "src/npb-24.04-imgs"
    disk_desc = f"the npb benchmarks for Ubuntu {ver} for {isa}"
    workload_desc = "A workload that runs NPB BT size S Benchmark. " + HYPERCALLS + ROI
    readfile = "/home/gem5/NPB3.4-OMP/bin/bt.S.x; sleep 5;"
    tags = ["npb", ver, "fullsystem"]
else:
    disk_id = a.disk_id or f"{isa}-ubuntu-{ver}-gapbs-img"
    workload_id = a.workload_id or f"{isa}-ubuntu-{ver}-gapbs-bc-test"
    source = "src/gapbs"
    disk_desc = f"the gapbs benchmarks for Ubuntu {ver} for {isa}"
    workload_desc = (
        "A workload that runs GAPBS bc Benchmark. It runs with graph size "
        "2^19 and degree 4. " + HYPERCALLS + ROI
    )
    readfile = "/home/gem5/gapbs/bin/bc -u 19 -k 4 -s; sleep 5;"
    tags = ["gapbs", ver, "fullsystem"]
readfile = a.readfile or readfile

md5 = hashlib.md5()
with open(image, "rb") as f:
    for chunk in iter(lambda: f.read(1 << 24), b""):
        md5.update(chunk)

disk = {
    "id": disk_id,
    "resource_version": a.version,
    "category": "disk-image",
    "author": [a.author],
    "code_examples": [],
    "description": (
        f"A disk image containing {disk_desc}. This image will run an "
        "`m5 readfile` instruction after booting. This diskimage will run m5 "
        "exit events at different intervals in the boot process, please "
        "refer to the README.md of the source for more information."
    ),
    "source_url": f"https://github.com/gem5/gem5-resources/tree/stable/{source}",
    "license": "",
    "tags": [isa, "fullsystem"],
    "example_usage": f'obtain_resource(resource_id="{disk_id}")',
    "gem5_versions": gem5_versions,
    "size": os.path.getsize(image),
    "url": "file://" + image,
    "is_tar_archive": False,
    "md5sum": md5.hexdigest(),
    "is_zipped": False,
    "architecture": ARCH[isa],
    "root_partition": ROOT_PARTITION[isa],
    "source": source,
}

resources = {
    "kernel": id_version(a.kernel),
    "disk_image": {"id": disk_id, "resource_version": a.version},
}
bootloader = a.bootloader or BOOTLOADER.get(isa)
if bootloader:
    resources["bootloader"] = id_version(bootloader)

workload = {
    "id": workload_id,
    "resource_version": a.version,
    "category": "workload",
    "author": [a.author],
    "code_examples": [],
    "description": workload_desc,
    "source_url": "",
    "license": "",
    "tags": tags,
    "example_usage": f'obtain_resource("{workload_id}", resource_version="{a.version}")',
    "gem5_versions": gem5_versions,
    "size": 0,
    "architecture": ARCH[isa],
    "function": "set_kernel_disk_workload",
    "additional_params": {"readfile_contents": readfile} if readfile else {},
    "resources": resources,
}

if not os.path.exists(a.json):
    with open(a.json, "w") as f:
        f.write("[]\n")

with open(a.json + ".lock", "w") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    with open(a.json) as f:
        data = json.load(f)
    new_keys = {(r["id"], r["resource_version"]) for r in (disk, workload)}
    data = [r for r in data if (r["id"], r["resource_version"]) not in new_keys]
    data += [disk, workload]
    with open(a.json + ".tmp", "w") as f:
        json.dump(data, f, indent=4)
        f.write("\n")
    os.replace(a.json + ".tmp", a.json)

print(workload_id)
