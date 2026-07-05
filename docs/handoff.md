# Handoff: OCI Linux to Legacy HP-UX NFS Read Failure

## Current status

The NFS export mounts on the OCI Linux client, but directory and file reads remain unusable.

The latest Linux mount options were:

```fstab
167.28.202.2:/habinat /habinat nfs rw,hard,vers=3,proto=udp,mountvers=3,mountproto=udp,rsize=8192,wsize=8192,timeo=11,retrans=3,nordirplus 0 0
```

Result:

```text
Mount succeeds.
ls -ltr /habinat does not respond.
```

This option set is not a working mitigation. Do not promote it as the production fix.

## Topology

```text
OCI Linux client: 10.4.3.209
        |
        | Routed backbone and firewall path
        v
Legacy HP-UX NFS server: 167.28.202.2 (produc)
Export: /habinat
Client mount: /habinat
```

The HP-UX machine dates from approximately 2000 and was last updated in 2013.

## Confirmed server compatibility constraint

The HP-UX server registers NFSv3 only over UDP:

```bash
rpcinfo -p 167.28.202.2 | awk '$1 == 100003 && $2 == 3'
```

Observed result:

```text
100003  3  udp  2049  nfs
```

There is no NFSv3/TCP registration. Adding `proto=tcp` on the Linux client fails with:

```text
mount.nfs: requested NFS version or transport protocol is not supported
```

Do not use `proto=tcp` until NFS/TCP has been enabled and verified on HP-UX.

## Mount variants attempted

### Original effective mount

```text
vers=3,rsize=32768,wsize=32768,hard,proto=udp,timeo=11,retrans=3
```

Result: extreme read delay.

### TCP attempt

```text
vers=3,proto=tcp
```

Result: mount rejected because the HP-UX server does not advertise NFS/TCP.

### Small UDP transfer attempt

```text
vers=3,proto=udp,rsize=1024,wsize=1024
```

Result: mount completed, but directory access was very slow and eventually returned:

```text
ls: reading directory '.': Invalid argument
```

### UDP with 8 KiB and READDIRPLUS disabled

```text
vers=3,proto=udp,mountvers=3,mountproto=udp,hard,timeo=11,retrans=3,rsize=8192,wsize=8192,nordirplus
```

Result: mount completed, but `ls -ltr /habinat` did not respond.

Conclusion: changing Linux `rsize`, `wsize`, and `nordirplus` has not restored usable access. Client mount tuning alone is insufficient.

## Diagnostic evidence

### Large-file run

Source directory:

```text
diag-logs/nfs_read_customer_20260704_222453
```

Test file:

```text
/habinat/SLB/DATA/RESTOT202603.SLB
```

Results:

```text
1 MiB transferred in 166 seconds
Observed throughput: 6.3 kB/s
NFS RPC calls delta: 354
NFS RPC retransmission delta: 263
Retransmission-to-call ratio: 74.3%
NFSv3 READ operation delta: 68
```

IP fragmentation evidence during the same run:

```text
IP reassembly fragments requested: +1,476
IP reassemblies completed: +65
Approximately 22.7 fragments per completed datagram
```

The fragmentation pattern is consistent with 32 KiB UDP NFS responses crossing a path with smaller MTU segments.

### Tiny-file run

Source directory:

```text
diag-logs/nfs_read_customer_20260704_223709
```

Test file:

```text
/habinat/pruebaoci
File size: 15 bytes
```

Results:

```text
First 15-byte read took approximately 9 seconds at the dd layer
NFS RPC calls delta: 57
NFS RPC retransmission delta: 35
Retransmission-to-call ratio: 61.4%
```

This confirms that the problem is not limited to bulk transfer or large-file fragmentation. Small NFS metadata/data RPCs also experience severe delay or retransmission.

### Client interface evidence

```text
Route: 167.28.202.2 via 10.4.3.1 dev bondeth0 src 10.4.3.209
Client interface MTU: 9000
Client RX errors/drops: 0
Client TX errors/drops: 0
```

A local OCI client NIC failure is unlikely.

## Current assessment

The immediate failure mechanism is severe NFSv3/UDP RPC loss or delayed responses. The likely fault domains are:

1. Firewall or network handling of UDP and fragmented IP traffic.
2. Packet loss or MTU incompatibility on the routed path.
3. Legacy HP-UX NFS service response behavior.
4. HP-UX server CPU, NIC, NFS daemon, or storage latency.

Fragmentation clearly affects large reads, but the tiny-file test shows that fragmentation alone does not explain every delay. The exact loss point is not established.

## Packet-capture limitation

Both customer runs failed to produce a pcap. `tcpdump` dropped privileges and could not create the rotated output file inside the root-only diagnostic directory:

```text
tcpdump: /tmp/nfs_read_customer_<timestamp>/nfs_read.pcap0: Permission denied
```

No packet-level evidence is available yet.

## Immediate operational action

If `ls -ltr /habinat` is still running, stop it with `Ctrl+C` once. Because the mount is `hard`, the command can continue retrying indefinitely.

Do not run more unbounded `ls`, `find`, `du`, or file-copy commands against `/habinat`.

From a second Linux session, inspect only mount state with a timeout:

```bash
timeout 10 findmnt -T /habinat -o TARGET,SOURCE,FSTYPE,OPTIONS
```

Do not force-unmount or lazy-unmount the production filesystem while applications are using it. Coordinate a maintenance window and stop consumers before a clean unmount.

## Required next steps

### 1. Network and firewall investigation

Provide the following flow to the network team:

```text
Source: 10.4.3.209
Destination: 167.28.202.2
Protocol: UDP
NFS port: 2049
```

Request checks for:

- Dropped or filtered non-initial IP fragments.
- UDP/2049 packet loss.
- UDP session timeout behavior.
- MTU consistency across OCI, backbone, firewall, and HP-UX segments.
- Firewall interface fragmentation, drop, and discard counters.
- A controlled firewall-bypass comparison if policy permits.

### 2. HP-UX server investigation

Collect server-side evidence during a bounded client read:

- `nfsstat -s` before and after.
- `netstat -s` before and after.
- NFS daemon availability and saturation.
- Server NIC errors and drops.
- CPU, run queue, memory pressure, and disk latency.
- Export configuration for `/habinat`.

Use HP-UX-native commands approved by the platform administrator. The system is legacy and should not be restarted or reconfigured without a maintenance plan.

### 3. Determine whether NFS/TCP can be enabled

The preferred transport correction is NFSv3 over TCP. The HP-UX administrator must determine whether the installed HP-UX/NFS release can enable TCP using a supported configuration or patch level.

After any server-side change, verify from Linux:

```bash
rpcinfo -p 167.28.202.2 | awk '$1 == 100003 && $2 == 3'
```

Do not attempt a TCP mount unless a TCP registration is visible.

### 4. Strategic remediation

If the HP-UX server cannot reliably provide NFS/TCP, move the data-serving function to a supported platform. Options include:

- Migrate the export to a supported NFS server.
- Replicate or stage required files near OCI using a supported transfer mechanism.
- Introduce a validated data-transfer gateway close to HP-UX, avoiding long-distance legacy NFS/UDP.

Do not rely on additional Linux mount tuning as the permanent correction.

## References

- Full RCA: `docs/RCA.md`
- First-run analysis: `diag-logs/nfs_read_customer_20260704_222453/analysis.md`
- Second-run analysis: `diag-logs/nfs_read_customer_20260704_223709/analysis.md`

## Handoff decision

**Current mount configuration is not usable.**  
**NFS/TCP is unavailable on the legacy server.**  
**Client-side UDP tuning did not restore directory access.**  
**Next owner:** network/firewall and HP-UX platform teams, followed by a supported-platform migration decision.
