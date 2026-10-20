# libra09: benchmark summary

Made by `bench/scripts/export_results.py` from the results in
`bench/workspace/results/libra09/sysbench/<db>/<run>/` (outside git, on libra09);
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

Throughput in transactions/s (mean of the runs at a point); protection on = PostgreSQL
full_page_writes / InnoDB doublewrite; KB/trx = device writes per transaction at the most threads.

## sysbench mysql

| workload | fs | protection | 1 thr | 8 thr | 16 thr | 32 thr | 64 thr | KB/trx | run |
|---|---|---|---:|---:|---:|---:|---:|---:|---|
| insert | btrfs | off | 281 | 389 | 1089 | 582 | 1260 | 32.1 | `20261019_061714` |
| insert | ext4 | off | 9061 | 61540 | 111453 | 154989 | 203505 | 2.0 | `20261017_093244` |
| insert | ext4 | on | 8854 | 60661 | 106814 | 147811 | 193581 | 3.2 | `20261017_093244` |
| insert | ext4-dj40 | off | 4877 | 31093 | 53438 | 70840 | 98128 | 5.1 | `20261017_093244` |
| insert | xfs | off | 8926 | 61679 | 111056 | 152929 | 201284 | 2.0 | `20261017_093244` |
| insert | xfs | on | 8811 | 59585 | 107164 | 147525 | 193656 | 3.1 | `20261017_093244` |
| insert | zfs-16k | off | 5010 | 33622 | 56897 | 82273 | 119797 | 3.3 | `20261017_093244` |
| update_index | btrfs | off | 52 | 100 | 233 | 1743 | 1736 | 53.3 | `20261019_061714` |
| update_index | ext4 | off | 6724 | 46728 | 79781 | 111359 | 140956 | 8.6 | `20261016_044321` |
| update_index | ext4 | on | 6021 | 38175 | 60843 | 81268 | 105688 | 15.7 | `20261016_044321` |
| update_index | ext4-dj40 | off | 2854 | 14510 | 21183 | 28435 | 41311 | 22.3 | `20261016_044321` |
| update_index | xfs | off | 6593 | 43961 | 74066 | 101497 | 126948 | 8.5 | `20261016_044321` |
| update_index | xfs | on | 6093 | 37173 | 58586 | 78497 | 102177 | 15.6 | `20261016_044321` |
| update_index | zfs-16k | off | 3084 | 20741 | 34412 | 51718 | 66241 | 19.7 | `20261016_044321` |
| update_non_index | btrfs | off | 874 | 266 | 298 | 452 | 3692 | 21.1 | `20261019_061714` |
| update_non_index | ext4 | off | 8267 | 59301 | 105366 | 153531 | 202162 | 3.3 | `20261016_165915` |
| update_non_index | ext4 | on | 8196 | 56330 | 98325 | 140359 | 182513 | 5.7 | `20261016_165915` |
| update_non_index | ext4-dj40 | off | 4628 | 27768 | 42608 | 59091 | 78962 | 7.6 | `20261016_165915` |
| update_non_index | xfs | off | 8006 | 58286 | 104689 | 149941 | 196352 | 3.3 | `20261016_165915` |
| update_non_index | xfs | on | 8083 | 55597 | 96076 | 136378 | 178734 | 5.7 | `20261016_165915` |
| update_non_index | zfs-16k | off | 4415 | 29640 | 49807 | 73957 | 103133 | 6.9 | `20261016_165915` |
| write_only | btrfs | off | 109 | 710 | 1780 | 1454 | 1994 | 68.1 | `20261019_061714` |
| write_only | btrfs-uniform | off |  |  |  |  | 811 | 226.4 | `20261002_072816_uniform` |
| write_only | ext4 | off | 2362 | 16824 | 28294 | 40319 | 47902 | 25.5 | `20261009_081451` |
| write_only | ext4 | on | 2089 | 13473 | 20737 | 27490 | 35030 | 47.2 | `20261009_081451` |
| write_only | ext4-dj40 | off | 1671 | 8547 | 12679 | 16829 | 21021 | 43.6 | `20261009_081451` |
| write_only | ext4-dj40-fullfill | off | 1631 | 8364 | 12508 | 16495 | 20765 | 43.5 | `20261009_212738_fullfill` |
| write_only | ext4-dj40-uniform | off | 1109 | 5202 | 6921 | 8164 | 9264 | 124.4 | `20261017_202936_uniform` |
| write_only | ext4-fullfill | off | 2388 | 16662 | 27414 | 38897 | 45597 | 25.7 | `20261009_212738_fullfill` |
| write_only | ext4-fullfill | on | 2047 | 13091 | 19840 | 26331 | 33192 | 47.5 | `20261009_212738_fullfill` |
| write_only | ext4-uniform | off | 1262 | 8509 | 14273 | 20446 | 22831 | 72.8 | `20261017_202936_uniform` |
| write_only | ext4-uniform | on | 1105 | 6568 | 9851 | 12495 | 13063 | 138.8 | `20261017_202936_uniform` |
| write_only | xfs | off | 2293 | 15660 | 26190 | 36156 | 44017 | 24.7 | `20261009_081451` |
| write_only | xfs | on | 2089 | 13117 | 20314 | 27547 | 34838 | 45.7 | `20261009_081451` |
| write_only | zfs-16k | off | 1520 | 9268 | 15983 | 22813 | 27355 | 53.3 | `20261009_081451` |
| write_only | zfs-16k-fullfill | off | 1504 | 9250 | 15844 | 22614 | 25721 | 53.8 | `20261009_212738_fullfill` |
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
| insert | ext4-dj40 | off | 5688 | 33892 | 57480 | 79774 | 109975 | 4.7 | `20261017_032251` |
| insert | xfs | off | 9734 | 57416 | 97879 | 144065 | 175178 | 2.1 | `20261017_032251` |
| insert | xfs | on | 9610 | 54380 | 85029 | 116443 | 134687 | 5.9 | `20261017_032251` |
| insert | zfs-8k | off | 6394 | 37636 | 63201 | 89416 | 125073 | 2.6 | `20261017_032251` |
| update_index | btrfs | off | 863 | 648 | 649 | 1696 | 18816 | 11.5 | `20261019_020217` |
| update_index | ext4 | off | 8754 | 51104 | 89557 | 134158 | 161094 | 4.8 | `20261015_223600` |
| update_index | ext4 | on | 7855 | 36777 | 54496 | 66859 | 71734 | 19.7 | `20261015_223600` |
| update_index | ext4-dj40 | off | 5277 | 28043 | 43915 | 59575 | 72479 | 11.0 | `20261015_223600` |
| update_index | xfs | off | 8633 | 50136 | 85844 | 126358 | 151743 | 4.8 | `20261015_223600` |
| update_index | xfs | on | 7820 | 37434 | 55136 | 68768 | 74702 | 19.9 | `20261015_223600` |
| update_index | zfs-8k | off | 5349 | 29163 | 45842 | 61877 | 71120 | 21.0 | `20261015_223600` |
| update_non_index | btrfs | off | 956 | 5562 | 6181 | 5640 | 20116 | 11.2 | `20261019_020217` |
| update_non_index | ext4 | off | 10738 | 59494 | 107053 | 155125 | 200065 | 2.5 | `20261016_105303` |
| update_non_index | ext4 | on | 9900 | 50877 | 83262 | 117664 | 144326 | 5.7 | `20261016_105303` |
| update_non_index | ext4-dj40 | off | 6005 | 31646 | 53091 | 76324 | 101657 | 5.9 | `20261016_105303` |
| update_non_index | xfs | off | 10503 | 58619 | 105711 | 152082 | 192640 | 2.5 | `20261016_105303` |
| update_non_index | xfs | on | 9977 | 51288 | 83196 | 118292 | 146653 | 5.8 | `20261016_105303` |
| update_non_index | zfs-8k | off | 6377 | 34691 | 56742 | 79221 | 104712 | 10.1 | `20261016_105303` |
| write_only | btrfs | off | 954 | 778 | 4120 | 7965 | 5901 | 31.4 | `20261019_020217` |
| write_only | btrfs-uniform | off |  |  |  |  | 2370 | 57.2 | `20261002_064708_uniform` |
| write_only | ext4 | off | 3004 | 20387 | 35092 | 50925 | 62207 | 17.3 | `20261009_151712` |
| write_only | ext4 | on | 2661 | 15770 | 23610 | 28810 | 29240 | 50.4 | `20261009_151712` |
| write_only | ext4-dj40 | off | 2336 | 12721 | 19095 | 24077 | 27902 | 34.8 | `20261009_151712` |
| write_only | ext4-dj40-fullfill | off | 2268 | 12724 | 19110 | 23369 | 27382 | 35.0 | `20261010_023220_fullfill` |
| write_only | ext4-dj40-uniform | off | 1285 | 6151 | 9047 | 11432 | 12170 | 89.4 | `20261017_171541_uniform` |
| write_only | ext4-fullfill | off | 2977 | 20278 | 35029 | 49947 | 61332 | 17.4 | `20261010_023220_fullfill` |
| write_only | ext4-fullfill | on | 2724 | 15715 | 23145 | 28174 | 28737 | 50.2 | `20261010_023220_fullfill` |
| write_only | ext4-uniform | off | 1531 | 10319 | 18003 | 27581 | 37352 | 47.8 | `20261017_171541_uniform` |
| write_only | ext4-uniform | on | 1364 | 7855 | 12131 | 14378 | 14761 | 104.6 | `20261017_171541_uniform` |
| write_only | xfs | off | 2981 | 20070 | 33662 | 48098 | 58655 | 17.3 | `20261009_151712` |
| write_only | xfs | on | 2754 | 15918 | 24186 | 29834 | 29858 | 51.5 | `20261009_151712` |
| write_only | zfs-8k | off | 2210 | 12508 | 18593 | 23539 | 24160 | 70.8 | `20261009_151712` |
| write_only | zfs-8k-fullfill | off | 2205 | 12484 | 18577 | 23463 | 23939 | 60.2 | `20261010_023220_fullfill` |
| write_only | zfs-8k-uniform | off |  |  |  |  | 8958 | 206.0 | `20261002_080556_uniform` |
