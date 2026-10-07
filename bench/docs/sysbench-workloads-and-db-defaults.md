# sysbench OLTP 워크로드 특성과 RDBMS 기본 설정이 tau 성능에 미치는 영향

작성 근거: `bench/scripts/sysbench/*`, `/usr/share/sysbench/oltp_*.lua`(sysbench 1.0.20),
`bench/workspace/results/sysbench/**`의 실측 `.log`/`.spec`/`.iostat` 1,673개 셀.
측정 환경은 PostgreSQL 17.5 / MySQL 8.4.5, DRAM 187 GB, 32 core,
Samsung 980 PRO 500GB(`/dev/nvme0n1`), 데이터셋 152 GB(16 tables x 40M rows).

---

## 0. 요약 (먼저 읽을 4가지)

> **[2026-09-09] 인용할 tau 수치는 §4.19 (커널 #250)뿐이다.** §4.18까지의 tau 셀은
> 전부 `tau_defer_txdirty_cpflush=0` 시절 측정이고, 그 기본값은 #250에서 1로 바뀌었다.
> §4.19는 PG 6 워크로드 18셀 + MySQL 4셀 + **XFS 2 워크로드 6셀**을 한 커널·
> 한 하네스·한 장치에서 덮는다. §4.13의 XFS 매트릭스는 §4.19 (9)가 대체한다.
>
> **[2026-09-07 무효화] `*_tau_trend.sh`에서 나온 tau 셀을 인용하지 말 것 — §4.18.**
> 두 trend 하네스의 `load_db()`가 파일시스템을 마운트한 채로 런에 들어간다. 로드 끝의
> `sync`는 `tau_sync_all()`(커밋만, 체크포인트 없음)까지만 가므로, tau 셀은 로드 백로그가
> 저널에 남은 채 — 32 GB 저널의 78%, `tauvar_force_reclaim` 무릎 위 — 에서 런을 시작한다.
> 152 GB PG에서 **런 쓰기 543.3 GB vs 348.2 GB, tps 96,621 vs 110,226**의 차이를 만든다.
> ext4/xfs 셀은 tau 저널이 없어 백로그도 없으므로 **이 벌점은 tau에만 붙는다.**
> `run_io.sh`/`run_main.sh`는 partclone 복원 후 새로 마운트하므로 `sosp2026/io_main`
> 코퍼스는 영향이 없다. 영향 범위: **§4.11~4.17의 tau 셀 전부.**

1. **워크로드 5+1개**. `run_main.sh`가 도는 것은 5개(`oltp_update_index`,
   `oltp_update_non_index`, `oltp_write_only`, `oltp_delete`, `oltp_insert`)이고,
   `oltp_read_write`는 구세대 `run.sh`/MySQL main 결과에만 남아 있다.
   `parse_sysbench.py`의 정규식이 인식하는 6개가 곧 실제로 측정된 6개다.
2. **sysbench의 ID 분포가 기본값 `special`이다** — 접근의 75%가 ID 범위의 1%에 몰린다.
   즉 152 GB 데이터셋의 실제 hot working set은 **약 1.6 GB**뿐이다.
   이 하나가 아래 모든 설정 민감도를 지배한다.
3. **MySQL에서는 파일시스템이 InnoDB의 I/O 경로를 바꾼다.** `innodb_flush_method`는
   지정되지 않아 InnoDB가 startup 프로브로 정하는데, 프로브가 성공해도 실제 `.ibd` I/O는
   buffered로 떨어지는 조합이 있다(§4.2~4.4). 결과적으로
   **`ext4`/`xfs`/`xfs-cow`만 진짜 O_DIRECT이고, `ext4-tau`/`xfs-tau`/`ext4-dj`/`zfs`는 buffered**다.
   즉 캐시 조건이 두 그룹으로 갈린다 — 어떤 `innodb_buffer_pool_size`도 양쪽에 동시에
   공정하지 않다. 다만 같은 buffered 그룹인 `ext4-dj`와 `zfs-16k`가
   `ext4`(진짜 O_DIRECT)의 0.63~0.65x에 그치므로, **캐시만으로 tau의 우위를 설명할 수는 없다.**
   `ext4-dj`와의 비교(1.84~2.51x)는 캐시가 맞아 그대로 인용 가능하다.
   **[2026-08-22] 통제 실험 완료 — §4.12.** flush_method를 O_DIRECT↔fsync로 바꿔도
   쓰기량은 ±5% 안쪽이라 캐시 교란은 애초에 작았고, `xfs-tau`는 `xfs fpw=on` 대비
   쓰기 −35~38% / 처리량 +11~29%, 무보장 `xfs fpw=off`와는 사실상 동률이다.
   **[2026-08-23 최종 — §4.13에 6 워크로드 x 8 구성 48셀]**
   tau 저널을 양쪽 32 GB(동적 할당이라 비용 없음)로 두면
   두 파일시스템 x 두 워크로드에서 일관된다 — `fpw=on` 대비 쓰기 **0.60~0.67x**,
   처리량 **1.10~1.37x**이고, 무보장 `fpw=off fsync`와는 쓰기 1.00~1.18x / 처리량 0.94~1.01x.
   **[2026-09-09 정밀화 — §4.19 (6)]** "쓰기량은 무감"은 맞다(310.8 vs 316.0, 1.7%).
   그러나 **처리량은 무감하지 않고, 부호가 `doublewrite`에 따라 뒤집힌다** —
   `doublewrite=ON`에서는 O_DIRECT가 +41%, `OFF`에서는 −8%다. 그리고 캐시 교란은
   읽기 축에서 작지 않다: buffered 팔은 읽기 25 GB, O_DIRECT 팔은 130 GB(5.2배)다.
   따라서 MySQL의 **쓰기 비는 단일 값으로, 처리량 비는 범위로만** 인용해야 한다.
   즉 **저널링 비용이 측정 한계 근처다.** (어제 보고한 "ext4-tau 붕괴"는
   저널을 1 GB로 강제한 인공물이었다 — §4.12 (4).)
   진짜 문제는 그 다음이다 — **MySQL의 tau 배수가 버퍼 풀 크기의 함수다**(§4.8):
   `oltp_update_index`가 bp=16 GB에서 fpw=on 대비 **2.33x**, bp=140 GB에서 **1.06x**다.
   DB(146 GB)가 RAM(187 GB)에 통째로 들어가는 게 근본 원인이고,
   해법은 버퍼 풀을 고르는 게 아니라 **`mem=64G`로 RAM을 고정하는 것**이다
   (`run_main.sh` 24~34행에 이미 주석 처리돼 있고, PG 예비 측정 기준 비용 −7%).
4. **모든 tau 측정이 PostgreSQL `shared_buffers = 128MB`(기본값)에서 이뤄졌다.**
   기록된 결과 전체에서 tau 셀 중 `shared_buffers`가 128MB가 아닌 셀은 **0개**다.
   그런데 128MB → 16GB로 올리면 `fpw=off`(tau가 도는 모드)는 최대 **+46%**,
   `fpw=on`(비교 대상)은 **+6~13%**밖에 오르지 않는다.
   → 지금 논문 수치는 tau에 **불리한 쪽으로 치우쳐 있을 가능성이 크다**.

> **결과 디렉터리 규칙**: 이름이 붙은 디렉터리 — `io_main`, `main_all`,
> `io_{fs}_{date}`, `main_{fs}_{date}`, `motivation_*` — 가 canonical이다.
> `20260415_095006`처럼 **날짜만 있는 디렉터리는 scratch**이며 인용해서는 안 된다.
> 이 문서의 수치는 그 규칙을 따른다(§3.1의 `shared_buffers` 민감도만 예외 —
> 해당 실험은 canonical 디렉터리에 없고 scratch에만 있어, 출처를 명시해 인용했다).

---

## 1. 공통 조건

### 1.1 스키마 (`oltp_common.lua`)

```sql
CREATE TABLE sbtestN (
  id  SERIAL / INTEGER AUTO_INCREMENT,   -- PRIMARY KEY
  k   INTEGER  NOT NULL DEFAULT 0,
  c   CHAR(120) NOT NULL DEFAULT '',
  pad CHAR(60)  NOT NULL DEFAULT ''
);
CREATE INDEX k_N ON sbtestN(k);          -- create_secondary=true (기본값)
```

행 하나가 약 200 B + 튜플 헤더. 인덱스는 PK 하나 + 보조 인덱스 `k` 하나.
`c` / `pad`에는 인덱스가 없다 — 이것이 `update_index` vs `update_non_index`를
가르는 유일한 구조적 차이다.

### 1.2 실행 파라미터 (`run_main.sh`)

| 항목 | 값 |
|---|---|
| `--tables` | 16 |
| `--table-size` | 40,000,000 (= `main_rows_per_table`: 640M / tables) |
| `--threads` | 16 / 32 / 64 |
| warmup | 600 s (버려짐, 측정 스레드 수와 동일) |
| measure | 300 s, `--report-interval=10 --percentile=99 --histogram=on` |
| PG 전용 | `--auto_inc=on` |

`create_image.sh`는 `oltp_read_write ... prepare`로 이미지를 한 번 만들고,
셀마다 partclone으로 복원하므로 모든 셀이 **바이트 동일한 초기 상태**에서 출발한다.

### 1.3 난수 분포 — 가장 중요한 기본값

```
--rand-type=special   (기본)
--rand-spec-pct=1     (기본)  → 범위의 1%를
--rand-spec-res=75    (기본)  → 요청의 75%가 때린다
```

* 테이블 선택: `sysbench.rand.uniform(1, tables)` → 16개 테이블 **균등**
* 행 선택: `sysbench.rand.default(1, table_size)` → **special 분포**

따라서 테이블당 hot 영역은 40M x 1% = 400K rows ≈ 100 MB,
16개 합쳐 **약 1.6 GB**. 152 GB DB지만 실제로 반복해서 dirty가 되는 페이지는
1.6 GB 수준이고, 나머지는 냉랭하다. `--rand-seed=0`(기본)이므로 매 실행 시드가 다르다.

이 사실의 파급:
* 읽기는 사실상 전부 캐시 히트 → 이 벤치마크는 **쓰기/fsync 바운드**다. tau를 보기에 좋은 조건.
* `shared_buffers`가 1.6 GB를 넘느냐 마느냐가 결과를 크게 가른다 (§3.1).
* 같은 페이지를 반복해서 다시 더럽히므로, **재-dirty 흡수 능력**(버퍼 풀 크기)이
  파일시스템에 도달하는 write 횟수를 좌우한다 → tau 저널 트래픽에 직결.

---

## 2. 워크로드별 특성

### 2.1 한눈에

| 워크로드 | 트랜잭션 1건 구성 | 명시적 BEGIN/COMMIT | PK 인덱스 | 보조 인덱스 `k` | PG HOT update 가능 | 테이블 크기 |
|---|---|---|---|---|---|---|
| `oltp_point_select` | `SELECT c WHERE id=?` x1 | 없음 | 조회 | - | - | 불변 (미사용) |
| `oltp_read_write` | point x10 + range x4 + upd_idx + upd_nonidx + del + ins | **있음** | R/W | W | 부분 | 불변 |
| `oltp_write_only` | upd_idx + upd_nonidx + del + ins | **있음** | W | W | 부분 | 불변 |
| `oltp_update_index` | `UPDATE SET k=k+1 WHERE id=?` x1 | 없음(autocommit) | W | **W** | **불가** | 불변(bloat만) |
| `oltp_update_non_index` | `UPDATE SET c=? WHERE id=?` x1 | 없음(autocommit) | W | - | **가능** | 불변(bloat만) |
| `oltp_delete` | `DELETE WHERE id=?` x1 | 없음(autocommit) | W | W | - | **감소** |
| `oltp_insert` | `INSERT (k,c,pad)` x1 | 없음(autocommit) | W(append) | W | - | **증가** |

### 2.2 개별 설명

#### `oltp_update_index` — 보조 인덱스를 때리는 갱신
`UPDATE sbtestN SET k = k+1 WHERE id = ?`.
`k`에 인덱스가 있으므로 PostgreSQL에서 **HOT update가 불가능**하다.
매 갱신마다 (1) 새 튜플 버전을 힙에 쓰고 (2) `k_N` 인덱스에 새 엔트리를 넣고
(3) PK 인덱스에도 새 ctid 엔트리를 넣는다. 결과적으로 **한 트랜잭션이 3개 페이지를 더럽힌다**.
힙 페이지가 차면 새 페이지로 넘어가므로 인덱스 페이지 분할까지 유발한다.
InnoDB에서도 secondary index 갱신 + undo 로그가 붙는다.
→ 5개 워크로드 중 **tau의 상대 이득이 가장 큰 워크로드**(ext4-tau/ext4-fpw_on = 1.52x @c64).
동시에 shared_buffers 민감도도 가장 크다(+27%).

#### `oltp_update_non_index` — 인덱스를 안 건드리는 갱신
`UPDATE sbtestN SET c = ? WHERE id = ?`. `c`에 인덱스가 없으므로
**HOT update 경로**를 탈 수 있다 — 같은 페이지 안에 새 버전을 만들고 인덱스는 손대지 않는다.
단 기본 `fillfactor = 100`(PG) 때문에 페이지에 여유가 없으면 HOT이 깨지고
곧바로 `update_index`와 비슷한 비용이 된다. 이것이 두 워크로드의
쓰기량 격차(12.8 vs 4.7 KB/event, §2.3)를 만든다.
`c`가 CHAR(120)이라 로그 레코드 자체는 `update_index`보다 크다.

#### `oltp_write_only` — 논문의 대표 워크로드
`BEGIN; upd_idx; upd_nonidx; DELETE id=x; INSERT id=x; COMMIT;`
4개 쓰기 문장이 **하나의 명시적 트랜잭션**으로 묶인다. 즉 **commit 당 fsync 1회**로
쓰기 4건이 상각되므로, TPS는 낮지만(41k vs 122k) 트랜잭션당 I/O가 가장 크다(40.6 KB).
DELETE와 INSERT가 같은 `id`를 쓰므로 테이블 크기는 유지된다.
`ignored errors`가 소수(85건/300s) 발생하는데, 서로 다른 스레드가 같은 hot id를
동시에 delete/insert 하면서 나는 PK 충돌이다 — 정상이다.
fsync 상각이 있어 tau의 상대 이득은 `update_index`보다 작다(1.42x @c64).

#### `oltp_read_write` — 읽기 섞인 표준 OLTP
`write_only` + point select 10 + range 4 (`BETWEEN`, `SUM`, `ORDER BY`, `DISTINCT`, range_size=100).
range 쿼리 4개가 CPU/정렬 바운드라 TPS가 한 자리 수 천 대로 떨어지고,
파일시스템 차이가 가장 덜 드러난다. `run_main.sh`에서 빠져 있는 이유가 이것으로 보인다.
**MySQL main 결과에는 남아 있고, 거기서 tau16G/ext4-fpw_on = 2.21x로 오히려 가장 높다** —
InnoDB는 doublewrite가 읽기 경로의 버퍼 풀 압박과 겹치기 때문. 다시 측정할 가치가 있다.

#### `oltp_delete` — 해석에 주의가 필요한 워크로드
`DELETE FROM sbtestN WHERE id = ?` 단독. 삭제된 행은 **다시 채워지지 않는다**.
special 분포 때문에 hot 1%가 먼저 고갈되고, 이후의 DELETE는 0행에 매칭된다.

실측 (`main_all`, ext4, fpw=off, c64, 300 s):

```
write:  31,175,718        <- 실제로 행을 지운 DELETE
other: 291,549,879        <- 0행 매칭 (사실상 index probe + no-op)
transactions: 322,725,597 (537,848 per sec.)
```

**보고된 537k TPS 중 실제 쓰기는 9.7%뿐이다.** 600 s warmup 동안 이미 hot 영역이
비워졌기 때문. 게다가 구간 TPS가 507k(10s) → 567k(600s)로 **단조 증가**한다 —
고갈이 진행될수록 빨라진다는 뜻이라 "정상 상태 처리량"이 아니다.
`oltp_delete` 숫자는 파일시스템 비교용으로는 쓸 수 있으나(모든 셀이 동일 이미지에서
동일하게 고갈됨) **절대값을 인용하면 안 된다**. `run_io.sh`의 고정 이벤트 수 측정에도
같은 왜곡이 들어간다.

#### `oltp_insert` — 유일한 순증 워크로드
PostgreSQL + `--auto_inc=on` 경로는 lua에서 **prepared statement를 쓰지 않고**
`con:query(string.format("INSERT ..."))`로 매번 ad-hoc SQL을 만든다
(`oltp_insert.lua`). 따라서 PG 쪽은 매 이벤트마다 parse/plan 비용이 붙는다.
MySQL은 prepared 경로. **PG와 MySQL의 insert 수치를 나란히 비교할 때 주의.**
id는 SERIAL이라 힙 append + PK append(순차) + `k` 인덱스는 랜덤 삽입.
300 s x 150k TPS = 4,500만 행 ≈ 11 GB가 실행 중 늘어나고, warmup까지 합치면 ~35 GB.
쓰기가 대부분 순차 append라 **파일시스템 간 차이가 가장 작다**(tau/fpw_on = 1.18x).

### 2.3 실측: 워크로드별 쓰기량 (고정 32M 이벤트, PG, c32, t16)

출처: `results/sysbench/postgres/sosp2026/io_main/iostat_summary.csv`

| 워크로드 | ext4 fpw=off | ext4 fpw=on | ext4-tau | xfs-tau | ext4-dj20 | zfs-8k |
|---|---|---|---|---|---|---|
| `oltp_write_only` | 1240 GB | 2116 GB | 1606 GB | 1800 GB | 3469 GB | 3566 GB |
| `oltp_update_index` | 409 | 709 | 526 | 585 | 1319 | 1192 |
| `oltp_update_non_index` | 152 | 345 | 270 | 293 | 647 | 701 |
| `oltp_insert` | 149 | 193 | 171 | 206 | 556 | 303 |
| `oltp_delete`\* | 76 | 165 | 139 | 176 | 283 | 323 |

ext4 fpw=off를 1.00으로 정규화:

| 워크로드 | ext4 off | ext4 on | ext4-tau | xfs-tau | ext4-dj20 | zfs-8k |
|---|---|---|---|---|---|---|
| `oltp_write_only` | 1.00 | 1.71 | **1.30** | 1.45 | 2.80 | 2.88 |
| `oltp_update_index` | 1.00 | 1.74 | **1.29** | 1.43 | 3.23 | 2.92 |
| `oltp_update_non_index` | 1.00 | 2.28 | **1.78** | 1.93 | 4.27 | 4.62 |
| `oltp_insert` | 1.00 | 1.29 | **1.15** | 1.38 | 3.73 | 2.03 |
| `oltp_delete`\* | 1.00 | 2.17 | **1.83** | 2.32 | 3.72 | 4.24 |

\* 위의 no-op 고갈 문제로 delete 행은 참고용.

읽는 법: tau는 언제나 `fpw=off`와 `fpw=on` **사이**에 있다. FPW가 가장 비싼 워크로드
(`update_non_index`, `delete` — 로그 레코드는 작은데 FPI가 8 KB 통짜라 비율이 튄다)에서
tau의 절대 절감폭이 가장 크고, 이미 순차인 `insert`에서 가장 작다.

### 2.4 실측: TPS (PG 17.5, 152 GB, `sosp2026/main_all`)

`ext4-tau` / `ext4 fpw=on`(정직한 baseline) 비율:

| 워크로드 | c16 | c32 | c64 |
|---|---|---|---|
| `oltp_update_index` | **1.45x** | 1.47x | **1.52x** |
| `oltp_write_only` | 1.38x | 1.55x | 1.42x |
| `oltp_update_non_index` | 1.21x | 1.28x | 1.30x |
| `oltp_delete` | 1.16x | 1.23x | 1.29x |
| `oltp_insert` | 1.09x | 1.17x | 1.18x |

`ext4-tau` / `ext4 fpw=off`(안전하지 않은 상한):

| 워크로드 | c16 | c32 | c64 |
|---|---|---|---|
| `oltp_insert` | 1.00 | 1.00 | 0.97 |
| `oltp_update_non_index` | 0.99 | 0.96 | 0.94 |
| `oltp_write_only` | 0.94 | 0.81 | 0.81 |
| `oltp_update_index` | 0.95 | 0.81 | 0.77 |
| `oltp_delete` | 0.90 | 0.84 | 0.73 |

**스레드가 늘수록 tau의 오버헤드가 커진다** (update_index 0.95 → 0.77).
동시성이 올라갈 때 tau 쪽이 먼저 포화된다는 신호이고, 뒤의 §3.1 가설과 연결된다.

MySQL 8.4.5(`main_all_20251130_181416`, buffer pool 16 GB, c32)는 그림이 다르다 —
`tau16G`가 `ext4 fpw=off`조차 넘어선다:

| 워크로드 | tau16G / ext4 fpw=on | tau16G / ext4 fpw=off |
|---|---|---|
| `oltp_write_only` | **2.44x** | 1.59x |
| `oltp_update_index` | 2.33x | 1.51x |
| `oltp_read_write` | 2.21x | 1.63x |
| `oltp_delete` | 1.87x | 1.38x |
| `oltp_insert` | 1.61x | 1.24x |
| `oltp_update_non_index` | 1.45x | 1.26x |

InnoDB는 16 KB 페이지를 in-place 랜덤 쓰기로 내리는데 tau가 이를 순차 저널 쓰기로
바꿔주기 때문으로 보인다. PG(8 KB, 이미 page cache 경유)보다 이득이 큰 것이 자연스럽다.

---

## 3. RDBMS 기본 설정이 결과에 미치는 영향

### 3.1 PostgreSQL — `shared_buffers = 128MB` (가장 큰 문제)

`run_main.sh` / `run_io.sh` / `run_motiv.sh`는 `full_page_writes`와 `max_wal_size`만
건드리고 `shared_buffers`는 손대지 않는다 → initdb 기본값 128MB.
`shared_buffers = 16GB`를 세팅하는 스크립트는 `run_claude.sh`(107행)와
`run_profile.sh`(74행) 둘뿐인데, **둘 다 `FS_GROUPS="ext4"`다.**
(주의: 바깥 루프는 `for FS in $FS_GROUPS`이고 `FS_FPWON`/`FS_FPWOFF`는
그 FS를 fpw on/off로 돌릴지 고르는 *필터*일 뿐이다. `run_profile.sh`의
`FS_FPWOFF`에 `ext4-tau xfs-tau`가 적혀 있어도 `FS_GROUPS`에 없으면 절대 실행되지 않는다.)
결과적으로 16GB 데이터는 ext4 전용이고, tau는 한 셀도 없다.

집계 결과 (`results/sysbench/**`의 PG 셀 1,338개):

```
shared_buffers=128MB : 1,173 셀
shared_buffers=16GB  :    76 셀   <- 전부 ext4, tau 없음
tau 셀 중 128MB 아닌 것 : 0 셀
```

#### 실측 민감도 (ext4, `max_wal_size=16GB` 고정, 128MB → 16GB)

| 워크로드 | thr | fpw=off | fpw=on |
|---|---|---|---|
| `oltp_write_only` | 64 | **+45.9%** | +6.1% |
| `oltp_write_only` | 32 | +18.5% | +11.5% |
| `oltp_write_only` | 16 | +18.7% | +13.3% |
| `oltp_update_index` | 64 | **+27.3%** | +9.3% |
| `oltp_update_index` | 32 | +22.7% | +6.0% |
| `oltp_update_index` | 16 | +20.4% | +7.4% |
| `oltp_update_non_index` | 64 | +14.8% | +8.0% |
| `oltp_delete` | 64 | +16.2% | +7.6% |
| `oltp_insert` | 64 | +12.6% | +10.3% |

원본: `postgres/WAL16G_20260404_170406`(128MB) vs `postgres/SB16G_WAL16G_20260403_220014`(16GB).
`20260405_134347`이 후자를 재현해 값이 0.3% 이내로 일치 — 노이즈가 아니다.

이 4개 실행은 `run_claude.sh` 계열이라 **warmup 300 s / measure 600 s**다
(`run_main.sh`는 반대로 warmup 600 s / measure 300 s). 서로 간의 비교는 공정하지만
§2.4의 절대값과 직접 나란히 놓지 말 것 — 특히 `oltp_delete`는 고갈 진행도가 달라진다.

#### 왜 중요한가

* hot working set이 1.6 GB(§1.3)다. 128MB는 그 **8%**만 담고, 16GB는 전부 담는다.
  128MB에서는 hot 페이지가 계속 evict → OS page cache로 `write()` → 다시 read-in 된다.
  187 GB DRAM 덕에 페이지 캐시가 다 흡수하므로 **디스크 read는 안 늘지만
  파일시스템이 보는 `write()` 호출 수는 폭증한다.**
* tau는 바로 그 `write()`를 buffer_head/iomap 단위로 저널링한다. 즉
  **작은 shared_buffers = 최대치의 tau 저널 트래픽**. 반대로 큰 shared_buffers는
  재-dirty를 PG 내부에서 흡수하고 checkpoint 때 큰 덩어리로 한 번에 내보낸다.
* `fpw=on`이 덜 오르는 이유: FPW 비용은 checkpoint 직후 첫 수정 때 발생하는
  8 KB WAL 레코드이고 shared_buffers와 거의 무관하다. FPW가 병목을 붙잡고 있어
  버퍼 풀을 키워도 그만큼 못 먹는다.

**결론(가설, 미검증):** tau를 `shared_buffers=16GB`에서 다시 재면
`fpw=off` 계열이 얻은 +27~46%를 tau도 대체로 따라갈 것이고,
`fpw=on` baseline은 +6~9%만 오르므로 **tau 대 fpw=on 비율이 1.42x → 1.9x 수준으로
벌어질 가능성**이 있다. 반대 결과(tau가 못 따라감 = 병목이 tau 내부)도
그 자체로 중요한 정보다. **어느 쪽이든 지금은 데이터가 없다.**

**주의 — 이 민감도 실험 자체에 confound가 있다.**
`wal_buffers = -1`(기본)은 `shared_buffers / 32`로 유도되고 16 MB에서 클램프된다.
따라서 128MB → 16GB 실험은 `wal_buffers`도 **4 MB → 16 MB**로 같이 바꿨다.
둘을 분리하려면 `wal_buffers=16MB`를 명시 고정한 3번째 조건이 필요하다.

### 3.2 PostgreSQL — `max_wal_size` 비대칭

`run_main.sh` / `run_io.sh`는 `FPW == on`일 때만 `max_wal_size = 16GB`로 올린다.
`fpw=off`(= 모든 tau 셀)는 **기본값 1GB** 그대로다.

실측 (ext4, fpw=off, shared_buffers=16GB 고정, 1GB → 16GB):

| 워크로드 | c16 | c32 | c64 |
|---|---|---|---|
| `oltp_delete` | +6.2% | +8.6% | **+11.4%** |
| `oltp_insert` | +0.1% | +2.1% | +3.7% |
| `oltp_update_index` | −3.7% | −1.8% | +2.0% |
| `oltp_update_non_index` | −3.0% | −1.8% | +0.6% |
| `oltp_write_only` | −5.3% | −2.8% | +2.1% |

원본: `postgres/20260406_092508`(1GB) vs `postgres/20260405_134347`(16GB).

읽는 법: FPI가 없는 `fpw=off`에서는 `max_wal_size`가 대체로 노이즈 수준(±3%)이다.
**단 `oltp_delete`만은 최대 11% 손해**를 본다 — no-op이 많아 WAL 생성 속도 대비
checkpoint 요구가 상대적으로 자주 걸리기 때문. 즉 **`oltp_delete` 셀에서 tau가
baseline보다 10% 정도 핸디캡을 지고 있다.** 다행히 §2.4 표에서 delete는 tau 이득이
가장 작은 워크로드 중 하나이므로, 바로잡으면 수치가 개선되는 방향이다.

**이 비대칭은 의도된 것이다** — tau는 파일시스템 안에 저널 공간을 따로 먹으므로,
DB 로그 상한을 줄여 장치 점유를 맞추려는 페널티다. 근거가 타당하고, 위 실측대로
`fpw=off`에서 `max_wal_size`의 영향은 대부분 노이즈 수준이라 비용도 작다.

남는 일은 근거를 숫자로 만드는 것뿐이다. tau 저널은 128 MB 세그먼트 단위로
**동적 할당**되므로 마운트 옵션의 값(§4.6)은 상한일 뿐 실제 점유가 아니다.
정상 상태에서 실제로 몇 GB를 쓰는지 한 번 계측해 표로 남겨 두면
"WAL을 1 GB로 줄인 이유"가 그대로 방어된다. `oltp_delete`만 이 페널티로
최대 11%를 손해 보므로, 그 셀만이라도 16 GB로 다시 재 두면 깔끔하다.

### 3.3 PostgreSQL — 기타 기본값 점검

`.spec`이 기록하는 값과 initdb 기본값을 대조한 결과:

| 파라미터 | 실제 값 | 기본값? | tau에 대한 함의 |
|---|---|---|---|
| `fsync` | on | 기본 | 필수. 유지. |
| `synchronous_commit` | on | 기본 | 필수. 유지. |
| `wal_level` | replica | 기본 | `minimal`이면 WAL이 줄지만 baseline/tau 양쪽에 동일. 현행 유지가 안전. |
| `full_page_writes` | on/off | 실험 변수 | §3.1 참조. |
| `shared_buffers` | **128MB** | 기본 | 최대 이슈. §3.1. |
| `wal_buffers` | −1 → **4MB** | 기본 유도값 | 64 세션 commit에 4 MB는 좁다. shared_buffers와 얽혀 있음. |
| `max_wal_size` | 1GB / 16GB | 비대칭 | §3.2. |
| `checkpoint_timeout` | 5min | 기본 | 1GB 조건에서는 사실상 무의미 — 항상 WAL 크기로 먼저 트리거된다. |
| `checkpoint_completion_target` | 0.9 | 기본 | 1GB에선 펼칠 구간 자체가 짧아 버스트가 남는다. |
| `bgwriter_lru_maxpages` | 100 / 200ms | 기본 | 초당 500 페이지 = 4 MB/s. 이 부하에선 **완전히 무력**하고, 결국 backend가 직접 evict-write 한다. tau 입장에선 writeback이 백그라운드가 아니라 **foreground 경로로 들어온다는 뜻**. |
| `autovacuum` | on, `scale_factor=0.2` | 기본 | 40M 행 테이블에서 800만 dead tuple이 쌓여야 발동. `vacuum_cost_delay=2ms`/`cost_limit=200`으로 강하게 스로틀돼 100k TPS를 따라가지 못한다 → 900 s 동안 bloat가 단조 증가. 모든 셀이 같은 이미지에서 출발하므로 **비교는 공정하지만**, 측정 구간이 정상 상태가 아니다. |
| `maintenance_work_mem` | 64MB | 기본 | 위 vacuum이 실제로 돌 때 인덱스 다중 패스를 유발할 수 있다. |
| `max_connections` | 100 | 기본 | c64 + autovacuum worker로 여유 있음. 문제 없음. |
| `wal_compression` | off | 기본 | 켜면 FPW 비용이 줄어 `fpw=on` baseline이 강해진다. **켜지 않은 것은 정당하지만, 리뷰어가 물어볼 항목이다** — 최소 1셀은 재 두는 편이 좋다. |
| `effective_io_concurrency` | 16 (PG17 기본) | 기본 | 읽기가 전부 캐시 히트라 영향 미미. |

### 3.4 MySQL 8.4.5 — 버전이 바꿔놓은 기본값들

`bench/mysql-server`는 **MySQL 8.4 브랜치**다(`git log`: `mysql-8.4`에 
`patch for open flag for atomicity`). 8.4는 InnoDB 기본값을 대거 바꿨고,
`.spec`에 그 값이 그대로 찍혀 있다 — 즉 **누군가 튜닝한 값이 아니라 8.4 기본값**이다.

| 파라미터 | 실측 값 | 8.0 기본 | 8.4 기본 | 비고 |
|---|---|---|---|---|
| `innodb_io_capacity` | 10000 | 200 | **10000** | page cleaner가 매우 공격적으로 flush |
| `innodb_io_capacity_max` | 20000 | 2000 | **`io_capacity`의 2배** | 위와 동일 |
| `innodb_read_io_threads` | 16 | 4 | **`clamp(nproc/2,4,64)`** | 32 core라 16. 머신을 바꾸면 조용히 같이 바뀐다 |
| `innodb_change_buffering` | none | all | **none** | 보조 인덱스 갱신이 즉시 페이지를 때린다 |
| `innodb_adaptive_hash_index` | OFF | ON | **OFF** | 소스에서 확인 (`ha_innodb.cc`) |
| `innodb_redo_log_capacity` | **100 MB** | 100 MB | 100 MB | 152 GB DB에는 극단적으로 작다 |
| `innodb_doublewrite` | 실험 변수 | ON | ON | `fpw` 노브 |
| `innodb_flush_log_at_trx_commit` | 1 | 1 | 1 | 유지 |
| `sync_binlog` + `log_bin` | 1 + ON | 1 + ON | 1 + ON | commit마다 binlog/redo **2단계 커밋 + 2회 fsync** |
| `innodb_buffer_pool_size` | 128MB~48GB (실행마다 다름) | 128MB | 128MB | §3.5 |
| `innodb_buffer_pool_instances` | 1 (128MB) / 4 (1GB) | 유도값 | 유도값 | 풀 크기 따라 **자동으로 같이 바뀐다** |

주목할 조합:
* **`innodb_io_capacity=10000` + `change_buffering=none` + `redo_log_capacity=100MB`.**
  redo가 100 MB뿐이라 checkpoint age가 즉시 한계에 닿고, page cleaner가
  초당 1만 페이지(=160 MB) 규모로 dirty 16 KB 페이지를 **랜덤 in-place**로 내린다.
  tau 입장에서는 이것이 그대로 저널 유입이 된다.
  동시에 이것이 §2.4에서 MySQL tau가 `fpw=off`조차 이기는 이유이기도 하다 —
  tau가 그 랜덤 쓰기를 순차 저널 쓰기로 흡수해 준다.
  `run_main.sh` 등에 `--innodb_redo_log_capacity=$INNODB_LOG_SIZE`가 **주석 처리된 채**
  남아 있다. 켜고 끄는 것으로 tau 이득의 상당 부분을 설명할 수 있을 것으로 보인다.
* **binlog가 기본 ON이다.** commit 경로가 `binlog fsync → redo fsync`의 XA 2PC라
  트랜잭션당 fsync가 2회다. 켜 둔 채 재는 것이 현실적이지만,
  파일시스템 저널의 효과를 절반쯤 희석시킨다. `--disable-log-bin` 셀이
  `create_image` 경로에만 있고 측정 경로엔 없다.

### 3.5 MySQL — `innodb_buffer_pool_size`가 실행마다 다르다

집계 결과, MySQL 셀의 버퍼 풀 크기가 실행 디렉터리마다 제각각이다:
128 MB / 1 GB / 2 GB / 4 GB / 8 GB / 16 GB / 48 GB / 70 GB / 100 GB / 140 GB.
현행 `run_main.sh`는 `--innodb_buffer_pool_size=1G`로 하드코딩돼 있다.

실측 (`oltp_write_only`, c64, fpw=off):

| FS | 128 MB | 1 GB | 4 GB |
|---|---|---|---|
| `ext4-tau` | 8,660~8,893 (7회 반복) | **14,774** | 13,861 |
| `xfs-tau` | 8,647~9,024 (4회 반복) | **14,875** | 15,487 |

**128 MB → 1 GB 만으로 1.7x**. 4 GB에서는 포화(§1.3의 hot set 1.6 GB와 정확히 일치).
CLAUDE.md에 적힌 "2026년 4월 8.7k → 14.8k 점프"가 바로 이것이고, 최적화가 아니다.
날짜가 다른 MySQL 결과를 **`.spec` 확인 없이 비교하면 안 된다**는 기존 경고를
이 표가 정량적으로 뒷받침한다.

### 3.6 MySQL — `innodb_flush_method` 교란 (기존 경고 재확인, 정량화)

같은 실행(`mysql/20260415_095006`) 안에서:

```
mysql_oltp_insert_ext4-tau_...spec :  innodb_flush_method = O_DIRECT
mysql_oltp_insert_xfs-tau_....spec :  innodb_flush_method = fsync
```

`xfs_file_open()`이 tjournal 마운트에서 `FMODE_CAN_ODIRECT`를 무조건 지우기 때문에
InnoDB의 기동 시 O_DIRECT 프로브가 실패하고 조용히 `fsync`로 내려간다.
로그도 남지 않는다.

정량화 (`oltp_insert`/`oltp_update_non_index`, c32, bp=128MB):

| 워크로드 | ext4-tau (O_DIRECT) | xfs-tau (fsync) | 차이 |
|---|---|---|---|
| `oltp_insert` | 39,141 | 34,859 | −10.9% |
| `oltp_update_non_index` | 39,442 | 33,901 | −14.0% |

**`ext4-tau` vs `xfs-tau` MySQL 비교는 최대 14%까지 flush method 때문이다.**
공정하게 비교하려면 양쪽 모두 `--innodb_flush_method=fsync`를 **명시**해야 한다.
`run_main.sh`에 해당 줄이 주석 처리돼 있다(139행 근처).

---

## 4. MySQL 결과는 왜 다른가 — 코드로 확인한 것

PG에서 tau의 이득은 `fpw=on` 대비 1.09~1.52x이고 `fpw=off`는 넘지 못한다(0.73~1.00).
MySQL에서는 `fpw=on` 대비 1.45~2.44x이고 **`fpw=off`조차 1.24~1.63x로 넘어선다**.
이 격차의 원인을 커널/InnoDB 소스에서 추적한 결과가 아래다.

### 4.1 tau가 활성화되는 파일의 범위

`bench/mysql-server` 패치(`10abe885`, `os0file.cc`)는 딱 이것뿐이다.

```c
#ifdef TAU_JOURNAL
  if (purpose == OS_DATA_FILE)
    create_flag |= O_TAU_ATOMIC;
#endif
```

* `O_TAU_ATOMIC`(= `O_TAU_UNTORN`, `040000000`)은 **`OS_DATA_FILE`(=`.ibd` 테이블스페이스)에만** 붙는다.
* **redo log(`OS_LOG_FILE`)와 binlog는 tau 대상이 아니다.** 즉 commit 경로는 tau를 전혀 타지 않고,
  tau는 오직 **page cleaner의 dirty page flush**만 가로챈다.
* `O_TAU_ATOMIC` / `TAU_JOURNAL` 매크로는 `os0file.h`에 **무조건** `#define TAU_JOURNAL 1`로
  박혀 있다. 최상위 `CLAUDE.md`가 "`-DTAU_JOURNAL=1` cmake 플래그로 가드된다"고 적어둔 것은
  **사실이 아니다** — cmake 변수는 컴파일 정의로 전달되지 않으며, 패치는 항상 켜져 있다.
* ext4 쪽에는 파일명 기반 예외가 하나 있다(`include/linux/tau_perf.h`):
  `strstr(name, "dblw")`가 걸리면 tau 활성화를 건너뛴다 → doublewrite 파일은 tau 대상이 아니다.

### 4.2 `innodb_flush_method`는 자동 탐지된다 (기본값이 아니라 *탐지 결과*)

`ha_innodb.cc:4953`:

```c
if (!innodb_flush_method_is_set()) {
  innodb_flush_method = os_is_o_direct_supported()
                          ? SRV_UNIX_O_DIRECT : SRV_UNIX_FSYNC;
}
```

`os_is_o_direct_supported()`(`os0file.cc:137`)가 하는 일은 이것뿐이다:

```c
strcat(file_name + dir_len, "o_direct_test");
file_handle = ::open(file_name, O_CREAT|O_TRUNC|O_WRONLY|O_DIRECT, S_IRWXU);
if (file_handle == -1 && errno == EINVAL) { unlink(...); return false; }
```

datadir에 `o_direct_test`를 만들며 **open(2)에 O_DIRECT를 줘 보고 EINVAL이 나는지만** 본다.
이 프로브 파일은 `O_TAU_UNTORN` 없이 열리므로 tau 활성화 대상이 아니고,
`open` 이후의 실제 write 경로는 전혀 확인하지 않는다.

스크립트가 값을 지정하지 않으므로 **파일시스템이 InnoDB 설정을 결정한다.** 로그는
`ER_IB_MSG_INNODB_FLUSH_METHOD` 한 줄뿐인데 `run_main.sh`는 `--log-error`를 주지 않아
그 줄조차 남지 않는다.

### 4.3 프로브를 통과해도 실제 I/O는 buffered일 수 있다 ★

InnoDB는 `.ibd`를 열 때 open 플래그로 O_DIRECT를 주지 않는다. 먼저 열고
`os_file_set_nocache()` → `fcntl(fd, F_SETFL, O_DIRECT)`로 켠다
(실패해도 경고만 찍고 계속 진행한다).

```
os_file_create_func():
   open(name, ... | O_TAU_ATOMIC)      <- tau 활성화됨. O_DIRECT는 여기 없음
   if (flush_method == O_DIRECT && purpose == OS_DATA_FILE)
       os_file_set_nocache(fd)          <- fcntl(F_SETFL, O_DIRECT)
```

`ext4_file_open()`의 `O_DIRECT + O_TAU_UNTORN → EINVAL` 검사(`fs/ext4/file.c:1303`)는
**open 플래그만** 본다. InnoDB는 open에 O_DIRECT를 안 주므로 그냥 통과한다.
ext4 aops는 tau 모드에서도 `.direct_IO = noop_direct_IO`를 쓰므로 `FMODE_CAN_ODIRECT`가
살아 있고(`fs/open.c:966`), `fcntl`도 성공한다.

그런데 쓰기는 tau를 우회하지 **않는다.** 마지막 방어선이 있다:

```c
/* fs/ext4/inode.c:6123 */
u32 ext4_dio_alignment(struct inode *inode)
{
	if (fsverity_active(inode))          return 0;
	if (ext4_should_journal_data(inode)) return 0;   /* <- data=journal */
#ifdef CONFIG_EXT4_TAU_JOURNAL
	if (ext4_should_tau_journal(inode))  return 0;   /* <- tau */
#endif
	...
}
```

`ext4_dio_write_iter()`는 `!ext4_should_use_dio()`이면 `ext4_buffered_write_iter()`로
되돌린다(`fs/ext4/file.c:940`). 읽기 경로도 같다.
**정합성은 깨지지 않는다** — tau는 정상적으로 저널링한다. 다만 InnoDB는 자기가
O_DIRECT를 쓰고 있다고 믿는다.

`ext4_should_journal_data`가 같은 함수 안에 있다는 점에 주의: **`ext4-dj`(data=journal)도
정확히 같은 경로로 buffered가 된다.** ZFS(OpenZFS 2.3 이전)도 O_DIRECT 시맨틱을 구현하지
않고 내부적으로 buffered + ARC로 처리한다. `xfs-tau`만 유일하게 정직하게 보고하는데,
`xfs_file_open()`이 tjournal 마운트에서 `FMODE_CAN_ODIRECT`를 무조건 지우므로
(`fs/xfs/xfs_file.c:1398`) 프로브 자체가 EINVAL로 실패해 `fsync`로 잡힌다.

### 4.4 결과: 캐시 조건이 두 그룹으로 갈린다

| 구성 | `.spec`이 보고하는 값 | 실제 `.ibd` I/O | 187 GB page cache / ARC |
|---|---|---|---|
| `ext4` | O_DIRECT | **O_DIRECT** | 못 씀 |
| `xfs` | O_DIRECT | **O_DIRECT** | 못 씀 |
| `xfs-cow` | O_DIRECT | **O_DIRECT** | 못 씀 |
| `ext4-dj10/20` | O_DIRECT | **buffered** (`ext4_should_journal_data`) | 씀 |
| `zfs-16k` | O_DIRECT | **buffered** (OpenZFS) | **ARC (기본 상한 ≈ RAM/2)** |
| `ext4-tau` / `tau16G` | O_DIRECT | **buffered** (`ext4_should_tau_journal`) | 씀 |
| `xfs-tau` | fsync | **buffered** | 씀 |

집계로 확인한 실제 `.spec` 값 (MySQL 셀 전체):

```
ext4      O_DIRECT  95 |  ext4-dj  O_DIRECT 17 |  zfs-16k  O_DIRECT 21
xfs       O_DIRECT  61 |  ext4-tau O_DIRECT 14 |  tau16G   O_DIRECT 32
xfs-cow   O_DIRECT   7 |  xfs-tau  fsync    81 |  ext4     fsync     4
```

**중요: 이 비대칭이 tau의 우위를 설명하지는 못한다.**
`ext4-dj`와 `zfs-16k`는 tau와 **같은 buffered 그룹**이고 ZFS는 심지어 ARC까지 얹혀 있는데,
`main_all_20251130_181416`(c32, bp=16GB) 기준으로 `ext4`(진짜 O_DIRECT)의 각각
0.63x / 0.64x(`oltp_write_only`)에 머문다. buffered라는 것만으로 이기지는 않는다는 뜻이다.

같은 표에서 `tau16G` 대비 배수:

| 워크로드 | ext4 fpw=on | ext4 fpw=off | xfs fpw=off | **ext4-dj** | zfs-16k | xfs-cow |
|---|---|---|---|---|---|---|
| `oltp_write_only` | 2.44x | 1.59x | 1.56x | **2.51x** | 2.47x | 3.72x |
| `oltp_update_index` | 2.33x | 1.51x | 1.47x | **2.43x** | 2.42x | 3.08x |
| `oltp_read_write` | 2.21x | 1.63x | 1.62x | **2.01x** | 2.08x | 3.26x |
| `oltp_delete` | 1.87x | 1.38x | 1.38x | **1.84x** | 2.32x | 3.40x |
| `oltp_insert` | 1.61x | 1.24x | 1.29x | **1.90x** | 1.87x | 2.35x |
| `oltp_update_non_index` | 1.45x | 1.26x | 1.35x | **1.97x** | 2.11x | 1.96x |

**`ext4-dj` 열이 가장 깨끗한 비교다.** 같은 buffered 경로, 같은
"파일시스템이 원자성을 제공한다"는 주장, 같은 캐시 조건 — 캐시 교란이 없다.
tau가 1.84~2.51x로 이긴다. 이건 지금 그대로 인용해도 된다.

교란이 남는 것은 **`tau` vs `ext4`/`xfs`(진짜 O_DIRECT)** 비교, 즉 헤드라인 수치뿐이다.
크기의 유일한 통제 관측이 `mysql/99_Archive/ext4_nobinlog_{O_DIRECT,fsync}_20251122_*`에 있다
(plain ext4, binlog off, `innodb_buffer_pool_size = 140GB`):

| 워크로드 | fpw | thr | O_DIRECT | fsync(buffered) | fsync/O_DIRECT |
|---|---|---|---|---|---|
| `oltp_update_index` | off | 64 | 136,826 | 145,672 | 1.06x |
| `oltp_update_index` | off | 128 | 157,763 | 154,484 | 0.98x |
| `oltp_update_index` | on | 64 | 104,341 | 122,369 | **1.17x** |
| `oltp_update_index` | on | 128 | 122,511 | 130,123 | 1.06x |

버퍼 풀이 140 GB면 page cache가 더해 줄 것이 없어 차이가 0.98~1.17x에 그친다.
**버퍼 풀이 작을수록 이 값은 커진다**(§4.8). 헤드라인 표에 쓰는 버퍼 풀 크기에서
`ext4 --innodb_flush_method=fsync` 셀 하나만 추가로 재면 교란의 크기가 확정된다.

### 4.5 doublewrite와 FPW는 비용이 걸리는 위치가 다르다

쓰기량만 보면 둘 다 대략 2배다(PG FPW 실측 1.71~2.28x, InnoDB doublewrite는 정의상 2x).
차이는 **어느 경로에서 기다리게 만드느냐**다.

* **PostgreSQL FPW** — checkpoint 직후 첫 수정 시 8 KB 페이지 이미지를 **WAL에 순차 기록**.
  commit 경로에 붙지만 group commit으로 상각되고, WAL은 어차피 순차다.
* **InnoDB doublewrite** — page cleaner가 dirty page를 내릴 때 **doublewrite 버퍼에 쓰고
  fsync한 뒤** 제자리에 랜덤 기록. 즉 **flush 경로의 동기 지연**이다.

여기에 `innodb_redo_log_capacity = 100MB`(8.4 기본값, 152 GB DB에 대해 극단적으로 작음)가
겹친다. redo가 3초면 한 바퀴 도는 규모라 checkpoint age가 상시 한계에 붙어 있고,
user thread가 `log_free_check()`에서 page flush를 기다린다.
**doublewrite를 없애면 그 flush 비용이 대략 반으로 줄고, 곧바로 스로틀이 풀린다.**
PG의 FPW 제거가 "WAL 볼륨이 준다"인 반면 MySQL의 doublewrite 제거는
"병목이 풀린다"인 셈이고, 이것이 MySQL의 배수가 큰 구조적 이유다.

검증 방법: `innodb_redo_log_capacity`를 100 MB(기본) vs 10 GB로 스윕하면
tau 이득이 얼마나 줄어드는지 바로 나온다. 스크립트에는
`--innodb_redo_log_capacity=$INNODB_LOG_SIZE`가 **주석 처리된 채** 있다
(`run_main.sh:139` 등).

### 4.6 tau 저널 상한이 ext4/xfs 간에 32배 다르다

`bench/scripts/common.sh` 현행:

```shell
ext4-tau) mount -t ext4 -o tjournal,tjournal_size=32 ...   # 상한 32 GB
xfs-tau)  mkfs.xfs -f -l tjmaxsize=1G ...                  # 상한 1 GB
```

`tjournal_size`의 단위는 **GB**다 — `fs/ext4/super.c:2429`:
`ctx->tau_journal_size = result.uint_32 * (1UL << 30);`
(구세대 라벨 `tau16G`는 `tjournal_size=16` = ext4 + 16 GB 상한이고,
당시 `xfs-tau`는 `mkfs.xfs -l tjsize=40G`였다.)

**저널은 128 MB 세그먼트 단위로 동적 할당되므로 이 값은 상한일 뿐 실제 점유가 아니다.**
따라서 장치 공간 형평 문제로 볼 필요는 없다. 다만 상한은 **체크포인트를 얼마나 미룰 수
있는지**를 정하므로 꼬리 지연에는 직접 영향을 준다. 실제로 `oltp_write_only`, c64, bp=1GB에서

| | TPS | p99 |
|---|---|---|
| `ext4-tau` (상한 32 GB) | 14,774 | **30.8 ms** |
| `xfs-tau` (상한 1 GB) | 14,875 | **12.5 ms** |

처리량은 같은데 p99가 2.5배 갈린다.

> **[2026-08-23] 상한을 같게 맞춰 봤더니 그게 답이 아니었다(§4.12 (4)).**
> 양쪽을 1 GB로 낮추면 `ext4-tau`가 무너지고(처리량 1/4~1/9), 양쪽을 32 GB로 올리면
> 둘 다 정상이며 `xfs-tau`는 1 GB에서도 정상이다. 즉 "같은 숫자로 맞추기"가 아니라
> **각 파일시스템이 충분한 상한을 갖도록** 하는 것이 옳은 통제다.
> 저널 공간은 128 MB 세그먼트로 동적 할당되므로 상한을 크게 잡는 데 비용이 없다.
> `common.sh`의 `xfs-tau` `tjmaxsize=1G`는 `ext4-tau`의 32 GB와 맞춰 올리는 편이 낫다.

### 4.7 MySQL 결과 디렉터리에 섞인 설정

`mysql/main_xfs_20260401_213305`처럼 **하나의 스케일 곡선 안에서 셀마다
버퍼 풀이 다른** 디렉터리가 있다. `oltp_update_index`, `xfs-tau`, `fpw=off`:

| threads | `innodb_buffer_pool_size` | TPS |
|---|---|---|
| 1 | 4 GB | 2,064 |
| 8 | 128 MB | 7,894 |
| 16 | 128 MB | 11,299 |
| 32 | 128 MB | 42,964 |
| 64 | 4 GB | 26,881 |

c32 → c64에서 TPS가 **떨어지는** 것은 확장성 문제가 아니라 설정이 바뀐 것이다.
여러 실행에서 셀을 모아 붙인 디렉터리로 보이며, 스케일 곡선으로 인용하면 안 된다.

### 4.8 "적당한 버퍼 풀 크기"가 안 잡히는 이유

MySQL 결과 디렉터리마다 `innodb_buffer_pool_size`가 128 MB부터 140 GB까지 흩어져 있는데,
이건 결정을 못 한 게 아니라 **결정할 수 있는 값이 없기 때문**이다. 두 가지가 겹쳐 있다.

**(a) 캐시 총량이 파일시스템마다 다르다 (§4.4).**
`ext4`/`xfs`는 유효 캐시 = 버퍼 풀. `tau`/`ext4-dj`/`zfs`는 버퍼 풀 + page cache(또는 ARC).
187 GB 머신에서 버퍼 풀을 1 GB로 잡으면 앞 그룹은 1 GB, 뒤 그룹은 사실상 100 GB+를 쓴다.
어떤 값을 고르든 한쪽에 유리하다.

**(b) tau의 이득이 버퍼 풀 크기의 함수다.**
같은 데이터셋(`s5000`, 146 GB)에서 `oltp_update_index`:

| `innodb_buffer_pool_size` | thr | `ext4` fpw=on | `ext4` fpw=off | `tau16G` | tau / fpw=on | tau / fpw=off |
|---|---|---|---|---|---|---|
| 16 GB | 32 | 6,214 | 9,585 | 14,494 | **2.33x** | **1.51x** |
| 140 GB | 64 | 105,499 | 140,009 | 111,633 | **1.06x** | **0.80x** |
| 140 GB | 128 | 124,785 | 160,641 | 129,428 | **1.04x** | 0.81x |

(스레드 수가 달라 완전한 통제 비교는 아니지만 방향은 분명하다.)

**버퍼 풀이 DB 전체를 담으면 tau의 이득이 거의 사라진다.** 당연하다 —
DB 146 GB, RAM 187 GB, 버퍼 풀 140 GB면 읽기가 전부 메모리에서 끝나고 dirty page도
버퍼 풀 안에서 계속 재사용되므로, doublewrite가 붙는 flush 경로 자체가 상대적으로
작아진다. 즉 그 조건은 **in-memory DB를 벤치마킹하는 것**이다.

**근본 원인은 버퍼 풀이 아니라 DB/RAM 비율이다.** 장치가 500 GB라 데이터셋을
키우는 데 한계가 있고, 그래서 146 GB DB가 187 GB RAM에 통째로 들어간다.
현실의 OLTP는 DB가 RAM보다 훨씬 크다.

**권장: 버퍼 풀을 고르지 말고 RAM을 고정할 것.**
`run_main.sh` 24~34행에 이미 그 의도의 코드가 주석 처리돼 있다
(`mem=64G` GRUB 제한 + 64 GB 초과 시 중단). 이걸 되살리면

* DB(146~152 GB) > RAM(64 GB)이 되어 캐시가 더 이상 전체를 담지 못한다.
* page cache 여유가 줄어 §4.4의 O_DIRECT/buffered 비대칭도 같이 줄어든다.
* 버퍼 풀은 그 위에서 관례대로 RAM의 50~75%(= 32~48 GB)로 잡으면 근거를 댈 수 있다.

PG 쪽에는 이미 예비 측정이 하나 있다 —
`sosp2026/64GB_DRAM_20260327_215252` vs `187GB_20260327_234010`,
`oltp_write_only`/`ext4-tau`/c64: **32,575 vs 35,139 TPS (−7%)**.
hot working set이 1.6 GB뿐이라(§1.3) DRAM을 1/3로 줄여도 7%밖에 안 잃는다.
**즉 `mem=64G`는 PG 쪽에서는 거의 공짜로 실험 정당성을 사 오는 셈이다.**
MySQL 쪽에는 같은 대조가 없으니 한 셀 재 두면 좋다.

### 4.9 쓰기량: canonical 결과는 tau가 `fpw=off`보다 **더 쓴다**

> **먼저 디렉터리 규칙.** 결과는 이름이 붙은 디렉터리(`io_main`, `main_all`, `io_{fs}_*`,
> `main_{fs}_*`)가 canonical이고, `20260415_095006`처럼 **날짜만 있는 디렉터리는 scratch**다.
> 아래는 canonical만 쓴다.

#### PostgreSQL — `postgres/sosp2026/io_main` (40셀 전부 정확히 32,000,000 이벤트)

이벤트당 쓰기량(KB):

| 워크로드 | ext4 off | ext4 on | **ext4-tau** | xfs off | xfs on | **xfs-tau** | ext4-dj20 | zfs-8k |
|---|---|---|---|---|---|---|---|---|
| `oltp_write_only` | 40.62 | 69.32 | **52.61** | 41.26 | 69.04 | **58.97** | 113.65 | 116.83 |
| `oltp_update_index` | 13.39 | 23.24 | **17.23** | 13.51 | 22.94 | **19.16** | 43.22 | 39.05 |
| `oltp_update_non_index` | 4.96 | 11.30 | **8.82** | 4.89 | 11.38 | **9.59** | 21.18 | 22.93 |
| `oltp_insert` | 4.87 | 6.23 | **5.60** | 4.68 | 5.88 | **6.70** | 18.21 | 9.90 |
| `oltp_delete` | 2.48 | 5.40 | **4.54** | 2.49 | 5.25 | **5.76** | 9.28 | 10.56 |

`ext4 fpw=off = 1.00`으로 정규화:

| 워크로드 | ext4 on | **ext4-tau** | **xfs-tau** | ext4-dj20 | zfs-8k |
|---|---|---|---|---|---|
| `oltp_write_only` | 1.71 | **1.30** | 1.45 | 2.80 | 2.88 |
| `oltp_update_index` | 1.74 | **1.29** | 1.43 | 3.23 | 2.92 |
| `oltp_update_non_index` | 2.28 | **1.78** | 1.93 | 4.27 | 4.63 |
| `oltp_insert` | 1.28 | **1.15** | 1.37 | 3.74 | 2.03 |
| `oltp_delete` | 2.17 | **1.83** | 2.32 | 3.74 | 4.25 |

**tau는 언제나 `fpw=off`와 `fpw=on` 사이에 있다. `fpw=off`보다 적게 쓰는 셀은 하나도 없다.**
이게 canonical한 답이고, 물리적으로도 이래야 맞다 — PostgreSQL은 기본이 buffered I/O라
(`io_direct`는 PG 17에서도 기본 off) **baseline과 tau가 같은 I/O 모드**다. 즉 io_main은
I/O 모드 교란이 없는 상태에서 **tau 저널링의 순수 바이트 비용만** 재고 있다:
`fpw=off` 대비 **+15~83%**, `fpw=on` 대비 **−15~24%** 절감.

#### MySQL — 대부분의 IO 측정이 iostat 브래킷 버그로 무효다

**주의: MySQL 쪽 IO 데이터는 두 가지 파일명 규칙으로 흩어져 있다** —
신세대는 `*.iostat`, 구세대는 `*_iostat.log`다. 한쪽만 찾으면 데이터의 절반을 놓친다.
둘을 합치면 MySQL IO 측정 셀은 **67개**다.

##### 근본 원인: `iostat_end`가 iostat을 죽이지 못한다

`bench/scripts/sysbench/run_io.sh`:

```shell
iostat_start() {
    iostat -dmx 1 | grep -E "Device|$SEARCH_PATTERN" > "$LOG_FILE" &
    IOSTAT_PID=$!        # <- 파이프라인의 '마지막' 프로세스 = grep 의 PID
}
iostat_end() { kill "$IOSTAT_PID"; ... }
```

`$!`는 파이프라인의 **마지막** 명령(`grep`)의 PID다. `iostat`은 죽지 않고
다음 write에서 SIGPIPE를 받을 때까지 계속 돈다. 게다가 `grep`이 파일로 쓸 때는
블록 버퍼링을 하므로 kill 시점의 꼬리가 잘린다. 구세대 스크립트에서는
`iostat_start`가 이미지 복원보다 먼저 불린 경우도 있다.

그래서 셀마다 **iostat 창이 실제 측정 구간과 전혀 맞지 않는다.**
`cov = (iostat 초) ÷ (sysbench total time)`을 보면 **0.02 ~ 605** 범위다.

##### 극단적인 예: `taujournal_old_Version_20251101_125258`

이 디렉터리의 tau 셀들은 원본 그대로 읽으면 `oltp_insert` **0.40~0.59 KB/event**,
`oltp_update_index` **0.74~1.14 KB/event**로, 같은 시기 `ext4 fpw=off`
(`ext4_fpw_off_s5000_all20251113_145810`, 같은 s5000, 같은 bp=128M)의
65~122 / 259~522 KB/event보다 **100~400배 적게** 나온다.

하지만 그 창을 열어 보면 1800초 실행에서 **45초만** 잡혔고, 그 45초의 초당 쓰기가

```
1379 → 883 → 190 → 0 → 0 MB/s   (5분위 평균)
```

**0으로 감쇠한다.** 워크로드가 아니라 이미지 복원의 꼬리와 그 뒤 유휴 구간을 찍은 것이다.
반대로 ext4 쪽(`cov` 1.4~7.1)은 복원+로드+워밍업까지 다 포함해 부풀어 있다
(그쪽 창은 888/901/892/882/831 MB/s로 평평하다).
**두 개의 서로 다른 버그가 같은 방향으로 작용해 tau가 100배 싸 보인 것이다.**

##### 품질 필터를 통과하는 셀: 67개 중 16개

`0.90 ≤ cov ≤ 1.15` **그리고** 창 내부 5분위 최대/최소 비 < 3 을 요구하면:

| 워크로드 | size | fs | fpw | thr | bp | cov | **KB/event** | 디렉터리 |
|---|---|---|---|---|---|---|---|---|
| `update_non_index` | t16 | **ext4** | off | 32 | 48 GB | 1.01 | **17.63** | `20260415_124709` |
| `update_non_index` | t16 | **ext4-tau** | off | 32 | 128 MB | 1.03 | **15.00** | `20260415_095006` |
| `update_non_index` | t16 | **xfs-tau** | off | 32 | 128 MB | 1.01 | **11.66** | `20260415_095006` |
| `update_non_index` | t16 | **xfs-tau** | off | 32 | 128 MB | 1.02 | **22.89** | `20260401_140949` |
| `insert` | t16 | ext4-tau | off | 32 | 128 MB | 1.02 | 23.15 | `20260415_095006` |
| `insert` | t16 | xfs-tau | off | 32 | 128 MB | 1.02 | 10.73 | `20260415_095006` |
| `insert` | t16 | xfs-tau | off | 32 | 128 MB | 1.02 | 27.93 | `20260401_140949` |
| `insert` | s5000 | tau16G | off | 16 | 16 GB | 1.01 | 27.67 | `20251202_102252` |
| `update_index` | t16 | xfs-tau | off | 32 | 128 MB | 1.01 | 78.67 | `20260401_140949` |
| `update_index` | s2500 | ext4 | off | 32 | 70 GB | 1.06 | 8.69 | `motiv_volume_*` |
| `update_index` | s2500 | ext4 | on | 32 | 70 GB | 1.06 | 16.77 | `motiv_volume_*` |
| `update_index` | s2500 | xfs | off | 32 | 70 GB | 1.06 | 8.44 | `motiv_volume_*` |
| `update_index` | s2500 | xfs | on | 32 | 70 GB | 1.06 | 17.48 | `motiv_volume_*` |
| `update_index` | s2500 | zfs-16k | off | 32 | 70 GB | 1.01 | 65.21 | `motiv_volume_*` |
| `delete` | t16 | xfs-tau | off | 32 | 128 MB | 1.03 | 29.68 | `20260401_140949` |
| `write_only` | t16 | xfs-tau | off | 32 | 128 MB | 1.00 | 187.44 | `20260401_140949` |

##### 이 표가 말해 주는 것

**tau가 `fpw=off`보다 적게 쓴 관찰은 실재한다.** `oltp_update_non_index`, t16, c32에서

```
ext4  fpw=off   17.63   <- 진짜 O_DIRECT, bp 48 GB
ext4-tau        15.00   (-15%)
xfs-tau         11.66   (-34%)   [20260415]
```

**그런데 같은 표가 그 결론을 확정하지 못하게 막는다:**

1. 같은 `xfs-tau`, 같은 t16/c32/bp=128M/fsync/MySQL 8.4.5 조합인데
   **`20260401` 22.89 vs `20260415` 11.66 — 2배 차이**다.
   `oltp_insert`도 27.93 vs 10.73으로 2.6배 벌어진다. 두 셀 모두 `cov`≈1로 깨끗하다.
   2주 사이 tau 쪽에 실제 변화가 있었을 가능성이 높다(4/15 쪽이 처리량도 22% 높다).
   **어느 쪽이 현재 코드인지 확인하기 전에는 두 값 다 쓸 수 없다.**
2. 유일한 non-tau 베이스라인이 **bp 48 GB**이고 tau는 **bp 128 MB**다(375배).
3. `oltp_insert`에는 통과한 non-tau 베이스라인이 **하나도 없다**
   (`20260415_124709`의 insert 셀은 277초에 중단, `motivation_test_(insert)`는 cov 3.9~8.2).

##### [2026-08-22 정정] 아래 메커니즘 설명은 실측으로 반증됐다

§4.12의 통제 실험에서 `innodb_flush_method`를 O_DIRECT → fsync로만 바꾼 효과는
4개 조합(ext4/xfs x update_non_index/insert)에서 각각
**−4.9% / −1.6% / −3.5% / +0.3%** — 사실상 0이다. `innodb_flush_method=fsync`여도
InnoDB는 flush 배치마다 데이터 파일에 `fsync()`를 걸므로 page cache에 지연 병합의
여지가 없다. 아래 문단이 이 항을 빠뜨렸다. 실제 결론은 §4.12를 볼 것.

##### (반증된 설명) 메커니즘은 §4.3~4.4로 설명된다

효과의 방향은 예측과 맞는다 — MySQL에서는 baseline만 진짜 O_DIRECT라
InnoDB의 flush 한 번이 곧 장치 쓰기 한 번인데,
`innodb_io_capacity=10000`(8.4 기본값) + redo 100 MB 조합에서 page cleaner가
hot 페이지를 반복해서 내리므로 그 반복이 전부 바이트로 나간다.
buffered인 tau 쪽은 그 반복이 page cache에서 합쳐진다.
PostgreSQL `io_main`이 반대로 나오는 것(§ 위 표)도 같은 이론으로 설명된다 —
PG는 양쪽 다 buffered라 흡수 조건이 같고, 그래서 tau 저널링 비용(+15~83%)만 남는다.

**즉 가설은 일관되지만, MySQL 데이터로는 아직 증명되지 않았다.**
§6의 4b 셀 하나면 끝난다.

##### 먼저 고쳐야 할 것: `iostat_start`

```shell
iostat_start() {
    iostat -dmx 1 > "${LOG_FILE}.raw" &     # 파이프 없이 직접 리다이렉트
    IOSTAT_PID=$!                            # 이제 진짜 iostat 의 PID
}
iostat_end() {
    kill "$IOSTAT_PID" 2>/dev/null
    wait "$IOSTAT_PID" 2>/dev/null
    grep -E "Device|$SEARCH_PATTERN" "${LOG_FILE}.raw" > "$LOG_FILE"   # 사후 필터
    rm -f "${LOG_FILE}.raw"
}
```

추가로 sysbench 시작/종료 시각을 `.spec`에 기록해 두면 나중에 `cov`를 검증할 수 있다.
지금은 `total time`과 iostat 줄 수를 비교하는 것이 유일한 사후 검증 수단이다.

## 4.10 실행 환경 함정 (2026-08-21 확인)

`6.8.0tjournal+`(#208, 커널 HEAD `5a0b8734fcf8`)로 베어메탈 재부팅한 뒤 확인한 것들.

### 부팅 메모리가 결과에 들어가는데 기록되지 않는다 ★

`/etc/default/grub`에 주석 처리된 커맨드라인이 셋 있다:

```
#GRUB_CMDLINE_LINUX_DEFAULT="intel_iommu=off mem=106496M pci=realloc"      # 104 GB
#GRUB_CMDLINE_LINUX_DEFAULT="maybe-ubiquity intel_iommu=on mem=79872M ..."  #  78 GB
#GRUB_CMDLINE_LINUX_DEFAULT="mem=32G"                                       #  32 GB
```

즉 과거 성능 측정은 **메모리를 제한하고 부팅**했다. 그런데 `.spec`에도 `.log`에도
**RAM 크기가 기록되지 않는다.** PG 쪽은 디렉터리 이름(`64GB_DRAM_*`, `187GB_*`)으로만
겨우 구분된다.

**그래서 §4.9의 `xfs-tau` 4/1 vs 4/15 2배 차이에는 후보가 둘이다:**

1. 커널 변경 — 두 실행 사이에 tau 커밋이 있었다:

   | 커밋 | 날짜 | 제목 |
   |---|---|---|
   | `32a81fa79b75` | 2026-04-13 | memory management improved |
   | `aa182dcf1125` | 2026-04-12 | **eager checkpoint bug fix** ← 쓰기량 2배 변화의 유력 후보 |
   | `426737cb58ca` | 2026-04-12 | bug fixed, postgre/mysql test done |
   | `906cd8b8ddd6` | 2026-04-01 | fix xfs (4/1 실행은 이 근처에서 빌드) |

2. **부팅 메모리가 달랐을 가능성.** buffered인 tau는 page cache 크기가 곧
   write coalescing 여력이므로(§4.9), `mem=32G`와 187 GB는 쓰기량을 2배 가를 수 있다.

**둘을 사후에 구분할 방법이 없다.** 앞으로는 `.spec`에 `MemTotal`과 커널 커밋 해시를
반드시 남길 것. (`run_mysql_tau_trend.sh`는 남긴다.)

### `common.sh`의 xfs-tau mkfs가 이 머신에서 동작하지 않는다

```shell
xfs-tau) sudo mkfs.xfs $DEVICE -f -l tjmaxsize=1G ;;   # common.sh
```

`mkfs.xfs`를 PATH에서 찾는데, `set_env.sh`가 앞에 붙이는 `$TAUFS_ROOT/tools/bin`은
**존재하지 않는 디렉터리**다. 따라서 stock `/usr/sbin/mkfs.xfs`(6.16.0)가 잡히고,
그건 `tjmaxsize`를 모른다. 패치된 바이너리는
`$TAUFS_ROOT/xfsprogs-dev/mkfs/mkfs.xfs`이므로 **절대 경로로 부를 것.**
(`e2fsprogs`는 common.sh가 이미 절대 경로를 쓴다.)

### 장치 이름이 재부팅마다 바뀐다 — 그리고 옆자리에 남의 데이터가 있다

`set_env.sh`의 `TARGET_DISK`가 `"SAMSUNG MZPLJ3T2HBJR-00007"`(3.2 TB)로 바뀌어 있다.
`"Samsung SSD 980 PRO"` 줄은 주석 처리됨. 980 PRO는 **두 개**라
모델 문자열 매칭이 어느 쪽을 잡을지는 열거 순서에 달려 있다.

2026-08-21 기준 실제 상태:

| 노드 | 장치 | 내용 |
|---|---|---|
| `/dev/nvme0n1` | 980 PRO 500 GB | 파일시스템 없음 (비어 있음) |
| `/dev/nvme1n1` | 980 PRO 500 GB | **다른 사람 데이터** — `pg-benchmarks` 87 GB, `page-eviction-tracker` |
| `/dev/nvme2n1` | MZPLJ 3.2 TB | 현재 `TAU_DEVICE`. 스크래치 파일만 |
| `/dev/nvme3n1` | Optane 375 GB | **다른 uid의 PostgreSQL 클러스터** |

**2026년 4월 결과의 `nvme1n1`은 지금 남의 데이터 디스크다.** `.spec`의 SMART
스냅샷도 2025년은 `nvme0n1`, 2026년 4월은 `nvme1n1`으로 찍혀 있어
디스크 단위 비교(SMART delta)는 실행 간에 이어 붙일 수 없다.

### 백업 이미지가 이 머신에 없다

`TAU_BACKUP_ROOT=/mnt/tau_backup`은 비어 있고 마운트되지 않았으며,
`BACKUP_DISK="PM1753V8TLC"`는 `nvme list`에 없다.
게다가 그 블록은 `set_env.sh`의 중간 `return` 아래라 **원래 실행되지도 않는다**
(`TAUFS_ENV_SOURCED`도 마찬가지). `bench/scripts/env_local.sh`가 이 구멍들을 메운다.

## 4.11 실측 (2026-08-21, 커널 `5a0b8734fcf8` / `6.8.0tjournal+` #208)

결과: `results/sysbench/mysql/trend_20260821_170528/`,
스크립트: `bench/scripts/sysbench/run_mysql_tau_trend.sh`.

**경향성 전용 설정이다.** 8 tables x 5M rows (~10 GB), mysqld는 cgroup
`MemoryMax=4G`(호스트는 187 GB 무제한 부팅), 셀마다 mkfs + 재로드,
고정 8M 이벤트, c32. `.spec`에 커널 커밋 / 호스트 RAM / 메모리 캡 / 저널 상한을 기록한다.
**tau 전용 커널이라 `ext4`/`xfs` baseline 셀은 없다.**
iostat 창은 전 셀 `cov` 1.00~1.03 (§4.9의 브래킷 버그 수정 후).

| 셀 | fs | bp | flush | TPS | **KB/event** |
|---|---|---|---|---|---|
| `update_non_index` | xfs-tau | 128M | fsync | 37,983 | **10.96** |
| `update_non_index` | xfs-tau | 512M | fsync | 37,173 | **9.96** |
| `update_non_index` | xfs-tau | 2G | fsync | **10,735** | **22.29** |
| `update_non_index` | ext4-tau | 128M | fsync | 9,840 | 23.25 |
| `update_non_index` | ext4-tau | 128M | **O_DIRECT** | 9,456 | 23.05 |
| `insert` | xfs-tau | 128M | fsync | 33,503 | 25.95 |
| `insert` | ext4-tau | 128M | fsync | **4,063** | **55.16** |

### (1) §4.3 확인 — tau 위에서 InnoDB의 `O_DIRECT`는 무효다

같은 ext4-tau / bp=128M에서 `innodb_flush_method`만 바꾼 대조:

```
fsync    :  9,840 TPS   23.25 KB/event
O_DIRECT :  9,456 TPS   23.05 KB/event      (TPS -3.9%, 쓰기량 -0.9%)
```

**차이가 없다.** `ext4_dio_alignment()`가 tau inode에 0을 반환해
모든 쓰기가 buffered로 되돌아간다는 코드 분석(§4.3)이 실측으로 확인됐다.
InnoDB가 보고하는 `innodb_flush_method` 값은 tau 위에서 **동작에 영향이 없다.**

즉 §3.6이 지적한 "ext4-tau(O_DIRECT) vs xfs-tau(fsync)" 교란은
**flush_method 때문이 아니다.** 실제 원인은 아래 (2)다.

### (2) §4.6 수정 — 저널 상한은 p99뿐 아니라 처리량을 지배한다

`ext4-tau`와 `xfs-tau`의 저널 상한을 **둘 다 1 GB로 맞추자** 순위가 뒤집혔다:

| 워크로드 | xfs-tau | ext4-tau | ext4-tau 손해 |
|---|---|---|---|
| `update_non_index` | 37,983 TPS / 10.96 KB | 9,840 / 23.25 | **3.9x 느림, 2.1x 씀** |
| `insert` | 33,503 / 25.95 | 4,063 / 55.16 | **8.2x 느림, 2.1x 씀** |

2026-04-15 실행의 `ext4-tau`(저널 **32 GB**)는 15.00 / 23.15 KB/event였다.
같은 코드베이스 계열에서 저널만 1 GB로 줄이자 23.25 / 55.16으로
**1.6배 / 2.4배 악화**했다. 처리량도 함께 무너졌다(sysbench가 CPU 9%,
mysqld 219%로 완전한 I/O 대기).

**따라서 기존 MySQL의 `ext4-tau` vs `xfs-tau` 비교는 저널 상한 32배 차이가
지배하고 있었다.** 문서가 이전에 "상한 차이는 p99에만 영향"이라고 적어둔 것은 틀렸다.
xfs-tau는 같은 1 GB에서 멀쩡하므로, 저널 공간 압박에 대한 대응이
ext4(buffer_head) 경로와 XFS(iomap) 경로에서 크게 다르다는 뜻이다 — 조사할 가치가 있다.

### (3) §4.8 보강 — 메모리 예산이 고정되면 버퍼 풀은 키울수록 손해다

`xfs-tau` / `update_non_index` / cgroup 4 GB 고정:

| bp | TPS | KB/event |
|---|---|---|
| 128M | 37,983 | 10.96 |
| 512M | 37,173 | 9.96 |
| **2G** | **10,735** | **22.29** |

128M → 512M은 평평하고(-2% / -9%), 512M → 2G에서 **처리량 3.5배 하락, 쓰기량 2.2배**.
tau의 write coalescing은 page cache에서 일어나므로(§4.9),
고정 예산에서 버퍼 풀을 키우는 것은 **coalescing 공간을 빼앗는 것**이다.
일반적인 InnoDB 튜닝 지침(버퍼 풀 = RAM의 50~75%)과 정반대다.

이는 §4.8의 "과거 bp 128M→1G의 1.7배"를 다시 해석하게 한다 —
그 실행들은 호스트 메모리가 무제한이어서 버퍼 풀을 키우면 **캐시 총량이 늘었다.**
고정 예산에서 재분배만 하면 이득이 없거나 오히려 해롭다.
**즉 tau에서 조정해야 할 변수는 버퍼 풀 크기가 아니라 메모리 총 예산이다.**

미확정: 512M과 2G 사이가 비어 있어 절벽 위치를 모른다(hot working set은 약 0.9 GB로 추정).
cgroup reclaim 스래싱 가능성은 배제하지 못했다 — dmesg에 OOM/BUG는 없었지만
`memory.events`의 `high`/`max` 카운터를 덤프하지 않았다. 다음 실행에 추가할 것.

### (4) §4.9의 4d — 4월의 2배 차이는 단일 원인이 아니다

`xfs-tau`, 같은 워크로드/스레드 기준:

| 워크로드 | 2026-04-01 | 2026-04-15 | **2026-08-21 (현재)** | 붙는 쪽 |
|---|---|---|---|---|
| `update_non_index` | 22.89 | 11.66 | **10.96** | 4/15 |
| `insert` | 27.93 | 10.73 | **25.95** | **4/1** |

두 워크로드가 **반대 방향으로 붙는다.** 커널 버전이 둘을 함께 옮긴 단일 효과였다면
이렇게 갈릴 수 없다.

단, `oltp_insert`는 축소판과 원본이 같은 영역에 있지 않다 —
테이블 증가율이 이번 실행은 +20%(40M행에 8M행 추가), 원본은 +5%(640M행에 32M행)다.
`update_non_index`는 테이블 크기가 불변이라 스케일에 둔감했고
(10.96 vs 11.66, 데이터셋이 1/12인데도 일치), insert에는 그 논리가 적용되지 않는다.
**`insert` 항목은 원본 스케일에서 다시 재기 전까지 판단 보류.**

### 남은 것

이번 실행은 tau 전용 커널이라 **`ext4`/`xfs` baseline이 없다.**
따라서 원래 질문 — "MySQL에서 tau가 `fpw=off`보다 적게 쓰는가" — 은 여전히 미해결이다.
`6.8.0+`로 재부팅해 같은 스크립트로 `ext4`(O_DIRECT) / `ext4`(fsync) 셀을 채우면
§6의 4b가 완성된다. 위 (1)에서 flush_method가 tau 위에서 무효임이 확인됐으므로,
그 baseline 두 개가 coalescing 이득과 tau 저널 비용을 깨끗하게 분리해 줄 것이다.

## 4.12 전체 비교 실측 (2026-08-22) — MySQL, ext4 / xfs / tau 16셀

결과: `results/sysbench/mysql/trend_20260822_124028/`.
t8 x 5M rows (~10 GB), cgroup `MemoryMax=4G`, c32, **고정 4M 이벤트**, 셀마다 mkfs+재로드,
tau 저널 상한 **1 GB로 통일**, `innodb_flush_method`는 **셀마다 명시**.
전 셀 iostat `cov` 1.00~1.02.

> **설계 의도 (사용자 확인, 2026-08-24): RDBMS 기본값은 일부러 그대로 둔다.**
> 목표가 **I/O가 포화된 영역**에서의 거동을 보는 것이므로,
> `innodb_redo_log_capacity=100MB`, `log_bin=ON`, `sync_binlog=1`,
> `innodb_io_capacity=10000` 등 8.4 기본값을 튜닝하지 않고 측정한다.
> 작은 redo는 체크포인트 압박을 상시 유지시켜 flush 경로를 병목으로 만드는데,
> 그것이 바로 관측 대상이다.
>
> 데이터가 이 의도대로 됐음을 확인해 준다 — c=32 이상에서 **모든 구성이
> 장치 `%util` 98.7~99.7%**다(§4.14 실행 기준). 즉 결과는
> "튜닝된 배포에서의 tau"가 아니라 **"I/O 포화 상태에서의 tau"**로 읽어야 하고,
> 그렇게 서술하면 된다. `redo`를 키운 비교는 선택 사항이지
> 이 결과의 전제 조건이 아니다.

**베이스라인을 tau 커널에서 쟀다.** 코드상 문제가 없음은 확인했다 —
XFS의 `FMODE_CAN_ODIRECT` 제거는 `XFS_FEAT_TJOURNAL` 게이트 안에 있고
(`fs/xfs/xfs_file.c:1397`), ext4의 `ext4_dio_alignment()`는 tau inode에만 0을 반환한다.
평문 마운트는 stock과 같은 경로다. 그래도 논문 수치로 쓰려면 stock `6.8.0+`에서 재확인할 것.

### `oltp_update_non_index`

| fs | fpw | flush | TPS | KB/event |
|---|---|---|---|---|
| ext4 | on | O_DIRECT | 36,388 | 20.52 |
| ext4 | off | O_DIRECT | 39,919 | 14.00 |
| ext4 | off | fsync | 41,007 | 13.32 |
| **ext4-tau** | off | fsync | **9,784** | **23.75** |
| xfs | on | O_DIRECT | 31,958 | 17.83 |
| xfs | off | O_DIRECT | 35,833 | 11.30 |
| xfs | off | fsync | 37,342 | 10.91 |
| **xfs-tau** | off | fsync | **35,551** | **10.99** |

### `oltp_insert`

| fs | fpw | flush | TPS | KB/event |
|---|---|---|---|---|
| ext4 | on | O_DIRECT | 27,829 | 41.63 |
| ext4 | off | O_DIRECT | 34,416 | 24.53 |
| ext4 | off | fsync | 37,887 | 24.13 |
| **ext4-tau** | off | fsync | **4,053** | **55.94** |
| xfs | on | O_DIRECT | 24,848 | 36.97 |
| xfs | off | O_DIRECT | 30,613 | 20.89 |
| xfs | off | fsync | 34,695 | 20.95 |
| **xfs-tau** | off | fsync | **32,137** | **23.97** |

### (1) buffered I/O 가설 반증

`fpw=off` 고정, O_DIRECT → fsync만 변경:

| | update_non_index | insert |
|---|---|---|
| ext4 | 14.00 → 13.32 (**−4.9%**) | 24.53 → 24.13 (**−1.6%**) |
| xfs | 11.30 → 10.91 (**−3.5%**) | 20.89 → 20.95 (**+0.3%**) |

**쓰기량은 안 변한다.** §4.9가 예측한 3~6배 coalescing 이득은 없다.
`innodb_flush_method=fsync`여도 InnoDB는 flush 배치마다 `fsync()`를 걸므로
page cache가 병합할 시간이 없다 — 이 항을 §4.9가 빠뜨렸다.

단 **처리량은 buffered가 낫다**(ext4 insert +10%, xfs insert +13%).
바이트가 아니라 지연/큐 깊이의 문제다(§4.9의 request 통계와 일치).

### (2) doublewrite가 실제로 무는 비용

`fpw=on → off` (O_DIRECT 고정): ext4 −32% / −41%, xfs −37% / −43%.
**즉 InnoDB doublewrite는 쓰기량의 3분의 1에서 5분의 2를 차지한다.**

### (3) ★ XFS에서 tau 저널링은 거의 공짜다

`xfs-tau`를 두 기준과 비교:

| | vs `xfs fpw=on`(안전) | vs `xfs fpw=off fsync`(무보장, 캐시 조건 동일) |
|---|---|---|
| `update_non_index` 쓰기 | **0.62x (−38%)** | 1.007x (+0.7%) |
| `update_non_index` TPS | **1.11x** | 0.95x |
| `insert` 쓰기 | **0.65x (−35%)** | 1.14x (+14%) |
| `insert` TPS | **1.29x** | 0.93x |

**tau는 doublewrite가 무는 비용을 거의 전부 회수하면서, 그 대가로
같은 I/O 모드의 무보장 구성 대비 쓰기 0~14% / 처리량 5~7%만 지불한다.**

이것이 §4.9의 서사를 대체한다. 정확한 주장은
"tau가 `fpw=off`보다 적게 쓴다"가 아니라:

> tau는 `fpw=on` 대비 쓰기를 35~38% 줄이고 처리량을 11~29% 올리면서,
> 아무 보장도 하지 않는 `fpw=off`와 사실상 동률이다.
> 즉 **파일 단위 저널링의 비용이 측정 한계 근처다.**

저널+체크포인트로 2배가 붙어야 할 텐데 안 붙는 이유는
덮어써진 블록의 제자리 쓰기가 체크포인트에서 버려지기 때문으로 보인다.
`TE_chkpt_drop_blocks` / `TA_coalesced_blocks` 카운터(§4.9)가 이를 직접 증명할 수 있다.
**이 검증이 다음 우선순위다.**

### (4) ★ [2026-08-23 정정] ext4-tau의 붕괴는 내가 만든 인공물이었다

**2026-08-22 실행은 tau 저널 상한을 양쪽 다 1 GB로 "맞췄다".**
그 결과 `ext4-tau`가 안전한 baseline보다도 나빠 보였고, 나는 그것을
"ext4 통합 경로의 결함"으로 기술했다. **틀렸다.**
저널 공간은 128 MB 세그먼트로 **동적 할당**되므로 상한을 크게 잡아도 비용이 없고,
1 GB는 이 부하에서 ext4-tau의 정상 동작 영역을 벗어난 값이었다.
숫자만 맞추고 동작 조건을 깨뜨린 잘못된 통제였다.

`tjournal_size=32` / `-l tjmaxsize=32G`(양쪽 32 GB)로 다시 재면
(`results/sysbench/mysql/trend_20260823_041822/`):

| | 저널 1 GB | **저널 32 GB** | 변화 |
|---|---|---|---|
| `ext4-tau` `update_non_index` | 23.75 KB/ev, 9,784 TPS | **13.28, 41,118** | 쓰기 **−44%**, 처리량 **4.2x** |
| `ext4-tau` `insert` | 55.94, 4,053 | **25.06, 38,232** | 쓰기 **−55%**, 처리량 **9.4x** |
| `xfs-tau` `update_non_index` | 10.99, 35,551 | 11.21, 35,100 | +2% / −1% |
| `xfs-tau` `insert` | 23.97, 32,137 | 24.78, 33,391 | +3% / +4% |

**남는 진짜 발견은 민감도의 비대칭이다** — 같은 1 GB에서 XFS 경로는 멀쩡하고
ext4 경로만 무너진다. "ext4-tau가 느리다"가 아니라
"ext4 경로가 저널 공간 압박에 훨씬 취약하다"가 정확한 서술이며,
이것은 여전히 커널 쪽에서 볼 항목이다.

**주의:** XFS는 `-l tjmaxsize=`를 생략하면 기본이 **장치의 약 10%**다
(3.2 TB 장치에서 ~320 GB). ext4의 마운트 기본값 32 GB와 맞추려면 **명시해야 한다.**
`common.sh`는 현재 `xfs-tau`에 `tjmaxsize=1G`를 주고 있는데, 이 값이면
위 실험이 보여주듯 파일시스템 간 비교가 왜곡될 수 있다.

### 최종 표 (tau 저널 32 GB, 나머지 조건 동일)

> **6개 워크로드 전체는 §4.13을 볼 것.** 아래는 그중 2개다.

`oltp_update_non_index`:

| fs | fpw | flush | TPS | KB/event | vs `fpw=on` 쓰기 | vs `fpw=off fsync` 쓰기 |
|---|---|---|---|---|---|---|
| ext4 | on | O_DIRECT | 36,388 | 20.52 | 1.00 | |
| ext4 | off | O_DIRECT | 39,919 | 14.00 | 0.68 | |
| ext4 | off | fsync | 41,007 | 13.32 | 0.65 | 1.00 |
| **ext4-tau** | off | fsync | **41,118** | **13.28** | **0.65** | **1.00** |
| xfs | on | O_DIRECT | 31,958 | 17.83 | 1.00 | |
| xfs | off | O_DIRECT | 35,833 | 11.30 | 0.63 | |
| xfs | off | fsync | 37,342 | 10.91 | 0.61 | 1.00 |
| **xfs-tau** | off | fsync | **35,100** | **11.21** | **0.63** | **1.03** |

`oltp_insert`:

| fs | fpw | flush | TPS | KB/event | vs `fpw=on` 쓰기 | vs `fpw=off fsync` 쓰기 |
|---|---|---|---|---|---|---|
| ext4 | on | O_DIRECT | 27,829 | 41.63 | 1.00 | |
| ext4 | off | O_DIRECT | 34,416 | 24.53 | 0.59 | |
| ext4 | off | fsync | 37,887 | 24.13 | 0.58 | 1.00 |
| **ext4-tau** | off | fsync | **38,232** | **25.06** | **0.60** | **1.04** |
| xfs | on | O_DIRECT | 24,848 | 36.97 | 1.00 | |
| xfs | off | O_DIRECT | 30,613 | 20.89 | 0.57 | |
| xfs | off | fsync | 34,695 | 20.95 | 0.57 | 1.00 |
| **xfs-tau** | off | fsync | **33,391** | **24.78** | **0.67** | **1.18** |

### 결론

두 파일시스템, 두 워크로드에서 일관된다:

| | `fpw=on`(안전) 대비 | `fpw=off fsync`(무보장, 캐시 동일) 대비 |
|---|---|---|
| 쓰기량 | **0.60 ~ 0.67x (−33~40%)** | 1.00 ~ 1.18x |
| 처리량 | **1.10 ~ 1.37x** | 0.94 ~ 1.01x |

> **tau는 InnoDB doublewrite가 무는 비용(쓰기량의 32~43%)을 거의 전부 회수하면서,
> 아무 보장도 하지 않는 동일 I/O 모드 구성 대비 쓰기 0~18% / 처리량 −6~+1%만 지불한다.**

즉 파일 단위 저널링의 비용이 대부분의 셀에서 측정 한계 근처다.
가장 비싼 셀은 `xfs-tau` + `insert`(+18%)로, 파일이 계속 자라는 워크로드다.

### 남은 것

* `oltp_insert`의 tau 값은 축소판 의존성이 있다 — 이번 실행은 4M 이벤트로
  테이블이 +10% 자라고, 원본(t16 x 40M, 32M 이벤트)은 +5%다.
  `update_non_index`는 테이블 크기가 불변이라 이 문제가 없다(§4.11에서 스케일 무관 확인).
* `memory.events` 덤프를 넣었으므로, bp 스윕을 다시 돌리면 §4.11 (3)의
  절벽이 page cache 압박인지 reclaim 스래싱인지 가릴 수 있다.
* stock `6.8.0+`에서 baseline 재확인.

## 4.13 전체 매트릭스 (2026-08-23) — MySQL, 6 워크로드 x 8 구성 = 48셀

결과: `trend_20260822_124028` + `trend_20260823_041822` + `trend_20260823_135037`.
t8 x 5M rows (~10 GB), cgroup `MemoryMax=4G`, c32, 셀마다 mkfs+재로드,
tau 저널 상한 **32 GB**(양쪽), `innodb_flush_method` **셀마다 명시**,
`innodb_buffer_pool_size=128M`. 전 셀 iostat `cov` **1.00~1.09**.

이벤트 수는 워크로드마다 다르다(문장 수를 대략 맞추기 위해):
`update_non_index`/`insert`/`update_index` 4M, `delete`/`write_only` 1M,
`read_write` 500k. **워크로드 간 KB/event를 직접 비교하지 말 것** — 비교는
워크로드 안에서 파일시스템/구성끼리만 유효하다.

### 이벤트당 쓰기량 (KB)

| 구성 | upd_non_idx | insert | upd_idx | delete\* | write_only | read_write |
|---|---|---|---|---|---|---|
| ext4 fpw=on O_DIRECT | 20.52 | 41.63 | 74.22 | 31.53 | 198.36 | 245.78 |
| ext4 fpw=off O_DIRECT | 14.00 | 24.53 | 42.63 | 17.89 | 108.19 | 143.54 |
| ext4 fpw=off fsync | 13.32 | 24.13 | 49.46 | 19.12 | 124.48 | 173.98 |
| **ext4-tau fpw=off fsync** | **13.28** | **25.06** | **59.36** | **20.90** | **154.20** | **213.96** |
| xfs fpw=on O_DIRECT | 17.83 | 36.97 | 73.43 | 28.90 | 192.30 | 232.19 |
| xfs fpw=off O_DIRECT | 11.30 | 20.89 | 41.10 | 15.84 | 101.60 | 129.83 |
| xfs fpw=off fsync | 10.91 | 20.95 | 47.83 | 16.62 | 116.80 | 158.65 |
| **xfs-tau fpw=off fsync** | **11.21** | **24.78** | **57.35** | **20.14** | **151.88** | **207.73** |

\* `delete`는 1M 이벤트에서도 **48.5%가 0행 매칭 no-op**이다(`write` 514,953 /
`other` 485,047). 원인은 행 수가 아니라 `--rand-type=special`이다(§1.3, §2.2).
모든 구성이 동일하게 고갈되므로 셀 간 비교는 유효하지만, 절대값은
"실제 삭제 1건당"의 약 절반이다.

### TPS

| 구성 | upd_non_idx | insert | upd_idx | delete | write_only | read_write |
|---|---|---|---|---|---|---|
| ext4 fpw=on | 36,388 | 27,829 | 21,130 | 43,022 | 8,500 | 4,830 |
| ext4 fpw=off O_DIRECT | 39,919 | 34,416 | 26,247 | 51,751 | 11,400 | 5,521 |
| ext4 fpw=off fsync | 41,007 | 37,887 | 28,134 | 56,074 | 12,288 | 5,211 |
| **ext4-tau** | **41,118** | **38,232** | **25,379** | **53,735** | **10,747** | **5,176** |
| xfs fpw=on | 31,958 | 24,848 | 17,621 | 36,772 | 7,414 | 4,556 |
| xfs fpw=off O_DIRECT | 35,833 | 30,613 | 22,356 | 43,629 | 10,326 | 5,513 |
| xfs fpw=off fsync | 37,342 | 34,695 | 22,705 | 46,586 | 10,169 | 4,985 |
| **xfs-tau** | **35,100** | **33,391** | **20,690** | **43,975** | **8,826** | **4,702** |

### (1) doublewrite가 무는 비용 — 전 워크로드에서 3분의 1 이상

`fpw=on → off`(O_DIRECT 고정), 쓰기량 배수:

| | upd_non_idx | insert | upd_idx | delete | write_only | read_write |
|---|---|---|---|---|---|---|
| ext4 | 0.68 | 0.59 | 0.57 | 0.57 | **0.55** | 0.58 |
| xfs | 0.63 | 0.57 | 0.56 | 0.55 | **0.53** | 0.56 |

**InnoDB doublewrite는 장치 쓰기량의 32~47%를 차지한다.**
`write_only`에서 가장 크고(−45~47%, 처리량 +34~39%),
`update_non_index`에서 가장 작다(−32~37%).

### (2) ★ tau는 12개 조합 전부에서 정직한 baseline을 이긴다

`tau` vs 자기 파일시스템의 `fpw=on` (쓰기 배수 / TPS 배수):

| | upd_non_idx | insert | upd_idx | delete | write_only | read_write |
|---|---|---|---|---|---|---|
| ext4-tau | 0.65 / 1.13 | 0.60 / 1.37 | 0.80 / 1.20 | 0.66 / 1.25 | 0.78 / 1.26 | 0.87 / 1.07 |
| xfs-tau | 0.63 / 1.10 | 0.67 / 1.34 | 0.78 / 1.17 | 0.70 / 1.20 | 0.79 / 1.19 | 0.89 / 1.03 |

**쓰기 0.60~0.89x (−11~40%), 처리량 1.03~1.37x.** 예외 없다.
이득이 가장 작은 것은 `read_write`(쓰기 −11~13%, TPS +3~7%)로,
유일하게 읽기가 섞여 병목이 flush 경로를 벗어나는 워크로드다(§2.2와 일치).

### (3) ★ tau 저널링의 순비용은 dirtying 산포도에 비례한다

`tau` vs 자기 파일시스템의 `fpw=off fsync`
(= 같은 I/O 모드, 같은 캐시 조건, **아무 보장도 없음**):

| | upd_non_idx | insert | upd_idx | delete | write_only | read_write |
|---|---|---|---|---|---|---|
| ext4-tau 쓰기 | **1.00** | 1.04 | 1.20 | 1.09 | 1.24 | 1.23 |
| xfs-tau 쓰기 | 1.03 | 1.18 | 1.20 | 1.21 | 1.30 | 1.31 |
| ext4-tau TPS | 1.00 | 1.01 | 0.90 | 0.96 | 0.87 | 0.99 |
| xfs-tau TPS | 0.94 | 0.96 | 0.91 | 0.94 | 0.87 | 0.94 |

순비용은 **쓰기 0~31%, 처리량 −13~+1%**이고, 순서가 뚜렷하다:

```
update_non_index (hot 1%에 집중, 같은 블록 반복)   ~0~3%
insert           (append 위주)                     4~18%
delete / update_index (인덱스 랜덤 접근)           9~21%
write_only / read_write (트랜잭션당 다수 페이지)   23~31%
```

**같은 블록을 반복해서 더럽히는 워크로드에서는 tau가 사실상 공짜다** —
저널에 여러 번 써도 덮어써진 제자리 쓰기는 체크포인트에서 버려지기 때문이다.
반대로 매번 다른 블록을 때리면 버릴 것이 없어 저널+체크포인트 비용을 거의 그대로 낸다.
`TE_chkpt_drop_blocks` / `TA_coalesced_blocks` 카운터(§4.9)가 이 설명을 직접 검증한다.

**두 파일시스템의 tau 비용이 6개 워크로드에서 일관되게 근접한다**(대부분 0.0~0.1 차이).
비용을 결정하는 것은 통합 계층(buffer_head vs iomap)이 아니라 워크로드의 접근 패턴이다.

### (4) buffered vs O_DIRECT는 워크로드 의존적이다 (§4.12 (1) 정정)

`fpw=off` 고정, O_DIRECT → fsync 시 쓰기량 변화:

| | upd_non_idx | insert | upd_idx | delete | write_only | read_write |
|---|---|---|---|---|---|---|
| ext4 | −4.9% | −1.6% | **+16%** | +6.9% | **+15%** | **+21%** |
| xfs | −3.5% | +0.3% | **+16%** | +4.9% | **+15%** | **+22%** |

§4.12는 2개 워크로드만 보고 "buffered 전환은 바이트에 영향 없음"이라고 정리했는데,
**흩어진 쓰기 워크로드에서는 buffered가 15~22% 더 쓴다.** 방향과 크기가 두 파일시스템에서
거의 같으므로 파일시스템 특성이 아니라 워크로드 특성이다.

즉 tau의 baseline으로 `fpw=off fsync`를 쓰는 것은 여전히 옳지만(캐시 조건 일치),
그 baseline 자체가 `fpw=off O_DIRECT`보다 최대 22% 비싸다는 점을 함께 밝혀야 한다.
`tau` vs `fpw=off O_DIRECT`로 보면 순비용이 위 표보다 커진다.

### 정리

> MySQL 8.4.5 / InnoDB에서 tau는 **6개 OLTP 워크로드 x 2개 파일시스템 전부**에서
> 정직한 baseline(`innodb_doublewrite=ON`) 대비 **쓰기 11~40% 감소, 처리량 3~37% 증가**를
> 보인다. 그 대가로 아무 보장도 하지 않는 동일 I/O 모드 구성 대비
> **쓰기 0~31%, 처리량 0~13%**를 지불하며, 이 비용은 워크로드가 같은 블록을
> 얼마나 반복해서 더럽히는가에 반비례한다.

### 유보 사항

* 축소판이다 — DB 10 GB, 메모리 캡 4 GB. 절대값이 아니라 배수만 인용할 것.
* 베이스라인을 tau 커널(`6.8.0tjournal+`)에서 쟀다. 코드 경로상 동일함은 확인했으나
  (§4.12 서두) stock `6.8.0+`에서 한 번 재확인하는 편이 안전하다.
* `read_write`/`write_only`는 이벤트 수가 적어(500k/1M) 정상 상태 도달이
  다른 워크로드보다 짧다. `cov`는 모두 1.0대이나 종료 flush 몫이 상대적으로 크다.
* `delete`의 no-op 48.5% 문제는 위 각주 참조.

## 4.14 클라이언트 스케일링 (2026-08-23) — `oltp_write_only`, 30점

결과: `results/sysbench/mysql/trend_20260823_162528/summary_scale.csv`.
구성당 1회 로드 → c32에서 60 s warmup → c = 1/8/16/32/64 각 **180 s**,
점 사이 **45 s 정착**, `--percentile=99`. 전 30점 iostat `cov` 1.00.
`oltp_write_only`는 delete+insert가 같은 id를 재사용해 테이블 크기가 불변이므로
점 사이 재로드가 필요 없다(순서 효과는 모든 구성에서 동일).

### TPS

| 구성 | c=1 | c=8 | c=16 | c=32 | c=64 |
|---|---|---|---|---|---|
| ext4 fpw=on | 652 | 3,670 | 6,339 | 9,292 | 9,146 |
| ext4 fpw=off | 721 | 4,509 | 7,897 | 12,924 | 16,858 |
| **ext4-tau** | 1,313 | 6,290 | 9,325 | 12,856 | 12,747 |
| xfs fpw=on | 599 | 3,501 | 5,732 | 8,213 | 9,027 |
| xfs fpw=off | 688 | 4,207 | 7,167 | 11,474 | 14,899 |
| **xfs-tau** | 1,283 | 5,552 | 7,393 | 10,426 | 11,936 |

### p99 (ms)

| 구성 | c=1 | c=8 | c=16 | c=32 | c=64 |
|---|---|---|---|---|---|
| ext4 fpw=on | 3.30 | 6.67 | 6.91 | 8.74 | 15.55 |
| ext4 fpw=off | 2.43 | 3.49 | 4.57 | 7.30 | 9.39 |
| **ext4-tau** | 1.93 | 6.09 | 4.41 | 7.43 | 10.84 |
| xfs fpw=on | 3.96 | 6.91 | 7.56 | 9.73 | 15.55 |
| xfs fpw=off | 2.66 | 4.41 | 5.57 | 7.84 | 10.27 |
| **xfs-tau** | 2.00 | 6.21 | 5.77 | 7.98 | 11.24 |

### 이벤트당 쓰기량 (KB) — **같은 c 안에서만 비교할 것**

| 구성 | c=1 | c=8 | c=16 | c=32 | c=64 |
|---|---|---|---|---|---|
| ext4 fpw=on | 990.8 | 305.1 | 233.9 | 183.8 | 171.9 |
| ext4 fpw=off | 526.5 | 183.6 | 132.3 | 97.4 | 85.4 |
| **ext4-tau** | 486.3 | 182.6 | 166.6 | 130.5 | 122.3 |
| xfs fpw=on | 987.3 | 285.8 | 226.0 | 178.5 | 160.9 |
| xfs fpw=off | 510.1 | 170.8 | 123.6 | 91.4 | 81.7 |
| **xfs-tau** | 433.6 | 168.8 | 164.9 | 127.1 | 117.2 |

c에 반비례하는 것은 이 설정의 정상 거동이다 — 버퍼 풀 128 MB에 DB 10 GB라
거의 모든 접근이 미스이고, c=1에서는 한 트랜잭션이 적재한 페이지를 그 트랜잭션만
쓰고 evict하지만 c=32에서는 32개가 나눠 쓰므로 상각된다. (c=1 창의 초당 쓰기는
180 s 내내 618~637 MB/s로 평평하다 — warmup 잔여 유출이 아니라 정상 상태다.)

### (1) ★ tau의 이점은 저동시성에서 최대다

TPS 배수 (`tau / fpw=on` · `tau / fpw=off`):

| | c=1 | c=8 | c=16 | c=32 | c=64 |
|---|---|---|---|---|---|
| ext4-tau | 2.02 · 1.82 | 1.71 · 1.39 | 1.47 · 1.18 | 1.38 · 0.99 | 1.39 · 0.76 |
| xfs-tau | 2.14 · 1.87 | 1.59 · 1.32 | 1.29 · 1.03 | 1.27 · 0.91 | 1.32 · 0.80 |

**c=1에서는 tau가 TPS · p99 · 쓰기량 세 지표 모두 6개 구성 중 1위다.**
무보장 `fpw=off`보다도 빠르고(1.82~1.87x), 지연이 낮고(1.93 / 2.00 ms),
쓰기도 적다(486 / 434 vs 527 / 510 KB/ev).

기전은 §4.9의 큐/지연 구조다 — c=1에서는 커밋 지연이 곧 처리량이다.
O_DIRECT는 커밋 경로에서 랜덤 16 KB 쓰기를 장치까지 동기로 내리지만
(`w_await` ~1 ms), tau는 커밋이 **순차 저널 append**로 끝나고 제자리 쓰기를
체크포인트로 미룬다(`w_await` ~0.05 ms). 병렬성으로 지연을 감출 수 없는 구간에서
이 차이가 그대로 처리량이 된다. 동시성이 오르면 O_DIRECT도 큐를 채워
그 불이익이 사라지고, 남는 것은 tau의 저널 비용뿐이다.
`fpw=off`와의 교차점은 **c≈32**(ext4) / **c≈16**(xfs)다.

### (2) ★ doublewrite의 비용은 "포화점을 앞당기는 것"이다

`fpw=on` 대비 `fpw=off` TPS 배수:

| | c=1 | c=8 | c=16 | c=32 | c=64 |
|---|---|---|---|---|---|
| ext4 | 1.11 | 1.23 | 1.25 | 1.39 | 1.84 |
| xfs | 1.15 | 1.20 | 1.25 | 1.40 | 1.65 |

동시성이 오를수록 커진다. **§4.13은 c=32 한 점만 재서 doublewrite 비용을
과소평가했다.** 단일 동시성 지점의 배수로 doublewrite 비용을 말하면 안 된다.

### (3) ★ c=32 포화는 tau 코어가 아니라 **ext4 통합 경로**의 문제다

c=32 → c=64 TPS 변화:

| 구성 | 변화 |
|---|---|
| ext4 fpw=on | -1.6% |
| ext4 fpw=off | +30.4% |
| ext4-tau | -0.8% |
| xfs fpw=on | +9.9% |
| xfs fpw=off | +29.8% |
| xfs-tau | +14.5% |

**`xfs-tau`는 c=64에서 꺾이지 않는다(+14.5%).** 따라서 `ext4-tau`의 c=32 포화(−0.8%)는
tau 코어의 공통 병목이 아니라 **ext4(buffer_head) 통합 경로에 국한된 현상**이다.
§4.12 (4)에서 본 "ext4 경로가 저널 공간 압박에 훨씬 취약하다"와 같은 뿌리일 가능성이 크다.

`TAU_PROFILE`의 `TE_wait_on_prev_commit`, `TE_daemon_do_work`,
`TE_chkpt_flush_blocks`가 이를 직접 가른다. **커널 쪽 최우선 조사 항목.**

### (4) 참고: `fpw=on`의 포화 상한은 두 파일시스템이 같다

ext4는 c=32에서(9,292), xfs는 c=64에서(9,027) 같은 지점에 닿고 p99도 15.55 ms로 동일하다.
**§4.13의 c=32 한 점에서 "xfs가 ext4보다 13% 느리다"고 본 것은 포화점 차이였을 뿐,
상한은 같다.**

### 유보 사항

* **c=64가 측정 범위의 끝이다.** `ext4 fpw=on`과 `ext4-tau`는 꺾이는 것을 봤으므로
  포화가 확인됐지만, `fpw=off` 두 곡선 · `xfs fpw=on` · `xfs-tau`는
  "아직 안 꺾였다"까지만 말할 수 있다. c=128 점을 붙이면 확정된다(6점 ≈ 25분).
* 구성당 1회 로드 후 c=1→64를 연속 측정하므로 뒤쪽 점일수록 churn된 DB를 본다.
  모든 구성에서 순서가 같아 비교는 공정하고, c=32 점들이 §4.13(로드 직후)과
  7~15% 안쪽으로 일치하므로 효과는 작다.
* **`oltp_write_only` 한 워크로드다.** §4.13에서 tau 순비용이 워크로드마다
  0~31%로 갈렸고 `write_only`는 tau에게 가장 불리한 축이므로,
  다른 워크로드에서는 `fpw=off`와의 교차점이 c=32보다 뒤일 가능성이 크다.

## 4.15 PostgreSQL 전체 매트릭스 (2026-08-25) — 6 워크로드 x 6 구성 + WAL 대조

결과: `results/sysbench/postgres/trend_20260825_012956/`,
스크립트 `bench/scripts/sysbench/run_pg_tau_trend.sh`.
MySQL §4.13과 나란히 읽도록 조건을 맞췄다 — 8 tables x 5M rows (~10 GB),
cgroup `MemoryMax=4G`, c32, 셀마다 mkfs+재로드, tau 저널 32 GB,
워크로드별 이벤트 수 동일 비율(8M / 2M / 1M). 전 39셀 `cov` 0.97~1.03.

> **[2026-08-25] 이 절의 결론은 10 GB 규모에 한정된다 — §4.16을 먼저 볼 것.**
> 같은 셀을 원본 스케일(152 GB)에서 재면 방향이 뒤집힌다:
> `ext4-tau`가 `fpw=off`의 **0.79배**(여기) → **2.78배**(원본 스케일)가 된다.
> 아래 표는 축소판 실험의 유효 범위를 보여주는 자료로 읽되,
> **논문 수치로 인용하지 말 것.**

**PG는 구성이 6개다(MySQL은 8개).** PG는 기본이 buffered I/O이고 `io_direct`는
17에서도 off이므로 O_DIRECT/fsync 차원이 아예 없다 — MySQL에서 그 차원이 만든
교란(§4.3~4.4)이 PG에는 존재하지 않는다.

**`max_wal_size`는 `fpw=on`/`fpw=off` 양쪽 모두 기본값 1GB로 두었다.**
`run_main.sh`는 `fpw=on`에만 16GB를 주지만, 축소판에서 그렇게 하면
측정 대상인 FPW 비용이 사라진다 — 아래 (5) 참조.

### 이벤트당 쓰기량 (KB)

| 구성 | upd_non_idx | insert | upd_idx | delete | write_only | read_write |
|---|---|---|---|---|---|---|
| ext4 fpw=on | 8.04 | 5.04 | 22.74 | 4.01 | 61.83 | 75.41 |
| ext4 fpw=off | 4.30 | 3.54 | 10.49 | 2.26 | 28.96 | 39.93 |
| **ext4-tau** | 3.38 | 2.75 | 5.93 | 1.69 | 16.08 | 28.20 |
| xfs fpw=on | 8.05 | 5.11 | 22.67 | 4.04 | 61.77 | 76.75 |
| xfs fpw=off | 4.28 | 3.49 | 10.53 | 2.32 | 29.29 | 41.16 |
| **xfs-tau** | 3.91 | 3.69 | 6.39 | 1.61 | 15.69 | 29.62 |

### TPS

| 구성 | upd_non_idx | insert | upd_idx | delete | write_only | read_write |
|---|---|---|---|---|---|---|
| ext4 fpw=on | 100,410 | 113,972 | 56,821 | 194,431 | 22,424 | 9,602 |
| ext4 fpw=off | 138,469 | 129,620 | 114,597 | 252,175 | 46,990 | 11,104 |
| **ext4-tau** | 143,724 | 130,273 | 120,396 | 257,374 | 46,695 | 11,554 |
| xfs fpw=on | 90,946 | 102,366 | 55,163 | 166,122 | 20,693 | 8,119 |
| xfs fpw=off | 128,333 | 123,879 | 105,002 | 203,187 | 34,267 | 9,401 |
| **xfs-tau** | 139,646 | 124,954 | 113,080 | 229,743 | 41,714 | 9,706 |

### p99 (ms)

| 구성 | upd_non_idx | insert | upd_idx | delete | write_only | read_write |
|---|---|---|---|---|---|---|
| ext4 fpw=on | 0.75 | 0.59 | 1.27 | 0.65 | 3.68 | 5.37 |
| ext4 fpw=off | 0.55 | 0.45 | 0.73 | 0.49 | 1.55 | 4.74 |
| **ext4-tau** | 0.42 | 0.39 | 0.72 | 0.41 | 1.76 | 4.74 |
| xfs fpw=on | 0.92 | 0.69 | 1.55 | 0.94 | 5.99 | 7.84 |
| xfs fpw=off | 0.89 | 0.46 | 1.14 | 0.83 | 4.25 | 6.09 |
| **xfs-tau** | 0.55 | 0.50 | 0.86 | 0.56 | 2.26 | 5.77 |

### (1) ★ tau가 12개 조합 전부에서 `fpw=on`을 이긴다

쓰기 배수 · 처리량 배수:

| | upd_non_idx | insert | upd_idx | delete | write_only | read_write |
|---|---|---|---|---|---|---|
| ext4-tau | 0.42 · 1.43 | 0.55 · 1.14 | 0.26 · 2.12 | 0.42 · 1.32 | 0.26 · 2.08 | 0.37 · 1.20 |
| xfs-tau | 0.49 · 1.54 | 0.72 · 1.22 | 0.28 · 2.05 | 0.40 · 1.38 | 0.25 · 2.02 | 0.39 · 1.20 |

**쓰기 0.25~0.72x, 처리량 1.14~2.12x.** 이득이 가장 큰 것은
`update_index`와 `write_only`(쓰기 0.25~0.28x, 처리량 2.0~2.1x)이고,
가장 작은 것은 `insert`다.

### (2) ★ 12개 중 11개에서 무보장 `fpw=off`보다도 적게 쓴다

| | upd_non_idx | insert | upd_idx | delete | write_only | read_write |
|---|---|---|---|---|---|---|
| ext4-tau | 0.79 · 1.04 | 0.78 · 1.01 | 0.57 · 1.05 | 0.75 · 1.02 | 0.56 · 0.99 | 0.71 · 1.04 |
| xfs-tau | 0.91 · 1.09 | 1.06 · 1.01 | 0.61 · 1.08 | 0.69 · 1.13 | 0.54 · 1.22 | 0.72 · 1.03 |

유일한 예외는 `xfs-tau` + `insert`(1.06x)다.
**MySQL은 정반대였다** — 거기서 tau는 `fpw=off` 대비 쓰기 1.00~1.31x로 항상 손해였다.

| `fpw=off` 대비 tau 쓰기 배수 | upd_non_idx | insert | upd_idx | delete | write_only | read_write |
|---|---|---|---|---|---|---|
| **PG** ext4-tau | 0.79 | 0.78 | 0.57 | 0.75 | 0.56 | 0.71 |
| **MySQL** ext4-tau | 1.00 | 1.04 | 1.20 | 1.09 | 1.24 | 1.23 |

**방향이 워크로드 무게에 따라 반대로 간다** — PG는 무거울수록 tau가 유리해지고,
MySQL은 무거울수록 불리해진다.

**원인은 데이터 파일 fsync 시점이다.**
PG는 데이터 파일을 **체크포인트에서만** fsync한다(커밋 때는 WAL만). 따라서 tau는
체크포인트 간격 전체에 걸쳐 dirty 블록을 모아 두었다가 덮어써진 것을 버릴 수 있다.
InnoDB는 **flush 배치마다** 데이터 파일을 fsync하므로 그 병합 기회가 없다(§4.12 (1)).
즉 tau의 비용/이득은 tau 자체보다 **위층 DB가 언제 fsync를 거는가**로 결정된다.

### (3) ★ PG의 쓰기량은 파일시스템과 무관하다

`ext4`와 `xfs`의 KB/event가 12개 셀 전부에서 1% 안쪽으로 일치한다
(예: `write_only` fpw=on 61.83 vs 61.77). 쓰기량을 정하는 것은 WAL/FPW이고
파일시스템은 **처리량에만** 영향을 준다(ext4가 8~10% 우세).
MySQL에서는 xfs가 ext4보다 쓰기량이 7~10% 적었다 — 대조적이다.

### (4) ★ FPI 직접 계측 — MySQL에서는 못 했던 것

`pg_stat_wal` / `pg_stat_checkpointer`를 셀마다 기록했다. `write_only`, ext4:

| 구성 | wal_records | wal_fpi | wal_bytes | 요청 체크포인트 |
|---|---|---|---|---|
| fpw=off @1GB | 21.04M | **0** | **1.97 GB** | 7 |
| fpw=on @1GB | 21.03M | **6,900,478** | **52.39 GB** | **93** |
| ext4-tau | 21.05M | 0 | 1.97 GB | 7 |
| fpw=on @16GB | 21.05M | 491,964 | 5.90 GB | 4 |

**`full_page_writes`가 WAL 볼륨을 26.6배로 불린다.** 그리고 **체크포인트 피드백 루프**가
보인다 — FPI가 1 GB WAL을 계속 채워 체크포인트가 93회 요청되고, 체크포인트마다
다시 FPI가 발생한다. `fpw=off`는 7회뿐이다.
(`fpi_pct`가 107.9%로 100을 넘는 것은 FPI 레코드가 hole-skipping으로 압축되기 때문에
`wal_fpi x 8192`가 과대평가라서다.)

### (5) ★ 축소판에서는 `max_wal_size`를 반드시 함께 낮춰야 한다

`fpw=on`을 1GB → 16GB로 올렸을 때:

| 워크로드 | fs | 쓰기 | 처리량 |
|---|---|---|---|
| `write_only` | ext4 | 61.83 → 30.54 (**0.49x**) | 22,424 → 43,204 (**1.93x**) |
| `write_only` | xfs | 61.77 → 30.93 (**0.50x**) | 20,693 → 30,966 (1.50x) |
| `update_non_index` | ext4 | 8.04 → 4.73 (0.59x) | 100,410 → 126,935 (1.26x) |

10 GB DB에 16GB WAL 상한이면 실행 중 체크포인트가 크기로 트리거되지 않아
(위 표의 4회 vs 93회) FPI가 페이지당 한 번만 나오고 끝난다.
그 결과 `fpw=on @16GB`(30.54 / 43,204)가 `fpw=off @1GB`(28.96 / 46,990)와
거의 같아진다 — **측정하려던 FPW 비용 자체가 사라진다.**

**원본 스케일(152 GB)에서 합리적이던 `run_main.sh`의 비대칭 설정이
축소판에서는 결과를 무너뜨린다.** 축소 실험을 설계할 때 반드시 함께 조정할 것.

### 미해결: 원본 스케일 `io_main`과 어긋난다

`io_main`(PG, 152 GB, 2026-03)에서 tau는 `fpw=off` 대비 쓰기 **1.15~1.83x**로
항상 더 썼다. 이번 축소판은 **0.54~1.06x**로 방향이 반대다. 후보는 셋:

1. **커널 변경** — `io_main`은 3월, 이번은 8/21 HEAD(`5a0b8734fcf8`).
   그 사이 `eager checkpoint bug fix`(4/12) 등 체크포인트 관련 커밋이 있다.
2. **스케일** — 152 GB vs 10 GB. hot 영역이 작을수록 같은 블록 재-dirty 비율이 높아
   tau의 체크포인트 병합 기회가 커진다.
3. **메모리** — 원본은 187 GB 무제한(또는 미기록 `mem=`), 이번은 cgroup 4 GB.

**(1)이면 큰 개선이고 (2)/(3)이면 축소판 인공물이다.** 현재 커널로 원본 스케일
한 셀(`update_non_index`, ext4-tau, t16 x 40M)만 재면 (1)과 (2)/(3)이 갈린다.
**다음 우선순위.**

### 유보 사항

* 축소판이다. **절대값이 아니라 배수만 인용할 것.**
  `fpw=on`의 KB/event는 원본 대비 19~29% 낮다(FPI 대상 페이지가 적어서).
  따라서 이 표의 tau 이득은 원본 스케일 대비 **보수적**일 가능성이 크다.
* `delete`는 2M 이벤트에서 **61.5%가 0행 매칭 no-op**이다
  (`write` 769,966 / `other` 1,230,034). 원인은 `--rand-type=special`(§1.3).
  모든 구성이 동일하게 고갈되므로 구성 간 배수는 유효하나 절대값은 인용 금지.
* 베이스라인을 tau 커널에서 쟀다(§4.12 서두의 근거 참조).

## 4.16 ★ 원본 스케일 재현 (2026-08-25) — 축소판 결론이 뒤집힌다

결과: `results/sysbench/postgres/trend_20260825_151519/`.
`io_main`의 조건을 그대로 복원했다 — **16 tables x 40M rows (152 GB)**,
32M 이벤트, c32, `shared_buffers=128MB`, `max_wal_size`는 `fpw=on`만 16GB,
**cgroup 메모리 제한 없음**(187 GB), 현재 커널 `5a0b8734fcf8`.
워크로드는 `oltp_update_non_index`. 전 3셀 `cov` 1.00~1.01.

| ext4 | KB/event | TPS | p99 |
|---|---|---|---|
| fpw=on (WAL 16GB) | 10.77 | 92,734 | 0.86 |
| fpw=off (WAL 1GB) | 6.13 | 127,703 | 0.65 |
| **ext4-tau** | **17.05** | 98,941 | 2.07 |

### (1) 축소판 결론이 원본 스케일에서 성립하지 않는다

| `ext4-tau` 대비 | 축소판 10 GB (§4.15) | **원본 152 GB** |
|---|---|---|
| vs `fpw=off` 쓰기 | **0.79x** | **2.78x** |
| vs `fpw=on` 쓰기 | **0.42x** | **1.58x** |
| vs `fpw=on` 처리량 | 1.43x | 1.07x |

**원본 스케일에서 tau는 정직한 baseline보다도 58% 더 쓴다.**
§4.15의 PG 결론은 10 GB 규모에 한정된다.

이유는 §4.13 (3)에서 세운 산포도 가설과 일관된다 — 축소판은 hot 영역이 작아
같은 블록을 반복해서 더럽히므로 tau의 체크포인트 병합이 최대로 작동하지만,
152 GB에서는 dirtying이 흩어져 버릴 것이 없다.
**즉 tau의 이득은 "DB 크기 대비 hot working set 비율"에 민감하다.**

### (2) 그런데 재현이 부분적으로만 됐다 — 별도의 미해결 항목

| | `io_main` (2026-03) | 재현 (2026-08) | 차이 |
|---|---|---|---|
| ext4 fpw=on | 11.30 | 10.77 | **−4.7%** (재현됨) |
| ext4 fpw=off | 4.96 | 6.13 | **+24%** |
| **ext4-tau** | **8.82** | **17.05** | **+93%** |
| ext4-tau TPS | 121,863 | 98,941 | **−19%** |

`fpw=on`이 5% 안쪽으로 맞으므로 데이터셋·스레드·WAL 설정은 제대로 복원됐다.
그런데 **`fpw=off` 계열 두 셀만 어긋나고, tau가 특히 크게(+93%) 나빠졌다.**

후보:
1. **커널 회귀** — 3월 이후 tau 커밋들 중 하나가 원본 스케일에서 역효과.
   축소판에서는 오히려 좋아졌으므로 규모 의존적인 회귀일 수 있다.
2. **기록되지 않은 메모리 크기** — `io_main` 시기(3/25~29)에
   `64GB_DRAM_*` / `187GB_*` 디렉터리가 함께 있어 확정 불가.
   이번 재현은 187 GB 무제한이다.

**이것이 지금 가장 중요한 미해결 항목이다.** 벤치마크 설정 문제가 아니라
커널 회귀라면 성능 표가 아니라 코드를 봐야 한다.
가르는 방법: (a) `mem=64G`로 부팅해 같은 3셀 재실행, (b) 3월 커널을 빌드해 비교.
(a)가 훨씬 싸므로 먼저 할 것.

### (3) 부수 확인: 원본 스케일에서 `max_wal_size` 비대칭은 무해하다

요청된 체크포인트 수:

| 구성 | WAL 상한 | 요청 체크포인트 | wal_fpi | wal_bytes |
|---|---|---|---|---|
| fpw=on | 16GB | **63** | 16,956,534 | 141.6 GB |
| fpw=off | 1GB | 64 | 0 | 9.96 GB |
| ext4-tau | 1GB | 66 | 0 | 9.96 GB |

`fpw=on`이 16GB를 받았는데도 FPI가 141 GB의 WAL을 만들어 체크포인트가
정상적으로 63회 걸린다. 축소판에서는 같은 설정이 4회 vs 93회로 극단적으로 갈렸다(§4.15 (5)).

**즉 `run_main.sh`의 "fpw=on에만 16GB" 설정은 원본 스케일에서 합리적이고,
§3.2와 §4.15 (5)에서 내가 문제 삼은 것은 축소판에 한정된 이야기였다.**
원 설계가 옳았다.

### 축소판 방법론에 대한 교훈

이번 세션의 MySQL 결과(§4.11~4.14)도 모두 10 GB 축소판이다.
PG에서 스케일이 방향을 뒤집었으므로 **MySQL 결과도 원본 스케일에서 재확인해야 한다.**
특히 §4.13 (3)의 "tau 순비용은 dirtying 산포도에 비례" 관찰은
스케일이 산포도를 직접 바꾸므로 가장 취약하다.

축소판이 유효했던 것: `fpw=on`의 절대값(±5%), 체크포인트 거동의 정성적 패턴,
`fpw` on/off 처리량 배수(1.38 vs 1.34).
축소판이 무효였던 것: **tau 관련 배수 전부.**

## 4.17 ★★ tau silent data corruption (2026-08-25) — 성능 실험이 정합성 버그를 잡았다

`mem=64G` 재현 실행(§4.16 (2)의 메모리 가설 검증)의 **tau 셀이 sysbench FATAL로 중단됐다.**
성능 수치가 아니라 이것이 이 실행의 결과다.

```
FATAL: PQexecPrepared() failed: 7 invalid page in block 748637
       of relation base/16384/16487
SQLSTATE XX001 (data_corrupted)
```

**8 KiB PG 페이지의 앞 4 KiB가 통째로 0이고 뒤 4 KiB만 살아남았다.**
PG는 페이지 앞쪽에 헤더+라인 포인터를, 뒤쪽에 튜플을 두므로 사라진 것은 헤더 절반이고,
그래서 PG가 페이지를 거부했다.

**잃어버린 절반이 옛 데이터가 아니라 0이다** — 즉 전형적인 old/new 혼합 torn write가 아니라
**8 KiB 쓰기 중 4 KiB 블록 하나가 아예 기록되지 않은 것**이다.

이것은 `O_TAU_ATOMIC`이 제공하기로 한 보장 그 자체다.
PostgreSQL이 `full_page_writes=off`로 도는 근거가 무너졌다.

### 확정된 사실

1. **전원 차단이 없었다.** 정상 운영 중이며 크래시 복구 경로가 아니다.
2. **디스크에 실제로 그렇게 쓰여 있다.** `-o tjournal` 마운트와 평문 `-o ro` ext4 마운트가
   바이트 단위로 동일하다 — tau 읽기 경로의 착시가 아니다.
3. **익스텐트는 `unwritten`이 아니라 기록됨으로 표시돼 있다**
   (logical 1488896..1499135 -> phys 40732672, len 10240).
   파일시스템은 유효한 데이터가 있다고 믿는다. **애플리케이션 자체 검증 외에는 감지 불가.**
4. **커널은 아무것도 남기지 않았다.** BUG/WARN 없음.
   `tau_commit_all`이 47 트랜잭션 커밋을 계속 정상 보고했다. **silent corruption.**
5. **극히 드물다.** 16개 관계 133 GiB, **17,408,000 페이지 중 1개.**

### 발생 조건

커널 `6.8.0tjournal+` #208 (`5a0b8734fcf8`), `-o tjournal,tjournal_size=32`,
PG 17.5 `full_page_writes=off` / `shared_buffers=128MB` / `max_wal_size=1GB`,
**데이터셋 152 GB / 호스트 RAM 64 GB**, `oltp_update_non_index`, 32 스레드.

실패 시점 dmesg 기준 **저널이 32 GB 중 25~26 GB(약 80%)로 차 있었고 동시 tau 트랜잭션 47개**였다.
**같은 날 10 GB 축소판에서는 재현되지 않았다** — 그 규모에서는 저널이 차지 않는다.

### 미확정

* **로드 단계에서 찢어졌는지 측정 단계에서 찢어졌는지** 알 수 없다.
  두 단계 모두 tau가 활성이었고, PG는 읽을 때만 검증한다.
* 근본 원인. 0으로 채워진 절반 + 기록됨으로 표시된 익스텐트라는 조합은
  일반적인 torn write보다 **커밋 시점 delalloc 할당 / 체크포인트 writeback 경로**를 가리킨다.
  커널 쪽 조사가 필요하다.

### 이 실행의 성능 수치는 무효다

sysbench가 중간에 죽어 `run_s`/`tps`가 파싱되지 않았고(`cov=0.00`),
`summary.csv`의 15.28 KB/event는 명목 이벤트 수 32M으로 나눈 값이다.
`wal_records`(88.0M vs 정상 셀 105M)로 역산하면 실제 이벤트는 약 26.8M이므로 그 값은 틀렸다.
**§4.16의 메모리 가설은 아직 미해결로 남는다** — 이 버그를 고친 뒤 다시 물어야 한다.

다만 두 baseline 셀은 정상 완료했고, 그것만으로도 §4.16 (2)에 대한 부분 답이 나온다:

| ext4 | io_main (3월) | 재현 187 GB | 재현 60 GB |
|---|---|---|---|
| fpw=on | 11.30 | 10.77 | 10.96 |
| fpw=off | **4.96** | 6.13 | 6.58 |

메모리를 3배 줄여도 `fpw=off`가 io_main 쪽(4.96)으로 가지 않고 오히려 조금 멀어진다.
**`fpw=off` baseline이 3월 대비 24~33% 높은 것은 메모리로 설명되지 않는다.**
남는 후보는 커널 변경 또는 io_main의 기록되지 않은 다른 조건이다.

### 증거

`bench/workspace/corruption_evidence/` (자체 `README.md` 포함) —
두 마운트에서 뜬 페이지 덤프, 익스텐트 맵, dmesg, 전체 스캔 결과, `pg_control`,
`postgresql.conf`, 실패한 sysbench 로그.
커널 쪽 기록은 `djournalplus-kernel.code/CLAUDE.md`의 Known Bugs 최상단.

**손상된 파일시스템이 `/dev/nvme1n1`에 그대로 있다
(UUID `5361b2f3-2be4-4991-9eec-4c85b4d9625c`). 다음 벤치 실행이 mkfs로 지운다.**

### 다음 할 일

1. **재현 스크립트.** `tools/tautest`는 크래시 복구를 겨냥하므로 이 경로를 덮지 않는다.
   필요한 조건은 "DB >> RAM + 저널 고수위 + 높은 동시성 + 크래시 없음"이다.
   PG 없이 `tauwrite` 계열로 재현할 수 있으면 반복 실행이 훨씬 싸진다.
2. **검출기.** PG `data_checksums=on`으로 켜고 돌리면 손상을 훨씬 빨리,
   그리고 페이지 단위로 잡을 수 있다. 지금은 헤더가 깨져야만 걸린다.
3. 고친 뒤 §4.16의 성능 질문으로 복귀.

## 5. 정리 — 지금 결과를 인용할 때의 주의사항

1. `oltp_delete`의 절대 TPS(500k+)는 **약 90%가 0행 매칭 no-op**이다. 인용 금지.
   비율 비교만 쓰거나, `--rand-type=uniform` 또는 warmup 단축으로 다시 잴 것.
2. PG의 모든 tau 수치는 `shared_buffers=128MB`, `max_wal_size=1GB`에서 나온 것이고,
   비교 대상 `fpw=on`은 `max_wal_size=16GB`를 받았다. **tau가 핸디캡을 진 조건이다.**
3. MySQL 수치는 실행 날짜별로 버퍼 풀이 128 MB~140 GB로 다르다. `.spec` 없이 비교 금지.
4. MySQL `ext4-tau` vs `xfs-tau`는 flush method 교란으로 최대 14% 왜곡돼 있고,
   저널 상한이 32 GB vs 1 GB로 32배 다르다(§4.6). p99가 30.8 ms vs 12.5 ms로 갈리는 이유다.
5. **MySQL은 파일시스템이 InnoDB의 I/O 경로를 정한다**(§4.2~4.4).
   `ext4`/`xfs`/`xfs-cow`만 진짜 O_DIRECT이고 `tau`/`ext4-dj`/`zfs`는 buffered다.
   같은 buffered 그룹인 `ext4-dj`와의 비교는 캐시가 맞으므로 그대로 써도 되지만,
   `tau` vs `ext4`/`xfs` 헤드라인 비교에는 통제 셀이 하나 필요하다.
6. **MySQL의 tau 배수는 버퍼 풀 크기의 함수다**(§4.8) — `oltp_update_index`에서
   bp=16 GB일 때 fpw=on 대비 2.33x, bp=140 GB일 때 1.06x. 버퍼 풀을 명시하지 않은
   배수는 의미가 없다.
7. `mysql/main_xfs_20260401_213305` 류의 스케일 곡선은 셀마다 버퍼 풀이 달라
   c32 > c64 역전이 나 있다(§4.7). 확장성 그래프로 쓰면 안 된다.
8. **IO 볼륨은 `cov`(iostat 초 ÷ sysbench total time)를 먼저 확인할 것**(§4.9).
   `iostat_end`가 iostat이 아니라 grep을 죽이는 버그 때문에 MySQL 67개 셀 중
   **16개만** 창이 맞는다. PG `io_main`은 40셀 전부 정상이다.
   MySQL IO 파일은 `*.iostat`과 `*_iostat.log` 두 규칙으로 흩어져 있으니 둘 다 볼 것.
9. PG `oltp_insert`는 lua가 prepared statement를 쓰지 않는다 — MySQL과 절대 비교 금지.

## 6. 제안하는 후속 실험 (우선순위 순)

| # | 실험 | 셀 수 | 왜 |
|---|---|---|---|
| 1 | `shared_buffers` 128MB / 1GB / 4GB / 16GB x {ext4, ext4-tau, xfs-tau} x {write_only, update_index} x c64 | 24 | §3.1의 핵심 미검증 가설. tau가 `fpw=off`의 +27~46%를 따라가는지 확인. 논문 수치가 올라갈 가능성이 가장 큰 항목. |
| 2 | `max_wal_size`를 fpw와 무관하게 16GB 고정하고 main 매트릭스 재실행 | 기존 매트릭스 | §3.2 비대칭 제거. `oltp_delete`에서 최대 +11%. |
| 0 | **`mem=64G`로 부팅 + 버퍼 풀 = RAM의 50~75%로 고정하고 MySQL 매트릭스 재실행** | 기존 MySQL 매트릭스 | §4.8. DB > RAM을 회복해 "적당한 버퍼 풀"을 결정 가능하게 만든다. PG 예비 측정으로는 비용 −7%. 이게 안 되면 MySQL 배수는 계속 설정에 따라 1.05x~2.44x 사이를 오간다. |
| 0b | 헤드라인 버퍼 풀 크기에서 `ext4`/`xfs`에 `--innodb_flush_method=fsync` 셀 추가 | 5 | §4.4. tau vs 진짜 O_DIRECT baseline의 캐시 교란 크기를 확정한다. bp=140 GB에서는 1.06x였지만 작은 버퍼 풀에서는 미측정. |
| 3 | `ext4-tau`/`xfs-tau` 저널 상한을 동일하게 맞추고 p99 재측정 | 12 | §4.6. p99 30.8 vs 12.5 ms가 저널 상한 때문인지 ext4/XFS 구현 차이인지 가른다. |
| 4 | (선택) MySQL `innodb_redo_log_capacity` 100MB(기본) vs 10GB x {ext4 fpw=on, ext4-tau} | 8 | §3.4. **기본값 유지는 I/O 포화 영역을 보려는 의도적 선택이다**(§4.12 서두). 이 셀은 전제 확인이 아니라 "redo를 키우면 격차가 줄지 않나"는 예상 질문에 대한 방어용. |
| 4b | **`iostat_start` 버그 수정 후** IO 볼륨 4자 통제: 같은 bp에서 `ext4`(O_DIRECT) / `ext4`(fsync) / `ext4-tau` / `xfs-tau`, `update_non_index` + `insert` | 8 | §4.9. coalescing 이득과 tau 저널 비용을 분리한다. 중단된 `oltp_insert` 베이스라인도 복구된다. 수정 없이는 결과를 믿을 수 없다. |
| 4d | `xfs-tau` `20260401` vs `20260415` 2배 차이의 원인 특정(커널 커밋/마운트 옵션 diff) | 2 | §4.9. 같은 설정에서 IO 2배, 처리량 22% 차이. 어느 쪽이 현재 코드인지 모르면 두 값 다 못 쓴다. |
| 4c | `CONFIG_TAU_PROFILE`로 MySQL 1셀 — `commit_total_blocks` / `chkpt_flush_blocks` / `chkpt_drop_blocks` / `coalesced_blocks` 덤프 | 2 | §4.9. insert에서 ext4-tau가 xfs-tau의 2.16배인 이유를 가른다. 카운터는 이미 `tau_perf.h`에 있고 MySQL에 한 번도 안 돌렸다. |
| 5 | `wal_buffers`를 16MB로 고정한 채 `shared_buffers` 스윕 | 8 | §3.1의 내부 confound 분리. |
| 6 | `oltp_read_write`를 PG tau에 대해 측정 | 6 | 유일하게 읽기가 섞인 워크로드인데 PG tau 데이터가 없다. MySQL에선 tau 이득이 가장 컸다. |
| 7 | `wal_compression=on`에서 `fpw=on` baseline 1셀 | 2 | "FPW를 압축하면 되지 않느냐"는 예상 질문 방어. |

## 부록: 재현용 스크립트

이 문서의 집계는 아래로 만들었다.

`bench/docs/agg_sysbench.py`는 `$TAUFS_BENCH_WS/results/sysbench` 아래를 재귀 탐색해
파일명(`{db}_{workload}_{fs}_fpw_{on|off}_t{tables}_c{threads}_r{try}`)을 파싱하고,
같은 이름의 `.log`에서 TPS/QPS/avg/p99를, `.spec`에서 PG·InnoDB 주요 설정을 뽑아
하나의 CSV로 stdout에 내보낸다.

```shell
source set_env.sh
python3 bench/docs/agg_sysbench.py > /tmp/agg.csv     # 1,673 행 (2026-08 기준)

# 예: tau 셀의 shared_buffers 분포 확인
python3 - <<'EOF'
import csv, collections
rows = list(csv.DictReader(open('/tmp/agg.csv')))
print(collections.Counter(r['shared_buffers']
                          for r in rows if r['db']=='postgres' and 'tau' in r['fs']))
# -> Counter({'128MB': 278})
EOF
```

(MySQL 셀은 `shared_buffers` 칸이 비고 `innodb_buffer_pool_size`에 값이 들어간다.)

---

## 4.18 ★ §4.16의 미해결 항목이 풀렸다 — 커널 회귀가 아니라 하네스 결함 (2026-09-07)

측정: 커널 `6.8.0tjournal+ #243`(gcc 10.5.0), PG 17.5, 16 tables x 40M rows = **152 GB**,
`oltp_update_non_index`, 32 threads, 32M events, `shared_buffers=128MB`(기본값 유지),
`fpw=off`, `max_wal_size=1GB`, tau 저널 32 GB, 호스트 RAM 60 GB(cgroup 없음),
`tau_strict_cpdrop=1`. **셀마다 새 로드**(다중 사이클 폐기 — 같은 설정 재실행 간
드리프트가 write −12.9% / tps +9.5%로 재려는 효과와 같은 자릿수였다).
결과: `results/sysbench/postgres/cells242/`.

### (1) 원인 — `load_db()`가 언마운트를 안 한다

두 trend 하네스(`run_pg_tau_trend.sh`, `run_mysql_tau_trend.sh:175`)의 `load_db()`는
주석 그대로 *"Leaves the fs mounted"* 다. 로드 끝의 `sync`는
`ext4_sync_fs` → `tau_sync_all()`(`fs/taujournal/commit.c:987`)로 가는데, 이 함수는
`tau_start_commit()`만 부른다 — **체크포인트 호출이 없다.** 따라서 152 GB 로드가
저널에 남긴 약 25.7 GB가 그대로 있는 상태에서 런이 시작된다.

`Used journal 25728MB / 32768MB` = **free 21.5%**. `tauvar_force_reclaim = 20`이므로
런 전 구간이 긴급 reclaim 임계값 바로 위에서 진동한다. 재마운트하면 79% → 19.5%로
비워지고 무릎에 닿기까지 90초가 걸린다(런 300초의 30%).

**재현**: 하네스와 같은 조건(`REMOUNT=no`)으로 재실행한 셀이 **543.3 GB / 96,621 tps**.
오염된 원본 셀은 **543.0 GB / 96,012 tps** — 오차 **0.06%**.
따라서 §4.16이 "가장 중요한 미해결 항목"으로 남긴 두 후보(커널 회귀 / 기록되지 않은
메모리 크기)는 **둘 다 아니다.** 하네스가 만든 인공물이다.

### (2) 4셀 매트릭스

| 셀 | 런 쓰기 | tps | p99 | 저널 | 제자리 | duty | `txdirty` | `repeat` |
|---|---|---|---|---|---|---|---|---|
| `defer=0` 재마운트 | 348.2 GB | 110,226 | 1.30 | 136.3 | 130.5 | 31.0% | 28.7% | 29.0% |
| `defer=1` 재마운트 | **309.4** | **112,341** | **1.21** | 134.8 | **90.4** | 8.7% | 0.0% | 0.3% |
| `defer=0` 압력(하네스) | 543.3 | 96,621 | 1.96 | 169.9 | **316.3** | 60.7% | 49.9% | 50.0% |
| `defer=1` 압력 | **376.9** | **104,262** | 1.89 | 164.9 | **151.5** | 25.3% | 0.0% | 0.3% |

`duty` = `ckpt_enter / (ckpt_enter + ckpt_inline)`. `ckpt_enter`는 **압력 기반 fan-out만**
세고, 저널에 여유가 있으면 `tau_journald`가 인라인으로 `tau_do_checkpoint()`를 부른다
(`journal.c:470` 이하). **`ckpt_enter = 0`은 "체크포인트 안 돎"이 아니라 "fan-out 안 돎"이다.**

195 GB 격차의 분해가 정확히 닫힌다: 제자리 +185.8, 저널 +33.6(커밋 2,843 → 3,795로
tx가 작아짐), revoke 직행 −24.3 = **195.1 GB**(실측 195.1).

### (3) 낭비의 정체 — 곧 덮어써질 버전을 제자리에 쓴다

`tau_do_checkpoint()`는 살아있는 tx가 더 새 버전을 갖고 있어도 옛 버전을 제자리에 쓴다
(`checkpoint.c:437`, *"Flush it now rather than wait for that tx's commit, which would
stall checkpoint"*). 그 쓰기는 버려진다.

`cpflush_txdirty`(그 분기)와 `cpflush_repeat`(이미 `BH_TauWritten`이 붙은 블록 = 같은
cp tx에 대한 두 번째 제자리 쓰기)이 1% 안쪽으로 일치한다 → **두 집단이 같다.**
그리고 그 비율이 duty cycle을 따라간다(31% → 28.7%, 60.7% → 49.9%). 즉 체크포인트가
저널 압력에 떠밀려 **아직 뜨거운 블록** 위로 갈수록 버려지는 쓰기가 늘어난다.

`tau_defer_txdirty_cpflush=1`(런타임 노브, 출하 기본값 0)이 이걸 건너뛴다:
`txdirty` → 0, `repeat` → −99.4%, 런 쓰기 **−11.1%(여유) / −30.6%(압력)**.
**보상 쓰기가 없다** — `jwrite_blocks` −1.1~3%, `revoke_taken` ±6% 이내.
`cpflush_forced = 0`으로 30초 기한이 두 팔 모두에서 한 번도 발동하지 않았고,
오히려 duty cycle이 내려갔다(60.7% → 25.3%).

기본값을 1로 올리는 것은 "건너뛴 제자리 사본이 복구에 불필요한가"라는 **안전성 판단**이므로
커널 쪽 결정이다. 여기서는 측정치로만 둔다.

### (4) 쓰기 예산 — 처음으로 닫혔다

런 348.2 GB(`defer=0` 재마운트) 기준:

| 항목 | 크기 | 출처 |
|---|---|---|
| 저널 쓰기 | 136.3 GB | `jwrite_blocks + jwrite_revoke + jwrite_record` |
| 체크포인트 제자리 | 130.5 GB | `flush_submit` |
| **revoke 직행 라이트백** | ~71.9 GB | **tau 카운터 없음** (revoke 블록당 1.92회) |
| PG WAL | 9.5 GB | `pg_stat_wal` (`wal_fpi = 0`) |
| ext4 메타데이터 | ≤1.4 GB | `/proc/fs/jbd2/nvme1n1-8/info` — tx당 **7 블록** |

정지+드레인 구간 검산: 카운터 15.3 GB vs iostat 15.0 GB — **오차 2%**.
카운터 자체 검증: `txdirty + noevid + plain = 34,215,356` vs `flush_submit = 34,216,515`
— 차이 **0.003%**.

revoke된 블록은 "제자리가 authoritative"라 이후 덮어쓰기가 저널을 건너뛰고 평범한 ext4
라이트백으로 home에 직행한다 — 설계된 최적화이고, 그 바이트를 세는 tau 카운터가 없어서
미귀속으로 보였던 항이다.

### (5) 왜 tps가 올랐는가 — 장치는 4셀 모두 100% 포화다

| 셀 | %util | aqu-sz | w_await | w/s | wMB/s | **rMB/s** | tps |
|---|---|---|---|---|---|---|---|
| `defer=0` 재마운트 | 100.0 | 36.8 | 0.32 | 90,821 | 1,245 | 161 | 110,226 |
| `defer=1` 재마운트 | 100.0 | 35.3 | 0.35 | 71,338 | 1,127 | **168** | 112,341 |
| `defer=0` 압력 | 100.0 | 69.1 | 0.46 | 150,798 | 1,698 | **144** | 96,621 |
| `defer=1` 압력 | 100.0 | 57.3 | 0.52 | 86,480 | 1,268 | 161 | 104,262 |

`%util = 100.0`이 네 셀 전부다. **장치가 병목이다.** `shared_buffers = 128MB` 대
데이터셋 152 GB이므로 거의 모든 UPDATE가 페이지를 디스크에서 읽어야 하고,
그 읽기가 tau의 체크포인트 쓰기와 **같은 포화된 장치**를 놓고 경쟁한다.

버려지는 쓰기를 없애면 그만큼이 읽기 대역폭으로 간다: 압력 팔에서 rMB/s **144 → 161
(+12%)**, tps **+7.9%**. 큐 깊이도 69.1 → 57.3으로 내려간다. 쓰기 감소(−30.6%)보다
tps 증가(+7.9%)가 작은 것은 확보된 장치 시간의 일부가 대기열·지연 감소로 흡수되고
읽기와 쓰기가 완전히 대체 가능하지 않기 때문이다.

**즉 tps 상승은 CPU나 락이 아니라 포화된 장치에서 읽기가 확보한 대역폭이다.**
이 해석은 §0의 2번(접근의 75%가 ID 범위 1%에 몰림)과도 일관된다 — hot set이 1.6 GB라도
`shared_buffers`가 128MB면 그마저 캐시에 안 들어간다.

### (6) 정정된 헤드라인

창을 맞춰(런 + `pg_ctl stop`, 언마운트 제외) 비교하면:

| | 쓰기 | tps |
|---|---|---|
| ext4 `fpw=on` — 안전한 baseline | 348.3 GB | 87,338 |
| ext4 `fpw=off` — **크래시 안전 아님** | 202.8 GB | 122,079 |
| ext4-tau `defer=0` | 352.1 GB (1.01x) | 110,226 (1.26x) |
| **ext4-tau `defer=1`** | **313.1 GB (0.90x)** | **112,341 (1.29x)** |

**tau는 `fpw=on`보다 10% 적게 쓰면서 29% 빠르다.** 오염된 하네스가 말하던
"tau가 `fpw=on`보다 1.56배 더 쓴다"는 폐기한다.

### (7) 부수 결과: ext4에서 `tau_strict_cpdrop=1`은 공짜다

`cpflush_noevid = 0` — strict 우회가 **한 번도 발동하지 않았다.** drop 분기에 도달한
revoke 블록은 전부 이미 `BH_TauWritten` 또는 `BH_TauCpDone` 증거를 갖고 있었고,
strict 규칙이 추가 제자리 쓰기를 강요한 적이 0이다. 커널 CLAUDE.md가 "비용은 XFS에만"
이라고 적어둔 것을 ext4 쪽에서 실측으로 확인한 셈이다.

또한 `cpdrop_cpdone = 2,931,771` — **ext4에서 `BH_TauCpDone`은 살아 있다.**
293만 블록이 ext4 라이트백이 이미 썼기 때문에 체크포인트가 쓰지 않고 드롭했다.
(이 비트가 죽어 있다는 중간 가설은 `BH_TauDirty` 집단과 revoke 집단을 섞은 오류였다.)

### 유보 사항

- **재측정이 필요한 범위**: §4.11~4.17의 tau 셀 전부. MySQL 48셀 매트릭스(§4.13),
  클라이언트 스케일링(§4.14), PG 매트릭스(§4.15), 원본 스케일 재현(§4.16)이 모두
  같은 하네스에서 나왔다. baseline(ext4/xfs) 셀은 tau 저널이 없어 영향이 없다.
- 위 4셀은 `oltp_update_non_index` 하나뿐이다. 다른 워크로드에서 duty cycle과
  `txdirty` 비율이 같은 관계를 갖는지는 미측정이다.
- 병합비는 저널링 35.68M 블록 → 서로 다른 home 도달 약 27.2M = **1.31:1**이다.
  (이전에 보고한 2.3:1 / 3.8:1은 로드 구간이 섞인 누적 카운터에서 나온 값이라 폐기.)
- 평균 tx 크기 `jwrite_blocks / jwrite_record` = 12,551 블록(49 MB), 커밋 2,843회.
  커밋은 나이 기반이다: 2,843 / 290 s = 9.80/s ≈ 48 taus / `tau_max_commmit_age`(5 s)
  = 9.6/s. 이 노브가 tx 크기를, tx 크기가 tx 내 병합량을 정한다 — 미탐색 레버.

### (8) `oltp_update_index` — 스위치가 결과의 부호를 바꾼다 (2026-09-07)

같은 장비·커널(`#243`)·세션, `/dev/nvme1n1`, RAM 60 GB, 152 GB, 32M events,
셀마다 새 로드. `fpw=on`은 `max_wal_size=16GB`, 나머지는 1GB(`run_main.sh` 스킴).

| 구성 | 쓰기(런+정지) | tps | p99 |
|---|---|---|---|
| ext4 `fpw=on` — 안전한 baseline | 724.5 GB | 57,921 | 1.21 |
| ext4 `fpw=off` — **크래시 안전 아님** | 375.7 GB | 101,236 | 0.86 |
| ext4-tau `defer=0` | 882.3 GB (**1.22x**) | 53,273 (**0.92x**) | 2.03 |
| ext4-tau `defer=1` | 654.0 GB (0.90x) | 82,820 (1.43x) | 2.18 |
| ext4-tau `defer=1` + `commit_age=10` | **552.0 GB (0.74x)** | **85,909 (1.48x)** | 2.14 |

**`defer=0`으로는 `fpw=on`을 못 이긴다** — 쓰기 22% 더 쓰고 8% 느려서 양쪽 다 진다.
`update_non_index`에서는 `defer=0`도 이미 이기므로(1.01x / 1.26x), 이 스위치는
"있으면 좋은 최적화"가 아니라 **무거운 워크로드에서 결과의 부호를 바꾸는 항**이다.

두 워크로드를 `fpw=on` 대비로 놓으면:

| | `defer=0` | `defer=1` |
|---|---|---|
| `oltp_update_non_index` | 1.01x 쓰기 / 1.26x tps | 0.90x / 1.29x |
| `oltp_update_index` | **1.22x / 0.92x** | 0.90x / 1.43x |

### (9) duty cycle만으로는 설명되지 않는다 — 두 번째 인자

| | duty | `cpflush_txdirty` / `flush_submit` |
|---|---|---|
| `update_non_index` 재마운트 | 31.0% | 28.7% |
| `update_non_index` 압력 | 60.7% | 49.9% |
| **`update_index` 재마운트** | **29.8%** | **66.0%** |

같은 워크로드 안에서는 duty를 따라가지만, `update_index`는 **duty가 거의 같은데 비율이
2.3배**다. 두 번째 인자는 **워크로드의 블록 재갱신율 λ**다. 블록이 cp 리스트에 얹혀 있는
시간 Δt 동안 재갱신이 올 확률이므로 `비율 ≈ 1 − exp(−λ·Δt)`이고, duty가 Δt를 대리한다.
관측치를 넣으면 λΔt가 0.338(UNI) vs 1.078(UIDX)로 3.2배다. 640M 행의 `k` 인덱스 리프는
약 1.6M 페이지, 힙은 19M 페이지라 페이지당 hotness는 12배인데, 66%는 이미 포화 구간이라
비율 차이가 그보다 작게 나타난다. **더 hot한 워크로드에서도 이 비율은 70~80%에서 천장을
칠 것으로 예측된다**(미검증).

### (10) `defer=0`은 커밋조차 굶고 있었다

커밋은 나이 기반이다(48 taus / `tau_max_commmit_age` 5 s = 9.6/s):

| | run_s | commits | commit/s |
|---|---|---|---|
| `update_non_index` d0 / d1 | 290 / 285 | 2,843 / 2,819 | 9.80 / 9.89 |
| **`update_index` d0** | 601 | 3,112 | **5.18** |
| `update_index` d1 | 386 | 3,801 | 9.85 |

기아는 체크포인트 부하가 가장 큰 셀 하나에만 있다. 게이트가 아니라 실행 부족이다 —
`gate_commit_cap`은 6,622 → 6,189로 **−6.5%**뿐인데 커밋률은 **+90%**다.
원인은 `tau_journald`의 직렬 구조다: `handle_expired_transactions()`(커밋 큐잉)와
`do_background_journal_reclaim()`(무압력 경로에서 **데몬 스레드 안에서 동기적으로**
`tau_do_checkpoint()` 호출)이 한 루프에서 순차 실행되므로, 데몬이 체크포인트 워크 안에
있는 동안 만료 트랜잭션이 커밋 큐에 오르지 못한다. 커밋률 = 1 / 데몬 루프 주기다.

그래서 `defer=1`에서 저널 쓰기가 **늘어난다**(244.2 → 303.3 GB, +24%): 이벤트당 저널
블록이 2.00 → 2.48로 오르고 트랜잭션당 이벤트가 10,285 → 8,408로 내려간 결과이며,
**deferral의 대가가 아니라 커밋 기아가 풀린 부작용**이다. λ가 낮은 `update_non_index`는
애초에 굶지 않았으므로 저널이 −1.1%로 움직이지 않았다 — 즉 **deferral 자체에는 저널 비용이
λ 양쪽 어디에도 없다.**

커밋이 정상 속도로 돌아왔으므로 `tau_max_commmit_age` 5 → 10이 tx 내 병합을 회복시킨다:
쓰기 649.3 → 532.9 GB(**−17.9%**), tps +3.7%.

### (11) 정합성 검증 — 통과 (2026-09-07)

`defer=1`은 체크포인트가 제자리 쓰기를 **덜** 하는 방향이라 저널 사본 의존도가 올라간다.
그리고 taudirty 분기의 제자리 쓰기는 jh를 못 빼지만 데이터는 home에 밀어넣으므로,
**commit-forget 인계 경로에 결함이 있어도 지금은 그 쓰기가 가려준다.** 위험은 새 버그가
아니라 **기존 버그가 드러나는 것**이고, 그 영역이 Known Bug #1/#2/#6이 나온 자리다.

`tools/tautest`를 게스트 커널 cmdline `tau_journal.tau_defer_txdirty_cpflush=1`로 실행
(커널 `#244`, 모든 재부팅에 걸쳐 유지됨을 콘솔 로그로 확인):

| 테스트 | 결과 |
|---|---|
| `crash-test.sh both` | **ALL PASS** (xfs, ext4). 실제 전원 차단 후 체크섬 대조, tau replay 로그 확인 |
| `sync-test.sh both` | **ALL PASS**. `sync(2)`, `syncfs(2)`, 덮어쓰기+sync |
| `stress-test.sh ext4 600 6 5` | **PASS** (600 rounds, no kernel faults, 51분) |
| `stress-test.sh xfs 600 6 5` | **PASS** (600 rounds, no kernel faults, 51분) |

게스트 콘솔 로그 600 KB에 `Call Trace` / `kernel BUG` / `Oops` **0건**.

`stress-test`의 인자는 `rounds racers seconds`이므로 라운드당 5초다 — 처음 돌린 60라운드는
5분이라 CLAUDE.md의 기준("A few hundred rounds is the bar", 버그가 30초~30분 사이에
나타남)에 한참 못 미쳤다. 600라운드 = 50분이 그 기준을 채운 분량이다.

XFS를 함께 돌린 이유: `BH_TauCpDone`을 세우는 코드가 ext4 밖에 없어서(`page-io.c:148`이
유일한 호출) XFS는 체크포인트가 증거를 얻는 경로가 좁고, `taudirty` 분기가 더 자주 발동할
수 있다. ext4 통과가 XFS를 보장하지 않는다.

### 유보 사항 (추가)

- **io_main과의 정량 비교는 하지 않는다.** 확정된 차이: RAM 187 GB(문서 헤더) vs 60 GB,
  커널·컴파일러 미기록, 장치 거동(`%util 64.9 @ 602 MB/s` vs `100 @ 1245`). 장치 자체는
  **확정 불가**다 — 문서 헤더는 "980 PRO / nvme0n1"인데 io_main의 iostat는 `nvme1c1n1`
  (오늘의 MZPLJ3T2HBJR 이름)이라 서로 어긋난다. `set_env.sh:21`에 980 PRO가 주석 처리돼
  있으나 변경 시점은 알 수 없다.
- `defer=1`을 출하 기본값으로 올리는 것은 안전성 판단이며 커널 쪽 결정이다.
- 위 결과는 두 워크로드뿐이다. `oltp_insert` / `oltp_delete` / `oltp_write_only`는 미측정.

---

## 4.19 ★ 정합성 수정을 전부 켠 재측정 (커널 #250, 2026-09-09)

§4.18까지의 tau 수치는 모두 `tau_defer_txdirty_cpflush=0`(당시 기본값) 아래에서
나왔다. #246~#250이 그 기본값을 1로 바꾸고 정합성 수정 셋을 더했으므로 **tau 셀을
전부 다시 측정했다.** ext4 셀은 tau 코드를 타지 않지만, 표 전체가 한 커널·한 하네스·
한 장치에서 나오도록 함께 다시 잰다. PG는 6개 워크로드 전부(18셀), MySQL은
`oltp_update_non_index` 한 워크로드를 §(6)에서 따로 다룬다.

측정: 커널 `6.8.0tjournal+ #250`, PG 17.5, 16 tables x 40M rows = **152 GB**,
32 threads, `shared_buffers=128MB`(기본값), tau 저널 32 GB,
호스트 RAM 60 GB(`mem=64G`), 장치는 모델 문자열로 해석되는 3.2 TB
MZPLJ3T2HBJR(이 부팅에서는 `/dev/nvme2n1` — 이름은 재부팅마다 바뀐다).
셀마다 새 로드 + 언마운트/재마운트, iostat는 mount/run/stop/drain 4구간 분할,
probe는 로드 후·런 직후·정지 후·언마운트 후에 읽는다.
결과: `results/sysbench/postgres/k250/`.

이벤트 수는 워크로드마다 다르다(런타임을 비슷하게 맞추려고). 워크로드 간 절대값
비교는 의미가 없고, **같은 행 안에서의 비율만** 읽어야 한다.

### (1) 결과 — PG 6개 워크로드

쓰기는 `run+stop` 구간(GB), tps는 sysbench 2차 호출.

| 워크로드 | events | ext4 `fpw=on`(안전) | ext4 `fpw=off`(**안전 아님**) | **ext4-tau** |
|---|---|---|---|---|
| `oltp_insert` | 32M | 208.1 GB / 108,654 | 180.4 / 124,925 | **234.8 / 120,662** |
| `oltp_update_non_index` | 32M | 347.2 / 87,653 | 203.0 / 122,850 | **320.0 / 111,558** |
| `oltp_read_write` | 4M | 331.9 / 8,127 | 192.6 / 9,104 | **261.9 / 9,026** |
| `oltp_write_only` | 8M | 504.3 / 22,465 | 262.4 / 39,277 | **425.5 / 32,627** |
| `oltp_delete` | 8M | 50.5 / 121,302 | 26.2 / 165,248 | **42.6 / 156,944** |
| `oltp_update_index` | 32M | 721.8 / 58,419 | 373.7 / 101,548 | **645.2 / 83,728** |

비율로 정리하면 (FPW 비용 = `fpw=on` 쓰기 / `fpw=off` 쓰기, 오름차순 정렬):

| 워크로드 | FPW 비용 | tau vs `fpw=on` 쓰기 | tps | tau vs `fpw=off` 쓰기 | tps |
|---|---|---|---|---|---|
| `oltp_insert` | 1.15x | **1.13x** | 1.11x | 1.30x | 0.97x |
| `oltp_update_non_index` | 1.71x | **0.92x** | 1.27x | 1.58x | 0.91x |
| `oltp_read_write` | 1.72x | **0.79x** | 1.11x | 1.36x | 0.99x |
| `oltp_write_only` | 1.92x | **0.84x** | 1.45x | 1.62x | 0.83x |
| `oltp_delete` | 1.93x | **0.84x** | 1.29x | 1.63x | 0.95x |
| `oltp_update_index` | 1.93x | **0.89x** | 1.43x | 1.73x | 0.82x |

**tps는 6/6 워크로드에서 `fpw=on`보다 높다(1.11x~1.45x).** 쓰기는 5/6에서 낮고,
`oltp_insert` 하나만 1.13x로 더 쓴다.

`oltp_insert`가 예외인 이유는 표 안에 있다. FPW 비용이 1.15x뿐이다 — append 위주라
PG가 full-page image를 쓸 일이 거의 없어서 **tau가 절약해 줄 이중 쓰기 자체가 없다.**
그러면 tau의 저널 쓰기가 상쇄되지 않고 그대로 남는다. FPW 비용이 1.7x를 넘는
나머지 다섯에서는 전부 tau가 이긴다.

다만 **FPW 비용이 tau의 우위를 단조적으로 예측하지는 않는다.** FPW 비용 1.71x와
1.72x인 두 워크로드의 tau 비가 0.92x와 0.79x로 갈린다. 방향은 맞지만 크기는
워크로드의 쓰기 패턴에 따로 달려 있다.

전체 창(`write_total`, tau의 마운트 시 세그먼트 풀 선할당과 언마운트 드레인 포함)
기준으로는 `fpw=on` 대비 0.84x / 0.97x / 0.84x / 0.87x / 1.04x / 0.91x다.
`oltp_delete`가 여기서 부호가 뒤집히는데, 절대 볼륨이 50 GB로 작아서 tau의 고정
비용(선할당 4.9 GB + 드레인 5.0 GB)이 런 자체보다 큰 비중을 차지하기 때문이다.
ext4 셀은 `write_pre`와 `write_drain`이 둘 다 0이므로 `run+stop` 비교가 공정한
형태이고, 전체 창 비교는 tau에 불리한 쪽으로 기운 보수적 수치다.

무보장 `fpw=off` 대비는 쓰기 1.30x~1.73x, 처리량 0.82x~0.99x다. 그 차이가 저널링의
순비용이며, **같은 보장을 주는 유일한 비교 대상은 `fpw=on`이다.**

### (2) 베이스라인이 이전 측정을 1% 안에서 재현한다

| 셀 | #250 | 이전 | 차이 |
|---|---|---|---|
| `update_non_index` ext4 `fpw=on` | 347.2 GB / 87,653 | 348.3 / 87,338 (#238) | −0.3% / +0.4% |
| `update_non_index` ext4 `fpw=off` | 203.0 GB / 122,850 | 202.8 / 122,079 (#238) | +0.1% / +0.6% |
| `update_index` ext4 `fpw=on` | 721.8 GB / 58,419 | 724.5 / 57,921 (#243) | −0.4% / +0.9% |
| `update_index` ext4 `fpw=off` | 373.7 GB / 101,548 | 375.7 / 101,236 (#243) | −0.5% / +0.3% |

커널이 #238/#243 → #250으로 바뀌고 하네스도 다른데 ext4 쪽이 움직이지 않는다는 것은,
**tau 셀에서 관측된 변화가 실제 tau 변화**라는 뜻이다.

### (3) 정합성 수정의 성능 비용은 측정 한계 근처다

| | 쓰기(run) | tps |
|---|---|---|
| #243, `defer=1`을 손으로 켬 | 309.4 GB | 112,341 |
| **#250, 기본값 + 수정 전부** | **316.3 GB** | **111,558** |

차이 +2.2% / −0.7%로 런 간 변동 범위 안이다. #246의 revoke 재태깅, #247의 folio
trylock, #250의 제출 시점 taudirty 가드가 더한 비용이 사실상 없다.

### (4) 안전 지표 — 그리고 보호가 실제로 발동했다

6개 tau 셀 전부, 언마운트 후 누적(로드 후 리셋 기준). `ins`=`oltp_insert`,
`nix`=`update_non_index`, `rw`=`read_write`, `wo`=`write_only`, `del`=`delete`,
`idx`=`update_index`.

| | ins | nix | rw | wo | del | idx |
|---|---|---|---|---|---|---|
| `retag_failed` (#246이 실패한 횟수) | 0 | 0 | 0 | 0 | 0 | 0 |
| `flush_onwrite` / `_rev` | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 |
| `wr_skip_unmapped` | 0 | 0 | 0 | 0 | 0 | 0 |
| `cpdrop_unwritten` | 0 | 0 | 0 | 0 | 0 | 0 |
| `cpflush_txdirty` (defer가 도는지) | 0 | 0 | 0 | 0 | 0 | 0 |
| `flush_txdirty_late` (큐잉↔제출 틈) | 0 | 0 | 0 | 0 | 0 | 0 |
| dmesg `Call Trace`/`BUG`/`WARNING` | 0 | 0 | 0 | 0 | 0 | 0 |
| **`flush_folio_busy`** (folio 락이 막음) | **1** | **8** | **18** | **14** | 0 | **13** |
| **`revoke_notag`** (#246이 재태깅) | 0 | 0 | 0 | **1** | 0 | **1** |
| `cpflush_defer` | 79,965 | 41,325 | 52,094 | 457,025 | 0 | 1,161,030 |

0만 늘어놓은 표가 아니라는 점이 중요하다. **`flush_folio_busy`가 6셀 합 54라는 것은
복사 중인 버퍼의 제출을 folio 락이 실제로 54번 막았다**는 뜻이고, `write_only`와
`update_index`의 `revoke_notag = 1`은 그 런이 #246이 닫은 창에 실제로 들어갔는데
`retag_failed = 0`, 즉 folio가 태그를 얻었다는 뜻이다. **창에 들어가지 않은 런의 0은
아무것도 증명하지 못하므로, 이 두 값이 판정의 전제다.** `oltp_delete`는 그 창에
한 번도 들어가지 않았다(`flush_folio_busy`, `cpflush_defer` 모두 0) — 이 셀의 0들은
"보호가 통과했다"가 아니라 "시험되지 않았다"로 읽어야 한다.

`cpflush_defer`가 워크로드마다 0에서 116만까지 3자릿수 넘게 벌어진다. 체크포인트와
살아 있는 트랜잭션이 같은 버퍼를 놓고 겹치는 정도가 워크로드 성질이라는 뜻이고,
`update_index`가 가장 심하다.

### (5) 부수 관측

`tau_journal_get_write_access()`의 lock-free fast path 히트율
(`wr_fastpath / (wr_fastpath + wr_slowpath)`)은 6셀에서 **17.5% ~ 26.7%**다
(ins 17.5, rw 19.5, nix 22.0, del 23.8, wo 26.4, idx 26.7). 이 경로만 버퍼 락을
잡지 않고 쓰기 창에 진입하므로, 체크포인트의 `lock_buffer` 기반 배제가 적용되지 않는
유일한 자리다. 지금은 `defer=1`(체크포인트가 tx 소유 버퍼에 IO를 내지 않음)과
제출 시점 taudirty 가드로 덮여 있다 — **락이 아니라 정책으로 닫힌 유일한 항목이다.**

tau 자신의 회계로 본 저널 대 제자리 쓰기(4 KiB x 카운터):

| | ins | nix | rw | wo | del | idx |
|---|---|---|---|---|---|---|
| 저널 (`jwrite_blocks`) | 95.2 GB | 141.1 | 113.8 | 201.3 | 19.3 | 299.8 |
| 제자리 (`flush_submit`) | 30.8 GB | 107.6 | 71.0 | 161.2 | 17.8 | 253.1 |
| 제자리 비중 | 24.5% | 43.3% | 38.4% | 44.5% | 48.0% | 45.8% |

`oltp_insert`의 제자리 비중이 24.5%로 유독 낮다. append는 같은 블록을 다시 건드리지
않아 체크포인트가 따라잡기 전에 커밋만 쌓이고, 그래서 저널 쓰기가 상쇄되지 않은 채
남는다 — (1)에서 이 워크로드만 tau가 더 쓰는 것과 같은 현상의 다른 면이다.

### (6) MySQL — 캐시 조건을 맞춘 베이스라인 (2026-09-09)

§4.18까지 MySQL 비교를 유보한 이유는 하나였다. **tau는 O_DIRECT를 지원하지 않으므로**
ext4-tau 위의 InnoDB는 `.ibd` I/O가 buffered로 떨어지고(mincore 실측 12.69% 상주),
ext4의 진짜 O_DIRECT와 캐시 조건이 달라진다. 그래서 `innodb_flush_method=fsync`로
ext4를 buffered로 내려 **캐시 조건을 맞춘 팔**을 추가로 측정했다.

측정: 커널 `#250`, MySQL 8.0, 16 tables x 40M rows = **146 GB**,
`oltp_update_non_index`, 32 threads, 8M events, `innodb_buffer_pool_size=128M`(기본값),
`log_bin=ON`, `sync_binlog=1`. 결과: `results/sysbench/mysql/k250/`,
교차검증은 `results/sysbench/mysql/cells242/`(커널 #243, `defer=0`).

| 구성 | 쓰기(run+stop) | tps | p99 | **읽기** |
|---|---|---|---|---|
| ext4 `doublewrite=ON`, `fsync` — 안전, 캐시 맞춤 | 313.8 GB | 21,733 | 6.79 | 25.2 GB |
| ext4 `doublewrite=ON`, O_DIRECT — 안전, 배포 현실 | 311.5 | 29,956 | 2.86 | 130.1 GB |
| ext4 `doublewrite=OFF`, `fsync` — **안전 아님** | 183.3 | 36,952 | 2.76 | 25.2 GB |
| **ext4-tau** (항상 `doublewrite=OFF`) | **201.6** | **36,846** | **2.18** | **24.9 GB** |

#### 캐시 조건이 맞았다는 것은 논증이 아니라 측정이다

`read_GB`가 판정한다. tau 24.9, ext4 `fsync` 두 셀 모두 25.2 — **0.4% 안에서 일치**한다.
반면 O_DIRECT 팔은 130.1 GB로 **5.2배**다. 페이지 캐시가 약 105 GB의 읽기를
흡수하고 있고, 그 이득은 tau가 저널링으로 번 것이 아니다. 따라서 `fsync` 팔이
**저널링 자체의 비용**을 재는 자리이고, O_DIRECT 팔은 **MySQL을 tau로 옮겼을 때
실제로 일어나는 일**을 재는 자리다. 둘 다 필요하고, 둘 중 하나만 인용하면 안 된다.

#### 결론은 두 축에서 신뢰도가 다르다

`doublewrite=ON`(같은 보장을 주는 유일한 베이스라인) 대비:

| | `fsync` 팔 (캐시 맞춤) | O_DIRECT 팔 (배포 현실) |
|---|---|---|
| tau 쓰기 | **0.64x** | **0.65x** |
| tau tps | **1.70x** | **1.23x** |

**쓰기 비는 두 팔에서 일치하므로 그대로 인용할 수 있다. tps 비는 갈리므로 한 숫자로
쓸 수 없다** — 범위로 적어야 한다. 양 끝이 서로 반대 방향의 핸디캡을 담고 있기
때문이다. O_DIRECT 팔에서는 tau가 페이지 캐시를 공짜로 얻고, `fsync` 팔에서는
ext4가 O_DIRECT를 뺏긴다.

#### 더 강한 결과는 무보장 베이스라인 쪽에 있다

tau는 **`doublewrite=OFF`의 처리량을 그대로 따라잡는다**(36,846 vs 36,952 = **1.00x**).
쓰기는 1.10x만 더 쓴다. 즉 tau는 **`doublewrite=OFF`의 성능으로 `doublewrite=ON`의
보장을 준다.** PG에서는 이 자리가 0.82x~0.99x였는데, MySQL에서 1.00x가 나오는 것은
아래 (7)의 카운터가 설명한다.

#### `flush_method`의 부호가 `doublewrite`에 따라 뒤집힌다

#243의 네 ext4 셀(한 커널·한 하네스에서 네 조합이 모두 측정된 유일한 세트):

| | `fsync`(buffered) | O_DIRECT |
|---|---|---|
| `doublewrite=ON` | 21,236 | **29,896** (+41%) |
| `doublewrite=OFF` | **36,943** | 33,863 (−8%) |

`doublewrite=ON`에서만 O_DIRECT가 이긴다. 이중 쓰기가 페이지 캐시 압력을 두 배로
만들기 때문으로 보인다. **`flush_method`를 "베이스라인에 유리한 설정"으로 뭉뚱그려
말할 수 없다** — doublewrite와 함께 봐야 부호가 정해진다.
쓰기량은 반대로 `flush_method`에 거의 무감하다(310.8 vs 316.0, 1.7%). §4.12의
"`flush_method`를 바꿔도 쓰기량은 ±5% 안"과 일치한다.

### (7) MySQL에서는 defer가 **구조적으로** 무효다

`my250_tau`(`defer=1`)는 #243의 `my_tau_defer1`(36,780 tps / 203.9 GB)을 0.2% / 1.4%
안에서 재현하고, #243의 `defer=0`(36,603 / 205.6)과도 0.5% 안이다. §4.18에서 PG는
`defer`가 결과의 부호를 바꿨는데 MySQL은 무반응이다. 카운터가 이유를 말한다.

| | PG `update_index` | **MySQL** |
|---|---|---|
| `cpflush_defer` | 1,161,030 | **0** |
| `cpflush_txdirty` | 0 | **0** |
| `revoke_taken` | 17.1M | **12.3M** |
| `flush_submit` | 66.4M | **6.7M** |

`cpflush_defer = 0`은 "미뤄봤자 이득이 없다"가 아니라 **미룰 것이 아예 없다**는 뜻이다.
InnoDB는 리두 로그를 fsync하지 체크포인트 전까지 `.ibd` 페이지를 fsync하지 않는다.
그래서 대부분의 페이지 재기록이 anchored 블록에 떨어져 revoke 경로로 제자리에 가고
(`revoke_taken`/`flush_submit`이 PG의 0.26 대 MySQL의 1.85 — 7배 역전), 체크포인트가 살아 있는 트랜잭션의 버퍼와
겹칠 일 자체가 생기지 않는다. **이것이 MySQL에서 tau의 쓰기 증폭이 PG보다 낮은
(24.9 KB/event) 이유이기도 하다** — 같은 페이지를 반복해서 저널에 다시 넣지 않는다.

### (8) MySQL tau 셀 안전 지표 — 통과

`retag_failed`, `flush_onwrite`/`_rev`, `wr_skip_unmapped`, `cpdrop_unwritten`,
`flush_txdirty_late`, `flush_unmapped`, `cpflush_noevid`, `anchore_notag`,
`flush_notdirty` **전부 0**, dmesg `Call Trace`/`BUG`/`WARNING` **0**.
`flush_folio_busy = 1`로 #247의 folio trylock이 이 워크로드에서도 발동했다.
`revoke_notag = 0`이므로 **#246이 닫은 창은 이 런에서 시험되지 않았다** — PG의
`write_only`/`update_index` 셀이 그 창의 증거를 담당한다.

### (9) XFS — 같은 커널·하네스·장치에서 (2026-09-18)

§4.19 는 처음에 ext4 만 담았고, §0 배너가 "인용할 tau 수치는 §4.19 뿐" 이라고
못박았으므로 §4.13 의 XFS 매트릭스는 그동안 인용 불가 상태였다. 그 구멍을 닫는다.

측정은 ext4 셀과 동일하다(커널 `#250`, PG 17.5, 16 tables x 40M = 152 GB,
32 threads, `shared_buffers=128MB`, 셀마다 새 로드 + 재마운트). 드라이버도
같은 파일에서 파생했고 mkfs/mount 두 함수만 다르다.

**저널은 양쪽 32 GB 로 맞췄다.** 다만 거는 자리가 다르다 -- XFS 는 mkfs 에서
(`-l tjmaxsize=32G`), ext4 는 마운트에서(`tjournal_size=32`). XFS 에 
`tjournal_size=` 를 **쓰지 않은 것은 의도적**이다: 그 옵션을 주면 한 트랜잭션을
넘는 파일 확장이 EINVAL 로 실패한다(§4.20). `bench/scripts/common.sh` 의
xfs-tau 는 저널을 1 GB 로 주는데(ext4-tau 는 32 GB), 그 비대칭은 쓰지 않았다.
결과: `results/sysbench/postgres/k250xfs/`.

#### 결과

| 워크로드 | 구성 | 쓰기(run+stop) | tps | p99 |
|---|---|---|---|---|
| `oltp_update_non_index` | xfs `fpw=on` — 안전 | 349.1 GB | 84,479 | 1.08 |
| | xfs `fpw=off` — **안전 아님** | 202.2 | 115,673 | 0.89 |
| | **xfs-tau** | **328.1** | **86,874** | 1.76 |
| `oltp_update_index` | xfs `fpw=on` | 717.5 | 54,509 | 2.18 |
| | xfs `fpw=off` — **안전 아님** | 379.1 | 94,129 | 1.30 |
| | **xfs-tau** | **684.1** | **63,624** | 2.39 |

#### ext4 와 나란히 — 쓰기는 옮겨 가고 처리량은 옮겨 가지 않는다

| | `update_non_index` ext4 / **XFS** | `update_index` ext4 / **XFS** |
|---|---|---|
| FPW 비용 | 1.71x / **1.73x** | 1.93x / **1.89x** |
| tau 쓰기 vs `fpw=on` | 0.92x / **0.94x** | 0.89x / **0.95x** |
| **tau tps vs `fpw=on`** | 1.27x / **1.03x** | 1.43x / **1.17x** |
| tau 쓰기 vs `fpw=off` | 1.58x / **1.62x** | 1.73x / **1.80x** |
| **tau tps vs `fpw=off`** | 0.91x / **0.75x** | 0.82x / **0.68x** |

**FPW 비용이 두 파일시스템에서 사실상 같다**(1.71 vs 1.73, 1.93 vs 1.89). 즉
"XFS 는 절약해 줄 이중 쓰기가 적어서" 라는 설명은 성립하지 않는다. 쓰기 비도
거의 같다(0.92~0.89 vs 0.94~0.95).

달라지는 것은 **처리량 하나뿐이다.** tau 는 XFS 에서 `fpw=on` 대비 1.03x /
1.17x 에 그치고(ext4 는 1.27x / 1.43x), 무보장 `fpw=off` 대비로는 0.75x /
0.68x 까지 떨어진다(ext4 는 0.91x / 0.82x).

전체 창(`write_total`, tau 의 마운트 선할당과 언마운트 드레인 포함) 기준
`fpw=on` 대비는 0.996x / 0.976x 다. XFS 의 드레인이 ext4 보다 크다
(15.2 GB / 11.7 GB vs 10.6 GB / 9.8 GB).

#### 원인은 카운터에 있고, 코드 주석이 이미 예측해 두었다

| 언마운트 후 누적 | ext4 `nix` | ext4 `idx` | **XFS `nix`** | **XFS `idx`** |
|---|---|---|---|---|
| `cpflush_noevid` | 0 | 0 | **3,784,546** | **3,910,425** |
| `cpflush_defer` | 41,325 | 1,161,030 | **5,220,364** | **19,002,192** |
| `flush_submit` | 28.2M | 66.4M | 30.3M | 72.7M |
| `flush_txdirty_late` | 0 | 0 | **6** | **9** |

`cpflush_noevid` 는 "revoke 됐는데 쓰였다는 증거가 없어 다시 제자리에 써야 하는
버퍼" 다. XFS 에서 제자리 쓰기의 **12.5% / 5.4%** 가 이 증거 확보용 재작성이고,
ext4 에서는 정확히 0 이다. `checkpoint.c` 의 해당 분기 주석이 이유를 미리 적어
두었다: ext4 바깥에서는 아무도 `BH_TauCpDone` 을 세우지 않고
(`fs/ext4/page-io.c` 가 유일한 호출자), `tau_mark_bh_dirty()` 는 revoke 된
블록을 iomap 의 dirty 비트맵에 넣으므로, 평범한 백그라운드 writeback 이 그
블록을 청소하면서 **아무 증거도 남기지 않는다.** tau 는 "writeback 이 이미
썼다" 를 배울 방법이 없어 직접 다시 쓴다.

`cpflush_defer` 가 126x / 16x 인 것도 같은 뿌리다 -- 체크포인트가 살아 있는
트랜잭션과 훨씬 자주 부딪힌다.

**따라서 §4.18 (7) 의 "`tau_strict_cpdrop=1` 은 공짜다" 는 ext4 에 한정된다.**
XFS 에서는 제자리 쓰기의 1/8 을 만들어낸다.

#### 안전 지표 — 통과, 다만 읽는 법에 한정이 붙는다

| | XFS `nix` | XFS `idx` |
|---|---|---|
| `cpdrop_unwritten` (실제 유실 조건) | 0 | 0 |
| `retag_failed` | 0 | 0 |
| `flush_onwrite` / `_rev` | 0 / 0 | 0 / 0 |
| `wr_skip_unmapped`, `anchore_notag`, `flush_unmapped` | 0 | 0 |
| dmesg `Call Trace`/`BUG`/`Oops` | 0 | 0 |
| **`flush_folio_busy`** (folio 락이 막음) | **6** | **23** |
| **`flush_txdirty_late`** (제출 시점 가드가 막음) | **6** | **9** |
| **`revoke_notag`** (#246 창에 진입) | 0 | **2** |

`flush_txdirty_late` 는 ext4 6 셀에서 전부 0 이었는데 XFS 에서는 6 / 9 다.
이것은 결함이 아니라 **#250 의 제출 시점 taudirty 가드가 XFS 에서 실제로
값어치를 한다는 증거**다 -- 큐잉 시점엔 깨끗했다가 제출 직전에 tx 소유가 된
버퍼를 그만큼 막았다는 뜻이다.

`flush_notdirty` 는 must-be-zero 가 **아니다**: ext4 40 / 90, XFS 36 / 39 로
양쪽 모두 같은 자릿수다. 발동 시 커널이 남기는 상태는
`[up mapped revoke] folio_tag=0 cp_tx=1` 로, revoke 된 블록을 writeback 이
먼저 청소한 경우다. 유실 여부를 판정하는 것은 `cpdrop_unwritten` 이며 그것은
네 셀 모두 0 이다.

#### 유보 사항

- 워크로드 두 개뿐이다. ext4 는 6 개를 덮었고, 거기서 tau 비가 0.79x~1.13x 로
  벌어졌으므로 XFS 의 다른 워크로드가 같은 값을 줄 것이라고 가정하면 안 된다.
- 각 셀 1 회 측정이다. 다만 두 워크로드가 같은 방향을 가리키고, 차이의 크기가
  §4.18 의 셀 간 편차보다 크며, 카운터가 독립적인 메커니즘을 제시한다.
- §4.13 의 XFS 수치(`fpw=on` 대비 쓰기 0.60~0.67x, 처리량 1.10~1.37x)와는
  맞지 않는다. §4.13 은 trend 하네스에서 나왔고 §4.18 이 그 계열을 무효화했으므로
  여기서 조정을 시도하지 않는다. 인용 가능한 XFS 수치는 이 절뿐이다.

### 유보 사항

- 워크로드마다 이벤트 수가 다르다. 워크로드 간 절대값 비교는 무의미하고, 행 안의
  비율만 유효하다.
- 각 셀은 1회 측정이다. §4.18에서 확인한 셀 간 편차(같은 조건 반복에서 쓰기 -12.9% /
  tps +9.5%)를 감안하면, **0.9x와 1.0x 같은 근소한 차이는 유의하다고 볼 수 없다.**
  6/6에서 tps가 오른다는 방향성과 1.4x급 차이는 그 편차보다 크다. 다만 ext4 베이스라인은
  #238/#243/#250 세 커널에서 1% 안으로 재현되고((2), (6)), MySQL tau 셀도 #243을
  0.2% 안에서 재현하므로((7)), 이 편차는 tau 셀의 로드 상태에서 오는 것으로 보인다.
- `oltp_delete`의 tau 셀은 보호 카운터가 전부 0인데, 이는 통과가 아니라 **미시험**이다.
  MySQL tau 셀도 `revoke_notag = 0`이라 #246의 창은 시험되지 않았다.
- MySQL은 워크로드 하나(`oltp_update_non_index`)뿐이다. PG에서 워크로드에 따라
  tau 비가 0.79x~1.13x로 벌어졌으므로, MySQL의 다른 워크로드가 같은 값을 줄 것이라고
  가정하면 안 된다.
- MySQL의 tps 비는 **1.23x~1.70x 범위로만** 인용해야 한다((6)). 쓰기 비 0.64x~0.65x는
  두 팔이 일치하므로 단일 값으로 인용할 수 있다.
- `defer=1`은 이제 출하 기본값이다. `defer=0`으로 되돌리면 §4.18의 수치대로 돌아가고,
  (5)의 fast path 창도 함께 열린다. MySQL은 (7)대로 어느 쪽이든 무반응이다.


## 4.20 ★ xfs-tau: `tjournal_size=` 를 지정하면 파일 확장이 EINVAL 이다 (2026-09-18)

`tools/tautest` 의 torn-test 가 XFS 에서 레이아웃 단계부터 실패하는 것을
추적하다 나왔다. 증상은 `fallocate: Invalid argument` 였지만 **fallocate 의
문제가 아니다.**

격리 실험(파일시스템 x 마운트 옵션 x 활성화 x fallocate 모드/크기, 24 셀)에서
fallocate 는 **어디서도 깨지지 않았다.** `falloc-test both`(전원 차단 포함,
자유 공간을 0xEE 로 채우고 stale 바이트 검사)도 xfs·ext4 양쪽 PASS 였다.
차이를 만든 것은 마운트 옵션 하나였다:

| 마운트 | 1 GB `O_TAU_UNTORN` fallocate | df used |
|---|---|---|
| `-o tjournal` (저널 기본값 = 장치의 약 10%) | **OK** | 381 G |
| `-o tjournal,tjournal_size=1` | **EINVAL** | 62 G |
| `-o tjournal,tjournal_size=4` | **EINVAL** | 65 G |

커널 로그가 원인을 말한다: `xfs_tau_file_start failed for inode ...`.

`fs/xfs/xfs_iomap.c` 의 `xfs_zero_range()` 는 **범위 전체를 트랜잭션 하나로**
연다:

```c
blocks = (pos + len - 1) / PAGE_SIZE;
blocks -= pos / PAGE_SIZE - 1;
ret = xfs_tau_file_start(inode, blocks);
```

그리고 `tau_file_transaction_start()` 는 `data_blocks > tau_max_buffers_per_tx`
이면 **-EINVAL** 을 반환한다. `tau_max_buffers_per_tx` 는 저널 크기에서
유도되므로(`j_max_transaction_buffers - tau_get_default_blocks_per_tx()`),
**한 번에 확장할 수 있는 최대 크기가 저널 크기에 묶인다.** 사용자 공간에는
맨 EINVAL 만 도착하고 설명은 `pr_err` 에만 남는다.

범위는 fallocate 보다 넓다. `xfs_zero_range` 의 호출자에는 setattr 파일 확장
(`xfs_iops.c`), EOF 너머에서 시작하는 buffered write(`xfs_file.c`),
`xfs_zero_file_space`, reflink 가 있다. 즉 저널이 작으면 `truncate -s 1G` 도
같은 EINVAL 이다.

ext4 는 무관하다 -- `ext4_tau_file_start` 의 호출자는 쓰기 경로이지 확장
경로가 아니다.

**§4.19 (9) 의 XFS 측정에는 영향이 없다.** 그 셀들은 저널을 mkfs 에서
(`-l tjmaxsize=32G`) 걸고 마운트는 `-o tjournal` 만 쓰므로 이 경로를 타지
않는다. `bench/scripts/common.sh` 의 xfs-tau 도 같은 방식이라 과거 측정도
영향이 없다.

### 같은 자리에서 나온 두 번째 결함

`fs/xfs/xfs_super.c`:

```c
case Opt_tau_journal_all:
        parsing_mp->tau_journal_size = 0;   /* 이것이 전부 */
```

`XFS_FEAT_TJOURNAL` 을 세우지 않고, `TJOURNAL_ALL` 심볼은 `fs/xfs` 전체에
존재하지 않는다. ext4 는 `EXT4_MOUNT2_TAU_JOURNAL | EXT4_MOUNT2_TAU_ALL` 을
둘 다 세운다. 즉 **XFS 에서 `-o tjournal_all` 은 조용히 평범한 XFS 를 준다.**
벤치·테스트 스크립트 중 이 옵션을 쓰는 것이 없어 과거 측정에는 영향이 없다.
