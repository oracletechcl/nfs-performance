#!/usr/bin/env bash
#
# nfs-collect.sh — ONE script, ONE tarball. Run it on the OCI Linux client.
#
#   sudo ./nfs-collect.sh                      # diagnoses /habinat
#   sudo ./nfs-collect.sh /habinat/pruebaoci   # also does a tiny read test
#
# Read-only. It never hangs (every network/NFS step is time-bounded), changes
# no mount/fstab, and touches nothing on the HP-UX server. When done it prints
# the path to a single .tar.gz to send to the analyst / network team.

if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -u
export LC_ALL=C

[ "$(uname -s)" = "Linux" ] || { echo "ERROR: run on the OCI Linux client only, not HP-UX/macOS." >&2; exit 1; }
(( EUID == 0 )) || { echo "ERROR: run with sudo (needed for tcpdump)." >&2; exit 1; }

SERVER=${SERVER:-167.28.202.2}
TARGET=${1:-/habinat}
CAP_SECONDS=${CAP_SECONDS:-30}     # hard cap on packet capture
PROBE_BUDGET=${PROBE_BUDGET:-25}   # hard cap on each stat/read probe
PING_WAIT=2

have() { command -v "$1" >/dev/null 2>&1; }
run()  { local f=$1; shift; if have "$1"; then timeout 20 "$@" >"$f" 2>&1 || true; else echo "unavailable: $1" >"$f"; fi; }

# Resolve mountpoint + optional read-test file.
if [[ -f $TARGET ]]; then FILE=$TARGET; MP=$(dirname "$TARGET"); else MP=$TARGET; FILE=""; fi
IFACE=$(ip route get "$SERVER" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')

RUN=$(date +%Y%m%d_%H%M%S)
W="/var/tmp/nfs_diag_${RUN}"
mkdir -p "$W" && chmod 777 "$W"
S="$W/SUMMARY.txt"                 # human-readable verdict lives here
exec 3>"$S"                        # fd 3 = summary
say() { printf '%s\n' "$*" | tee -a /dev/fd/3; }

say "=== NFS collect $RUN ==="
say "server=$SERVER  mountpoint=$MP  iface=${IFACE:-unknown}  readfile=${FILE:-none}"
say ""

snap()  { awk '$1=="rpc"{print $2,$3;exit}' /proc/net/rpc/nfs 2>/dev/null; }
reasm() { awk '/^Ip:/{if(h){print $r,$c}else{for(i=1;i<=NF;i++){if($i=="ReasmReqds")r=i;if($i=="ReasmOKs")c=i};h=1}}' /proc/net/snmp 2>/dev/null; }

# ---- BEFORE snapshots ----
read -r C0 R0 <<<"$(snap)"; FR0=$(reasm)
run "$W/findmnt.txt"       findmnt -T "$MP" -o SOURCE,TARGET,FSTYPE,OPTIONS
run "$W/mount_opts.txt"    nfsstat -m
run "$W/ip_route.txt"      ip route get "$SERVER"
run "$W/ip_link.txt"       ip -s link show dev "${IFACE:-lo}"
run "$W/nfsstat_before.txt"  nfsstat -c
run "$W/snmp_before.txt"     cat /proc/net/snmp
run "$W/rpc_before.txt"      cat /proc/net/rpc/nfs

# ---- Packet capture (fixed: -Z root so it can write; bounded) ----
PCAP="$W/nfs.pcap"; TPID=""
if have tcpdump && [[ -n $IFACE ]]; then
    say "[capture] up to ${CAP_SECONDS}s on $IFACE ..."
    ( tcpdump -ni "$IFACE" -Z root -s 256 -w "$PCAP" \
        "host $SERVER and (port 2049 or port 111)" >"$W/tcpdump.log" 2>&1 ) &
    TPID=$!
    ( sleep "$CAP_SECONDS"; kill -INT "$TPID" 2>/dev/null ) &   # watchdog
    sleep 2
    kill -0 "$TPID" 2>/dev/null || { say "[capture] tcpdump failed (see tcpdump.log)"; TPID=""; }
else
    say "[capture] tcpdump or iface unavailable — skipping pcap"
fi

# ---- Path-MTU sweep (DF bit) ----
{
    if have ping && timeout $((PING_WAIT+1)) ping -c1 -W "$PING_WAIT" "$SERVER" >/dev/null 2>&1; then
        IF_MTU=$(ip link show dev "${IFACE:-lo}" 2>/dev/null | sed -n 's/.*\bmtu \([0-9]*\).*/\1/p')
        HI=$(( ${IF_MTU:-1500} - 28 )); (( HI>8972 )) && HI=8972; LO=1272; BEST=0
        if timeout $((PING_WAIT+1)) ping -c1 -W "$PING_WAIT" -M do -s "$LO" "$SERVER" >/dev/null 2>&1; then
            BEST=$LO
            while (( LO<=HI )); do M=$(((LO+HI)/2))
                if timeout $((PING_WAIT+1)) ping -c1 -W "$PING_WAIT" -M do -s "$M" "$SERVER" >/dev/null 2>&1
                    then BEST=$M; LO=$((M+1)); else HI=$((M-1)); fi
            done
            echo "path_mtu=$((BEST+28))"
        else echo "path_mtu=inconclusive (small DF packet dropped; ICMP filtered or MTU<1300)"; fi
    else echo "path_mtu=unknown (server does not answer ping; ICMP likely blocked)"; fi
} >"$W/path_mtu.txt" 2>&1
say "[mtu] $(cat "$W/path_mtu.txt")"

# ---- One stat + one 1 KiB read, timed, bounded ----
t0=$(date +%s%N); timeout "$PROBE_BUDGET" stat "$MP" >/dev/null 2>&1; sc=$?; t1=$(date +%s%N)
say "[probe] stat: exit=$sc in $(awk -v a=$t0 -v b=$t1 'BEGIN{printf "%.2f",(b-a)/1e9}')s"
if [[ -n $FILE ]]; then
    t0=$(date +%s%N); timeout "$PROBE_BUDGET" dd if="$FILE" of=/dev/null bs=1024 count=1 >/dev/null 2>&1; dc=$?; t1=$(date +%s%N)
    say "[probe] 1KiB read: exit=$dc in $(awk -v a=$t0 -v b=$t1 'BEGIN{printf "%.2f",(b-a)/1e9}')s"
fi

# ---- Stop capture, AFTER snapshots ----
if [[ -n $TPID ]]; then sleep 3; kill -INT "$TPID" 2>/dev/null; wait "$TPID" 2>/dev/null; fi
run "$W/nfsstat_after.txt" nfsstat -c
run "$W/snmp_after.txt"    cat /proc/net/snmp
run "$W/rpc_after.txt"     cat /proc/net/rpc/nfs
read -r C1 R1 <<<"$(snap)"; FR1=$(reasm)

# ---- Analyze ----
say ""
say "=== RESULT ==="
if [[ -s $PCAP ]]; then
    cnt() { timeout 20 tcpdump -nr "$PCAP" "$1" 2>/dev/null | wc -l | tr -d ' '; }
    REQ=$(cnt "dst host $SERVER and dst port 2049")
    REP=$(cnt "src host $SERVER and src port 2049")
    FRAGS=$(timeout 20 tcpdump -nr "$PCAP" 2>/dev/null | grep -c frag || true)
    say "NFS requests sent : ${REQ:-?}"
    say "NFS replies recv  : ${REP:-?}"
    say "fragmented dgrams : ${FRAGS:-0}"
    if [[ -n ${REQ:-} && $REQ -gt 0 ]]; then
        if   (( REP == 0 ));        then say "VERDICT: requests leave, NOTHING returns -> path/firewall drops UDP-2049 or server silent. NETWORK/HP-UX owns this."
        elif (( REP < REQ/2 ));     then say "VERDICT: many resends per reply -> heavy UDP loss on the path. NEEDS TCP transport."
        else                             say "VERDICT: replies return ~1:1 but slow -> per-RPC LATENCY (slow server/path), not gross loss."
        fi
    fi
else
    say "No pcap captured (see tcpdump.log); relying on counters below."
fi
if [[ -n ${C0:-} && -n ${C1:-} ]]; then
    dc=$((C1-C0)); dr=$((R1-R0))
    (( dc>0 )) && say "RPC calls +$dc, retransmits +$dr ($(awk -v r=$dr -v c=$dc 'BEGIN{printf "%.0f",r*100.0/c}')%)"
fi
say "IP reasm (reqds ok) before=[$FR0] after=[$FR1]"

exec 3>&-
# ---- One tarball ----
BUNDLE="${W}.tar.gz"
tar -czf "$BUNDLE" -C /var/tmp "$(basename "$W")" 2>/dev/null
have sha256sum && sha256sum "$BUNDLE" >"${BUNDLE}.sha256"
echo
echo "============================================================"
echo "DONE. SEND THIS ONE FILE:"
echo "  $BUNDLE"
echo "Summary was printed above and is inside SUMMARY.txt."
echo "============================================================"
