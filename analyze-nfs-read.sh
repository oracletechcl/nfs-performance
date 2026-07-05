#!/usr/bin/env bash

# Analyst-side parser for the single customer support bundle.

set -u
export LC_ALL=C

PROGRAM=${0##*/}
BUNDLE=
DD_LOG_OVERRIDE=
SLOW_THRESHOLD=100
REPORT=

usage() {
    cat <<EOF
Usage: ./$PROGRAM customer_bundle.tar.gz [--slow-mib-s 100] [--output report.txt]
       ./$PROGRAM --bundle customer_bundle.tar.gz [--dd-log legacy_read.log]
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

if (( $# > 0 )) && [[ $1 != --* ]]; then
    BUNDLE=$1
    shift
fi
while (( $# > 0 )); do
    case $1 in
        --bundle) BUNDLE=$2; shift 2 ;;
        --dd-log) DD_LOG_OVERRIDE=$2; shift 2 ;;
        --slow-mib-s) SLOW_THRESHOLD=$2; shift 2 ;;
        --output) REPORT=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
done

[[ -f $BUNDLE ]] || die "bundle not found: $BUNDLE"
[[ $SLOW_THRESHOLD =~ ^[0-9]+([.][0-9]+)?$ ]] || die "invalid slow threshold"
[[ -n $REPORT ]] || REPORT="nfs_read_analysis_$(date +%Y%m%d_%H%M%S).txt"

TMP=$(mktemp -d /tmp/nfs_read_analyze.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT
tar -xzf "$BUNDLE" -C "$TMP" || die "cannot extract bundle"

METRICS_BEFORE=$(find "$TMP" -type f -name metrics_before.txt | head -1)
[[ -n $METRICS_BEFORE ]] || die "metrics_before.txt missing from bundle"
MONITOR_DIR=$(dirname "$METRICS_BEFORE")
METRICS_AFTER="$MONITOR_DIR/metrics_after.txt"
[[ -f $METRICS_AFTER ]] || die "metrics_after.txt missing from bundle"

if [[ -n $DD_LOG_OVERRIDE ]]; then
    DD_LOG=$DD_LOG_OVERRIDE
else
    DD_LOG=$(find "$TMP" -type f -name 'nfs_read_dd*.log' | head -1)
fi
[[ -f $DD_LOG ]] || die "NFS read-test log missing from bundle"

MANIFEST=$(find "$TMP" -type f -name MANIFEST.txt | head -1)
metric() { awk -F= -v key="$2" '$1 == key {print $2; exit}' "$1"; }
number_or_zero() { [[ ${1:-} =~ ^[0-9]+$ ]] && printf '%s' "$1" || printf '0'; }

TCP_BEFORE=$(number_or_zero "$(metric "$METRICS_BEFORE" tcp_retrans_segs)")
TCP_AFTER=$(number_or_zero "$(metric "$METRICS_AFTER" tcp_retrans_segs)")
TCP_IN_BEFORE=$(number_or_zero "$(metric "$METRICS_BEFORE" tcp_in_segs)")
TCP_IN_AFTER=$(number_or_zero "$(metric "$METRICS_AFTER" tcp_in_segs)")
TCP_OUT_BEFORE=$(number_or_zero "$(metric "$METRICS_BEFORE" tcp_out_segs)")
TCP_OUT_AFTER=$(number_or_zero "$(metric "$METRICS_AFTER" tcp_out_segs)")
NFS_BEFORE=$(number_or_zero "$(metric "$METRICS_BEFORE" nfs_rpc_retrans)")
NFS_AFTER=$(number_or_zero "$(metric "$METRICS_AFTER" nfs_rpc_retrans)")

TCP_DELTA=$(( TCP_AFTER - TCP_BEFORE ))
TCP_SEGMENT_DELTA=$(( TCP_IN_AFTER + TCP_OUT_AFTER - TCP_IN_BEFORE - TCP_OUT_BEFORE ))
NFS_DELTA=$(( NFS_AFTER - NFS_BEFORE ))
(( TCP_DELTA < 0 )) && TCP_DELTA=0
(( TCP_SEGMENT_DELTA < 0 )) && TCP_SEGMENT_DELTA=0
(( NFS_DELTA < 0 )) && NFS_DELTA=0
TCP_RATIO=$(awk -v retrans="$TCP_DELTA" -v segments="$TCP_SEGMENT_DELTA" \
    'BEGIN {if (segments > 0) printf "%.4f", retrans*100/segments; else print "0.0000"}')

RATES=()
while IFS= read -r RATE; do
    RATES[${#RATES[@]}]=$RATE
done < <(awk '
    /^RESULT / {
        for (i=1; i<=NF; i++)
            if ($i ~ /^throughput_MiB_s=/) {split($i,a,"="); print a[2]}
    }
' "$DD_LOG")
(( ${#RATES[@]} > 0 )) || die "no successful throughput results in read log"

FIRST_RATE=${RATES[0]}
LAST_RATE=${RATES[$(( ${#RATES[@]} - 1 ))]}
AVERAGE=$(printf '%s\n' "${RATES[@]}" | awk '{sum+=$1} END{printf "%.2f",sum/NR}')
CACHE_RATIO=$(awk -v first="$FIRST_RATE" -v last="$LAST_RATE" \
    'BEGIN {if (first > 0) printf "%.2f",last/first; else print "0.00"}')
SLOW=$(awk -v rate="$AVERAGE" -v threshold="$SLOW_THRESHOLD" \
    'BEGIN {print rate < threshold ? 1 : 0}')
CACHE_EFFECT=$(awk -v ratio="$CACHE_RATIO" 'BEGIN {print ratio >= 1.5 ? 1 : 0}')

PCAP_COUNT=0
PCAP_BYTES=0
for PCAP_FILE in "$MONITOR_DIR"/nfs_read.pcap*; do
    [[ -f $PCAP_FILE ]] || continue
    PCAP_COUNT=$((PCAP_COUNT + 1))
    PCAP_FILE_BYTES=$(stat -f %z "$PCAP_FILE" 2>/dev/null || stat -c %s "$PCAP_FILE" 2>/dev/null || echo 0)
    PCAP_BYTES=$((PCAP_BYTES + PCAP_FILE_BYTES))
done

exec > >(tee "$REPORT") 2>&1
printf 'NFS READ PERFORMANCE ANALYSIS\n'
printf '========================================\n'
printf 'Bundle: %s\n' "$BUNDLE"
[[ -f $MANIFEST ]] && cat "$MANIFEST"
printf '\nTHROUGHPUT\n'
for i in "${!RATES[@]}"; do printf 'Run %d: %s MiB/s\n' "$((i+1))" "${RATES[$i]}"; done
printf 'Average: %s MiB/s\n' "$AVERAGE"
printf 'First-to-last ratio: %sx\n' "$CACHE_RATIO"

printf '\nNETWORK/NFS COUNTERS\n'
printf 'TCP retransmission delta: %d\n' "$TCP_DELTA"
printf 'TCP retransmission ratio: %s%%\n' "$TCP_RATIO"
printf 'NFS RPC retransmission delta: %d\n' "$NFS_DELTA"
printf 'Packet capture files: %s (%s bytes)\n' "$PCAP_COUNT" "$PCAP_BYTES"

printf '\nEFFECTIVE NFS MOUNT\n'
cat "$MONITOR_DIR/findmnt_nfs.txt" 2>/dev/null || true

printf '\nCONCLUSION\n'
if (( SLOW == 1 && TCP_DELTA > 0 )); then
    printf 'Network/firewall/MTU path problem likely.\n'
    printf 'Next: inspect the pcap, OCI VNIC drops, firewall counters, and path MTU.\n'
elif (( SLOW == 1 && NFS_DELTA > 0 )); then
    printf 'NFS requests are being retried without matching TCP retransmissions.\n'
    printf 'Next: inspect HP-UX nfsd load, server CPU, NIC errors, and storage latency.\n'
elif (( CACHE_EFFECT == 1 )); then
    printf 'Strong cache effect: later reads are at least 1.5x faster.\n'
    printf 'Next: compare a customer run using --direct-io and inspect HP-UX storage latency.\n'
elif (( SLOW == 1 )); then
    printf 'HP-UX NFS server/storage or mount behavior likely; TCP loss was not observed.\n'
    printf 'Next: inspect server disk latency and compare effective rsize with a direct-I/O run.\n'
else
    printf 'Average throughput exceeds the configured %s MiB/s threshold.\n' "$SLOW_THRESHOLD"
fi

printf '\nReport written to: %s\n' "$REPORT"
