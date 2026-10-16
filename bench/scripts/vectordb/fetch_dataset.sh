#!/bin/bash
# Download a VectorDBBench dataset into DATASET_LOCAL_DIR, where VectorDBBench
# finds it and skips its own download.
#
#   bench/scripts/vectordb/fetch_dataset.sh cohere_medium_1m      # Performance768D1M
#   bench/scripts/vectordb/fetch_dataset.sh cohere_large_10m      # Performance768D10M
#   bench/scripts/vectordb/fetch_dataset.sh openai_small_50k      # Performance1536D50K
#
# VectorDBBench downloads through s3fs, which stalled at ~1 MB/s from libra09
# (2026-10-07); plain HTTPS from the same bucket ran at ~16 MB/s. curl resumes
# a file whose transfer stalls (-C -). The file list is VectorDBBench's own.
set -e

NAME="$1"
[ -n "$NAME" ] || { echo "Usage: $0 <dataset dir name, e.g. cohere_medium_1m>"; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
VENV="${VDB_VENV-$ROOT/bench/workspace/vdb-venv}"
export DATASET_LOCAL_DIR="${DATASET_LOCAL_DIR-/mnt/tau_backup/vectordb/dataset}"
URL="https://assets.zilliz.com/benchmark/$NAME"

# <local dir> <file>...: the files VectorDBBench reads for this dataset (k = 100)
read -r DIR FILES < <(LOG_FILE=/dev/null "$VENV/bin/python" - "$NAME" <<'EOF'
import sys
from vectordb_bench import config
from vectordb_bench.backend.dataset import Dataset

name = sys.argv[1]
for ds in Dataset:
    for size in getattr(ds.value, "_size_label", {}):
        try:
            m = ds.manager(size)
        except Exception:
            continue
        if m.data.dir_name.lower() != name:
            continue
        d = m.data
        files = list(d.train_files)
        if d.with_gt:
            sf = m.resolve_search_files(k=config.K_DEFAULT)
            files += [*sf.test_files, sf.gt_file]
        if d.with_scalar_labels and d.scalar_labels_file_separated:
            files.append(d.scalar_labels_file)
        print(m.data_dir, *dict.fromkeys(files))
        sys.exit(0)
sys.exit(f"unknown dataset {name}")
EOF
)

mkdir -p "$DIR"
cd "$DIR"
for f in $FILES; do
  want=$(curl -sI "$URL/$f" | awk 'tolower($1)=="content-length:"{print $2}' | tr -d '\r')
  [ -n "$want" ] || { echo "❌ $URL/$f: no size"; exit 1; }
  for try in $(seq 1 30); do
    [ "$(stat -c %s "$f" 2>/dev/null || echo 0)" -ge "$want" ] && break
    curl -s --speed-limit 1000000 --speed-time 20 -C - -o "$f" "$URL/$f" || true
  done
  have=$(stat -c %s "$f")
  [ "$have" = "$want" ] || { echo "❌ $f: $have of $want bytes"; exit 1; }
  echo "$f $have"
done
echo "$NAME in $DIR"
