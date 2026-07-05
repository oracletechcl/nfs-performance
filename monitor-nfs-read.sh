#!/usr/bin/env bash

# Linux NFS client monitor. Run on the client that experiences slow reads.

set -u
umask 077
export LC_ALL=C

PROGRAM=${0##*/}
SERVER_IP=167.28.202.2
SERVER_PORT=2049
DURATION=300
INTERVAL=5
OUTPUT_BASE=/tmp/nfs_read_test
INTERFACE=
NO_TCPDUMP=0
PCAP_LIMIT_MB=500
TCPDUMP_PID=
CAPTURE_STATUS="not started"
FINISHED=0
INTERRUPTED=0

usage() {
    cat <<EOF
Usage: $PROGRAM [duration_seconds]
       $PROGRAM [--server IP] [--duration seconds] [--interval seconds]
                [--outdir prefix] [--interface device] [--server-port port]
                [--pcap-size-limit-mb MB] [--no-tcpdump]

Example:
  sudo ./$PROGRAM --server 167.28.202.2 --duration 900 \\
    --outdir /tmp/nfs_read_test
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

positive_integer() {
    [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 > 0 ))
}

capture() {
    local file=$1
    shift
    if have "$1"; then
        "$@" >"$file" 2>&1 || true
    else
        printf 'Command unavailable: %s\n' "$1" >"$file"
    fi
}

snmp_tcp_value() {
    local key=$1
    awk -v wanted="$key" '
        $1 == "Tcp:" && !header_seen {
            for (i = 2; i <= NF; i++) header[i] = $i
            header_seen = 1
            next
        }
        $1 == "Tcp:" && header_seen {
            for (i = 2; i <= NF; i++)
                if (header[i] == wanted) { print $i; exit }
        }
    ' /proc/net/snmp 2>/dev/null
}

nfs_rpc_value() {
    local field=$1
    awk -v field="$field" '$1 == "rpc" { print $field; exit }' \
        /proc/net/rpc/nfs 2>/dev/null
}

write_metrics() {
    local file=$1
    {
        printf 'tcp_retrans_segs=%s\n' "$(snmp_tcp_value RetransSegs)"
        printf 'tcp_in_segs=%s\n' "$(snmp_tcp_value InSegs)"
        printf 'tcp_out_segs=%s\n' "$(snmp_tcp_value OutSegs)"
        printf 'tcp_in_errors=%s\n' "$(snmp_tcp_value InErrs)"
        printf 'nfs_rpc_calls=%s\n' "$(nfs_rpc_value 2)"
        printf 'nfs_rpc_retrans=%s\n' "$(nfs_rpc_value 3)"
    } >"$file"
}

stop_tcpdump() {
    if [[ -n ${TCPDUMP_PID:-} ]]; then
        if kill -0 "$TCPDUMP_PID" 2>/dev/null; then
            kill -INT "$TCPDUMP_PID" 2>/dev/null || true
        fi
        wait "$TCPDUMP_PID" 2>/dev/null || true
        TCPDUMP_PID=
    fi
}

finish() {
    (( FINISHED == 1 )) && return
    FINISHED=1

    printf '[5/6] Stopping packet capture...\n'
    stop_tcpdump

    printf '[6/6] Saving final counters...\n'
    capture "$OUTDIR/netstat_s_after.txt" netstat -s
    capture "$OUTDIR/nstat_after.txt" nstat -az
    capture "$OUTDIR/nfsstat_client_after.txt" nfsstat -c
    capture "$OUTDIR/proc_net_snmp_after.txt" cat /proc/net/snmp
    capture "$OUTDIR/proc_net_rpc_nfs_after.txt" cat /proc/net/rpc/nfs
    write_metrics "$OUTDIR/metrics_after.txt"

    if [[ -n ${ROUTE_INTERFACE:-} ]]; then
        capture "$OUTDIR/ip_link_after.txt" ip -s link show dev "$ROUTE_INTERFACE"
        capture "$OUTDIR/ethtool_stats_after.txt" ethtool -S "$ROUTE_INTERFACE"
    fi

    {
        printf 'NFS read monitor summary\n'
        printf 'Client: %s\n' "$(hostname -f 2>/dev/null || hostname)"
        printf 'Kernel: %s\n' "$(uname -r)"
        printf 'Server: %s:%s\n' "$SERVER_IP" "$SERVER_PORT"
        printf 'Route interface: %s\n' "${ROUTE_INTERFACE:-unknown}"
        printf 'Duration requested: %s seconds\n' "$DURATION"
        printf 'Packet capture: %s\n' "$CAPTURE_STATUS"
        printf 'Interrupted: %s\n' "$INTERRUPTED"
    } >"$OUTDIR/summary.txt"

    ARCHIVE="${OUTDIR}.tar.gz"
    tar -czf "$ARCHIVE" -C "$(dirname "$OUTDIR")" "$(basename "$OUTDIR")" || \
        printf 'WARNING: archive creation failed; raw files remain in %s\n' "$OUTDIR" >&2

    printf '%s\n' '========================================'
    printf 'DONE\nRaw results: %s\nArchive: %s\n' "$OUTDIR" "$ARCHIVE"
    printf '%s\n' '========================================'
}

on_signal() {
    INTERRUPTED=1
    printf '\nStopping and packaging results...\n' >&2
    finish
    exit 130
}

trap on_signal HUP INT TERM

if (( $# > 0 )) && [[ $1 != --* ]]; then
    DURATION=$1
    shift
fi

while (( $# > 0 )); do
    case $1 in
        --server) [[ $# -ge 2 ]] || die "--server requires a value"; SERVER_IP=$2; shift 2 ;;
        --duration) [[ $# -ge 2 ]] || die "--duration requires a value"; DURATION=$2; shift 2 ;;
        --interval) [[ $# -ge 2 ]] || die "--interval requires a value"; INTERVAL=$2; shift 2 ;;
        --outdir) [[ $# -ge 2 ]] || die "--outdir requires a value"; OUTPUT_BASE=$2; shift 2 ;;
        --interface) [[ $# -ge 2 ]] || die "--interface requires a value"; INTERFACE=$2; shift 2 ;;
        --server-port) [[ $# -ge 2 ]] || die "--server-port requires a value"; SERVER_PORT=$2; shift 2 ;;
        --pcap-size-limit-mb) [[ $# -ge 2 ]] || die "--pcap-size-limit-mb requires a value"; PCAP_LIMIT_MB=$2; shift 2 ;;
        --no-tcpdump) NO_TCPDUMP=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
done

positive_integer "$DURATION" || die "duration must be a positive integer"
positive_integer "$INTERVAL" || die "interval must be a positive integer"
positive_integer "$SERVER_PORT" || die "server port must be a positive integer"
positive_integer "$PCAP_LIMIT_MB" || die "pcap limit must be a positive integer"

for cmd in date tar ip ss nfsstat findmnt awk grep sleep hostname uname; do
    have "$cmd" || die "required command not found: $cmd"
done

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTDIR="${OUTPUT_BASE}_${TIMESTAMP}"
mkdir -p "$OUTDIR" || die "cannot create output directory: $OUTDIR"

ROUTE_INTERFACE=$INTERFACE
if [[ -z $ROUTE_INTERFACE ]]; then
    ROUTE_INTERFACE=$(ip route get "$SERVER_IP" 2>/dev/null | \
        awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')
fi

printf '%s\n' '========================================'
printf 'NFS READ MONITOR (Linux client)\n'
printf 'Client: %s\nServer: %s:%s\nInterface: %s\nDuration: %ss\nOutput: %s\n' \
    "$(hostname -f 2>/dev/null || hostname)" "$SERVER_IP" "$SERVER_PORT" \
    "${ROUTE_INTERFACE:-unknown}" "$DURATION" "$OUTDIR"
printf '%s\n' '========================================'

printf '[1/6] Saving mount, route, and interface information...\n'
capture "$OUTDIR/mount_info.txt" mount
capture "$OUTDIR/findmnt_nfs.txt" findmnt -t nfs,nfs4 -o TARGET,SOURCE,FSTYPE,OPTIONS
capture "$OUTDIR/nfsstat_mounts.txt" nfsstat -m
capture "$OUTDIR/ip_route.txt" ip route get "$SERVER_IP"
capture "$OUTDIR/ip_address.txt" ip address show
capture "$OUTDIR/uname.txt" uname -a
if [[ -n $ROUTE_INTERFACE ]]; then
    capture "$OUTDIR/ip_link_before.txt" ip -s link show dev "$ROUTE_INTERFACE"
    capture "$OUTDIR/ethtool_stats_before.txt" ethtool -S "$ROUTE_INTERFACE"
fi

printf '[2/6] Saving TCP and NFS counters before test...\n'
capture "$OUTDIR/netstat_s_before.txt" netstat -s
capture "$OUTDIR/nstat_before.txt" nstat -az
capture "$OUTDIR/nfsstat_client_before.txt" nfsstat -c
capture "$OUTDIR/proc_net_snmp_before.txt" cat /proc/net/snmp
capture "$OUTDIR/proc_net_rpc_nfs_before.txt" cat /proc/net/rpc/nfs
write_metrics "$OUTDIR/metrics_before.txt"

printf '[3/6] Starting bounded packet capture...\n'
if (( NO_TCPDUMP == 1 )); then
    CAPTURE_STATUS="disabled by --no-tcpdump"
elif ! have tcpdump; then
    CAPTURE_STATUS="tcpdump unavailable; capture skipped"
elif (( $(id -u) != 0 )); then
    CAPTURE_STATUS="not root; tcpdump skipped"
else
    PCAP_COUNT=$(( (PCAP_LIMIT_MB + 99) / 100 ))
    CAPTURE_INTERFACE=${ROUTE_INTERFACE:-any}
    tcpdump -ni "$CAPTURE_INTERFACE" -s 128 -C 100 -W "$PCAP_COUNT" \
        -w "$OUTDIR/nfs_read.pcap" "host $SERVER_IP and port $SERVER_PORT" \
        >"$OUTDIR/tcpdump.log" 2>&1 &
    TCPDUMP_PID=$!
    sleep 1
    if kill -0 "$TCPDUMP_PID" 2>/dev/null; then
        CAPTURE_STATUS="running pid=$TCPDUMP_PID interface=$CAPTURE_INTERFACE limit=${PCAP_LIMIT_MB}MB"
    else
        wait "$TCPDUMP_PID" 2>/dev/null || true
        TCPDUMP_PID=
        CAPTURE_STATUS="tcpdump failed; see tcpdump.log"
    fi
fi
printf '%s\n' "$CAPTURE_STATUS" >"$OUTDIR/packet_capture_status.txt"

printf '[4/6] Sampling socket, TCP, and NFS state...\n'
END_EPOCH=$(( $(date +%s) + DURATION ))
while (( $(date +%s) < END_EPOCH )); do
    NOW=$(date '+%Y-%m-%d %H:%M:%S')
    {
        printf '===== %s =====\n' "$NOW"
        ss -tin dst "$SERVER_IP" || true
        printf '\n'
    } >>"$OUTDIR/ss_ti.log" 2>&1
    {
        printf '===== %s =====\n' "$NOW"
        snmp_tcp_value RetransSegs
        printf '\n'
    } >>"$OUTDIR/tcp_retrans.log" 2>&1
    {
        printf '===== %s =====\n' "$NOW"
        nfsstat -c || true
        printf '\n'
    } >>"$OUTDIR/nfsstat_client_during.log" 2>&1
    sleep "$INTERVAL"
done

finish
