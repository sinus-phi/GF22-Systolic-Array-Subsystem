"""cocotb APB functional tests for the integrated SA subsystem.

The tests intentionally model firmware behavior rather than probing internal
signals.  They use the same GEMM interpretation as sw/gemm/gemm.c:

    C[i, n] = sum_k A[i, k] * W[n, k]

The current RTL returns the raw 64-bit accumulator tile.  Bias addition, final
C_TYPE casting, and full 32x32 tiling remain firmware responsibilities, so they
are not included in the expected hardware result here.
"""

from __future__ import annotations

import os
import random
import re
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


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

PH_IDLE = 0
PH_LOAD_WEIGHTS = 1
PH_BATCH_COMPUTE = 2
PH_DRAIN_WRITEBACK = 3
PH_ERROR = 4

REPO_ROOT = Path(__file__).resolve().parents[4]
GEMM_INCLUDE_DIR = REPO_ROOT / "sw" / "gemm" / "include"

BITS_TO_PRECISION = {
    4: DTYPE_INT4,
    8: DTYPE_INT8,
    16: DTYPE_INT16,
    32: DTYPE_INT32,
}


def log_check(dut, case: str, item: str, expected, actual):
    """Emit one stable PASS/FAIL line and assert on mismatch.

    The CSV-like prefix is intentional: it lets us quickly grep the cocotb log
    for exactly what behavior was tested and which expected/actual value was
    observed.
    """
    ok = emit_check(dut, case, item, expected, actual)
    assert ok, f"{case}: {item}: expected={expected}, actual={actual}"


def emit_check(dut, case: str, item: str, expected, actual) -> bool:
    """Emit a PASS/FAIL line and return the result without stopping the test.

    Full-matrix tests use this helper so all mismatching elements can be printed
    before the final assertion.  Smaller control checks still use log_check().
    """
    ok = expected == actual
    dut._log.info(
        "COCOTB_CHECK,%s,%s,expected=%s,actual=%s,%s",
        case,
        item,
        expected,
        actual,
        "PASS" if ok else "FAIL",
    )
    return ok


def log_case(dut, case: str, result: str = "PASS"):
    dut._log.info("COCOTB_CASE,%s,%s", case, result)


def _strip_c_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//.*?$", "", text, flags=re.M)


def parse_c_array(header: Path, name: str) -> list[int]:
    """Parse a simple integer C array from one of the provided GEMM headers."""
    text = _strip_c_comments(header.read_text(encoding="utf-8"))
    match = re.search(rf"\b{name}\s*\[[^\]]*\]\s*=\s*\{{(.*?)\}};", text, flags=re.S)
    if not match:
        raise ValueError(f"array {name!r} not found in {header}")
    return [int(token, 0) for token in re.findall(r"[-+]?(?:0x[0-9a-fA-F]+|\d+)", match.group(1))]


def parse_c_define_int(header: Path, name: str) -> int:
    """Read integer defines such as M_d/K_d/N_d from a GEMM header."""
    text = _strip_c_comments(header.read_text(encoding="utf-8"))
    match = re.search(rf"^\s*#define\s+{name}\s+(\d+)\s*$", text, flags=re.M)
    if not match:
        raise ValueError(f"#define {name} not found in {header}")
    return int(match.group(1), 10)


def parse_precision_from_header_name(header: Path) -> tuple[int, int]:
    """Infer activation/weight precision from names like array_mode8_16b_4b_...h."""
    match = re.search(r"array_mode\d+_(\d+)b_(\d+)b_", header.name)
    if not match:
        raise ValueError(f"cannot infer precision from header name: {header.name}")

    act_bits = int(match.group(1), 10)
    weight_bits = int(match.group(2), 10)
    try:
        return BITS_TO_PRECISION[act_bits], BITS_TO_PRECISION[weight_bits]
    except KeyError as exc:
        raise ValueError(f"unsupported precision in header name: {header.name}") from exc


def resolve_gemm_header(token: str) -> Path:
    """Resolve a user-provided GEMM header token.

    Team members can pass either a full/relative path or just the basename under
    sw/gemm/include.  Keeping this resolution in the testbench lets the same
    cocotb flow be reused after swapping the active GEMM data header.
    """
    candidate = Path(token)
    if candidate.exists():
        return candidate.resolve()

    repo_relative = (REPO_ROOT / token).resolve()
    if repo_relative.exists():
        return repo_relative

    include_relative = (GEMM_INCLUDE_DIR / token).resolve()
    if include_relative.exists():
        return include_relative

    raise FileNotFoundError(f"GEMM header not found: {token}")


def select_random_headers(rng: random.Random) -> list[Path]:
    """Return the headers used by the randomized regression.

    GEMM_HEADER accepts one or more comma/semicolon separated paths or basenames.
    If omitted, the test randomly samples from all provided sw/gemm headers.
    """
    requested = os.getenv("GEMM_HEADER", "").strip()
    if requested:
        tokens = [token.strip() for token in re.split(r"[;,]", requested) if token.strip()]
        return [resolve_gemm_header(token) for token in tokens]

    headers = sorted(GEMM_INCLUDE_DIR.glob("array_mode*.h"))
    if not headers:
        raise FileNotFoundError(f"no GEMM headers found under {GEMM_INCLUDE_DIR}")

    count = int(os.getenv("GEMM_RANDOM_HEADERS", "2"))
    count = max(1, min(count, len(headers)))
    return rng.sample(headers, count)


def sanitize_case_token(text: str) -> str:
    return re.sub(r"[^0-9A-Za-z_]+", "_", text)


def make_cfg(act_precision: int, weight_precision: int, tile_m: int, tile_n: int, tile_k: int, batch_count: int) -> int:
    return (
        (act_precision & 0x3)
        | ((weight_precision & 0x3) << 2)
        | ((tile_m & 0x1F) << 4)
        | ((tile_n & 0x1F) << 9)
        | ((tile_k & 0x1F) << 14)
        | ((batch_count & 0x3F) << 19)
    )


def elems_per_word(precision: int) -> int:
    return {DTYPE_INT4: 8, DTYPE_INT8: 4, DTYPE_INT16: 2, DTYPE_INT32: 1}[precision]


def mask_to_width(value: int, width: int) -> int:
    return value & ((1 << width) - 1)


def sign_extend(value: int, width: int) -> int:
    value &= (1 << width) - 1
    sign = 1 << (width - 1)
    return value - (1 << width) if value & sign else value


def cast_signed(value: int, width: int) -> int:
    """Model firmware's final signed integer cast for the C output type."""
    return sign_extend(value, width)


def pack_vector(values: list[int], precision: int, tile_k: int) -> list[int]:
    """Pack one K-vector into APB words exactly as firmware should stream it.

    Each logical weight column or activation row starts on a new APB word.  If
    tile_k does not fill the final word, high elements in that word are zero and
    are intentionally not reused for the next vector.
    """
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


def status_phase(status: int) -> int:
    return (status >> 7) & 0x7


def status_busy(status: int) -> bool:
    return bool(status & 0x1)


def status_error(status: int) -> bool:
    return bool((status >> 1) & 0x1)


def status_done(status: int) -> bool:
    return bool((status >> 2) & 0x1)


def status_weights_valid(status: int) -> bool:
    return bool((status >> 3) & 0x1)


def status_output_valid(status: int) -> bool:
    return bool((status >> 4) & 0x1)


def status_output_blocked(status: int) -> bool:
    return bool((status >> 6) & 0x1)


def status_overflow(status: int) -> bool:
    return bool((status >> 14) & 0x1)


def status_output_words(status: int) -> int:
    return (status >> 16) & 0xFF


def expected_tile(acts: list[list[int]], weights: list[list[int]], tile_m: int, tile_n: int, tile_k: int) -> list[list[int]]:
    """Return raw int64 accumulator values for one hardware tile.

    weights is indexed as W[n][k], matching sw/gemm/gemm.c.
    """
    out: list[list[int]] = []
    for m in range(tile_m):
        row: list[int] = []
        for n in range(tile_n):
            acc = 0
            for k in range(tile_k):
                acc += acts[m][k] * weights[n][k]
            row.append(acc)
        out.append(row)
    return out


def int64_to_words(value: int) -> tuple[int, int]:
    bits = value & ((1 << 64) - 1)
    return bits & 0xFFFF_FFFF, (bits >> 32) & 0xFFFF_FFFF


class ApbMaster:
    def __init__(self, dut):
        self.dut = dut

    async def reset(self):
        self.dut.PADDR.value = 0
        self.dut.PENABLE.value = 0
        self.dut.PSEL.value = 0
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

    async def write(self, addr: int, data: int, expect_error: bool = False):
        self.dut.PADDR.value = addr
        self.dut.PWDATA.value = data & 0xFFFF_FFFF
        self.dut.PWRITE.value = 1
        self.dut.PSEL.value = 1
        self.dut.PENABLE.value = 0
        await RisingEdge(self.dut.clk_i)

        self.dut.PENABLE.value = 1
        for _ in range(80):
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
                self.dut.PWDATA.value = 0
                await RisingEdge(self.dut.clk_i)
                return
            await RisingEdge(self.dut.clk_i)
        raise TimeoutError(f"APB write timed out at 0x{addr:03x}")

    async def read(self, addr: int, expect_error: bool = False) -> int:
        self.dut.PADDR.value = addr
        self.dut.PWRITE.value = 0
        self.dut.PSEL.value = 1
        self.dut.PENABLE.value = 0
        await RisingEdge(self.dut.clk_i)

        self.dut.PENABLE.value = 1
        for _ in range(80):
            await Timer(1, unit="ps")
            if int(self.dut.PREADY.value):
                got_error = bool(int(self.dut.PSLVERR.value))
                assert got_error == expect_error, (
                    f"APB read 0x{addr:03x} PSLVERR={got_error}, expected {expect_error}"
                )
                data = int(self.dut.PRDATA.value) & 0xFFFF_FFFF
                self.dut.PSEL.value = 0
                self.dut.PENABLE.value = 0
                await RisingEdge(self.dut.clk_i)
                return data
            await RisingEdge(self.dut.clk_i)
        raise TimeoutError(f"APB read timed out at 0x{addr:03x}")

    async def status(self) -> int:
        return await self.read(OFF_STATUS)

    async def wait_phase(self, phase: int, timeout_reads: int = 250) -> int:
        last = 0
        for _ in range(timeout_reads):
            last = await self.status()
            if status_phase(last) == phase:
                return last
        raise TimeoutError(f"phase {phase} not reached, last status=0x{last:08x}")

    async def wait_output_valid(self, timeout_reads: int = 500) -> int:
        last = 0
        for _ in range(timeout_reads):
            last = await self.status()
            if status_output_valid(last):
                return last
        raise TimeoutError(f"output_valid not reached, last status=0x{last:08x}")


async def start_clock_and_reset(dut) -> ApbMaster:
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    bus = ApbMaster(dut)
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
    """Copy the firmware-visible output window into a software scratch tile.

    Keep this helper side-effect free: the caller should issue release_output()
    immediately after the copy, then do reference comparison or accumulation on
    the scratch data while the next hardware batch is allowed to start.
    """
    got = [[0 for _ in range(tile_n)] for _ in range(tile_m)]
    for m in range(tile_m):
        for n in range(tile_n):
            word_idx = ((m * tile_n) + n) * 2
            low = await bus.read(OUTPUT_BASE + word_idx * 4)
            high = await bus.read(OUTPUT_BASE + (word_idx + 1) * 4)
            bits = low | (high << 32)
            got[m][n] = sign_extend(bits, 64)
    return got


async def release_output(bus: ApbMaster):
    await bus.write(OFF_CONTROL, CTRL_RELEASE_OUTPUT | CTRL_CLEAR_DONE)


async def run_weight_stationary_transaction(
    bus: ApbMaster,
    *,
    case_name: str,
    act_precision: int,
    weight_precision: int,
    weights: list[list[int]],
    activation_batches: list[list[list[int]]],
    tile_m: int,
    tile_n: int,
    tile_k: int,
    scenario_extra: dict[str, object] | None = None,
    log_value_checks: bool = True,
):
    cfg = make_cfg(act_precision, weight_precision, tile_m, tile_n, tile_k, len(activation_batches))
    scenario_fields = [
        f"act={PRECISION_NAME[act_precision]}",
        f"weight={PRECISION_NAME[weight_precision]}",
        f"tile_m={tile_m}",
        f"tile_n={tile_n}",
        f"tile_k={tile_k}",
        f"batches={len(activation_batches)}",
    ]
    if scenario_extra:
        scenario_fields.extend(f"{key}={value}" for key, value in scenario_extra.items())

    bus.dut._log.info(
        "COCOTB_SCENARIO,%s,%s",
        case_name,
        ",".join(scenario_fields),
    )
    await bus.write(OFF_CONFIG, cfg)
    await bus.write(OFF_CONTROL, CTRL_LOAD_WEIGHTS)
    await bus.wait_phase(PH_LOAD_WEIGHTS)

    await stream_weight_tile(bus, weights, weight_precision, tile_n, tile_k)
    status = await bus.wait_phase(PH_BATCH_COMPUTE)
    log_check(bus.dut, case_name, "weights_valid_after_load", True, status_weights_valid(status))

    output_tiles: list[list[list[int]]] = []

    for batch_idx, acts in enumerate(activation_batches):
        await stream_activation_tile(bus, acts, act_precision, tile_m, tile_k)
        status = await bus.wait_output_valid()

        expected_words = tile_m * tile_n * 2
        log_check(bus.dut, case_name, f"batch{batch_idx}_status_output_words", expected_words, status_output_words(status))
        log_check(bus.dut, case_name, f"batch{batch_idx}_done_sticky", True, status_done(status))
        log_check(bus.dut, case_name, f"batch{batch_idx}_weights_still_valid", True, status_weights_valid(status))
        log_check(bus.dut, case_name, f"batch{batch_idx}_error_sticky", False, status_error(status))
        log_check(bus.dut, case_name, f"batch{batch_idx}_overflow_sticky", False, status_overflow(status))

        # Output-valid is the starvation window for the current single-buffer
        # hardware. Copy the tile, release the buffer immediately, and defer
        # software/reference work until the next batch is allowed to run.
        got = await read_output_tile(bus, tile_m, tile_n)
        output_tiles.append(got)
        await release_output(bus)

        if batch_idx + 1 < len(activation_batches):
            status = await bus.wait_phase(PH_BATCH_COMPUTE)
            log_check(bus.dut, case_name, f"batch{batch_idx}_weights_valid_after_release", True, status_weights_valid(status))
            log_check(bus.dut, case_name, f"batch{batch_idx}_output_valid_after_release", False, status_output_valid(status))
        else:
            status = await bus.wait_phase(PH_IDLE)
            log_check(bus.dut, case_name, "weights_valid_after_final_release", False, status_weights_valid(status))
            log_check(bus.dut, case_name, "busy_after_final_release", False, status_busy(status))

    if log_value_checks:
        for batch_idx, (acts, got) in enumerate(zip(activation_batches, output_tiles)):
            exp = expected_tile(acts, weights, tile_m, tile_n, tile_k)
            for m in range(tile_m):
                for n in range(tile_n):
                    log_check(
                        bus.dut,
                        case_name,
                        f"batch{batch_idx}_out_m{m}_n{n}",
                        exp[m][n],
                        got[m][n],
                    )

    log_case(bus.dut, case_name)
    return output_tiles


@cocotb.test()
async def test_mode6_header_weight_stationary_three_batches(dut):
    """Use real sw/gemm mode6-style data: INT8 activations, INT4 weights."""
    bus = await start_clock_and_reset(dut)

    header = GEMM_INCLUDE_DIR / "array_mode6_8b_4b_32_32_32_sequential.h"
    a_full = parse_c_array(header, "input_unpacked")
    w_full = parse_c_array(header, "weights_unpacked")
    full_k = 32

    tile_m = 2
    tile_n = 4
    tile_k = 5
    row_bases = [0, 8, 16]

    weights = [
        [w_full[n * full_k + k] for k in range(tile_k)]
        for n in range(tile_n)
    ]
    activation_batches = [
        [
            [a_full[(row_base + m) * full_k + k] for k in range(tile_k)]
            for m in range(tile_m)
        ]
        for row_base in row_bases
    ]

    await run_weight_stationary_transaction(
        bus,
        case_name="mode6_header_int8xint4_three_batches",
        act_precision=DTYPE_INT8,
        weight_precision=DTYPE_INT4,
        weights=weights,
        activation_batches=activation_batches,
        tile_m=tile_m,
        tile_n=tile_n,
        tile_k=tile_k,
    )


@cocotb.test()
async def test_mode8_header_two_weight_tiles_firmware_accumulation(dut):
    """Exercise a real header across two K-tiles and firmware-style accumulation.

    A full 32x32x32 GEMM is intentionally not run as one hardware transaction:
    the RTL tile_k limit is 8, so firmware must issue multiple weight tiles and
    accumulate the returned partial sums.  This test proves that the same APB
    protocol can use two different weight tiles from one real GEMM header.
    """
    bus = await start_clock_and_reset(dut)

    header = GEMM_INCLUDE_DIR / "array_mode8_16b_4b_32_32_32_random.h"
    a_full = parse_c_array(header, "input_unpacked")
    w_full = parse_c_array(header, "weights_unpacked")
    full_k = 32

    tile_m = 2
    tile_n = 3
    tile_k = 8
    row_bases = [0, 6]
    k_offsets = [0, 8]

    accumulated = [
        [[0 for _ in range(tile_n)] for _ in range(tile_m)]
        for _ in row_bases
    ]

    for tile_idx, k_base in enumerate(k_offsets):
        weights = [
            [w_full[n * full_k + k_base + k] for k in range(tile_k)]
            for n in range(tile_n)
        ]
        activation_batches = [
            [
                [a_full[(row_base + m) * full_k + k_base + k] for k in range(tile_k)]
                for m in range(tile_m)
            ]
            for row_base in row_bases
        ]

        await run_weight_stationary_transaction(
            bus,
            case_name=f"mode8_header_k_tile_{tile_idx}_int16xint4",
            act_precision=DTYPE_INT16,
            weight_precision=DTYPE_INT4,
            weights=weights,
            activation_batches=activation_batches,
            tile_m=tile_m,
            tile_n=tile_n,
            tile_k=tile_k,
        )

        for batch_idx, acts in enumerate(activation_batches):
            partial = expected_tile(acts, weights, tile_m, tile_n, tile_k)
            for m in range(tile_m):
                for n in range(tile_n):
                    accumulated[batch_idx][m][n] += partial[m][n]

    for batch_idx, row_base in enumerate(row_bases):
        for m in range(tile_m):
            for n in range(tile_n):
                exp = 0
                for k in range(k_offsets[0], k_offsets[-1] + tile_k):
                    exp += a_full[(row_base + m) * full_k + k] * w_full[n * full_k + k]
                log_check(
                    dut,
                    "mode8_two_k_tiles_firmware_accumulation",
                    f"batch{batch_idx}_accum_m{m}_n{n}",
                    exp,
                    accumulated[batch_idx][m][n],
                )

    log_case(dut, "mode8_two_k_tiles_firmware_accumulation")


@cocotb.test()
async def test_reload_weights_between_transactions_changes_result(dut):
    """After final release, a new weight tile must replace the old one cleanly."""
    bus = await start_clock_and_reset(dut)

    acts = [
        [2, -1, 3, 1],
        [-3, 2, 0, 4],
    ]
    weights_a = [
        [1, 0, -2, 3],
        [-1, 2, 1, 0],
        [4, -3, 1, -2],
    ]
    weights_b = [
        [-2, 1, 0, 1],
        [3, -1, 2, -2],
        [0, 4, -3, 1],
    ]

    await run_weight_stationary_transaction(
        bus,
        case_name="reload_a_int4xint4",
        act_precision=DTYPE_INT4,
        weight_precision=DTYPE_INT4,
        weights=weights_a,
        activation_batches=[acts],
        tile_m=2,
        tile_n=3,
        tile_k=4,
    )

    # Start a completely new transaction and prove old weights are not reused.
    await run_weight_stationary_transaction(
        bus,
        case_name="reload_b_int4xint4",
        act_precision=DTYPE_INT4,
        weight_precision=DTYPE_INT4,
        weights=weights_b,
        activation_batches=[acts],
        tile_m=2,
        tile_n=3,
        tile_k=4,
    )

    assert expected_tile(acts, weights_a, 2, 3, 4) != expected_tile(acts, weights_b, 2, 3, 4)


@cocotb.test()
async def test_mixed_precision_small_sweep_and_short_k(dut):
    """Cover representative mixed-precision paths without running full 32x32 GEMM."""
    bus = await start_clock_and_reset(dut)

    cases = [
        # act_precision, weight_precision, tile_m, tile_n, tile_k, weights, activations
        (
            DTYPE_INT4,
            DTYPE_INT4,
            1,
            2,
            3,
            [[1, -2, 3], [-1, 2, -3]],
            [[[2, 1, -1]]],
        ),
        (
            DTYPE_INT16,
            DTYPE_INT8,
            2,
            2,
            5,
            [[7, -4, 3, 2, -1], [-3, 6, 1, -2, 4]],
            [
                [[100, -50, 25, -10, 5], [-80, 12, 7, 9, -4]],
                [[1, 2, 3, 4, 5], [-6, -5, -4, -3, -2]],
            ],
        ),
        (
            DTYPE_INT32,
            DTYPE_INT4,
            1,
            1,
            2,
            [[-8, 7]],
            [[[123456, -3]]],
        ),
    ]

    for idx, (act_p, weight_p, tile_m, tile_n, tile_k, weights, batches) in enumerate(cases):
        await run_weight_stationary_transaction(
            bus,
            case_name=f"mixed_precision_case_{idx}_{PRECISION_NAME[act_p]}x{PRECISION_NAME[weight_p]}",
            act_precision=act_p,
            weight_precision=weight_p,
            weights=weights,
            activation_batches=batches,
            tile_m=tile_m,
            tile_n=tile_n,
            tile_k=tile_k,
        )
        await bus.write(OFF_CONTROL, CTRL_SOFT_RESET | CTRL_CLEAR_DONE | CTRL_CLEAR_ERROR)
        status = await bus.wait_phase(PH_IDLE)
        assert not status_error(status), f"unexpected error after mixed case {idx}"


@cocotb.test()
async def test_randomized_sequences_from_gemm_headers(dut):
    """Randomly sample tile sequences from one or more sw/gemm headers.

    This test is intentionally data-driven.  A team member can replace the
    selected header without editing Python code:

        GEMM_HEADER=array_mode9_16b_8b_32_32_32_random.h
        GEMM_RANDOM_SEED=1234

    Each sampled sequence still follows the same firmware-visible protocol:
    load one weight tile, reuse it for one or more activation batches, read and
    release each output tile, then start the next randomized transaction.
    """
    bus = await start_clock_and_reset(dut)

    seed = int(os.getenv("GEMM_RANDOM_SEED", "20260521"))
    rng = random.Random(seed)
    headers = select_random_headers(rng)

    sequences_per_header = max(1, int(os.getenv("GEMM_RANDOM_CASES", "2")))
    max_tile_m = max(1, min(8, int(os.getenv("GEMM_RANDOM_MAX_TILE_M", "3"))))
    max_tile_n = max(1, min(8, int(os.getenv("GEMM_RANDOM_MAX_TILE_N", "4"))))
    max_tile_k = max(1, min(8, int(os.getenv("GEMM_RANDOM_MAX_TILE_K", "8"))))
    max_batches = max(1, int(os.getenv("GEMM_RANDOM_MAX_BATCHES", "3")))

    for header_idx, header in enumerate(headers):
        act_precision, weight_precision = parse_precision_from_header_name(header)
        full_m = parse_c_define_int(header, "M_d")
        full_k = parse_c_define_int(header, "K_d")
        full_n = parse_c_define_int(header, "N_d")
        a_full = parse_c_array(header, "input_unpacked")
        w_full = parse_c_array(header, "weights_unpacked")
        header_token = sanitize_case_token(header.stem)

        for seq_idx in range(sequences_per_header):
            tile_m = rng.randint(1, min(max_tile_m, full_m))
            tile_n = rng.randint(1, min(max_tile_n, full_n))
            tile_k = rng.randint(1, min(max_tile_k, full_k))
            k_base = rng.randint(0, full_k - tile_k)
            n_base = rng.randint(0, full_n - tile_n)

            row_start_candidates = list(range(0, full_m - tile_m + 1))
            batch_count = rng.randint(1, min(max_batches, len(row_start_candidates)))
            row_bases = rng.sample(row_start_candidates, batch_count)

            weights = [
                [w_full[(n_base + n) * full_k + k_base + k] for k in range(tile_k)]
                for n in range(tile_n)
            ]
            activation_batches = [
                [
                    [a_full[(row_base + m) * full_k + k_base + k] for k in range(tile_k)]
                    for m in range(tile_m)
                ]
                for row_base in row_bases
            ]

            case_name = f"random_header_{header_idx}_{seq_idx}_{header_token}"
            await run_weight_stationary_transaction(
                bus,
                case_name=case_name,
                act_precision=act_precision,
                weight_precision=weight_precision,
                weights=weights,
                activation_batches=activation_batches,
                tile_m=tile_m,
                tile_n=tile_n,
                tile_k=tile_k,
                scenario_extra={
                    "header": header.name,
                    "seed": seed,
                    "k_base": k_base,
                    "n_base": n_base,
                    "row_bases": ";".join(str(row_base) for row_base in row_bases),
                },
            )

            # Start every randomized sequence from a clean firmware-visible
            # state.  The tested behavior is the sequence itself, not accidental
            # state carry-over from the previous random draw.
            await bus.write(OFF_CONTROL, CTRL_SOFT_RESET | CTRL_CLEAR_DONE | CTRL_CLEAR_ERROR)
            status = await bus.wait_phase(PH_IDLE)
            assert not status_error(status), f"unexpected error after {case_name}"


@cocotb.test(skip=os.getenv("RUN_FULL_GEMM_MODE5", "0") != "1")
async def test_mode5_full_gemm_8b_x_32b_32x32_firmware_tiling(dut):
    """Run the full mode5 32x32x32 GEMM through the tile-engine RTL.

    The RTL computes one tile_k<=8 partial result at a time, so this test models
    the missing firmware loop:
      1. sweep output-column tiles,
      2. sweep K tiles,
      3. reuse each loaded weight tile across all M-row batches,
      4. accumulate raw 64-bit partial sums in software,
      5. add bias and cast to int32 before comparing against the header golden.
    """
    bus = await start_clock_and_reset(dut)

    header = GEMM_INCLUDE_DIR / "array_mode5_8b_32b_32_32_32_random.h"
    act_precision, weight_precision = parse_precision_from_header_name(header)
    full_m = parse_c_define_int(header, "M_d")
    full_k = parse_c_define_int(header, "K_d")
    full_n = parse_c_define_int(header, "N_d")
    a_full = parse_c_array(header, "input_unpacked")
    w_full = parse_c_array(header, "weights_unpacked")
    bias = parse_c_array(header, "bias")
    golden = parse_c_array(header, "golden")

    assert (act_precision, weight_precision) == (DTYPE_INT8, DTYPE_INT32)
    assert (full_m, full_k, full_n) == (32, 32, 32)

    tile_m = 8
    tile_n = 8
    tile_k = 8
    row_bases = list(range(0, full_m, tile_m))

    raw_accum = [[0 for _ in range(full_n)] for _ in range(full_m)]
    transaction_count = 0

    for n_base in range(0, full_n, tile_n):
        for k_base in range(0, full_k, tile_k):
            weights = [
                [w_full[(n_base + n) * full_k + k_base + k] for k in range(tile_k)]
                for n in range(tile_n)
            ]
            activation_batches = [
                [
                    [a_full[(row_base + m) * full_k + k_base + k] for k in range(tile_k)]
                    for m in range(tile_m)
                ]
                for row_base in row_bases
            ]

            case_name = f"mode5_full_gemm_tile_n{n_base}_k{k_base}"
            output_tiles = await run_weight_stationary_transaction(
                bus,
                case_name=case_name,
                act_precision=act_precision,
                weight_precision=weight_precision,
                weights=weights,
                activation_batches=activation_batches,
                tile_m=tile_m,
                tile_n=tile_n,
                tile_k=tile_k,
                scenario_extra={
                    "header": header.name,
                    "n_base": n_base,
                    "k_base": k_base,
                    "firmware_role": "raw_partial_accumulation",
                },
                log_value_checks=False,
            )

            for batch_idx, row_base in enumerate(row_bases):
                got = output_tiles[batch_idx]
                for m in range(tile_m):
                    for n in range(tile_n):
                        raw_accum[row_base + m][n_base + n] += got[m][n]

            transaction_count += 1

    case_name = "mode5_full_gemm_8b_x_32b_32x32"
    dut._log.info(
        "COCOTB_SCENARIO,%s,header=%s,act=INT8,weight=INT32,M=%d,K=%d,N=%d,"
        "tile_m=%d,tile_n=%d,tile_k=%d,transactions=%d,final_cast=int32",
        case_name,
        header.name,
        full_m,
        full_k,
        full_n,
        tile_m,
        tile_n,
        tile_k,
        transaction_count,
    )

    mismatches: list[tuple[int, int, int, int]] = []
    for m in range(full_m):
        for n in range(full_n):
            actual = cast_signed(raw_accum[m][n] + bias[n], 32)
            expected = golden[m * full_n + n]
            if not emit_check(dut, case_name, f"final_m{m}_n{n}", expected, actual):
                mismatches.append((m, n, expected, actual))

    dut._log.info(
        "COCOTB_FULL_GEMM_RESULT,%s,total=%d,matched=%d,mismatches=%d,%s",
        case_name,
        full_m * full_n,
        (full_m * full_n) - len(mismatches),
        len(mismatches),
        "PASS" if not mismatches else "FAIL",
    )
    log_check(dut, case_name, "full_matrix_mismatch_count", 0, len(mismatches))
    log_case(dut, case_name)


@cocotb.test()
async def test_invalid_sequence_protection(dut):
    """Firmware ordering mistakes should be rejected before corrupting datapath state."""
    bus = await start_clock_and_reset(dut)
    case_name = "invalid_sequence_protection"

    # Cannot stream activation before loading a valid weight context.
    await bus.write(ACT_BASE, 0x1111_1111, expect_error=True)
    status = await bus.status()
    log_check(dut, case_name, "activation_before_weights_phase", PH_IDLE, status_phase(status))
    log_check(dut, case_name, "activation_before_weights_error_sticky", True, status_error(status))
    error_code = await bus.read(OFF_ERROR_CODE)
    dut._log.info(
        "COCOTB_CHECK,%s,activation_before_weights_error_code,expected=nonzero,actual=%d,%s",
        case_name,
        error_code,
        "PASS" if error_code != 0 else "FAIL",
    )
    assert error_code != 0, "activation-before-weights did not report an error code"

    await bus.write(OFF_CONTROL, CTRL_CLEAR_ERROR | CTRL_SOFT_RESET)
    status = await bus.wait_phase(PH_IDLE)
    log_check(dut, case_name, "error_cleared_after_soft_reset", False, status_error(status))

    # Invalid CONFIG should reject load_weights.
    bad_cfg = make_cfg(DTYPE_INT4, DTYPE_INT4, 0, 1, 1, 1)
    await bus.write(OFF_CONFIG, bad_cfg)
    await bus.write(OFF_CONTROL, CTRL_LOAD_WEIGHTS, expect_error=True)
    status = await bus.status()
    log_check(dut, case_name, "invalid_config_phase", PH_IDLE, status_phase(status))
    log_check(dut, case_name, "invalid_config_error_sticky", True, status_error(status))
    log_case(dut, case_name)


@cocotb.test()
async def test_output_blocking_policy_rejects_next_batch_until_release(dut):
    """While output_valid is high, firmware must copy/release before next input."""
    bus = await start_clock_and_reset(dut)
    case_name = "output_blocking_policy"

    weights = [[1, -1, 2, -2]]
    acts = [[3, 4, -1, 2]]
    cfg = make_cfg(DTYPE_INT4, DTYPE_INT4, 1, 1, 4, 2)

    await bus.write(OFF_CONFIG, cfg)
    await bus.write(OFF_CONTROL, CTRL_LOAD_WEIGHTS)
    await bus.wait_phase(PH_LOAD_WEIGHTS)
    await stream_weight_tile(bus, weights, DTYPE_INT4, 1, 4)
    status = await bus.wait_phase(PH_BATCH_COMPUTE)
    log_check(dut, case_name, "weights_valid_after_load", True, status_weights_valid(status))

    await stream_activation_tile(bus, acts, DTYPE_INT4, 1, 4)
    status = await bus.wait_output_valid()
    log_check(dut, case_name, "output_valid_after_first_batch", True, status_output_valid(status))
    log_check(dut, case_name, "phase_after_first_batch", PH_DRAIN_WRITEBACK, status_phase(status))
    got = await read_output_tile(bus, 1, 1)
    exp = expected_tile(acts, weights, 1, 1, 4)
    log_check(dut, case_name, "first_batch_output_m0_n0", exp[0][0], got[0][0])

    await bus.write(ACT_BASE, 0x0000_0001, expect_error=True)
    status = await bus.status()
    log_check(dut, case_name, "next_batch_before_release_phase", PH_DRAIN_WRITEBACK, status_phase(status))
    log_check(dut, case_name, "next_batch_before_release_output_valid", True, status_output_valid(status))
    log_check(dut, case_name, "next_batch_before_release_error", True, status_error(status))

    # Decoder faults now report PSLVERR/sticky error without aborting the active
    # output context. Firmware can clear the fault, release the already-valid
    # output, and continue with the next activation batch.
    await bus.write(OFF_CONTROL, CTRL_RELEASE_OUTPUT | CTRL_CLEAR_ERROR | CTRL_CLEAR_DONE)
    status = await bus.wait_phase(PH_BATCH_COMPUTE)
    log_check(dut, case_name, "phase_after_fault_clear_release", PH_BATCH_COMPUTE, status_phase(status))
    log_check(dut, case_name, "error_clear_after_release", False, status_error(status))
    log_check(dut, case_name, "output_valid_clear_after_release", False, status_output_valid(status))
    log_case(dut, case_name)
