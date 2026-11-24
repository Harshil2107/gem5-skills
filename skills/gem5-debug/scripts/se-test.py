# gem5 config: run one binary in SE mode on a single core.
#
#   gem5.opt se-test.py BINARY [--isa riscv] [--cpu atomic|timing|minor|o3]
#            [--sysroot DIR] [--args "ARG ..."] [--caches]
#
# --sysroot runs a dynamically linked binary with the loader and libraries
# from DIR (for example a root filesystem extracted from a disk image).

import argparse
import shlex

from gem5.components.boards.simple_board import SimpleBoard
from gem5.components.cachehierarchies.classic.no_cache import NoCache
from gem5.components.cachehierarchies.classic.private_l1_private_l2_cache_hierarchy import (
    PrivateL1PrivateL2CacheHierarchy,
)
from gem5.components.memory import SingleChannelDDR3_1600
from gem5.components.processors.cpu_types import CPUTypes
from gem5.components.processors.simple_processor import SimpleProcessor
from gem5.isas import ISA
from gem5.resources.resource import BinaryResource
from gem5.simulate.simulator import Simulator

ap = argparse.ArgumentParser()
ap.add_argument("binary")
ap.add_argument("--isa", default="riscv", choices=["riscv", "x86", "arm"])
ap.add_argument(
    "--cpu", default="atomic", choices=["atomic", "timing", "minor", "o3"]
)
ap.add_argument("--sysroot")
ap.add_argument("--args", default="", help="arguments for the binary")
ap.add_argument("--caches", action="store_true", help="add L1/L2 caches")
args = ap.parse_args()

isa = {"riscv": ISA.RISCV, "x86": ISA.X86, "arm": ISA.ARM}[args.isa]
board = SimpleBoard(
    clk_freq="1GHz",
    processor=SimpleProcessor(
        cpu_type=CPUTypes[args.cpu.upper()],
        isa=isa,
        num_cores=1,
        clk_freq="1GHz",
    ),
    memory=SingleChannelDDR3_1600("1GiB"),
    cache_hierarchy=(
        PrivateL1PrivateL2CacheHierarchy(
            l1d_size="32KiB", l1i_size="32KiB", l2_size="256KiB"
        )
        if args.caches
        else NoCache()
    ),
)

extra = {}
if args.sysroot:
    extra["loader_path"] = args.sysroot
    extra["redirect_paths"] = {
        "/lib": [f"{args.sysroot}/lib"],
        "/usr/lib": [f"{args.sysroot}/usr/lib"],
    }
board.set_se_binary_workload(
    BinaryResource(local_path=args.binary),
    arguments=shlex.split(args.args),
    **extra,
)
Simulator(board=board).run()
