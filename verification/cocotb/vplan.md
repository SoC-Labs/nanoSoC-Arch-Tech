# NanoSoC Cocotb Verification Plan

System-level verification of the NanoSoC M0 SoC using cocotb testbenches driven through the HOSTIO4 debug interface.

- **Top-level testbench:** `nanosoc_tb`
- **Interface:** HOSTIO4 channel 0 (ADP debug protocol) via the SoC debug initiator
- **Simulator:** QuestaSim (`SIM=questa`), also supports VCS, Xcelium, Icarus
- **Drivers:** `nanosoc_cocotb_driver.py` (`NanoSoC` class), `adp_cocotb_driver.py` (`ADP` class)

## Test State Key

| State | Meaning |
|:------|:--------|
| **Pass** | Implemented and verified passing |
| **Impl** | Implemented, not yet run / result unknown |
| **Broken** | Implemented but has known bugs preventing execution |
| **Suspect** | Implemented but relies on unverified assumptions |
| **Proposed** | Not yet implemented — rationale and plan described below |

---

## Test Summary

| ID | Test | Module | State | Result | Description |
|:---|:-----|:-------|:------|:-------|:------------|
| **1. Address Map Verification** | | `test_address_map.py` | | | |
| ADDR\_MAP\_001 | `test_peripheral_identity` | `test_address_map.py` | Impl | — | PID/CID register check at 8 peripherals |
| ADDR\_MAP\_002 | `test_memory_write_read` | `test_address_map.py` | Impl | — | Write-read-back on 3 memory regions |
| ADDR\_MAP\_003 | `test_address_map_regions` | `test_address_map.py` | Impl | — | Smoke read at every debug-visible region |
| **2. Discovery Table Verification** | | `test_discovery.py` | | | |
| DISC\_001 | `test_discovery_header` | `test_discovery.py` | Impl | — | Discovery table header validation |
| DISC\_002 | `test_discovery_targets` | `test_discovery.py` | Impl | — | All 7 target descriptors |
| DISC\_003 | `test_discovery_initiators` | `test_discovery.py` | Impl | — | All 4 initiator descriptors |
| DISC\_004 | `test_discovery_cross_check_address_map` | `test_discovery.py` | Impl | — | Discovery vs Python address map consistency |
| **3. Region Probe Tests** | | `test_region_probe.py` | | | |
| REGION\_001 | `test_region_probe_read` | `test_region_probe.py` | Impl | — | Read-probe at boundary+random addresses per region |
| REGION\_002 | `test_region_probe_write_read` | `test_region_probe.py` | Impl | — | Write-read-back on all writable memory regions |
| **4. ADP Protocol Tests** | | `test_adp.py` | | | |
| ADP\_001 | `test_clocks` | `test_adp.py` | Broken | Fail | Clock/reset basic test (BUG-001) |
| ADP\_002 | `test_adp_read` | `test_adp.py` | Impl | — | Boot and ADP read from UART |
| ADP\_003 | `test_address_pointer` | `test_adp.py` | Impl | — | ADP address pointer set/readback |
| ADP\_004 | `test_adp_write` | `test_adp.py` | Broken | Fail | ADP write sequence (BUG-002) |
| ADP\_005 | `test_adp_hello` | `test_adp.py` | Broken | Fail | Hex file upload and run (BUG-003) |
| **5. Bus Address Coverage Tests** | | `adp_tests.py` | | | |
| BUS\_001 | `bit_toggle_address` | `adp_tests.py` | Impl | — | Address register bit toggle coverage |
| BUS\_002 | `address_test_walking1` | `adp_tests.py` | Impl | — | Walking-1 address pattern |
| BUS\_003 | `address_test_pof2` | `adp_tests.py` | Impl | — | Power-of-2 + random address pattern |
| BUS\_004 | `write_read_test` | `adp_tests.py` | Impl | — | Word/halfword/byte write-read consistency |
| **6. Memory Tests** | | `fill_test_dmem.py`, `read_write_test.py` | | | |
| MEM\_001 | `test_fill` | `fill_test_dmem.py` | Suspect | — | DMEM fill and verify (BUG-005) |
| MEM\_002 | `random_address_read_write` | `read_write_test.py` | Impl | — | 15 random address/data write-read pairs |
| **7. Peripheral Register Tests** | | `test_peripheral_regs.py` | | | *Proposed* |
| PERIPH\_001 | `test_timer_reset_values` | — | Proposed | — | Timer 0/1 register reset values |
| PERIPH\_002 | `test_timer_countdown` | — | Proposed | — | Timer count-down and reload |
| PERIPH\_003 | `test_dualtimer_reset_values` | — | Proposed | — | Dual-timer register reset values |
| PERIPH\_004 | `test_watchdog_identity` | — | Proposed | — | Watchdog lock register and PID |
| PERIPH\_005 | `test_sysctrl_remap` | — | Proposed | — | REMAP\_CTRL changes address decode |
| PERIPH\_006 | `test_gpio_data_loopback` | — | Proposed | — | GPIO write-read on pins with pullups |
| PERIPH\_007 | `test_test_slave_scratchpad` | — | Proposed | — | APB test slave 4 KB scratchpad |
| **8. System Table Tests** | | `test_systable.py` | | | *Proposed* |
| SYS\_001 | `test_systable_coresight_id` | — | Proposed | — | CoreSight ROM table PID/CID |
| SYS\_002 | `test_systable_rom_entries` | — | Proposed | — | ROM table entry 0 points to CPU debug |
| **9. Firmware Load Tests** | | `test_firmware.py` | | | *Proposed* |
| FW\_001 | `test_hex_upload_and_reset` | — | Proposed | — | Upload hex, reset CPU, verify output |
| FW\_002 | `test_bootrom_read` | — | Proposed | — | Read bootrom and verify non-zero content |
| **10. Memory Stress Tests** | | `test_memory_stress.py` | | | *Proposed* |
| MSTRESS\_001 | `test_sram_full_write_read` | — | Proposed | — | Fill entire SRAM with pattern, read back |
| MSTRESS\_002 | `test_sram_address_uniqueness` | — | Proposed | — | Verify each SRAM word is independently addressable |
| MSTRESS\_003 | `test_memory_alias_boundary` | — | Proposed | — | Verify aliasing at physical/aperture boundary |

---

## 1. Address Map Verification

**Test module:** `test_address_map.py`
**Driver:** `NanoSoC` (via `nanosoc_cocotb_driver.py`)
**Source model:** `build/rtl/nanosoc_combined_address_map/address_maps/nanosoc_address_map.py`

### ADDR\_MAP\_001 — Peripheral Identity

**Function:** `test_peripheral_identity` | **State: Impl**

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

**Function:** `test_memory_write_read` | **State: Impl**

Write random 32-bit values to boundary and random addresses in each writable memory region, then read back and compare. Tests decode edges and data integrity.

| Region  | Base Address | Physical Size | Access |
|:--------|:-------------|:-------------|:-------|
| dmem\_0 | 0x18000000   | 16 KB        | rwx    |
| sram\_0 | 0x80000000   | 1 MB         | rwx    |
| sram\_1 | 0x90000000   | 1 MB         | rwx    |

**Pass criteria:** Every write-read-back comparison matches.

### ADDR\_MAP\_003 — Address Map Region Probe

**Function:** `test_address_map_regions` | **State: Impl**

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

### DISC\_001 — Discovery Table Header

**Function:** `test_discovery_header` | **State: Impl**

Read the four header registers and verify against expected constants.

| Register           | Offset | Expected     | Description |
|:-------------------|:-------|:-------------|:------------|
| TABLE\_ID          | 0x000  | 0x534F4344   | Magic number "SOCD" |
| TABLE\_VERSION     | 0x004  | 0x00000001   | Format version 1 |
| TABLE\_SIZE        | 0x008  | 0x00200407   | 7 targets, 4 initiators, 32-bit addr |
| INTERCONNECT\_NAME | 0x00C  | 0x6F6E616E   | "nano" packed LE ASCII |

**Pass criteria:** All four registers match.

### DISC\_002 — Target Descriptors

**Function:** `test_discovery_targets` | **State: Impl**

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

**Pass criteria:** All 28 register values match (4 per target x 7 targets).

### DISC\_003 — Initiator Descriptors

**Function:** `test_discovery_initiators` | **State: Impl**

Read all 4 initiator descriptors (NAME, VISIBILITY).

| Idx | Name    | NAME (packed) | VISIBILITY   | Visible Targets |
|:----|:--------|:-------------|:-------------|:----------------|
| 0   | cpu\_0  | 0x5F757063   | 0x0000007E   | soc\_peripheral, dmac\_ctrl, exp, sram\_0, sram\_1, systable |
| 1   | debug   | 0x75626564   | 0x0000007F   | All 7 targets |
| 2   | dmac\_0 | 0x63616D64   | 0x0000003B   | cpu\_ss, soc\_peripheral, exp, sram\_0, sram\_1 |
| 3   | dmac\_1 | 0x63616D64   | 0x0000003B   | cpu\_ss, soc\_peripheral, exp, sram\_0, sram\_1 |

**Pass criteria:** All 8 register values match.

### DISC\_004 — Cross-Check Against Python Address Map

**Function:** `test_discovery_cross_check_address_map` | **State: Impl**

Resolve each discovery target base address through `ADDRESS_MAP.resolve()` to verify the discovery backend and address-map backend agree on the topology.

**Pass criteria:** Every discovery target base address resolves to a valid region.

---

## 3. Region Probe Tests

**Test module:** `test_region_probe.py`
**Driver:** `ADP` (via `adp_cocotb_driver.py`)

### REGION\_001 — Read Probe All Regions

**Function:** `test_region_probe_read` | **State: Impl**

For every debug-visible region, probe at base, base+4, top of physical extent, and random addresses.

**Pass criteria:** All reads complete (no bus hangs).

### REGION\_002 — Write-Read Probe Writable Regions

**Function:** `test_region_probe_write_read` | **State: Impl**

Write-read-back on all writable memory regions at boundary and random addresses.

**Pass criteria:** All comparisons match.

---

## 4. ADP Protocol Tests

**Test module:** `test_adp.py`
**Driver:** `ADP` (via `adp_cocotb_driver.py`)

### ADP\_001 — Clock and Reset

**Function:** `test_clocks` | **State: Broken** (BUG-001)

Basic clock and reset sanity check. Currently crashes due to wrong argument count in `setup_dut()` call.

### ADP\_002 — ADP Read

**Function:** `test_adp_read` | **State: Impl**

Boot the SoC and verify ADP can receive the bootcode output stream.

**Pass criteria:** Bootcode completion marker received.

### ADP\_003 — Address Pointer

**Function:** `test_address_pointer` | **State: Impl**

Enter monitor mode, set address pointer, write data, and verify echoed responses.

**Pass criteria:** ADP commands echo correctly.

### ADP\_004 — ADP Write Sequence

**Function:** `test_adp_write` | **State: Broken** (BUG-002)

Tests a longer ADP write/read sequence. Crashes due to undefined method calls.

### ADP\_005 — Hex Upload and Run

**Function:** `test_adp_hello` | **State: Broken** (BUG-003)

Upload hex file to IMEM, reset CPU, verify output. Crashes due to missing await and method errors.

---

## 5. Bus Address Coverage Tests

**Test module:** `adp_tests.py`
**Driver:** `ADP` (via `adp_cocotb_driver.py`)

### BUS\_001 — Bit Toggle Coverage

**Function:** `bit_toggle_address` | **State: Impl**

Set random address, read back, invert all bits, verify again. Ensures every address bit can toggle.

### BUS\_002 — Walking-1 Address

**Function:** `address_test_walking1` | **State: Impl**

Walking-1 patterns (0x1, 0x2, ..., 0x80000000) through the address pointer.

### BUS\_003 — Power-of-2 Random

**Function:** `address_test_pof2` | **State: Impl**

Power-of-2 base + random lower bits for decode coverage.

### BUS\_004 — Write-Read Granularity

**Function:** `write_read_test` | **State: Impl**

Write/read as words, halfwords, bytes and verify cross-granularity consistency at 0x30000000.

---

## 6. Memory Tests

**Test module:** `fill_test_dmem.py`, `read_write_test.py`

### MEM\_001 — DMEM Fill

**Function:** `test_fill` | **State: Suspect** (BUG-005)

Uses ADP `V` and `F` commands which may not be implemented in the current ADP firmware. Needs verification that the bootrom ADP supports these fill commands.

### MEM\_002 — Random Address Write-Read

**Function:** `random_address_read_write` | **State: Impl**

15 random address/data pairs in 0x30000000-0x3FFFFFFF. Write all, read all, compare.

---

## 7. Peripheral Register Tests (Proposed)

**Proposed module:** `test_peripheral_regs.py`
**Driver:** `NanoSoC` (via `nanosoc_cocotb_driver.py`)

### PERIPH\_001 — Timer Reset Values | **State: Proposed**

**Rationale:** The timers are the most commonly used CMSDK peripheral but no test currently verifies their control registers are at the correct reset state. A manufacturing defect or synthesis issue could leave registers at wrong values, which firmware would misinterpret.

**Method:** After boot, read CTRL, VALUE, RELOAD registers at timer\_0 (0x40000000) and timer\_1 (0x40001000). All should be 0x00000000 at reset.

| Register | Offset | Expected |
|:---------|:-------|:---------|
| CTRL     | 0x000  | 0x00     |
| VALUE    | 0x004  | 0x00     |
| RELOAD   | 0x008  | 0x00     |

**Pass criteria:** All timer registers read their documented reset values.

### PERIPH\_002 — Timer Countdown | **State: Proposed**

**Rationale:** Verifies the timer actually counts. The existing tests only check bus connectivity (PID/CID) — they never confirm the peripheral functions. A timer that responds on the bus but doesn't count would pass all current tests.

**Method:** Write a reload value (e.g. 0x0000FFFF) to timer\_0 RELOAD, enable the timer (CTRL=0x01), wait some clock cycles, read VALUE and verify it has decremented below the reload value.

**Pass criteria:** VALUE < RELOAD after enabling the timer.

### PERIPH\_003 — Dual-Timer Reset Values | **State: Proposed**

**Rationale:** The dual-timer has a non-zero reset value on its control registers (Timer1Control and Timer2Control reset to 0x20), which is different from the single timers. This is an easy misassumption to make and worth catching.

**Method:** Read Timer1Control (0x40002008) and Timer2Control (0x40002028) after reset.

**Pass criteria:** Both control registers read 0x20.

### PERIPH\_004 — Watchdog Lock and Identity | **State: Proposed**

**Rationale:** The watchdog has a lock register (WDOGLOCK at 0x40008C00) that gates write access to all other registers. Verifying the lock/unlock mechanism works is critical — if the watchdog cannot be unlocked, firmware cannot configure it; if it cannot be locked, a stray write could accidentally trigger a reset.

**Method:** Read WDOGLOCK (should be 0x00000000 = unlocked after reset). Write 0x1 to lock it. Read back WDOGLOCK (should return 0x1 = locked). Write the unlock key 0x1ACCE551. Read back (should return 0x0 = unlocked).

**Pass criteria:** Lock and unlock transitions verified.

### PERIPH\_005 — System Controller Remap | **State: Proposed**

**Rationale:** The REMAP\_CTRL register at 0x4001F000 controls whether address 0x00000000 maps to bootrom or IMEM. This is the mechanism the bootloader uses to hand off to user code. Incorrect remap behaviour would brick the SoC after bootloader completes. No current test verifies the remap mechanism through the debug initiator.

**Method:** After boot (remap should already be active, reading 0x1), read REMAP\_CTRL. Then read 4 bytes from 0x00000000 and from 0x10000000 — they should match (both pointing to IMEM after remap). Write 0x0 to REMAP\_CTRL, read from 0x00000000 again — it should now match bootrom content (read from 0x08000000). Restore remap to 0x1.

**Pass criteria:** Address 0x00000000 content changes with remap bit.

### PERIPH\_006 — GPIO Data Loopback | **State: Proposed**

**Rationale:** GPIO is the primary user-facing peripheral but no test exercises the data registers. The testbench has pullups on GPIO pins, so writing to DATAOUT and reading DATA should produce predictable results on pins configured as outputs.

**Method:** On gpio\_0 (0x40010000): set OUTENSET to enable some pins as outputs, write a pattern to DATAOUT, read back DATA register and verify the output pins reflect the written value.

**Pass criteria:** DATA register reflects written DATAOUT for enabled output pins.

### PERIPH\_007 — APB Test Slave Scratchpad | **State: Proposed**

**Rationale:** The test slave at 0x4000B000 has a 4 KB read/write scratchpad. This is the simplest peripheral to verify — it's just memory on the APB bus. It serves as a baseline: if this test fails, the APB bus itself has issues, isolating failures from peripheral-specific logic.

**Method:** Write random words to several addresses within 0x4000B000-0x4000BFFF, then read them all back and compare.

**Pass criteria:** All write-read comparisons match.

---

## 8. System Table Tests (Proposed)

**Proposed module:** `test_systable.py`
**Driver:** `NanoSoC` (via `nanosoc_cocotb_driver.py`)

### SYS\_001 — CoreSight ROM Table Identity | **State: Proposed**

**Rationale:** The systable at 0xF0000000 is a CoreSight ROM table containing the SoC's JEDEC manufacturer ID (JEPID=0x51), part number (0x001), and revision. Debug tools rely on these fields to identify the SoC. No current test verifies these values, which are parameterised and could be wrong if the build system misconfigures them.

**Method:** Read PID0-PID4 and CID0-CID3 from the systable at offsets 0xFD0-0xFFC. Verify:

| Register | Offset | Expected | Derivation |
|:---------|:-------|:---------|:-----------|
| PID0     | 0xFE0  | 0x01     | PARTNUMBER[7:0] = 0x001 & 0xFF |
| PID1     | 0xFE4  | 0x50     | {JEPID[3:0], PARTNUMBER[11:8]} = {0x1, 0x0} |
| PID2     | 0xFE8  | 0x2A     | {REVISION[3:0], 1'b1, JEPID[6:4]} = {0x1, 1, 0x2} |
| PID4     | 0xFD0  | 0x00     | JEPCONTINUATION = 0 |
| CID0     | 0xFF0  | 0x0D     | CoreSight ROM table |
| CID1     | 0xFF4  | 0x10     | CoreSight ROM table (class=0x1) |
| CID2     | 0xFF8  | 0x05     | CoreSight ROM table |
| CID3     | 0xFFC  | 0xB1     | CoreSight ROM table |

**Pass criteria:** All PID/CID values match the expected parameterised values.

### SYS\_002 — ROM Table Entry Decode | **State: Proposed**

**Rationale:** The ROM table entries are pointers that debug tools follow to discover components. Entry 0 should point to the Cortex-M0 debug ROM (0xE00FF000). Verifying this ensures debug tools can enumerate the system correctly.

**Method:** Read entry 0 at 0xF0000000 + 0x000. The value should be a non-zero entry with bit [0] (present) set. Decode the address offset and verify it points to the expected base address. Read entry 1 and verify it is not present (bit [0] = 0). Read entry at offset 0x010+ and verify it is 0x00000000 (end-of-table).

**Pass criteria:** Entry 0 present and pointing to correct debug ROM, entry 1 not present, end-of-table marker found.

---

## 9. Firmware Load Tests (Proposed)

**Proposed module:** `test_firmware.py`
**Driver:** `NanoSoC` (via `nanosoc_cocotb_driver.py`)

### FW\_001 — Hex Upload and CPU Reset | **State: Proposed**

**Rationale:** The broken `test_adp_hello` (ADP\_005) was attempting this but has bugs. A working firmware load test is essential — it validates the complete path: HOSTIO4 -> ADP -> upload -> memory -> CPU fetch -> execute -> output. This is the ultimate system-level integration test.

**Method:** Using `soc.load_hex()`, upload the `hello` test program to IMEM at 0x10000000. Call `soc.reset()` to restart the CPU. Read characters from the SoC and verify the hello program's expected output appears.

**Pass criteria:** Hello program output received after upload and reset.

### FW\_002 — Bootrom Content Verification | **State: Proposed**

**Rationale:** The bootrom is preloaded at synthesis time. If the bootrom content is wrong (e.g. simulation model not initialised), the SoC won't boot at all. Currently, boot failures just result in a timeout — a direct content check gives a clearer diagnostic.

**Method:** Read the first few words from bootrom at 0x00000000 (before remap) or 0x08000000 (always-valid alias). The first word should be the initial SP value and the second word should be the reset vector — both should be non-zero and within the bootrom address range.

**Pass criteria:** First two words are non-zero and consistent with a valid ARM vector table.

---

## 10. Memory Stress Tests (Proposed)

**Proposed module:** `test_memory_stress.py`
**Driver:** `NanoSoC` (via `nanosoc_cocotb_driver.py`)

### MSTRESS\_001 — SRAM Full Write-Read | **State: Proposed**

**Rationale:** Current memory tests only probe a handful of addresses. An SRAM manufacturing defect (stuck bit, address line short) may only manifest at specific addresses. Writing a unique pattern to every word and reading it all back catches single-bit failures and address-line faults. This is a standard production test pattern.

**Method:** Write the word's own address as data to every 4th word in SRAM\_0 (0x80000000, physical size 1 MB, step by 1 KB to keep runtime manageable — ~1024 locations). Then read all locations back and verify each contains its own address.

**Pass criteria:** All locations read back their expected address-as-data pattern.

### MSTRESS\_002 — SRAM Address Uniqueness | **State: Proposed**

**Rationale:** If two address lines are shorted together on the bus or in the SRAM, writes to different addresses would alias. Walking-1 through the address bits catches this class of fault which the random-address tests may miss.

**Method:** Within SRAM\_0, write a unique value to addresses at each power-of-2 offset (0x80000000, 0x80000004, 0x80000008, 0x80000010, ..., up to physical size). Then read all back and verify no value was overwritten by a later write to a different address.

**Pass criteria:** Every power-of-2 address retains its unique written value.

### MSTRESS\_003 — Memory Alias Boundary | **State: Proposed**

**Rationale:** SRAM\_0 has 1 MB of physical memory but a 256 MB aperture. Addresses above the physical size alias back (wrap around). Firmware that accidentally accesses the aliased region should still get valid data. This test verifies the wrap-around works correctly.

**Method:** Write a value to SRAM\_0 base (0x80000000). Read from the alias address (0x80000000 + physical\_size = 0x80100000). They should return the same data because the upper address bits are not decoded by the SRAM.

**Pass criteria:** Aliased address returns the same data as the base address.

---

## Known Issues

| ID | Issue | Severity | File | Details |
|:---|:------|:---------|:-----|:--------|
| BUG-001 | `test_clocks` wrong arg count | High | `test_adp.py:83` | Calls `setup_dut(dut, adp_driver)` but function takes 1 arg |
| BUG-002 | `test_adp_write` undefined methods | High | `test_adp.py:134` | Calls `.write()` (should be `.write_bytes()`) |
| BUG-003 | `test_adp_hello` missing await | High | `test_adp.py:160` | `adp_driver.readLine()` called without `await` |
| BUG-004 | `wait_prompt` string comparison | Low | `test_adp.py:64` | Compares against literal `"bootcode_last"` instead of `"]"` |
| BUG-005 | `test_fill` undocumented ADP cmds | Medium | `fill_test_dmem.py:72` | Uses `V` and `F` commands — may not exist in current ADP |
