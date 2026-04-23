import logging
import re

log = logging.getLogger("cocotb.tb")

_SYSTEM_RAM_RE = re.compile(
    r'^([0-9a-f]+)-([0-9a-f]+)\s*:\s*System RAM\s*$',
    re.IGNORECASE,
)


def parse_iomem_system_ram(iomem_path: str = "/proc/iomem") -> list[tuple[int, int]] | None:
    """Return list of (base, size) for top-level System RAM entries in iomem_path.

    Returns None if any entry has base address 0, which indicates that
    /proc/iomem addresses are hidden (root privileges required).
    """
    ranges = []
    with open(iomem_path) as f:
        for line in f:
            m = _SYSTEM_RAM_RE.match(line)
            if m:
                base = int(m.group(1), 16)
                end = int(m.group(2), 16)
                if base == 0:
                    log.warning(
                        "System RAM entry at address 0x0 in %s — "
                        "addresses may be hidden; re-run with root privileges (sudo).",
                        iomem_path,
                    )
                    return None
                size = end - base + 1
                ranges.append((base, size))
    return ranges


def _align_to_largest_power2_in_gap(gap_base: int, gap_size: int) -> int:
    """在 gap 内找使 (addr & -addr) 最大的对齐地址（尾部零最多）。"""
    gap_end = gap_base + gap_size
    best_addr = gap_base
    best_align = (gap_base & -gap_base) if gap_base else 0
    n = 1
    while (1 << n) <= gap_size:
        candidate = (gap_base + (1 << n) - 1) & ~((1 << n) - 1)
        if candidate < gap_end:
            align = candidate & -candidate
            if align > best_align:
                best_align = align
                best_addr = candidate
        n += 1
    return best_addr


def compute_pcie_address_layout(ram_ranges: list[tuple[int, int]]) -> dict:
    """根据真实 RAM 范围，动态计算 PCIe/MSI 所需的安全基地址。

    返回 dict，包含：
      msi_base              — MSI region 注册地址（32-bit 空间第一个可用 gap）
      mem_base              — PCIe 非预取 MMIO 基地址（32-bit 空间最大 gap 内最大对齐）
      prefetchable_mem_base — PCIe 预取 MMIO 基地址（全部 RAM 之上，1GB 对齐）
    """
    ADDR_32BIT_TOP = 0x1_0000_0000

    sorted_ram = sorted(ram_ranges)
    gaps_32: list[tuple[int, int]] = []
    cursor = 0x1000
    for base, size in sorted_ram:
        if base >= ADDR_32BIT_TOP:
            break
        gap_end = min(base, ADDR_32BIT_TOP)
        if cursor < gap_end:
            gaps_32.append((cursor, gap_end - cursor))
        cursor = max(cursor, base + size)
    if cursor < ADDR_32BIT_TOP:
        gaps_32.append((cursor, ADDR_32BIT_TOP - cursor))

    if not gaps_32:
        raise RuntimeError("32-bit 地址空间中没有可用的 RAM 空白区")

    max_ram_end = max(base + size for base, size in ram_ranges)

    msi_base = next((g for g, s in gaps_32 if s >= 16), None)
    if msi_base is None:
        raise RuntimeError("32-bit 地址空间中没有足够大的 gap 用于 MSI region")

    largest_gap = max(gaps_32, key=lambda g: g[1])
    mem_base = _align_to_largest_power2_in_gap(*largest_gap)

    align = 1 << 30
    prefetchable_mem_base = (max_ram_end + align - 1) & ~(align - 1)

    log.info(
        "PCIe 地址布局：msi_base=0x%x  mem_base=0x%x  prefetchable_mem_base=0x%x",
        msi_base, mem_base, prefetchable_mem_base,
    )
    return {
        "msi_base":              msi_base,
        "mem_base":              mem_base,
        "prefetchable_mem_base": prefetchable_mem_base,
    }


if __name__ == "__main__":
    import sys

    if len(sys.argv) > 1:
        iomem_path = sys.argv[1]
    else:
        iomem_path = "/proc/iomem"
    print(parse_iomem_system_ram(iomem_path))