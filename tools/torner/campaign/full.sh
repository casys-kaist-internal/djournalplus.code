#!/bin/bash
# The whole atomicity table (paper §6.2) in four VMs side by side:
#   q1  tau kernel   tau-ext4, all rows, both profiles; then its three controls
#   q2  tau kernel   tau-xfs, the same
#   q3  basevm       ext4, all rows; ext4-dioread-lock and ext4-nodelalloc, the append rows
#   q4  basevm       xfs and ext4-data, all rows
#   q5  basevm+ZFS   zfs-16k-tp, the append rows, after q3 } with build_zfs.sh's kit
#   q6  basevm+ZFS   zfs-16k-tp, the other rows, after q4  } (ZFS_KIT), else no ZFS
# Each queue runs table.sh calls one after another; when all are done, the
# table.csv files are merged and paper_table.py writes summary.md.
#   usage: full.sh <tau kernel tree> <basevm kernel tree> <out dir>
#   LIMIT_* and MEM [10G] can be overridden (four VMs fit beside the 126 GiB of
#   1G hugepages libra08 holds from boot); the ZFS VMs take ZFS_MEM [8G] and
#   little CPU: ZFS explores one state at a time (every state is the same pool
#   GUID), ~0.5 s a state, so its 14 cells take two VMs ~3.5 h.
#   QUEUES [q1 q2 q3 q4 q5 q6] runs some of them, and MERGE names captures of an
#   earlier run to merge in -- after a tau fix, the tau columns alone:
#   QUEUES="q1 q2" MERGE="$(ls -d <earlier out>/{q3,q4,q5,q6}/cap-*)"
set -u
TC=$(cd "$(dirname "$0")" && pwd)
KT=$(cd "${1:?usage: full.sh <tau tree> <basevm tree> <out dir>}" && pwd) || exit 1
KB=$(cd "${2:?}" && pwd) || exit 1
OUT=$(realpath -m "${3:?}")
mkdir -p "$OUT" || exit 1
exec > >(tee -a "$OUT/full.log") 2>&1
ROWS="ow4k ow16k ap2k ap4k ap16k prealloc hole"
cells() { local fs=$1 r c=""; shift; for r in ${*:-$ROWS}; do c="$c $fs:$r"; done; echo $c; }
export MEM=${MEM:-10G}

# tau: no budget preference -- every write is a candidate; T has nothing to cut
# (tau writes each block in its own bio), so its time goes to O, R and prefix
tq() {	# <name> <port> <gdb> <fs>
	local n=$1 p=$2 gp=$3 fs=$4 sw
	CELLS="$(cells $fs)" PROFILES="quiet busy" LIMIT_ATOM=${LIMIT_TAU_ATOM:-1500} \
		LIMIT_EPOCH=${LIMIT_TAU_EPOCH:-2000} NAME=$n PORT=$p GDB_PORT=$gp \
		bash $TC/table.sh "$KT" "$OUT/$n-main"
	# controls: each switch restores a bug a fix closed; the rows must fail again
	for sw in tau_record_fua_only tau_segmap_fua_only tau_reuse_flush_only; do
		CELLS="$(cells $fs ow16k ap16k)" PROFILES="busy" CAP_PARAM="$sw=1" TAG=${sw#tau_} \
			LIMIT_ATOM=${LIMIT_CTL:-800} LIMIT_EPOCH=${LIMIT_CTL:-800} NAME=$n PORT=$p \
			GDB_PORT=$gp bash $TC/table.sh "$KT" "$OUT/$n-ctl-${sw#tau_}"
	done
}
# baselines: a witness is enough where they tear, so atom-* take split writes
# first; the epoch strategies get the larger budget -- an append's size can be on
# disk before its data, and only a crash point between the two shows it
bq() {	# <name> <port> <gdb> <cells>
	CELLS="$4" PROFILES="quiet busy" LIMIT_ATOM=${LIMIT_BASE_ATOM:-500} \
		LIMIT_EPOCH=${LIMIT_BASE_EPOCH:-2000} PREFER_SPLIT=1 NAME=$1 PORT=$2 GDB_PORT=$3 \
		bash $TC/table.sh "$KB" "$OUT/$1"
}
ZK=${ZFS_KIT:-/mnt/tau_backup/build/zfs-kit-2.2.2-0ubuntu9.5-basevm}
zq() {	# <name> <port> <gdb> <cells>: baseline budgets, the kit installed
	CELLS="$4" PROFILES="quiet busy" LIMIT_ATOM=${LIMIT_BASE_ATOM:-500} \
		LIMIT_EPOCH=${LIMIT_BASE_EPOCH:-2000} PREFER_SPLIT=1 MEM=${ZFS_MEM:-8G} \
		ZFS_KIT=$ZK NAME=$1 PORT=$2 GDB_PORT=$3 bash $TC/table.sh "$KB" "$OUT/$1"
}

QUEUES=${QUEUES:-q1 q2 q3 q4 q5 q6}
on() { case " $QUEUES " in *" $1 "*) return 0 ;; esac; return 1; }
if [ ! -f "$ZK/zfs.ko" ] && { on q5 || on q6; }; then
	echo "no ZFS kit at $ZK (campaign/build_zfs.sh): no ZFS column"
	QUEUES=${QUEUES//q5/}; QUEUES=${QUEUES//q6/}
fi

echo "===== full start $(date '+%F %T')  tau $KT  base $KB  queues" $QUEUES
pids=
on q1 && { tq q1 5556 1236 tau-ext4 & pids="$pids $!"; sleep 20; }
on q2 && { tq q2 5559 1239 tau-xfs & pids="$pids $!"; sleep 20; }
# ZFS takes a baseline's VM when it is done: four VMs at most
{ on q3 && bq q3 5560 1240 "$(cells ext4) $(cells ext4-dioread-lock ap2k ap4k ap16k) $(cells ext4-nodelalloc ap2k ap4k ap16k)"
  on q5 && zq q5 5562 1242 "$(cells zfs-16k-tp ap2k ap4k ap16k)"; } & pids="$pids $!"
sleep 20
{ on q4 && bq q4 5561 1241 "$(cells xfs) $(cells ext4-data)"
  on q6 && zq q6 5563 1243 "$(cells zfs-16k-tp ow4k ow16k prealloc hole)"; } & pids="$pids $!"
wait $pids
echo "===== merge $(date '+%F %T')"
if [ -n "${MERGE:-}" ]; then
	printf '%s\n' $MERGE > "$OUT/merged.txt"
	echo "with $(wc -l < "$OUT/merged.txt") captures of an earlier run (merged.txt)"
fi
# from the captures themselves (cell.json says which cell), with this tree's
# cell_csv.py -- not the guests' copies
python3 $TC/cell_csv.py --header "$OUT"/*/cap-* ${MERGE:-} > "$OUT/table.csv"
{
	python3 $TC/paper_table.py "$OUT/table.csv"
	echo; echo "controls (a switch restores a fixed bug: each must fail)"
	python3 - "$OUT/table.csv" <<'PYEOF'
import csv, sys
for r in csv.DictReader(open(sys.argv[1])):
    if r["tag"]:
        bad = sum(int(r[k] or 0) for k in ("viol_content", "viol_size", "viol_durability", "writes_torn"))
        print("  %-9s %-6s %-22s states=%-5s content=%s size=%s durability=%s torn=%s/%s  %s" % (
            r["config"], r["row"], r["tag"], r["states"], r["viol_content"], r["viol_size"],
            r["viol_durability"], r["writes_torn"], r["writes_targeted"], "FAILS (good)" if bad else "no signal"))
PYEOF
} > "$OUT/summary.md"
cat "$OUT/summary.md"
echo "===== full done $(date '+%F %T')"
