#!/bin/bash

# 1. 테스트용 디렉토리 설정
TEST_DIR="/mnt/temp" # 실제 마운트 경로에 맞게 수정하세요
mkdir -p "$TEST_DIR"

# [핵심 개선 1] 디스크명 수동 입력 제거 -> 마운트된 실제 파티션 자동 추출
REAL_DEVICE=$(df "$TEST_DIR" | tail -1 | awk '{print $1}')
echo "=> 타겟 디바이스 자동 감지: $REAL_DEVICE"

MAJOR=$((0x$(stat -c "%t" "$REAL_DEVICE")))
MINOR=$((0x$(stat -c "%T" "$REAL_DEVICE")))
DEV_NUM=$(( (MAJOR << 20) | MINOR ))

# 2. bpftrace 시작
echo "=> bpftrace 초기화 중..."
sudo bpftrace -e '
tracepoint:block:block_rq_issue
/args->dev == '$DEV_NUM'/
{
    if (args->rwbs == "WM" || args->rwbs == "WSM" || args->rwbs == "WFM" || args->rwbs == "WFSM" || args->rwbs == "WNM") {
        @meta_write_bytes = sum(args->bytes);
    }
}
END {
    printf("\n[eBPF 분석 완료]\n");
    print(@meta_write_bytes);
    clear(@meta_write_bytes);
}
' > test_ebpf_meta.log 2>&1 &

# 커널에 eBPF 프로그램이 적재될 시간 확보
sleep 3

# 3. 메타데이터 I/O 유발 (빈 파일 100개 생성)
echo "=> 100개의 파일 생성 중..."
touch "$TEST_DIR"/dummy_{1..100}

# 4. 파일 삭제
echo "=> 파일 삭제 중..."
find "$TEST_DIR" -type f -name "dummy_*" -delete

# 5. 캐시 비우기 (디스크로 물리적 쓰기 강제)
sync -f "$TEST_DIR"

# 6. bpftrace 종료
echo "=> 프로파일링 종료 및 결과 생성 중..."
# [핵심 개선 2] sudo의 PID 대신 bpftrace 프로세스 자체에 확실하게 SIGINT 전달
sudo pkill -INT bpftrace
sleep 2 # 결과를 파일에 쓸 시간 대기

# 7. 결과 확인
echo "==================================="
cat test_ebpf_meta.log
echo "==================================="

# 8. 흔적 지우기
rm -f test_ebpf_meta.log