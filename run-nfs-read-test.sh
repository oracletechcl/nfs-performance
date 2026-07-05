#!/bin/bash

NFS_PATH="$1"
TEST_FILE="$2"
OUTFILE="/tmp/nfs_read_dd_$(date +%Y%m%d_%H%M%S).log"

if [ -z "$NFS_PATH" ] || [ -z "$TEST_FILE" ]; then
  echo "Usage:"
  echo "  $0 <nfs_mount_path> <test_file>"
  echo
  echo "Example:"
  echo "  $0 /mnt/nfs_167 /mnt/nfs_167/testfile.dat"
  exit 1
fi

echo "========================================" | tee -a "$OUTFILE"
echo "NFS READ TEST" | tee -a "$OUTFILE"
echo "Client: $(hostname)" | tee -a "$OUTFILE"
echo "NFS path: $NFS_PATH" | tee -a "$OUTFILE"
echo "Test file: $TEST_FILE" | tee -a "$OUTFILE"
echo "Date: $(date)" | tee -a "$OUTFILE"
echo "========================================" | tee -a "$OUTFILE"

echo "[1/4] Mount info..." | tee -a "$OUTFILE"
mount | grep "$NFS_PATH" | tee -a "$OUTFILE"

echo | tee -a "$OUTFILE"
echo "[2/4] File size..." | tee -a "$OUTFILE"
ls -lh "$TEST_FILE" | tee -a "$OUTFILE"

echo | tee -a "$OUTFILE"
echo "[3/4] Running 3 read tests..." | tee -a "$OUTFILE"

for i in 1 2 3; do
  echo | tee -a "$OUTFILE"
  echo "===== READ TEST $i =====" | tee -a "$OUTFILE"
  date | tee -a "$OUTFILE"

  /usr/bin/time -p dd if="$TEST_FILE" of=/dev/null bs=1M status=progress 2>&1 | tee -a "$OUTFILE"

  sync
  sleep 10
done

echo | tee -a "$OUTFILE"
echo "[4/4] Final NFS client stats..." | tee -a "$OUTFILE"
nfsstat -c | tee -a "$OUTFILE"

echo | tee -a "$OUTFILE"
echo "DONE" | tee -a "$OUTFILE"
echo "Output file: $OUTFILE"