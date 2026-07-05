#!/usr/bin/sh

# HP-UX 11 compatible, read-only NFS throughput test.

PATH="${PATH}:/usr/sbin:/usr/bin:/sbin:/usr/contrib/bin:/usr/local/bin"
export PATH
LC_ALL=C
export LC_ALL
umask 077

PROGRAM=${0##*/}
NFS_PATH=
TEST_FILE=
RUNS=3
BLOCK_SIZE=1048576
SLEEP_SECONDS=10
OUTFILE=

usage()
{
    cat <<EOF
Usage:
  $PROGRAM <nfs_mount_path> <test_file>
  $PROGRAM --mount path --file path [--runs count]
           [--block-size bytes] [--sleep seconds] [--log file]

HP-UX example:
  $PROGRAM --mount /habiacu --file /habiacu/path/large_file.dat \\
    --runs 3 --block-size 1048576

The test file must already exist on an NFS/NFSv3 mount. The script only reads
the file and writes the data to /dev/null. Block-size suffixes K and M are
accepted and converted to bytes before invoking HP-UX dd.
EOF
}

die()
{
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

is_nonnegative_integer()
{
    case $1 in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

is_positive_integer()
{
    is_nonnegative_integer "$1" && [ "$1" -gt 0 ] 2>/dev/null
}

command_exists()
{
    command -v "$1" >/dev/null 2>&1
}

normalize_block_size()
{
    BLOCK_VALUE=$1
    case $BLOCK_VALUE in
        *[mM])
            BLOCK_NUMBER=${BLOCK_VALUE%?}
            is_positive_integer "$BLOCK_NUMBER" || return 1
            BLOCK_SIZE=$((BLOCK_NUMBER * 1048576))
            ;;
        *[kK])
            BLOCK_NUMBER=${BLOCK_VALUE%?}
            is_positive_integer "$BLOCK_NUMBER" || return 1
            BLOCK_SIZE=$((BLOCK_NUMBER * 1024))
            ;;
        *)
            is_positive_integer "$BLOCK_VALUE" || return 1
            BLOCK_SIZE=$BLOCK_VALUE
            ;;
    esac
    [ "$BLOCK_SIZE" -gt 0 ] 2>/dev/null
}

log()
{
    printf '%s\n' "$*" | tee -a "$OUTFILE"
}

# Preserve the original positional form.
if [ $# -ge 1 ]; then
    case $1 in
        --*) ;;
        *)
            [ $# -eq 2 ] || {
                usage >&2
                die "positional usage requires exactly a mount path and a test file"
            }
            NFS_PATH=$1
            TEST_FILE=$2
            shift 2
            ;;
    esac
fi

while [ $# -gt 0 ]; do
    case $1 in
        --mount)
            [ $# -ge 2 ] || die "--mount requires a value"
            NFS_PATH=$2
            shift 2
            ;;
        --file)
            [ $# -ge 2 ] || die "--file requires a value"
            TEST_FILE=$2
            shift 2
            ;;
        --runs)
            [ $# -ge 2 ] || die "--runs requires a value"
            RUNS=$2
            shift 2
            ;;
        --block-size)
            [ $# -ge 2 ] || die "--block-size requires a value"
            BLOCK_SIZE=$2
            shift 2
            ;;
        --sleep)
            [ $# -ge 2 ] || die "--sleep requires a value"
            SLEEP_SECONDS=$2
            shift 2
            ;;
        --log)
            [ $# -ge 2 ] || die "--log requires a value"
            OUTFILE=$2
            shift 2
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

[ -n "$NFS_PATH" ] || die "NFS mount path is required"
[ -n "$TEST_FILE" ] || die "test file is required"
is_positive_integer "$RUNS" || die "runs must be a positive integer"
is_nonnegative_integer "$SLEEP_SECONDS" || die "sleep must be a non-negative integer"
normalize_block_size "$BLOCK_SIZE" || die "block size must be bytes or an integer with K/M suffix"

for REQUIRED_COMMAND in date dd awk mount bdf ls tee nfsstat uname dirname; do
    command_exists "$REQUIRED_COMMAND" || die "required command not found: $REQUIRED_COMMAND"
done

[ -d "$NFS_PATH" ] || die "mount path is not a directory: $NFS_PATH"
[ -f "$TEST_FILE" ] || die "test file is not a regular file: $TEST_FILE"
[ -r "$TEST_FILE" ] || die "test file is not readable: $TEST_FILE"

NFS_PATH=$(cd "$NFS_PATH" 2>/dev/null && pwd -P) || die "cannot resolve mount path"
TEST_DIR=$(dirname "$TEST_FILE")
TEST_DIR=$(cd "$TEST_DIR" 2>/dev/null && pwd -P) || die "cannot resolve test file directory"
TEST_FILE="$TEST_DIR/${TEST_FILE##*/}"

case $TEST_FILE in
    "$NFS_PATH"/*) ;;
    *) die "test file is not beneath mount path: $NFS_PATH" ;;
esac

MOUNT_OUTPUT=$(mount 2>&1)
BDF_OUTPUT=$(bdf "$NFS_PATH" 2>&1)
MOUNT_MATCH=$(printf '%s\n' "$MOUNT_OUTPUT" | awk -v path="$NFS_PATH" '
    index($0, path) && (tolower($0) ~ /nfs/ || $1 ~ /:/) { print; exit }
')

if [ -z "$MOUNT_MATCH" ]; then
    BDF_SOURCE=$(printf '%s\n' "$BDF_OUTPUT" | awk '
        NR > 1 && $1 != "" && $1 !~ /%$/ { print $1; exit }
    ')
    case $BDF_SOURCE in
        *:*) MOUNT_MATCH=$BDF_SOURCE ;;
        *)
            printf '%s\n' "$BDF_OUTPUT" >&2
            die "$NFS_PATH is not identified as an NFS mount; refusing to benchmark local storage"
            ;;
    esac
fi

if [ -z "$OUTFILE" ]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S) || die "could not generate timestamp"
    OUTFILE="/tmp/nfs_read_dd_${TIMESTAMP}.log"
fi

OUT_PARENT=${OUTFILE%/*}
[ "$OUT_PARENT" = "$OUTFILE" ] && OUT_PARENT=.
[ -d "$OUT_PARENT" ] || die "log directory does not exist: $OUT_PARENT"
: >"$OUTFILE" || die "cannot write log file: $OUTFILE"

FILE_BYTES=$(ls -ln "$TEST_FILE" 2>/dev/null | awk '{print $5; exit}')
is_positive_integer "$FILE_BYTES" || FILE_BYTES=unknown

log '========================================'
log 'NFS READ TEST (HP-UX 11 compatible)'
log "Client: $(uname -n 2>/dev/null)"
log "NFS path: $NFS_PATH"
log "Test file: $TEST_FILE"
log "File bytes: $FILE_BYTES"
log "Runs: $RUNS"
log "dd block size: $BLOCK_SIZE bytes"
log "Date: $(date)"
log '========================================'

log '[1/4] Mount information:'
printf '%s\n' "$MOUNT_MATCH" | tee -a "$OUTFILE"
printf '%s\n' "$BDF_OUTPUT" | tee -a "$OUTFILE"

log ''
log '[2/4] File information:'
ls -l "$TEST_FILE" 2>&1 | tee -a "$OUTFILE"

log ''
log "[3/4] Running $RUNS read tests:"

RUN_NUMBER=1
SUCCESSFUL_RUNS=0
TOTAL_MIB_PER_SECOND=0
while [ "$RUN_NUMBER" -le "$RUNS" ]; do
    log ''
    log "===== READ TEST $RUN_NUMBER ====="
    date | tee -a "$OUTFILE"

    RUN_TMP="${OUTFILE}.run${RUN_NUMBER}.tmp"
    /usr/bin/time -p dd if="$TEST_FILE" of=/dev/null bs="$BLOCK_SIZE" \
        > /dev/null 2>"$RUN_TMP"
    DD_STATUS=$?
    tee -a "$OUTFILE" <"$RUN_TMP"

    ELAPSED_SECONDS=$(awk '$1 == "real" { print $2; exit }' "$RUN_TMP")
    rm -f "$RUN_TMP"

    if [ "$DD_STATUS" -eq 0 ] && [ "$FILE_BYTES" != unknown ] && \
        [ -n "$ELAPSED_SECONDS" ]; then
        MIB_PER_SECOND=$(awk -v bytes="$FILE_BYTES" -v seconds="$ELAPSED_SECONDS" '
            BEGIN {
                if (seconds > 0) printf "%.2f", bytes / 1048576 / seconds
                else print "unknown"
            }
        ')
        log "RESULT run=$RUN_NUMBER elapsed_seconds=$ELAPSED_SECONDS throughput_MiB_s=$MIB_PER_SECOND"
        case $MIB_PER_SECOND in
            unknown) ;;
            *)
                SUCCESSFUL_RUNS=$((SUCCESSFUL_RUNS + 1))
                TOTAL_MIB_PER_SECOND=$(awk -v total="$TOTAL_MIB_PER_SECOND" -v value="$MIB_PER_SECOND" \
                    'BEGIN { printf "%.6f", total + value }')
                ;;
        esac
    else
        log "RESULT run=$RUN_NUMBER status=failed dd_exit=$DD_STATUS"
    fi

    if [ "$DD_STATUS" -ne 0 ]; then
        log 'Stopping because dd failed.'
        exit "$DD_STATUS"
    fi

    if [ "$RUN_NUMBER" -lt "$RUNS" ] && [ "$SLEEP_SECONDS" -gt 0 ]; then
        sleep "$SLEEP_SECONDS"
    fi
    RUN_NUMBER=$((RUN_NUMBER + 1))
done

log ''
log '[4/4] Final NFS client statistics:'
nfsstat -c 2>&1 | tee -a "$OUTFILE"

if [ "$SUCCESSFUL_RUNS" -gt 0 ]; then
    AVERAGE_MIB_PER_SECOND=$(awk -v total="$TOTAL_MIB_PER_SECOND" -v runs="$SUCCESSFUL_RUNS" \
        'BEGIN { printf "%.2f", total / runs }')
    log ''
    log "AVERAGE successful_runs=$SUCCESSFUL_RUNS throughput_MiB_s=$AVERAGE_MIB_PER_SECOND"
fi

log ''
log 'DONE'
log "Output file: $OUTFILE"
