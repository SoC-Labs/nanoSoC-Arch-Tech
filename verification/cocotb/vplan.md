# NanoSoC Cocotb Verification Plan

System-level verification of the NanoSoC M0 SoC using cocotb testbenches driven through the HOSTIO4 debug interface.

- **Top-level testbench:** `nanosoc_tb`
- **Interface:** HOSTIO4 channel 0 (ADP debug protocol) via the SoC debug initiator
- **Simulator:** QuestaSim (`SIM=questa`), also supports VCS, Xcelium, Icarus
- **Drivers:** `nanosoc_cocotb_driver.py` (`NanoSoC` class), `adp_cocotb_driver.py` (`ADP` class)

## Test State Key

| State | Meaning |
|:------|:--------|
| **Pass** | Implemented, verified passing in simulation |
| **Impl** | Implemented and syntax-verified, awaiting simulation run |
| **Blocked** | Implemented but uses old ADP driver with wrong signal names — needs NanoSoC driver port |
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
| REGION\_001 | `test_region_probe_read` | `test_region_probe.py` | Blocked | — | Read-probe at boundary+random addresses per region |
| REGION\_002 | `test_region_probe_write_read` | `test_region_probe.py` | Blocked | — | Write-read-back on all writable memory regions |
| **4. ADP Protocol Tests** | | `test_adp.py` | | | |
| ADP\_001 | `test_clocks` | `test_adp.py` | Impl | — | Clock/reset basic test |
| ADP\_002 | `test_adp_read` | `test_adp.py` | Impl | — | Boot and ADP read |
| ADP\_003 | `test_address_pointer` | `test_adp.py` | Impl | — | Address pointer set/readback + write verify |
| ADP\_004 | `test_adp_write` | `test_adp.py` | Impl | — | Multi-address write-read sequence |
| ADP\_005 | `test_adp_hello` | `test_adp.py` | Impl | — | Hex file upload and run |
| **5. Bus Address Coverage Tests** | | `adp_tests.py` | | | |
| BUS\_001 | `bit_toggle_address` | `adp_tests.py` | Blocked | — | Address register bit toggle coverage |
| BUS\_002 | `address_test_walking1` | `adp_tests.py` | Blocked | — | Walking-1 address pattern |
| BUS\_003 | `address_test_pof2` | `adp_tests.py` | Blocked | — | Power-of-2 + random address pattern |
| BUS\_004 | `write_read_test` | `adp_tests.py` | Blocked | — | Word/halfword/byte write-read consistency |
| **6. Memory Tests** | | `fill_test_dmem.py`, `read_write_test.py` | | | |
| MEM\_001 | `test_fill` | `fill_test_dmem.py` | Impl | — | DMEM fill and verify |
| MEM\_002 | `random_address_read_write` | `read_write_test.py` | Blocked | — | 15 random address/data write-read pairs |
| **7. Peripheral Register Tests** | | `test_peripheral_regs.py` | | | |
| PERIPH\_001 | `test_timer_reset_values` | `test_peripheral_regs.py` | Impl | — | Timer 0/1 register reset values |
| PERIPH\_002 | `test_timer_countdown` | `test_peripheral_regs.py` | Impl | — | Timer count-down and reload |
| PERIPH\_003 | `test_dualtimer_reset_values` | `test_peripheral_regs.py` | Impl | — | Dual-timer register reset values |
| PERIPH\_004 | `test_watchdog_identity` | `test_peripheral_regs.py` | Impl | — | Watchdog lock register and PID |
| PERIPH\_005 | `test_sysctrl_remap` | `test_peripheral_regs.py` | Impl | — | REMAP\_CTRL changes address decode |
| PERIPH\_006 | `test_gpio_data_loopback` | `test_peripheral_regs.py` | Impl | — | GPIO write-read on pins with pullups |
| PERIPH\_007 | `test_test_slave_scratchpad` | `test_peripheral_regs.py` | Impl | — | APB test slave 4 KB scratchpad |
| **7b. Peripheral Functional Tests** | | `test_peripheral_functional.py` | | | |
| PERIPH\_010 | `test_timer_reload_wrap` | `test_peripheral_functional.py` | Impl | — | Timer reload/wrap-around and stop |
| PERIPH\_011 | `test_timer_interrupt_status` | `test_peripheral_functional.py` | Impl | — | Timer interrupt flag after countdown |
| PERIPH\_012 | `test_timer1_independent` | `test_peripheral_functional.py` | Impl | — | Timer 0 and Timer 1 run independently |
| PERIPH\_013 | `test_timer_accuracy` | `test_peripheral_functional.py` | Impl | — | Timer countdown rate consistency |
| PERIPH\_020 | `test_dualtimer_countdown` | `test_peripheral_functional.py` | Impl | — | Dual-timer Timer1 counts down |
| PERIPH\_021 | `test_dualtimer_32bit_mode` | `test_peripheral_functional.py` | Impl | — | Dual-timer 32-bit counter mode |
| PERIPH\_022 | `test_dualtimer_oneshot` | `test_peripheral_functional.py` | Impl | — | Dual-timer one-shot stops at zero |
| PERIPH\_023 | `test_dualtimer_interrupt_status` | `test_peripheral_functional.py` | Impl | — | Dual-timer RIS/MIS status registers |
| PERIPH\_024 | `test_dualtimer_timer2_independent` | `test_peripheral_functional.py` | Impl | — | Dual-timer Timer1 and Timer2 independent |
| PERIPH\_025 | `test_dualtimer_background_load` | `test_peripheral_functional.py` | Impl | — | Background load doesn't restart counter |
| PERIPH\_030 | `test_watchdog_reset_values` | `test_peripheral_functional.py` | Impl | — | Watchdog CTRL/RIS/MIS/LOCK reset state |
| PERIPH\_031 | `test_watchdog_countdown` | `test_peripheral_functional.py` | Impl | — | Watchdog counts down from load value |
| PERIPH\_032 | `test_watchdog_write_protection` | `test_peripheral_functional.py` | Impl | — | Locked watchdog rejects register writes |
| PERIPH\_033 | `test_watchdog_interrupt_status` | `test_peripheral_functional.py` | Impl | — | Watchdog RIS/MIS after underflow |
| PERIPH\_040 | `test_uart2_reset_values` | `test_peripheral_functional.py` | Impl | — | UART 2 CTRL/BAUDDIV/STATE reset state |
| PERIPH\_041 | `test_uart2_bauddiv_readback` | `test_peripheral_functional.py` | Impl | — | UART 2 baud rate divider write-readback |
| PERIPH\_042 | `test_uart2_ctrl_readback` | `test_peripheral_functional.py` | Impl | — | UART 2 control register write-readback |
| PERIPH\_043 | `test_uart2_identity` | `test_peripheral_functional.py` | Impl | — | UART 2 PID/CID identification |
| PERIPH\_044 | `test_usrt1_reset_values` | `test_peripheral_functional.py` | Impl | — | USRT 1 (AXI-Stream UART) reset state |
| PERIPH\_045 | `test_usrt1_ctrl_readback` | `test_peripheral_functional.py` | Impl | — | USRT 1 control register write-readback |
| PERIPH\_050 | `test_gpio1_data_loopback` | `test_peripheral_functional.py` | Impl | — | GPIO port 1 data loopback |
| PERIPH\_051 | `test_gpio_outenset_readback` | `test_peripheral_functional.py` | Impl | — | GPIO output enable set/clear mechanism |
| PERIPH\_052 | `test_gpio_all_pins_pattern` | `test_peripheral_functional.py` | Impl | — | Walking-1 pattern on all 16 GPIO pins |
| PERIPH\_053 | `test_gpio_interrupt_config` | `test_peripheral_functional.py` | Impl | — | GPIO interrupt enable/type/polarity config |
| PERIPH\_054 | `test_gpio_altfunc_readback` | `test_peripheral_functional.py` | Impl | — | GPIO alternate function set/clear |
| PERIPH\_060 | `test_sysctrl_pmu_ctrl` | `test_peripheral_functional.py` | Impl | — | Sysctrl PMU\_CTRL register readback |
| PERIPH\_061 | `test_sysctrl_sys_ctrl` | `test_peripheral_functional.py` | Impl | — | Sysctrl SYS\_CTRL LOCKUPRESETEN |
| PERIPH\_062 | `test_sysctrl_reset_info` | `test_peripheral_functional.py` | Impl | — | Sysctrl RESET\_INFO read and W1C clear |
| PERIPH\_063 | `test_sysctrl_identity` | `test_peripheral_functional.py` | Impl | — | Sysctrl PID/CID identification |
| **8. System Table Tests** | | `test_systable.py` | | | |
| SYS\_001 | `test_systable_coresight_id` | `test_systable.py` | Impl | — | CoreSight ROM table PID/CID |
| SYS\_002 | `test_systable_rom_entries` | `test_systable.py` | Impl | — | ROM table entry 0 points to CPU debug |
| **9. Firmware Load Tests** | | `test_firmware.py` | | | |
| FW\_001 | `test_hex_upload_and_reset` | `test_firmware.py` | Impl | — | Upload hex, reset CPU, verify output |
| FW\_002 | `test_bootrom_read` | `test_firmware.py` | Impl | — | Read bootrom and verify non-zero content |
| **10. Memory Stress Tests** | | `test_memory_stress.py` | | | |
| MSTRESS\_001 | `test_sram_full_write_read` | `test_memory_stress.py` | Impl | — | Fill entire SRAM with pattern, read back |
| MSTRESS\_002 | `test_sram_address_uniqueness` | `test_memory_stress.py` | Impl | — | Verify each SRAM word is independently addressable |
| MSTRESS\_003 | `test_memory_alias_boundary` | `test_memory_stress.py` | Impl | — | Verify aliasing at physical/aperture boundary |

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

**Function:** `test_clocks` | **State: Impl**

Boot the SoC via the `NanoSoC` driver (clock, reset, bootcode, monitor mode). Confirms the basic clock and reset path works.

**Pass criteria:** `soc.start()` completes without timeout.

### ADP\_002 — ADP Read

**Function:** `test_adp_read` | **State: Impl**

Boot the SoC and verify ADP can receive the bootcode output stream.

**Pass criteria:** Bootcode completion marker received.

### ADP\_003 — Address Pointer

**Function:** `test_address_pointer` | **State: Impl**

Write 0x11 to 0x30000000 via the debug initiator, read it back and assert equality.

**Pass criteria:** Read-back matches written value.

### ADP\_004 — ADP Write Sequence

**Function:** `test_adp_write` | **State: Impl**

Write and read-back a single value, then write 4 sequential words and verify all 4 read back correctly. Tests multi-access sequences.

**Pass criteria:** All 5 write-read comparisons match.

### ADP\_005 — Hex Upload and Run

**Function:** `test_adp_hello` | **State: Impl**

Upload the hello hex file to IMEM via `soc.load_hex()`, exit monitor mode, reset the CPU, and capture the program output. Skips gracefully if the hex file doesn't exist.

**Pass criteria:** Program output received after upload and reset.

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

**Function:** `test_fill` | **State: Impl**

Rewritten to use the `NanoSoC` driver. Writes a random fill value to 16 consecutive words at 0x30000000, reads them all back and verifies each matches.

**Pass criteria:** All 16 read-back values match the fill value.

### MEM\_002 — Random Address Write-Read

**Function:** `random_address_read_write` | **State: Blocked**

Uses the old ADP driver with incorrect signal names (`txd8`/`rxd8`). Needs porting to the `NanoSoC` driver.

---

## 7. Peripheral Register Tests

**Test module:** `test_peripheral_regs.py`
**Driver:** `NanoSoC` (via `nanosoc_cocotb_driver.py`)

### PERIPH\_001 — Timer Reset Values | **State: Impl**

**Rationale:** The timers are the most commonly used CMSDK peripheral but no test currently verifies their control registers are at the correct reset state. A manufacturing defect or synthesis issue could leave registers at wrong values, which firmware would misinterpret.

**Method:** After boot, read CTRL, VALUE, RELOAD registers at timer\_0 (0x40000000) and timer\_1 (0x40001000). All should be 0x00000000 at reset.

| Register | Offset | Expected |
|:---------|:-------|:---------|
| CTRL     | 0x000  | 0x00     |
| VALUE    | 0x004  | 0x00     |
| RELOAD   | 0x008  | 0x00     |

**Pass criteria:** All timer registers read their documented reset values.

### PERIPH\_002 — Timer Countdown | **State: Impl**

**Rationale:** Verifies the timer actually counts. The existing tests only check bus connectivity (PID/CID) — they never confirm the peripheral functions. A timer that responds on the bus but doesn't count would pass all current tests.

**Method:** Write a reload value (e.g. 0x0000FFFF) to timer\_0 RELOAD, enable the timer (CTRL=0x01), wait some clock cycles, read VALUE and verify it has decremented below the reload value.

**Pass criteria:** VALUE < RELOAD after enabling the timer.

### PERIPH\_003 — Dual-Timer Reset Values | **State: Impl**

**Rationale:** The dual-timer has a non-zero reset value on its control registers (Timer1Control and Timer2Control reset to 0x20), which is different from the single timers. This is an easy misassumption to make and worth catching.

**Method:** Read Timer1Control (0x40002008) and Timer2Control (0x40002028) after reset.

**Pass criteria:** Both control registers read 0x20.

### PERIPH\_004 — Watchdog Lock and Identity | **State: Impl**

**Rationale:** The watchdog has a lock register (WDOGLOCK at 0x40008C00) that gates write access to all other registers. Verifying the lock/unlock mechanism works is critical — if the watchdog cannot be unlocked, firmware cannot configure it; if it cannot be locked, a stray write could accidentally trigger a reset.

**Method:** Read WDOGLOCK (should be 0x00000000 = unlocked after reset). Write 0x1 to lock it. Read back WDOGLOCK (should return 0x1 = locked). Write the unlock key 0x1ACCE551. Read back (should return 0x0 = unlocked).

**Pass criteria:** Lock and unlock transitions verified.

### PERIPH\_005 — System Controller Remap | **State: Impl**

**Rationale:** The REMAP\_CTRL register at 0x4001F000 controls whether address 0x00000000 maps to bootrom or IMEM. This is the mechanism the bootloader uses to hand off to user code. Incorrect remap behaviour would brick the SoC after bootloader completes. No current test verifies the remap mechanism through the debug initiator.

**Method:** After boot (remap should already be active, reading 0x1), read REMAP\_CTRL. Then read 4 bytes from 0x00000000 and from 0x10000000 — they should match (both pointing to IMEM after remap). Write 0x0 to REMAP\_CTRL, read from 0x00000000 again — it should now match bootrom content (read from 0x08000000). Restore remap to 0x1.

**Pass criteria:** Address 0x00000000 content changes with remap bit.

### PERIPH\_006 — GPIO Data Loopback | **State: Impl**

**Rationale:** GPIO is the primary user-facing peripheral but no test exercises the data registers. The testbench has pullups on GPIO pins, so writing to DATAOUT and reading DATA should produce predictable results on pins configured as outputs.

**Method:** On gpio\_0 (0x40010000): set OUTENSET to enable some pins as outputs, write a pattern to DATAOUT, read back DATA register and verify the output pins reflect the written value.

**Pass criteria:** DATA register reflects written DATAOUT for enabled output pins.

### PERIPH\_007 — APB Test Slave Scratchpad | **State: Impl**

**Rationale:** The test slave at 0x4000B000 has a 4 KB read/write scratchpad. This is the simplest peripheral to verify — it's just memory on the APB bus. It serves as a baseline: if this test fails, the APB bus itself has issues, isolating failures from peripheral-specific logic.

**Method:** Write random words to several addresses within 0x4000B000-0x4000BFFF, then read them all back and compare.

**Pass criteria:** All write-read comparisons match.

---

## 7b. Peripheral Functional Tests

**Test module:** `test_peripheral_functional.py`
**Driver:** `NanoSoC` (via `nanosoc_cocotb_driver.py`)

### PERIPH\_010 — Timer Reload Wrap | **State: Impl**

**Rationale:** PERIPH\_002 confirms the timer counts down but doesn't verify it reloads after reaching zero or that disabling the timer stops the count. A timer that counts once and stops would pass PERIPH\_002 but break any firmware depending on periodic interrupts.

**Method:** Load timer\_0 with a small reload value (0x100), enable, take 5 consecutive reads. Verify values remain within [0, RELOAD]. Then disable the timer and verify VALUE stops changing between two reads.

**Pass criteria:** Timer values stay within reload range; VALUE is constant after CTRL=0.

### PERIPH\_011 — Timer Interrupt Status | **State: Impl**

**Rationale:** No existing test verifies the timer interrupt output. Firmware relies on polling or ISR-driven timer interrupts. If the interrupt flag never sets, periodic task scheduling fails silently.

**Method:** Load timer\_0 with a very small reload (0x10), enable with IRQEN=1. After ADP latency (hundreds of cycles), read the INTCLEAR register (which returns interrupt status on read). Verify bit 0 is set. Clear it and disable the timer.

**Pass criteria:** Interrupt status bit set after countdown.

### PERIPH\_012 — Timer 1 Independence | **State: Impl**

**Rationale:** Timer 0 and Timer 1 share the same APB bus. A decode error could cause writes to one timer to affect the other. This verifies they are independently addressable.

**Method:** Load different reload values into timer\_0 (0xFFFF) and timer\_1 (0xFF0000). Enable both. Read both VALUE registers and verify each is within its own reload range, with timer\_1's value significantly larger than timer\_0's.

**Pass criteria:** Each timer VALUE is within its respective reload range; timer\_1 VALUE > timer\_0 VALUE.

### PERIPH\_013 — Timer Accuracy | **State: Impl**

**Rationale:** Verifies the timer counts at a consistent rate. If the timer clock is mis-connected or gated incorrectly, the count rate would be erratic.

**Method:** Load timer\_0 with maximum value (0xFFFFFFFF) to avoid wrap. Take 4 consecutive VALUE reads and compute 3 deltas. Verify all deltas are positive and within 50% of their average (allowing for ADP read jitter).

**Pass criteria:** All deltas positive and within 2x of the average.

### PERIPH\_020 — Dual-Timer Countdown | **State: Impl**

**Rationale:** PERIPH\_003 only checks dual-timer reset values. No test confirms the dual-timer actually counts. This is the most basic functional test for this peripheral.

**Method:** Load Timer1Load with 0xFFFF, enable in 32-bit periodic mode. Read Timer1Value and verify it has decremented below the load value.

**Pass criteria:** Timer1Value < Timer1Load after enable.

### PERIPH\_021 — Dual-Timer 32-bit Mode | **State: Impl**

**Rationale:** The dual-timer supports both 16-bit and 32-bit counting modes (TIMER\_SIZE bit in control). If the 32-bit mode doesn't work, only the lower 16 bits count — values above 0xFFFF would be wrong.

**Method:** Load 0x00FFFFFF (>16 bits), enable in 32-bit mode. Read Timer1Value and verify it is > 0xFFFF, proving the upper bits are active.

**Pass criteria:** Timer1Value > 0xFFFF.

### PERIPH\_022 — Dual-Timer One-Shot | **State: Impl**

**Rationale:** One-shot mode is used for single-fire delays. If broken, the timer would keep reloading and fire spurious interrupts.

**Method:** Load a tiny value (0x8), enable in one-shot + 32-bit mode. After ADP latency, read Timer1Value twice. Both should be 0 (timer stopped at zero).

**Pass criteria:** Timer1Value = 0 on consecutive reads.

### PERIPH\_023 — Dual-Timer Interrupt Status | **State: Impl**

**Rationale:** Verifies raw and masked interrupt status registers (RIS/MIS) respond correctly to timer underflow.

**Method:** Load tiny value (0x4), enable with IRQEN. Read Timer1RIS and Timer1MIS — both should have bit 0 set. Clear interrupt, disable timer, verify RIS clears.

**Pass criteria:** RIS and MIS set after underflow, RIS clear after INTCLR+disable.

### PERIPH\_024 — Dual-Timer Timer2 Independence | **State: Impl**

**Rationale:** Timer1 and Timer2 within the dual-timer module could alias if the sub-decode is wrong.

**Method:** Load different values into Timer1 (0xFFFF) and Timer2 (0xFF0000). Enable both. Read both values and verify Timer2 > Timer1.

**Pass criteria:** Each timer within its own load range; Timer2 value > Timer1 value.

### PERIPH\_025 — Dual-Timer Background Load | **State: Impl**

**Rationale:** The background load register (BGLoad) updates the reload value without restarting the current count. If BGLoad acts like LOAD, it would disrupt timing of the current period.

**Method:** Start Timer1 with a large load (0x00FFFFFF). Write a small background load (0xFF). Read Timer1Value — should still be counting from the original large load (value >> 0xFF).

**Pass criteria:** Timer1Value > BGLoad value after writing BGLoad.

### PERIPH\_030 — Watchdog Reset Values | **State: Impl**

**Rationale:** PERIPH\_004 only checks the lock register. This verifies WDOGCONTROL, WDOGRIS, WDOGMIS, and WDOGLOCK are all at expected reset state.

**Method:** Read WDOGCONTROL (expect 0), WDOGRIS (expect 0), WDOGMIS (expect 0), WDOGLOCK (expect 0) after boot.

**Pass criteria:** All registers at zero.

### PERIPH\_031 — Watchdog Countdown | **State: Impl**

**Rationale:** No test confirms the watchdog actually counts down. A watchdog that doesn't count would never trigger a reset, silently defeating the purpose of having one.

**Method:** Unlock, load 0x0FFFFFFF, enable interrupt (INTEN=1, RESEN=0). Read WDOGVALUE and verify it has decremented. Disable and clear.

**Pass criteria:** WDOGVALUE < WDOGLOAD after enable.

### PERIPH\_032 — Watchdog Write Protection | **State: Impl**

**Rationale:** The watchdog lock mechanism is safety-critical — it prevents accidental reconfiguration. PERIPH\_004 verifies the lock register transitions, but doesn't verify that locked writes are actually rejected.

**Method:** Unlock, write 0xAAAAAAAA to WDOGLOAD, verify it. Lock the watchdog. Write 0x55555555 to WDOGLOAD. Read back — should still be 0xAAAAAAAA.

**Pass criteria:** WDOGLOAD unchanged after locked write attempt.

### PERIPH\_033 — Watchdog Interrupt Status | **State: Impl**

**Rationale:** Firmware uses the watchdog interrupt to detect the first timeout and either service the watchdog or prepare for reset. If RIS/MIS don't set, the ISR never fires.

**Method:** Unlock, load tiny value (0x10), enable INTEN. Read WDOGRIS and WDOGMIS — both should be set. Clear and disable.

**Pass criteria:** RIS and MIS set after underflow.

### PERIPH\_040 — UART 2 Reset Values | **State: Impl**

**Rationale:** UART 2 at 0x40006000 has no tests at all in the existing plan. This is a standard CMSDK UART with baud rate divider — a completely different IP from the USRT used on slots 4-5. Basic register verification ensures it is correctly instantiated.

**Method:** Read CTRL (expect 0), BAUDDIV (expect 0), STATE (expect TX\_FULL=0, RX\_FULL=0).

**Pass criteria:** All registers at expected reset state.

### PERIPH\_041 — UART 2 Baud Rate Divider | **State: Impl**

**Rationale:** The baud rate divider is a 20-bit register unique to this UART. If truncated or mis-wired, the UART would run at the wrong baud rate.

**Method:** Write several test values to BAUDDIV and read back. Verify the 20-bit field is correctly stored.

**Pass criteria:** All write-readback comparisons match (masked to 20 bits).

### PERIPH\_042 — UART 2 Control Register | **State: Impl**

**Rationale:** The UART CTRL register has 7 independently settable bits (TX/RX enable, interrupt enables, high-speed test). Verifying each bit can be set and read back confirms the register is fully wired.

**Method:** Write various bit patterns to CTRL and read back each time.

**Pass criteria:** All write-readback comparisons match (masked to 7 bits).

### PERIPH\_043 — UART 2 Identity | **State: Impl**

**Rationale:** Confirms the correct UART IP is at slot 6 (PID0=0x21 for CMSDK UART).

**Method:** Read PID0, PID1, PID2, PID4, CID0-CID3 and compare against expected values.

**Pass criteria:** All PID/CID values match.

### PERIPH\_044 — USRT 1 Reset Values | **State: Impl**

**Rationale:** USRT 0 (slot 4, 0x40004000) is used by the ADP debug interface and cannot be tested directly. USRT 1 (slot 5, 0x40005000) is available and should be verified. The USRT is a different IP than the standard UART — it uses AXI-Stream instead of a baud rate divider.

**Method:** Read CTRL (expect 0) and STATE after reset.

**Pass criteria:** CTRL at zero.

### PERIPH\_045 — USRT 1 Control Register | **State: Impl**

**Rationale:** Verifies the 6-bit CTRL register (TX/RX enable, 4 interrupt enables) can be written and read back.

**Method:** Write various bit patterns to USRT1 CTRL and read back each time.

**Pass criteria:** All write-readback comparisons match (masked to 6 bits).

### PERIPH\_050 — GPIO Port 1 Data Loopback | **State: Impl**

**Rationale:** PERIPH\_006 only tests GPIO port 0. GPIO port 1 at 0x40011000 is a separate instantiation that could have different wiring issues.

**Method:** Same as PERIPH\_006 but on GPIO port 1: enable outputs, write pattern, read DATAOUT.

**Pass criteria:** DATAOUT reflects written pattern.

### PERIPH\_051 — GPIO Output Enable Set/Clear | **State: Impl**

**Rationale:** The OUTENSET/OUTENCLR registers use a set/clear idiom (write 1 to set, separate register to clear). If the clear register doesn't work, pins could be stuck as outputs. If set doesn't OR with existing state, enabling new pins would disable others.

**Method:** Clear all output enables. Verify OUTENSET reads 0. Set pins 4-7, verify. Set pins 0-3, verify the OR behaviour (should now be 0xFF). Clear 4-7, verify only 0-3 remain.

**Pass criteria:** Each set/clear operation produces the expected cumulative result.

### PERIPH\_052 — GPIO All Pins Walking-1 | **State: Impl**

**Rationale:** PERIPH\_006 only tests 8 pins with a single pattern. A walking-1 through all 16 pins catches stuck-at or shorted pin faults.

**Method:** Enable all 16 GPIO0 pins as outputs. Write walking-1 pattern (0x0001, 0x0002, ..., 0x8000) and verify DATAOUT matches each time. Also test all-ones and all-zeros.

**Pass criteria:** Each walking-1 pattern and boundary pattern reads back correctly.

### PERIPH\_053 — GPIO Interrupt Configuration | **State: Impl**

**Rationale:** GPIO interrupts require configuring enable, type (edge/level), and polarity (high/low) registers. These are set/clear register pairs. If they don't work, GPIO interrupts won't fire or will trigger on the wrong edge.

**Method:** Clear all interrupt config. Set INTENSET on pins 0-7, verify. Set INTTYPESET on pins 0-3, verify. Set INTPOLSET on pins 0-1, verify. Clean up.

**Pass criteria:** Each interrupt config register reflects the set operations.

### PERIPH\_054 — GPIO Alternate Function | **State: Impl**

**Rationale:** The alternate function registers (ALTFUNCSET/ALTFUNCCLR) switch pins between GPIO and peripheral functions (e.g., UART). If broken, peripherals that share GPIO pins wouldn't work.

**Method:** Clear all alt functions. Set alt function on pins 4-7, read back ALTFUNCSET and verify. Clear all.

**Pass criteria:** ALTFUNCSET reflects the set operation.

### PERIPH\_060 — Sysctrl PMU\_CTRL | **State: Impl**

**Rationale:** PERIPH\_005 only tests REMAP\_CTRL. The PMU\_CTRL register enables the power management unit. If the register can't be written, PMU functionality would be inaccessible.

**Method:** Read PMU\_CTRL (expect 0 at reset). Write 1, read back, verify. Restore to 0.

**Pass criteria:** PMU\_CTRL reads back the written value.

### PERIPH\_061 — Sysctrl SYS\_CTRL | **State: Impl**

**Rationale:** SYS\_CTRL.LOCKUPRESETEN controls whether a CPU lockup triggers a system reset. If this register doesn't work, a locked-up CPU could hang the entire system indefinitely.

**Method:** Read SYS\_CTRL (expect 0 at reset). Write 1, read back, verify. Restore to 0.

**Pass criteria:** SYS\_CTRL reads back the written value.

### PERIPH\_062 — Sysctrl RESET\_INFO | **State: Impl**

**Rationale:** RESET\_INFO records the cause of the last reset (system request, watchdog, lockup). It's a write-1-to-clear (W1C) register — a non-standard access type that is easy to implement incorrectly.

**Method:** Read RESET\_INFO after boot. Verify only defined bits [2:0] are set. If non-zero, write the active bits back (W1C) and verify it clears to 0.

**Pass criteria:** Only defined bits set; W1C clear works.

### PERIPH\_063 — Sysctrl Identity | **State: Impl**

**Rationale:** Verifies the system controller is the correct IP at the correct address (PID0=0x26).

**Method:** Read PID0, PID1, PID2, PID4, CID0-CID3 and compare against expected values.

**Pass criteria:** All PID/CID values match.

---

## 8. System Table Tests (Proposed)

**Test module:** `test_systable.py`
**Driver:** `NanoSoC` (via `nanosoc_cocotb_driver.py`)

### SYS\_001 — CoreSight ROM Table Identity | **State: Impl**

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

### SYS\_002 — ROM Table Entry Decode | **State: Impl**

**Rationale:** The ROM table entries are pointers that debug tools follow to discover components. Entry 0 should point to the Cortex-M0 debug ROM (0xE00FF000). Verifying this ensures debug tools can enumerate the system correctly.

**Method:** Read entry 0 at 0xF0000000 + 0x000. The value should be a non-zero entry with bit [0] (present) set. Decode the address offset and verify it points to the expected base address. Read entry 1 and verify it is not present (bit [0] = 0). Read entry at offset 0x010+ and verify it is 0x00000000 (end-of-table).

**Pass criteria:** Entry 0 present and pointing to correct debug ROM, entry 1 not present, end-of-table marker found.

---

## 9. Firmware Load Tests (Proposed)

**Test module:** `test_firmware.py`
**Driver:** `NanoSoC` (via `nanosoc_cocotb_driver.py`)

### FW\_001 — Hex Upload and CPU Reset | **State: Impl**

**Rationale:** The broken `test_adp_hello` (ADP\_005) was attempting this but has bugs. A working firmware load test is essential — it validates the complete path: HOSTIO4 -> ADP -> upload -> memory -> CPU fetch -> execute -> output. This is the ultimate system-level integration test.

**Method:** Using `soc.load_hex()`, upload the `hello` test program to IMEM at 0x10000000. Call `soc.reset()` to restart the CPU. Read characters from the SoC and verify the hello program's expected output appears.

**Pass criteria:** Hello program output received after upload and reset.

### FW\_002 — Bootrom Content Verification | **State: Impl**

**Rationale:** The bootrom is preloaded at synthesis time. If the bootrom content is wrong (e.g. simulation model not initialised), the SoC won't boot at all. Currently, boot failures just result in a timeout — a direct content check gives a clearer diagnostic.

**Method:** Read the first few words from bootrom at 0x00000000 (before remap) or 0x08000000 (always-valid alias). The first word should be the initial SP value and the second word should be the reset vector — both should be non-zero and within the bootrom address range.

**Pass criteria:** First two words are non-zero and consistent with a valid ARM vector table.

---

## 10. Memory Stress Tests (Proposed)

**Test module:** `test_memory_stress.py`
**Driver:** `NanoSoC` (via `nanosoc_cocotb_driver.py`)

### MSTRESS\_001 — SRAM Full Write-Read | **State: Impl**

**Rationale:** Current memory tests only probe a handful of addresses. An SRAM manufacturing defect (stuck bit, address line short) may only manifest at specific addresses. Writing a unique pattern to every word and reading it all back catches single-bit failures and address-line faults. This is a standard production test pattern.

**Method:** Write the word's own address as data to every 4th word in SRAM\_0 (0x80000000, physical size 1 MB, step by 1 KB to keep runtime manageable — ~1024 locations). Then read all locations back and verify each contains its own address.

**Pass criteria:** All locations read back their expected address-as-data pattern.

### MSTRESS\_002 — SRAM Address Uniqueness | **State: Impl**

**Rationale:** If two address lines are shorted together on the bus or in the SRAM, writes to different addresses would alias. Walking-1 through the address bits catches this class of fault which the random-address tests may miss.

**Method:** Within SRAM\_0, write a unique value to addresses at each power-of-2 offset (0x80000000, 0x80000004, 0x80000008, 0x80000010, ..., up to physical size). Then read all back and verify no value was overwritten by a later write to a different address.

**Pass criteria:** Every power-of-2 address retains its unique written value.

### MSTRESS\_003 — Memory Alias Boundary | **State: Impl**

**Rationale:** SRAM\_0 has 1 MB of physical memory but a 256 MB aperture. Addresses above the physical size alias back (wrap around). Firmware that accidentally accesses the aliased region should still get valid data. This test verifies the wrap-around works correctly.

**Method:** Write a value to SRAM\_0 base (0x80000000). Read from the alias address (0x80000000 + physical\_size = 0x80100000). They should return the same data because the upper address bits are not decoded by the SRAM.

**Pass criteria:** Aliased address returns the same data as the base address.

---

## Known Issues

| ID | Issue | Severity | Status | Details |
|:---|:------|:---------|:-------|:--------|
| BUG-001 | `test_clocks` wrong arg count | High | **Fixed** | Rewrote `test_adp.py` to use `NanoSoC` driver |
| BUG-002 | `test_adp_write` undefined methods | High | **Fixed** | Rewrote to use `NanoSoC` driver `write32`/`read32` |
| BUG-003 | `test_adp_hello` missing await | High | **Fixed** | Rewrote to use `NanoSoC` driver `load_hex`/`reset` |
| BUG-004 | `wait_prompt` string comparison | Low | **Fixed** | Removed broken helper — no longer used |
| BUG-005 | `test_fill` undocumented ADP cmds | Medium | **Fixed** | Rewrote `fill_test_dmem.py` to use `NanoSoC` driver `write32`/`read32` |
| BUG-006 | Old tests use wrong signal names | Medium | Open | `adp_tests.py`, `test_region_probe.py`, `read_write_test.py` use `AxiStreamBus.from_prefix(dut, "txd8")` but testbench signals are `axis_rx0_*`/`axis_tx0_*`. These tests need porting to the `NanoSoC` driver. |
| BUG-007 | `soc_model` build incomplete | Medium | Open | `make soc_model` fails with exit code 1 (39 warnings, missing port references). Blocks generation of `makefile.flist` needed for cocotb simulation. Run `source set_env.sh` and fix model warnings to enable simulation. |

---

## Remaining Coverage Gaps

The following areas cannot be fully tested via the debug initiator (HOSTIO4/ADP) and require either CPU-executed firmware tests or additional testbench infrastructure:

| Area | Gap | Why | Mitigation |
|:-----|:----|:----|:-----------|
| **Timer prescaler** | Dual-timer prescale modes (/16, /256) | ADP latency (~1000s of cycles per read) masks prescaler effects — all modes appear fast | Firmware-based test with cycle-counting or capture/compare |
| **UART TX/RX data path** | No test sends/receives actual serial data through UART 2 | UART 2 TX/RX pins are external; no loopback in testbench | Add testbench loopback wire (TXD -> RXD) or use firmware test |
| **USRT 0 (ADP port)** | Cannot test — it's the debug interface itself | Testing it would break the debug channel | Verify indirectly: if ADP works, USRT 0 works |
| **GPIO pin-level behaviour** | DATA register reads depend on testbench pullups | Without external stimulus, can only verify output latch (DATAOUT), not input path | Add testbench stimulus or firmware GPIO test |
| **Interrupt delivery to CPU** | Tests verify peripheral IRQ status bits but not CPU-level interrupt handling | Debug initiator cannot trigger/observe CPU NVIC interrupts | Firmware-based ISR tests for each peripheral |
| **Watchdog system reset** | Cannot test RESEN=1 (reset enable) | Triggering a watchdog reset would reset the SoC and break the debug session | Firmware test that enables watchdog reset and verifies RESET\_INFO after reboot |
| **DMA controller** | No tests at all for DMAC at 0x50000000 | DMA requires programming channel descriptors and observing memory transfers — complex setup via ADP | Firmware-based DMA transfer test |
| **Expansion region** | No tests for expansion peripherals at 0x60000000 | Region contents are design-specific and may not be populated | Test when expansion peripherals are integrated |
| **Power management** | PMU\_CTRL can be set but PMU behaviour not verified | PMU effects (clock gating, sleep modes) cannot be observed through ADP | Firmware test with power measurement or status register checks |
