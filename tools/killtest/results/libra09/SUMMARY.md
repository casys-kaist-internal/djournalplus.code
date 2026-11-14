# QEMU kill 테스트 요약 — libra09, 2026-10-03 ~ 11-14

> `tools/killtest`로 libra09에서 돌린 실험 전부의 요약이다. 실험별 분석(`ANALYSIS.md`)과
> 실행 기록(`run.json`, `trials.jsonl`, `summary.txt`, 로그, 스크립트)은 libra09의
> `tools/killtest/results/libra09/<날짜_주제>/`에만 있다(§6). 방법과 크래시 모델은
> [`../../README.md`](../../README.md). **비율은 이 환경의 숫자다** — 같은 하네스로도
> 환경이 바뀌면 0–30%를 오간다(§3.1). τJournal 행은 §3.13(#1980)과 §3.14(최종 커널 #1982)다.
> 논문 수치는 §3.11의 x100 캠페인이다(libra09의
> `bench/workspace/results/libra09/paper/motivation/killtest_db_x100/`에 사본과 README).

## 0. 결론

1. **4 KiB가 원자 단위인 장치에서 ext4·xfs는 크래시 뒤 DB 페이지가 찢어지고, DB 복구가
   실패한다** (FPW/DWB off). 무작위 시각 kill 262번 중 44번(17%). 장치에 쓰기가 16개
   이상 걸린 순간의 kill은 49번 중 18번(37%)이 찢어졌다.
2. **ZFS는 데이터를 `logbias=throughput`으로 두면(OpenZFS 권장 구성) 찢어지지 않았다**:
   0/40, 쓰는 도중의 kill 17번 포함(ext4·xfs 대비 p = 0.0015). 기본값(latency)에선 ZIL이
   쓰기를 로그 블록 경계에서 바이트 단위로 나눠 찢어진다(마이크로 3/100, MySQL 2/20;
   openzfs/zfs#17879, 2.4.4·master에도 그대로).
3. **ext4 data=journal도 16 KiB를 원자적으로 쓰지 못한다** — 4 KiB 페이지마다 저널 핸들을
   잡아 커밋이 그 사이에 끼면 한 쓰기가 두 트랜잭션으로 갈린다(마이크로 22–34%, MySQL
   4/20).
4. **찢어짐은 장치 요청 분할(4 KiB)에 묶여 있다.** 분할을 없애면 MySQL ext4가 7/20 →
   1/20, kill 순간 쓰기가 0개였던 경우의 찢어짐은 16/55 → 0/18(§3.9). 장치 모델의
   가정(원자 단위 4 KiB)은 실제 장치의 규격 보장(PM1735·990 PRO는 512 B)보다 후하다.
5. PostgreSQL이 MySQL보다 덜 찢어진다(ext4 9% 대 30%): 8 KiB 페이지는 4 KiB 요청
   둘이라 경계가 하나다. 쓰기를 늘려도 거의 변하지 않았다.

| 실험 | 무엇 | 결과 |
|---|---|---|
| 3.1 파일럿 (10-03) | 마이크로벤치 900 trial, SOSP 재현 | ext4-dj 22–34%로 SOSP와 같음. xfs 4–10%, ext4 14–32%는 SOSP와 다름 |
| 3.2 DB, SOSP 절차 (10-04) | 61 s 고정 kill, 20회씩 | ext4·xfs 0–2/20. MySQL ext4-dj 4/20, zfs-16k 2/20 |
| 3.3 zfs-16k 마이크로 (10-04, 10-06) | logbias latency 대 throughput | 3/100 대 0/75 |
| 3.4 writeback 중 kill (10-04) | 쓰기 64개 이상일 때 kill, 10회씩 | MySQL ext4 9, xfs 4, PG ext4 6, xfs 6 (/10) |
| 3.5 무작위 kill (10-05) | 2.5 GB VM, 무작위 시각 | uniform 31/182 (17%) |
| 3.6 설정 탐색 (10-06) | 워크로드·스레드·캐시·체크포인트 | 기존보다 나은 것 없음 |
| 3.7 기본 로그 크기 (10-06) | **유지 설정** | 13/80 (16%) |
| 3.8 ZFS 분리 구성 (10-07) | 같은 설정, ZFS | 0/40 |
| 3.9 4 KiB 분할 없이 (10-07) | MySQL ext4 | 1/20 (분할 있을 때 7/20) |
| 3.11 x100 캠페인 (10-10 ~ 10-14) | §2 설정, 게스트 6.8.0-base+, config당 100회 | MySQL ext4 54, xfs 32, ext4-dj 12, ZFS 0; PG ext4 15, xfs 15, ext4-dj 6, ZFS 0 (/100) |
| 3.12 EXT4_App x100 (11-04 ~ 11-05) | 3.11 ext4와 같고 보호만 켬(PG FPW, MySQL doublewrite) | 찢어짐 MySQL 3, PG 4 (/100) — 모두 복구됨, 재시작 실패 0 |
| 3.13 τJournal #1980 (11-06 ~ 11-07) | 3.11 설정, FS만 τ-ext4·τ-xfs, 20회씩 | 0/84 (smoke 포함) |
| 3.14 τJournal 최종 #1982 (11-11, 11-13 ~ 11-14) | 3.13과 같고 최종 커널·(가) 설정, config당 100회 | MySQL τ-ext4 0, τ-xfs 0; PG τ-ext4 0, τ-xfs 0 (/100), 재시작 실패 0 |

## 1. 도구와 크래시 모델

Yewon Choi의 `taujournal-test.code`(SOSP §2.2 Table 1 실험)를 이식했다. trial 하나:
이미지 복사 → VM 부팅(게스트 6.8.0+, 테스트 디스크는 호스트 파일 위 에뮬레이트 NVMe,
`cache=writeback`, `max_sectors_kb=4`) → 워크로드 → QEMU SIGKILL → 재부팅·마운트(복구) →
검사. 마이크로벤치는 `fs.c`(32 스레드 × 16 KiB `pwrite` + fsync)로 청크마다 전부 옛 값/
전부 새 값인지, DB는 PostgreSQL 17.5(`--data-checksums`)·MySQL 8.4.5에서 sysbench를 돌리고
복구 성공 여부와 오프라인 페이지 검사(`innochecksum`, `pgscan`)를 복구 전후로 본다.

- 완료된 쓰기는 모두 남는다(호스트 페이지 캐시). 진행 중이던 요청만 잃는다(원자 단위
  4 KiB). 휘발성 캐시의 유실·재배열(Torner의 모델 R)은 생기지 않는다.
- kill 시점: `time`(고정), `writeback`(게스트 감시 프로그램 `ktwatch`가 쓰기 K개 이상이
  걸린 순간 요청), `random`(호스트가 무작위 시각에, 감시 프로그램은 그 순간 상태만 기록),
  `checkpoint`(PG 체크포인트 시작 뒤 무작위).
- 게스트의 kill 요청은 ivshmem 공유 페이지로 보낸다. I/O 포트로 보내면 QEMU의 BQL 때문에
  NVMe 배치가 다 쓰인 뒤에야 도착해 하나도 찢어지지 않았다(§3.4).

## 2. 유지 설정 (2026-10-06)

```
killtest.py db --db <mysql|postgres> --fs <ext4|xfs|zfs-8k|zfs-16k> --profile revision \
    --mem 2560M --rand-type uniform --log-default --kill-on random --run-s 300 \
    --trials N --seed S
```

VM 2.5 GB(데이터 4.4 GB는 메모리의 1.9배 — 성능 실험 호스트와 같은 비율), 캐시 640 MB
(메모리의 25%), oltp_write_only 32 스레드, 300 s run의 30–270 s 균등 무작위 kill, DB 기본 로그
크기(MySQL redo 100 MB, PG `max_wal_size` 1 GB), FPW/DWB off, MySQL `flush_method=fsync`·
binlog off, ZFS는 데이터 `logbias=throughput`과 WAL/redo dataset(`zfspool/log`, latency, 128K).
설정으로 writeback을 강제하거나 kill 시점을 노리는 방식은 주 결과로 쓰지 않는다.

## 3. 실험별

### 3.1 파일럿 — 마이크로벤치, SOSP 재현 (10-03)

15개 실행, 900 trial(torn 143). 도구는 끝까지 돌았다(setup·mount 실패, 패닉, 검증 오류 0).

| fs | 여기 (실행별) | SOSP 로그 |
|---|---|---|
| ext4 data=journal | 22/100, 12/50, 13/50, 17/50 (22–34%) | 29/100, 30/100, 61/100 |
| xfs | 5/100, 2/50, 2/50, 5/50, 2/50, 2/50 (4–10%) | 24/100, 32/100 |
| ext4 | 22/100, 16/50, 9/50, 7/50, 7/50 (14–32%) | 0/100 ×3, 1/100 |

- data=journal은 SOSP와 모양까지 같다: 찢어진 청크는 전부 "앞 4/8/12 KiB만 새 값" —
  다른 스레드의 fsync가 연 커밋이 16 KiB 쓰기 도중에 트랜잭션을 닫은 경우다(Torner가 찾은
  FLUSH 사이 분할과 같다).
- xfs·ext4는 차이를 SOSP 쪽으로 하나씩 맞춰도(QEMU 7.2.1 → 9.2.4, 장치 16 → 8 GiB, WBT
  on → off, SOSP의 mkfs geometry) 비율이 움직이지 않았다. ext4는 kill 시점의 진행량까지
  같은데 SOSP는 0/100, 여기는 14–18%였다. kill 방식의 비율은 하네스 밖 환경(커널 빌드,
  사용자 공간, 호스트 저장장치)에 따라 움직인다 — "N번 죽여서 M%"의 약점.

### 3.2 DB, SOSP 절차 (10-04)

SOSP 커밋의 bench 설정(32 테이블 × 50만 행, oltp_write_only 32 스레드, PG
`max_wal_size=2GB`, MySQL 버퍼 풀 16G), 300 s 에이징 이미지, 측정 run 61 s에 kill, 20회씩.

| | ext4 | xfs | ext4 data=journal | ZFS |
|---|---|---|---|---|
| PostgreSQL | 1/20 | 2/20 | 0/20 | 0/20 (zfs-8k) |
| MySQL | 0/20 | 1/20 | **4/20** | **2/20** (zfs-16k) |

- ext4·xfs가 드문 것은 고정 시각이 데이터 페이지 버스트(0.3–1 ms) 안에 떨어지는 일이
  드물어서다. SOSP 로그도 같았다.
- MySQL data=journal: ext4는 data=journal에서 O_DIRECT를 끄고 버퍼드 쓰기로 바꾸는데,
  16 KiB 쓰기가 4 KiB 페이지마다 저널 핸들을 잡아 §3.1과 같은 모양으로 찢어진다.
- MySQL ZFS: ZIL의 바이트 단위 분할(§3.3)과 같은 경로로 본다.
- PG의 찢어진 trial은 모두 redo가 그 페이지를 읽다 `invalid page` → FATAL. MySQL은 복구 중
  찢어진 페이지에서 멈춰 기동을 끝내지 못한다(이후 `--db-giveup-s 60`으로 60 s 뒤 포기).
  에이징 TPS는 data=journal이 절반 이하(PG 1380 대 6795, MySQL 767 대 1462).

### 3.3 zfs-16k 마이크로벤치 — logbias (10-04, 10-06)

- **latency(기본값) 3/100**: 찢어진 세 청크의 분할 지점이 바이트 단위다(16 KiB 중 앞
  12752, 14664, 15512 바이트만 새 값). fsync 없는 16 KiB 쓰기는 ZIL에 `WR_NEED_COPY`로
  기록되고 `zil_lwb_assign()`이 레코드를 로그 블록 경계에서 바이트 단위로 나눈다.
  재생은 레코드 단위라 앞 조각만 남은 로그가 쓰기의 일부를 되살린다. OpenZFS 문서의
  "ZFS will never commit a partial write"와 어긋난다.
- **throughput 0/75**: kill을 150·300·500 ms(덮어쓰기 도중, 새 청크 21·46·80%)에 떨어뜨린
  75번 모두 청크가 통째로 옛것이거나 새것이었다(95% CI 0–4.9%). 데이터가
  `WR_INDIRECT`로 블록째 쓰이면 분할이 없다. 800 ms와 10-04의 1000 ms는 덮어쓰기가 끝난
  뒤라 무효.
- 이 결과로 성능 스크립트와 리비전 프로필의 ZFS를 "데이터 throughput, WAL/redo 분리"로
  바꿨다(§3.8).

### 3.4 writeback 중 kill — 리비전 설정 (10-04)

리비전 설정(캐시 = VM 32 GB의 25%, WAL/redo 16 GB, MySQL fsync, binlog off; 데이터가 캐시에
다 들어감)에서, 무장 뒤 쓰기 64개 이상이 걸린 첫 순간 kill. 10회씩.

| | MySQL ext4 | MySQL xfs | PG ext4 | PG xfs |
|---|---|---|---|---|
| writeback 중 kill | **9/10** | **4/10** | **6/10** | **6/10** |
| SOSP 절차 (§3.2) | 0/20 | 1/20 | 1/20 | 2/20 |

- 감시만 한 보정 run: 데이터 페이지는 4 KiB 요청 64–127개가 0.3–1 ms 걸리는 버스트로
  나간다(MySQL 16페이지 flush 배치 + fsync, PG 체크포인트의 256 kB `sync_file_range`;
  초당 30여 번). 로그(WAL·redo) 쓰기는 대부분 32개 미만, 300 µs 미만. 그래서 K = 64.
- 찢어진 trial은 전부 DB가 스스로 발견했고(trial당 1페이지, PG ext4 한 번 2페이지),
  오프라인 검사가 복구 전후로 같은 페이지를 잡았다.
- kill 요청 경로: I/O 포트(isa-debugcon)로는 0/5 — 포트 접근은 BQL을 잡고, NVMe 에뮬레이션은
  BQL을 쥔 채 제출 큐를 통째로 스레드 풀에 넘긴다. ivshmem 공유 페이지로 바꾸자 3/3.
- 데이터 페이지 writeback 순간을 노린 kill이라 "존재 증명"으로만 쓸 수 있다는 판단으로,
  이후 무작위 시각 kill로 바꿨다.

### 3.5 무작위 시각 kill, 2.5 GB VM (10-05)

kill 시점은 고르지 않고, 데이터 페이지 writeback이 run 내내 일어나는 환경을 만든다: VM을
2.5 GB로 줄이면 데이터가 메모리의 1.9배, 캐시의 7.5배가 된다(성능 실험 호스트와 같은 비율).
장치에 64개 이상 걸린 시간 비율이 32 GB 1.3–1.4% → 4 GB 7.5% → 2.5 GB 9–13%.

| | MySQL ext4 | MySQL xfs | PG ext4 | PG xfs | 합계 |
|---|---|---|---|---|---|
| special (sysbench 기본), 20회 | 0 | 5 (+검사만 2) | 2 | 0 | 7/80 |
| uniform, 20회 | 5 | 3 | 3 | 3 | 14/80 |
| uniform, +25회 (x100의 1라운드, 중단) | 8 (+2회 0) | 2 (+검사만 1) | 2 | 4 | 17/102 |
| **uniform 합계** | **13/47 (28%)** | **6/45 (13%)** | **5/45 (11%)** | **7/45 (16%)** | **31/182 (17%)** |

uniform 합계, kill 순간 걸린 쓰기별(찢어짐/trial):

| | 0 | 1–15 | 16–63 | 64+ |
|---|---|---|---|---|
| MySQL ext4 | **11/38** | 2/4 | 0/2 | 0/3 |
| MySQL xfs | 1/37 | 2/4 | 1/1 | 2/3 |
| PG ext4 | 1/31 | – | 1/4 | 3/10 |
| PG xfs | 2/30 | – | 0/4 | 5/11 |

- uniform(성능 실험의 민감도 변형과 같다)은 데이터 전체를 고르게 건드려 쓰기가 늘었다.
- MySQL ext4는 대부분 쓰기 0개일 때, trial마다 여러 페이지(1–14)가 찢어졌다. 이것은 4 KiB
  요청 분할에 묶인 현상이다(§3.9, §4).
- "검사만 잡은" 경우: InnoDB는 첫 redo 레코드가 페이지 초기화(`MLOG_INIT_FILE_PAGE`)인
  페이지를 새 페이지로 보고, 찢어져 있어도 0으로 채운 뒤 redo로 다시 만든다
  (`recv_page_is_brand_new`). 테이블 끝에 새로 붙은 페이지라 DB는 멀쩡하다. PG에선 없었다.

### 3.6 설정 탐색 (10-06)

§3.5 uniform 설정에서 하나씩 바꿨다. 어느 것도 기존보다 찢어짐을 잘 드러내지 못했다.

| 바꾼 것 | 결과 |
|---|---|
| 워크로드 update_index / update_non_index, 64 스레드 (감시만) | 쓰기가 write_only보다 많지 않음. MySQL update_index 무작위 kill 1/8에서 중단 |
| 64 스레드 (감시만) | MySQL은 오히려 느려짐(48 대 77 MiB/s), PG는 쓰기 +17% |
| 캐시 128 MB (두 DB의 기본값) | MySQL 7/20 (쓰기는 줄어 60 MiB/s), **PG 0/20** (쓰기는 늘어 182 MiB/s) |
| PG 체크포인트 중 kill (시작 0–240 s 뒤) | ext4 1/20 |

- PG는 쓰기를 늘려도 덜 찢어졌다: PG의 찢어짐은 쓰기량이 아니라 kill이 장치에 쓰는 순간에
  떨어지느냐에 달려 있다.
- 체크포인트가 쓰는 양은 적다(141 s에 4,115 버퍼, 5%) — 데이터가 캐시보다 훨씬 커서 dirty
  버퍼 대부분은 백엔드가 축출하며 쓴다. 체크포인트를 노릴 이유가 없다.
- `checkpoint_flush_after=0` 등 설정으로 writeback을 바꾸는 시도는 1회에서 멈췄다.

### 3.7 DB 기본 로그 크기 — 유지 설정 (10-06)

WAL/redo를 16 GB → DB 기본값으로(16 GB는 4.4 GB DB보다 컸다). 쓰기 부하는 그대로였다:
MySQL 77 → 81 MiB/s, PG 149 → 150 MiB/s, ≥64 비율 5.5 → 4.6%, 22.6 → 23.0%. PG는 1 GB에서
WAL 조건 체크포인트가 run 시작 ~140 s 뒤부터 연달아 돈다.

| | 기본 로그, 20회 | 16 GB (§3.5) | 합계 | 95% CI |
|---|---|---|---|---|
| MySQL ext4 | 7 | 13/47 | **20/67 (30%)** | 20–42% |
| MySQL xfs | 5 | 6/45 | **11/65 (17%)** | 10–28% |
| PG ext4 | 1 | 5/45 | **6/65 (9%)** | 4–19% |
| PG xfs | 0 | 7/45 | **7/65 (11%)** | 5–21% |
| 합계 | 13/80 (16%) | 31/182 (17%) | **44/262 (17%)** | 13–22% |

기본 로그 20회, kill 순간 걸린 쓰기별: MySQL ext4 0개 5/17, 1–63개 2/2, 64+ 0/1; MySQL xfs
0개 0/15, 16–63개 1/1, **64+ 4/4**; PG ext4 0개 1/16, 64+ 0/3; PG xfs 0개 0/17, 64+ 0/1.

- MySQL xfs는 쓰는 도중의 kill이 모두 찢어졌다(16 KiB = 4 KiB 요청 넷, flush 배치는 데이터
  페이지뿐).
- PG xfs 0/20은 kill이 64+에 걸린 경우가 1번뿐이었던 탓으로 본다(점유율로 ~4번 기대, 1번
  이하일 확률 ~7%).

### 3.8 ZFS — 데이터 throughput, WAL/redo 분리 (10-07)

§3.7과 같은 설정. 풀은 `recordsize`=DB 페이지·`compression=off`·`logbias=throughput`, 그리고
`zfspool/log`(128K, latency)에 PG `pg_wal`(initdb `--waldir`)·MySQL redo
(`innodb_log_group_home_dir`). trial마다 속성을 기록해 확인했다. OpenZFS 2.2.11.

| | 쓰기 (감시) | ≥64 / ≥8 | 찢어짐 | 걸린 쓰기 0 / 1–15 / 16–63 / 64+ | 복구 중앙값 |
|---|---|---|---|---|---|
| PG zfs-8k | 284 MiB/s | 2.1% / 46.7% | **0/20** | 0/7, 0/1, **0/12**, – | 45 s |
| MySQL zfs-16k | 184 MiB/s | 8.0% / 32.2% | **0/20** | 0/15, –, 0/3, 0/2 | 9 s |

- ZFS는 ext4의 두 배쯤 쓰고 16–63개 버스트가 많다. 장치에 16개 이상 걸린 순간의 kill이
  17번 있었고 모두 깨끗했다(ext4·xfs는 같은 순간 18/49, p = 0.003).
- 0/40의 95% 상한은 8.8%. 100회씩이면 3.7%.

### 3.9 4 KiB 요청 분할 없이 — MySQL ext4 (10-07)

§3.7의 MySQL ext4에서 `max_sectors_kb`만 장치 기본값(512 KiB)으로.

| | 4 KiB 분할 | 분할 없음 |
|---|---|---|
| 찢어짐 | 7/20 (35%) | **1/20 (5%)** (p = 0.044) |
| kill 순간 쓰기 0개 | 5/17 (10-05 이후 16/55) | **0/18** (p = 0.008) |

- 남은 한 번은 233개가 걸린 1 ms 버스트 안이었다(페이지 2개). QEMU는 요청을 버퍼드
  `pwrite`로 쓰고 호스트 커널은 그것을 페이지 단위로 복사하므로, 그 사이에 SIGKILL이 떨어지면
  일부만 남을 수 있다(확인 안 함).
- 쓰기 0개 torn도 분할에 묶인 현상이다. 나머지 조각이 장치에 닿기 전 어디서 기다리는지는
  확인하지 못했다.

### 3.10 중단한 실행

설정을 바꾸기로 해서 멈춘 세 개(libra09의 `99_Archive`): MySQL ext4 update_index 무작위 kill
8회(1 찢어짐), PG ext4 `checkpoint_flush_after=0`·`bgwriter_flush_after=0` 1회, PG xfs 체크포인트
중 kill 0회.

### 3.11 x100 캠페인 — config당 100회 (10-10 ~ 10-14)

§2 설정에서 바꾼 것: 게스트 커널을 성능 실험의 `6.8.0-base+`(aio·jbd2 수정 포함)와 호스트
모듈로(OpenZFS 2.2.2), MySQL native AIO를 ZFS에서도 켬. 테스트 디스크는 모든 config에서 루트
SATA 위 파일, ZFS golden 이미지만 PM1753(`--image`). 20회씩 5라운드(ZFS는 7라운드 중 SATA 5개),
config를 번갈아, 시드는 라운드·config마다 고정(`scripts/db100*.sh`). 집계 `scripts/tally.py`:

| config | trials | 찢어짐 (95% CI) | 그중 DB 재시작 실패 | 그중 재시작됨 |
|---|---|---|---|---|
| MySQL ext4 | 100 | 54 (44–64%) | 54 | 0 |
| MySQL xfs | 100 | 32 (23–42%) | 32 | 0 |
| MySQL ext4 data=journal | 100 | 12 (6–20%) | 10 | 2 |
| MySQL ZFS | 100 | 0 (0–4%) | – | – |
| PostgreSQL ext4 | 100 | 15 (9–24%) | 14 | 1 |
| PostgreSQL xfs | 100 | 15 (9–24%) | 15 | 0 |
| PostgreSQL ext4 data=journal | 100 | 6 (2–13%) | 6 | 0 |
| PostgreSQL ZFS | 100 | 0 (0–4%) | – | – |

- 재시작 실패는 모두 찢어짐과 함께 났고, 실패한 시도의 DB 로그에는 전부 찢어진 페이지 오류가
  있다: MySQL `Database page corruption on disk`(MY-011906, 복구 2–8 s 만에) 뒤 91/96은 멈춰
  60 s 뒤 포기, 5/96은 InnoDB assertion으로 종료; PostgreSQL은 `invalid page in block` 뒤 스스로
  종료(35/35). 600 s 제한에 걸린 것은 없고, 재시작된 MySQL 복구는 최대 16 s.
- 재시작된 찢어짐 3건(PG ext4 1, MySQL data=journal 2)은 복구 전 검사에서만 찢어진 페이지가
  보였고, 복구가 그 페이지를 다시 썼다.
- ZFS 3–4라운드는 시도별 테스트 디스크까지 PM1753에 둔 채 돌았다(`KILLTEST_WORK`). 게스트 I/O가
  달라져(쓰기 64개 이상 걸린 시간 7% → 32%(MySQL), 1% → 58%(PG)) 민감도로 따로 둔다: 0/40, 0/40.
- MySQL이 §3.7(바닐라 6.8.0+)보다 많이 찢어진다(ext4 30% → 54%, xfs 17% → 32%, 모든 라운드에서).
  PostgreSQL은 그대로. native AIO와 커널의 aio 수정이 걸린 차이로 보이나 확인하지 않았다.

### 3.12 EXT4_App x100 — 보호를 켠 대조군 (11-04 ~ 11-05)

§3.11의 ext4 행과 같은 설정·같은 golden 이미지에서 DB의 찢어진 페이지 보호만 켰다(EVAL_PLAN
§6.2 T2b의 EXT4_App 행): PostgreSQL `--pg-set full_page_writes=on`, MySQL `--my-set
innodb-doublewrite=1`. 복구 기동을 포함한 모든 기동에 적용되고, 실행 중 서버에서 읽은 값으로
확인했다(`db_vars`). 호스트·게스트 모두 6.8.0-base+, 20회씩 5라운드, 시드 20261900+10·라운드+{0,1}
(`2026-11-03_db_app_x100/scripts/dbapp.sh`, README):

| config | trials | 찢어짐, 복구 전 (95% CI) | 재시작 실패 또는 복구 후 손상 | 복구 시간 중간값 (최대) |
|---|---|---|---|---|
| MySQL ext4, doublewrite 켬 | 100 | 3 (1.0–8.5%) | 0 (0–3.7%) | 17.0 s (20.0) |
| PostgreSQL ext4, FPW 켬 | 100 | 4 (1.6–9.8%) | 0 (0–3.7%) | 7.3 s (10.3) |

- 찢어진 7건은 모두 재시작했고, 복구 후 검사가 깨끗하다: doublewrite·full-page image가 그 페이지를
  다시 썼다. §3.11의 보호를 끈 ext4는 찢어진 시도가 거의 모두 재시작에 실패했다(MySQL 54/54,
  PG 14/15).
- 찢어짐 비율 자체도 낮다(MySQL 54 → 3%, PG 15 → 4%). 보호가 쓰기 모양(doublewrite 배치,
  WAL의 페이지 이미지, 낮은 처리량)을 바꾸므로, 비교할 것은 비율이 아니라 결과(페이지가 온전한
  재시작)다.
- 복구 시간: PostgreSQL은 FPW를 켜면 9배 빠르다(7.3 대 64 s, 페이지 이미지가 없으면 WAL 레코드마다
  페이지를 장치에서 읽는다). MySQL은 17 s(보호를 끈 성공 재시작 8 s).

### 3.13 τJournal — §3.11 설정, 구성당 20회 (11-06 ~ 11-07)

§3.11과 같은 설정에서 FS만 τ-EXT4·τ-XFS로 바꿨다. DB 보호는 끈 채다.
- FS 구성(killtest.py DBFSCONF, f4f40f1):
  - 게스트에서 포크 mkfs를 쓰고 베이스라인과 같은 FS 기능으로 만든다(ext4는 rootfs의 stock
    mke2fs.conf, xfs는 `-i nrext64=0`).
  - 마운트: ext4 `tjournal,tjournal_size=32`, xfs `tjournal`.
  - DB 빌드는 데이터 파일을 O_TAU_ATOMIC으로 연다.
- 커널: 게스트는 τ 트리의 #1980(new_main a6d55fe7)이다. 호스트도 #1980이다(베이스라인 행의 호스트는
  6.8.0-base+, 호스트는 하이퍼바이저일 뿐).
- golden 이미지: smoke(`2026-11-06_db_tau_smoke`, 구성당 1회)가 #1980에서 만들었고 PM1735
  `/mnt/recidem/killtest`에 둔다(`--image`, c4b695f). τ 저널이 들어 있어 11–24 GB다.
- 일정: smoke 4회가 모두 clean일 때만 본 실행으로 넘어간다(`scripts/dbtau_chain.sh`). 시드는
  20262010+i(`2026-11-06_db_tau/scripts/dbtau.sh`, README).

| config | trials | 찢어짐 (95% CI) | 재시작 실패 | 복구 시간 중간값 (최대) |
|---|---|---|---|---|
| MySQL τ-EXT4 | 20 (+smoke 1) | 0 (0–16.1%) | 0 | 8.0 s (9.0) |
| PostgreSQL τ-EXT4 | 20 (+1) | 0 (0–16.1%) | 0 | 53.2 s (70.1) |
| MySQL τ-XFS | 20 (+1) | 0 (0–16.1%) | 0 | 7.0 s (8.0) |
| PostgreSQL τ-XFS | 20 (+1) | 0 (0–16.1%) | 0 | 42.3 s (68.7) |

- 84회 모두 clean이다. 기록된 커널 줄에도, 남긴 콘솔에도 WARNING/BUG/lockup 줄이 없다.
- 쓰기 16개 이상이 걸린 채 죽인 시도: PG τ-ext4 6, PG τ-xfs 7, MySQL τ-xfs 2. 그래도 찢어진 페이지는
  없었다.
- FS를 합치면 DB마다 0/42다. §3.11의 PostgreSQL 비율 15%에서 0/42가 나올 확률은 0.1%다.
- MySQL 시도 40회 중 34회에서 τ 재생이 `TAU: invalid block ... expected magic` 류를 남긴다. kill 때
  쓰던, 커밋되지 않은 트랜잭션을 버리는 메시지다(recovery.c).
- 이 VM에서 golden 이미지 aging 처리량은 §3.11 이미지의 약 절반이다(MySQL 581/565 대 1306/1399 tps,
  PG 1790/1818 대 3508/3517). 호스트 커널과 디스크 경로가 달라 성능 비교로 쓰지 않는다.
- 최종 τ 커널 #1982에서 golden 이미지부터 다시 돌렸다: §3.14.

### 3.14 τJournal — 최종 커널 #1982, config당 100회 (11-11, 11-13 ~ 11-14)

§3.13을 최종 τ 커널 #1982(81f4707b)에서 다시 돌리고 config당 20회를 100회로 늘렸다(11-13 사용자
선택 (a), tau-ops 전달). §3.13과 다른 점:
- τ 구성은 (가)다: 세그먼트 16 MiB, 상한 32 GiB.
  - ext4 `tau_segsize=16m`, xfs `-l tjsegsize=16m,tjmaxsize=32G`.
  - `tau_shrink_seeks`는 #1982 기본값 32다.
  - §3.13은 세그먼트가 128 MiB 기본값이었다.
- 호스트는 베이스라인 행처럼 6.8.0-base+ #3이다(host_setup.sh 적용). 게스트는 #1982 bzImage와 호스트의 #1982
  모듈이다.
- golden 이미지가 두 벌이라, config마다 100회가 두 이미지에 20 + 80으로 나뉜다.
  - 1회차(20회): 11-11 smoke가 만든 1벌. A단계가 PM1735를 다시 쓰면서 사라졌다.
  - 2–5회차(80회): 11-13 smoke가 새로 만든 2벌.
  - 두 벌의 aging 처리량과 크기는 거의 같다(MySQL 595–621 tps, PG 2,433–2,453 tps).
- 일정은 `final_tau/phaseB.sh`의 killsmoke와 killtest다. killsmoke는 config당 1회이고, 모두 clean일 때만
  다음으로 넘어간다.
  - 시드: 20262000+10·회차+i.
  - 1회차: 11-11 04:52–11:32 UTC(`2026-11-11_db_tau_1982`).
  - 2–5회차: 11-13 08:50 ~ 11-14 10:27 UTC, 시도당 4.8분(`2026-11-13_db_tau_1982`).
  - 두 폴더에 README가 있다.

| config | trials | 찢어짐 (95% CI) | 재시작 실패 | 복구 시간 중간값 (최대) |
|---|---|---|---|---|
| MySQL τ-EXT4 | 100 (20 + 80, +smoke 2) | 0 (0–3.7%) | 0 | 7.0 s (9.0) |
| PostgreSQL τ-EXT4 | 100 (+2) | 0 (0–3.7%) | 0 | 54.5 s (80.1) |
| MySQL τ-XFS | 100 (+2) | 0 (0–3.7%) | 0 | 7.0 s (9.0) |
| PostgreSQL τ-XFS | 100 (+2) | 0 (0–3.7%) | 0 | 43.9 s (75.9) |

- **400회 모두 clean이다.** run 20개가 모두 clean=20이다.
  - 남긴 콘솔과 각 시도의 게스트 커널 로그에 WARNING:/BUG:/Oops/GP/soft lockup/hung_task/Call Trace 줄이 없다.
  - 11-13 부팅 뒤 호스트 journal에도 없다.
- FS를 합치면 DB마다 0/200(95% CI 0–1.9%), 전체는 0/400(0–0.95%)이다. §3.11의 PostgreSQL 비율 15%에서
  config 하나가 0/100일 확률은 약 9×10⁻⁸이다.
- 쓰기 16개 이상이 걸린 채 죽인 시도(괄호는 64개 이상): PG τ-ext4 31(20), PG τ-xfs 32(17), MySQL τ-ext4 12(7),
  MySQL τ-xfs 11(6).
- 복구 메시지는 §3.13과 같은 종류다.
  - 로그 끝의 `invalid block ... expected magic`이 400회 중 175회 나온다.
  - 커밋되지 않았거나 호스트 저널에 내구화되지 않은 트랜잭션을 빼는 pr_warn들도 나온다.
  - #1982에서 처음 보인 것은 `tail N not in the journal, replaying from M` 하나다(가장 오래된 트랜잭션부터
    재생). 1회차에 1번, 2–5회차에 5번 나왔다.
  - libra08:develop은 11-14에 이 줄을 정상 경로로 판단했다(t006의 복구 로그로 확인).
    - 가장 새 record의 tail 트랜잭션이 이후 체크포인트로 빠지고, 그 세그먼트가 flush 뒤 반납됐다. 그다음 새
      record가 쓰이기 전에 kill된 경우다.
    - 그래서 빠진 트랜잭션의 데이터는 이미 홈에 있다.
    - 16 MiB 세그먼트는 128 MiB보다 약 8배 자주 반납돼서 #1982에서만 보였다.
    - 커널 수정은 없다. warn을 info로 낮출지는 사용자가 정한다.
  - `stopping replay`는 없다.

## 4. 정정

- 10-05·06의 분석은 MySQL ext4의 쓰기 0개 torn을 "커널 writeback이 16 KiB 페이지의 4 KiB 조각
  일부만 내보내고 나머지를 페이지 캐시에 남긴 상태 — 장치와 무관"이라고 설명했다. 분할 없이
  돌리자 사라졌으므로(§3.9) 철회한다. "xfs는 large folio라서 이런 분할이 없다"는 설명도 근거가
  없어 뺐다. 실험별 분석에는 정정 표시를 남겼다.

## 5. 남은 일

- ~~τJournal을 §2 설정으로~~: §3.13에서 #1980으로 함(84회 모두 clean). §3.14에서 최종 τ 커널 #1982로
  config당 100회를 돌렸다(400회 모두 clean).
  config당 100회와 ext4 data=journal은 §3.11.
- ~~FPW/DWB를 켠 대조군~~: §3.12에서 함(찢어짐 7/200, 모두 복구).
- 쓰기 0개 torn의 정확한 경로(§3.9).

## 6. 실행 기록 (libra09)

`tools/killtest/results/libra09/` 아래, 폴더마다 `ANALYSIS.md`와 `scripts/`가 있다.

| 폴더 | 실행 (UTC 시각) |
|---|---|
| `2026-10-03_pilot` | `20261003_172020` … `213306`, 15개 |
| `2026-10-04_db_sosp` | 8 config × 20회 (+중단 1) |
| `2026-10-04_zfs16k` | `20261004_002948`(latency), `122622`(throughput, 무효), `20261006_013835`·`014327`·`014836`·`015407`(throughput) |
| `2026-10-04_db_writeback` | 보정 `125024`·`131026`·`135150`·`135741`, 포트 `133234`·`140929`, 공유 메모리 `142407`, 파일럿 `143930`·`152847`·`165136`·`175223` |
| `2026-10-05_db_random` | special `20261005_020857`·`033459`·`045415`·`062750`; uniform `101608`·`114910`·`133118`·`145836`; x100 1라운드 `173001`·`193541`·`213729`·`234453`, `20261006_013005`; 보정 run |
| `2026-10-06_db_variants` | `20261006_015956` … `022913`(감시), `030839`·`031424`·`032733`·`044859`(캐시 128 MB), `070143`(체크포인트) |
| `2026-10-06_db_logdefault` | 감시 `104038`·`105555`; kill `110135`·`122934`·`141533`·`155203` |
| `2026-10-07_db_zfs` | 감시 `172547`·`201222`; kill `174238`·`203039` |
| `2026-10-07_db_msk512` | `20261006_231033` |
| `2026-10-10_base_kernel_smoke` | `20261010_120609`(게스트 6.8.0-base+ 확인, MySQL ZFS 1회) |
| `2026-10-10_db_x100` | `20261010_123546` … `20261014_055814`, 45개(첫 PG ZFS `20261010_220036`은 디스크 부족으로 0회); `scripts/db100.sh`·`db100b.sh`·`db100c.sh`·`db100d.sh`, `tally.py` |
| `2026-11-03_db_app_smoke` | `20261103_145718`(PG)·`150131`(MySQL), 1회씩, 이미지 보관해 확인 |
| `2026-11-03_db_app_x100` | `20261104_132538` … `20261105_024626`, 10개; `scripts/dbapp.sh`, README |
| `2026-11-06_db_tau_smoke` | `20261106_114039`·`115424`·`120945`·`122544`, 1회씩(golden 이미지 생성 포함) |
| `2026-11-06_db_tau` | `20261106_124238`·`142510`·`162543`·`180234`, 20회씩; `scripts/dbtau.sh`·`dbtau_chain.sh`, README |
| `2026-11-11_db_tau_1982_smoke` | `20261111_035227`·`040547`·`042037`·`043610`, 1회씩(golden 이미지 1벌 생성) |
| `2026-11-11_db_tau_1982` | `20261111_045231`·`062931`·`082105`·`095100`, 20회씩(1회차); `scripts/dbtau.sh`, README |
| `2026-11-13_db_tau_1982_smoke` | `20261113_075039`·`080354`·`081839`·`083409`, 1회씩(golden 이미지 2벌 생성) |
| `2026-11-13_db_tau_1982` | `20261113_085033` … `20261114_084732`, 16개(2–5회차, 20회씩); `scripts/dbtau.sh`, README |
| `99_Archive` | `20261006_023520`·`065310`·`103503` |

이미지는 `tools/killtest/work/db-<db>-<fs>[-revision[-mem<size>][-logdefault]].img`(gitignore). τ 이미지는
같은 이름으로 PM1735의 `/mnt/recidem/killtest/`에 있다(§3.13). #1982 이미지는 `/mnt/recidem/killtest-1982/`에
둔다(1벌은 A단계가 PM1735를 다시 쓰면서 사라졌다, §3.14).
