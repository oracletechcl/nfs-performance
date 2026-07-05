# NFS read diagnostic

This toolkit uses two scripts:

| Script | Where it runs | Purpose |
|---|---|---|
| `nfs-read-customer.sh` | OCI Linux client `10.4.3.209` | Runs the test and creates one support bundle |
| `analyze-nfs-read.sh` | Analyst workstation | Analyzes the returned support bundle |

The NFS server is the HP-UX machine `167.28.202.2`. Do not run the customer script on the HP-UX server.

## Customer procedure

Send only `nfs-read-customer.sh` to the customer.

On OCI Linux `10.4.3.209`, select an existing large file beneath `/habiacu`. The script never modifies that file; it reads it into `/dev/null`.

Run:

```bash
chmod 755 nfs-read-customer.sh

sudo ./nfs-read-customer.sh \
  /habiacu/PATH_TO_EXISTING_LARGE_FILE
```

Example:

```bash
sudo ./nfs-read-customer.sh /habiacu/backups/large-backup-file
```

The script validates that:

- The file exists and is readable.
- The file is beneath `/habiacu`.
- `/habiacu` is an NFS mount.
- The NFS source is `167.28.202.2`.

It then runs three read tests and collects NFS, TCP, route, interface, socket, and bounded packet-capture evidence.

When complete, it prints:

```text
DONE. SEND THIS SINGLE FILE TO THE ANALYST:
/tmp/nfs_read_customer_YYYYMMDD_HHMMSS.tar.gz
```

The customer sends that `.tar.gz` file to the analyst. The `.sha256` file is optional and can be used to verify the transfer.

## Analyst procedure

Copy the returned bundle into this project directory or reference it by its full path.

Run:

```bash
chmod 755 analyze-nfs-read.sh

./analyze-nfs-read.sh \
  /path/to/nfs_read_customer_YYYYMMDD_HHMMSS.tar.gz
```

The analyzer prints the conclusion and creates:

```text
nfs_read_analysis_YYYYMMDD_HHMMSS.txt
```

The report includes:

- Throughput for each read and the average throughput.
- Client-cache effect between reads.
- TCP retransmission count and ratio.
- NFS RPC retransmissions.
- Effective NFS mount options.
- Packet-capture availability.
- Likely fault domain and next investigation step.

The default slow-throughput threshold is `100 MiB/s`. Override it when the expected service level is different:

```bash
./analyze-nfs-read.sh customer-bundle.tar.gz --slow-mib-s 200
```

No production mount, network, or HP-UX server settings are changed automatically.
