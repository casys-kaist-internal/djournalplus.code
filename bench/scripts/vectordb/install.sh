#!/bin/bash
# pgvector into the benchmark PostgreSQL (bench/workspace/pg_install) and
# VectorDBBench into a venv (bench/workspace/vdb-venv).
#
#   source set_env.sh   # from the repository root
#   bench/scripts/vectordb/install.sh
#
# VectorDBBench itself is the bench/VectorDBBench submodule; nothing is changed
# in it (vdbbench.py adds what the pgvector commands lack).
set -e

if [ -z "$TAUFS_ENV_SOURCED" ]; then
  echo "Do source set_env.sh first."
  exit 1
fi

PGVECTOR_TAG="${PGVECTOR_TAG-v0.8.7}"
PG_CONFIG="$TAUFS_BENCH_WS/pg_install/bin/pg_config"
SRC="$TAUFS_BENCH_WS/pgvector"
VENV="$TAUFS_BENCH_WS/vdb-venv"

[ -x "$PG_CONFIG" ] || { echo "❌ no PostgreSQL in $TAUFS_BENCH_WS/pg_install (bench/scripts/postgres/install_postgres.sh)"; exit 1; }

if [ ! -d "$SRC" ]; then
  git clone --branch "$PGVECTOR_TAG" --depth 1 https://github.com/pgvector/pgvector.git "$SRC"
fi
# -march=native (pgvector's default): build on the machine that runs it
make -C "$SRC" PG_CONFIG="$PG_CONFIG" -j"$(nproc)"
make -C "$SRC" PG_CONFIG="$PG_CONFIG" install

# VectorDBBench needs Python >= 3.11
[ -x "$VENV/bin/python" ] || python3 -m venv "$VENV"
"$VENV/bin/pip" install -q --upgrade pip
"$VENV/bin/pip" install -q "$TAUFS_BENCH/VectorDBBench[pgvector]"

echo "pgvector $(cd "$SRC" && git describe --tags) in $("$PG_CONFIG" --pkglibdir)"
echo "VectorDBBench: $VENV/bin/vectordbbench"
echo "Datasets: bench/scripts/vectordb/fetch_dataset.sh <name>, e.g. cohere_medium_1m"
