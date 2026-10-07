# OSDI 실험 계획 — 4 절 구성

상태: **계획.** 실행 전. 커널 변경 없음(빌드 변형 ablation 은 별도 표시).
기준: 커널 `#250`, 하네스 `bench/workspace/tools/`, 정합성 `tools/tautest/`.
확정된 결과는 `sysbench-workloads-and-db-defaults.md` §4.19 에 있다.

구성과 각 절이 지지하는 주장:

| 절 | 주장 | 상태 |
|---|---|---|
| 1. 마이크로벤치 | 원시 연산(임의 크기 failure-atomic write())의 비용 곡선과 적용 범위 — 상한(hot overwrite)부터 하한(append)까지 | 도구 있음, 축 추가 필요 |
| 2. 메인 + 메커니즘 분리 | 두 RDBMS 에서 같은 보장을 3~12x 싸게; 이득의 원인은 바이트가 아니라 fsync 경로 | 메인 있음, 분리 실험 필요 |
| 3. 정합성 | 11 개 크래시/정합성 스위트 + CrashMonkey + VM 투명 | 11 개 PASS, 나머지 필요 |
| 4. Ablation | 설계 요소별 기여 — 특히 **공유 세그먼트 풀(동적 저널 공간)** | 일부 있음 |

---

## 1. 마이크로벤치 — 원시 연산 특성화, 범용성, 하한

### 1.1 비용 곡선: write() 크기 × 보호 방식

같은 old-or-new 보장을 응용이 직접 구현하는 방법과 비교한다.

| 방식 | 구현 | fsync/op |
|---|---|---|
| **tau** | `pwrite` + `fsync` (제자리, `O_TAU_UNTORN`) | 1 |
| temp+rename | write temp + fsync + rename + dir fsync | 2 |
| 응용 이중 쓰기 | 사본 write + fsync + 본체 write + fsync (doublewrite 의 일반형) | 2 |
| 무보호 | `pwrite` + `fsync` (하한선, 보장 없음) | 1 |

- 크기: 512 B · 4 K · 8 K · 16 K · 64 K · 256 K · 1 M · 4 M · … 트랜잭션 상한(EINVAL)까지.
  상한이 나오는 지점을 **저널 크기별로** 기록한다 — "최대 원자 크기 = f(저널)" 곡선.
- 지표: 지연 avg/p99, ops/s, **장치 바이트/op**(iostat 또는 `write-attrib` 의 block tracepoint), fsync/op.
- 예측: 소형에서 tau 는 fsync 1 회 절감으로 지연 ~1/2, 바이트는 저널 사본만큼 +1x.
  대형으로 갈수록 저널 이중 쓰기가 지배해 temp+rename 과 교차. **교차점이 첫 그림.**
- 도구: `tauoverwrite` 에 보호 방식 모드 추가(또는 `tauatomic` 신규). 커널 변경 없음.

### 1.2 접근 패턴 envelope — 상한과 하한

기존 스크립트 그대로, 세 행(vanilla / tau-mount / tau-file) 유지:

| 패턴 | 스크립트 | 기대 | 의미 |
|---|---|---|---|
| **append** | `append-bench.sh` | ~2x 바이트, 처리량 저하 | **하한.** 모든 블록이 첫 dirty → 저널 + 제자리, 병합 없음. 정직하게 보여야 하는 최악 |
| random overwrite | `overwrite-bench.sh` | ~1x 로 수렴 | anchor→revoke 로 재기록이 제자리로 |
| same-region rewrite | `rewrite-same.sh` | ~1x | 병합의 상한 |
| sequential overwrite | `tauoverwrite seq` | 중간 | |

`tau-mount` 행이 중요하다 — "마운트만 한 비용" 과 "파일이 활성화된 비용" 을 분리한다.
`TAU_SMALL_TX`(2 MB) 경계를 걸치는 크기를 포함한다(`rewrite-same.sh` 주석 참고).

### 1.3 fsync 주기 → 저널 바이트 (메커니즘 검증)

재저널은 시간이 아니라 **fsync 에포크**가 정한다(`recent_fsync_tid`, `transaction.c:621`).
`tauoverwrite … fsync-every N` 을 1 · 10 · 100 · 1000 으로 스윕하고 `tau_probe_jwrite_blocks`
를 읽는다. 예측: 저널 바이트 ∝ fsync 횟수, 시간·`tau_max_commmit_age` 와 무관.
이것이 §4.19 의 "저널 ≈ FPI" 를 마이크로 수준에서 재현한다.

### 1.4 hot set 크기 → 병합률

random overwrite 의 대상 영역을 파일 크기의 1 % · 10 % · 100 % 로. `revoke_taken /
(revoke_taken + 첫 dirty)` 가 병합률. 예측: hot set 이 작을수록 1x 에 가까워짐.

### 1.5 같은 파일 동시성 (선제 비용 실험)

같은 파일에 1 · 4 · 16 · 32 스레드 pwrite+fsync. `t_atomic_lock` 이 write() 를 직렬화하므로
확장성 비용이 여기서 드러난다. 리뷰어가 반드시 묻는다. 도구에 스레드 축 추가 필요.

### 1.6 쓰기 귀속

`write-attrib.sh` — 장치 쓰기를 발행 스레드별(저널 / 체크포인터 / jbd2 / kworker)로
나눈 그림. "amplification 이 어디로 갔나" 를 한 장으로.

### 1.7 크래시 검증

1.1 의 모든 크기에서 전원 차단 후 old-or-new 확인 — `tautorn` 이 그 검사기.

환경: `tools/tautest` 의 VM + passthrough NVMe(기존). 베어메탈이 필요하면 `bench/fs_microbench`.

---

## 2. 메인 벤치 + 메커니즘 분리

### 2.1 메인 (있음)

PG 152 GB: 6 워크로드 × {`fpw=on`, `fpw=off`, tau} × ext4, 2 워크로드 × XFS.
MySQL 146 GB: 4 셀(두 팔). 전부 §4.19. 선택적 보강: XFS 나머지 4 워크로드, MySQL 워크로드 추가.

### 2.2 메커니즘 분리 A — 저동시성 커밋 지연

지금 결과는 전부 32 스레드 장치 포화 구간이라 이득이 처리량으로만 보인다.
같은 셀 드라이버로 **동시성 1 · 4 · 8 · 16** × {on, off, tau}, `oltp_update_non_index`.

- 지표: sysbench 지연 avg/p95/p99, `pg_stat_wal` (wal_bytes, wal_sync), iostat aqu-sz.
- 예측: 커밋 지연이 지배하는 저동시성에서 **tau ≈ `fpw=off`**, `fpw=on` 만 나쁨.
  원인은 WAL fsync 페이로드(§4.19 (10): 403 vs 35 MB/s).
- 도구: `cell242.sh` 의 `THREADS=32` 상수를 파라미터화.

### 2.3 메커니즘 분리 B — 대조군: `synchronous_commit=off`

fsync 가 커밋 경로에서 빠지면 `fpw=on` 의 페널티와 tau 의 이득이 **함께 줄어야** 한다.
같은 워크로드, 32 스레드, `synchronous_commit=off` 로 세 구성. 예측을 미리 적는다:
`fpw=on` 손실 28.6 % → 크게 감소, tau 이득 1.27x → 1.1x 근처. 맞으면 인과가 닫힌다.

### 2.4 MySQL

이득이 바이트 항(1.56x of 1.70x) 지배라 분리 실험 불필요. doublewrite 가 flush 경로의
동기 fsync 임을 설명으로 대신한다.

---

## 3. 정합성 벤치

### 3.1 tautest 스위트 — 표로 (11 개 PASS, #250)

| 테스트 | 검증하는 것 | 규모 |
|---|---|---|
| crash-test | 전원 차단 후 내용(md5) | 파일 7 개, 리플레이 확인 |
| cp-race | 체크포인트 writeback 중 차단 | 차단 20 회 |
| repair | 찢어진 in-place 사본 복구 | |
| sync / sync-race | sync(2)/syncfs(2), 다중 세그먼트 | |
| falloc | fallocate/unwritten + 차단, salt 누출 검사 | 7 파일 |
| xfs-hold | XFS 로그 순서 데드락 회귀 | |
| stress ext4 / xfs | 동시성 | 300 라운드 × 6 |
| db-crash postgres | 워크로드 중 차단, pgbench 불변식 | ext4-tau, xfs-tau |
| pg-torn | 2026-08-25 손상 워크로드, fpw off | 1,403,124 페이지, 저널 73 % |
| torn ext4 (4 GB) | 정적 유실 사냥, 100 % 점유 | 1,048,576 페이지 |

옆에 안전 카운터 감사(`retag_failed` · `cpdrop_unwritten` · `flush_onwrite` = 0, 보호 발동
`flush_folio_busy` · `flush_txdirty_late` > 0)를 병기한다.

### 3.2 CrashMonkey / ACE (FS 수준)

트리에 있으나 생성된 테스트 0 개. ACE seq-1 · seq-2 생성 → ext4-tau, xfs-tau 실행.
**FS 메타데이터 순서** 검사이므로 응용 수준 torn 과 별개임을 명시한다.

### 3.3 QEMU 게스트 투명 — 정합성 한 줄, 성능 주장 없음

"보장이 그것을 모르는 계층을 통과하는가". 호스트 ext4-tau 위 이미지 파일을
`O_TAU_UNTORN` 으로(QEMU `block/file-posix.c` 패치 ~10 줄 또는 `LD_PRELOAD`),
**cache=writeback**(현재 `run_vm.sh` 기본; `cache=none` 은 O_DIRECT 라 불가).
게스트: 무수정 PG `fpw=off` / MySQL `doublewrite=OFF`. qemu SIGKILL N 회 → 불변식.
비교 행: 호스트 ext4 → 손상 예상. `db-crash-test.sh` 를 passthrough 에서 호스트 파일
디스크로 확장.

### 3.4 추가

`db-crash-test.sh both mysql` (지원됨, 미실행).

---

## 4. Ablation

### 4.1 런타임 노브 (지금 가능, 커널 변경 없음)

| 노브 | 값 | 무엇을 보이나 | 상태 |
|---|---|---|---|
| `tau_defer_txdirty_cpflush` | 0 / 1 | 무효화될 제자리 쓰기 — `update_index` 에서 부호를 바꿈 | §4.18 있음 |
| `tau_strict_cpdrop` | 0 / 1 | 정합성 규칙의 비용: ext4 0, XFS 제자리 쓰기의 12.5 % | 있음 |
| `tau_max_commmit_age` | 1 / 5 / 30 | 예측: PG 저널 바이트 **불변**(fsync 에포크가 정함), 커밋 수만 변함 | 필요 |
| `tauvar_force_reclaim` | 10 / 20 / 40 | 회수 무릎의 위치 | 필요 |
| `tau_segment_per_alloc` | 1 / 8 / 32 | 할당 배치 | 필요 |

### 4.2 저널 공간 동적 조정 — 설계 장점의 ablation

**정의(코드)**: 세그먼트(128 MB)는 마운트 시 풀로 선할당되고(`tau_journal_init_blocks`,
`journal.c:1153`), **파일의 트랜잭션이 필요할 때 공유 풀에서 가져가고**
(`tau_journal_get_segment`, `:1229`) **체크포인트 후 반납한다**(`put_tau_segment`,
`:1433`). 즉 공간이 수요를 따라 파일 사이를 이동한다. jbd2 는 단일 원형 로그에 고정
head/tail. 이것이 "파일별 독립 트랜잭션 + 공유 풀" 의 실체이며, 논문의 핵심 설계 대비다.
(shrink 경로는 범위 밖 — 사용자 결정.)

| 실험 | 보이는 것 | 대조군 |
|---|---|---|
| (a) 최대 크기 스윕 4 / 8 / 16 / 32 GB | 성능·점유율·writer 정지(`wait_done_checkpoint`) vs 풀 크기. 무릎이 어디인가 | — |
| (b) 점유율 시계열 | `seg_free` 를 1 초 샘플링 — 풀이 "숨쉬는" 그림(가져감/반납) | — |
| (c) **파일 간 편중** | 1 hot + 15 cold, Zipf 파일 분포. 풀이 편중을 흡수하는가 | 정적 분할은 빌드 변형 필요 |
| (d) **단일 전역 로그 대비** | 같은 워크로드를 **ext4 `data=journal`**(`ext4-dj`, 하네스에 있음)로. 파일별 독립 커밋+풀 vs jbd2 전역 로그 | #250 에서 재측정 필요 |

(d) 가 이 절의 주인공이다. §0 의 ext4-dj 비교(1.84~2.51x)는 구세대 하네스라 재측정한다.
1 GB 데드락과 XFS 굶김은 결함이 아니라 **풀이 바닥났을 때의 경계**로 §6 에 넣는다.

### 4.3 빌드 변형 (사용자 빌드 필요)

fast path 제거 · XFS 완료 훅(진단 문서 A1) · 체크포인트 IO 에 `PG_writeback`(A2) ·
commit-time delalloc on/off · `TAU_COMMIT_WORKERS_MAX` / `TAU_CHCKPT_WORKERS_MAX`.
각각 예측을 먼저 적고 돌린다. A1 은 XFS 처리량 격차의 원인이므로 우선.

---

## 5. 필요한 하네스 작업 (커널 X)

| 작업 | 절 | 공수 |
|---|---|---|
| `tauoverwrite` 보호 방식 모드 + 스레드 축 | 1.1, 1.5 | 2~3 일 |
| `cell242.sh` `THREADS` · `synchronous_commit` 파라미터 | 2.2, 2.3 | 반나절 |
| `seg_free` 1 초 샘플러 | 4.2(b) | 반나절 |
| 파일 편중 워크로드(sysbench 대신 `tauoverwrite` 다중 파일 or 커스텀) | 4.2(c) | 2 일 |
| `db-crash-test.sh` 호스트 파일 디스크 + QEMU 플래그 | 3.3 | 2~3 일 |
| ACE 테스트 생성 + 실행 스크립트 | 3.2 | 1~2 일 |
| `ext4-dj` 를 `cell_xfs.sh` 계열 드라이버에 추가 | 4.2(d) | 반나절 |

---

## 6. 실행 순서

1. **2.2 + 2.3** (메커니즘 분리) — 셀 몇 개, 하네스 반나절. 논문 인과 주장의 핵심.
2. **4.2(d)** ext4-dj 재측정 — 설계 대비의 주인공.
3. **1.2 + 1.3** — 도구 있음. append 하한과 fsync 에포크 검증.
4. **3.3 + 3.2 + 3.4** — 정합성 표 완성.
5. **1.1 + 1.5** — 도구 작업 후.
6. **4.2(a)(b)(c)**, **4.1** 나머지.
7. 4.3 은 빌드마다 별도.

1·2·3 은 서로 독립이라 병렬 가능(장치는 하나라 순차 실행).
