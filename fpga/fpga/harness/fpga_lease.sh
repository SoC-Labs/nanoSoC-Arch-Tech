#-----------------------------------------------------------------------------
# fpga_lease.sh — board-agnostic fpgahub lease helpers (sourceable).
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# Promoted from nanosoc-multicore-system/set_env.sh so every nanosoc system
# shares one board-lease lifecycle. Source this from a system's set_env.sh:
#
#     source "${SOCLABS_NANOSOC_ARCH_TECH_DIR}/fpga/fpga/harness/fpga_lease.sh"
#
# Then:
#     fpga_use fpga1           # explicit board name, 1h lease
#     fpga_use pynq_z2 2h      # capability tag, 2h lease
#     fpga_release             # release early (otherwise released on shell EXIT)
#
# Exports FPGA_BOARD / BOARD / PYNQ_HOST / PYNQ_PROXY for the deploy harness
# (fpga.mk). Requires `fpgahub` and `jq` on PATH. Nothing here is board- or
# system-specific.
#-----------------------------------------------------------------------------

fpga_use() {
    local tag_or_name=${1:-}
    local ttl=${2:-1h}
    if [ -z "$tag_or_name" ]; then
        echo "usage: fpga_use <board-name|capability> [ttl]" >&2
        return 2
    fi
    if ! command -v fpgahub >/dev/null 2>&1; then
        echo "fpga_use: fpgahub not found on PATH" >&2
        return 127
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "fpga_use: jq not found on PATH" >&2
        return 127
    fi

    local json
    if fpgahub board show "$tag_or_name" >/dev/null 2>&1; then
        json=$(fpgahub lease acquire "$tag_or_name" --ttl "$ttl" --json) || return $?
    else
        json=$(fpgahub lease acquire --capability "$tag_or_name" --ttl "$ttl" --json) || return $?
    fi

    local board token
    board=$(echo "$json" | jq -r '.board')
    token=$(echo "$json" | jq -r '.token')
    if [ -z "$board" ] || [ "$board" = "null" ]; then
        echo "fpga_use: could not parse board name from fpgahub output" >&2
        return 1
    fi

    export FPGA_BOARD="$board"
    export FPGA_LEASE_TOKEN="$token"
    export BOARD="$board"
    eval "$(fpgahub board status "$board" --json | jq -r '
        "export PYNQ_HOST=\(.host_ssh // "")\nexport PYNQ_PROXY=\(.host_proxy // "")"
    ')"
    trap "fpgahub lease release '$board' --token '$token' >/dev/null 2>&1" EXIT
    echo "fpga_use: acquired $board (ttl=$ttl) ssh=$PYNQ_HOST proxy=${PYNQ_PROXY:-none}"
}

fpga_release() {
    if [ -z "${FPGA_BOARD:-}" ] || [ -z "${FPGA_LEASE_TOKEN:-}" ]; then
        echo "fpga_release: no active lease in this shell" >&2
        return 1
    fi
    fpgahub lease release "$FPGA_BOARD" --token "$FPGA_LEASE_TOKEN"
    trap - EXIT
    unset FPGA_BOARD FPGA_LEASE_TOKEN BOARD PYNQ_HOST PYNQ_PROXY
}
