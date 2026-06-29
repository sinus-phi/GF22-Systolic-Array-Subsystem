"""Full GEMM cocotb testbench for every provided sw/gemm header.

This file is intentionally independent from test_subsystem_gemm_cocotb.py.
It is a heavier, opt-in verification target that runs every array_mode*.h
header through the APB-visible subsystem interface.

The RTL remains a tile engine, not a complete autonomous GEMM engine.  This
testbench therefore models the firmware loops around the RTL:

  * sweep N tiles,
  * sweep K tiles,
  * load one weight tile,
  * reuse that weight tile across all M-row batches,
  * read each raw 64-bit output tile,
  * accumulate K partial sums in Python,
  * add bias and cast to the header C_TYPE,
  * compare every final output element against the header golden array.

Run directly from the repository root:

    python src/ss_integration/testbench/cocotb/test_all_gemm_headers_full_cocotb.py
"""

from __future__ import annotations

import os
import re
import threading
import time
from dataclasses import dataclass
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


try:
    from cocotb_tools.runner import get_runner
except ModuleNotFoundError:
    get_runner = None

try:
    from find_libpython import find_libpython
except ModuleNotFoundError:
    find_libpython = None


OFF_CONTROL = 0x000
OFF_STATUS = 0x004
OFF_CONFIG = 0x008
OFF_ERROR_CODE = 0x010
OFF_OUTPUT_WORDS = 0x014
WEIGHT_BASE = 0x100
ACT_BASE = 0x200
OUTPUT_BASE = 0x400

CTRL_LOAD_WEIGHTS = 0x0000_0001
CTRL_RELEASE_OUTPUT = 0x0000_0002
CTRL_CLEAR_DONE = 0x0000_0004
CTRL_CLEAR_ERROR = 0x0000_0008
CTRL_SOFT_RESET = 0x0000_0010

DTYPE_INT4 = 0
DTYPE_INT8 = 1
DTYPE_INT16 = 2
DTYPE_INT32 = 3

PRECISION_NAME = {
    DTYPE_INT4: "INT4",
    DTYPE_INT8: "INT8",
    DTYPE_INT16: "INT16",
    DTYPE_INT32: "INT32",
}

PRECISION_WIDTH = {
    DTYPE_INT4: 4,
    DTYPE_INT8: 8,
    DTYPE_INT16: 16,
    DTYPE_INT32: 32,
}

BITS_TO_PRECISION = {
    4: DTYPE_INT4,
    8: DTYPE_INT8,
    16: DTYPE_INT16,
    32: DTYPE_INT32,
}

PH_IDLE = 0
PH_LOAD_WEIGHTS = 1
PH_BATCH_COMPUTE = 2
PH_DRAIN_WRITEBACK = 3
PH_ERROR = 4

PHASE_NAME = {
    PH_IDLE: "IDLE",
    PH_LOAD_WEIGHTS: "LOAD_WEIGHTS",
    PH_BATCH_COMPUTE: "BATCH_COMPUTE",
    PH_DRAIN_WRITEBACK: "DRAIN_WRITEBACK",
    PH_ERROR: "ERROR",
}

ARRAY_PEAK_MACS_PER_CYCLE = 64

REPO_ROOT = Path(__file__).resolve().parents[4]
GEMM_INCLUDE_DIR = REPO_ROOT / "sw" / "gemm" / "include"
BUILD_DIR = REPO_ROOT / "build" / "ss_integration_all_headers_cocotb"
BUILD_LOG = BUILD_DIR / "all_headers_full_gemm_build.log"
LOG_FILE = BUILD_DIR / "all_headers_full_gemm.log"
RESULTS_XML = BUILD_DIR / "all_headers_full_gemm.xml"


def _strip_c_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//.*?$", "", text, flags=re.M)


def parse_c_array(header: Path, name: str) -> list[int]:
    text = _strip_c_comments(header.read_text(encoding="utf-8"))
    match = re.search(rf"\b{name}\s*\[[^\]]*\]\s*=\s*\{{(.*?)\}};", text, flags=re.S)
    if not match:
        raise ValueError(f"array {name!r} not found in {header}")
    return [int(token, 0) for token in re.findall(r"[-+]?(?:0x[0-9a-fA-F]+|\d+)", match.group(1))]


def parse_c_define_int(header: Path, name: str) -> int:
    text = _strip_c_comments(header.read_text(encoding="utf-8"))
    match = re.search(rf"^\s*#define\s+{name}\s+(\d+)\s*$", text, flags=re.M)
    if not match:
        raise ValueError(f"#define {name} not found in {header}")
    return int(match.group(1), 10)


def parse_type_width(header: Path, macro: str) -> int:
    text = _strip_c_comments(header.read_text(encoding="utf-8"))
    match = re.search(rf"^\s*#define\s+{macro}\s+int(\d+)_t\s*$", text, flags=re.M)
    if not match:
        raise ValueError(f"#define {macro} int*_t not found in {header}")
    return int(match.group(1), 10)


def parse_precision_from_header_name(header: Path) -> tuple[int, int]:
    match = re.search(r"array_mode\d+_(\d+)b_(\d+)b_", header.name)
    if not match:
        raise ValueError(f"cannot infer precision from header name: {header.name}")
    return BITS_TO_PRECISION[int(match.group(1))], BITS_TO_PRECISION[int(match.group(2))]


def mask_to_width(value: int, width: int) -> int:
    return value & ((1 << width) - 1)


def sign_extend(value: int, width: int) -> int:
    value &= (1 << width) - 1
    sign = 1 << (width - 1)
    return value - (1 << width) if value & sign else value


def cast_signed(value: int, width: int) -> int:
    return sign_extend(value, width)


def elems_per_word(precision: int) -> int:
    return {DTYPE_INT4: 8, DTYPE_INT8: 4, DTYPE_INT16: 2, DTYPE_INT32: 1}[precision]


def signed_range_for_precision(precision: int) -> tuple[int, int]:
    width = PRECISION_WIDTH[precision]
    return -(1 << (width - 1)), (1 << (width - 1)) - 1


def pack_vector(values: list[int], precision: int, tile_k: int) -> list[int]:
    width = PRECISION_WIDTH[precision]
    epw = elems_per_word(precision)
    words: list[int] = []

    for base in range(0, tile_k, epw):
        word = 0
        for lane in range(epw):
            idx = base + lane
            if idx >= tile_k:
                break
            word |= mask_to_width(values[idx], width) << (lane * width)
        words.append(word & 0xFFFF_FFFF)

    return words


def make_cfg(act_precision: int, weight_precision: int, tile_m: int, tile_n: int, tile_k: int, batch_count: int) -> int:
    return (
        (act_precision & 0x3)
        | ((weight_precision & 0x3) << 2)
        | ((tile_m & 0x1F) << 4)
        | ((tile_n & 0x1F) << 9)
        | ((tile_k & 0x1F) << 14)
        | ((batch_count & 0x3F) << 19)
    )


def status_phase(status: int) -> int:
    return (status >> 7) & 0x7


def status_done(status: int) -> bool:
    return bool((status >> 2) & 0x1)


def status_weights_valid(status: int) -> bool:
    return bool((status >> 3) & 0x1)


def status_output_valid(status: int) -> bool:
    return bool((status >> 4) & 0x1)


def status_error(status: int) -> bool:
    return bool((status >> 1) & 0x1)


def status_overflow(status: int) -> bool:
    return bool((status >> 14) & 0x1)


def status_output_words(status: int) -> int:
    return (status >> 16) & 0xFF


def log_check(dut, header: str, item: str, expected, actual) -> bool:
    ok = expected == actual
    dut._log.info(
        "COCOTB_ALL_HEADER_CHECK,%s,%s,golden=%s,actual=%s,%s",
        header,
        item,
        expected,
        actual,
        "PASS" if ok else "FAIL",
    )
    return ok


@dataclass
class PerfReport:
    """Derived performance numbers for one measured region."""

    cycles: int
    useful_mac_ops: int
    output_elements: int
    effective_mac_per_cycle: float
    system_pe_utilization_pct: float
    sa_active_utilization_pct: float
    cycles_per_mac: float
    cycles_per_output: float


class PerfMonitor:
    """cocotb-side performance counter.

    This is intentionally testbench-only instrumentation.  It counts APB
    traffic from the BFM and, when the simulator exposes internal top-module
    signals, samples SA activity signals every clock edge.  RTL behavior and
    firmware-visible registers are not changed.
    """

    COUNTER_FIELDS = (
        "cycle",
        "apb_writes",
        "apb_reads",
        "apb_access_cycles",
        "apb_write_cycles",
        "apb_read_cycles",
        "apb_wait_cycles",
        "config_writes",
        "control_writes",
        "weight_writes",
        "activation_writes",
        "status_reads",
        "status_read_cycles",
        "output_reads",
        "output_read_cycles",
        "sa_en_cycles",
        "input_vector_cycles",
        "load_settle_cycles",
        "output_drain_cycles",
        "out_write_cycles",
        "output_valid_cycles",
    )

    def __init__(self, dut):
        self.dut = dut
        for field in self.COUNTER_FIELDS:
            setattr(self, field, 0)
        self.phase_cycles = [0 for _ in range(8)]
        self.visible_signals: set[str] = set()

    def _read_optional_int(self, name: str) -> int | None:
        try:
            value = int(getattr(self.dut, name).value)
        except (AttributeError, ValueError, TypeError):
            return None
        self.visible_signals.add(name)
        return value

    async def run(self):
        while True:
            await RisingEdge(self.dut.clk_i)
            self.cycle += 1

            phase = self._read_optional_int("phase")
            if phase is not None and 0 <= phase < len(self.phase_cycles):
                self.phase_cycles[phase] += 1

            if self._read_optional_int("sa_en"):
                self.sa_en_cycles += 1
            if self._read_optional_int("input_vector_valid"):
                self.input_vector_cycles += 1
            if self._read_optional_int("load_settle_active"):
                self.load_settle_cycles += 1
            if self._read_optional_int("output_drain_active"):
                self.output_drain_cycles += 1
            if self._read_optional_int("out_wr_en"):
                self.out_write_cycles += 1
            if self._read_optional_int("output_valid"):
                self.output_valid_cycles += 1

    def snapshot(self) -> dict[str, object]:
        snap = {field: getattr(self, field) for field in self.COUNTER_FIELDS}
        snap["phase_cycles"] = tuple(self.phase_cycles)
        return snap

    def delta(self, start: dict[str, object]) -> dict[str, object]:
        now = self.snapshot()
        diff = {
            field: int(now[field]) - int(start[field])
            for field in self.COUNTER_FIELDS
        }
        start_phase = start["phase_cycles"]
        now_phase = now["phase_cycles"]
        diff["phase_cycles"] = tuple(
            int(now_phase[idx]) - int(start_phase[idx])
            for idx in range(len(now_phase))
        )
        diff["visible_signals"] = "+".join(sorted(self.visible_signals)) or "none"
        return diff


def _classify_apb_addr(addr: int) -> str:
    if addr == OFF_CONFIG:
        return "config"
    if addr == OFF_CONTROL:
        return "control"
    if addr == OFF_STATUS:
        return "status"
    if WEIGHT_BASE <= addr < ACT_BASE:
        return "weight"
    if ACT_BASE <= addr < OUTPUT_BASE:
        return "activation"
    if addr >= OUTPUT_BASE:
        return "output"
    return "other"


def make_perf_report(metrics: dict[str, object], useful_mac_ops: int, output_elements: int) -> PerfReport:
    cycles = int(metrics.get("cycle", 0))
    sa_en_cycles = int(metrics.get("sa_en_cycles", 0))
    effective_mac_per_cycle = useful_mac_ops / cycles if cycles else 0.0
    system_pe_utilization_pct = (
        100.0 * useful_mac_ops / (ARRAY_PEAK_MACS_PER_CYCLE * cycles)
        if cycles else 0.0
    )
    sa_active_utilization_pct = (
        100.0 * useful_mac_ops / (ARRAY_PEAK_MACS_PER_CYCLE * sa_en_cycles)
        if sa_en_cycles else 0.0
    )
    cycles_per_mac = cycles / useful_mac_ops if useful_mac_ops else 0.0
    cycles_per_output = cycles / output_elements if output_elements else 0.0
    return PerfReport(
        cycles=cycles,
        useful_mac_ops=useful_mac_ops,
        output_elements=output_elements,
        effective_mac_per_cycle=effective_mac_per_cycle,
        system_pe_utilization_pct=system_pe_utilization_pct,
        sa_active_utilization_pct=sa_active_utilization_pct,
        cycles_per_mac=cycles_per_mac,
        cycles_per_output=cycles_per_output,
    )


def _fmt_float(value: float) -> str:
    return f"{value:.6f}"


class ApbMaster:
    def __init__(self, dut):
        self.dut = dut
        self.perf = PerfMonitor(dut)

    async def reset(self):
        self.dut.PADDR.value = 0
        self.dut.PENABLE.value = 0
        self.dut.PSEL.value = 0
        self.dut.PSTRB.value = 0
        self.dut.PWDATA.value = 0
        self.dut.PWRITE.value = 0
        self.dut.irq_en_i.value = 1
        self.dut.ss_ctrl_i.value = 0
        self.dut.pmod_gpi.value = 0
        self.dut.rst_ni.value = 0
        for _ in range(4):
            await RisingEdge(self.dut.clk_i)
        self.dut.rst_ni.value = 1
        for _ in range(2):
            await RisingEdge(self.dut.clk_i)

    async def write(self, addr: int, data: int, expect_error: bool = False, pstrb: int = 0xF):
        start_cycle = self.perf.cycle
        addr_class = _classify_apb_addr(addr)
        self.perf.apb_writes += 1
        if addr_class == "config":
            self.perf.config_writes += 1
        elif addr_class == "control":
            self.perf.control_writes += 1
        elif addr_class == "weight":
            self.perf.weight_writes += 1
        elif addr_class == "activation":
            self.perf.activation_writes += 1

        self.dut.PADDR.value = addr
        self.dut.PWDATA.value = data & 0xFFFF_FFFF
        self.dut.PSTRB.value = pstrb & 0xF
        self.dut.PWRITE.value = 1
        self.dut.PSEL.value = 1
        self.dut.PENABLE.value = 0
        await RisingEdge(self.dut.clk_i)

        self.dut.PENABLE.value = 1
        for _ in range(120):
            await Timer(1, unit="ps")
            if int(self.dut.PREADY.value):
                got_error = bool(int(self.dut.PSLVERR.value))
                assert got_error == expect_error, (
                    f"APB write 0x{addr:03x}=0x{data:08x} PSLVERR={got_error}, "
                    f"expected {expect_error}"
                )
                self.dut.PSEL.value = 0
                self.dut.PENABLE.value = 0
                self.dut.PWRITE.value = 0
                self.dut.PSTRB.value = 0
                self.dut.PWDATA.value = 0
                await RisingEdge(self.dut.clk_i)
                elapsed = self.perf.cycle - start_cycle
                self.perf.apb_access_cycles += elapsed
                self.perf.apb_write_cycles += elapsed
                return
            self.perf.apb_wait_cycles += 1
            await RisingEdge(self.dut.clk_i)
        raise TimeoutError(f"APB write timed out at 0x{addr:03x}")

    async def read(self, addr: int, expect_error: bool = False) -> int:
        start_cycle = self.perf.cycle
        addr_class = _classify_apb_addr(addr)
        self.perf.apb_reads += 1
        if addr_class == "status":
            self.perf.status_reads += 1
        elif addr_class == "output":
            self.perf.output_reads += 1

        self.dut.PADDR.value = addr
        self.dut.PSTRB.value = 0
        self.dut.PWRITE.value = 0
        self.dut.PSEL.value = 1
        self.dut.PENABLE.value = 0
        await RisingEdge(self.dut.clk_i)

        self.dut.PENABLE.value = 1
        for _ in range(120):
            await Timer(1, unit="ps")
            if int(self.dut.PREADY.value):
                got_error = bool(int(self.dut.PSLVERR.value))
                assert got_error == expect_error, (
                    f"APB read 0x{addr:03x} PSLVERR={got_error}, expected {expect_error}"
                )
                data = int(self.dut.PRDATA.value) & 0xFFFF_FFFF
                self.dut.PSEL.value = 0
                self.dut.PENABLE.value = 0
                self.dut.PSTRB.value = 0
                await RisingEdge(self.dut.clk_i)
                elapsed = self.perf.cycle - start_cycle
                self.perf.apb_access_cycles += elapsed
                self.perf.apb_read_cycles += elapsed
                if addr_class == "status":
                    self.perf.status_read_cycles += elapsed
                elif addr_class == "output":
                    self.perf.output_read_cycles += elapsed
                return data
            self.perf.apb_wait_cycles += 1
            await RisingEdge(self.dut.clk_i)
        raise TimeoutError(f"APB read timed out at 0x{addr:03x}")

    async def status(self) -> int:
        return await self.read(OFF_STATUS)

    async def wait_phase(self, phase: int, timeout_reads: int = 500) -> int:
        last = 0
        for _ in range(timeout_reads):
            last = await self.status()
            if status_phase(last) == phase:
                return last
        raise TimeoutError(f"phase {phase} not reached, last status=0x{last:08x}")

    async def wait_output_valid(self, timeout_reads: int = 800) -> int:
        last = 0
        for _ in range(timeout_reads):
            last = await self.status()
            if status_output_valid(last):
                return last
        raise TimeoutError(f"output_valid not reached, last status=0x{last:08x}")


async def start_clock_and_reset(dut) -> ApbMaster:
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    bus = ApbMaster(dut)
    cocotb.start_soon(bus.perf.run())
    await bus.reset()
    return bus


async def stream_weight_tile(bus: ApbMaster, weights: list[list[int]], weight_precision: int, tile_n: int, tile_k: int):
    for n in range(tile_n):
        for word in pack_vector(weights[n], weight_precision, tile_k):
            await bus.write(WEIGHT_BASE, word)


async def stream_activation_tile(bus: ApbMaster, acts: list[list[int]], act_precision: int, tile_m: int, tile_k: int):
    for m in range(tile_m):
        for word in pack_vector(acts[m], act_precision, tile_k):
            await bus.write(ACT_BASE, word)


async def read_output_tile(bus: ApbMaster, tile_m: int, tile_n: int) -> list[list[int]]:
    """Copy the compact output window before releasing the hardware buffer."""
    got = [[0 for _ in range(tile_n)] for _ in range(tile_m)]
    for m in range(tile_m):
        for n in range(tile_n):
            word_idx = ((m * tile_n) + n) * 2
            low = await bus.read(OUTPUT_BASE + word_idx * 4)
            high = await bus.read(OUTPUT_BASE + (word_idx + 1) * 4)
            got[m][n] = sign_extend(low | (high << 32), 64)
    return got


async def release_output(bus: ApbMaster):
    await bus.write(OFF_CONTROL, CTRL_RELEASE_OUTPUT | CTRL_CLEAR_DONE)


async def run_one_weight_stationary_tile(
    bus: ApbMaster,
    *,
    act_precision: int,
    weight_precision: int,
    weights: list[list[int]],
    activation_batches: list[list[list[int]]],
    tile_m: int,
    tile_n: int,
    tile_k: int,
):
    cfg = make_cfg(act_precision, weight_precision, tile_m, tile_n, tile_k, len(activation_batches))
    await bus.write(OFF_CONFIG, cfg)
    await bus.write(OFF_CONTROL, CTRL_LOAD_WEIGHTS)
    await bus.wait_phase(PH_LOAD_WEIGHTS)
    await stream_weight_tile(bus, weights, weight_precision, tile_n, tile_k)
    status = await bus.wait_phase(PH_BATCH_COMPUTE)
    assert status_weights_valid(status), f"weights_valid did not rise, status=0x{status:08x}"

    output_tiles: list[list[list[int]]] = []
    for batch_idx, acts in enumerate(activation_batches):
        await stream_activation_tile(bus, acts, act_precision, tile_m, tile_k)
        status = await bus.wait_output_valid()
        expected_words = tile_m * tile_n * 2
        assert status_output_words(status) == expected_words, (
            f"batch {batch_idx}: output_words={status_output_words(status)}, expected {expected_words}"
        )
        assert status_done(status), f"batch {batch_idx}: done_sticky missing"
        assert status_weights_valid(status), f"batch {batch_idx}: weights_valid dropped early"
        assert not status_error(status), f"batch {batch_idx}: error_sticky set, status=0x{status:08x}"
        assert not status_overflow(status), f"batch {batch_idx}: overflow_sticky set, status=0x{status:08x}"

        # Minimize the single-buffer output-valid stall: copy the result tile,
        # release immediately, and let software accumulation run on the copied
        # data after the next hardware batch can proceed.
        output_tiles.append(await read_output_tile(bus, tile_m, tile_n))
        await release_output(bus)

        if batch_idx + 1 < len(activation_batches):
            status = await bus.wait_phase(PH_BATCH_COMPUTE)
            assert status_weights_valid(status), "weights were not retained for next batch"
        else:
            await bus.wait_phase(PH_IDLE)

    return output_tiles


async def run_full_header(bus: ApbMaster, dut, header: Path) -> tuple[int, int, int, dict[str, object]]:
    header_perf_start = bus.perf.snapshot()
    act_precision, weight_precision = parse_precision_from_header_name(header)
    full_m = parse_c_define_int(header, "M_d")
    full_k = parse_c_define_int(header, "K_d")
    full_n = parse_c_define_int(header, "N_d")
    c_width = parse_type_width(header, "C_TYPE")
    a_full = parse_c_array(header, "input_unpacked")
    w_full = parse_c_array(header, "weights_unpacked")
    bias = parse_c_array(header, "bias")
    golden_literals = parse_c_array(header, "golden")
    golden_effective = [cast_signed(value, c_width) for value in golden_literals]
    act_min, act_max = min(a_full), max(a_full)
    weight_min, weight_max = min(w_full), max(w_full)
    act_legal_min, act_legal_max = signed_range_for_precision(act_precision)
    weight_legal_min, weight_legal_max = signed_range_for_precision(weight_precision)
    act_range_ok = act_legal_min <= act_min and act_max <= act_legal_max
    weight_range_ok = weight_legal_min <= weight_min and weight_max <= weight_legal_max

    tile_m_max = 8
    tile_n_max = 8
    tile_k_max = 8

    if full_m % tile_m_max != 0 or full_n % tile_n_max != 0 or full_k % tile_k_max != 0:
        raise ValueError(
            f"{header.name}: this full-header test expects dimensions to be multiples of 8"
        )

    await bus.write(OFF_CONTROL, CTRL_SOFT_RESET | CTRL_CLEAR_DONE | CTRL_CLEAR_ERROR)
    await bus.wait_phase(PH_IDLE)

    raw_accum = [[0 for _ in range(full_n)] for _ in range(full_m)]
    transactions = 0
    output_tile_count = 0

    dut._log.info(
        "COCOTB_ALL_HEADER_BEGIN,%s,act=%s,weight=%s,C_WIDTH=%d,M=%d,K=%d,N=%d,"
        "act_range=%d:%d,weight_range=%d:%d,weight_range_ok=%s",
        header.name,
        PRECISION_NAME[act_precision],
        PRECISION_NAME[weight_precision],
        c_width,
        full_m,
        full_k,
        full_n,
        act_min,
        act_max,
        weight_min,
        weight_max,
        act_range_ok and weight_range_ok,
    )

    for n_base in range(0, full_n, tile_n_max):
        tile_n = min(tile_n_max, full_n - n_base)
        for k_base in range(0, full_k, tile_k_max):
            tile_k = min(tile_k_max, full_k - k_base)
            weights = [
                [w_full[(n_base + n) * full_k + k_base + k] for k in range(tile_k)]
                for n in range(tile_n)
            ]
            row_bases = list(range(0, full_m, tile_m_max))
            activation_batches = [
                [
                    [a_full[(row_base + m) * full_k + k_base + k] for k in range(tile_k)]
                    for m in range(tile_m_max)
                ]
                for row_base in row_bases
            ]

            txn_perf_start = bus.perf.snapshot()
            output_tile_data = await run_one_weight_stationary_tile(
                bus,
                act_precision=act_precision,
                weight_precision=weight_precision,
                weights=weights,
                activation_batches=activation_batches,
                tile_m=tile_m_max,
                tile_n=tile_n,
                tile_k=tile_k,
            )
            txn_metrics = bus.perf.delta(txn_perf_start)
            txn_useful_ops = tile_m_max * len(activation_batches) * tile_n * tile_k
            txn_output_elements = tile_m_max * len(activation_batches) * tile_n
            txn_perf = make_perf_report(txn_metrics, txn_useful_ops, txn_output_elements)

            for batch_idx, row_base in enumerate(row_bases):
                got = output_tile_data[batch_idx]
                for m in range(tile_m_max):
                    for n in range(tile_n):
                        raw_accum[row_base + m][n_base + n] += got[m][n]

            transactions += 1
            output_tile_count += len(activation_batches)
            dut._log.info(
                "COCOTB_ALL_HEADER_TXN,%s,n_base=%d,k_base=%d,tile_m=%d,tile_n=%d,tile_k=%d,batches=%d,"
                "cycles=%d,useful_mac_ops=%d,effective_mac_per_cycle=%s,"
                "system_pe_utilization_pct=%s,sa_active_utilization_pct=%s,"
                "apb_writes=%d,apb_reads=%d,status_reads=%d,output_reads=%d,"
                "apb_wait_cycles=%d,sa_en_cycles=%d,input_vector_cycles=%d,"
                "load_settle_cycles=%d,output_drain_cycles=%d,out_write_cycles=%d,PASS",
                header.name,
                n_base,
                k_base,
                tile_m_max,
                tile_n,
                tile_k,
                len(activation_batches),
                txn_perf.cycles,
                txn_perf.useful_mac_ops,
                _fmt_float(txn_perf.effective_mac_per_cycle),
                _fmt_float(txn_perf.system_pe_utilization_pct),
                _fmt_float(txn_perf.sa_active_utilization_pct),
                txn_metrics["apb_writes"],
                txn_metrics["apb_reads"],
                txn_metrics["status_reads"],
                txn_metrics["output_reads"],
                txn_metrics["apb_wait_cycles"],
                txn_metrics["sa_en_cycles"],
                txn_metrics["input_vector_cycles"],
                txn_metrics["load_settle_cycles"],
                txn_metrics["output_drain_cycles"],
                txn_metrics["out_write_cycles"],
            )

    mismatches = 0
    total = full_m * full_n
    for m in range(full_m):
        for n in range(full_n):
            actual = cast_signed(raw_accum[m][n] + bias[n], c_width)
            expected = golden_effective[m * full_n + n]
            if not log_check(dut, header.name, f"final_m{m}_n{n}", expected, actual):
                mismatches += 1

    header_metrics = bus.perf.delta(header_perf_start)
    useful_mac_ops = full_m * full_n * full_k
    header_perf = make_perf_report(header_metrics, useful_mac_ops, total)
    phase_cycles = header_metrics["phase_cycles"]
    weight_reuse_factor = (output_tile_count / transactions) if transactions else 0.0

    dut._log.info(
        "COCOTB_ALL_HEADER_SUMMARY,%s,act=%s,weight=%s,C_WIDTH=%d,M=%d,K=%d,N=%d,"
        "act_range=%d:%d,act_range_ok=%s,weight_range=%d:%d,weight_range_ok=%s,"
        "transactions=%d,output_tiles=%d,weight_reuse_factor=%s,total=%d,matched=%d,mismatches=%d,"
        "cycles=%d,useful_mac_ops=%d,effective_mac_per_cycle=%s,"
        "system_pe_utilization_pct=%s,sa_active_utilization_pct=%s,"
        "cycles_per_mac=%s,cycles_per_output=%s,"
        "apb_writes=%d,apb_reads=%d,apb_access_cycles=%d,apb_write_cycles=%d,apb_read_cycles=%d,"
        "apb_wait_cycles=%d,config_writes=%d,control_writes=%d,weight_writes=%d,"
        "activation_writes=%d,status_reads=%d,status_read_cycles=%d,output_reads=%d,output_read_cycles=%d,"
        "sa_en_cycles=%d,input_vector_cycles=%d,load_settle_cycles=%d,output_drain_cycles=%d,"
        "out_write_cycles=%d,output_valid_cycles=%d,"
        "phase_idle_cycles=%d,phase_load_cycles=%d,phase_batch_cycles=%d,phase_drain_cycles=%d,"
        "phase_error_cycles=%d,visible_signals=%s,%s",
        header.name,
        PRECISION_NAME[act_precision],
        PRECISION_NAME[weight_precision],
        c_width,
        full_m,
        full_k,
        full_n,
        act_min,
        act_max,
        act_range_ok,
        weight_min,
        weight_max,
        weight_range_ok,
        transactions,
        output_tile_count,
        _fmt_float(weight_reuse_factor),
        total,
        total - mismatches,
        mismatches,
        header_perf.cycles,
        header_perf.useful_mac_ops,
        _fmt_float(header_perf.effective_mac_per_cycle),
        _fmt_float(header_perf.system_pe_utilization_pct),
        _fmt_float(header_perf.sa_active_utilization_pct),
        _fmt_float(header_perf.cycles_per_mac),
        _fmt_float(header_perf.cycles_per_output),
        header_metrics["apb_writes"],
        header_metrics["apb_reads"],
        header_metrics["apb_access_cycles"],
        header_metrics["apb_write_cycles"],
        header_metrics["apb_read_cycles"],
        header_metrics["apb_wait_cycles"],
        header_metrics["config_writes"],
        header_metrics["control_writes"],
        header_metrics["weight_writes"],
        header_metrics["activation_writes"],
        header_metrics["status_reads"],
        header_metrics["status_read_cycles"],
        header_metrics["output_reads"],
        header_metrics["output_read_cycles"],
        header_metrics["sa_en_cycles"],
        header_metrics["input_vector_cycles"],
        header_metrics["load_settle_cycles"],
        header_metrics["output_drain_cycles"],
        header_metrics["out_write_cycles"],
        header_metrics["output_valid_cycles"],
        phase_cycles[PH_IDLE],
        phase_cycles[PH_LOAD_WEIGHTS],
        phase_cycles[PH_BATCH_COMPUTE],
        phase_cycles[PH_DRAIN_WRITEBACK],
        phase_cycles[PH_ERROR],
        header_metrics["visible_signals"],
        "PASS" if mismatches == 0 else "FAIL",
    )
    return total, mismatches, useful_mac_ops, header_metrics


@cocotb.test()
async def test_all_gemm_headers_full_matrix(dut):
    bus = await start_clock_and_reset(dut)
    full_perf_start = bus.perf.snapshot()

    header_glob = os.getenv("ALL_HEADERS_GLOB", "array_mode*.h")
    headers = sorted(GEMM_INCLUDE_DIR.glob(header_glob))
    if not headers:
        raise FileNotFoundError(f"no headers matched {header_glob!r} under {GEMM_INCLUDE_DIR}")

    total_values = 0
    total_mismatches = 0
    total_useful_mac_ops = 0
    failed_headers: list[str] = []

    for header in headers:
        header_total, header_mismatches, header_useful_ops, _ = await run_full_header(bus, dut, header)
        total_values += header_total
        total_mismatches += header_mismatches
        total_useful_mac_ops += header_useful_ops
        if header_mismatches:
            failed_headers.append(header.name)

    full_metrics = bus.perf.delta(full_perf_start)
    full_perf = make_perf_report(full_metrics, total_useful_mac_ops, total_values)
    dut._log.info(
        "COCOTB_ALL_HEADERS_FINAL,headers=%d,total=%d,matched=%d,mismatches=%d,"
        "cycles=%d,useful_mac_ops=%d,effective_mac_per_cycle=%s,"
        "system_pe_utilization_pct=%s,sa_active_utilization_pct=%s,"
        "cycles_per_mac=%s,cycles_per_output=%s,"
        "apb_writes=%d,apb_reads=%d,apb_wait_cycles=%d,status_reads=%d,output_reads=%d,"
        "sa_en_cycles=%d,input_vector_cycles=%d,load_settle_cycles=%d,output_drain_cycles=%d,"
        "out_write_cycles=%d,failed_headers=%s,%s",
        len(headers),
        total_values,
        total_values - total_mismatches,
        total_mismatches,
        full_perf.cycles,
        full_perf.useful_mac_ops,
        _fmt_float(full_perf.effective_mac_per_cycle),
        _fmt_float(full_perf.system_pe_utilization_pct),
        _fmt_float(full_perf.sa_active_utilization_pct),
        _fmt_float(full_perf.cycles_per_mac),
        _fmt_float(full_perf.cycles_per_output),
        full_metrics["apb_writes"],
        full_metrics["apb_reads"],
        full_metrics["apb_wait_cycles"],
        full_metrics["status_reads"],
        full_metrics["output_reads"],
        full_metrics["sa_en_cycles"],
        full_metrics["input_vector_cycles"],
        full_metrics["load_settle_cycles"],
        full_metrics["output_drain_cycles"],
        full_metrics["out_write_cycles"],
        ";".join(failed_headers) if failed_headers else "none",
        "PASS" if total_mismatches == 0 else "FAIL",
    )
    assert total_mismatches == 0, f"full-header GEMM mismatches: {failed_headers}"


def _separator(char: str = "=", width: int = 92) -> str:
    return char * width


def _parse_key_value_payload(payload: str) -> dict[str, str]:
    fields = payload.split(",")
    info = {"header": fields[0]}
    for field in fields[1:]:
        key, _, value = field.partition("=")
        if value:
            info[key] = value
        else:
            info["result"] = key
    return info


class RealtimeHeaderProgress:
    """Print one terminal update whenever a header summary reaches the log.

    cocotb runner writes simulator output to LOG_FILE.  Tailing that file avoids
    changing the RTL or relying on simulator-specific stdout behavior, while
    still giving live progress for long all-header runs.
    """

    def __init__(self, log_path: Path):
        self.log_path = log_path
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._seen_headers: set[str] = set()
        self._final_seen = False

    def start(self):
        if os.getenv("ALL_HEADERS_REALTIME", "1") == "0":
            return
        print()
        print(_separator())
        print("Live all-header GEMM progress")
        print(_separator())
        print("A one-line update is printed as soon as each header completes.")
        print(_separator("-"))
        self._thread = threading.Thread(target=self._run, name="all-header-log-tail", daemon=True)
        self._thread.start()

    def stop(self):
        if self._thread is None:
            return
        self._stop.set()
        self._thread.join(timeout=3.0)
        self._thread = None

    def _run(self):
        offset = 0
        pending = ""
        while not self._stop.is_set():
            offset, pending = self._poll_once(offset, pending)
            time.sleep(0.25)
        # One last read catches the final summary if the simulator exits just
        # before the polling interval.
        self._poll_once(offset, pending, flush=True)

    def _poll_once(self, offset: int, pending: str, flush: bool = False) -> tuple[int, str]:
        if not self.log_path.exists():
            return offset, pending

        try:
            with self.log_path.open("r", encoding="utf-8", errors="replace") as log_file:
                log_file.seek(offset)
                chunk = log_file.read()
                offset = log_file.tell()
        except OSError:
            return offset, pending

        if not chunk and not flush:
            return offset, pending

        pending += chunk
        if not pending:
            return offset, pending

        lines = pending.splitlines(keepends=True)
        if lines and not lines[-1].endswith(("\n", "\r")) and not flush:
            pending = lines.pop()
        else:
            pending = ""

        for line in lines:
            self._handle_line(line)
        return offset, pending

    def _handle_line(self, line: str):
        if "COCOTB_ALL_HEADER_SUMMARY," in line:
            payload = line.split("COCOTB_ALL_HEADER_SUMMARY,", 1)[1].strip()
            info = _parse_key_value_payload(payload)
            header = info["header"]
            if header in self._seen_headers:
                return
            self._seen_headers.add(header)
            idx = len(self._seen_headers)
            result = info.get("result", "UNKNOWN")
            print(
                f"[LIVE {idx:02d}] {header}: {result} | "
                f"matched={info.get('matched')}/{info.get('total')} "
                f"mismatches={info.get('mismatches')} | "
                f"cycles={info.get('cycles')} "
                f"eff_mac/cycle={info.get('effective_mac_per_cycle')} "
                f"system_util={info.get('system_pe_utilization_pct')}% | "
                f"wait={info.get('apb_wait_cycles')} "
                f"reuse={info.get('weight_reuse_factor')}",
                flush=True,
            )

        elif "COCOTB_ALL_HEADERS_FINAL," in line and not self._final_seen:
            self._final_seen = True
            payload = line.split("COCOTB_ALL_HEADERS_FINAL,", 1)[1].strip()
            info = _parse_key_value_payload(f"final,{payload}")
            print(_separator("-"), flush=True)
            print(
                "LIVE FINAL: "
                f"headers={info.get('headers')} "
                f"matched={info.get('matched')}/{info.get('total')} "
                f"mismatches={info.get('mismatches')} "
                f"cycles={info.get('cycles')} "
                f"system_util={info.get('system_pe_utilization_pct')}% "
                f"failed={info.get('failed_headers')} "
                f"{info.get('result', 'UNKNOWN')}",
                flush=True,
            )
            print(_separator(), flush=True)


def _parse_summary_log():
    summaries: list[dict[str, str]] = []
    samples: dict[str, dict[str, list[dict[str, str]]]] = {}
    final_line: str | None = None
    total_line: str | None = None

    if not LOG_FILE.exists():
        return summaries, samples, final_line, total_line

    sample_limit = int(os.getenv("ALL_HEADERS_SUMMARY_VALUES", "8"))
    print_all = os.getenv("ALL_HEADERS_PRINT_ALL_VALUES", "0") == "1"

    for line in LOG_FILE.read_text(encoding="utf-8", errors="replace").splitlines():
        if "COCOTB_ALL_HEADER_CHECK," in line:
            payload = line.split("COCOTB_ALL_HEADER_CHECK,", 1)[1]
            fields = payload.split(",")
            if len(fields) < 5:
                continue
            header = fields[0]
            item = fields[1]
            golden = fields[2].replace("golden=", "", 1)
            actual = fields[3].replace("actual=", "", 1)
            result = fields[4]
            buckets = samples.setdefault(header, {"pass": [], "fail": []})
            bucket_name = "pass" if result == "PASS" else "fail"
            bucket = buckets[bucket_name]
            if print_all or len(bucket) < sample_limit:
                bucket.append(
                    {
                        "item": item,
                        "golden": golden,
                        "actual": actual,
                        "result": result,
                    }
                )
        elif "COCOTB_ALL_HEADER_SUMMARY," in line:
            payload = line.split("COCOTB_ALL_HEADER_SUMMARY,", 1)[1]
            summaries.append(_parse_key_value_payload(payload))
        elif "COCOTB_ALL_HEADERS_FINAL," in line:
            final_line = line.split("COCOTB_ALL_HEADERS_FINAL,", 1)[1]
        elif "TESTS=" in line:
            total_line = line.strip(" *")

    return summaries, samples, final_line, total_line


def print_human_summary() -> bool:
    summaries, samples, final_line, total_line = _parse_summary_log()
    all_pass = bool(summaries)

    print()
    print(_separator())
    print("All GEMM headers full-matrix cocotb verification summary")
    print(_separator())
    print(f"Build log : {BUILD_LOG}")
    print(f"Run log   : {LOG_FILE}")
    print(f"Results   : {RESULTS_XML}")
    if total_line:
        print(f"cocotb    : {total_line}")
    print(_separator("-"))

    for idx, info in enumerate(summaries, start=1):
        header = info["header"]
        result = info.get("result", "UNKNOWN")
        mismatches = info.get("mismatches", "?")
        matched = info.get("matched", "?")
        total = info.get("total", "?")
        all_pass = all_pass and result == "PASS" and mismatches == "0"

        print(f"[{idx}] {header}")
        print(
            "Config  : "
            f"act={info.get('act')}, weight={info.get('weight')}, "
            f"C_WIDTH={info.get('C_WIDTH')}, "
            f"M={info.get('M')}, K={info.get('K')}, N={info.get('N')}, "
            f"transactions={info.get('transactions')}, "
            f"output_tiles={info.get('output_tiles')}, "
            f"weight_reuse={info.get('weight_reuse_factor')}"
        )
        print(
            "Ranges  : "
            f"act={info.get('act_range')} ok={info.get('act_range_ok')}, "
            f"weight={info.get('weight_range')} ok={info.get('weight_range_ok')}"
        )
        print(
            "Cycles  : "
            f"total={info.get('cycles')}, "
            f"sa_en={info.get('sa_en_cycles')}, "
            f"wait={info.get('apb_wait_cycles')}, "
            f"output_read={info.get('output_read_cycles')}"
        )
        print(
            "Traffic : "
            f"writes={info.get('apb_writes')} "
            f"(cfg={info.get('config_writes')}, ctrl={info.get('control_writes')}, "
            f"weight={info.get('weight_writes')}, act={info.get('activation_writes')}), "
            f"reads={info.get('apb_reads')} "
            f"(status={info.get('status_reads')}, output={info.get('output_reads')})"
        )
        print(
            "Perf    : "
            f"useful_mac_ops={info.get('useful_mac_ops')}, "
            f"eff_mac/cycle={info.get('effective_mac_per_cycle')}, "
            f"system_util={info.get('system_pe_utilization_pct')}%, "
            f"sa_active_util={info.get('sa_active_utilization_pct')}%, "
            f"cycles/mac={info.get('cycles_per_mac')}, "
            f"cycles/output={info.get('cycles_per_output')}"
        )
        print(
            "Activity: "
            f"phase_idle={info.get('phase_idle_cycles')}, "
            f"load={info.get('phase_load_cycles')}, "
            f"batch={info.get('phase_batch_cycles')}, "
            f"drain={info.get('phase_drain_cycles')}, "
            f"error={info.get('phase_error_cycles')}, "
            f"visible={info.get('visible_signals')}"
        )
        print(f"Result  : {result} ({matched}/{total} matched, mismatches={mismatches})")
        header_samples = samples.get(header, {"pass": [], "fail": []})
        selected_samples = header_samples["fail"] or header_samples["pass"]
        label = "mismatch samples" if header_samples["fail"] else "golden/RTL samples"
        print(f"Golden/RTL {label}:")
        for sample in selected_samples:
            print(
                f"  [{sample['result']:<4}] {sample['item']}: "
                f"golden={sample['golden']} actual={sample['actual']}"
            )
        print(_separator("-"))

    if final_line:
        print(f"Final   : {final_line}")
    print(f"FINAL_RESULT: {'PASS' if all_pass else 'FAIL'}")
    return all_pass


def main() -> None:
    if get_runner is None:
        raise SystemExit(
            "cocotb/cocotb_tools is not installed. Install it first: "
            "python -m pip install cocotb"
        )

    try:
        sim = os.getenv("SIM", "verilator")
        runner = get_runner(sim)
        sources = [
            REPO_ROOT / "src" / "ss_integration" / "subsystem_pkg.sv",
            REPO_ROOT / "src" / "ss_integration" / "subsystem_apb_if.sv",
            REPO_ROOT / "src" / "ss_integration" / "subsystem_addr_decoder.sv",
            REPO_ROOT / "src" / "ss_integration" / "subsystem_regbank.sv",
            REPO_ROOT / "src" / "ss_integration" / "subsystem_sa_ctrl.sv",
            REPO_ROOT / "src" / "ss_integration" / "subsystem_input_frontend.sv",
            REPO_ROOT / "src" / "ss_integration" / "subsystem_pe.sv",
            REPO_ROOT / "src" / "ss_integration" / "subsystem_sa.sv",
            REPO_ROOT / "src" / "ss_integration" / "subsystem_output_buffer.sv",
            REPO_ROOT / "src" / "ss_integration" / "subsystem_topmodule.sv",
        ]

        build_args: list[str] = []
        if sim == "icarus":
            build_args.append("-g2012")
        elif sim == "verilator":
            build_args.append("-Wno-fatal")
            # Performance reporting samples internal top-module activity
            # signals such as sa_en and output_drain_active.  This option keeps
            # those signals visible to cocotb without adding RTL perf counters.
            build_args.append("--public-flat-rw")

        runner.build(
            hdl_library="work",
            sources=sources,
            hdl_toplevel="subsystem_topmodule",
            build_dir=BUILD_DIR,
            always=True,
            clean=True,
            build_args=build_args,
            timescale=("1ns", "1ps"),
            waves=bool(int(os.getenv("WAVES", "0"))),
            verbose=bool(int(os.getenv("VERBOSE", "0"))),
            log_file=str(BUILD_LOG),
        )

        extra_env = {
            "PYTHONPATH": str(Path(__file__).resolve().parent)
            + os.pathsep
            + os.environ.get("PYTHONPATH", ""),
        }
        for name in (
            "ALL_HEADERS_GLOB",
            "ALL_HEADERS_SUMMARY_VALUES",
            "ALL_HEADERS_PRINT_ALL_VALUES",
        ):
            if name in os.environ:
                extra_env[name] = os.environ[name]
        if find_libpython is not None:
            libpython = find_libpython()
            if libpython:
                extra_env["LIBPYTHON_LOC"] = libpython
        os.environ.update(extra_env)

        try:
            LOG_FILE.unlink(missing_ok=True)
        except OSError:
            pass

        live_progress = RealtimeHeaderProgress(LOG_FILE)
        live_progress.start()
        try:
            runner.test(
                hdl_toplevel="subsystem_topmodule",
                hdl_toplevel_library="work",
                test_module=Path(__file__).stem,
                test_dir=BUILD_DIR,
                build_dir=BUILD_DIR,
                results_xml=str(RESULTS_XML),
                log_file=str(LOG_FILE),
                extra_env=extra_env,
                waves=bool(int(os.getenv("WAVES", "0"))),
                verbose=bool(int(os.getenv("VERBOSE", "0"))),
            )
        finally:
            live_progress.stop()
    except SystemExit:
        if LOG_FILE.exists():
            print_human_summary()
        raise
    except Exception as exc:
        print(f"all-header cocotb runner failed: {exc}")
        print(f"Build log: {BUILD_LOG}")
        print(f"Run log  : {LOG_FILE}")
        print("FINAL_RESULT: FAIL")
        raise SystemExit(1) from exc

    if not print_human_summary():
        raise SystemExit(1)


if __name__ == "__main__":
    main()
