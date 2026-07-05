#!/usr/bin/env bash

set -u
export LC_ALL=C

PROGRAM=${0##*/}
BUNDLE=
DD_LOG=
SLOW_THRESHOLD=100

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
    printf 'Usage: %s --bundle monitor.tar.gz --dd-log read.log [--slow-mib-s 100]\n' "$PROGRAM"
}

while (( $# > 0 )); do
    case $1 in
        --bundle) BUNDLE=$2; shift 2 ;;
        --dd-log) DD_LOG=$2; shift 2 ;;
        --slow-mib-s) SLOW_THRESHOLD=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
done

[[ -f $BUNDLE ]] || die "monitor bundle not found: $BUNDLE"
[[ -f $DD_LOG ]] || die "read log not found: $DD_LOG"
TMPDIR_ANALYZE=$(mktemp -d /tmp/nfs_read_analyze.XXXXXX) || exit 1
trap 'rm -rf "$TMPDIR_ANALYZE"' EXIT
tar -xzf "$BUNDLE" -C "$TMPDIR_ANALYZE" || die "cannot extract bundle"
RESULT_DIR=$(find "$TMPDIR_ANALYZE" -mindepth 1 -maxdepth 1 -type d | head -1)

metric() { awk -F= -v key="$2" '$1==key {print $2; exit}' "$1"; }
BEFORE="$RESULT_DIR/metrics_before.txt"
AFTER="$RESULT_DIR/metrics_after.txt"

TCP_BEFORE=$(metric "$BEFORE" tcp_retrans_segs); TCP_AFTER=$(metric "$AFTER" tcp_retrans_segs)
NFS_BEFORE=$(metric "$BEFORE" nfs_rpc_retrans); NFS_AFTER=$(metric "$AFTER" nfs_rpc_retrans)
TCP_DELTA=$(( ${TCP_AFTER:-0} - ${TCP_BEFORE:-0} ))
NFS_DELTA=$(( ${NFS_AFTER:-0} - ${NFS_BEFORE:-0} ))
AVERAGE=$(awk -F= '/^AVERAGE /{for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+$/){print $i}}' "$DD_LOG" | tail -1)
[[ -n $AVERAGE ]] || AVERAGE=$(awk -F= '/throughput_MiB_s=/{print $NF}' "$DD_LOG" | \
    awk '{sum+=$1;n++} END{if(n) printf "%.2f",sum/n; else print 0}')
SLOW=$(awk -v rate="$AVERAGE" -v limit="$SLOW_THRESHOLD" 'BEGIN{print rate < limit ? 1 : 0}')

printf 'Average throughput: %s MiB/s\n' "$AVERAGE"
printf 'TCP retransmission delta: %s\n' "$TCP_DELTA"
printf 'NFS RPC retransmission delta: %s\n' "$NFS_DELTA"
printf 'Slow threshold: %s MiB/s\n\n' "$SLOW_THRESHOLD"

if (( SLOW == 1 && TCP_DELTA > 0 )); then
    printf 'CONCLUSION: Network/firewall/MTU path issue likely.\n'
    printf 'ACTION: Check OCI VNIC errors, path MTU, firewall drops, and TCP retransmissions.\n'
elif (( SLOW == 1 && NFS_DELTA > 0 )); then
    printf 'CONCLUSION: NFS transport/server responsiveness issue likely.\n'
    printf 'ACTION: Check HP-UX nfsd saturation, server NIC errors, CPU, and storage latency.\n'
elif (( SLOW == 1 )); then
    printf 'CONCLUSION: HP-UX NFS server/storage or mount tuning issue likely; TCP loss not observed.\n'
    printf 'ACTION: Check server disk latency and effective rsize; compare a --direct-io run.\n'
else
    printf 'CONCLUSION: Throughput is above the supplied slow threshold.\n'
fi

printf '\nEffective mount options:\n'
cat "$RESULT_DIR/nfsstat_mounts.txt" 2>/dev/null || true
