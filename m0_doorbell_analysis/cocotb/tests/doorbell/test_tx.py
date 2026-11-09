import cocotb
from cocotb.triggers import RisingEdge

from bfm.tx import TB, configure_basic, pipe_get
from model.tx import (
    DecodedGdrpSubmission,
    GdrpDoorbellWrite,
    TxReferenceModel,
    TxScoreboard,
    make_token,
)

DOORBELL_BAR_OFFSET = 0x1000


@cocotb.test(timeout_time=100_000, timeout_unit="ns")
async def raw_doorbell_matches_decoded_m0_behavior(dut):
    tb = TB(dut)
    await tb.reset()
    model = TxReferenceModel()
    await configure_basic(tb, model, max_len=4096)

    token = make_token(slot_id=0, length=1500, debug_seq=0xA)
    expected = model.submit(DecodedGdrpSubmission(qpn=0, token=token))
    write = GdrpDoorbellWrite(
        barOffset=DOORBELL_BAR_OFFSET,
        token=token,
        storeBytes=8,
        byteEnable=0xFF,
    )
    await tb.submission.enq(write.pack())

    for index, expected_request in enumerate(expected):
        TxScoreboard.compare(
            expected_request,
            await pipe_get(tb.dma, tb.clock),
            event=f"raw-doorbell[{index}]",
        )

    for _ in range(16):
        await RisingEdge(tb.clock)
        assert not await tb.dma.not_empty(), "trailing DMA request"
