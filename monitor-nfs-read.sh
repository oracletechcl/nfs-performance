#!/bin/bash

SERVER_IP="167.28.202.2"
DURATION_SECONDS="${1:-180}"
OUTDIR="/tmp/nfs_read_test_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$OUTDIR"

echo "========================================"
echo "NFS READ MONITOR"
echo "Client: $(hostname)"
echo "Server: $SERVER_IP"
echo "Duration: ${DURATION_SECONDS}s"
echo "Output: $OUTDIR"
echo "========================================"

echo "[1/6] Saving mount info..."
mount | grep "$SERVER_IP" > "$OUTDIR/mount_info.txt" 2>&1
nfsstat -m > "$OUTDIR/nfsstat_mounts.txt" 2>&1

echo "[2/6] Saving TCP counters before test..."
netstat -s > "$OUTDIR/netstat_s_before.txt" 2>&1
nfsstat -c > "$OUTDIR/nfsstat_client_before.txt" 2>&1

echo "[3/6] Starting tcpdump on TCP/2049..."
tcpdump -ni any host "$SERVER_IP" and tcp port 2049 -s 0 -w "$OUTDIR/nfs_read_${SERVER_IP}.pcap" &
TCPDUMP_PID=$!

sleep 2

echo "[4/6] Monitoring ss/netstat/nfsstat..."
END=$((SECONDS + DURATION_SECONDS))

while [ $SECONDS -lt $END ]; do
  TS=$(date '+%Y-%m-%d %H:%M:%S')

  {
    echo "===== $TS ====="
    ss -ti dst "$SERVER_IP"
    echo
  } >> "$OUTDIR/ss_ti.log" 2>&1

  {
    echo "===== $TS ====="
    netstat -s | egrep -i "retrans|timeout|segments retrans|reset|failed"
    echo
  } >> "$OUTDIR/tcp_retrans.log" 2>&1

  {
    echo "===== $TS ====="
    nfsstat -c
    echo
  } >> "$OUTDIR/nfsstat_client_during.log" 2>&1

  sleep 5
done

echo "[5/6] Stopping tcpdump..."
kill "$TCPDUMP_PID" 2>/dev/null
wait "$TCPDUMP_PID" 2>/dev/null

echo "[6/6] Saving counters after test..."
netstat -s > "$OUTDIR/netstat_s_after.txt" 2>&1
nfsstat -c > "$OUTDIR/nfsstat_client_after.txt" 2>&1

echo "Creating tarball..."
tar czf "${OUTDIR}.tar.gz" -C /tmp "$(basename "$OUTDIR")"

echo "========================================"
echo "DONE"
echo "Results:"
echo "${OUTDIR}.tar.gz"
echo "========================================"