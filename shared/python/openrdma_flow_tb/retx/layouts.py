"""Retx 测试使用的 packed-field helper。"""
from __future__ import annotations


def pack(fields: list[tuple[str, int]], values: dict[str, int], *, strict: bool = False) -> int:
    packed = 0
    for name, width in fields:
        value = int(values.get(name, 0))
        if strict and not 0 <= value < (1 << width):
            raise ValueError(f"{name}={value} 超出 {width} bit")
        packed = (packed << width) | (value & ((1 << width) - 1))
    return packed


def unpack(fields: list[tuple[str, int]], packed: int) -> dict[str, int]:
    values: dict[str, int] = {}
    for name, width in reversed(fields):
        values[name] = packed & ((1 << width) - 1)
        packed >>= width
    return values


def pack_named(layouts: dict[str, list[tuple[str, int]]], name: str, values: dict[str, int]) -> int:
    return pack(layouts[name], values, strict=True)


def unpack_named(layouts: dict[str, list[tuple[str, int]]], name: str, packed: int) -> dict[str, int]:
    return unpack(layouts[name], packed)
