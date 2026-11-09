import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from openrdma_flow_tb.cocotb_bsv import PipeIn, PipeOut

from bfm.tx import pipe_get
from model.tx import DecodedGdrpSubmission, GdrpDoorbellWrite

DOORBELL_BAR_OFFSET = 0x1000


class DecoderTB:
    def __init__(self, dut) -> None:
        self.clock = dut.CLK
        self.resetn = dut.RST_N
        self.doorbell = PipeIn(dut, "doorbellPipeIn", self.clock)
        self.decoded = PipeOut(dut, "decodedPipeOut", self.clock)

    async def reset(self) -> None:
        cocotb.start_soon(Clock(self.clock, 2, unit="ns").start())
        self.resetn.value = 0
        for _ in range(4):
            await RisingEdge(self.clock)
        self.resetn.value = 1
        for _ in range(4):
            await RisingEdge(self.clock)


def doorbell_write(qpn: int, token: int) -> GdrpDoorbellWrite:
    return GdrpDoorbellWrite(
        barOffset=DOORBELL_BAR_OFFSET + qpn * 8,
        token=token,
        storeBytes=8,
        byteEnable=0xFF,
    )


@cocotb.test(timeout_time=100_000, timeout_unit="ns")
async def qp_window_boundaries_decode_without_changing_token(dut):
    tb = DecoderTB(dut)
    await tb.reset()

    tokens = [
        0x0000_0000_0000_0000,
        0x0123_4567_89AB_CDEF,
        0xFEDC_BA98_7654_3210,
        0xFFFF_FFFF_FFFF_FFFF,
    ]
    for qpn, token in enumerate(tokens):
        await tb.doorbell.enq(doorbell_write(qpn, token).pack())
        decoded = DecodedGdrpSubmission.unpack(
            await pipe_get(tb.decoded, tb.clock)
        )
        assert int(decoded.qpn) == qpn
        assert int(decoded.token) == token

    for _ in range(16):
        await RisingEdge(tb.clock)
        assert not await tb.decoded.not_empty(), "trailing decoded submission"


@cocotb.test(timeout_time=100_000, timeout_unit="ns")
async def output_backpressure_preserves_order_and_value(dut):
    tb = DecoderTB(dut)
    await tb.reset()

    writes = [
        doorbell_write(index % 4, 0xA500_0000_0000_0000 | index)
        for index in range(5)
    ]
    await tb.doorbell.enq(writes[0].pack())
    while not await tb.decoded.not_empty():
        await RisingEdge(tb.clock)

    held = await tb.decoded.first()
    producers = [
        cocotb.start_soon(tb.doorbell.enq(write.pack()))
        for write in writes[1:]
    ]
    for _ in range(32):
        assert await tb.decoded.first() == held
        await RisingEdge(tb.clock)
    assert not all(producer.done() for producer in producers), (
        "input backpressure did not reach the fifth Doorbell write"
    )

    observed = [DecodedGdrpSubmission.unpack(held)]
    await tb.decoded.deq()
    for _ in writes[1:]:
        observed.append(
            DecodedGdrpSubmission.unpack(await pipe_get(tb.decoded, tb.clock))
        )
    for producer in producers:
        await producer

    assert [int(item.qpn) for item in observed] == [0, 1, 2, 3, 0]
    assert [int(item.token) for item in observed] == [
        int(write.token) for write in writes
    ]
    for _ in range(16):
        await RisingEdge(tb.clock)
        assert not await tb.decoded.not_empty(), "trailing decoded submission"
