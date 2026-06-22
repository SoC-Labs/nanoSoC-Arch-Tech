# Copyright 2026, SoC Labs (www.soclabs.org)
"""Generic Cortex-M IMEM launch sequence over an OpenOCD raw session.

The reusable kernel of the multicore firmware loader: inject the OpenOCD helper
procs, then halt a core via its AHB-AP, load an image into IMEM (``load_image``
with a DAP-stream fallback for a remote OpenOCD host), read the reset vectors,
set VTOR, establish the boot context (CONTROL/MSP/SP/xPSR/PC via DCRSR) and
resume — the exact sequence proven on hardware in the multicore system, here
parameterised so any nanosoc can launch an image on any core.

System-specifics are arguments, not hard-coded: the DAP name, the per-core AP
and load address, the VTOR base, and the optional boot-gate / vector-remap
register writes (see core_remap_ctrl). App enumeration and boot-table packing
stay system-side; this module only orchestrates the launch over a
``raw_session()`` from :class:`nanosoc_dap_hal.swd.SwdRegisterChannel`.

    async with regs.raw_session() as sess:
        res = await launch_imem(sess, ap=1, load_addr=0x10000000,
                                vtor_base=0x10000000, bin_path="app.bin",
                                target="compute.compute", dap_name="compute.dap",
                                bootgate=(0x29000000, 0x2), manager_target="compute.cpu0")
"""

from __future__ import annotations

import asyncio
import struct
from pathlib import Path
from typing import Callable, List, Optional, Tuple

SCB_VTOR = 0xE000ED08          # ARMv6-M/v7-M vector-table-offset register
_DAP_WRITE_CHUNK = 256         # words per write_memory when DAP-streaming an image


def proc_defs(dap_name: str = "nanosoc.dap") -> List[str]:
    """OpenOCD helper proc definitions, bound to ``dap_name``.

    The project openocd cfg does not source these, so they are injected into the
    running interpreter. Constants inlined: CSW 0x23000002 (32-bit single AHB-AP
    access); DHCSR 0xE000EDF0; DCRSR 0xE000EDF4 (|0x10000 = write); DCRDR
    0xE000EDF8; DBGKEY 0xA05F0000; C_HALT 0x2; C_DEBUGEN 0x1. ``nsfw_``-prefixed
    to avoid collisions; redefinition is harmless (idempotent).
    """
    return [
        "proc nsfw_rd32 {addr} { return [lindex [read_memory $addr 32 1] 0] }",
        (f"proc nsfw_apmem_w {{ap addr value}} {{ {dap_name} apreg $ap 0x00 0x23000002 ; "
         f"{dap_name} apreg $ap 0x04 $addr ; {dap_name} apreg $ap 0x0C $value }}"),
        ("proc nsfw_core_reg_w {ap regnum value} { nsfw_apmem_w $ap 0xE000EDF8 $value ; "
         "nsfw_apmem_w $ap 0xE000EDF4 [expr {$regnum | 0x10000}] }"),
        "proc nsfw_halt {ap} { nsfw_apmem_w $ap 0xE000EDF0 0xA05F0003 }",
        "proc nsfw_resume {ap} { nsfw_apmem_w $ap 0xE000EDF0 0xA05F0001 }",
    ]


def image_words(path: Optional[str]) -> Optional[List[int]]:
    """Local .bin → list of little-endian 32-bit words (zero-padded), or None.

    Used to stream an image to IMEM over the DAP when ``load_image`` can't reach
    the file (OpenOCD on a remote host).
    """
    if not path:
        return None
    try:
        data = Path(path).read_bytes()
    except OSError:
        return None
    if len(data) % 4:
        data += b"\x00" * (4 - len(data) % 4)
    return list(struct.unpack("<%dI" % (len(data) // 4), data))


def _word(out: str) -> Optional[int]:
    """Parse a decimal/hex word from an nsfw_rd32 reply, else None."""
    tok = out.strip().split()[0] if out.strip() else ""
    try:
        return int(tok, 0) if tok.lower().startswith("0x") else int(tok)
    except ValueError:
        return None


async def inject_procs(sess, dap_name: str = "nanosoc.dap",
                       _state: Optional[dict] = None) -> None:
    """Inject the helper procs into the running OpenOCD interpreter (self-healing).

    The procs live in the OpenOCD interp, not this process; if OpenOCD restarts
    its interp is wiped. Verify a sentinel proc exists rather than trusting a
    cached flag, so this re-injects across a restart. Pass a dict as ``_state``
    to cache the "injected" status across calls on the same session.
    """
    if _state is not None and _state.get("injected"):
        try:
            present = await sess.command("info commands nsfw_halt")
            if "nsfw_halt" in (present or ""):
                return
        except Exception:
            pass  # can't verify -> fall through and (re)inject
    for d in proc_defs(dap_name):
        await sess.command(d)
    if _state is not None:
        _state["injected"] = True


async def launch_imem(sess, *, ap: int, load_addr: int, vtor_base: int,
                      target: str,
                      bin_path: Optional[str] = None,
                      words: Optional[List[int]] = None,
                      dap_name: str = "nanosoc.dap",
                      bootgate: Optional[Tuple[int, int]] = None,
                      manager_target: Optional[str] = None,
                      remap: Optional[Tuple[int, int]] = None,
                      restore_target: Optional[str] = None,
                      inject: bool = True,
                      _state: Optional[dict] = None,
                      progress: Optional[Callable[[str], None]] = None,
                      log: Optional[List[str]] = None) -> dict:
    """Halt ``target``, load an image into IMEM, set VTOR + boot context, resume.

    Faithful to the HW-validated multicore sequence; system-specifics are args:
      ap             the core's AHB-AP index
      load_addr      where to load the image (the core's IMEM, DAP view)
      vtor_base      VTOR value (the image's vector table, in the core's OWN map)
      target         openocd target to arp_examine/select, e.g. "nanosoc.cpu1"
      bootgate       (addr, value) to release a boot-gated core BEFORE examine,
                     written over ``manager_target`` (e.g. (0x29000000, 0x2))
      remap          (addr, value) vector-remap write AFTER vectors (e.g. (addr, 0x3))
      restore_target target to reselect at the end (e.g. "nanosoc.cpu0"); skipped
                     if equal to ``target``
      bin_path/words image source (path for load_image; words for DAP-stream
                     fallback / remote host). At least one should be given.

    Returns ``{ok, sp, pc, note, log}``.
    """
    log = log if log is not None else []
    p = progress or (lambda _ph: None)

    async def cmd(c: str) -> str:
        out = await sess.command(c)
        log.append(f"$ {c}  -> {out}" if out else f"$ {c}")
        return out

    p("connect")
    if inject:
        await inject_procs(sess, dap_name, _state)

    # 0) Optional: release a boot-gated managed core first, over the manager's
    #    target (the gate is a system-bus register reachable from the matrix),
    #    before the managed core is examined. Idempotent.
    if bootgate is not None:
        bg_addr, bg_val = bootgate
        mgr = manager_target or restore_target or target
        await cmd(f"{mgr} mww 0x{bg_addr:08X} 0x{bg_val:08X}")
        await asyncio.sleep(0.01)
        await cmd(f"{target} arp_examine")

    # 1) Halt the target via its AP, then examine + select it.
    p("halt")
    await cmd(f"nsfw_halt {ap}")
    await asyncio.sleep(0.05)
    await cmd(f"{target} arp_examine")
    await cmd(f"targets {target}")

    # 2) Probe IMEM writability (catches a wrong AP / dead window early).
    await cmd(f"write_memory 0x{load_addr:08X} 32 {{0xCAFEBABE}}")
    probe = _word(await cmd(f"nsfw_rd32 0x{load_addr:08X}"))
    if probe != 0xCAFEBABE:
        log.append(f"IMEM writability probe FAILED (readback {probe})")
        return {"ok": False, "addr_hex": f"0x{load_addr:08X}",
                "note": "could not write IMEM — wrong AP or core not halted",
                "log": log}

    # 3) Load the image + read its reset vectors. load_image reads on the
    #    OpenOCD HOST; if OpenOCD is REMOTE it is a SILENT no-op (IMEM keeps the
    #    probe value) — detect and fall back to DAP-streaming local words.
    p("write")
    if bin_path:
        await cmd(f"load_image {bin_path} 0x{load_addr:08X} bin")
    p("verify")
    sp = _word(await cmd(f"nsfw_rd32 0x{load_addr:08X}"))
    if sp == 0xCAFEBABE or not bin_path:
        w = words if words is not None else image_words(bin_path)
        if not w:
            return {"ok": False, "addr_hex": f"0x{load_addr:08X}",
                    "note": ("load_image did not load (remote OpenOCD host?) and "
                             "the .bin could not be read locally to DAP-stream it"),
                    "log": log}
        log.append(f"DAP-streaming {len(w)} words to 0x{load_addr:08X}")
        for i in range(0, len(w), _DAP_WRITE_CHUNK):
            blk = w[i:i + _DAP_WRITE_CHUNK]
            wl = " ".join(f"0x{x:08X}" for x in blk)
            await cmd(f"write_memory 0x{load_addr + i * 4:08X} 32 {{{wl}}}")
        sp = _word(await cmd(f"nsfw_rd32 0x{load_addr:08X}"))
    pcv = _word(await cmd(f"nsfw_rd32 0x{load_addr + 4:08X}"))
    if sp is None or pcv is None:
        return {"ok": False,
                "note": "could not read reset vectors after load",
                "log": log}
    pc = pcv & 0xFFFFFFFE

    # 4) Optional vector-remap (alias 0x0 -> IMEM). Preserve the boot-gate bit if
    #    one was released in step 0 (caller passes the combined value, e.g. 0x3).
    if remap is not None:
        rm_addr, rm_val = remap
        await cmd(f"write_memory 0x{rm_addr:08X} 32 {{0x{rm_val:08X}}}")

    # 4b) Relocate VTOR to the loaded image's table (the core resolves VTOR in
    #     its OWN map, so use the local IMEM base). Written via the AP memory path.
    await cmd(f"nsfw_apmem_w {ap} 0x{SCB_VTOR:08X} 0x{vtor_base:08X}")

    # 5) Boot context: CONTROL=0 (MSP,priv), MSP=SP, SP=SP, xPSR T-bit, PC=entry
    #    via DCRSR; then resume.
    p("resume")
    for reg, val in ((20, 0), (17, sp), (13, sp), (16, 0x01000000), (15, pc)):
        await cmd(f"nsfw_core_reg_w {ap} {reg} 0x{val:08X}")
        await asyncio.sleep(0.005)
    await cmd(f"nsfw_resume {ap}")

    # Restore the global target so a later bare command doesn't land on this AP.
    if restore_target and restore_target != target:
        await cmd(f"targets {restore_target}")

    return {"ok": True, "addr_hex": f"0x{load_addr:08X}",
            "sp_hex": f"0x{sp:08X}", "pc_hex": f"0x{pc:08X}",
            "note": f"loaded to 0x{load_addr:08X} and resumed", "log": log}
