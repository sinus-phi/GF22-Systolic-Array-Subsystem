import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, Timer

from common.runner import setup_runner

DATA_WIDTH = 32
ACC_WIDTH = DATA_WIDTH * 2
MAC_STAGES = 1
ARRAY_HEIGHT = 2
ARRAY_WIDTH = 2
BUFF_ADDR_WIDTH = 8
OUTPUT_BYTES_PER_BEAT = (ACC_WIDTH * ARRAY_WIDTH) // 8

INSTR_GEMM = 0
INSTR_LOAD = 1
DTYPE_INT32 = 3
S_IDLE = 0
S_DRAIN = 2
OUT_IDLE = 0

SA_CTRL_TEST_FILE = "test_sa_ctrl"
SA_CTRL_SOURCES = ["pe.sv", "sa.sv", "sa_ctrl.sv"]
SA_CTRL_TOP = "sa_ctrl"
SA_CTRL_PARAMETERS = {
    "DATA_WIDTH": DATA_WIDTH,
    "ACC_WIDTH": ACC_WIDTH,
    "MAC_STAGES": MAC_STAGES,
    "ARRAY_HEIGHT": ARRAY_HEIGHT,
    "ARRAY_WIDTH": ARRAY_WIDTH,
    "BUFF_ADDR_WIDTH": BUFF_ADDR_WIDTH,
}
SA_CTRL_TESTCASES = (
    "test_matrix_load",
    "test_signed_matrix_load",
    "test_gemm_operation",
    "test_signed_gemm_operation",
)


def signed_value(value, width):
    value &= (1 << width) - 1
    if value & (1 << (width - 1)):
        value -= 1 << width
    return value


async def tick(dut, cycles=1):
    await ClockCycles(dut.clk, cycles)
    await Timer(1, unit="ps")


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())

    dut.rst_n.value = 0
    dut.i_data.value = 0
    dut.i_valid.value = 0
    dut.ctrl_en.value = 0
    dut.ctrl_instr.value = 0
    dut.ctrl_dtype.value = DTYPE_INT32
    dut.ctrl_out_addr.value = 0
    dut.ctrl_rows.value = 0

    await tick(dut, 2)
    dut.rst_n.value = 1
    await tick(dut)


async def start_command(dut, instr, rows):
    dut.ctrl_instr.value = instr
    dut.ctrl_dtype.value = DTYPE_INT32
    dut.ctrl_out_addr.value = 3
    dut.ctrl_rows.value = rows
    dut.ctrl_en.value = 1
    await tick(dut)
    dut.ctrl_en.value = 0


async def push_vector(dut, values):
    for value in values:
        dut.i_data.value = value & ((1 << 32) - 1)
        dut.i_valid.value = 1
        await tick(dut)
    dut.i_valid.value = 0
    dut.i_data.value = 0


async def wait_idle(dut, limit=64):
    for _ in range(limit):
        if dut.o_state.value.to_unsigned() == S_IDLE:
            return
        await tick(dut)
    assert False, "sa_ctrl did not return to idle"


async def wait_done_idle(dut, limit=128):
    done_seen = 0

    for _ in range(limit):
        assert dut.done.value in (0, 1)

        if dut.done.value == 1:
            done_seen += 1
            assert dut.o_state.value.to_unsigned() == S_IDLE

        if done_seen:
            await tick(dut)
            assert dut.done.value == 0
            assert dut.o_state.value.to_unsigned() == S_IDLE
            assert done_seen == 1
            return

        await tick(dut)

    assert False, "sa_ctrl did not pulse done"


def pe_weight(dut, row, col):
    pe = dut.systolic_array.gen_row[row].gen_col[col].pe_inst
    return signed_value(pe.weight_reg.value.to_unsigned(), DATA_WIDTH)


def output_lanes(dut):
    data = dut.wr_data.value.to_unsigned()
    mask = (1 << ACC_WIDTH) - 1
    return tuple(
        signed_value((data >> (ACC_WIDTH * col)) & mask, ACC_WIDTH)
        for col in range(ARRAY_WIDTH)
    )


def matmul(lhs, rhs):
    return tuple(
        tuple(
            sum(lhs_row[k] * rhs[k][col] for k in range(len(rhs)))
            for col in range(len(rhs[0]))
        )
        for lhs_row in lhs
    )


def transpose(matrix):
    return tuple(zip(*matrix))


async def load_matrix(dut, matrix):
    await start_command(dut, INSTR_LOAD, ARRAY_WIDTH)
    for row in reversed(matrix):
        await push_vector(dut, row)
    await wait_done_idle(dut)
    assert dut.wr_en.value == 0
    assert dut.out_state.value.to_unsigned() == OUT_IDLE


def expected_loaded_weights(matrix):
    return (
        matrix[0][0],
        matrix[0][1],
        matrix[1][0],
        matrix[1][1],
    )


def loaded_weights(dut):
    return (
        pe_weight(dut, 0, 0),
        pe_weight(dut, 1, 0),
        pe_weight(dut, 0, 1),
        pe_weight(dut, 1, 1),
    )


def expected_output_writes(lhs, rhs, base_addr=3):
    expected_matrix = matmul(lhs, rhs)
    return tuple(
        (base_addr + col * OUTPUT_BYTES_PER_BEAT, data)
        for col, data in enumerate(transpose(expected_matrix))
    )


async def run_gemm(dut, loaded_matrix, second_matrix):
    writes = []
    done_seen = 0
    second_matrix_transposed = transpose(second_matrix)

    await reset_dut(dut)
    await load_matrix(dut, loaded_matrix)
    weights_after_load = loaded_weights(dut)

    await start_command(dut, INSTR_GEMM, ARRAY_WIDTH)
    for column in second_matrix_transposed:
        await push_vector(dut, column)

    for _ in range(64):
        if dut.wr_en.value == 1:
            writes.append((dut.addr.value.to_unsigned(), output_lanes(dut)))

        if dut.done.value == 1:
            done_seen += 1
            assert len(writes) == len(expected_output_writes(loaded_matrix, second_matrix))
            assert dut.o_state.value.to_unsigned() == S_IDLE

        if dut.o_state.value.to_unsigned() == S_DRAIN:
            assert dut.sa_en.value == 1
            assert dut.sa_load.value.to_unsigned() == 0
            assert dut.sa_i_data.value.to_unsigned() == 0

        if done_seen and dut.o_state.value.to_unsigned() == S_IDLE:
            break
        await tick(dut)

    assert done_seen == 1
    assert tuple(writes) == expected_output_writes(loaded_matrix, second_matrix)
    assert weights_after_load == loaded_weights(dut)


@cocotb.test()
async def test_matrix_load(dut):
    matrix = (
        (1, 2),
        (3, 4),
    )

    await reset_dut(dut)
    await load_matrix(dut, matrix)

    assert loaded_weights(dut) == expected_loaded_weights(matrix)


@cocotb.test()
async def test_signed_matrix_load(dut):
    matrix = (
        (-1, 2),
        (3, -4),
    )

    await reset_dut(dut)
    await load_matrix(dut, matrix)

    assert loaded_weights(dut) == expected_loaded_weights(matrix)


@cocotb.test()
async def test_gemm_operation(dut):
    loaded_matrix = (
        (1, 2),
        (3, 4),
    )
    second_matrix = (
        (5, 6),
        (7, 8),
    )

    await run_gemm(dut, loaded_matrix, second_matrix)


@cocotb.test()
async def test_signed_gemm_operation(dut):
    loaded_matrix = (
        (-1, 2),
        (3, -4),
    )
    second_matrix = (
        (5, -6),
        (-7, 8),
    )

    await run_gemm(dut, loaded_matrix, second_matrix)


@pytest.mark.parametrize("testcase", SA_CTRL_TESTCASES)
def test_sa_ctrl(testcase):
    setup_runner(
        SA_CTRL_TEST_FILE,
        SA_CTRL_SOURCES,
        SA_CTRL_TOP,
        SA_CTRL_PARAMETERS,
        testcase=testcase,
    )


if __name__ == "__main__":
    for testcase in SA_CTRL_TESTCASES:
        setup_runner(
            SA_CTRL_TEST_FILE,
            SA_CTRL_SOURCES,
            SA_CTRL_TOP,
            SA_CTRL_PARAMETERS,
            testcase=testcase,
        )
