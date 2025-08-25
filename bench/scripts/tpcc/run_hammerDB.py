import os
import subprocess
from pathlib import Path
import sys
import time
import shutil
import pexpect

if "TAUFS_ENV_SOURCED" not in os.environ:
    print("Please source set_env.sh first. (TAUFS_ENV_SOURCED not set)")
    sys.exit(1)

# MODE = "IOVOLUME"
MODE = "PERFORMANCE"
# MODE = "TRIAL"

FS_GROUPS = {
    "on": [],        # full_page_writes: on
    # "off": ["zfs8k", "taujournal"]  # full_page_writes: off
    # "on": ["ext4", "f2fs"],        # full_page_writes: on
    # "off": ["ext4", "taujournal"]  # full_page_writes: off

    # "on": ["ext4", "btrfs", "f2fs"],
    # "off": ["ext4", "taujournal"]
    "off": ["zfs8k"]
}

# VU_LIST = [1, 32]
# WAREHOUSE_LIST = [10]

VU_LIST = [8, 16, 24, 32, 48, 64]
WAREHOUSE_LIST = [256] # 256 --> 25GB 정도인 듯


STOREDPROCS = [True] # default 
if MODE == "IOVOLUME":
    TOTAL_ITERATION=10000
    DURATION=100
    RAMPUP=0
elif MODE == "PERFORMANCE":
    TOTAL_ITERATION=100000000
    DURATION=10
    RAMPUP=5
elif MODE == "TRIAL":
    TOTAL_ITERATION=10000
    DURATION=1
    RAMPUP=1
else:
    print(f"Unsupported mode: {MODE}")
    sys.exit(1)


FULL_PAGE_WRITES = ["on", "off"]
TAU_DEVICE = os.environ.get("TAU_DEVICE")
TAUFS_BENCH = Path(os.environ["TAUFS_BENCH"])
TAUFS_BENCH_WS = Path(os.environ["TAUFS_BENCH_WS"])
HAMMERDB = TAUFS_BENCH_WS / "HammerDB-5.0"
TCL_TEMPLATE_BUILD = HAMMERDB / "build_template.tcl"
TCL_TEMPLATE_RUN = HAMMERDB / "run_template.tcl"
PG_INSTALL = TAUFS_BENCH_WS / "pg_install"
RESULTS = TAUFS_BENCH_WS / "results"
MOUNT_POINT = Path("/mnt/temp")
PG_DATA = MOUNT_POINT / "postgres"
PG_BACKUP_DIR = MOUNT_POINT / "pgdata_backup"
PG_USER = os.getlogin()

PG_DB = "tpccdb"
PG_PORT = 5432
PG_APP_USER = "tpccuser"
PG_APP_PASS = "tpccpass"

# === [2] 헬퍼 함수 ===
def run(cmd, **kwargs):
    print(f"[+] $ {cmd}")
    subprocess.run(cmd, shell=True, check=True, **kwargs)

def setup_filesystem(fs_type):
    if fs_type == "ext4":
        print(f"[+] Formatting {TAU_DEVICE} to ext4")
        run(f"sudo mkfs.ext4 -E lazy_itable_init=0,lazy_journal_init=0 -F {TAU_DEVICE}")
    elif fs_type == "btrfs":
        print(f"[+] Formatting {TAU_DEVICE} to btrfs")
        run(f"sudo mkfs.btrfs -f {TAU_DEVICE}")
    elif fs_type == "f2fs":
        print(f"[+] Formatting {TAU_DEVICE} to f2fs")
        run(f"sudo mkfs.f2fs -f {TAU_DEVICE}")
    elif fs_type == "taujournal":
        print(f"[+] Formatting {TAU_DEVICE} to TauJournal")
        run(f"sudo mke2fs -t ext4 -J size=40000 -E lazy_itable_init=0,lazy_journal_init=0 -F {TAU_DEVICE}")
    elif fs_type == "zfs":
        print(f"[+] Formatting {TAU_DEVICE} to ZFS")
        run(f"sudo zpool create zfspool {TAU_DEVICE}")
    elif fs_type == "zfs8k":
        print(f"[+] Formatting {TAU_DEVICE} to ZFS with 8K block size")
        run(f"sudo zpool create zfs8kpool {TAU_DEVICE}")
        run(f"sudo zfs set recordsize=8K zfs8kpool")
    else:
        raise ValueError(f"Unsupported filesystem type: {fs_type}")

def clear_filesystem(fs_type):
    if fs_type == "zfs":
        run(f"sudo zpool export zfspool")
        time.sleep(2)
    if fs_type == "zfs8k":
        run(f"sudo zpool export zfs8kpool")
        time.sleep(2)
    run(f"sudo wipefs -a {TAU_DEVICE}")

def mount_device(fs_type):
    MOUNT_POINT.mkdir(parents=True, exist_ok=True)
    if fs_type == "ext4":
        run(f"sudo mount -t ext4 -o data=ordered {TAU_DEVICE} {MOUNT_POINT}")
    elif fs_type == "btrfs":
        run(f"sudo mount -t btrfs {TAU_DEVICE} {MOUNT_POINT}")
    elif fs_type == "f2fs":
        run(f"sudo mount -t f2fs {TAU_DEVICE} {MOUNT_POINT}")
    elif fs_type == "taujournal":
        run(f"sudo mount -t ext4 -o data=ordered {TAU_DEVICE} {MOUNT_POINT}")
    elif fs_type == "zfs":
        run(f"sudo zfs set mountpoint={MOUNT_POINT} zfspool")
    elif fs_type == "zfs8k":
        run(f"sudo zfs set mountpoint={MOUNT_POINT} zfs8kpool")
    else:
        raise ValueError(f"Unsupported filesystem type: {fs_type}")
    # Permissions setting after mounting
    run(f"sudo chown -R {PG_USER}:{PG_USER} {MOUNT_POINT}")
    PG_DATA.mkdir(parents=True, exist_ok=True)

def umount_device():
    run(f"sudo umount {MOUNT_POINT}")

def init_postgres(fpw: str):
    print(f"[+] Initializing PostgreSQL with full_page_writes={fpw}")
    run(f"{PG_INSTALL}/bin/initdb -D {PG_DATA} -U postgres")

    # 1. postgresql.conf 설정
    conf = PG_DATA / "postgresql.conf"
    conf_lines = conf.read_text().splitlines()
    new_conf = []
    for line in conf_lines:
        # if line.strip().startswith("#") or line.strip() == "":
        #     new_conf.append(line)
        if "full_page_writes" in line:
            new_conf.append(f"full_page_writes = {fpw}")
        # elif "shared_buffers" in line:
        #     new_conf.append("shared_buffers = '4GB'")
        # elif "max_wal_size" in line:
        #     new_conf.append("max_wal_size = '2GB'")
        # elif "max_connections" in line:
        #     new_conf.append("max_connections = 200")
        else:
            new_conf.append(line)
    conf.write_text("\n".join(new_conf))

def start_postgres(log_file):
    run(f"{PG_INSTALL}/bin/pg_ctl -D {PG_DATA} -l {log_file} start")
    time.sleep(2)

def stop_postgres():
    run(f"{PG_INSTALL}/bin/pg_ctl -D {PG_DATA} stop -m fast")
    time.sleep(1)

def render_tcl_template(template_path, output_path, replacements):
    content = Path(template_path).read_text()
    for key, value in replacements.items():
        content = content.replace(f"__{key}__", str(value))
    Path(output_path).write_text(content)

def iostat_start(dev_path: str, out_path: Path) -> subprocess.Popen:
    dev_name = os.path.basename(dev_path)  # "nvme0n1"
    print(f"[+] Starting iostat for {dev_name}, logging to {out_path}")
    with open(out_path, "w") as f:
        proc = subprocess.Popen(
            ["iostat", "-dmx", "1", dev_name],
            stdout=f,
            stderr=subprocess.DEVNULL
        )
    return proc

def load_hammerdb(build_tcl_path, result_dir):
    iostat_log = result_dir / "load_iostat.log"
    iostat_proc = iostat_start(TAU_DEVICE, iostat_log)
    try:
        run(f"./hammerdbcli auto {build_tcl_path.name} > {result_dir}/hmdb_load.log")
    finally:
        iostat_proc.terminate()
        iostat_proc.wait()
        print(f"[+] iostat logging complete.")

def run_hammerdb_interactive(vu, run_tcl_path, result_dir):
    run_log = result_dir / f"hmdb_run_vu{vu}.log"
    iostat_log = result_dir / f"run_vu{vu}_iostat.log"

    iostat_proc = iostat_start(TAU_DEVICE, iostat_log)

    child = pexpect.spawn("./hammerdbcli")
    child.logfile = run_log.open("wb")

    child.expect("hammerdb>")
    child.sendline(f"source {run_tcl_path.name}")

    finish_count = 0
    while finish_count < vu:
        line = child.readline().decode("utf-8", errors="ignore")
        if "FINISHED SUCCESS" in line:
            finish_count += 1

    print(f"[✓] All {vu} VUs finished, quitting...")
    child.sendline("quit")
    child.close()

    iostat_proc.terminate()
    iostat_proc.wait()



def run_hammerdb(vu, run_tcl_path, result_dir):
    if MODE == "IOVOLUME":
        run_hammerdb_interactive(vu, run_tcl_path, result_dir)
        return

    run(f"./hammerdbcli auto {run_tcl_path.name} > {result_dir}/hmdb_run_vu{vu}.log")
    # iostat_log = result_dir / f"run_vu{vu}_iostat.log"
    # iostat_proc = iostat_start(TAU_DEVICE, iostat_log)
    # try:
    #     run(f"./hammerdbcli auto {run_tcl_path.name} > {result_dir}/hmdb_run_vu{vu}.log")
    # finally:
    #     iostat_proc.terminate()
    #     iostat_proc.wait()
    #     print(f"[+] iostat logging complete.")

def setup_pg_users_and_db():
    run(f"{PG_INSTALL}/bin/psql -p {PG_PORT} -h localhost -U postgres -c \"CREATE USER {PG_APP_USER} WITH SUPERUSER PASSWORD '{PG_APP_PASS}';\"")
    run(f"{PG_INSTALL}/bin/createdb -p {PG_PORT} -h localhost -U postgres {PG_DB}")

def save_postgres_config(output_path: Path, pg_user="postgres", pg_port=5432, pg_db="tpccdb"):
    print(f"[+] Saving PostgreSQL config to: {output_path}")
    key_params = [
        "shared_buffers", "max_connections", "max_wal_size", "min_wal_size",
        "full_page_writes", "checkpoint_timeout", "checkpoint_completion_target",
        "wal_compression", "synchronous_commit", "fsync", "wal_writer_delay"
    ]
    with output_path.open("w") as f:
        f.write("\n# Key Parameters\n")
        for param in key_params:
            try:
                result = subprocess.run(
                    [f"{PG_INSTALL}/bin/psql", "-U", pg_user, "-p", str(pg_port), "-d", pg_db,
                    "-tAc", f"SHOW {param};"],
                    check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
                )
                value = result.stdout.strip()
                f.write(f"{param} = {value if value else '[EMPTY]'}\n")
            except subprocess.CalledProcessError as e:
                f.write(f"{param} = [ERROR: {e.stderr.strip()}]\n")

        try:
            result = subprocess.run(
                [f"{PG_INSTALL}/bin/psql", "-U", pg_user, "-p", str(pg_port), "-d", pg_db,
                "-tAc", "SELECT pg_size_pretty(pg_database_size(current_database()));"],
                check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
            )
            size = result.stdout.strip()
            f.write(f"\ndatabase_size = {size}\n")
        except subprocess.CalledProcessError as e:
            f.write(f"\ndatabase_size = [ERROR: {e.stderr.strip()}]\n")


def backup_pgdata():
    print(f"[+] Backing up PGDATA to {PG_BACKUP_DIR}")
    if PG_BACKUP_DIR.exists():
        shutil.rmtree(PG_BACKUP_DIR)
    shutil.copytree(PG_DATA, PG_BACKUP_DIR, symlinks=True)

def restore_pgdata():
    print(f"[+] Restoring PGDATA from {PG_BACKUP_DIR}")
    if PG_DATA.exists():
        shutil.rmtree(PG_DATA)
    shutil.copytree(PG_BACKUP_DIR, PG_DATA, symlinks=True)


def main():
    for fpw in FULL_PAGE_WRITES:
        for fs_type in FS_GROUPS[fpw]:
            print(f"=== Making file system: {fs_type} ===")
            setup_filesystem(fs_type)
            for wh in WAREHOUSE_LIST:
                for proc in STOREDPROCS:
                    label = f"{fs_type}_fpw_{fpw}_wh{wh}_proc{int(proc)}"
                    result_dir = RESULTS / f"tpcc_{label}"
                    result_dir.mkdir(parents=True, exist_ok=True)

                    print(f"=== Preparing environment: {label} ===")
                    mount_device(fs_type)
                    init_postgres(fpw)
                    start_postgres(result_dir / "postgres_build.log")
                    setup_pg_users_and_db()

                    replacements = {
                        "VU": min(32, wh),  # Default VU for build
                        "WAREHOUSE": wh,
                        "STOREDPROCS": str(proc).lower(),
                        "ITERATIONS": TOTAL_ITERATION,
                        "DURATION": DURATION,
                        "RAMPUP": RAMPUP,
                    }

                    build_tcl = HAMMERDB / f"build_{label}.tcl"
                    render_tcl_template(TCL_TEMPLATE_BUILD, build_tcl, replacements)

                    os.chdir(HAMMERDB)
                    load_hammerdb(build_tcl, result_dir)
                    stop_postgres()
                    backup_pgdata()
                    umount_device()
                    shutil.move(str(build_tcl), result_dir / build_tcl.name)

                    for vu in VU_LIST:
                        vu_label = label+f"_vu{vu}"
                        mount_device(fs_type)
                        if PG_DATA.exists():
                            run(f"rm -rf {PG_DATA}/*")
                        restore_pgdata()

                        # Remount file system to clear cache states
                        umount_device()
                        mount_device(fs_type)

                        start_postgres(result_dir / f"postgres_run_vu{vu}.log")

                        run_tcl = HAMMERDB / f"run_{vu_label}.tcl"

                        replacements["VU"] = vu
                        # if MODE == "IOVOLUME":
                        #     replacements["ITERATIONS"] = max(10000, TOTAL_ITERATION / vu)
                        render_tcl_template(TCL_TEMPLATE_RUN, run_tcl, replacements)
                        run_hammerdb(vu, run_tcl, result_dir)
                        save_postgres_config(result_dir / "postgres_config.txt", "postgres", PG_PORT, PG_DB)
                        
                        shutil.move(str(run_tcl), result_dir / run_tcl.name)
                        stop_postgres()
                        umount_device()

                        print(f"=== Done: {label} ===\n")
            clear_filesystem(fs_type)

if __name__ == "__main__":
    main()
