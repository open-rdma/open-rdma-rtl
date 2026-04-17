"""
bsv_rtile_glue.py
=================
Glue helpers that connect mkBsvTop's raw RTile PCIe interface signals to
cocotbext-pcie's RTilePcieDevice Python model.

Background
----------
In hardware, mkBsvTop sits between the Intel R-Tile PCIe hard IP and the RDMA
logic.  The module exposes the raw RTile streaming interface to the outside:

  mkBsvTop ports (relevant subset, from backend/quartus/rtl/top.v):

    Inputs driven by RTile HIP → user logic (RX direction):
      rtilePcieAdaptorRxRawIfc_data          [1023:0]
      rtilePcieAdaptorRxRawIfc_hdr           [511:0]
      rtilePcieAdaptorRxRawIfc_sop           [3:0]
      rtilePcieAdaptorRxRawIfc_eop           [3:0]
      rtilePcieAdaptorRxRawIfc_hvalid        [3:0]
      rtilePcieAdaptorRxRawIfc_dvalid        [3:0]
      rtilePcieAdaptorRxRawIfc_bar           [11:0]
      rtilePcieAdaptorRxRawIfc_empty         [11:0]
      rtilePcieAdaptorRxRawIfc_hcrdt_init_ack[2:0]
      rtilePcieAdaptorRxRawIfc_dcrdt_init_ack[2:0]

    Outputs driven by user logic → RTile HIP (RX direction, flow-control):
      rtilePcieAdaptorRxRawIfc_ready
      rtilePcieAdaptorRxRawIfc_hcrdt_init    [2:0]
      rtilePcieAdaptorRxRawIfc_hcrdt_update  [2:0]
      rtilePcieAdaptorRxRawIfc_hcrdt_update_cnt [5:0]
      rtilePcieAdaptorRxRawIfc_dcrdt_init    [2:0]
      rtilePcieAdaptorRxRawIfc_dcrdt_update  [2:0]
      rtilePcieAdaptorRxRawIfc_dcrdt_update_cnt [11:0]

    Outputs driven by user logic → RTile HIP (TX direction):
      rtilePcieAdaptorTxRawIfc_data          [1023:0]
      rtilePcieAdaptorTxRawIfc_hdr           [511:0]
      rtilePcieAdaptorTxRawIfc_sop           [3:0]
      rtilePcieAdaptorTxRawIfc_eop           [3:0]
      rtilePcieAdaptorTxRawIfc_hvalid        [3:0]
      rtilePcieAdaptorTxRawIfc_dvalid        [3:0]
      rtilePcieAdaptorTxRawIfc_hcrdt_init_ack[2:0]
      rtilePcieAdaptorTxRawIfc_dcrdt_init_ack[2:0]

    Inputs driven by RTile HIP → user logic (TX direction, flow-control):
      rtilePcieAdaptorTxRawIfc_ready
      rtilePcieAdaptorTxRawIfc_hcrdt_init    [2:0]
      rtilePcieAdaptorTxRawIfc_hcrdt_update  [2:0]
      rtilePcieAdaptorTxRawIfc_hcrdt_update_cnt [5:0]
      rtilePcieAdaptorTxRawIfc_dcrdt_init    [2:0]
      rtilePcieAdaptorTxRawIfc_dcrdt_update  [2:0]
      rtilePcieAdaptorTxRawIfc_dcrdt_update_cnt [11:0]

In simulation we replace the RTile hard IP with RTilePcieDevice.  The device
model expects RTileRxBus / RTileTxBus objects whose attribute names match the
RTile reference naming convention (data, hdr, sop, eop, …).  The BSV DUT uses
the same signals but under a different prefix and without the `prefix` /
`pvalid` wires (those are tied to 0 in the real top.v wrapper).

This module provides:

  DummySignal            – stub for absent prefix / pvalid signals
  BsvRtileBusProxy       – thin bus wrapper with drive() / sample() semantics
  create_bsv_rtile_pcie_dev()  – factory that wires everything up and returns
                                 an RTilePcieDevice ready to connect to an RC

Usage
-----
In your cocotb test (do NOT also call Clock(dut.CLK, …) – RTilePcieDevice
owns that clock):

    from cocotbext.pcie.core.rc import RootComplex
    from test_framework.bsv_rtile_glue import create_bsv_rtile_pcie_dev

    rc  = RootComplex()
    dev = create_bsv_rtile_pcie_dev(dut, rc)

    # Optionally connect a PERST# pin:
    # dev = create_bsv_rtile_pcie_dev(dut, rc, pin_perst_n=dut.my_perst_n)

    await RisingEdge(dut.RST_N)   # wait for RTilePcieDevice to assert reset_status_n
    await rc.enumerate()
    …
"""

import logging
from typing import Optional

from cocotbext.pcie.intel.rtile.rtile_model import RTilePcieDevice

# ---------------------------------------------------------------------------
# Segment geometry for mkBsvTop's PCIe interface
# 4 segments × 256-bit data = 1024-bit total bus  →  PCIe Gen-5 x16 @ 500 MHz
# ---------------------------------------------------------------------------
_SEG_COUNT = 4
_SEG_DATA_WIDTH = 256          # bits per segment
_TOTAL_DATA_WIDTH = _SEG_COUNT * _SEG_DATA_WIDTH   # 1024
_TOTAL_HDR_WIDTH  = _SEG_COUNT * 128               # 512
_TOTAL_BAR_WIDTH  = _SEG_COUNT * 3                 # 12
_SEG_BYTE_LANES   = _SEG_DATA_WIDTH // 32          # 8 DWORDs per segment
_SEG_EMPTY_WIDTH  = (_SEG_BYTE_LANES - 1).bit_length()  # 3
_TOTAL_EMPTY_WIDTH = _SEG_COUNT * _SEG_EMPTY_WIDTH # 12
_TOTAL_PREFIX_WIDTH = _SEG_COUNT * 32              # 128 (dummy)


# ---------------------------------------------------------------------------
# DummySignal
# ---------------------------------------------------------------------------

class DummySignal:
    """
    Fake one-dimensional signal that always reads as 0 and silently ignores
    writes.  Used for the `prefix` and `pvalid` wires that are not exposed by
    the BSV DUT (they are hardwired to 0 in the real hardware wrapper).

    The object satisfies the minimal interface that RTilePcieBase, Clock(),
    and init_signal() expect:
      __len__()           → signal width in bits
      .value              → readable / writable property
      .set(Immediate(x))  → ignore
      .setimmediatevalue(x) → ignore
    """

    def __init__(self, width: int):
        self._width = width

    # --- cocotb handle interface ---

    def __len__(self) -> int:
        return self._width

    @property
    def value(self):
        return 0

    @value.setter
    def value(self, v):
        pass  # ignore writes

    def set(self, v):
        """Accept .set(Immediate(x)) without error."""
        pass

    def setimmediatevalue(self, v):
        pass


# ---------------------------------------------------------------------------
# BsvRtileBusProxy
# ---------------------------------------------------------------------------

class BsvRtileBusProxy:
    """
    Thin proxy object that presents a dict of {attr: signal_handle} as a
    bus interface compatible with RTilePcieSource / RTilePcieSink.

    RTilePcieBase (the common base of Source and Sink) accesses:
      bus._entity._name   – used for logger name
      bus._name           – used for logger name
      bus.<signal>        – each named signal attribute
      bus.drive(obj)      – drive RTilePcieTransaction fields onto signals
      bus.sample(obj)     – read signals into RTilePcieTransaction fields

    The drive() / sample() implementations iterate over instance attributes
    (excluding '_'-prefixed ones) and map them to RTilePcieTransaction slots.
    """

    def __init__(self, entity_name: str, bus_name: str, signal_map: dict):
        """
        Args:
            entity_name:  Logical name of the entity (used by logger).
            bus_name:     Logical name of this bus direction (e.g. "rx" / "tx").
            signal_map:   Mapping of attribute name → cocotb signal handle (or
                          DummySignal).  All entries are set as instance attrs.
        """
        # Private attrs used for logger construction (mirrors Bus._entity._name)
        self._entity = type("_FakeEntity", (), {"_name": entity_name})()
        self._name   = bus_name

        for attr, sig in signal_map.items():
            setattr(self, attr, sig)

    # ------------------------------------------------------------------
    # drive / sample  (mimics cocotb_bus.Bus.drive / Bus.sample)
    # ------------------------------------------------------------------

    def drive(self, obj):
        """
        Drive all bus signals from the corresponding fields of *obj*
        (a RTilePcieTransaction instance).  Unknown fields are silently
        skipped.
        """
        for attr, sig in vars(self).items():
            if attr.startswith("_"):
                continue
            if not hasattr(obj, attr):
                continue
            try:
                sig.value = getattr(obj, attr)
            except (AttributeError, Exception):
                pass

    def sample(self, obj):
        """
        Sample all bus signals into the corresponding fields of *obj*
        (a RTilePcieTransaction instance).  Unreadable signals are skipped.
        """
        for attr, sig in vars(self).items():
            if attr.startswith("_"):
                continue
            if not hasattr(obj, attr):
                continue
            try:
                raw = sig.value
                # cocotb signal values may be LogicArray or int-like
                setattr(obj, attr, int(raw))
            except (AttributeError, ValueError, TypeError):
                pass


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _rx_bus_proxy(dut) -> BsvRtileBusProxy:
    """
    Build the RX-direction bus proxy.

    "RX" = data flowing from the RTile HIP to user logic (BSV).
    RTilePcieDevice creates RTilePcieSource on this bus; the source WRITES the
    data/header/sop/eop/… signals and READS the ready / flow-control signals.
    """
    p = "rtilePcieAdaptorRxRawIfc"
    d = dut

    signal_map = {
        # ---- driven by RTilePcieSource (inputs to BSV DUT) ----
        "data":   getattr(d, f"{p}_data"),    # 1024 bits
        "hdr":    getattr(d, f"{p}_hdr"),     # 512 bits
        "sop":    getattr(d, f"{p}_sop"),     # 4 bits
        "eop":    getattr(d, f"{p}_eop"),     # 4 bits
        "dvalid": getattr(d, f"{p}_dvalid"),  # 4 bits
        "hvalid": getattr(d, f"{p}_hvalid"),  # 4 bits
        "empty":  getattr(d, f"{p}_empty"),   # 12 bits
        "bar":    getattr(d, f"{p}_bar"),     # 12 bits
        # Flow-control ACKs driven by the model back to BSV (inputs to BSV)
        "hcrdt_init_ack": getattr(d, f"{p}_hcrdt_init_ack"),  # 3 bits
        "dcrdt_init_ack": getattr(d, f"{p}_dcrdt_init_ack"),  # 3 bits

        # ---- read by RTilePcieSource (outputs from BSV DUT) ----
        "ready":            getattr(d, f"{p}_ready"),            # 1 bit
        "hcrdt_init":       getattr(d, f"{p}_hcrdt_init"),       # 3 bits
        "hcrdt_update":     getattr(d, f"{p}_hcrdt_update"),     # 3 bits
        "hcrdt_update_cnt": getattr(d, f"{p}_hcrdt_update_cnt"), # 6 bits
        "dcrdt_init":       getattr(d, f"{p}_dcrdt_init"),       # 3 bits
        "dcrdt_update":     getattr(d, f"{p}_dcrdt_update"),     # 3 bits
        "dcrdt_update_cnt": getattr(d, f"{p}_dcrdt_update_cnt"), # 12 bits

        # ---- dummy stubs for absent signals ----
        # `prefix` (TLP prefix) and `pvalid` are hardwired to 0 in top.v.
        # RTilePcieSource will write to them; DummySignal silently discards.
        "prefix": DummySignal(_TOTAL_PREFIX_WIDTH),  # 128 bits
        "pvalid": DummySignal(_SEG_COUNT),            # 4 bits
    }

    return BsvRtileBusProxy(
        entity_name=dut._name,
        bus_name=p,
        signal_map=signal_map,
    )


def _tx_bus_proxy(dut) -> BsvRtileBusProxy:
    """
    Build the TX-direction bus proxy.

    "TX" = data flowing from user logic (BSV) to the RTile HIP.
    RTilePcieDevice creates RTilePcieSink on this bus; the sink WRITES ready
    and READS the data/header/sop/eop/… signals.
    """
    p = "rtilePcieAdaptorTxRawIfc"
    d = dut

    signal_map = {
        # ---- read by RTilePcieSink (outputs from BSV DUT) ----
        "data":   getattr(d, f"{p}_data"),    # 1024 bits
        "hdr":    getattr(d, f"{p}_hdr"),     # 512 bits
        "sop":    getattr(d, f"{p}_sop"),     # 4 bits
        "eop":    getattr(d, f"{p}_eop"),     # 4 bits
        "dvalid": getattr(d, f"{p}_dvalid"),  # 4 bits
        "hvalid": getattr(d, f"{p}_hvalid"),  # 4 bits
        # Flow-control ACKs driven by BSV user logic (outputs from BSV DUT)
        "hcrdt_init_ack": getattr(d, f"{p}_hcrdt_init_ack"),  # 3 bits
        "dcrdt_init_ack": getattr(d, f"{p}_dcrdt_init_ack"),  # 3 bits

        # ---- driven by RTilePcieSink / FlowControlSinkHandler
        #      (inputs to BSV DUT) ----
        "ready":            getattr(d, f"{p}_ready"),            # 1 bit
        "hcrdt_init":       getattr(d, f"{p}_hcrdt_init"),       # 3 bits
        "hcrdt_update":     getattr(d, f"{p}_hcrdt_update"),     # 3 bits
        "hcrdt_update_cnt": getattr(d, f"{p}_hcrdt_update_cnt"), # 6 bits
        "dcrdt_init":       getattr(d, f"{p}_dcrdt_init"),       # 3 bits
        "dcrdt_update":     getattr(d, f"{p}_dcrdt_update"),     # 3 bits
        "dcrdt_update_cnt": getattr(d, f"{p}_dcrdt_update_cnt"), # 12 bits

        # ---- dummy stubs for absent signals ----
        "prefix": DummySignal(_TOTAL_PREFIX_WIDTH),  # 128 bits
        "pvalid": DummySignal(_SEG_COUNT),            # 4 bits
    }

    return BsvRtileBusProxy(
        entity_name=dut._name,
        bus_name=p,
        signal_map=signal_map,
    )


# ---------------------------------------------------------------------------
# Public factory
# ---------------------------------------------------------------------------

def create_bsv_rtile_pcie_dev(
        dut,
        *,
        pin_perst_n=None,
        pcie_generation: int = 5,
        pcie_link_width: int = 16,
        pld_clk_frequency: float = 500e6,
        max_payload_size: int = 128,
        enable_extended_tag: bool = False,
        pf0_msi_enable: bool = True,
        pf0_msi_count: int = 32,
        pf0_msix_enable: bool = False,
        pf0_msix_table_size: int = 0,
        pf0_msix_table_bir: int = 0,
        pf0_msix_table_offset: int = 0x0000_0000,
        pf0_msix_pba_bir: int = 0,
        pf0_msix_pba_offset: int = 0x0000_0000,
) -> RTilePcieDevice:
    """
    Create and wire up an RTilePcieDevice that emulates the Intel R-Tile PCIe
    hard IP for the mkBsvTop simulation.

    Clock / reset ownership
    -----------------------
    RTilePcieDevice drives ``dut.CLK`` (coreclkout_hip) at *pld_clk_frequency*.
    Do **NOT** also start ``Clock(dut.CLK, …)`` in your testbench – that would
    create a double-driver conflict.

    For ``dut.RST_N`` (the long-buffered reset to the RDMA core) the model
    asserts 0 initially, then de-asserts to 1 once the simulated link comes up
    (controlled by *pin_perst_n*).  ``dut.RST_N_partitionReset`` (short-
    buffered reset) is **not** driven by this helper; assert/de-assert it
    separately in your test if needed.

    Typical usage::

        rc  = RootComplex()
        dev = create_bsv_rtile_pcie_dev(dut)
        rc.make_port().connect(dev)

        await RisingEdge(dut.RST_N)
        await rc.enumerate()
        …

    Args:
        dut:                 Cocotb DUT handle (compiled mkBsvTop).
        pin_perst_n:         Optional cocotb signal to use as PCIe PERST#.
                             If None the model internally releases reset after
                             a short delay (no physical reset pin needed).
        pcie_generation:     PCIe generation (5 matches the RDMA board).
        pcie_link_width:     PCIe lane count (16 matches the RDMA board).
        pld_clk_frequency:   HiP clock frequency in Hz; also sets the period
                             of the Clock coroutine that drives dut.CLK.
        max_payload_size:    Max TLP payload size in bytes.
        enable_extended_tag: Enable 10-bit tags.
        pf0_msi_enable:      Enable MSI for PF0.
        pf0_msi_count:       MSI vector count for PF0.
        pf0_msix_*:          MSI-X configuration for PF0.

    Returns:
        Configured RTilePcieDevice instance (``dev``).
        Call ``rc.make_port().connect(dev)`` separately to attach it to a RootComplex.
    """
    rx_bus = _rx_bus_proxy(dut)
    tx_bus = _tx_bus_proxy(dut)

    dev = RTilePcieDevice(
        port_num=0,
        pcie_generation=pcie_generation,
        pcie_link_width=pcie_link_width,
        pld_clk_frequency=pld_clk_frequency,
        pf_count=1,
        max_payload_size=max_payload_size,
        enable_extended_tag=enable_extended_tag,

        # PF0 interrupt configuration
        pf0_msi_enable=pf0_msi_enable,
        pf0_msi_count=pf0_msi_count,
        pf1_msi_enable=False,  pf1_msi_count=1,
        pf2_msi_enable=False,  pf2_msi_count=1,
        pf3_msi_enable=False,  pf3_msi_count=1,

        pf0_msix_enable=pf0_msix_enable,
        pf0_msix_table_size=pf0_msix_table_size,
        pf0_msix_table_bir=pf0_msix_table_bir,
        pf0_msix_table_offset=pf0_msix_table_offset,
        pf0_msix_pba_bir=pf0_msix_pba_bir,
        pf0_msix_pba_offset=pf0_msix_pba_offset,
        pf1_msix_enable=False, pf1_msix_table_size=0, pf1_msix_table_bir=0,
        pf1_msix_table_offset=0, pf1_msix_pba_bir=0, pf1_msix_pba_offset=0,
        pf2_msix_enable=False, pf2_msix_table_size=0, pf2_msix_table_bir=0,
        pf2_msix_table_offset=0, pf2_msix_pba_bir=0, pf2_msix_pba_offset=0,
        pf3_msix_enable=False, pf3_msix_table_size=0, pf3_msix_table_bir=0,
        pf3_msix_table_offset=0, pf3_msix_pba_bir=0, pf3_msix_pba_offset=0,

        # ----------------------------------------------------------------
        # Clock / reset
        # ----------------------------------------------------------------
        # RTilePcieDevice will start Clock(dut.CLK, 1e9/pld_clk_frequency ns).
        # Do NOT separately run Clock(dut.CLK, …) in the testbench.
        coreclkout_hip=dut.CLK,

        # The model drives dut.RST_N low during reset and high after link-up.
        # This corresponds to rtile_pcie_p0_reset_status_n_buffered_long in HW.
        reset_status_n=dut.RST_N,

        # PCIe PERST# input. None → model auto-releases reset internally.
        pin_perst_n=pin_perst_n,

        # ----------------------------------------------------------------
        # Data busses (mapped via proxy objects)
        # ----------------------------------------------------------------
        rx_bus=rx_bus,   # RTile→user (model SOURCE, BSV receives)
        tx_bus=tx_bus,   # user→RTile (model SINK,   BSV transmits)

        # ----------------------------------------------------------------
        # Signals not exposed at the mkBsvTop port boundary – leave as None.
        # (link_up, ltssm_state, tl_cfg_*, cii_*, flr_*, etc. are all
        # internal to mkBsvTopOnlyHardIp and not reachable from the DUT.)
        # ----------------------------------------------------------------
    )

    return dev
