#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# test_with_lease.sh -- with_lease.sh against a fake `fpgahub` CLI (no hub, no
# board). Exit status = failed checks.
#
#   bash fpga/fpga/harness/tests/test_with_lease.sh [path/to/with_lease.sh]
#
# The fake models fpgahub 0.3.0: `lease acquire <member>` grants a token,
# `board status <member>` fails ("no such board"), and `board status <group>`
# returns the member list with host_ssh per member. FAKE_SCHEMA=flat models
# the older CLI, where `board status <member>` returns the flat object.
#
# Checks: the lease is released on success, on a failing command, and when
# status lookup fails after the lease was granted; PYNQ_HOST/PYNQ_PROXY come
# from the right member under both schemas.
#
# Pass the pre-fix script as the argument to see the leak checks fail.
#-----------------------------------------------------------------------------
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${1:-$HERE/../scripts/with_lease.sh}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fails=0

mkdir -p "$T/bin"
cat > "$T/bin/fpgahub" <<'FAKE'
#!/usr/bin/env bash
log="$FAKE_LOG"
echo "$*" >> "$log"
case "$1 $2" in
    "lease acquire")
        echo "granted token=TOK123 expires=2099-01-01T00:00:00Z tier=interactive" ;;
    "lease release")
        echo "RELEASED $3 $5" >> "$log.released" ;;
    "board status")
        name="$3"
        if [ "${FAKE_SCHEMA:-grouped}" = flat ]; then
            [ "$name" = pynq_z2_09_pl ] || { echo "no such board: '$name'" >&2; exit 1; }
            echo '{"name":"pynq_z2_09_pl","host_ssh":"xilinx@10.9.9.101","host_proxy":"","host_dev_host":"dev@devhost"}'
            exit 0
        fi
        [ "$name" = pynq_z2_09 ] && [ -z "${FAKE_NO_GROUP:-}" ] || { echo "no such board: '$name'" >&2; exit 1; }
        cat <<'JSON'
{"name":"pynq_z2_09","members":[
 {"name":"pynq_z2_09_ps","status":{"host_ssh":"xilinx@ps.example","host_proxy":"","host_dev_host":"dev@devhost"}},
 {"name":"pynq_z2_09_pl","status":{"host_ssh":"xilinx@10.9.9.101","host_proxy":"","host_dev_host":"dev@devhost"}}]}
JSON
        ;;
    *) echo "fake fpgahub: unhandled: $*" >&2; exit 2 ;;
esac
FAKE
chmod +x "$T/bin/fpgahub"

check() {  # check <label> <0|1 ok> <detail>
    if [ "$2" = 1 ]; then echo "PASS  $1"; else echo "FAIL  $1  -- $3"; fails=$((fails + 1)); fi
}

run() {  # run <case> [env...] -- <cmd...>; sets RC, OUT, REL
    local name="$1"; shift
    local envs=()
    while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
    export FAKE_LOG="$T/$name.log"; : > "$FAKE_LOG"; rm -f "$FAKE_LOG.released"
    OUT=$(env -u FPGA_BOARD -u FPGA_LEASE_TOKEN -u PYNQ_PROXY PATH="$T/bin:$PATH" "${envs[@]}" \
          bash "$SUT" --board pynq_z2_09_pl --ttl 60 -- "$@" 2>&1)
    RC=$?
    REL=$(cat "$FAKE_LOG.released" 2>/dev/null)
}

# 1. Success, grouped (0.3.0) schema: host resolved from the PL member.
run ok_grouped -- bash -c 'echo "HOST=$PYNQ_HOST PROXY=$PYNQ_PROXY"'
check "grouped: command ran"         "$([ $RC = 0 ] && echo 1 || echo 0)" "rc=$RC out=$OUT"
check "grouped: PL member's host"    "$(grep -q 'HOST=xilinx@10.9.9.101 ' <<<"$OUT" && echo 1 || echo 0)" "$OUT"
check "grouped: proxy = dev host"    "$(grep -qE 'PROXY=dev@devhost(\.|$)' <<<"$OUT" && echo 1 || echo 0)" "$OUT"
check "grouped: lease released"      "$([ "$REL" = "RELEASED pynq_z2_09_pl TOK123" ] && echo 1 || echo 0)" "released='$REL'"

# 2. Success, flat (older CLI) schema.
run ok_flat FAKE_SCHEMA=flat -- bash -c 'echo "HOST=$PYNQ_HOST"'
check "flat: PL host"                "$(grep -q 'HOST=xilinx@10.9.9.101' <<<"$OUT" && echo 1 || echo 0)" "$OUT"
check "flat: lease released"         "$([ -n "$REL" ] && echo 1 || echo 0)" "released='$REL'"

# 3. The command fails: its status propagates and the lease is released.
run cmd_fails -- bash -c 'exit 7'
check "failing cmd: rc propagates"   "$([ $RC = 7 ] && echo 1 || echo 0)" "rc=$RC"
check "failing cmd: lease released"  "$([ -n "$REL" ] && echo 1 || echo 0)" "released='$REL'"

# 4. Status lookup fails AFTER the lease was granted (the leak).
run status_fails FAKE_NO_GROUP=1 -- bash -c 'echo SHOULD-NOT-RUN'
check "status fails: cmd not run"    "$(grep -q SHOULD-NOT-RUN <<<"$OUT" && echo 0 || echo 1)" "$OUT"
check "status fails: non-zero rc"    "$([ $RC != 0 ] && echo 1 || echo 0)" "rc=$RC"
check "status fails: lease released" "$([ -n "$REL" ] && echo 1 || echo 0)" "released='$REL' (lease leaked)"

echo "== $fails failed"
exit "$fails"
