# libra09: benchmark summary

Made by `bench/scripts/export_results.py` from the results in
`bench/workspace/results/libra09/{sysbench,benchbase}/<db>/<run>/` (outside git, on libra09);
notes on the runs in `README.md`.

Machine (`env.txt` of mysql/20261019_061714; full snapshot in `bench/machines/libra09.txt`):

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

The τ rows (ext4-tau, xfs-tau and their variants) ran on the τ kernel (6.8.0tjournal+).

The ssd990 rows ran on a Samsung 990 PRO 4TB (no PLP, volatile write cache) in its steady state (written once over its capacity, no trim before the restore), the baselines on the base kernel; their 64-thread points are one 40-min run (TPC-C: 64 terminals for 40 min once). The -kcheck rows are baselines run on the τ kernel as a kernel cross-check. The drive settled into a slower steady state between 2026-10-26 and 10-27, its over-provisioning filled up (EXT4 Raw 64 threads: PG 8,872 -> 7,600 TPS, MySQL 8,060 -> ~5,000, stable since): ssd990 runs up to 2026-10-26 are from the earlier, transitional state and compare only among themselves. The steady-state set is the 64-thread/terminal points from 2026-10-29 on; MySQL runs from 2026-10-29 on pre-write the spare redo files after each start (mysql/api.sh prewrite_spare_redo).

The -empty rows (EVAL_PLAN DB3 insert-from-empty) insert into the empty tables of the t16_r0 images: a 60-s warm-up, then three 5-min runs at 64 threads on the growing database, all three averaged here. MySQL EXT4 Raw/App step up ~30% about 5.5 min after the server start, inside the first run, so the paper table (paper/evaluation/db3_insert_empty in the results) uses runs 2-3.

Throughput in transactions/s (mean of the runs at a point); protection on = PostgreSQL
full_page_writes / InnoDB doublewrite; KB/trx = device writes per transaction at the most threads.

## sysbench mysql

| workload | fs | protection | 1 thr | 8 thr | 16 thr | 32 thr | 64 thr | KB/trx | run |
|---|---|---|---:|---:|---:|---:|---:|---:|---|
| insert | btrfs | off | 281 | 389 | 1089 | 582 | 1260 | 32.1 | `20261019_061714` |
| insert | ext4 | off | 9061 | 61540 | 111453 | 154989 | 203505 | 2.0 | `20261017_093244` |
| insert | ext4 | on | 8854 | 60661 | 106814 | 147811 | 193581 | 3.2 | `20261017_093244` |
| insert | ext4-dj20-empty | off |  |  |  |  | 118484 | 2.9 | `20261031_003824_empty` |
| insert | ext4-dj40 | off | 4877 | 31093 | 53438 | 70840 | 98128 | 5.1 | `20261017_093244` |
| insert | ext4-empty | off |  |  |  |  | 193372 | 1.5 | `20261031_003824_empty` |
| insert | ext4-empty | on |  |  |  |  | 189047 | 1.8 | `20261031_003824_empty` |
| insert | ext4-tau | off | 8925 | 61467 | 110611 | 151631 | 196329 | 2.9 | `20261020_204243` |
| insert | xfs | off | 8926 | 61679 | 111056 | 152929 | 201284 | 2.0 | `20261017_093244` |
| insert | xfs | on | 8811 | 59585 | 107164 | 147525 | 193656 | 3.1 | `20261017_093244` |
| insert | xfs-tau | off | 8844 | 62443 | 111451 | 153807 | 203541 | 2.3 | `20261020_204243` |
| insert | zfs-16k | off | 5010 | 33622 | 56897 | 82273 | 119797 | 3.3 | `20261017_093244` |
| update_index | btrfs | off | 52 | 100 | 233 | 1743 | 1736 | 53.3 | `20261019_061714` |
| update_index | ext4 | off | 6724 | 46728 | 79781 | 111359 | 140956 | 8.6 | `20261016_044321` |
| update_index | ext4 | on | 6021 | 38175 | 60843 | 81268 | 105688 | 15.7 | `20261016_044321` |
| update_index | ext4-dj40 | off | 2854 | 14510 | 21183 | 28435 | 41311 | 22.3 | `20261016_044321` |
| update_index | ext4-tau | off | 6681 | 44684 | 71291 | 97482 | 122596 | 12.5 | `20261020_204243` |
| update_index | xfs | off | 6593 | 43961 | 74066 | 101497 | 126948 | 8.5 | `20261016_044321` |
| update_index | xfs | on | 6093 | 37173 | 58586 | 78497 | 102177 | 15.6 | `20261016_044321` |
| update_index | xfs-tau | off | 6697 | 45080 | 70552 | 94546 | 119393 | 12.0 | `20261020_204243` |
| update_index | zfs-16k | off | 3084 | 20741 | 34412 | 51718 | 66241 | 19.7 | `20261016_044321` |
| update_non_index | btrfs | off | 874 | 266 | 298 | 452 | 3692 | 21.1 | `20261019_061714` |
| update_non_index | ext4 | off | 8267 | 59301 | 105366 | 153531 | 202162 | 3.3 | `20261016_165915` |
| update_non_index | ext4 | on | 8196 | 56330 | 98325 | 140359 | 182513 | 5.7 | `20261016_165915` |
| update_non_index | ext4-dj40 | off | 4628 | 27768 | 42608 | 59091 | 78962 | 7.6 | `20261016_165915` |
| update_non_index | ext4-tau | off | 8367 | 58540 | 104094 | 147535 | 193026 | 4.3 | `20261020_204243` |
| update_non_index | xfs | off | 8006 | 58286 | 104689 | 149941 | 196352 | 3.3 | `20261016_165915` |
| update_non_index | xfs | on | 8083 | 55597 | 96076 | 136378 | 178734 | 5.7 | `20261016_165915` |
| update_non_index | xfs-tau | off | 8300 | 58498 | 104734 | 148564 | 193495 | 4.0 | `20261020_204243` |
| update_non_index | zfs-16k | off | 4415 | 29640 | 49807 | 73957 | 103133 | 6.9 | `20261016_165915` |
| write_only | btrfs | off | 109 | 710 | 1780 | 1454 | 1994 | 68.1 | `20261019_061714` |
| write_only | btrfs-uniform | off |  |  |  |  | 811 | 226.4 | `20261002_072816_uniform` |
| write_only | ext4 | off | 2362 | 16824 | 28294 | 40319 | 47902 | 25.5 | `20261009_081451` |
| write_only | ext4 | on | 2089 | 13473 | 20737 | 27490 | 35030 | 47.2 | `20261009_081451` |
| write_only | ext4-dj40 | off | 1671 | 8547 | 12679 | 16829 | 21021 | 43.6 | `20261009_081451` |
| write_only | ext4-dj40-fullfill | off | 1631 | 8364 | 12508 | 16495 | 20765 | 43.5 | `20261009_212738_fullfill` |
| write_only | ext4-dj40-ssd990 | off | 63 | 331 | 599 | 1063 | 1591 | 116.5 | `20261029_014905_ssd990`, `20261029_025829_ssd990` |
| write_only | ext4-dj40-uniform | off | 1109 | 5202 | 6921 | 8164 | 9264 | 124.4 | `20261017_202936_uniform` |
| write_only | ext4-fullfill | off | 2388 | 16662 | 27414 | 38897 | 45597 | 25.7 | `20261009_212738_fullfill` |
| write_only | ext4-fullfill | on | 2047 | 13091 | 19840 | 26331 | 33192 | 47.5 | `20261009_212738_fullfill` |
| write_only | ext4-odirect | off | 2624 | 18247 | 31069 | 44438 | 56572 | 10.7 | `20261030_171320_odirect` |
| write_only | ext4-odirect | on | 2498 | 16474 | 28416 | 40154 | 50418 | 18.4 | `20261030_092359_odirect` |
| write_only | ext4-ssd990 | off | 180 | 1125 | 2205 | 4176 | 5087 | 36.5 | `20261025_114503_ssd990`, `20261029_082315_ssd990` |
| write_only | ext4-ssd990 | on | 121 | 663 | 1254 | 1483 | 1048 | 51.5 | `20261028_232948_ssd990`, `20261029_003917_ssd990` |
| write_only | ext4-ssd990-kcheck | off |  |  |  |  | 7914 | 31.1 | `20261026_064604_ssd990-kcheck` |
| write_only | ext4-tau | off | 2343 | 15626 | 26191 | 36383 | 43164 | 36.2 | `20261020_204243` |
| write_only | ext4-tau-ssd990 | off | 162 | 964 | 1864 | 3483 | 6707 | 45.9 | `20261026_033248_ssd990`, `20261026_043637_ssd990` |
| write_only | ext4-tau-uniform | off | 1246 | 7638 | 11718 | 15930 | 17200 | 124.8 | `20261022_031357_uniform` |
| write_only | ext4-uniform | off | 1262 | 8509 | 14273 | 20446 | 22831 | 72.8 | `20261017_202936_uniform` |
| write_only | ext4-uniform | on | 1105 | 6568 | 9851 | 12495 | 13063 | 138.8 | `20261017_202936_uniform` |
| write_only | xfs | off | 2293 | 15660 | 26190 | 36156 | 44017 | 24.7 | `20261009_081451` |
| write_only | xfs | on | 2089 | 13117 | 20314 | 27547 | 34838 | 45.7 | `20261009_081451` |
| write_only | xfs-ssd990 | off | 172 | 1039 | 1838 | 3342 | 5833 | 26.9 | `20261029_040801_ssd990`, `20261029_061535_ssd990` |
| write_only | xfs-ssd990 | on | 114 | 647 | 1164 | 1426 | 1014 | 51.2 | `20261029_040801_ssd990`, `20261029_061535_ssd990` |
| write_only | xfs-tau | off | 2295 | 15735 | 24532 | 34136 | 40826 | 36.1 | `20261020_204243` |
| write_only | zfs-16k | off | 1520 | 9268 | 15983 | 22813 | 27355 | 53.3 | `20261009_081451` |
| write_only | zfs-16k-fullfill | off | 1504 | 9250 | 15844 | 22614 | 25721 | 53.8 | `20261009_212738_fullfill` |
| write_only | zfs-16k-ssd990 | off | 133 | 850 | 1281 | 1850 | 2625 | 84.3 | `20261027_024812_ssd990`, `20261027_034306_ssd990` |
| write_only | zfs-16k-uniform | off |  |  |  |  | 5287 | 297.7 | `20261002_083534_uniform` |

## sysbench postgres

| workload | fs | protection | 1 thr | 8 thr | 16 thr | 32 thr | 64 thr | KB/trx | run |
|---|---|---|---:|---:|---:|---:|---:|---:|---|
| delete | ext4 | off | 21913 | 156793 | 297810 | 441570 | 644243 | 0.9 | `20261016_231053` |
| delete | ext4 | on | 19125 | 130321 | 231612 | 351972 | 511228 | 1.8 | `20261016_231053` |
| delete | xfs | off | 22109 | 154036 | 291421 | 425810 |  | 1.3 | `20261016_231053` |
| delete | xfs | on | 19284 | 131826 | 233794 | 352536 | 504318 | 1.8 | `20261016_231053` |
| insert | btrfs | off | 2462 | 11646 | 22366 | 7488 | 13837 | 8.4 | `20261019_020217` |
| insert | ext4 | off | 9865 | 57584 | 98321 | 145735 | 175973 | 2.1 | `20261017_032251` |
| insert | ext4 | on | 9650 | 55136 | 85932 | 117871 | 135935 | 6.0 | `20261017_032251` |
| insert | ext4-dj20-empty | off |  |  |  |  | 118344 | 3.6 | `20261030_232156_empty` |
| insert | ext4-dj40 | off | 5688 | 33892 | 57480 | 79774 | 109975 | 4.7 | `20261017_032251` |
| insert | ext4-empty | off |  |  |  |  | 177772 | 1.7 | `20261030_232156_empty` |
| insert | ext4-empty | on |  |  |  |  | 176115 | 1.8 | `20261030_232156_empty` |
| insert | ext4-tau | off | 9821 | 58722 | 97749 | 139992 | 169359 | 3.0 | `20261020_122600` |
| insert | xfs | off | 9734 | 57416 | 97879 | 144065 | 175178 | 2.1 | `20261017_032251` |
| insert | xfs | on | 9610 | 54380 | 85029 | 116443 | 134687 | 5.9 | `20261017_032251` |
| insert | xfs-tau | off | 9789 | 58858 | 98799 | 141949 | 168696 | 3.2 | `20261020_122600` |
| insert | zfs-8k | off | 6394 | 37636 | 63201 | 89416 | 125073 | 2.6 | `20261017_032251` |
| update_index | btrfs | off | 863 | 648 | 649 | 1696 | 18816 | 11.5 | `20261019_020217` |
| update_index | ext4 | off | 8754 | 51104 | 89557 | 134158 | 161094 | 4.8 | `20261015_223600` |
| update_index | ext4 | on | 7855 | 36777 | 54496 | 66859 | 71734 | 19.7 | `20261015_223600` |
| update_index | ext4-dj40 | off | 5277 | 28043 | 43915 | 59575 | 72479 | 11.0 | `20261015_223600` |
| update_index | ext4-tau | off | 8919 | 49608 | 83045 | 117567 | 136845 | 8.4 | `20261020_122600` |
| update_index | xfs | off | 8633 | 50136 | 85844 | 126358 | 151743 | 4.8 | `20261015_223600` |
| update_index | xfs | on | 7820 | 37434 | 55136 | 68768 | 74702 | 19.9 | `20261015_223600` |
| update_index | xfs-tau | off | 9036 | 49142 | 82507 | 115523 | 133964 | 8.5 | `20261020_122600` |
| update_index | zfs-8k | off | 5349 | 29163 | 45842 | 61877 | 71120 | 21.0 | `20261015_223600` |
| update_non_index | btrfs | off | 956 | 5562 | 6181 | 5640 | 20116 | 11.2 | `20261019_020217` |
| update_non_index | ext4 | off | 10738 | 59494 | 107053 | 155125 | 200065 | 2.5 | `20261016_105303` |
| update_non_index | ext4 | on | 9900 | 50877 | 83262 | 117664 | 144326 | 5.7 | `20261016_105303` |
| update_non_index | ext4-dj40 | off | 6005 | 31646 | 53091 | 76324 | 101657 | 5.9 | `20261016_105303` |
| update_non_index | ext4-tau | off | 10544 | 58970 | 102395 | 145680 | 179973 | 4.2 | `20261020_122600` |
| update_non_index | xfs | off | 10503 | 58619 | 105711 | 152082 | 192640 | 2.5 | `20261016_105303` |
| update_non_index | xfs | on | 9977 | 51288 | 83196 | 118292 | 146653 | 5.8 | `20261016_105303` |
| update_non_index | xfs-tau | off | 10670 | 59092 | 104477 | 144322 | 178448 | 4.2 | `20261020_122600` |
| update_non_index | zfs-8k | off | 6377 | 34691 | 56742 | 79221 | 104712 | 10.1 | `20261016_105303` |
| write_only | btrfs | off | 954 | 778 | 4120 | 7965 | 5901 | 31.4 | `20261019_020217` |
| write_only | btrfs-uniform | off |  |  |  |  | 2370 | 57.2 | `20261002_064708_uniform` |
| write_only | ext4 | off | 3004 | 20387 | 35092 | 50925 | 62207 | 17.3 | `20261009_151712` |
| write_only | ext4 | on | 2661 | 15770 | 23610 | 28810 | 29240 | 50.4 | `20261009_151712` |
| write_only | ext4-dj40 | off | 2336 | 12721 | 19095 | 24077 | 27902 | 34.8 | `20261009_151712` |
| write_only | ext4-dj40-fullfill | off | 2268 | 12724 | 19110 | 23369 | 27382 | 35.0 | `20261010_023220_fullfill` |
| write_only | ext4-dj40-ssd990 | off | 85 | 349 | 688 | 1350 | 2643 | 34.1 | `20261026_170144_ssd990`, `20261026_180724_ssd990` |
| write_only | ext4-dj40-uniform | off | 1285 | 6151 | 9047 | 11432 | 12170 | 89.4 | `20261017_171541_uniform` |
| write_only | ext4-fullfill | off | 2977 | 20278 | 35029 | 49947 | 61332 | 17.4 | `20261010_023220_fullfill` |
| write_only | ext4-fullfill | on | 2724 | 15715 | 23145 | 28174 | 28737 | 50.2 | `20261010_023220_fullfill` |
| write_only | ext4-ssd990 | off | 304 | 1197 | 2357 | 4562 | 7519 | 12.3 | `20261025_073136_ssd990`, `20261030_053744_ssd990` |
| write_only | ext4-ssd990 | on | 291 | 1113 | 2195 | 3945 | 4198 | 46.9 | `20261025_073136_ssd990`, `20261030_022354_ssd990` |
| write_only | ext4-ssd990-kcheck | off |  |  |  |  | 8867 | 12.0 | `20261026_054259_ssd990-kcheck` |
| write_only | ext4-tau | off | 2946 | 19512 | 31269 | 42540 | 50690 | 32.3 | `20261020_122600` |
| write_only | ext4-tau-ssd990 | off | 288 | 1096 | 2135 | 4052 | 7504 | 22.9 | `20261026_012613_ssd990`, `20261026_022929_ssd990` |
| write_only | ext4-tau-uniform | off | 1506 | 9406 | 14405 | 20210 | 24386 | 89.8 | `20261022_021029_uniform` |
| write_only | ext4-uniform | off | 1531 | 10319 | 18003 | 27581 | 37352 | 47.8 | `20261017_171541_uniform` |
| write_only | ext4-uniform | on | 1364 | 7855 | 12131 | 14378 | 14761 | 104.6 | `20261017_171541_uniform` |
| write_only | ext4-walcomp | on | 2376 | 15249 | 24873 | 31646 | 32495 | 40.9 | `20261030_102802_walcomp` |
| write_only | xfs | off | 2981 | 20070 | 33662 | 48098 | 58655 | 17.3 | `20261009_151712` |
| write_only | xfs | on | 2754 | 15918 | 24186 | 29834 | 29858 | 51.5 | `20261009_151712` |
| write_only | xfs-ssd990 | off | 298 | 1151 | 2318 | 4276 | 7594 | 12.2 | `20261027_091459_ssd990`, `20261027_111517_ssd990` |
| write_only | xfs-ssd990 | on | 287 | 1077 | 1977 | 3272 | 4669 | 47.5 | `20261027_091459_ssd990`, `20261027_111517_ssd990` |
| write_only | xfs-tau | off | 3044 | 19798 | 30987 | 42185 | 49313 | 32.4 | `20261020_122600` |
| write_only | zfs-8k | off | 2210 | 12508 | 18593 | 23539 | 24160 | 70.8 | `20261009_151712` |
| write_only | zfs-8k-fullfill | off | 2205 | 12484 | 18577 | 23463 | 23939 | 60.2 | `20261010_023220_fullfill` |
| write_only | zfs-8k-ssd990 | off | 276 | 1114 | 2071 | 3727 | 5508 | 38.4 | `20261027_010132_ssd990`, `20261027_015443_ssd990` |
| write_only | zfs-8k-uniform | off |  |  |  |  | 8958 | 206.0 | `20261002_080556_uniform` |

TPC-C (BenchBase, warehouses chosen at random per transaction, no think time): tpmC = new orders per minute counted by the database over each 5-min measurement (mean of the runs at a point); p99 and device KB per new order (KB/NO) at the most terminals.

## TPC-C mysql

| fs | protection | WH | 1 term | 8 term | 16 term | 32 term | 64 term | p99 ms | KB/NO | run |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| btrfs | off | 1100 | 1594 | 3938 | 2983 | 3274 | 14184 | 2786.7 | 680 | `20261019_010023` |
| ext4 | off | 1100 | 7313 | 53699 | 98322 | 145306 | 160446 | 40.8 | 300 | `20261015_011917` |
| ext4 | on | 1100 | 7262 | 50009 | 86183 | 118345 | 135912 | 53.5 | 582 | `20261015_011917` |
| ext4-dj40 | off | 1100 | 6754 | 39806 | 61554 | 82381 | 98184 | 89.5 | 590 | `20261015_100648` |
| ext4-dj40-ssd990 | off | 1100 | 1317 | 6331 | 10124 | 17455 | 23240 | 261.3 | 626 | `20261029_103456_ssd990`, `20261029_160107_ssd990` |
| ext4-odirect | off | 1100 | 8131 | 61592 | 113652 | 171616 | 189632 | 33.6 | 113 | `20261030_191444_odirect` |
| ext4-odirect | on | 1100 | 7950 | 60119 | 109516 | 152891 | 186507 | 33.3 | 209 | `20261030_113108_odirect` |
| ext4-ssd990 | off | 1100 | 2027 | 10247 | 18178 | 26970 | 37380 | 187.5 | 302 | `20261028_035259_ssd990`, `20261029_134822_ssd990` |
| ext4-ssd990 | on | 1100 | 2129 | 6763 | 10614 | 12690 | 6189 | 2156.2 | 584 | `20261029_092916_ssd990`, `20261029_145440_ssd990` |
| ext4-tau | off | 1100 | 7362 | 52725 | 93039 | 132443 | 155754 | 43.6 | 421 | `20261021_071529` |
| ext4-tau-ssd990 | off | 1100 |  |  |  |  | 52084 | 106.4 | 529 | `20261026_101921_ssd990` |
| xfs | off | 1100 | 7247 | 52892 | 92799 | 116527 | 119350 | 104.1 | 322 | `20261015_100648` |
| xfs | on | 1100 | 7048 | 48814 | 81260 | 102005 | 109515 | 112.3 | 591 | `20261015_100648` |
| xfs-ssd990 | off | 1100 | 2239 | 7529 | 11075 | 11153 | 9780 | 1401.7 | 286 | `20261029_114325_ssd990`, `20261029_171105_ssd990` |
| xfs-ssd990 | on | 1100 | 2124 | 5641 | 8069 | 9350 | 4834 | 3249.1 | 573 | `20261029_114325_ssd990`, `20261029_171105_ssd990` |
| xfs-tau | off | 1100 | 7210 | 51871 | 89521 | 113018 | 110830 | 134.7 | 522 | `20261021_071529` |
| zfs-16k | off | 1100 | 6265 | 40717 | 65520 | 87640 | 95343 | 71.3 | 1138 | `20261015_100648` |
| zfs-16k-ssd990 | off | 1100 | 1695 | 6905 | 10581 | 15480 | 19775 | 432.0 | 828 | `20261027_053338_ssd990`, `20261028_091556_ssd990` |

## TPC-C postgres

| fs | protection | WH | 1 term | 8 term | 16 term | 32 term | 64 term | p99 ms | KB/NO | run |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| btrfs | off | 1100 | 9784 | 12276 | 31315 | 26049 | 49028 | 128.0 | 242 | `20261018_235303` |
| ext4 | off | 1100 | 18638 | 140595 | 263809 | 381409 | 457845 | 13.7 | 99 | `20261014_230651` |
| ext4 | on | 1100 | 16538 | 115313 | 199450 | 263246 | 305602 | 20.5 | 264 | `20261014_230651` |
| ext4-dj40 | off | 1100 | 16502 | 109266 | 179957 | 243801 | 297181 | 57.6 | 196 | `20261015_045502` |
| ext4-dj40-ssd990 | off | 1100 | 2165 | 8919 | 17567 | 28483 | 46695 | 220.6 | 229 | `20261027_070025_ssd990`, `20261027_234531_ssd990` |
| ext4-ssd990 | off | 1100 | 6194 | 18795 | 34630 | 61389 | 92841 | 67.5 | 98 | `20261027_213557_ssd990`, `20261030_032809_ssd990` |
| ext4-ssd990 | on | 1100 | 5666 | 15746 | 26498 | 38798 | 47713 | 126.9 | 300 | `20261027_213557_ssd990`, `20261030_032809_ssd990` |
| ext4-tau | off | 1100 | 18704 | 136535 | 249175 | 352011 | 419372 | 14.3 | 179 | `20261021_050528` |
| ext4-tau-ssd990 | off | 1100 |  |  |  |  | 110911 | 48.6 | 171 | `20261026_091450_ssd990` |
| ext4-walcomp | on | 1100 | 15714 | 112506 | 199357 | 270354 | 292116 | 23.4 | 235 | `20261030_123637_walcomp` |
| xfs | off | 1100 | 18792 | 140484 | 262619 | 377616 | 449526 | 14.3 | 99 | `20261015_045502` |
| xfs | on | 1100 | 16660 | 117860 | 201309 | 264036 | 260176 | 27.2 | 269 | `20261015_045502` |
| xfs-ssd990 | off | 1100 | 6217 | 19391 | 32942 | 56553 | 85059 | 76.1 | 100 | `20261027_172856_ssd990`, `20261028_005236_ssd990` |
| xfs-ssd990 | on | 1100 | 5838 | 15667 | 26394 | 40884 | 49512 | 124.3 | 296 | `20261027_172856_ssd990`, `20261028_005236_ssd990` |
| xfs-tau | off | 1100 | 19092 | 138795 | 244945 | 341183 | 404835 | 14.8 | 177 | `20261021_050528` |
| zfs-8k | off | 1100 | 14900 | 92533 | 141657 | 185792 | 210977 | 40.1 | 485 | `20261015_045502` |
| zfs-8k-ssd990 | off | 1100 | 5356 | 13781 | 22756 | 30414 | 35542 | 179.2 | 430 | `20261027_043815_ssd990`, `20261028_025605_ssd990` |
