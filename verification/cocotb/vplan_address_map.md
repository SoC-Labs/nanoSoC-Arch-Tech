# NanoSoC Address Map Verification Plan

Verify the NanoSoC address map by exercising bus reads and writes through the HOSTIO4 debug interface. Tests confirm that the interconnect decode, peripheral instantiation, and memory regions are correctly wired.

- **Test module:** `test_address_map.py`
- **Driver:** `nanosoc_cocotb_driver.py` (`NanoSoC` class)
- **Address map:** `build/rtl/nanosoc_combined_address_map/address_maps/nanosoc_address_map.py`
- **Interface:** HOSTIO4 channel 0 (ADP) — all accesses use the real I/O path through the debug initiator

---

## ADDR\_MAP\_001 — Peripheral Identity

**Test function:** `test_peripheral_identity`

**Description:** Read the PID0 and CID0-CID3 identity registers at each peripheral base address and compare against expected values from the register-map model.

**Goal:** Confirm that each peripheral is instantiated at the correct address and is the correct IP type.

**Method:** For each peripheral, read five 32-bit registers (PID0 at offset 0xFE0, CID0-CID3 at offsets 0xFF0-0xFFC) via `soc.read32()` and compare the low byte against the expected constant.

**Coverage:**
- Interconnect decode from debug initiator to `soc_peripheral` target
- APB sub-decode within the `soc_peripheral` region
- AHB target decode for GPIO peripherals
- Correct IP instantiation (PID0 value uniquely identifies IP type)

### Test Points

| Peripheral | Base Address | Expected PID0 | Expected CID |
|:-----------|:-------------|:--------------|:-------------|
| timer\_0   | 0x40000000   | 0x22          | 0x0D, 0xF0, 0x05, 0xB1 |
| timer\_1   | 0x40001000   | 0x22          | 0x0D, 0xF0, 0x05, 0xB1 |
| dualtimer  | 0x40002000   | 0x23          | 0x0D, 0xF0, 0x05, 0xB1 |
| uart\_2    | 0x40006000   | 0x21          | 0x0D, 0xF0, 0x05, 0xB1 |
| watchdog   | 0x40008000   | 0x24          | 0x0D, 0xF0, 0x05, 0xB1 |
| gpio\_0    | 0x40010000   | 0x20          | 0x0D, 0xF0, 0x05, 0xB1 |
| gpio\_1    | 0x40011000   | 0x20          | 0x0D, 0xF0, 0x05, 0xB1 |
| sysctrl    | 0x4001F000   | 0x26          | 0x0D, 0xF0, 0x05, 0xB1 |

**Pass criteria:** All PID0 and CID0-CID3 register values match the expected constants for every peripheral.

---

## ADDR\_MAP\_002 — Memory Write-Read

**Test function:** `test_memory_write_read`

**Description:** Write random 32-bit values to boundary and random addresses in each writable memory region, then read back and compare.

**Goal:** Confirm that the debug initiator has read/write access to all memory targets and that data is stored/retrieved correctly.

**Method:** For each region, generate test addresses at the base, base+4, top of physical extent, and `NUM_RANDOM_PROBES` random locations. Write a random word, read it back, and assert equality.

**Coverage:**
- Interconnect decode to each memory target
- Write data path: HOSTIO4 -> ADP -> interconnect -> memory
- Read data path: memory -> interconnect -> ADP -> HOSTIO4
- Boundary addresses (base, top) to test decode edges
- Random interior addresses for general coverage

### Memory Regions

| Region  | Base Address | Physical Size | Access |
|:--------|:-------------|:-------------|:-------|
| dmem\_0 | 0x18000000   | 16 KB        | rwx    |
| sram\_0 | 0x80000000   | 1 MB         | rwx    |
| sram\_1 | 0x90000000   | 1 MB         | rwx    |

**Pass criteria:** Every write-read-back comparison matches exactly.

---

## ADDR\_MAP\_003 — Address Map Region Probe

**Test function:** `test_address_map_regions`

**Description:** Use the auto-generated Python address map to enumerate all regions visible to the debug initiator and perform a single read at each region's base address.

**Goal:** Fast smoke test to verify that the bus responds at every decoded address region (no hangs or decode errors).

**Method:** Load regions from `ADDRESS_MAP.get_regions(initiator="debug")`, de-duplicate by target, and issue `soc.read32(base)` for each. The test passes if all reads complete without timeout.

### Address Regions

| Target          | Base Address |
|:----------------|:-------------|
| bootrom\_0      | 0x00000000   |
| imem\_0         | 0x10000000   |
| dmem\_0         | 0x18000000   |
| soc\_peripheral | 0x40000000   |
| dmac\_ctrl      | 0x50000000   |
| exp             | 0x60000000   |
| sram\_0         | 0x80000000   |
| sram\_1         | 0x90000000   |
| systable        | 0xF0000000   |

**Pass criteria:** All reads complete without HOSTIO4 timeout, confirming bus connectivity to every target.
