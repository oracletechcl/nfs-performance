# Root Cause Analysis: Severe NFS Read Performance

## Incident summary

The OCI Linux client `10.4.3.209` experienced extremely slow reads from the HP-UX NFS server `167.28.202.2`. Basic reachability tests succeeded, but an NFS read from `/habinat` transferred only 1 MiB in 166 seconds, approximately 6.3 kB/s.

The diagnostic run was intentionally interrupted because completing the multi-run test at that rate would have taken many hours or days.

## Affected flow

```text
OCI Linux client: 10.4.3.209
        |
        | Routed and firewalled network path
        v
HP-UX NFS server: 167.28.202.2
Export: produc:/habinat
Client mount: /habinat
Protocol: NFSv3 over UDP
```

## Root cause

The primary root cause is the use of NFSv3 over UDP with 32 KiB read responses across a routed and firewalled network path:

```text
vers=3,rsize=32768,wsize=32768,hard,proto=udp,timeo=11,retrans=3
```

A 32 KiB NFS UDP response exceeds the network packet size and must be fragmented. The client recorded approximately 22.7 received IP fragments for each successfully reassembled datagram, which closely matches the fragmentation expected for a 32 KiB response crossing a 1500-byte segment of the path.

Loss or delay of any fragment prevents reconstruction of the complete UDP datagram. NFS must then wait for its RPC timeout and retransmit the request. Because the mount is `hard`, the client continues retrying instead of failing the operation. This combination produced the observed long stalls and extremely low effective throughput.

The collection recorded 263 new NFS RPC retransmissions for 354 new RPC calls, a retransmission-to-call ratio of 74.3% during the diagnostic window.

## Supporting evidence

### Read performance

| Measurement | Result |
|---|---:|
| File | `/habinat/SLB/DATA/RESTOT202603.SLB` |
| Data transferred before interruption | 1 MiB |
| Elapsed time | 166 seconds |
| Observed throughput | 6.3 kB/s |

### Effective NFS configuration

```text
Source: produc:/habinat
Target: /habinat
NFS version: 3
Read size: 32768
Write size: 32768
Mount behavior: hard
Data transport: UDP
RPC timeout: 11
Retransmissions: 3
Server address: 167.28.202.2
```

The active NFS data transport was UDP, not TCP.

### NFS and network counters

| Counter | Before | After | Delta |
|---|---:|---:|---:|
| NFS RPC calls | 1,460,224 | 1,460,578 | 354 |
| NFS RPC retransmissions | 32,976 | 33,239 | 263 |
| NFSv3 READ operations | 686,798 | 686,866 | 68 |
| IP reassembly fragments requested | 46,793 | 48,269 | 1,476 |
| IP reassemblies completed | 8,301 | 8,366 | 65 |
| Client TCP input errors | 66 | 66 | 0 |
| Client NIC receive errors/drops | 0 | 0 | 0 |
| Client NIC transmit errors/drops | 0 | 0 | 0 |

The NFS client counters are global across all NFS mounts on the host, so some background activity is included. Nevertheless, the retransmission increase, fragmentation pattern, and measured read delay are strongly consistent.

### Client interface and route

```text
Route: 167.28.202.2 via 10.4.3.1 dev bondeth0 src 10.4.3.209
Client interface: bondeth0
Client MTU: 9000
```

The OCI interface did not report receive or transmit errors. This makes a local client NIC fault unlikely. The routed path may contain smaller-MTU segments even though the OCI interface uses MTU 9000.

### TCP counters are not the NFS signal

Global TCP retransmissions increased during the collection, but NFS `/habinat` was using UDP. TCP retransmission counters therefore cannot directly explain this NFS read failure. No NFS TCP/2049 connection was present in the collected socket samples.

## Causal chain

```text
NFSv3 uses UDP
    -> 32 KiB NFS read responses require IP fragmentation
    -> fragments cross a routed/firewalled path
    -> fragment loss or delay prevents UDP datagram reassembly
    -> NFS RPC timeout and retransmission
    -> hard mount continues retrying
    -> read throughput collapses to approximately 6.3 kB/s
```

## Contributing factors

1. `proto=udp` was selected implicitly because the mount configuration did not explicitly require TCP.
2. `rsize=32768` creates large UDP datagrams that require many IP fragments.
3. The path crosses routing and firewall infrastructure, where fragmented UDP is more vulnerable to loss, filtering, or timeout behavior.
4. The `hard` mount correctly protects application data integrity, but makes packet-loss symptoms appear as long-running or stuck I/O.

## What was ruled out

- Basic network reachability was available.
- The OCI client interface showed no packet errors or drops.
- The issue was not a local filesystem test; the file resided on the NFS mount.
- TCP retransmissions were not the direct transport symptom because this mount used UDP.

HP-UX server CPU, NFS daemon capacity, NIC health, and storage latency were not measured in this collection. They remain secondary possibilities if an NFS/TCP comparison is also slow.

## Packet-capture limitation

No packet capture was produced. `tcpdump` dropped privileges to its service account and could not create the rotated capture file inside the root-only diagnostic directory:

```text
tcpdump: /tmp/nfs_read_customer_20260704_222453/nfs_read.pcap0: Permission denied
```

This prevents identification of the exact network device or direction where fragments were lost. The available NFS and IP counters are sufficient to prioritize an NFS/TCP comparison.

## Corrective action

### 1. Verify HP-UX NFS/TCP support

From the OCI Linux client:

```bash
rpcinfo -p 167.28.202.2 | awk '$1 == 100003 && $2 == 3'
```

Confirm that NFS version 3 is advertised with `tcp` on port 2049.

### 2. Perform a temporary read-only TCP comparison

Do not change the active `/habinat` mount initially. With customer change approval, create a temporary read-only mount. Keep the 32 KiB transfer size so the comparison changes only the transport from UDP to TCP:

```bash
sudo mkdir -p /mnt/habinat_tcp_test

sudo mount -t nfs \
  -o ro,vers=3,proto=tcp,hard,timeo=600,retrans=2,rsize=32768,wsize=32768 \
  167.28.202.2:/habinat /mnt/habinat_tcp_test
```

Run a bounded comparison:

```bash
sudo timeout --signal=INT 300 \
  dd if=/mnt/habinat_tcp_test/SLB/DATA/RESTOT202603.SLB \
  of=/dev/null bs=1M iflag=direct status=progress
```

If the NFS client rejects `iflag=direct`, repeat without it and record that client caching may affect the result.

Remove the temporary mount:

```bash
sudo umount /mnt/habinat_tcp_test
```

### 3. Schedule the production correction

If the temporary TCP test is materially faster and does not increase NFS RPC retransmissions, schedule a maintenance-window change of the production mount from UDP to TCP.

Recommended baseline options:

```text
rw,hard,vers=3,proto=tcp,timeo=600,retrans=2,rsize=32768,wsize=32768
```

The exact `/etc/fstab` entry must be validated against the customer naming standard and HP-UX server capabilities before deployment.

Do not remount the active production filesystem while applications are using it.

## Contingency actions

- If HP-UX does not offer NFSv3 over TCP, enable NFS/TCP server-side. Reducing UDP `rsize` can be tested as a temporary mitigation, but TCP is preferred.
- If NFS/TCP remains slow without TCP retransmissions, collect HP-UX NFS daemon, CPU, NIC, and disk-latency evidence.
- If NFS/TCP shows retransmissions or stalls, inspect OCI VNIC metrics, firewall drop counters, path MTU, and packet captures from both ends.

## Validation criteria

The correction is successful when all of the following are true:

1. `/habinat` uses `proto=tcp` in the effective mount options.
2. A bounded read completes at the agreed service-level throughput.
3. NFS RPC retransmissions remain stable or increase only negligibly during the read.
4. Client and server interfaces show no new errors or drops.
5. Application read performance returns to its expected baseline.

## Status

**Root cause confidence:** High for NFSv3/UDP fragmentation and retransmission as the immediate performance mechanism.  
**Exact loss location:** Not established because the pcap failed and no firewall or HP-UX server counters were included.  
**Recommended resolution:** Validate and migrate the NFS data transport to TCP through a temporary read-only A/B test followed by a controlled maintenance-window change.
