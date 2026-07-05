#!/usr/bin/env bash

# Single-file customer runner. Execute on Linux OCI client 10.4.3.209.

# Customers sometimes invoke this file with "sh". Re-launch under Bash because
# the collector uses Bash arrays and PIPESTATUS.
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -u
set -o pipefail
umask 077
export LC_ALL=C

SERVER=167.28.202.2
MOUNT=
RUNS=3
BLOCK_SIZE=1M
INTERVAL=5
PCAP_LIMIT_MB=500
TEST_FILE=${1:-}
TCPDUMP_PID=
SAMPLER_PID=
FINISHED=0
INTERRUPTED=0
CAPTURE_STATUS="not started"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
capture() {
    local file=$1
    shift
    if have "$1"; then "$@" >"$file" 2>&1 || true
    else printf 'Command unavailable: %s\n' "$1" >"$file"
    fi
}
snmp_tcp_value() {
    awk -v wanted="$1" '
        $1=="Tcp:" && !seen {for(i=2;i<=NF;i++) h[i]=$i; seen=1; next}
        $1=="Tcp:" && seen {for(i=2;i<=NF;i++) if(h[i]==wanted){print $i; exit}}
    ' /proc/net/snmp 2>/dev/null
}
nfs_rpc_value() {
    awk -v field="$1" '$1=="rpc" {print $field; exit}' /proc/net/rpc/nfs 2>/dev/null
}
write_metrics() {
    {
        printf 'tcp_retrans_segs=%s\n' "$(snmp_tcp_value RetransSegs)"
        printf 'tcp_in_segs=%s\n' "$(snmp_tcp_value InSegs)"
        printf 'tcp_out_segs=%s\n' "$(snmp_tcp_value OutSegs)"
        printf 'tcp_in_errors=%s\n' "$(snmp_tcp_value InErrs)"
        printf 'nfs_rpc_calls=%s\n' "$(nfs_rpc_value 2)"
        printf 'nfs_rpc_retrans=%s\n' "$(nfs_rpc_value 3)"
    } >"$1"
}

if [[ -z $TEST_FILE || $TEST_FILE == -h || $TEST_FILE == --help ]]; then
    printf 'Usage: sudo ./nfs-read-customer.sh /path/on/nfs/existing-large-file\n'
    exit $([[ -n $TEST_FILE ]] && echo 0 || echo 1)
fi
(( $# == 1 )) || die "provide exactly one existing test-file path"
(( EUID == 0 )) || die "run with sudo"

for cmd in findmnt stat dd nfsstat ss ip tar awk tee date readlink; do
    have "$cmd" || die "required command not found: $cmd"
done
[[ -f $TEST_FILE && -r $TEST_FILE ]] || die "file does not exist or is unreadable: $TEST_FILE"

TEST_FILE=$(readlink -f "$TEST_FILE") || die "cannot resolve test-file path"
FINDMNT_LINE=$(findmnt -T "$TEST_FILE" -n -o SOURCE,TARGET,FSTYPE,OPTIONS) || \
    die "cannot resolve NFS mount"
MOUNT_SOURCE=$(awk '{print $1}' <<<"$FINDMNT_LINE")
MOUNT_TARGET=$(awk '{print $2}' <<<"$FINDMNT_LINE")
MOUNT_TYPE=$(awk '{print $3}' <<<"$FINDMNT_LINE")
[[ $MOUNT_TYPE == nfs || $MOUNT_TYPE == nfs4 ]] || die "file is on $MOUNT_TYPE, not NFS"
MOUNT=$MOUNT_TARGET
if [[ $MOUNT_SOURCE != "$SERVER":* ]]; then
    printf 'WARNING: NFS source is %s; expected IP %s. Continuing and recording evidence.\n' \
        "$MOUNT_SOURCE" "$SERVER" >&2
fi

RUN_ID=$(date +%Y%m%d_%H%M%S)
WORKDIR="/tmp/nfs_read_customer_${RUN_ID}"
BUNDLE="${WORKDIR}.tar.gz"
DD_LOG="$WORKDIR/nfs_read_dd.log"
RUN_FLAG="$WORKDIR/.sampling"
mkdir -p "$WORKDIR" || die "cannot create $WORKDIR"

ROUTE_INTERFACE=$(ip route get "$SERVER" 2>/dev/null | \
    awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
FILE_BYTES=$(stat -c %s "$TEST_FILE") || die "cannot read file size"

{
    printf 'run_id=%s\n' "$RUN_ID"
    printf 'date=%s\n' "$(date --iso-8601=seconds)"
    printf 'client=%s\nserver=%s\nmount=%s\n' \
        "$(hostname -f 2>/dev/null || hostname)" "$SERVER" "$MOUNT"
    printf 'file=%s\nruns=%s\nblock_size=%s\n' "$TEST_FILE" "$RUNS" "$BLOCK_SIZE"
    printf 'route_interface=%s\n' "${ROUTE_INTERFACE:-unknown}"
} >"$WORKDIR/MANIFEST.txt"

printf '[1/4] Collecting baseline data...\n'
capture "$WORKDIR/findmnt_nfs.txt" findmnt -t nfs,nfs4 -o TARGET,SOURCE,FSTYPE,OPTIONS
capture "$WORKDIR/nfsstat_mounts.txt" nfsstat -m
capture "$WORKDIR/nfsstat_client_before.txt" nfsstat -c
capture "$WORKDIR/netstat_s_before.txt" netstat -s
capture "$WORKDIR/nstat_before.txt" nstat -az
capture "$WORKDIR/ip_route.txt" ip route get "$SERVER"
capture "$WORKDIR/ip_address.txt" ip address show
capture "$WORKDIR/ip_link_before.txt" ip -s link show dev "$ROUTE_INTERFACE"
capture "$WORKDIR/ethtool_stats_before.txt" ethtool -S "$ROUTE_INTERFACE"
capture "$WORKDIR/proc_net_snmp_before.txt" cat /proc/net/snmp
capture "$WORKDIR/proc_net_rpc_nfs_before.txt" cat /proc/net/rpc/nfs
write_metrics "$WORKDIR/metrics_before.txt"

printf '[2/4] Starting bounded packet capture and sampling...\n'
if have tcpdump; then
    tcpdump -ni "${ROUTE_INTERFACE:-any}" -s 128 -C 100 -W 5 \
        -w "$WORKDIR/nfs_read.pcap" "host $SERVER and port 2049" \
        >"$WORKDIR/tcpdump.log" 2>&1 &
    TCPDUMP_PID=$!
    sleep 1
    if kill -0 "$TCPDUMP_PID" 2>/dev/null; then
        CAPTURE_STATUS="running; header-only capture limited to ${PCAP_LIMIT_MB}MB"
    else
        TCPDUMP_PID=
        CAPTURE_STATUS="tcpdump failed; see tcpdump.log"
    fi
else
    CAPTURE_STATUS="tcpdump unavailable"
fi
printf '%s\n' "$CAPTURE_STATUS" >"$WORKDIR/packet_capture_status.txt"

touch "$RUN_FLAG"
(
    while [[ -e $RUN_FLAG ]]; do
        NOW=$(date '+%Y-%m-%d %H:%M:%S')
        { printf '===== %s =====\n' "$NOW"; ss -tin dst "$SERVER" || true; } \
            >>"$WORKDIR/ss_ti.log" 2>&1
        { printf '===== %s =====\n' "$NOW"; nfsstat -c || true; } \
            >>"$WORKDIR/nfsstat_client_during.log" 2>&1
        sleep "$INTERVAL"
    done
) &
SAMPLER_PID=$!

finish() {
    (( FINISHED == 1 )) && return
    FINISHED=1
    rm -f "$RUN_FLAG"
    if [[ -n ${SAMPLER_PID:-} ]]; then wait "$SAMPLER_PID" 2>/dev/null || true; fi
    if [[ -n ${TCPDUMP_PID:-} ]] && kill -0 "$TCPDUMP_PID" 2>/dev/null; then
        kill -INT "$TCPDUMP_PID" 2>/dev/null || true
        wait "$TCPDUMP_PID" 2>/dev/null || true
    fi

    capture "$WORKDIR/nfsstat_client_after.txt" nfsstat -c
    capture "$WORKDIR/netstat_s_after.txt" netstat -s
    capture "$WORKDIR/nstat_after.txt" nstat -az
    capture "$WORKDIR/ip_link_after.txt" ip -s link show dev "$ROUTE_INTERFACE"
    capture "$WORKDIR/ethtool_stats_after.txt" ethtool -S "$ROUTE_INTERFACE"
    capture "$WORKDIR/proc_net_snmp_after.txt" cat /proc/net/snmp
    capture "$WORKDIR/proc_net_rpc_nfs_after.txt" cat /proc/net/rpc/nfs
    write_metrics "$WORKDIR/metrics_after.txt"
    printf 'interrupted=%s\npacket_capture=%s\n' "$INTERRUPTED" "$CAPTURE_STATUS" \
        >>"$WORKDIR/MANIFEST.txt"

    tar -czf "$BUNDLE" -C /tmp "$(basename "$WORKDIR")" || die "bundle creation failed"
    have sha256sum && sha256sum "$BUNDLE" >"${BUNDLE}.sha256"
}

on_signal() {
    INTERRUPTED=1
    printf '\nInterrupted; packaging partial results...\n' >&2
    finish
    printf 'SEND THIS FILE: %s\n' "$BUNDLE"
    exit 130
}
trap on_signal HUP INT TERM

printf '[3/4] Running three read-only NFS tests...\n'
: >"$DD_LOG"
TOTAL=0
SUCCESSFUL=0
for (( run=1; run<=RUNS; run++ )); do
    printf 'Read test %d of %d...\n' "$run" "$RUNS"
    printf '\n===== READ TEST %d =====\n' "$run" | tee -a "$DD_LOG"
    RUN_TMP="$WORKDIR/read_${run}.tmp"
    START_NS=$(date +%s%N)
    dd if="$TEST_FILE" of=/dev/null bs="$BLOCK_SIZE" status=progress 2>&1 | \
        tee -a "$DD_LOG" "$RUN_TMP"
    DD_STATUS=${PIPESTATUS[0]}
    END_NS=$(date +%s%N)
    ELAPSED=$(awk -v start="$START_NS" -v end="$END_NS" \
        'BEGIN {printf "%.3f", (end-start)/1000000000}')
    printf 'TIME real_seconds=%s\n' "$ELAPSED" | tee -a "$DD_LOG"
    rm -f "$RUN_TMP"
    if (( DD_STATUS != 0 )) || [[ -z $ELAPSED ]]; then
        printf 'RESULT run=%d status=failed dd_exit=%d\n' "$run" "$DD_STATUS" | tee -a "$DD_LOG"
        break
    fi
    RATE=$(awk -v bytes="$FILE_BYTES" -v seconds="$ELAPSED" \
        'BEGIN{if(seconds>0) printf "%.2f",bytes/1048576/seconds; else print 0}')
    printf 'RESULT run=%d elapsed_seconds=%s throughput_MiB_s=%s\n' \
        "$run" "$ELAPSED" "$RATE" | tee -a "$DD_LOG"
    TOTAL=$(awk -v total="$TOTAL" -v rate="$RATE" 'BEGIN{printf "%.6f",total+rate}')
    SUCCESSFUL=$((SUCCESSFUL + 1))
    (( run < RUNS )) && sleep 10
done
if (( SUCCESSFUL > 0 )); then
    AVERAGE=$(awk -v total="$TOTAL" -v count="$SUCCESSFUL" 'BEGIN{printf "%.2f",total/count}')
    printf 'AVERAGE successful_runs=%d throughput_MiB_s=%s\n' "$SUCCESSFUL" "$AVERAGE" | tee -a "$DD_LOG"
fi

printf '[4/4] Packaging one support bundle...\n'
finish
trap - HUP INT TERM
printf '\n============================================================\n'
printf 'DONE. SEND THIS SINGLE FILE TO THE ANALYST:\n%s\n' "$BUNDLE"
[[ -f ${BUNDLE}.sha256 ]] && printf 'Optional checksum: %s\n' "${BUNDLE}.sha256"
printf '============================================================\n'
