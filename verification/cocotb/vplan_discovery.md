# NanoSoC Discovery Table Verification Plan

Verify the auto-generated bus topology discovery table registers. The discovery table is generated from the SoC YAML description by the `soc_model` discovery backend, compiled to RDL, and synthesised to RTL via peakrdl-regblock. It is mapped at APB slot 13 (0x4000\_D000) in the `soc_peripheral` region.

- **Test module:** `test_discovery.py`
- **Driver:** `nanosoc_cocotb_driver.py` (`NanoSoC` class)
- **RTL:** `build_soc/rtl/nanosoc_ahb_interconnect_discovery/`
- **Register map:** `build_soc/discovery/nanosoc_ahb_interconnect_discovery.yaml`
- **Base address:** 0x4000D000
- **Interface:** HOSTIO4 channel 0 (ADP) via the debug initiator

---

## DISC\_001 — Discovery Table Header

**Test function:** `test_discovery_header`

**Description:** Read the four header registers and verify against expected constants.

**Goal:** Confirm the discovery table is present, accessible, and correctly identifies itself.

**Method:** Read 32-bit words at offsets 0x000, 0x004, 0x008, 0x00C and compare each against the expected hardcoded value.

### Registers

| Register           | Offset | Expected     | Description |
|:-------------------|:-------|:-------------|:------------|
| TABLE\_ID          | 0x000  | 0x534F4344   | Magic number "SOCD" |
| TABLE\_VERSION     | 0x004  | 0x00000001   | Format version 1 |
| TABLE\_SIZE        | 0x008  | 0x00200407   | 7 targets, 4 initiators, 32-bit address width |
| INTERCONNECT\_NAME | 0x00C  | 0x6F6E616E   | "nano" in packed LE ASCII |

**Pass criteria:** All four registers match expected values exactly.

---

## DISC\_002 — Target Descriptors

**Test function:** `test_discovery_targets`

**Description:** Read all 7 target descriptors (BASE, SIZE, ATTR, NAME for each) and verify against the generated discovery YAML.

**Goal:** Confirm the discovery table accurately describes the interconnect's target address map.

**Method:** For each target index 0-6, read four descriptor registers at offsets `0x010 + (i * 16)`.

### Targets

| Idx | Name             | BASE         | SIZE         | ATTR         | NAME (packed) |
|:----|:-----------------|:-------------|:-------------|:-------------|:-------------|
| 0   | cpu\_ss          | 0x00000000   | 0x20000000   | 0x00000041   | 0x5F757063   |
| 1   | soc\_peripheral  | 0x40000000   | 0x10000000   | 0x00010032   | 0x5F636F73   |
| 2   | dmac\_ctrl       | 0x50000000   | 0x10000000   | 0x00020032   | 0x63616D64   |
| 3   | exp              | 0x60000000   | 0x20000000   | 0x00030032   | 0x00707865   |
| 4   | sram\_0          | 0x80000000   | 0x00010000   | 0x00040041   | 0x6D617273   |
| 5   | sram\_1          | 0x90000000   | 0x00010000   | 0x00050041   | 0x6D617273   |
| 6   | systable         | 0xF0000000   | 0x00040000   | 0x00060012   | 0x74737973   |

**ATTR field encoding:** `[3:0]` region\_type (1=memory, 2=periph), `[7:4]` sw\_access (1=ro, 3=rw, 4=rwx), `[15:8]` protocol (0=ahb), `[23:16]` target\_id

**Pass criteria:** All 28 register values (4 per target x 7 targets) match.

---

## DISC\_003 — Initiator Descriptors

**Test function:** `test_discovery_initiators`

**Description:** Read all 4 initiator descriptors (NAME, VISIBILITY for each) and verify name and target visibility bitmasks.

**Goal:** Confirm the discovery table correctly encodes which bus masters can access which targets.

**Method:** For each initiator index 0-3, read the two descriptor registers and compare.

### Initiators

| Idx | Name    | NAME (packed) | VISIBILITY   | Visible Targets |
|:----|:--------|:-------------|:-------------|:----------------|
| 0   | cpu\_0  | 0x5F757063   | 0x0000007E   | soc\_peripheral, dmac\_ctrl, exp, sram\_0, sram\_1, systable |
| 1   | debug   | 0x75626564   | 0x0000007F   | All 7 targets |
| 2   | dmac\_0 | 0x63616D64   | 0x0000003B   | cpu\_ss, soc\_peripheral, exp, sram\_0, sram\_1 |
| 3   | dmac\_1 | 0x63616D64   | 0x0000003B   | cpu\_ss, soc\_peripheral, exp, sram\_0, sram\_1 |

**Pass criteria:** All 8 register values (2 per initiator x 4) match.

---

## DISC\_004 — Cross-Check Against Python Address Map

**Test function:** `test_discovery_cross_check_address_map`

**Description:** Cross-check discovery table target base addresses against the generated Python address map to verify consistency between the two generated artifacts.

**Goal:** Confirm the discovery backend and address-map backend agree on the system topology.

**Method:** For each target in the discovery table, resolve its base address through `ADDRESS_MAP.resolve()` and verify the address map returns a valid region.

**Pass criteria:** Every discovery target base address resolves to a valid region in the Python address map.
