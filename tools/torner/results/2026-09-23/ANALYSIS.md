# Torner 검증 분석 — 2026-09-23

> Torner(② 분할 탐지 → ③ 자체 복구를 거친 크래시 상태 판정 → ① 입력 퍼징)를
> VM의 실제 캡처에 처음 적용한 결과다. **도구 검증용 스냅샷이지 논문 표가 아니다.**
> 캡처와 복구가 서로 다른 커널 빌드에서 이루어졌다 — §3 참고.
> 방법론(모델 O/R/T의 정의와 합법성)은 [`../../README.md`](../../README.md)의
> "What Torner verifies, and how"에 있다.

## 1. 결론

찢어진 증거(witness)가 나온 파일시스템은 **ext4(ordered), ext4 data=journal, xfs,
f2fs**다. **btrfs·zfs는 어느 모델에서도 0**이었지만, 이는 증명이 아니라 표본 크기에
따른 상한이다(§4.6).

| | 장치가 bio를 찢을 수 있다 (T) | 장치에 대한 가정 없음 (O/R) |
|---|---|---|
| ext4 ordered | 전부 찢어짐 (100/100) | 드묾 (768개 중 분할된 1개가 찢어짐) |
| xfs | 전부 (100/100) | 드묾 (512개 중 분할된 1개) |
| f2fs | 전부 (100/100) | 증거 없음 — 분할된 쓰기 자체가 0개 |
| ext4 data=journal | 드묾 (2/256) | 동시성·간섭이 있으면 찢어짐 (t4 5/256, t16 FLUSH 사이 분할 18개 중 14개) |
| btrfs | 0/51 | 0/9 (O), 0/9 (R) |
| zfs | 0/24 (16k) | 0/662 (16k, O), 0/133 (4k, R) |

핵심 발견:

1. **모양(②)이 찢어짐을 예측한다.** data=journal에서 찢어진 쓰기는 전부 *FLUSH를 사이에
   두고 분할된* 쓰기였다(t4 6개 중 5개, t16 18개 중 14개). *한 flush window 안에서*
   분할된 쓰기는 하나도 찢어지지 않았다(0/250, 0/84, 0/30). 단, FLUSH 사이 분할인데도
   원자적으로 복구된 쓰기 (1016, 1)이 있었다 — 모양은 필요조건일 뿐이고, 그래서 ③에서
   실제 복구를 거쳐 확인한다.
2. **장치 찢어짐 없이도(모델 O) 찢어진다.** ext4 ordered, xfs, data=journal 모두
   파일시스템이 쓰기를 쪼갤 때 찢어졌다. ext4는 같은 파일에 대한 다른 스레드의 `fsync`가
   16 KiB `pwrite`의 앞 4 KiB만 먼저 내보냈고, data=journal은 외부 커밋(다른 스레드의
   `fsync`, `sync`)이 쓰기 도중에 트랜잭션을 닫았다(*commit-induced split*).
3. **장치가 bio를 찢으면(T) 제자리 덮어쓰기 FS는 모든 쓰기가 찢어진다**
   (ext4/xfs/f2fs 100/100). data=journal은 저널 사본 덕에 대부분 막히고, 커밋으로 쪼개진
   쓰기만 찢어진다. btrfs·zfs(copy-on-write)는 0이다.
4. **퍼저(①)가 찢어짐이 없던 설정에서 witness를 찾았다.** data=journal 단일 스레드
   (FLUSH 사이 분할 0개)에서 출발해, 9번째 반복이 `sync` 5 ms + 다른 파일 `fsync` 20 ms
   간섭을 찾아 쓰기 (134, 1)을 커밋 사이로 쪼갰고, 복구 후 찢어진 상태를 손으로 재현했다.
   ext4 저널 복구와 fsck는 파일시스템이 일관적이라고 보고한다.

τJournal 관점에서 가장 중요한 것은 2번이다: **데이터 저널링을 켠 ext4조차 동시성
하에서는 장치 찢어짐 없이 응용 쓰기의 원자성을 잃는다.**

## 2. 무엇을 어떻게 쟀나

- **속성**: `pwrite(16 KiB)` + `fsync` 이후, 장치가 낼 수 있는 어떤 합법적 크래시와
  파일시스템 복구 뒤에도 그 16 KiB는 전부 옛 값이거나 전부 새 값이어야 한다.
- **파이프라인**: `capture.sh`(dm-log-writes로 워크로드 기록) → `torner atoms`(②, 각
  쓰기가 장치에 도달한 모양) → `replay --strategy atom-*`(③, 쓰기가 깨질 수 있는 지점의
  크래시 상태) → mount(**파일시스템 자체 복구**) → `check --focus-file`(겨냥한 쓰기 판정)
  → `report.py`.
- **크래시 모델**
  - **O** 순서대로 prefix — 장치에 대한 가정 없음
  - **R** 캐시 재정렬 — 마지막 FLUSH 이후의 일반 쓰기만 버림
  - **T** bio 찢어짐 — 진행 중인 bio가 4 KiB 경계까지만 기록됨
- **판정 단위**: 응용 쓰기 W = (page, version). W를 겨냥한 상태 중 하나라도 복구 후 W가
  찢어져 있으면 torn. 비율은 95% Wilson 구간과 함께 보고한다.
- **워크로드**: `torner gen` overwrite, 16 KiB 단위(4 KiB 섹터 4개), 매 쓰기 `fsync`,
  1024 pages, 스레드 1/4/16, 3~4초. 모든 스레드가 같은 파일에 쓰되 페이지 소유는 분할.

## 3. 출처와 한계

- **커널**: 캡처(I/O 패턴)는 대부분 2026-09-22 당시 빌드(#1975로 추정), tau t1/t4
  캡처만 09-23 02:04(#1978). 크래시 상태의 복구·판정은 2026-09-23 게스트 커널
  `6.8.0tjournal+ #1978`(djournalplus-kernel.code f70bf94a + 미커밋 변경)에서 했다.
  `capture.json`에 커널 정보가 기록되지 않는다 — 고쳐야 할 점(§5).
- **baseline FS도 djournalplus 커널에서 측정했다.** tau 경로는 `-o tjournal` 없이는
  비활성이라고 가정했다. 논문 표는 커널 빌드 하나로 다시 측정해야 한다.
- **τJournal은 분석하지 않았다.** 복구 경로를 패치 중이다. `raw/`에는 tau 캡처의
  atoms 결과와 이전 세션의 epoch 기반 결과만 있다.
- **표본**: atom-order/reorder는 대부분 전수다(ext4-data t4 O는 1350 상태 전수).
  예산을 쓴 실행은 쓰기 단위 샘플링이다 — atom-tear 300/150, ext4-data t4 R 500,
  t1 O 500, t16 O 400(`--prefer-split`, 분할 쓰기 우선이므로 모양별로만 읽어야 함).
- **ext4-data t4 O(첫 실행)는 모양 태그 추가 전에 돌린 것**이라 `report.txt`에 모양별
  행이 없다. FLUSH 사이 분할 6개와의 대조(5/6)는 `atoms` 결과로 따로 확인했다.
- **0은 상한일 뿐이다.** 모든 모델은 완료된 FLUSH를 믿는다(FLUSH를 어기는 장치는
  재현하지 못한다). 모델이 표현하지 못하는 합법 상태 두 가지는 README에 적혀 있다.

## 4. 결과 상세

### 4.1 쓰기가 장치에 도달한 모양 (② `torner atoms`)

| config | 스레드 | 쓰기 | 한 bio | window 안 분할 | FLUSH 사이 분할 | 재정렬 가능 | O / R / T 전수 상태 수 |
|---|---|---|---|---|---|---|---|
| ext4 | t1 | 576 | 576 | 0 | 0 | 0 | 0 / 0 / 1728 |
| ext4 | t4 | 768 | 767 | 0 | 1 | 0 | 3 / 0 / 2303 |
| ext4-data | t1 | 448 | 0 | 448 | 0 | 448 | 2692 / 3584 / 1344 |
| ext4-data | t4 | 256 | 0 | 250 | 6 | 256 | 1350 / 2061 / 733 |
| ext4-data | t16 | 2048 | 0 | 2030 | 18 | 2048 | 10841 / 19088 / 4488 |
| xfs | t1 | 576 | 576 | 0 | 0 | 0 | 0 / 0 / 1728 |
| xfs | t4 | 512 | 511 | 1 | 0 | 1 | 2 / 1 / 1535 |
| f2fs | t1 | 640 | 640 | 0 | 0 | 0 | 0 / 0 / 1920 |
| f2fs | t4 | 1280 | 1280 | 0 | 0 | 0 | 0 / 0 / 3840 |
| btrfs | t1 | 448 | 448 | 0 | 0 | 0 | 0 / 0 / 1344 |
| btrfs | t4 | 768 | 759 | 9 | 0 | 9 | 18 / 9 / 2295 |
| zfs (128K) | t4 | 1024 | 1024 | 0 | 0 | 0 | 339 / 0 / 6082 |
| zfs-16k | t1 | 768 | 768 | 0 | 0 | 0 | 845 / 0 / 4968 |
| zfs-16k | t4 | 1024 | 1024 | 0 | 0 | 0 | 380 / 0 / 6082 |
| zfs-8k | t4 | 1280 | 1280 | 0 | 0 | 0 | 463 / 50 / 7451 |
| zfs-4k | t4 | 1088 | 1088 | 0 | 0 | 0 | 544 / 236 / 6391 |

- data=journal은 데이터를 4 KiB씩 저널에 쓰므로 모든 쓰기가 분할된다. 대부분은 한 window
  안이고, 스레드가 늘면 FLUSH 사이 분할이 생긴다(t1 0 → t4 6 → t16 18).
- zfs는 모든 쓰기가 ZIL 레코드 안에 한 bio로(비정렬로 내장되어) 먼저 도달하고, 나중에
  제자리에 다시 쓰인다. 그래서 "한 bio"인데도 두 사본 사이의 O 상태가 존재한다.
- tau-ext4 행은 `report.txt`에 있지만 패치 중이라 여기서 다루지 않는다.

### 4.2 모델별 쓰기 단위 결과 (③)

| config | 스레드 | 모델 | 찢어진 쓰기 / 시도한 쓰기 | 비율 [95% 구간] | 상태 수 |
|---|---|---|---|---|---|
| ext4 | t4 | O | 1/1 | 100% [21–100] | 3 |
| ext4 | t4 | T | 100/100 | 100% [96–100] | 300 |
| ext4 | t1 | T | 100/100 | 100% [96–100] | 300 |
| xfs | t4 | O | 1/1 | 100% [21–100] | 2 |
| xfs | t4 | R | 1/1 | 100% [21–100] | 1 |
| xfs | t4 | T | 100/100 | 100% [96–100] | 300 |
| f2fs | t4 | T | 100/100 | 100% [96–100] | 300 |
| ext4-data | t4 | O | 5/256 | 2.0% [0.8–4.5] | 1350 (전수) |
| ext4-data | t4 | R | 1/63 | 1.6% [0.3–8.5] | 507 |
| ext4-data | t4 | T | 2/256 | 0.8% [0.2–2.8] | 733 (전수) |
| ext4-data | t16 | O (분할 우선) | 14/48 | 모양별로 읽을 것 (§4.3) | 403 |
| ext4-data | t1 | O | 0/84 | 0% [0–4.4] | 504 |
| btrfs | t4 | O / R / T | 0/9, 0/9, 0/51 | 상한 30%, 30%, 7.0% | 18, 9, 152 |
| zfs-16k | t4 | O / T | 0/662, 0/24 | 상한 0.6%, 13.8% | 380, 150 |
| zfs-4k | t4 | R | 0/133 | 상한 2.8% | 236 |

모든 상태가 마운트(zfs는 import)에 성공했다(unmountable 0).

### 4.3 ext4 data=journal — 모양별

| 스레드 | 모델 | FLUSH 사이 분할 | window 안 분할 |
|---|---|---|---|
| t4 | O | **5/6** | 0/250 |
| t4 | R | **1/1** | 0/62 |
| t4 | T | **2/6** | 0/250 |
| t16 | O | **14/18** | 0/30 |
| t1 | O | (해당 없음) | 0/84 |

window 안 분할은 트랜잭션 하나에 전부 들어가므로, 커밋 블록이 없으면 복구가 통째로
버리고 있으면 통째로 재생한다. FLUSH 사이 분할은 쓰기가 **두 트랜잭션에 걸친** 경우로,
앞 트랜잭션만 커밋된 시점에 크래시가 나면 앞부분만 재생된다.

### 4.4 재현 가능한 witness

| FS | 캡처 (VM `/mnt/scratch/`) | 모델 | state_spec | 쓰기 | 모양 |
|---|---|---|---|---|---|
| ext4 ordered | `cap-ext4` | O | `entry<=512` | (843, 1) | FLUSH 사이 분할 |
| xfs | `cap-xfs` | O | `entry<=917` | (332, 1) | window 안 분할 |
| xfs | `cap-xfs` | R | `entry<=918,drop=[917]` | (332, 1) | window 안 분할 |
| ext4 data=journal t4 | `cap-ext4data` | O | `entry<=4986` | (669, 1) | FLUSH 사이 분할 |
| ext4 data=journal t4 | `cap-ext4data` | R | `entry<=5590,drop=[5589]` | (746, 1) | FLUSH 사이 분할 |
| ext4 data=journal t4 | `cap-ext4data` | T | `entry<=4987,partial=[4987:16]` | (669, 1) | FLUSH 사이 분할 |
| ext4 data=journal t16 | `cap-ed-t16` | O | `entry<=5236` | (356, 1) | FLUSH 사이 분할 |
| ext4 data=journal t1 + 간섭 | `fuzz-ed1/c0010` | O | `entry<=5418` | (134, 1) | FLUSH 사이 분할 |
| ext4 ordered | `cap-ext4` | T | `entry<=507,partial=[507:16]` | (378, 1) | 한 bio |
| xfs | `cap-xfs` | T | `entry<=157,partial=[157:16]` | (843, 1) | 한 bio |
| f2fs | `cap-t4-f2fs` | T | `entry<=2071,partial=[2071:16]` | (843, 1) | 한 bio |

- ext4 ordered (843, 1): 첫 4 KiB가 entry 509(flush epoch 7), 나머지 12 KiB가
  entry 514(epoch 8). `entry<=512`에서 복구하면 [v1, v0, v0, v0].
- data=journal (669, 1): 섹터 0–2가 flush epoch 69, 섹터 3이 epoch 71에 저널링.
  `entry<=4986`(첫 트랜잭션 커밋 후, 섹터 3 저널링 전)에서 복구하면 섹터 0–2만 새 값.
- 모든 witness는 `version_mismatch`(한 쓰기 안에서 섹터 버전이 섞임)였다.
- 상태별 전체 목록은 `raw/*/states-atom-*.jsonl`의 `targets_torn`에 있다.

재현(게스트에서; `base.img`/`log.img`는 크기 때문에 VM에만 있다):

```sh
C=/mnt/scratch/fuzz-ed1/c0010
rid=$(sed -n 's/.*"run_id":\([0-9]*\).*/\1/p' $C/capture.json)
truncate -r $C/base.img s.img
torner replay --log $C/log.img --target s.img --state-spec 'entry<=5418'
L=$(losetup --show -f s.img); mkdir -p m; mount -o data=journal $L m   # 복구
echo "134 1" > focus
torner check --file m/torner.dat --run-id $rid --focus-file focus
# -> "focus":{"torn":[{"page":134,"version":1,"kind":"version_mismatch",...}]}
```

(마운트 옵션은 FS마다 `scripts/fsmap.sh`의 `fs_mount_opts`를 따른다.)

### 4.5 퍼징 캠페인 (①)

```sh
scripts/fuzz.py --fs ext4-data --workdir /mnt/scratch/fuzz-ed1 \
    --seed-config '{"threads": 1}' --iterations 12 --explore-limit 150 \
    --stop-on-witness --seed 3
```

| # | 설정 (seed에서 바뀐 것) | 쓰기 | window / FLUSH 분할 | 새 커버리지 | witness |
|---|---|---|---|---|---|
| 0 | t1 overwrite 16K, 매 쓰기 fsync (seed) | 105 | 105 / 0 | 2 | 0 |
| 1 | 64K, fsync 4회마다, 4096 pages | 216 | 216 / 0 | 2 | 0 |
| 2 | + writeback 1 ms | 180 | 180 / 0 | 0 | — |
| 3 | mixed 8K | 114 | 114 / 0 | 2 | 0 |
| 4 | append 8K, fsync 없음 | 1024 | 1024 / 0 | 1 | 0 |
| 5 | + O_DIRECT, fdatasync | 1024 | 1024 / 0 | 3 | 0 |
| 6 | 64K + 다른 파일 fsync 5 ms | 156 | 156 / 0 | 0 | — |
| 7 | append 32K, fsync 없음 + sync 20 ms + writeback 20 ms | 1024 | 1023 / 1 | 3 | 0 |
| 8 | O_DIRECT, fdatasync | 116 | 116 / 0 | 0 | — |
| 9 | **sync 5 ms + 다른 파일 fsync 20 ms** | 77 | 72 / **5** | 4 | **4 상태, 쓰기 (134, 1)** |

10개 설정, corpus 8개, 커버리지 feature 17개에서 멈췄다(`--stop-on-witness`).
새 커버리지가 없는 반복(—)은 탐색하지 않고 이미지를 지웠다. 이 캠페인은
**시그니처 기반 탐색(`--signatures`) 추가 전 버전**으로 돌았다 — 새 커버리지가 있는
캡처는 모든 쓰기를 대상으로 `--prefer-split` 탐색했다. 새 모양의 쓰기에만 상태를
겨냥하는 현재 버전은 테스트만 했고 캠페인으로는 아직 돌리지 않았다.

### 4.6 btrfs·zfs의 0

- 결과: btrfs O 0/9, R 0/9, T 0/51 · zfs-16k O 0/662, T 0/24 · zfs-4k R 0/133.
- 95% 상한: btrfs O/R 약 30%(분할된 쓰기가 9개뿐), T 7.0% · zfs O 0.6%, T 13.8%,
  4k R 2.8%.
- 원리상 설명: 둘 다 copy-on-write라 새 블록을 다른 자리에 쓰고 커밋 때 루트 포인터
  (btrfs tree root, zfs uberblock)를 원자적으로 바꾼다. 찢어진 새 블록은 참조되지
  않고, 체크섬이 한 번 더 막는다.
- 이전에 zfs `recordsize=16k`에서 관찰했던 찢어짐(ZIL/txg 경계)은 재현되지 않았다.
  버전 차이 때문인지 모델 밖 현상인지는 이 결과로 구분할 수 없다(README의 ZFS 절).

### 4.7 기타 관찰

- **f2fs**: T 상태 300개 중 31개에서 fsck가 pristine 기준선에 없던 지적을 했다(P3).
  데이터 bio 찢어짐이 메타데이터 불일치로 이어지는지 따로 볼 가치가 있다.
- T 상태의 **P2 "lost"**(ext4 81, xfs 48, f2fs 102 등)는 대부분 찢어진 바로 그 페이지다
  — 새 버전이 찢어지면서 이전에 durable했던 버전도 더는 읽을 수 없게 된 것.

## 5. 다음 단계

- `capture.json`에 커널 빌드 정보를 기록하고, 커널 하나로 전체를 다시 측정해 논문 표를
  만든다(가능하면 stock 커널 baseline과 비교).
- τJournal: 패치가 안정되면 `atom-*` 전수 + `fuzz.py --fs tau-ext4 --time-budget …`.
- `targeted` 전략(커밋은 durable한데 데이터는 없는 불법 상태) 구현.
- f2fs P3 지적 조사.
- 모델이 표현하지 못하는 합법 상태 두 가지 보강 검토.

## 6. 파일 구성

| 경로 | 내용 |
|---|---|
| `report.txt` | `report.py` 전체 출력: Table 1(epoch 기반 전략 포함), 쓰기 단위 표, 모양 표, 상태 커버리지 |
| `report.tex` | LaTeX: Table 1 + 쓰기 단위 표 |
| `raw/cap-*/` | 캡처별 `capture.json`, `atoms.json`(최종 바이너리로 재생성), `states-*.jsonl`, `fsck-baseline.txt` |
| `raw/cap-*/states-{single-drop,torn-entry}.jsonl` | 이전 세션(2026-09-22)의 epoch 기반 전략 결과 |
| `raw/fuzz-ed1/` | `fuzz.jsonl`, `witnesses.jsonl`, `corpus.json`, 반복별 `c*.log`·`c*/capture.json`·`atoms.json`, witness 캡처 `c0010`의 상태 결과 |
| `raw/batch*.log`, `raw/fuzz-ed1.log` | 실행 로그 |

이미지(`base.img`, `log.img`, `progress.img`)는 크기 때문에 커밋하지 않았다.
VM 스크래치 디스크(`tools/qemu/vm_imgs/torner-scratch.raw`)의 `/mnt/scratch/`에 있다.
