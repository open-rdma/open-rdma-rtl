"""Retx cocotb 测试共用的 method/Pipe 驱动。"""
from __future__ import annotations

from cocotb.triggers import RisingEdge


async def reset(dut) -> None:
    dut.RST_N.value = 0
    await RisingEdge(dut.CLK)
    await RisingEdge(dut.CLK)
    dut.RST_N.value = 1
    await RisingEdge(dut.CLK)


async def call(dut, name: str, value: int = 0) -> None:
    if value:
        getattr(dut, f"{name}_value").value = value
    getattr(dut, f"EN_{name}").value = 1
    await RisingEdge(dut.CLK)
    getattr(dut, f"EN_{name}").value = 0
    await RisingEdge(dut.CLK)


async def call_config(dut, name: str, index: int, config: int) -> None:
    getattr(dut, f"{name}_idx").value = index
    getattr(dut, f"{name}_cfg").value = config
    getattr(dut, f"EN_{name}").value = 1
    await RisingEdge(dut.CLK)
    getattr(dut, f"EN_{name}").value = 0
    await RisingEdge(dut.CLK)


async def send(dut, port: str, value: int) -> None:
    getattr(dut, f"{port}_enq_value").value = value
    getattr(dut, f"EN_{port}_enq").value = 1
    await RisingEdge(dut.CLK)
    getattr(dut, f"EN_{port}_enq").value = 0
    await RisingEdge(dut.CLK)


async def recv(dut, port: str, timeout_cycles: int = 300) -> int:
    for _ in range(timeout_cycles):
        if int(getattr(dut, f"{port}_notEmpty").value) == 1:
            break
        await RisingEdge(dut.CLK)
    else:
        raise AssertionError(f"{port} 在 {timeout_cycles} cycles 内未就绪")
    value = int(getattr(dut, f"{port}_first").value)
    getattr(dut, f"EN_{port}_deq").value = 1
    await RisingEdge(dut.CLK)
    getattr(dut, f"EN_{port}_deq").value = 0
    await RisingEdge(dut.CLK)
    return value
