import os
import re
import csv
from glob import glob

def parse_iostat_file(filepath):
    rmb_index = None
    wmb_index = None
    r_values = []
    w_values = []
    header_found = False

    with open(filepath, 'r') as f:
        for line in f:
            if not line.strip():
                continue

            # 헤더 찾기
            if line.startswith("Device") and "rMB/s" in line and "wMB/s" in line:
                headers = line.split()
                try:
                    rmb_index = headers.index("rMB/s")
                    wmb_index = headers.index("wMB/s")
                    header_found = True
                except ValueError:
                    continue
                continue

            if not header_found:
                continue

            parts = line.split()
            if len(parts) <= max(rmb_index, wmb_index):
                continue

            try:
                r_val = float(parts[rmb_index])
                w_val = float(parts[wmb_index])
                r_values.append(r_val)
                w_values.append(w_val)
            except ValueError:
                continue

    if not r_values:
        return {k: 0.0 for k in [
            'read_GB','write_GB','total_GB',
            'read_avg_MBps','read_min_MBps','read_max_MBps',
            'write_avg_MBps','write_min_MBps','write_max_MBps'
        ]}

    count = len(r_values)

    avg_r_all = sum(r_values) / count
    avg_w_all = sum(w_values) / count
    read_gb = (avg_r_all * count) / 1024
    write_gb = (avg_w_all * count) / 1024
    total_gb = read_gb + write_gb

    r_nonzero = [v for v in r_values if v > 0]
    w_nonzero = [v for v in w_values if v > 0]

    def safe_avg(values):
        return sum(values) / len(values) if values else 0.0
    def safe_min(values):
        return min(values) if values else 0.0
    def safe_max(values):
        return max(values) if values else 0.0

    return {
        'read_GB': round(read_gb, 3),
        'write_GB': round(write_gb, 3),
        'total_GB': round(total_gb, 3),
        'read_avg_MBps': round(safe_avg(r_nonzero), 3),
        'read_min_MBps': round(safe_min(r_nonzero), 3),
        'read_max_MBps': round(safe_max(r_nonzero), 3),
        'write_avg_MBps': round(safe_avg(w_nonzero), 3),
        'write_min_MBps': round(safe_min(w_nonzero), 3),
        'write_max_MBps': round(safe_max(w_nonzero), 3),
    }

def extract_metadata(filename):
    # wal_*GB 지원
    pattern = (
        r'^(?P<db>mysql|postgres)_'
        r'(?P<workload>oltp_[a-zA-Z0-9_]+)_'
        r'(?P<fs>[a-zA-Z0-9\-]+)_'
        r'fpw_(?P<fpw>[a-zA-Z0-9]+)_'
        r'(?P<size>t\d+)_'
        r'(?P<cores>c\d+)_'
        r'(wal_(?P<wal>\d+GB)_)?'
        r'iostat\.log$'
    )
    m = re.match(pattern, filename)
    return m.groupdict() if m else None

def main(target_dir):
    log_files = glob(os.path.join(target_dir, '*_fpw_*_iostat.log'))
    results = []

    for filepath in log_files:
        filename = os.path.basename(filepath)
        meta = extract_metadata(filename)
        if not meta:
            print(f"⚠️  파일명 패턴 불일치: {filename}")
            continue
        stats = parse_iostat_file(filepath)
        results.append({**meta, **stats})

    fs_order = ["ext4", "ext4-dj", "xfs", "zfs-8k", "zfs-16k", "taujournal"]
    fpw_order = ["off", "on"]

    def wal_to_gb(wal):
        if wal and re.match(r'\d+GB', wal):
            return int(re.match(r'(\d+)GB', wal).group(1))
        return 0

    def cores_to_int(c):
        try:
            return int(c[1:])  # 'c32' -> 32
        except Exception:
            return 0

    def sort_key(item):
        return (
            fpw_order.index(item['fpw']) if item['fpw'] in fpw_order else 99,
            fs_order.index(item['fs']) if item['fs'] in fs_order else 99,
            item['db'],
            item['workload'],
            item['size'],
            cores_to_int(item['cores']),     # ✅ client(core 수) 숫자 기준 정렬
            wal_to_gb(item.get('wal'))       # ✅ wal 용량 숫자 기준 정렬
        )

    results.sort(key=sort_key)

    # CSV 출력 (wal 추가)
    csv_path = os.path.join(target_dir, 'iostat_summary.csv')
    with open(csv_path, 'w', newline='') as csvfile:
        fieldnames = [
            'db','workload','fpw','fs','size','cores','wal',
            'read_GB','write_GB','total_GB',
            'read_avg_MBps','read_min_MBps','read_max_MBps',
            'write_avg_MBps','write_min_MBps','write_max_MBps'
        ]
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(results)

    print(f"\n✅ 결과가 {csv_path} 에 저장되었습니다.")
    print(f"총 {len(results)}개 파일 처리 완료.")
    print("정렬 기준: fpw(off→on) → fs(ext4→taujournal) → cores(숫자순) → wal(GB순)")

if __name__ == '__main__':
    import sys
    if len(sys.argv) < 2:
        print("사용법: python parse_iostat_final_stats_nozero.py <디렉토리 경로>")
        sys.exit(1)
    main(sys.argv[1])
