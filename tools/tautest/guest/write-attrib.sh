#!/bin/bash
# Attribute device writes to the thread that issued them.
#
#   usage: write-attrib.sh <ext4|xfs> <vanilla|tau> [io-bytes] [count]
#
# Answers "where did the write amplification go?" for a repeated write+fsync of
# the same region. block:block_rq_issue carries the issuing task's comm, which
# splits cleanly along the paths we care about:
#
#   tauoverwrite   tau journal (descriptor, data, commit record) - fsync context
#   tau_journald   checkpoint writeback to the original location
#   jbd2/...       ext4's own metadata journal
#   kworker/...    VM writeback
#
# The totals are per-request bytes from the tracepoint, so they should add up to
# roughly the NVMe SMART delta over the same window.

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:?usage: $0 <ext4|xfs> <vanilla|tau> [io-bytes] [count]}
VARIANT=${2:?usage: $0 <ext4|xfs> <vanilla|tau> [io-bytes] [count]}
IO=${3:-4096}
CNT=${4:-3000}

OW=${OW:-$TAU_BIN/tauoverwrite}
[ -x "$OW" ] || die "missing $OW"
TR=${TR:-/sys/kernel/tracing}
# tracefs is mode 0700, so the existence check has to run as root too
sudo test -d "$TR/events/block" || die "no tracefs at $TR"

[ "$VARIANT" = tau ] && TF=1 || TF=0

mnt() {	# mnt <mkfs 0|1>
	sudo umount "$TAU_MNT" 2>/dev/null || true
	case "$FS/$VARIANT" in
	ext4/vanilla) [ "$1" = 1 ] && sudo "$MKE2FS" -t ext4 -F -E lazy_itable_init=0 "$TAU_DEV" >/dev/null 2>&1
	              sudo mount -t ext4 "$TAU_DEV" "$TAU_MNT" ;;
	ext4/tau)     [ "$1" = 1 ] && sudo "$MKE2FS" -t ext4 -F -E lazy_itable_init=0 "$TAU_DEV" >/dev/null 2>&1
	              sudo mount -t ext4 -o tjournal,tjournal_size=32 "$TAU_DEV" "$TAU_MNT" ;;
	xfs/vanilla)  [ "$1" = 1 ] && sudo "$MKFS_XFS" -f "$TAU_DEV" >/dev/null 2>&1
	              sudo mount -t xfs "$TAU_DEV" "$TAU_MNT" ;;
	xfs/tau)      [ "$1" = 1 ] && sudo "$MKFS_XFS" "$TAU_DEV" -f -l tjmaxsize=1G >/dev/null 2>&1
	              sudo mount -t xfs -o tjournal "$TAU_DEV" "$TAU_MNT" ;;
	esac || die "mount failed"
}

duw() {
	sudo nvme smart-log "$TAU_DEV" 2>/dev/null |
		awk -F: '/Data Units Written/ {split($2,a,"("); gsub(/[ \t]/,"",a[1]); print a[1]}'
}

sudo mkdir -p "$TAU_MNT"
mnt 1
sudo "$OW" setup "$TAU_MNT/s.dat" "$IO" "$TF" >/dev/null
mnt 0

# Physical extent of the data file, so a request can be called in-place or not.
# filefrag reports filesystem blocks; the tracepoint reports 512 B sectors.
BS=$(sudo blockdev --getbsz "$TAU_DEV" 2>/dev/null || echo 4096)
# extent line: "   0:        0..       7:     274432..    274439:      8:  last,eof"
# turning ".." into a space makes the physical range fields $4 and $5
read -r DLO DHI <<EOF
$(sudo filefrag -b512 -v "$TAU_MNT/s.dat" 2>/dev/null |
	awk '$1 ~ /^[0-9]+:$/ {
		gsub(/\.\./, " "); gsub(/:/, "")
		if (lo == "" || $4 < lo) lo = $4
		if ($5 > hi) hi = $5
	} END { print lo + 0, hi + 0 }')
EOF
[ "${DHI:-0}" -gt 0 ] || { DLO=0; DHI=0; }
echo "data extent: sectors $DLO..$DHI (block size $BS)"

# ext4 zeroes inode tables in the background after mkfs; that traffic would be
# counted as ours. Wait it out before snapshotting the counters.
while pgrep -x ext4lazyinit >/dev/null 2>&1; do sleep 2; done
sync; sleep 2
S0=$(duw)

sudo sh -c "echo 0 > $TR/tracing_on
	    echo > $TR/trace
	    echo 32768 > $TR/buffer_size_kb
	    echo 1 > $TR/events/block/block_rq_issue/enable
	    echo 1 > $TR/tracing_on"

sudo "$OW" run "$TAU_MNT/s.dat" "$IO" "$IO" "$CNT" 1 seq "$TF"

sudo sh -c "echo 0 > $TR/tracing_on"
sudo cp "$TR/trace" /tmp/attrib.txt
sudo chmod 644 /tmp/attrib.txt
sudo sh -c "echo 0 > $TR/events/block/block_rq_issue/enable"
sudo umount "$TAU_MNT"; sync; sleep 3
S1=$(duw)

echo
echo "== device writes by issuing thread ($FS/$VARIANT, ${IO}B x $CNT, fsync each) =="
# The tracepoint stops at the umount, so SMART also covers the unmount-time
# flush; a large gap between the two means work deferred past the last fsync.
printf '   %-16s %8d MB  (NVMe SMART, includes umount)\n' \
	"smart-delta" $(( (S1 - S0) * 512000 / 1048576 ))
# trace line: comm-pid [cpu] flags ts: block_rq_issue: 259,0 WS 32768 () sector + nr [comm]
# Parsed positionally rather than with match(): the guest has mawk, whose
# match() takes no capture array.
awk -v cnt="$CNT" -v dlo="$DLO" -v dhi="$DHI" '
	{
		for (i = 1; i <= NF; i++) if ($i == "block_rq_issue:") break
		if (i > NF) next
		rwbs = $(i + 2); nbytes = $(i + 3)
		if (rwbs !~ /W/) next		# writes only (W, WS, WM, FWS...)
		split($1, a, "-"); who = a[1]
		bytes[who] += nbytes; reqs[who]++; tot += nbytes

		# $(i+4) is the "()" payload column, $(i+5) the starting sector
		sec = $(i + 5) + 0
		if (dhi > 0 && sec >= dlo && sec <= dhi) {
			inplace += nbytes; inreq++
		} else {
			jrnl += nbytes; jreq++
			seen[sec]++
		}
	}
	END {
		for (w in bytes)
			printf "   %-16s %8.1f MB  %7d reqs  %6.1f KB/write-op\n",
			       w, bytes[w]/1048576, reqs[w], bytes[w]/1024/cnt
		printf "   %-16s %8.1f MB\n", "TOTAL", tot/1048576
		printf "   %-16s %8.1f MB  %7d reqs  %6.1f KB/write-op\n",
		       "  in-place", inplace/1048576, inreq, inplace/1024/cnt
		printf "   %-16s %8.1f MB  %7d reqs  %6.1f KB/write-op  %d distinct sectors\n",
		       "  journal+meta", jrnl/1048576, jreq, jrnl/1024/cnt, length(seen)
	}
' /tmp/attrib.txt
