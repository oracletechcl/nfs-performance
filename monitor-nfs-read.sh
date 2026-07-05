#!/usr/bin/sh

# HP-UX 11 compatible NFS read monitor.
# This script only reads system counters and optionally captures NFS traffic.

PATH="${PATH}:/usr/sbin:/usr/bin:/sbin:/usr/contrib/bin:/usr/local/bin:/opt/iexpress/bin"
export PATH
LC_ALL=C
export LC_ALL
umask 077

PROGRAM=${0##*/}
SERVER_IP="167.28.202.2"
SERVER_PORT=2049
DURATION_SECONDS=180
SAMPLE_INTERVAL=5
OUTPUT_BASE=/tmp/nfs_read_test
INTERFACE=
NO_TCPDUMP=0
TCPDUMP_PID=
CAPTURE_STATUS="not started"
FINISHED=0
INTERRUPTED=0

usage()
{
    cat <<EOF
Usage:
  $PROGRAM [duration_seconds]
  $PROGRAM [--server host] [--duration seconds] [--interval seconds]
           [--outdir path_prefix] [--interface interface] [--server-port port]
           [--no-tcpdump]

HP-UX example:
  $PROGRAM --server 167.28.202.2 --duration 300 \\
    --outdir /tmp/nfs_read_test --interface lan0

Notes:
  --outdir is a path prefix; a timestamp is appended.
  If --interface is omitted, tcpdump uses its default interface.
  Use "lanscan -i" or "netstat -in" to identify the HP-UX interface.
EOF
}

die()
{
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

is_positive_integer()
{
    case $1 in
        ''|*[!0-9]*) return 1 ;;
        *) [ "$1" -gt 0 ] 2>/dev/null ;;
    esac
}

command_exists()
{
    command -v "$1" >/dev/null 2>&1
}

capture_command()
{
    OUTPUT_FILE=$1
    shift
    if command_exists "$1"; then
        "$@" >"$OUTPUT_FILE" 2>&1
    else
        printf 'Command not available: %s\n' "$1" >"$OUTPUT_FILE"
    fi
}

stop_tcpdump()
{
    if [ -n "$TCPDUMP_PID" ]; then
        if kill -0 "$TCPDUMP_PID" 2>/dev/null; then
            kill "$TCPDUMP_PID" 2>/dev/null
        fi
        wait "$TCPDUMP_PID" 2>/dev/null
        TCPDUMP_PID=
    fi
}

create_archive()
{
    OUT_PARENT=${OUTDIR%/*}
    OUT_NAME=${OUTDIR##*/}
    [ "$OUT_PARENT" = "$OUTDIR" ] && OUT_PARENT=.
    TAR_FILE="${OUTDIR}.tar"

    if (cd "$OUT_PARENT" && tar cf "$TAR_FILE" "$OUT_NAME"); then
        if command_exists gzip; then
            gzip -f "$TAR_FILE"
            ARCHIVE_FILE="${TAR_FILE}.gz"
        elif command_exists compress; then
            compress -f "$TAR_FILE"
            ARCHIVE_FILE="${TAR_FILE}.Z"
        else
            ARCHIVE_FILE=$TAR_FILE
        fi
    else
        ARCHIVE_FILE=
        printf 'WARNING: could not create archive. Raw results remain in %s\n' "$OUTDIR" >&2
    fi
}

finish()
{
    [ "$FINISHED" -eq 1 ] && return
    FINISHED=1

    printf '[5/6] Stopping packet capture...\n'
    stop_tcpdump

    printf '[6/6] Saving counters after test...\n'
    capture_command "$OUTDIR/netstat_s_after.txt" netstat -s
    capture_command "$OUTDIR/nfsstat_client_after.txt" nfsstat -c

    {
        printf 'NFS read monitor summary\n'
        printf 'Platform: %s\n' "$(uname -sr 2>/dev/null)"
        printf 'Client: %s\n' "$(uname -n 2>/dev/null)"
        printf 'Server: %s:%s\n' "$SERVER_IP" "$SERVER_PORT"
        printf 'Duration requested: %s seconds\n' "$DURATION_SECONDS"
        printf 'Sample interval: %s seconds\n' "$SAMPLE_INTERVAL"
        printf 'Packet capture: %s\n' "$CAPTURE_STATUS"
        printf 'Interrupted: %s\n' "$INTERRUPTED"
    } >"$OUTDIR/summary.txt"

    printf 'Creating archive...\n'
    create_archive

    printf '%s\n' '========================================'
    printf 'DONE\n'
    printf 'Raw results: %s\n' "$OUTDIR"
    if [ -n "$ARCHIVE_FILE" ]; then
        printf 'Archive: %s\n' "$ARCHIVE_FILE"
    fi
    printf '%s\n' '========================================'
}

handle_signal()
{
    INTERRUPTED=1
    printf '\nSignal received; finalizing collected data...\n' >&2
    finish
    exit 130
}

trap 'handle_signal' 1 2 15

# Preserve the original positional duration form: ./monitor-nfs-read.sh 300
if [ $# -gt 0 ]; then
    case $1 in
        --*) ;;
        *)
            DURATION_SECONDS=$1
            shift
            ;;
    esac
fi

while [ $# -gt 0 ]; do
    case $1 in
        --server)
            [ $# -ge 2 ] || die "--server requires a value"
            SERVER_IP=$2
            shift 2
            ;;
        --duration)
            [ $# -ge 2 ] || die "--duration requires a value"
            DURATION_SECONDS=$2
            shift 2
            ;;
        --interval)
            [ $# -ge 2 ] || die "--interval requires a value"
            SAMPLE_INTERVAL=$2
            shift 2
            ;;
        --outdir)
            [ $# -ge 2 ] || die "--outdir requires a value"
            OUTPUT_BASE=$2
            shift 2
            ;;
        --interface)
            [ $# -ge 2 ] || die "--interface requires a value"
            INTERFACE=$2
            shift 2
            ;;
        --server-port)
            [ $# -ge 2 ] || die "--server-port requires a value"
            SERVER_PORT=$2
            shift 2
            ;;
        --no-tcpdump)
            NO_TCPDUMP=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown argument: $1"
            ;;
    esac
done

is_positive_integer "$DURATION_SECONDS" || die "duration must be a positive integer"
is_positive_integer "$SAMPLE_INTERVAL" || die "interval must be a positive integer"
is_positive_integer "$SERVER_PORT" || die "server port must be a positive integer"

for REQUIRED_COMMAND in mkdir date mount netstat nfsstat tar sleep grep uname; do
    command_exists "$REQUIRED_COMMAND" || die "required command not found: $REQUIRED_COMMAND"
done

TIMESTAMP=$(date +%Y%m%d_%H%M%S) || die "could not generate timestamp"
OUTDIR="${OUTPUT_BASE}_${TIMESTAMP}"
mkdir -p "$OUTDIR" || die "could not create output directory: $OUTDIR"

printf '%s\n' '========================================'
printf 'NFS READ MONITOR (HP-UX 11 compatible)\n'
printf 'Client: %s\n' "$(uname -n)"
printf 'Server: %s:%s\n' "$SERVER_IP" "$SERVER_PORT"
printf 'Duration: %ss\n' "$DURATION_SECONDS"
printf 'Output: %s\n' "$OUTDIR"
printf '%s\n' '========================================'

printf '[1/6] Saving mount and platform information...\n'
capture_command "$OUTDIR/mount_info.txt" mount
capture_command "$OUTDIR/nfsstat_mounts.txt" nfsstat -m
capture_command "$OUTDIR/netstat_routes.txt" netstat -rn
capture_command "$OUTDIR/netstat_interfaces.txt" netstat -in
capture_command "$OUTDIR/uname.txt" uname -a

printf '[2/6] Saving TCP and NFS counters before test...\n'
capture_command "$OUTDIR/netstat_s_before.txt" netstat -s
capture_command "$OUTDIR/nfsstat_client_before.txt" nfsstat -c

printf '[3/6] Starting packet capture...\n'
PCAP_FILE="$OUTDIR/nfs_read_${SERVER_IP}.pcap"
if [ "$NO_TCPDUMP" -eq 1 ]; then
    CAPTURE_STATUS="disabled by --no-tcpdump"
    printf '%s\n' "$CAPTURE_STATUS" >"$OUTDIR/packet_capture_status.txt"
elif ! command_exists tcpdump; then
    CAPTURE_STATUS="tcpdump not installed; capture skipped"
    printf 'WARNING: %s\n' "$CAPTURE_STATUS" >&2
    printf '%s\n' "$CAPTURE_STATUS" >"$OUTDIR/packet_capture_status.txt"
else
    if [ -n "$INTERFACE" ]; then
        tcpdump -i "$INTERFACE" -n -s 65535 -w "$PCAP_FILE" \
            "host $SERVER_IP and tcp port $SERVER_PORT" \
            >"$OUTDIR/tcpdump.log" 2>&1 &
    else
        tcpdump -n -s 65535 -w "$PCAP_FILE" \
            "host $SERVER_IP and tcp port $SERVER_PORT" \
            >"$OUTDIR/tcpdump.log" 2>&1 &
    fi
    TCPDUMP_PID=$!
    sleep 2
    if kill -0 "$TCPDUMP_PID" 2>/dev/null; then
        CAPTURE_STATUS="running with pid $TCPDUMP_PID"
    else
        wait "$TCPDUMP_PID" 2>/dev/null
        TCPDUMP_PID=
        CAPTURE_STATUS="tcpdump failed; see tcpdump.log"
        printf 'WARNING: %s\n' "$CAPTURE_STATUS" >&2
    fi
    printf '%s\n' "$CAPTURE_STATUS" >"$OUTDIR/packet_capture_status.txt"
fi

printf '[4/6] Sampling HP-UX netstat and nfsstat counters...\n'
ELAPSED=0
while [ "$ELAPSED" -lt "$DURATION_SECONDS" ]; do
    SAMPLE_TIME=$(date '+%Y-%m-%d %H:%M:%S')

    {
        printf '===== %s =====\n' "$SAMPLE_TIME"
        netstat -an 2>&1 | grep "$SERVER_IP" || printf 'No matching connection found.\n'
        printf '\n'
    } >>"$OUTDIR/socket_state.log"

    {
        printf '===== %s =====\n' "$SAMPLE_TIME"
        netstat -s 2>&1 | egrep -i 'retrans|timeout|reset|failed' || \
            printf 'No matching TCP counter lines found.\n'
        printf '\n'
    } >>"$OUTDIR/tcp_retrans.log"

    {
        printf '===== %s =====\n' "$SAMPLE_TIME"
        nfsstat -c 2>&1
        printf '\n'
    } >>"$OUTDIR/nfsstat_client_during.log"

    sleep "$SAMPLE_INTERVAL"
    ELAPSED=$((ELAPSED + SAMPLE_INTERVAL))
done

finish
