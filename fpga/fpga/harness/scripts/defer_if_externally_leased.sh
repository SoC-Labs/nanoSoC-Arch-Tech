#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# defer_if_externally_leased.sh — let a scheduled reflash CI back off when a
# human / multicore deploy is using the board.
#
# Problem (docs/BRINGUP_TODO.md "P0 — CI race that's actively blocking
# iteration"): the eth-subsystem scheduled FPGA-deploy reflashes
# pynq_z2_01_pl with nanosoc_eth_flash_design_wrapper.bin every ~16 min.
# It `fpgahub lease acquire --wait`s, so it grabs the board the instant a
# manual multicore deploy releases (or between renewals) and clobbers it.
#
# Fix (option (c)): before the reflash job acquires, ask the daemon who
# holds the board. If an active lease is held by anyone OTHER than the CI
# reflash identity, DEFER — exit EX_TEMPFAIL (75) so the job can skip this
# cycle without reflashing. The scheduled pipeline simply tries again next
# tick; the multicore deploy stays intact as long as it holds (and renews)
# its own lease.
#
# Identity convention: CI reflash jobs MUST acquire with a stable sentinel,
#   fpgahub lease acquire <board> --holder "$CI_LEASE_HOLDER" ...
# (default sentinel: "ci-reflash"). Any lease whose holder/user is not that
# sentinel is treated as a foreign (non-CI) lease and triggers the defer.
#
# Usage:
#   defer_if_externally_leased.sh --board <name> [--ci-holder <s>] [--ci-user <s>]
#
# Exit codes:
#   0   clear to proceed   (board free, or held by the CI sentinel itself)
#   75  defer / try later  (a foreign, non-CI lease is held; EX_TEMPFAIL)
#   2   usage error
#   127 fpgahub not on PATH
#
# Fail-safe: if the lease state cannot be determined (daemon unreachable,
# unexpected output), DEFER (75) rather than risk clobbering a live deploy
# — a skipped scheduled reflash is harmless; a stomped deploy is not.
#
# No jq dependency (parses the documented `fpgahub lease show` text:
#   "not leased"  |  "held by <holder> (user <user>, expires <ts>)").
#
# A joint work commissioned on behalf of SoC Labs, under Arm Academic
# Access license.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
set -euo pipefail

EX_OK=0
EX_DEFER=75
EX_USAGE=2
EX_NOFPGAHUB=127

usage() {
    cat >&2 <<EOF
usage: defer_if_externally_leased.sh --board <name> [--ci-holder <s>] [--ci-user <s>]
  Exit 0 = clear to proceed; 75 = defer (foreign lease held).
  CI sentinel defaults: --ci-holder \$CI_LEASE_HOLDER or "ci-reflash".
EOF
    exit $EX_USAGE
}

BOARD=""
CI_HOLDER="${CI_LEASE_HOLDER:-ci-reflash}"
CI_USER="${CI_LEASE_USER:-${CI_LEASE_HOLDER:-ci-reflash}}"

while [ $# -gt 0 ]; do
    case "$1" in
        --board)     BOARD="${2:-}";     shift 2 ;;
        --ci-holder) CI_HOLDER="${2:-}"; shift 2 ;;
        --ci-user)   CI_USER="${2:-}";   shift 2 ;;
        -h|--help)   usage ;;
        *) echo "defer_if_externally_leased.sh: unknown arg: $1" >&2; usage ;;
    esac
done

[ -n "$BOARD" ] || { echo "defer_if_externally_leased.sh: --board is required" >&2; usage; }

if ! command -v fpgahub >/dev/null 2>&1; then
    echo "defer_if_externally_leased.sh: fpgahub not on PATH" >&2
    exit $EX_NOFPGAHUB
fi

# Query lease state. fpgahub exits 0 for both free and held; an error
# (non-zero) or unparseable output is treated fail-safe as "defer".
raw=""
if ! raw=$(fpgahub lease show "$BOARD" 2>&1); then
    echo "defer: 'fpgahub lease show $BOARD' failed — cannot confirm board is free; backing off:" >&2
    echo "  $raw" >&2
    exit $EX_DEFER
fi

# Strip rich/ANSI styling so parsing is TTY-independent.
clean=$(printf '%s\n' "$raw" | sed -E 's/\x1b\[[0-9;]*m//g')

if printf '%s' "$clean" | grep -qi 'not leased'; then
    echo "clear: $BOARD is not leased — proceeding." >&2
    exit $EX_OK
fi

line=$(printf '%s\n' "$clean" | grep -i '^held by ' | head -1 || true)
if [ -z "$line" ]; then
    echo "defer: unexpected 'fpgahub lease show' output — cannot confirm holder; backing off:" >&2
    printf '%s\n' "$clean" | sed 's/^/  /' >&2
    exit $EX_DEFER
fi

# "held by <holder> (user <user>, expires <ts>)"
holder=$(printf '%s' "$line" | sed -n 's/^[Hh]eld by \(.*\) (user .*/\1/p')
luser=$(printf  '%s' "$line" | sed -n 's/^[Hh]eld by .* (user \(.*\), expires .*/\1/p')
holder=$(printf '%s' "$holder" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
luser=$(printf  '%s' "$luser"  | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

if [ -z "$holder" ] && [ -z "$luser" ]; then
    echo "defer: could not parse holder from: '$line' — backing off." >&2
    exit $EX_DEFER
fi

if [ "$holder" = "$CI_HOLDER" ] || { [ -n "$CI_USER" ] && [ "$luser" = "$CI_USER" ]; }; then
    echo "clear: $BOARD held by the CI reflash identity (holder='$holder' user='$luser') — proceeding." >&2
    exit $EX_OK
fi

echo "DEFER: $BOARD is held by a non-CI lease (holder='$holder' user='$luser')." >&2
echo "       Skipping this reflash cycle so the live deploy is not clobbered." >&2
exit $EX_DEFER
