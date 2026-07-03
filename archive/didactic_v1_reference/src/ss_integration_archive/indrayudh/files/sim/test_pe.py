import cocotb
import pytest
import vsc
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, Timer

from common.runner import setup_runner

DATA_WIDTH = 32
ACC_WIDTH = DATA_WIDTH * 2
MAC_STAGES = 2

PE_TEST_FILE = "test_pe"
PE_SOURCES = ["pe.sv"]
PE_TOP = "pe"
PE_PARAMETERS = {
    "DATA_WIDTH": DATA_WIDTH,
    "ACC_WIDTH": ACC_WIDTH,
    "MAC_STAGES": MAC_STAGES,
}
PE_TESTCASES = (
    "test_weight_load",
    "test_mac"
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
    dut.en.value = 0
    dut.i_load.value = 0
    dut.i_data.value = 0
    dut.i_sum.value = 0

    await tick(dut, 2)
    dut.rst_n.value = 1
    await tick(dut, 1)


@cocotb.test()
async def test_weight_load(dut):
    async def check(dut, en, load, weight):
        curr_weight = dut.weight_reg.value
        await tick(dut)
        if en and load:
            assert weight == dut.weight_reg.value
        else:
            assert curr_weight == dut.weight_reg.value
        assert load == dut.o_load.value

    await reset_dut(dut)
    for _ in range(500):
        en = vsc.rand_bit_t(1)
        load = vsc.rand_bit_t(1)
        weight = vsc.rand_bit_t(DATA_WIDTH)
        cocotb.start_soon(check(dut, en, load, weight))

@cocotb.test()
async def test_mac(dut):
    await reset_dut(dut)
    dut.en.value = 1

    async def check(dut, en, load, i_data, i_sum):
        if not (en and not load):
            return
        weight = dut.weight_reg.value.to_unsigned()
        await tick(dut, MAC_STAGES)
        expected = (
            signed_value(weight, DATA_WIDTH) * signed_value(i_data, DATA_WIDTH)
            + signed_value(i_sum, ACC_WIDTH)
        )
        expected = signed_value(expected, ACC_WIDTH)
        actual = signed_value(dut.o_sum.value.to_unsigned(), ACC_WIDTH)
        assert actual == expected

    for _ in range(1000):
        i_data = vsc.rand_bit_t(DATA_WIDTH)
        i_sum = vsc.rand_bit_t(ACC_WIDTH)
        load = vsc.rand_bit_t(1)
        en = vsc.rand_bit_t(1)

        vsc.randomize(en, load, i_data, i_sum)

        i_data = int(i_data.get_val())
        i_sum = int(i_sum.get_val())
        en = int(en.get_val())
        load = int(load.get_val())

        dut.i_load.value = load
        dut.en.value = en
        dut.i_data.value = i_data
        dut.i_sum.value = i_sum

        await cocotb.start_soon(check(dut, en, load, i_data, i_sum))


@pytest.mark.parametrize("testcase", PE_TESTCASES)
def test_pe(testcase):
    setup_runner(PE_TEST_FILE, PE_SOURCES, PE_TOP, PE_PARAMETERS, testcase=testcase)


if __name__ == "__main__":
    for testcase in PE_TESTCASES:
        setup_runner(PE_TEST_FILE, PE_SOURCES, PE_TOP, PE_PARAMETERS, testcase=testcase)
