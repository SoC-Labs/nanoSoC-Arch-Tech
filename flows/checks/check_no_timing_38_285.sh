#!/usr/bin/env bash
# Copyright 2026, SoC Labs (www.soclabs.org)
#
# FPGA-flow guard: FAIL the build if Vivado emitted ANY
#   CRITICAL WARNING: [Timing 38-285] ... does not have a valid master clock
# (the exact warning the fix/qspi-constraints-regression branch *claims* the
# QSPI generated clock produces). Also fails on the generic phrasing in case the
# message id changes across Vivado versions.
#
# This is the dynamic complement to scripts/trace/lint_generated_clocks.py: the
# lint proves the EMITTED XDC is self-consistent (no dangling named master);
# this proves the NETLIST actually resolved every generated-clock source pin.
#
# Run it right after impl in the Vivado build wrapper, e.g. in
# pynq/build_nanosoc_multicore_design.tcl after launch_runs impl_1 / wait_on_run,
# or standalone in CI against the runs tree.
#
# Usage:
#   check_no_timing_38_285.sh [RUNS_DIR]
#     RUNS_DIR defaults to imp/fpga/project/pynq-z2/nanosoc_multicore_project.runs
#   Honours $RUNS_DIR env var if set and no arg given.
#
# Exit 0 = clean, 1 = at least one 38-285 / invalid-master-clock hit, 2 = no logs.
set -uo pipefail

RUNS_DIR="${1:-${RUNS_DIR:-imp/fpga/project/pynq-z2/nanosoc_multicore_project.runs}}"

if [ ! -d "$RUNS_DIR" ]; then
  echo "check_no_timing_38_285: runs dir not found: $RUNS_DIR" >&2
  exit 2
fi

# Search every synth/impl runme.log plus any top-level vivado*.log.
mapfile -t LOGS < <(find "$RUNS_DIR" -name 'runme.log' 2>/dev/null; \
                    find "$RUNS_DIR/.." -maxdepth 2 -name 'vivado*.log' 2>/dev/null)

if [ "${#LOGS[@]}" -eq 0 ]; then
  echo "check_no_timing_38_285: no runme.log/vivado.log under $RUNS_DIR" >&2
  exit 2
fi

# -E so both the message-id and the human phrasing are caught.
PAT='38-285|does not have a valid master clock or valid waveform|does not have a valid master clock'

HITS="$(grep -HnE "$PAT" "${LOGS[@]}" 2>/dev/null)"
if [ -n "$HITS" ]; then
  echo "check_no_timing_38_285: FAIL — invalid-master-clock warning(s) found:" >&2
  echo "$HITS" >&2
  exit 1
fi

echo "check_no_timing_38_285: OK — 0 Timing 38-285 / invalid-master-clock warnings across ${#LOGS[@]} log(s)"
exit 0
