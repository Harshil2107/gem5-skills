"""Compare a gem5 run with a baseline run, stage by stage, and estimate when
it will finish if it's still running.

A stage is the time between two stats dumps (gem5 dumps stats at each
hypercall in the disk-image workloads). Uses stats.txt and simout of both
runs.

Usage: python3 -I compare.py BASELINE_OUTDIR RUN_OUTDIR
"""

import os
import re
import subprocess
import sys
import time


def read(path):
    try:
        with open(path, errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def stages(outdir):
    """[(label, host_seconds, final_tick)] for each stats dump."""
    stats = read(os.path.join(outdir, "stats.txt"))
    simout = read(os.path.join(outdir, "simout.txt")) or read(
        os.path.join(outdir, "simout")
    )
    labels = re.findall(r"Dumping and resetting stats ([^\n]*)", simout)
    out = []
    for i, block in enumerate(stats.split("Begin Simulation Statistics")[1:]):
        host = re.search(r"^hostSeconds\s+([\d.]+)", block, re.M)
        tick = re.search(r"^finalTick\s+(\d+)", block, re.M)
        label = labels[i] if i < len(labels) else "end of run"
        out.append(
            (
                label.strip(" !"),
                float(host.group(1)) if host else 0.0,
                int(tick.group(1)) if tick else 0,
            )
        )
    return out


def elapsed(outdir):
    """Seconds the run has been going, if it is still running."""
    try:
        pid = open(os.path.join(outdir, "pid")).read().strip()
        args = subprocess.run(
            ["ps", "-o", "etimes=,args=", "-p", pid],
            capture_output=True, text=True,
        ).stdout.strip()
    except OSError:
        return None
    if not args or os.path.realpath(outdir) not in args:
        return None
    return int(args.split()[0])


def fmt(s):
    s = int(s)
    return f"{s // 3600}h{s % 3600 // 60:02d}m" if s >= 3600 else f"{s // 60}m{s % 60:02d}s"


base_dir, run_dir = sys.argv[1:3] if len(sys.argv) == 3 else sys.exit(__doc__)
base, run = stages(base_dir), stages(run_dir)
if not base:
    sys.exit(f"No stats dumps in {base_dir}/stats.txt")

print(f"{'stage':<55} {'baseline':>9} {'this run':>9} {'ratio':>6}")
for i, (label, bhost, _) in enumerate(base):
    if i < len(run):
        rhost = run[i][1]
        ratio = f"{rhost / bhost:.2f}" if bhost else "-"
        print(f"{label[:55]:<55} {fmt(bhost):>9} {fmt(rhost):>9} {ratio:>6}")
    else:
        print(f"{label[:55]:<55} {fmt(bhost):>9} {'':>9}")

done = len(run)
running = elapsed(run_dir)
if running is None:
    print(f"\nRun has exited after {done} of {len(base)} baseline stages.")
    sys.exit(0)

# Scale the baseline's remaining stages by how much slower or faster this run
# has been so far, then subtract the time already spent in the current stage.
spent = sum(r[1] for r in run)
ratio = spent / sum(b[1] for b in base[:done]) if done and spent else 1.0
in_stage = max(0, running - spent)
left = max(0, sum(b[1] for b in base[done:]) * ratio - in_stage)
finish = time.strftime("%H:%M", time.localtime(time.time() + left))
print(
    f"\nRunning for {fmt(running)}, {done} of {len(base)} stages done, "
    f"{ratio:.2f}x the baseline's time so far."
)
if done < len(base):
    print(f"Next: {base[done][0]}")
print(f"Rough finish: about {fmt(left)} from now (around {finish}).")
