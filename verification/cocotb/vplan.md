# NanoSoC Cocotb Verification Plan

System-level verification of the NanoSoC M0 SoC using cocotb testbenches driven through the HOSTIO4 debug interface.

- **Top-level testbench:** `nanosoc_tb`
- **Interface:** HOSTIO4 channel 0 (ADP debug protocol) via the SoC debug initiator
- **Simulator:** QuestaSim (`SIM=questa`), also supports VCS, Xcelium, Icarus
- **Drivers:** `nanosoc_cocotb_driver.py` (`NanoSoC` class), `adp_cocotb_driver.py` (`ADP` class)

---

## Test Summary

| ID | Test | Module | Status | Description |
|:---|:-----|:-------|:-------|:------------|
| ADDR\_MAP\_001 | `test_peripheral_identity` | `test_address_map.py` | Implemented | PID/CID register check at 8 peripherals |
| ADDR\_MAP\_002 | `test_memory_write_read` | `test_address_map.py` | Implemented | Write-read-back on 3 memory regions |
| ADDR\_MAP\_003 | `test_address_map_regions` | `test_address_map.py` | Implemented | Smoke read at every debug-visible region |
| DISC\_001 | `test_discovery_header` | `test_discovery.py` | Implemented | Discovery table header validation |
| DISC\_002 | `test_discovery_targets` | `test_discovery.py` | Implemented | All 7 target descriptors |
| DISC\_003 | `test_discovery_initiators` | `test_discovery.py` | Implemented | All 4 initiator descriptors |
| DISC\_004 | `test_discovery_cross_check_address_map` | `test_discovery.py` | Implemented | Discovery vs Python address map consistency |
| REGION\_001 | `test_region_probe_read` | `test_region_probe.py` | Implemented | Read-probe at boundary+random addresses per region |
| REGION\_002 | `test_region_probe_write_read` | `test_region_probe.py` | Implemented | Write-read-back on all writable memory regions |
| ADP\_001 | `test_clocks` | `test_adp.py` | Broken | Clock/reset basic test (wrong arg count) |
| ADP\_002 | `test_adp_read` | `test_adp.py` | Implemented | Boot and ADP read from UART |
| ADP\_003 | `test_address_pointer` | `test_adp.py` | Implemented | ADP address pointer set/readback |
| ADP\_004 | `test_adp_write` | `test_adp.py` | Broken | ADP write sequence (undefined methods) |
| ADP\_005 | `test_adp_hello` | `test_adp.py` | Broken | Hex file upload and run (undefined methods) |
| BUS\_001 | `bit_toggle_address` | `adp_tests.py` | Implemented | Address register bit toggle coverage |
| BUS\_002 | `address_test_walking1` | `adp_tests.py` | Implemented | Walking-1 address pattern |
| BUS\_003 | `address_test_pof2` | `adp_tests.py` | Implemented | Power-of-2 + random address pattern |
| BUS\_004 | `write_read_test` | `adp_tests.py` | Implemented | Word/halfword/byte write-read consistency |
| MEM\_001 | `test_fill` | `fill_test_dmem.py` | Suspect | DMEM fill and verify (uses undocumented ADP V/F commands) |
| MEM\_002 | `random_address_read_write` | `read_write_test.py` | Implemented | 15 random address/data write-read pairs |

---

## 1. Address Map Verification

**Test module:** `test_address_map.py`
**Driver:** `NanoSoC` (via `nanosoc_cocotb_driver.py`)
**Source model:** `build/rtl/nanosoc_combined_address_map/address_maps/nanosoc_address_map.py`

### ADDR\_MAP\_001 — Peripheral Identity

**Function:** `test_peripheral_identity`

Read PID0 and CID0-CID3 identity registers at each peripheral base address and compare against expected values from the register-map model. Validates interconnect decode, APB sub-decode, and correct IP instantiation.

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

**Pass criteria:** All PID0 and CID values match for every peripheral.

### ADDR\_MAP\_002 — Memory Write-Read

**Function:** `test_memory_write_read`

Write random 32-bit values to boundary and random addresses in each writable memory region, then read back and compare. Tests decode edges and data integrity.

| Region  | Base Address | Physical Size | Access |
|:--------|:-------------|:-------------|:-------|
| dmem\_0 | 0x18000000   | 16 KB        | rwx    |
| sram\_0 | 0x80000000   | 1 MB         | rwx    |
| sram\_1 | 0x90000000   | 1 MB         | rwx    |

**Pass criteria:** Every write-read-back comparison matches.

### ADDR\_MAP\_003 — Address Map Region Probe

**Function:** `test_address_map_regions`

Smoke test: enumerate all regions from the generated Python address map and perform a single read at each base address. Confirms no bus hangs at any decoded region.

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

**Pass criteria:** All reads complete without HOSTIO4 timeout.

---

## 2. Discovery Table Verification

**Test module:** `test_discovery.py`
**Driver:** `NanoSoC` (via `nanosoc_cocotb_driver.py`)
**Base address:** 0x4000D000 (APB slot 13)
**RTL:** `build_soc/rtl/nanosoc_ahb_interconnect_discovery/`
**Register map:** `build_soc/discovery/nanosoc_ahb_interconnect_discovery.yaml`

### DISC\_001 — Discovery Table Header

**Function:** `test_discovery_header`

Read the four header registers and verify against expected constants.

| Register           | Offset | Expected     | Description |
|:-------------------|:-------|:-------------|:------------|
| TABLE\_ID          | 0x000  | 0x534F4344   | Magic number "SOCD" |
| TABLE\_VERSION     | 0x004  | 0x00000001   | Format version 1 |
| TABLE\_SIZE        | 0x008  | 0x00200407   | 7 targets, 4 initiators, 32-bit addr |
| INTERCONNECT\_NAME | 0x00C  | 0x6F6E616E   | "nano" packed LE ASCII |

**Pass criteria:** All four registers match.

### DISC\_002 — Target Descriptors

**Function:** `test_discovery_targets`

Read all 7 target descriptors (BASE, SIZE, ATTR, NAME) at offsets `0x010 + (i * 16)`.

| Idx | Name             | BASE         | SIZE         | ATTR         | NAME (packed) |
|:----|:-----------------|:-------------|:-------------|:-------------|:-------------|
| 0   | cpu\_ss          | 0x00000000   | 0x20000000   | 0x00000041   | 0x5F757063   |
| 1   | soc\_peripheral  | 0x40000000   | 0x10000000   | 0x00010032   | 0x5F636F73   |
| 2   | dmac\_ctrl       | 0x50000000   | 0x10000000   | 0x00020032   | 0x63616D64   |
| 3   | exp              | 0x60000000   | 0x20000000   | 0x00030032   | 0x00707865   |
| 4   | sram\_0          | 0x80000000   | 0x00010000   | 0x00040041   | 0x6D617273   |
| 5   | sram\_1          | 0x90000000   | 0x00010000   | 0x00050041   | 0x6D617273   |
| 6   | systable         | 0xF0000000   | 0x00040000   | 0x00060012   | 0x74737973   |

ATTR encoding: `[3:0]` region\_type (1=memory, 2=periph), `[7:4]` sw\_access (1=ro, 3=rw, 4=rwx), `[15:8]` protocol (0=ahb), `[23:16]` target\_id

**Pass criteria:** All 28 register values match (4 per target x 7 targets).

### DISC\_003 — Initiator Descriptors

**Function:** `test_discovery_initiators`

Read all 4 initiator descriptors (NAME, VISIBILITY).

| Idx | Name    | NAME (packed) | VISIBILITY   | Visible Targets |
|:----|:--------|:-------------|:-------------|:----------------|
| 0   | cpu\_0  | 0x5F757063   | 0x0000007E   | soc\_peripheral, dmac\_ctrl, exp, sram\_0, sram\_1, systable |
| 1   | debug   | 0x75626564   | 0x0000007F   | All 7 targets |
| 2   | dmac\_0 | 0x63616D64   | 0x0000003B   | cpu\_ss, soc\_peripheral, exp, sram\_0, sram\_1 |
| 3   | dmac\_1 | 0x63616D64   | 0x0000003B   | cpu\_ss, soc\_peripheral, exp, sram\_0, sram\_1 |

**Pass criteria:** All 8 register values match.

### DISC\_004 — Cross-Check Against Python Address Map

**Function:** `test_discovery_cross_check_address_map`

Resolve each discovery target base address through `ADDRESS_MAP.resolve()` to verify the discovery backend and address-map backend agree on the topology.

**Pass criteria:** Every discovery target base address resolves to a valid region.

---

## 3. Region Probe Tests

**Test module:** `test_region_probe.py`
**Driver:** `ADP` (via `adp_cocotb_driver.py`)
**Source model:** `nanosoc_address_map.py`

### REGION\_001 — Read Probe All Regions

**Function:** `test_region_probe_read`

For every region visible to the debug initiator, generate probe addresses at base, base+4, top of physical extent, and `NUM_RANDOM_PROBES` random locations. Issue an ADP read at each address to verify bus connectivity and decode.

**Pass criteria:** All reads complete (no bus hangs) across all regions.

### REGION\_002 — Write-Read Probe Writable Regions

**Function:** `test_region_probe_write_read`

For all writable memory regions (excluding bootrom and peripherals), write a random word and read it back at boundary and random addresses.

**Pass criteria:** All write-read-back comparisons match.

---

## 4. ADP Protocol Tests

**Test module:** `test_adp.py`
**Driver:** `ADP` (via `adp_cocotb_driver.py`)

### ADP\_001 — Clock and Reset

**Function:** `test_clocks`
**Status: BROKEN** — calls `setup_dut(dut, adp_driver)` with wrong argument count (expects 1 arg).

Basic clock and reset sanity check.

### ADP\_002 — ADP Read

**Function:** `test_adp_read`

Boot the SoC and verify ADP can receive the bootcode output stream. Confirms HOSTIO4 channel 0 RX path is functional.

**Pass criteria:** Bootcode completion marker received.

### ADP\_003 — Address Pointer

**Function:** `test_address_pointer`

Enter ADP monitor mode, set address pointer to 0x30000000, write data 0x11, and verify echoed responses.

**Pass criteria:** ADP commands echo correctly.

### ADP\_004 — ADP Write Sequence

**Function:** `test_adp_write`
**Status: BROKEN** — calls undefined method `adp_driver.write()` (should be `write_bytes()`) and passes string to `read_bytes()` (expects int).

Tests a longer ADP write/read sequence: set address, get address, read bytes, and verify responses.

### ADP\_005 — Hex Upload and Run

**Function:** `test_adp_hello`
**Status: BROKEN** — calls `adp_driver.writeHex()` without `await`, and has other method call issues.

Upload `hello` hex file to IMEM, reset the CPU, and verify the "hello" program output.

---

## 5. Bus Address Coverage Tests

**Test module:** `adp_tests.py`
**Driver:** `ADP` (via `adp_cocotb_driver.py`)

### BUS\_001 — Bit Toggle Coverage

**Function:** `bit_toggle_address`

Set the ADP address pointer to a random value, read it back, then invert all bits and verify the inverted value reads back correctly. Ensures every bit on the address bus can toggle.

**Pass criteria:** Set and read addresses match for both original and inverted values.

### BUS\_002 — Walking-1 Address

**Function:** `address_test_walking1`

Set the address pointer to walking-1 patterns (0x1, 0x2, 0x4, ..., up to 0x80000000) and verify each reads back correctly. Tests one-hot state encoding coverage.

**Pass criteria:** All walking-1 addresses set and read back correctly.

### BUS\_003 — Power-of-2 Random

**Function:** `address_test_pof2`

For each power-of-2 from 2^1 to 2^31, set the address pointer to `2^n + random(n-1 bits)` and verify readback. Tests address decode across all significant bit positions.

**Pass criteria:** All power-of-2 + random addresses read back correctly.

### BUS\_004 — Write-Read Granularity

**Function:** `write_read_test`

Write a random word to 0x30000000 using word, halfword, and byte granularity. Read it back using all three granularities and verify consistency. Tests the ADP's ability to handle different transfer sizes.

**Pass criteria:** Data is consistent across word, halfword, and byte reads regardless of write granularity.

---

## 6. Memory Tests

**Test module:** `fill_test_dmem.py`, `read_write_test.py`
**Driver:** `ADP` (via `adp_cocotb_driver.py`)

### MEM\_001 — DMEM Fill

**Function:** `test_fill` (in `fill_test_dmem.py`)
**Status: SUSPECT** — uses ADP `V` (set fill value) and `F` (fill range) commands which may not be implemented in the current ADP firmware.

Fill a region of DMEM at 0x30000000 with a random value using the ADP fill command, then read back and verify every word matches.

**Pass criteria:** All read-back values match the fill value.

### MEM\_002 — Random Address Write-Read

**Function:** `random_address_read_write` (in `read_write_test.py`)

Generate 15 random address/data pairs in the 0x30000000-0x3FFFFFFF range. Write all values, then read all values back and compare. Tests that writes to different addresses do not interfere with each other.

**Pass criteria:** All 15 read-back values match the written data.

---

## Known Issues

| ID | Issue | Severity | File | Details |
|:---|:------|:---------|:-----|:--------|
| BUG-001 | `test_clocks` wrong arg count | High | `test_adp.py:83` | Calls `setup_dut(dut, adp_driver)` but function takes 1 arg |
| BUG-002 | `test_adp_write` undefined methods | High | `test_adp.py:134` | Calls `.write()` (should be `.write_bytes()`) |
| BUG-003 | `test_adp_hello` missing await | High | `test_adp.py:160` | `adp_driver.readLine()` called without `await` |
| BUG-004 | `wait_prompt` string comparison | Low | `test_adp.py:64` | Compares against literal `"bootcode_last"` instead of `"]"` |
| BUG-005 | `test_fill` undocumented ADP cmds | Medium | `fill_test_dmem.py:72` | Uses `V` and `F` commands — may not exist in current ADP |
