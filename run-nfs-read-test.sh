#!/usr/bin/env bash

# Read-only NFS throughput test for the Linux OCI client.

set -u
umask 077
export LC_ALL=C

PROGRAM=${0##*/}
SERVER_IP=167.28.202.2
NFS_PATH=
TEST_FILE=
RUNS=3
BLOCK_SIZE=1M
SLEEP_SECONDS=10
DIRECT_IO=0
OUTFILE=

usage() {
    cat <<EOF
Usage: $PROGRAM <nfs_mount_path> <test_file>
       $PROGRAM --mount path --file path [--server IP] [--runs count]
                [--block-size size] [--sleep seconds] [--direct-io]
                [--log file]

Example:
  ./$PROGRAM --mount /habiacu --file /habiacu/existing-large-file \\
    --server 167.28.202.2 --runs 3 --block-size 1M
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
positive_integer() { [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 > 0 )); }
nonnegative_integer() { [[ $1 =~ ^[0-9]+$ ]]; }
log() { printf '%s\n' "$*" | tee -a "$OUTFILE"; }

if (( $# > 0 )) && [[ $1 != --* ]]; then
    (( $# == 2 )) || die "positional usage requires mount path and test file"
    NFS_PATH=$1
    TEST_FILE=$2
    shift 2
fi

while (( $# > 0 )); do
    case $1 in
        --mount) [[ $# -ge 2 ]] || die "--mount requires a value"; NFS_PATH=$2; shift 2 ;;
        --file) [[ $# -ge 2 ]] || die "--file requires a value"; TEST_FILE=$2; shift 2 ;;
        --server) [[ $# -ge 2 ]] || die "--server requires a value"; SERVER_IP=$2; shift 2 ;;
        --runs) [[ $# -ge 2 ]] || die "--runs requires a value"; RUNS=$2; shift 2 ;;
        --block-size) [[ $# -ge 2 ]] || die "--block-size requires a value"; BLOCK_SIZE=$2; shift 2 ;;
        --sleep) [[ $# -ge 2 ]] || die "--sleep requires a value"; SLEEP_SECONDS=$2; shift 2 ;;
        --direct-io) DIRECT_IO=1; shift ;;
        --log) [[ $# -ge 2 ]] || die "--log requires a value"; OUTFILE=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
done

[[ -n $NFS_PATH ]] || die "--mount is required"
[[ -n $TEST_FILE ]] || die "--file is required"
positive_integer "$RUNS" || die "runs must be a positive integer"
nonnegative_integer "$SLEEP_SECONDS" || die "sleep must be a non-negative integer"

for cmd in findmnt stat dd nfsstat awk tee date; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
done
[[ -x /usr/bin/time ]] || die "/usr/bin/time is required"
[[ -d $NFS_PATH ]] || die "mount path is not a directory: $NFS_PATH"
[[ -f $TEST_FILE ]] || die "test file is not a regular file: $TEST_FILE"
[[ -r $TEST_FILE ]] || die "test file is not readable: $TEST_FILE"

NFS_PATH=$(readlink -f "$NFS_PATH") || die "cannot resolve mount path"
TEST_FILE=$(readlink -f "$TEST_FILE") || die "cannot resolve test file"
[[ $TEST_FILE == "$NFS_PATH"/* ]] || die "test file is outside $NFS_PATH"

FINDMNT_LINE=$(findmnt -T "$TEST_FILE" -n -o SOURCE,TARGET,FSTYPE,OPTIONS) || \
    die "findmnt could not resolve the test file"
MOUNT_SOURCE=$(awk '{print $1}' <<<"$FINDMNT_LINE")
MOUNT_TARGET=$(awk '{print $2}' <<<"$FINDMNT_LINE")
MOUNT_TYPE=$(awk '{print $3}' <<<"$FINDMNT_LINE")

[[ $MOUNT_TYPE == nfs || $MOUNT_TYPE == nfs4 ]] || \
    die "$TEST_FILE is on $MOUNT_TYPE, not NFS"
[[ $MOUNT_SOURCE == "$SERVER_IP":* ]] || \
    die "NFS source is $MOUNT_SOURCE, expected $SERVER_IP:/..."
[[ $MOUNT_TARGET == "$NFS_PATH" ]] || \
    die "actual mount target is $MOUNT_TARGET, not $NFS_PATH"

if [[ -z $OUTFILE ]]; then
    OUTFILE="/tmp/nfs_read_dd_$(date +%Y%m%d_%H%M%S).log"
fi
: >"$OUTFILE" || die "cannot write log: $OUTFILE"

FILE_BYTES=$(stat -c %s "$TEST_FILE") || die "cannot read file size"
DD_FLAGS=()
(( DIRECT_IO == 1 )) && DD_FLAGS+=(iflag=direct)

log '========================================'
log 'NFS READ TEST (Linux OCI client)'
log "Client: $(hostname -f 2>/dev/null || hostname)"
log "Server: $SERVER_IP"
log "Mount: $FINDMNT_LINE"
log "Test file: $TEST_FILE"
log "File bytes: $FILE_BYTES"
log "Runs: $RUNS"
log "Block size: $BLOCK_SIZE"
log "Direct I/O: $DIRECT_IO"
log '========================================'

log 'NFS counters before:'
nfsstat -c 2>&1 | tee -a "$OUTFILE"

TOTAL=0
SUCCESSFUL=0
for (( run=1; run<=RUNS; run++ )); do
    log ''
    log "===== READ TEST $run ====="
    RUN_TMP="${OUTFILE}.run${run}.tmp"

    /usr/bin/time -f 'TIME real_seconds=%e' \
        dd if="$TEST_FILE" of=/dev/null bs="$BLOCK_SIZE" "${DD_FLAGS[@]}" status=progress \
        > /dev/null 2>"$RUN_TMP"
    DD_STATUS=$?
    tee -a "$OUTFILE" <"$RUN_TMP" >&2

    ELAPSED=$(awk -F= '/^TIME real_seconds=/{print $2; exit}' "$RUN_TMP")
    rm -f "$RUN_TMP"
    if (( DD_STATUS != 0 )) || [[ -z $ELAPSED ]]; then
        log "RESULT run=$run status=failed dd_exit=$DD_STATUS"
        exit "${DD_STATUS:-1}"
    fi

    RATE=$(awk -v bytes="$FILE_BYTES" -v seconds="$ELAPSED" \
        'BEGIN { if (seconds > 0) printf "%.2f", bytes/1048576/seconds; else print 0 }')
    log "RESULT run=$run elapsed_seconds=$ELAPSED throughput_MiB_s=$RATE"
    TOTAL=$(awk -v total="$TOTAL" -v rate="$RATE" 'BEGIN {printf "%.6f", total+rate}')
    SUCCESSFUL=$((SUCCESSFUL + 1))

    (( run < RUNS && SLEEP_SECONDS > 0 )) && sleep "$SLEEP_SECONDS"
done

AVERAGE=$(awk -v total="$TOTAL" -v count="$SUCCESSFUL" \
    'BEGIN {printf "%.2f", total/count}')
log ''
log "AVERAGE successful_runs=$SUCCESSFUL throughput_MiB_s=$AVERAGE"
log 'NFS counters after:'
nfsstat -c 2>&1 | tee -a "$OUTFILE"
log 'DONE'
log "Output file: $OUTFILE"
