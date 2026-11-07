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
#   CONTROLS: the tau queues' controls, each switch restoring a bug a fix closed
#   (the rows must fail again); VARIANTS: settings the rows must still pass.
#   Entries <tag>[:cap=<p>=<v>[,...]][:exp=<p>=<v>[,...]][:gen=<arg>[,...]][:rows=<r>[,...]]
#   [:profiles=<p>[,...]][:strats=none][:seg=<size>][:reserve=<MiB>]: cap is set
#   for each capture, exp while its states are explored (the recovery side), gen
#   goes to `torner gen` (GEN_EXTRA: --fdatasync), rows [ow16k,ap16k], profiles
#   [busy]; strats=none captures only (loginv judges the log, no state is
#   explored), seg is the tau segment size [TAU_SEG, 2m], reserve holds that much
#   guest memory back while gen runs, so reclaim asks the tau shrinker
#   (CAP_RESERVE_MB); a variant's tag starts "set-"
#   KCMDLINE reaches every VM's kernel command line (table.sh). Captures from
#   11-08 on unmount with no sync and make ext4 with lazy init off (table.sh's
#   CAPTURE_NOSYNC, TORNER_EXT4_LAZYINIT); summary.md lists the settings of
#   every capture it merges
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
CONTROLS=${CONTROLS:-record_fua_only:cap=tau_record_fua_only=1 segmap_fua_only:cap=tau_segmap_fua_only=1 reuse_flush_only:cap=tau_reuse_flush_only=1}
VARIANTS=${VARIANTS:-}
tq() {	# <name> <port> <gdb> <fs>
	local n=$1 p=$2 gp=$3 fs=$4 c tag f cap exp gen rows profs kind lim strats seg res
	CELLS="$(cells $fs)" PROFILES="quiet busy" LIMIT_ATOM=${LIMIT_TAU_ATOM:-1500} \
		LIMIT_EPOCH=${LIMIT_TAU_EPOCH:-2000} NAME=$n PORT=$p GDB_PORT=$gp \
		bash $TC/table.sh "$KT" "$OUT/$n-main"
	for c in $CONTROLS $VARIANTS; do
		tag=${c%%:*} cap= exp= gen= rows="ow16k ap16k" profs=busy kind=ctl lim=${LIMIT_CTL:-800}
		strats=${STRATS:-row} seg=${TAU_SEG:-2m} res=${CAP_RESERVE_MB:-0}
		case $tag in set-*) kind=var lim=${LIMIT_VAR:-1000} ;; esac
		for f in $(tr : ' ' <<< "${c#"$tag"}"); do
			case $f in
			cap=*) cap=${f#cap=} ;;
			exp=*) exp=${f#exp=} ;;
			gen=*) gen=$(tr , ' ' <<< "${f#gen=}") ;;
			rows=*) rows=$(tr , ' ' <<< "${f#rows=}") ;;
			profiles=*) profs=$(tr , ' ' <<< "${f#profiles=}") ;;
			strats=*) strats=$(tr , ' ' <<< "${f#strats=}") ;;
			seg=*) seg=${f#seg=} ;;
			reserve=*) res=${f#reserve=} ;;
			*) echo "$c: unknown field $f" ;;
			esac
		done
		CELLS="$(cells $fs $rows)" PROFILES="$profs" CAP_PARAM="$cap" EXPLORE_PARAM="$exp" \
			GEN_EXTRA="$gen" TAG=$tag LIMIT_ATOM=$lim LIMIT_EPOCH=$lim NAME=$n PORT=$p \
			STRATS="$strats" TAU_SEG=$seg CAP_RESERVE_MB=$res \
			GDB_PORT=$gp bash $TC/table.sh "$KT" "$OUT/$n-$kind-$tag"
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

echo "===== full start $(date '+%F %T')  tau $KT  base $KB  queues" $QUEUES "${KCMDLINE:+ cmdline +$KCMDLINE}"
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
	python3 - "$OUT/table.csv" <<'PYEOF'
import csv, sys
allr = list(csv.DictReader(open(sys.argv[1])))
# what each capture was made with: a merged earlier run may differ (before 11-08:
# a sync before the unmount, ext4 with lazy init on, seeks 2)
def ext4(r):
    return r["config"] in ("ext4", "ext4-data", "ext4-dioread-lock", "ext4-nodelalloc", "tau-ext4")
st = {}
for r in allr:
    lazy = ("off" if "lazy_itable_init=0" in r["mkfs_opts"] else "on") if ext4(r) else "-"
    sync = {"0": "no sync", "1": "sync"}.get(r.get("unmount_sync", ""), "sync (not recorded)")
    k = (r["config"], r["kernel"].split()[1] if len(r["kernel"].split()) > 1 else r["kernel"],
         sync, lazy, r.get("seeks", "") or "-")
    st[k] = st.get(k, 0) + 1
print("\ncapture settings (config, kernel build, unmount, ext4 lazy init, tau_shrink_seeks): captures")
for k in sorted(st):
    print("  %-17s %-5s %-20s lazy init %-3s seeks %-3s %d" % (k + (st[k],)))
rows = [r for r in allr if r["tag"]]
for title, var in (("controls (a switch restores a fixed bug: each must fail)", False),
                   ("variants (a setting: each must pass)", True)):
    sel = [r for r in rows if r["tag"].startswith("set-") == var]
    if not sel:
        continue
    print("\n" + title)
    for r in sel:
        bad = sum(int(r[k] or 0) for k in ("viol_content", "viol_size", "viol_durability", "writes_torn"))
        verdict = ("VIOLATIONS" if bad else "passes") if var else ("FAILS (good)" if bad else "no signal")
        if not int(r["states"] or 0) and not bad:
            verdict = "captured only: loginv below"
        print("  %-9s %-9s %-6s %-30s states=%-5s content=%s size=%s durability=%s torn=%s/%s  %s" % (
            r["config"], r["row"], r["profile"], r["tag"], r["states"], r["viol_content"], r["viol_size"],
            r["viol_durability"], r["writes_torn"], r["writes_targeted"], verdict))
# the tau probe counters (CONFIG_TAU_PROBE_TORN), captures from 11-06 on
tau = [r for r in csv.DictReader(open(sys.argv[1])) if r.get("reuse_flush")]
if tau:
    print("\ntau segment reuse per cell: reuses, and frees tau_flush_freed wrote on the spot"
          " (none of the reused segment's free on the map log yet), in gen's timed run --"
          " the part explore crashes in -- and over the whole capture")
    for r in tau:
        bad = sum(int(r[k] or 0) for k in ("viol_content", "viol_size", "viol_durability", "writes_torn"))
        print("  %-9s %-10s %-6s %-14s states=%-5s violations=%-3s run: reused %s, on the spot %s"
              "   capture: reused %s, on the spot %s" % (
                  r["config"], r["row"], r["profile"], r["tag"], r["states"], bad,
                  r["reused_win"] or "?", r["reuse_flush_win"] or "?", r["reused"], r["reuse_flush"]))
# capture.sh's gated I1 (loginv.json), captures from 11-07 on: every record of
# the log, no crash state needed.  Only record_fua_only can show here; the
# other controls switch recovery, not the log.
i1 = [r for r in csv.DictReader(open(sys.argv[1])) if r.get("i1_checked")]
if i1:
    print("\ngated I1 per cell (torner loginv over every record): checked/skipped, blocks missing,"
          " ordered by own flush / by host commit / gate never open, violations")
    for r in i1:
        must_fail = r["tag"].startswith("record_fua_only")
        nv = int(r["i1_violations"] or 0)
        verdict = ("FAILS (good)" if nv else "NO SIGNAL") if must_fail else ("VIOLATIONS" if nv else "passes")
        print("  %-9s %-10s %-6s %-22s %s/%s  missing %s  own %s / host %s / never %s  violations %s  %s" % (
            r["config"], r["row"], r["profile"], r["tag"], r["i1_checked"], r["i1_skipped"],
            r["i1_missing"], r["i1_own"], r["i1_gated"], r["i1_gate_closed"], nv, verdict))
# I2-I4 from the same loginv.json: the tail, scoped revoke tags, the map log.
i24 = [r for r in csv.DictReader(open(sys.argv[1])) if r.get("i2_blocks")]
if i24:
    print("\nI2-I4 per cell (torner loginv): tail blocks not covered / checked, leads;"
          " scoped tags violating / checked; segment reuses violating / checked")
    # the controls these checks must catch (the kernel session, 11-07);
    # segmap_fua_only showed on tau-ext4 only with lazy init off and no sync
    # before the unmount (11-07), the capture defaults from 11-08
    must = ("record_fua_only", "segmap_fua_only", "maplog_early_base", "reuse_flush_only")
    for r in i24:
        nv = sum(int(r[k] or 0) for k in ("i2_uncovered", "i3_violations", "i4_violations"))
        ctl = r["tag"].replace("tau_", "", 1).startswith(must)
        verdict = ("FAILS (good)" if nv else "NO SIGNAL") if ctl else ("VIOLATIONS" if nv else "passes")
        print("  %-9s %-10s %-6s %-22s I2 %s/%s leads %s  I3 %s/%s  I4 %s/%s  %s" % (
            r["config"], r["row"], r["profile"], r["tag"], r["i2_uncovered"], r["i2_blocks"],
            r["i2_leads"], r["i3_violations"], r["i3_tags"], r["i4_violations"], r["i4_reuses"],
            verdict))
# how often reclaim asked the tau shrinker while gen ran (captures from 11-08 on):
# tau_shrink_seeks scales the scans, and each scan kicks a checkpoint
sh = [r for r in csv.DictReader(open(sys.argv[1])) if r.get("shrink_count")]
if sh:
    print("\ntau shrinker per cell, while gen ran: seeks, calls of count (reclaim asked) and"
          " of scan (it scanned: a checkpoint kick), memory held back")
    for r in sh:
        bad = sum(int(r[k] or 0) for k in ("viol_content", "viol_size", "viol_durability", "writes_torn"))
        print("  %-9s %-10s %-6s %-22s seeks %-3s count %-7s scan %-6s reserve %-5s violations %s" % (
            r["config"], r["row"], r["profile"], r["tag"], r["seeks"], r["shrink_count"],
            r["shrink_scan"], r["reserve_mb"] or "0", bad))
# I5 from the same loginv.json: is each application write inside one durable
# unit -- a tau or jbd2 transaction, the bio with no data journal.  tau must
# have no split; ext4 data=journal's splits are its commit-induced tears.
i5 = [r for r in csv.DictReader(open(sys.argv[1])) if r.get("i5_checked")]
if i5:
    print("\nI5 per cell (each application write inside one durable unit): writes, split"
          " (in gen's timed run), partial, in no unit; the bio where there is no data journal")
    for r in i5:
        ns = int(r["i5_split"] or 0)
        tau = r["config"].startswith("tau-")
        verdict = ("VIOLATIONS" if ns else "passes") if tau else ("splits" if ns else "none split")
        print("  %-9s %-10s %-6s %-22s writes %-6s split %s (run %s)  partial %s  no unit %s  %s" % (
            r["config"], r["row"], r["profile"], r["tag"], r["i5_checked"], ns,
            r["i5_split_run"] or "-", r["i5_partial"] or "-", r["i5_no_unit"] or "-", verdict))
PYEOF
} > "$OUT/summary.md"
cat "$OUT/summary.md"
echo "===== full done $(date '+%F %T')"
