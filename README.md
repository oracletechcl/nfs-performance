# nfs-performance


sudo ./monitor-nfs-read.sh \
  --server 167.28.202.2 \
  --duration 900 \
  --outdir /tmp/nfs_read_test



  ./run-nfs-read-test.sh \
  --server 167.28.202.2 \
  --mount /habiacu \
  --file /habiacu/PATH_TO_EXISTING_LARGE_FILE \
  --runs 3 \
  --block-size 1M