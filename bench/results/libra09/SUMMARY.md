# libra09: benchmark summary

Made by `bench/scripts/export_results.py` from the results in
`bench/workspace/results/libra09/sysbench/<db>/<run>/` (outside git, on libra09);
notes on the runs in `README.md`.

Machine (`env.txt` of postgres/20261010_023220_fullfill; full snapshot in `bench/machines/libra09.txt`):

    host:                    libra09
    product:                 Supermicro SYS-1029U-TR4
    kernel:                  6.8.0-base+
    model:                   Intel(R) Xeon(R) Gold 5218 CPU @ 2.30GHz
    topology:                2 sockets x 16 cores x 1 threads
    turbo:                   on
    cstates:                 intel_idle: POLL=on C1=on C1E=off C6=off
    memtotal:                187.6 GiB, usable 61.6 GiB (minus huge pages)
    dimms:                   12 x 16 GB @ 2666 MT/s
    test_device:             nvme0n1
    nvme0:                   SAMSUNG MZPLJ3T2HBJR-00007, fw EPK9GB5Q, numa 1, pcie Speed 8GT/s (downgraded) Width x8, 3200 GB, cache write through
    postgres:                postgres (PostgreSQL) 17.5
    mysql:                   8.4.5 for Linux on x86_64 (Source distribution)
    zfs:                     2.2.2-0ubuntu9.5 / userland 2.2.2-0ubuntu9.5 / arc_max 34359738368

Throughput in transactions/s (mean of the runs at a point); protection on = PostgreSQL
full_page_writes / InnoDB doublewrite; KB/trx = device writes per transaction at the most threads.

## sysbench mysql

| workload | fs | protection | 1 thr | 8 thr | 16 thr | 32 thr | 64 thr | KB/trx | run |
|---|---|---|---:|---:|---:|---:|---:|---:|---|
| insert | btrfs | off | 501 | 368 | 640 | 589 | 713 | 38.9 | `20261001_171503` |
| insert | ext4 | off | 9017 | 62739 | 112884 | 156655 | 206170 | 2.0 | `20260929_063532` |
| insert | ext4 | on | 9115 | 60073 | 106458 | 149758 | 196535 | 3.1 | `20260929_063532` |
| insert | ext4-dj40 | off | 4764 | 32427 | 54958 | 72412 | 99351 | 5.1 | `20260929_231455` |
| insert | xfs | off | 8943 | 62003 | 111532 | 154378 | 202756 | 2.0 | `20260929_063532` |
| insert | xfs | on | 8794 | 59705 | 108316 | 148537 | 192976 | 3.1 | `20260929_063532` |
| insert | zfs-16k | off | 4570 | 27329 | 43965 | 66494 | 94277 | 4.9 | `20261002_031438` |
| update_index | btrfs | off | 195 | 495 | 1870 | 2935 | 3747 | 48.2 | `20261001_171503` |
| update_index | ext4 | off | 6733 | 46670 | 77613 | 107487 | 137360 | 8.6 | `20260929_063532` |
| update_index | ext4 | on | 5884 | 35265 | 54706 | 72270 | 96058 | 15.9 | `20260929_063532` |
| update_index | ext4-dj40 | off | 2893 | 14648 | 20439 | 27257 | 39142 | 22.9 | `20260929_231455` |
| update_index | xfs | off | 6813 | 43988 | 73408 | 99915 | 123744 | 8.6 | `20260929_063532` |
| update_index | xfs | on | 5917 | 34966 | 55920 | 72192 | 94792 | 15.8 | `20260929_063532` |
| update_index | zfs-16k | off | 2352 | 12304 | 18328 | 23683 | 31674 | 29.7 | `20261002_031438` |
| update_non_index | btrfs | off | 1470 | 1880 | 1697 | 2213 | 3145 | 25.3 | `20261001_171503` |
| update_non_index | ext4 | off | 8310 | 59347 | 104429 | 150744 | 198132 | 3.3 | `20260929_063532` |
| update_non_index | ext4 | on | 8355 | 55840 | 95946 | 135783 | 175725 | 5.7 | `20260929_063532` |
| update_non_index | ext4-dj40 | off | 4646 | 28380 | 43407 | 59293 | 79813 | 7.6 | `20260929_231455` |
| update_non_index | xfs | off | 8531 | 60290 | 105283 | 148758 | 193381 | 3.3 | `20260929_063532` |
| update_non_index | xfs | on | 8181 | 55118 | 94478 | 132489 | 172420 | 5.7 | `20260929_063532` |
| update_non_index | zfs-16k | off | 4235 | 25765 | 37935 | 51486 | 74452 | 9.1 | `20261002_031438` |
| write_only | btrfs | off | 239 | 907 | 1216 | 1721 | 2080 | 68.9 | `20261001_171503` |
| write_only | btrfs-uniform | off |  |  |  |  | 811 | 226.4 | `20261002_072816_uniform` |
| write_only | ext4 | off | 2362 | 16824 | 28294 | 40319 | 47902 | 25.5 | `20261009_081451` |
| write_only | ext4 | on | 2089 | 13473 | 20737 | 27490 | 35030 | 47.2 | `20261009_081451` |
| write_only | ext4-dj40 | off | 1671 | 8547 | 12679 | 16829 | 21021 | 43.6 | `20261009_081451` |
| write_only | ext4-dj40-fullfill | off | 1631 | 8364 | 12508 | 16495 | 20765 | 43.5 | `20261009_212738_fullfill` |
| write_only | ext4-dj40-uniform | off |  |  |  |  | 8590 | 123.9 | `20261001_044332_uniform` |
| write_only | ext4-fullfill | off | 2388 | 16662 | 27414 | 38897 | 45597 | 25.7 | `20261009_212738_fullfill` |
| write_only | ext4-fullfill | on | 2047 | 13091 | 19840 | 26331 | 33192 | 47.5 | `20261009_212738_fullfill` |
| write_only | ext4-uniform | off |  |  |  |  | 21539 | 72.8 | `20261001_032505_uniform` |
| write_only | ext4-uniform | on |  |  |  |  | 11935 | 139.1 | `20261001_032505_uniform` |
| write_only | xfs | off | 2293 | 15660 | 26190 | 36156 | 44017 | 24.7 | `20261009_081451` |
| write_only | xfs | on | 2089 | 13117 | 20314 | 27547 | 34838 | 45.7 | `20261009_081451` |
| write_only | zfs-16k | off | 1520 | 9268 | 15983 | 22813 | 27355 | 53.3 | `20261009_081451` |
| write_only | zfs-16k-fullfill | off | 1504 | 9250 | 15844 | 22614 | 25721 | 53.8 | `20261009_212738_fullfill` |
| write_only | zfs-16k-uniform | off |  |  |  |  | 5287 | 297.7 | `20261002_083534_uniform` |

## sysbench postgres

| workload | fs | protection | 1 thr | 8 thr | 16 thr | 32 thr | 64 thr | KB/trx | run |
|---|---|---|---:|---:|---:|---:|---:|---:|---|
| insert | btrfs | off | 2515 | 11702 | 22914 | 9667 | 3153 | 6.7 | `20261001_123918` |
| insert | ext4 | off | 9975 | 59245 | 99942 | 150066 | 178265 | 1.8 | `20260930_054131` |
| insert | ext4 | on | 9768 | 55740 | 87207 | 117969 | 135137 | 5.8 | `20260930_054131` |
| insert | ext4-dj40 | off | 6188 | 35255 | 56189 | 83113 | 113070 | 3.8 | `20260930_223555` |
| insert | xfs | off | 10020 | 59605 | 100923 | 148554 | 177149 | 1.8 | `20260930_054131` |
| insert | xfs | on | 9754 | 55966 | 86707 | 116999 | 134787 | 5.8 | `20260930_054131` |
| insert | zfs-8k | off | 6461 | 37618 | 62794 | 86831 | 123091 | 2.2 | `20261001_212126` |
| update_index | btrfs | off | 1059 | 8478 | 1308 | 1413 | 5638 | 7.5 | `20261001_123918` |
| update_index | ext4 | off | 8897 | 52079 | 90127 | 134428 | 160241 | 4.5 | `20260930_054131` |
| update_index | ext4 | on | 7851 | 36607 | 52850 | 63712 | 66162 | 19.4 | `20260930_054131` |
| update_index | ext4-dj40 | off | 5654 | 28756 | 44432 | 53360 | 74660 | 9.7 | `20260930_223555` |
| update_index | xfs | off | 8992 | 51383 | 87264 | 127051 | 150032 | 4.4 | `20260930_054131` |
| update_index | xfs | on | 8095 | 36718 | 53204 | 63822 | 68534 | 19.4 | `20260930_054131` |
| update_index | zfs-8k | off | 5776 | 28984 | 43605 | 59122 | 73237 | 18.8 | `20261001_212126` |
| update_non_index | btrfs | off | 2504 | 10232 | 7261 | 32699 | 35764 | 7.9 | `20261001_123918` |
| update_non_index | ext4 | off | 10729 | 61013 | 108924 | 157170 | 199143 | 2.3 | `20260930_054131` |
| update_non_index | ext4 | on | 9884 | 51621 | 83649 | 118215 | 142245 | 5.5 | `20260930_054131` |
| update_non_index | ext4-dj40 | off | 6281 | 33707 | 55091 | 73010 | 103746 | 4.7 | `20260930_223555` |
| update_non_index | xfs | off | 10903 | 60992 | 108136 | 155324 | 193734 | 2.3 | `20260930_054131` |
| update_non_index | xfs | on | 9990 | 52204 | 83877 | 118367 | 143755 | 5.6 | `20260930_054131` |
| update_non_index | zfs-8k | off | 6312 | 34720 | 55294 | 76805 | 105516 | 8.4 | `20261001_212126` |
| write_only | btrfs | off | 1469 | 1202 | 6218 | 4732 | 12372 | 21.9 | `20261001_123918` |
| write_only | btrfs-uniform | off |  |  |  |  | 2370 | 57.2 | `20261002_064708_uniform` |
| write_only | ext4 | off | 3004 | 20387 | 35092 | 50925 | 62207 | 17.3 | `20261009_151712` |
| write_only | ext4 | on | 2661 | 15770 | 23610 | 28810 | 29240 | 50.4 | `20261009_151712` |
| write_only | ext4-dj40 | off | 2336 | 12721 | 19095 | 24077 | 27902 | 34.8 | `20261009_151712` |
| write_only | ext4-dj40-fullfill | off | 2268 | 12724 | 19110 | 23369 | 27382 | 35.0 | `20261010_023220_fullfill` |
| write_only | ext4-dj40-uniform | off |  |  |  |  | 13312 | 77.1 | `20261001_064502_uniform` |
| write_only | ext4-fullfill | off | 2977 | 20278 | 35029 | 49947 | 61332 | 17.4 | `20261010_023220_fullfill` |
| write_only | ext4-fullfill | on | 2724 | 15715 | 23145 | 28174 | 28737 | 50.2 | `20261010_023220_fullfill` |
| write_only | ext4-uniform | off |  |  |  |  | 37738 | 44.5 | `20261001_052459_uniform` |
| write_only | ext4-uniform | on |  |  |  |  | 14506 | 99.8 | `20261001_052459_uniform` |
| write_only | xfs | off | 2981 | 20070 | 33662 | 48098 | 58655 | 17.3 | `20261009_151712` |
| write_only | xfs | on | 2754 | 15918 | 24186 | 29834 | 29858 | 51.5 | `20261009_151712` |
| write_only | zfs-8k | off | 2210 | 12508 | 18593 | 23539 | 24160 | 70.8 | `20261009_151712` |
| write_only | zfs-8k-fullfill | off | 2205 | 12484 | 18577 | 23463 | 23939 | 60.2 | `20261010_023220_fullfill` |
| write_only | zfs-8k-uniform | off |  |  |  |  | 8958 | 206.0 | `20261002_080556_uniform` |
