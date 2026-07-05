# Codex Handoff: NFS Read Performance Diagnostic Toolkit

## Objective

Create a small Linux diagnostic toolkit to measure **NFS read performance only** for this flow:

```text
Client:      10.4.3.209
NFS Server:  167.28.202.2
Protocol:    NFS over TCP/2049
Direction:   Read from NFS server to OCI client
```

The problem is: **NFS reads from `10.4.3.209` toward `167.28.202.2` are slow**, while `ping` and `traceroute` look healthy.

The toolkit must determine whether the bottleneck is:

```text
1. TCP/network/firewall/MTU retransmissions
2. NFS client mount/options
3. NFS server/storage bottleneck
```

---

## Topology Context

```text
OCI Client 10.4.3.209
   ↓
CIRION / Backbone
   ↓
Firewall PA OCI 192.168.235.57
   ↓
Core switches / HSRP VIP 167.28.202.6
   ↓
NFS Server PRODUC 167.28.202.2
```

Known evidence:

```text
- Ping to 167.28.202.2 is successful.
- Traceroute to 167.28.202.2 is successful.
- Basic network reachability appears healthy.
- Issue appears only during NFS read performance.
```

---

## Required Deliverables

Create the following files:

```text
nfs_read_monitor.sh
nfs_read_test.sh
nfs_read_analyze.sh
README.md
```

Rules:

```text
- No secrets.
- No credentials.
- No hardcoded mount path except as configurable parameters.
- All output should go to a timestamped directory.
- Final monitor output should be packaged as .tar.gz.
```

---

# 1. Script: `nfs_read_monitor.sh`

## Purpose

Run in **session 1** on client `10.4.3.209`.

This script monitors TCP/NFS behavior while the read test runs in another terminal.

## Required usage

```bash
sudo ./nfs_read_monitor.sh \
  --server 167.28.202.2 \
  --duration 300 \
  --outdir /tmp/nfs_read_test
```

## Required behavior

The script must:

```text
- Create timestamped output directory.
- Capture mount information.
- Capture NFS mount options.
- Capture NFS client counters before/during/after.
- Capture TCP counters before/after.
- Sample TCP socket state with ss every 5 seconds.
- Run tcpdump for NFS TCP/2049.
- Stop tcpdump cleanly on timeout or Ctrl+C.
- Produce final tar.gz bundle.
```

## Required commands to collect

```bash
mount
nfsstat -m
nfsstat -c
netstat -s
ss -ti dst 167.28.202.2
tcpdump -ni any host 167.28.202.2 and tcp port 2049 -s 0 -w <file>.pcap
```

## Required output files

```text
mount_info.txt
nfsstat_mounts.txt
nfsstat_client_before.txt
nfsstat_client_during.log
nfsstat_client_after.txt
netstat_s_before.txt
netstat_s_after.txt
ss_ti.log
tcp_retrans.log
nfs_read_167.28.202.2.pcap
summary.txt
nfs_read_test_<timestamp>.tar.gz
```

## Required signal handling

The script must trap:

```bash
INT
TERM
EXIT
```

And must stop `tcpdump` cleanly.

---

# 2. Script: `nfs_read_test.sh`

## Purpose

Run in **session 2** on client `10.4.3.209`.

This script performs read-only NFS tests against the mounted export from `167.28.202.2`.

## Required usage

```bash
./nfs_read_test.sh \
  --mount /mnt/nfs_167 \
  --file /mnt/nfs_167/testfile.dat \
  --runs 3 \
  --block-size 1M
```

## Required behavior

The script must:

```text
- Validate that the test file exists.
- Validate that the path is under an NFS mount.
- Print mount options.
- Run repeated read tests.
- Use dd reading from NFS and writing to /dev/null.
- Capture elapsed time and throughput.
- Write a timestamped log.
```

## Required read command

Default:

```bash
dd if="$TEST_FILE" of=/dev/null bs=1M status=progress
```

Optional direct I/O mode if requested:

```bash
dd if="$TEST_FILE" of=/dev/null bs=1M iflag=direct status=progress
```

## Required output file

```text
/tmp/nfs_read_dd_<timestamp>.log
```

## Output format example

```text
NFS READ TEST
Client: dbprd01-ezhwb1
NFS Server: 167.28.202.2
Mount: /mnt/nfs_167
File: /mnt/nfs_167/testfile.dat
File size: 10G

READ TEST 1
Elapsed: 120.4 sec
Throughput: 85 MB/s

READ TEST 2
Elapsed: 119.8 sec
Throughput: 86 MB/s

READ TEST 3
Elapsed: 121.2 sec
Throughput: 84 MB/s
```

---

# 3. Script: `nfs_read_analyze.sh`

## Purpose

Analyze the collected monitor bundle and test log.

## Required usage

```bash
./nfs_read_analyze.sh \
  --bundle /tmp/nfs_read_test_YYYYMMDD_HHMMSS.tar.gz \
  --dd-log /tmp/nfs_read_dd_YYYYMMDD_HHMMSS.log
```

## Required checks

The script should parse and summarize:

```text
- NFS mount options.
- dd throughput per run.
- Average throughput.
- TCP retransmission delta.
- NFS client retrans delta.
- ss -ti retrans indicators.
- Whether tcpdump file exists.
```

## Required final recommendation logic

Use this decision tree:

```text
Case A:
dd is slow + TCP retransmissions increase
=> likely network/firewall/MTU/path loss issue.

Case B:
dd is slow + no TCP retransmissions increase
=> likely NFS server, storage, export backend, or NFS mount/options issue.

Case C:
first read slow, later reads much faster
=> likely cache effect; backend storage may be slow but cache improves later reads.

Case D:
performance improves with smaller rsize/wsize
=> suspect MTU/MSS/firewall/path handling of larger packets.
```

---

# 4. README.md

## Must include

```text
- Purpose
- Topology
- Prerequisites
- How to run session 1
- How to run session 2
- How to analyze results
- How to interpret outcomes
- What files to send back
```

## Required runbook

### Session 1

```bash
sudo ./nfs_read_monitor.sh \
  --server 167.28.202.2 \
  --duration 300 \
  --outdir /tmp/nfs_read_test
```

### Session 2

```bash
./nfs_read_test.sh \
  --mount /mnt/nfs_167 \
  --file /mnt/nfs_167/testfile.dat \
  --runs 3 \
  --block-size 1M
```

### Analyze

```bash
./nfs_read_analyze.sh \
  --bundle /tmp/nfs_read_test_YYYYMMDD_HHMMSS.tar.gz \
  --dd-log /tmp/nfs_read_dd_YYYYMMDD_HHMMSS.log
```

---

## Acceptance Criteria

The toolkit is successful if it produces:

```text
1. A timestamped monitor tarball.
2. A dd read test log.
3. A clear throughput summary.
4. Evidence showing whether TCP retransmissions happened during NFS reads.
5. A simple conclusion:
   - Network/firewall/MTU likely
   - NFS/server/storage likely
   - Cache effect likely
   - More data required
```

---

## Constraints

```text
- Must be safe to run on production client.
- Read-only NFS test only.
- Do not write to the NFS export.
- Do not modify system configuration.
- Do not restart services.
- tcpdump should only capture host 167.28.202.2 and tcp port 2049.
```

---

## Optional Enhancements

Codex may add optional flags:

```bash
--interval 5
--direct-io
--no-tcpdump
--pcap-size-limit-mb 500
--server-port 2049
```

For large captures, consider tcpdump rotation:

```bash
tcpdump -ni any host "$SERVER" and tcp port 2049 \
  -s 0 \
  -C 100 \
  -W 5 \
  -w "$OUTDIR/nfs_read.pcap"
```

---

## Expected Final Output Example

```text
Summary:
- Average NFS read throughput: 42 MB/s
- TCP retransmissions increased: yes
- NFS client retrans increased: yes
- ss showed retrans/rto spikes: yes
- Conclusion: likely network/firewall/MTU/path loss during NFS reads.
```

or:

```text
Summary:
- Average NFS read throughput: 38 MB/s
- TCP retransmissions increased: no
- NFS client retrans increased: no
- ss showed stable RTT and no retrans
- Conclusion: likely NFS server/storage/export backend bottleneck.
```

---

## Sources

Official / Standards:

- Linux `nfs(5)` — NFS mount options: https://man7.org/linux/man-pages/man5/nfs.5.html
- Linux `nfsstat(8)` — NFS statistics: https://man7.org/linux/man-pages/man8/nfsstat.8.html
- Linux `ss(8)` — TCP socket inspection: https://man7.org/linux/man-pages/man8/ss.8.html
- Wireshark TCP Display Filter Reference: https://www.wireshark.org/docs/dfref/t/tcp.html
- RFC 8881 — NFS Version 4 Minor Version 1 Protocol: https://www.rfc-editor.org/rfc/rfc8881.html
