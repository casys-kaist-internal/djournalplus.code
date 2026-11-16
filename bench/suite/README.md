# bench/suite: libra08's fast correctness test

The user decided on 2026-11-16 (relayed by tau-ops) that every change to tau runs a fast test of
about 6 hours. libra08 runs the VM correctness side and libra09 runs the performance side, in
parallel.

- Versions so far:
  - **beta**: every τ measurement up to 11-15.
  - **v1.0**: kernel new_main cc3d37bc (code 157b5750).
- `fast_correct.sh` runs the items below against a pinned kernel and writes one verdict.
- No item reboots the host, installs a kernel, rebinds 86:00.0 or writes a host device.

```sh
VERSION=v1.0 \
KDIR=/mnt/tau_backup/torner/kernels/tau-403 KMD5=45d5798546af47b7af84b80bac10d015 \
KDIR_LOCKDEP=/mnt/tau_backup/torner/kernels/tau-403-lockdep KMD5_LOCKDEP=<md5 from its PINNED> \
DRY=1 bash bench/suite/fast_correct.sh          # plan only: checks the kernels, starts no VM
# the same without DRY=1 runs it; LANES=serial, ITEMS="FC4 FC6", EXPECT=<file> as needed
```

## Items

| item | what | lane | time | owner |
|---|---|---|---:|---|
| FC1 | tautest, the #403 set: split, revoke, freetags, epoch free-*, trunc-reuse, trunc-race, crash, torn, stress | P | ~90 min | develop |
| FC2 | tautest, the lockdep set (`KDIR_LOCKDEP`) | P | ~30 min | develop |
| FC7 | DB counters: PostgreSQL and MySQL, 120 s × τ-EXT4 and τ-XFS; atoz_twotx, act_flush, act_dirty must be 0 | P | ~20 min | develop |
| FC3 | CrashMonkey seq-1 | F | ~12 min | develop |
| FC4 | Torner: the §6.2 table's main cells (7 workloads = 8 rows, quiet and busy) on τ-EXT4 and τ-XFS at a fifth of the state budget, plus the record_fua_only-fds control, which must fail | F | ~70 min | root |
| FC5 | Kill test (`tools/killtest db`): PostgreSQL and MySQL × τ-EXT4 and τ-XFS × 5 random QEMU kills; records the mount (τ replay) and DB recovery time | F | ~75 min, plus ~25 min per golden image still to make | root |
| FC6 | R3: a 1 GiB truncate and unlink at res1g on τ-EXT4 and τ-XFS; the truncate must not write home during the call | F | ~3 min | root |

- **Lane P** uses the PM1735 (86:00.0 through vfio) in one tautest VM at a time. Each of its items takes `~/soak-268/vm.lock` itself.
  - The VM has 32 vCPUs (VM_NUMA=1: 2 sockets × 16) and 16 GiB of 1 GiB pages per node, so it takes all 32 host CPUs by itself.
- **Lane F** uses VM disks that are files on the PM1753. FC4 and FC6 use the 1 GiB pool and FC5 does not.
- `LANES=serial` (the default) runs lane P and then lane F, about 4 h 50 min (once the FC5 golden images exist).
- `LANES=parallel` runs the two lanes side by side, about 2.5 h.
  - It overcommits the CPUs.
  - Starved vCPUs print soft lockups and hung tasks, and the log check counts those as faults.

## The item contract (`fc/fcN_<name>.sh`; `fc/lib.sh` has helpers)

`fast_correct.sh` passes these environment variables:

| variable | meaning |
|---|---|
| `FC_OUT` | the item's directory, already created |
| `FC_KDIR` | the probe kernel, pinned |
| `FC_KDIR_LOCKDEP` | the lockdep kernel, pinned |
| `FC_VERSION` | the version name |
| `FC_ROOT` | the umbrella checkout |
| `FC_DRY` | `1`: write `plan.txt` (the commands and an `ESTIMATE_MIN <n>` line) and start nothing |

The item writes these files into `FC_OUT`:

| file | content |
|---|---|
| `cases.tsv` | `<case-id>\t<PASS\|FAIL\|SKIP>\t<detail>`, one line per case. Case ids stay the same from run to run, because the expected lists name them. |
| `logs.list` | The kernel logs to scan: consoles, `journalctl -k`, dmesg. Kernel lines only, no user-space logs. |
| `allow.txt` | Optional. `<ERE>\t<why>` for fault lines the item causes on purpose. |
| `summary.md` | Optional. A short table for the report. |

It exits 0 when it ran to the end, whatever its cases say, and 2 when the harness itself failed.

**Initrd and modules.** tau-ops raised this on 11-16. A default such as `/boot/initrd.img-6.8.0tjournal+` pairs any build's bzImage with whatever initrd carries that name, and does so silently. In the R3 and Torner VMs, the initrd's `cryptd` and `padlock_aes` modules came from another build:
- MODVERSIONS refused them ("disagrees about version of symbol").
- The kernel was still tainted E.

So `fast_correct.sh` passes the initrd explicitly:
- `KINITRD` and `KINITRD_LOCKDEP` become `FC_INITRD` and `FC_INITRD_LOCKDEP`. The default is `none`, because the test kernels have the VMs' root drivers built in.
- `MANIFEST` records the initrd and its md5.

Each item then writes these checks after every boot:
- `<prefix>/boot/kernel`: `uname -v` is the pinned bzImage's.
- `<prefix>/boot/modules`: every loaded module is one the item allows, and its srcversion matches the pinned tree's `.ko`.
- `<prefix>/end/taint-W` where it can: no WARN taint (bit 512).

`fc/lib.sh` has `fc_guest_check` and `fc_guest_taint_w` for VMs reachable over ssh. FC4 reads Torner's `table.log` and `setup.log` instead, because `table.sh` owns those VMs. FC5 compares each killtest trial's recorded `uname -v`; killtest boots its own rootfs with no initrd.

## Verdict

Every kernel directory must hold `PINNED` and a bzImage whose md5 matches the one given. If one does not, nothing runs (exit 3).

The run passes when all of these hold:
- every item finished (rc 0) and wrote cases;
- no case is FAIL or XPASS;
- every log an item lists exists;
- no log has a fault line that its `allow.txt` does not cover.

Fault lines are BUG, WARNING, Oops, Call Trace, panic, the lockdep reports, suspicious RCU usage, UBSAN/KASAN, soft lockups, hung tasks and RCU stalls (`FAULT_RE`).

`expect/<VERSION>.txt` lists the cases that must fail on that version (`<item> <case glob> <reason>`):
- A listed case that fails is XFAIL and does not count against the run.
- A listed case that passes is XPASS and fails the run, because the test no longer tells the versions apart.

For **beta** the run uses the #401 pins (fccc4abd), whose τ code is #400's. These cases fail there:
- the twotx cases (bug.md #80, fixed in #403);
- FC6's truncate home write (B1, #403).

## Judging a finished run again (`REEVAL`)

`REEVAL=<raw run dir> bash bench/suite/fast_correct.sh` judges a run again under the current rules. It starts nothing and changes none of the run's files.
- It reads each item's `cases.tsv`, `logs.list` and `allow.txt` where the run left them.
- Next to the originals it writes `FCn/{faults.reeval.txt,verdicts.reeval.tsv,VERDICT.reeval}`, `MANIFEST.reeval` and `REPORT.reeval.md`. These go into the raw dir and into the umbrella report dir.
  - `MANIFEST.reeval` holds the run's `MANIFEST`, then the new harness md5s, the expected list and `FAULT_RE`.
  - With `REEVAL_OUT=<dir>` everything goes to `<dir>` instead.
- `VERSION`, `ITEMS`, `LANES` and the expected list come from the run's `MANIFEST` unless given.

It was first used on 11-16, on the beta run. That run's FC2 had counted 240 lockdep boot banner lines ("... MAX_LOCKDEP_KEYS: 8192") as faults. `FAULT_RE` now matches only lockdep's exhaustion reports ("MAX_LOCKDEP_… too low"), so beta and v1.0 are judged by the same rules.

## Results

| where | what |
|---|---|
| `/mnt/tau_backup/fast/<VERSION>/<UTC>/FCn/` | Raw output: `run.log`, the item's own files, `verdicts.tsv`, `faults.txt`, `VERDICT`. |
| `bench/results/libra08/versions/<VERSION>/fast/<UTC>/` | `MANIFEST` (kernels with md5 and build, umbrella commit and uncommitted files, host state, suite md5s), `REPORT.md`, and each item's `cases.tsv`, `verdicts.tsv`, `faults.txt`, `summary.md`. |
