"""Raw Doorbell address decoding through the complete M0 -> M3 chain."""

import cocotb

from m0_chain_bfm import M0ChainTB, M0Submission, run_m0_chain_scenario
from m0_chain_model import M0RefModel
from openrdma_flow_tb.tx.model.m3 import MacIpConfig
from tests.test_m0_chain import bring_up

DOORBELL_BAR_OFFSET = 0x1000
CFG = MacIpConfig(
    srcMac=0x020000000001,
    dstMac=0x020000000002,
    srcIp=0x0A000001,
    dstIp=0x0A000002,
)


@cocotb.test(timeout_time=3_000_000, timeout_unit="ns")
async def interleaved_qp_addresses_match_decoded_chain_behavior(dut):
    tb = M0ChainTB(dut, doorbell_bar_offset=DOORBELL_BAR_OFFSET)
    await tb.reset()
    model = M0RefModel()
    await bring_up(
        tb,
        model,
        qps={0: 0, 1: 1, 2: 2, 3: 3},
        slots={0: (0, 0x4000)},
        psn_starts={0: 0x10, 1: 0x100, 2: 0x1000, 3: 0x10000},
    )

    messages = [
        M0Submission(0, 0, 64, debug_seq=0),
        M0Submission(3, 0, 4096, debug_seq=1),
        M0Submission(1, 0, 512, debug_seq=2),
        M0Submission(2, 0, 1500, debug_seq=3),
        M0Submission(3, 0, 96, debug_seq=4),
        M0Submission(0, 0, 2048, debug_seq=5),
    ]
    await run_m0_chain_scenario(tb, model, messages, CFG)
