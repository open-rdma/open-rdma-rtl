import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from openrdma_flow_tb.cocotb_bsv import PipeIn, PipeOut

from model.tx import GdrpDoorbellWrite

DOORBELL_BAR_OFFSET = 0x1000
CASES = {
    "below_window": dict(barOffset=DOORBELL_BAR_OFFSET - 8),
    "at_upper_bound": dict(barOffset=DOORBELL_BAR_OFFSET + 32),
    "unaligned_plus_one": dict(barOffset=DOORBELL_BAR_OFFSET + 1),
    "unaligned_plus_two": dict(barOffset=DOORBELL_BAR_OFFSET + 2),
    "unaligned_plus_four": dict(barOffset=DOORBELL_BAR_OFFSET + 4),
    "store_size_4": dict(storeBytes=4),
    "store_size_16": dict(storeBytes=16),
    "partial_low": dict(byteEnable=0x0F),
    "partial_high": dict(byteEnable=0xF0),
    "invalid_while_output_blocked": dict(barOffset=DOORBELL_BAR_OFFSET - 8),
}


@cocotb.test(timeout_time=100_000, timeout_unit="ns")
async def selected_doorbell_violation_triggers_assert(dut):
    clock = dut.CLK
    resetn = dut.RST_N
    doorbell = PipeIn(dut, "doorbellPipeIn", clock)
    decoded = PipeOut(dut, "decodedPipeOut", clock)
    cocotb.start_soon(Clock(clock, 2, unit="ns").start())
    resetn.value = 0
    for _ in range(4):
        await RisingEdge(clock)
    resetn.value = 1
    for _ in range(4):
        await RisingEdge(clock)

    case = os.environ["M0_DOORBELL_NEGATIVE_CASE"]
    if case not in CASES:
        raise RuntimeError(f"unknown negative case: {case}")

    fields = {
        "barOffset": DOORBELL_BAR_OFFSET,
        "token": 0,
        "storeBytes": 8,
        "byteEnable": 0xFF,
    }
    if case == "invalid_while_output_blocked":
        for qpn in range(2):
            await doorbell.enq(
                GdrpDoorbellWrite(
                    barOffset=DOORBELL_BAR_OFFSET + qpn * 8,
                    token=qpn,
                    storeBytes=8,
                    byteEnable=0xFF,
                ).pack()
            )
        for _ in range(8):
            await RisingEdge(clock)
        assert await decoded.not_empty(), "decoder output did not become blocked"

    fields.update(CASES[case])
    await doorbell.enq(GdrpDoorbellWrite(**fields).pack())

    for _ in range(30):
        await RisingEdge(clock)
    raise AssertionError(f"M0_DOORBELL_ASSERTION_DID_NOT_FIRE_{case}")
