#!/usr/bin/env python3
"""Tables of the PROFILE=diag runs (paper §3 Tables 2/3) from their raw files.

Reads <profile_dir>/runs/<db>/<ts>/ (run_main.sh PROFILE=diag result
directories) and the throughput runs' summary.csv for the TPS comparison, and
writes <profile_dir>/tables.md and <profile_dir>/summary.csv:

- every run: TPS, mean and p99 latency of the 5-min measurement, and its TPS
  against the throughput run at 64 threads (run 1, same seed, and the mean of 3);
- PG: pg_stat_wal over the measurement (track_wal_io_timing=on): log sync
  latency = wal_sync_time / wal_sync, transactions per log sync, writes, FPI
  and WAL bytes per transaction; the FPI share of pg_waldump --stats (diagnosis
  window, with FPW);
- MySQL: redo fsyncs over the measurement (performance_schema, as in the
  throughput runs), Innodb_buffer_pool_wait_free and the single-page flush
  metrics; the free-page waits of the user threads in the diagnosis window
  (freepage_wait.bt): ms per transaction and share of their wall time;
- ZFS: perf record shares of the zfs/spl modules (diagnosis window).

Usage: profile_tables.py <profile_dir> <throughput summary.csv>
"""
import csv
import re
import statistics
import sys
from pathlib import Path

USER_THREADS = 64          # sysbench threads = user (connection) threads
CONFIGS = {("ext4", "off"): "EXT4_Raw", ("ext4", "on"): "EXT4_App",
           ("xfs", "off"): "XFS_Raw", ("xfs", "on"): "XFS_App"}


def config(fs, fpw):
    if (fs, fpw) in CONFIGS:
        return CONFIGS[(fs, fpw)]
    if fs.startswith("ext4-dj"):
        return "EXT4_Data"
    if fs.startswith("zfs"):
        return "ZFS"
    return fs


def kv_lines(path, tag):
    """key=value pairs of the lines that start with <tag>."""
    out = {}
    if not path.exists():
        return out
    for line in path.read_text().splitlines():
        if line.startswith(tag + " "):
            for k, v in re.findall(r"(\w+)=([-\d.]+)", line):
                out[k] = float(v)
    return out


def tag_table(path, tag):
    """'<tag> NAME VALUE ...' lines (SHOW GLOBAL STATUS / INNODB_METRICS dumps)."""
    out = {}
    if not path.exists():
        return out
    for line in path.read_text().splitlines():
        f = line.split()
        if len(f) >= 3 and f[0] == tag:
            try:
                out[f[1]] = float(f[2])
            except ValueError:
                pass
    return out


def bt_maps(path):
    """bpftrace '@map[key]: value' lines and the window markers."""
    maps, marks = {}, {}
    if not path.exists():
        return maps, marks
    for line in path.read_text().splitlines():
        m = re.match(r"@(\w+)\[(.+?)\]: (\d+)$", line)
        if m:
            maps.setdefault(m.group(1), {})[m.group(2)] = int(m.group(3))
        m = re.match(r"(window_\w+_ns) (\d+)", line)
        if m:
            marks[m.group(1)] = int(m.group(2))
    return maps, marks


def waldump_fpi_share(path):
    """FPI bytes / (record + FPI bytes) of pg_waldump --stats' Total line."""
    if not path.exists():
        return None
    for line in path.read_text().splitlines():
        if line.strip().startswith("Total"):
            nums = [float(x) for x in re.findall(r"[\d.]+", line)]
            # Total  N  [100%]  record bytes [pct]  FPI bytes [pct]  combined [100%]
            ints = [n for n in nums if n.is_integer()]
            if len(ints) >= 4:
                rec, fpi = ints[1], ints[2]
                return fpi / (rec + fpi) if rec + fpi else None
    return None


def perf_dso_share(path, names=("[zfs]", "[spl]")):
    if not path.exists():
        return None
    share = 0.0
    for line in path.read_text().splitlines():
        f = line.split()
        if len(f) >= 2 and f[-1] in names:
            share += float(f[0].rstrip("%"))
    return share


def main():
    pdir, thr_csv = Path(sys.argv[1]), Path(sys.argv[2])
    thr = {}
    for r in csv.DictReader(thr_csv.open()):
        if r["threads"] == "64":
            thr.setdefault((r["db"], config(r["fs"], r["fpw"])), {})[int(r["run"])] = float(r["tps"])
    rows = []
    for run in sorted(pdir.glob("runs/*/*/")):
        summ = run / "summary.csv"
        if not summ.exists():
            continue
        for r in csv.DictReader(summ.open()):
            if r["threads"] != "64":
                continue
            db, cfg = r["db"], config(r["fs"], r["fpw"])
            label = f"{db}_{r['workload']}_{r['fs']}_fpw_{r['fpw']}_t{r['tables']}_c64_r{r['run']}"
            pre = run / label
            tps, trx = float(r["tps"]), int(r["transactions"])
            ref = thr.get((db, cfg), {})
            row = {"db": db, "config": cfg, "source": run.name, "tps": round(tps),
                   "avg_ms": r["avg_ms"], "p99_ms": r["p99_ms"], "transactions": trx,
                   "tps_vs_r1_pct": round((tps / ref[1] - 1) * 100, 1) if 1 in ref else "",
                   "tps_vs_mean_pct": round((tps / statistics.mean(ref.values()) - 1) * 100, 1)
                   if ref else ""}
            if db == "postgres":
                b, e = kv_lines(Path(f"{pre}.pgstat"), "begin"), kv_lines(Path(f"{pre}.pgstat"), "end")
                d = {k: e[k] - b[k] for k in e if k in b}
                commits = d.get("xact_commit") or trx
                syncs = d.get("wal_sync", 0)
                row.update(
                    wal_sync=int(syncs), wal_sync_ms=round(d.get("wal_sync_time", 0), 1),
                    log_sync_ms=round(d["wal_sync_time"] / syncs, 4) if syncs else "",
                    trx_per_log_sync=round(commits / syncs, 2) if syncs else "",
                    wal_write=int(d.get("wal_write", 0)),
                    wal_write_ms=round(d.get("wal_write_time", 0), 1),
                    log_write_ms=round(d["wal_write_time"] / d["wal_write"], 4)
                    if d.get("wal_write") else "",
                    fpi_per_trx=round(d.get("wal_fpi", 0) / commits, 2),
                    wal_kb_per_trx=round(d.get("wal_bytes", 0) / 1024 / commits, 2),
                    commits=int(commits))
                share = waldump_fpi_share(Path(f"{pre}.diag.waldump"))
                if share is not None:
                    row["waldump_fpi_share_pct"] = round(share * 100, 1)
            else:
                rs, rms = float(r.get("redo_syncs") or 0), float(r.get("redo_sync_ms") or 0)
                row.update(redo_syncs=int(rs), redo_sync_ms=rms,
                           log_sync_ms=round(rms / rs, 4) if rs else "",
                           trx_per_log_sync=round(trx / rs, 2) if rs else "")
                sb = tag_table(Path(f"{pre}.my_status"), "begin")
                se = tag_table(Path(f"{pre}.my_status"), "end")
                wf = se.get("Innodb_buffer_pool_wait_free", 0) - sb.get("Innodb_buffer_pool_wait_free", 0)
                row.update(wait_free=int(wf), wait_free_per_s=round(wf / 300, 1),
                           wait_free_per_trx=round(wf / trx, 4))
                mb = tag_table(Path(f"{pre}.my_metrics"), "begin")
                me = tag_table(Path(f"{pre}.my_metrics"), "end")
                for name in ("buffer_LRU_single_flush_num_scan", "buffer_LRU_get_free_waits",
                             "buffer_LRU_get_free_loops", "buffer_flush_sync_waits"):
                    if name in me and name in mb:
                        row[name] = int(me[name] - mb[name])
                # diagnosis window: user threads' free-page waits
                maps, marks = bt_maps(Path(f"{pre}.diag.freepage.bt"))
                db_, de_ = (kv_lines(Path(f"{pre}.diag.freepage.status"), t) for t in ("begin", "end"))
                if maps and db_ and de_:
                    win_s = de_["time"] - db_["time"]
                    commits = de_["Com_commit"] - db_["Com_commit"]
                    user = "connection"
                    get_ns = maps.get("get_ns", {}).get(user, 0)
                    slow_ns = maps.get("slow_ns", {}).get(user, 0)
                    bt_win = (marks.get("window_end_ns", 0) - marks.get("window_begin_ns", 0)) / 1e9
                    sf = maps.get("single_flush_calls", {}).get(user, 0)
                    wall = USER_THREADS * bt_win * 1e9
                    row.update(
                        diag_window_s=round(win_s, 1), diag_bt_window_s=round(bt_win, 1),
                        diag_commits=int(commits), diag_tps=round(commits / win_s),
                        freepage_ms_per_trx=round(get_ns / 1e6 / commits, 4) if commits else "",
                        freepage_wall_share_pct=round(get_ns / wall * 100, 2) if bt_win else "",
                        freepage_slow_ms_per_trx=round(slow_ns / 1e6 / commits, 4) if commits else "",
                        freepage_slow_wall_share_pct=round(slow_ns / wall * 100, 2) if bt_win else "",
                        freepage_calls_user=maps.get("get_calls", {}).get(user, 0),
                        freepage_slow_calls_user=maps.get("slow_calls", {}).get(user, 0),
                        single_flush_user=sf,
                        single_flush_per_s=round(sf / bt_win, 1) if bt_win else "",
                        single_flush_per_trx=round(sf / commits, 4) if commits else "",
                        diag_wait_free_per_trx=round((de_["Innodb_buffer_pool_wait_free"]
                                                      - db_["Innodb_buffer_pool_wait_free"]) / commits, 4)
                        if commits else "")
            share = perf_dso_share(Path(f"{pre}.diag.perf.dso"))
            if share is not None:
                row["perf_zfs_spl_pct"] = round(share, 1)
            rows.append(row)

    fields = []
    for r in rows:
        fields += [k for k in r if k not in fields]
    with (pdir / "summary.csv").open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)
    md = ["# Profiling runs (PROFILE=diag): tables\n",
          "Generated by `bench/scripts/sysbench/profile_tables.py`. One 5-min measurement",
          "at 64 threads per configuration; the diagnosis window follows it.\n"]
    for db in ("postgres", "mysql"):
        sel = [r for r in rows if r["db"] == db]
        if not sel:
            continue
        cols = [c for c in fields if any(c in r for r in sel) and c != "db"]
        md.append(f"## {db}\n")
        md.append("| " + " | ".join(cols) + " |")
        md.append("|" + "---|" * len(cols))
        for r in sel:
            md.append("| " + " | ".join(str(r.get(c, "")) for c in cols) + " |")
        md.append("")
    (pdir / "tables.md").write_text("\n".join(md))
    print(f"{len(rows)} runs -> {pdir / 'tables.md'}")


if __name__ == "__main__":
    main()
