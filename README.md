# NFS read diagnostic

Two files only:

```text
nfs-read-customer.sh   Customer runs this on Linux OCI 10.4.3.209
analyze-nfs-read.sh    Analyst runs this against the returned bundle
```

## 1. Customer

Send only `nfs-read-customer.sh` to the customer. They run one command, replacing the file path with an existing large file below `/habiacu`:

```bash
chmod 755 nfs-read-customer.sh
sudo ./nfs-read-customer.sh /habiacu/PATH_TO_EXISTING_LARGE_FILE
```

The script is read-only against NFS. It produces one file such as:

```text
/tmp/nfs_read_customer_YYYYMMDD_HHMMSS.tar.gz
```

The customer sends that single `.tar.gz` file back. The `.sha256` file is optional.

## 2. Analyst

Run one command locally:

```bash
chmod 755 analyze-nfs-read.sh
./analyze-nfs-read.sh /path/to/nfs_read_customer_YYYYMMDD_HHMMSS.tar.gz
```

The conclusion appears on screen and is saved to:

```text
nfs_read_analysis_YYYYMMDD_HHMMSS.txt
```

No production mount or network settings are changed automatically.
