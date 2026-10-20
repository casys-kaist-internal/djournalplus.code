#!/bin/bash
# The whole atomicity table (paper §6.2) in four VMs side by side:
#   q1  tau kernel   tau-ext4, all rows, both profiles; then its three controls
#   q2  tau kernel   tau-xfs, the same
#   q3  basevm       ext4, all rows; ext4-dioread-lock and ext4-nodelalloc, the append rows
#   q4  basevm       xfs and ext4-data, all rows
# Each queue runs table.sh calls one after another; when all four are done, the
# table.csv files are merged and paper_table.py writes summary.md.
#   usage: full.sh <tau kernel tree> <basevm kernel tree> <out dir>
#   LIMIT_* and MEM [10G] can be overridden (four VMs fit beside the 126 GiB of
#   1G hugepages libra08 holds from boot); ZFS comes as a fifth queue later.
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

echo "===== full start $(date '+%F %T')  tau $KT  base $KB"
tq q1 5556 1236 tau-ext4 & p1=$!
sleep 20; tq q2 5559 1239 tau-xfs & p2=$!
sleep 20; bq q3 5560 1240 "$(cells ext4) $(cells ext4-dioread-lock ap2k ap4k ap16k) $(cells ext4-nodelalloc ap2k ap4k ap16k)" & p3=$!
sleep 20; bq q4 5561 1241 "$(cells xfs) $(cells ext4-data)" & p4=$!
wait $p1 $p2 $p3 $p4
echo "===== merge $(date '+%F %T')"
# from the captures themselves (cell.json says which cell), with this tree's
# cell_csv.py -- not the guests' copies
python3 $TC/cell_csv.py --header "$OUT"/*/cap-* > "$OUT/table.csv"
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
