#!/bin/bash
# BenchBase for the TPC-C runs: upstream cmu-db/benchbase at a pinned commit
# plus our patches (patches/), built for MySQL and PostgreSQL and unpacked to
# $TAUFS_BENCH_WS/benchbase/<mysql|postgres>/ (benchbase.jar, lib/).
#   0001  <randomWarehouse>true</randomWarehouse>: every TPC-C transaction picks
#         its warehouse and district at random (HammerDB's "Use All
#         Warehouses"); upstream binds each terminal to a home warehouse, so
#         32 terminals touch only 32 warehouses however many are loaded
#   0002  transaction outcomes (success, abort, retry, error) are counted only
#         in the measured window, like the latencies; upstream counts the
#         warm-up too and divides by the measured time (goodput, per-type counts)
#   0003  PostgreSQL deadlock_detected (40P01) is retried like MySQL's deadlock;
#         upstream gives up on it (TPC-C NewOrder updates stock in random order)
# Needs a JDK >= 23 (Ubuntu 24.04: openjdk-25-jdk-headless). The formatter
# plugin does not run on JDK 25 (skipped), and the build targets --release 23
# (with -source/-target 23 javac warns, which -Werror turns into an error).
# Usage: install.sh
set -e
BB_COMMIT=33c00473   # upstream main, 2025-12-13
SRC="$TAUFS_BENCH/benchbase"
PATCHES="$TAUFS_BENCH/scripts/benchbase/patches"
OUT="$TAUFS_BENCH_WS/benchbase"

command -v java >/dev/null || { echo "❌ no java (apt install openjdk-25-jdk-headless)"; exit 1; }
[[ -d "$SRC/.git" ]] || git clone https://github.com/cmu-db/benchbase.git "$SRC"
cd "$SRC"
if git apply --reverse --check "$PATCHES"/*.patch 2>/dev/null &&
    [[ "$(git rev-parse --short=8 HEAD)" == "$BB_COMMIT" ]]; then
  echo "[*] $SRC is at $BB_COMMIT with the patches"
else
  git diff --quiet || { echo "❌ $SRC has other local changes"; exit 1; }
  git cat-file -e "$BB_COMMIT^{commit}" 2>/dev/null || git fetch origin
  git checkout -q "$BB_COMMIT"
  git apply "$PATCHES"/*.patch
  echo "[*] $SRC at $BB_COMMIT, patches applied"
fi
for p in mysql postgres; do
  ./mvnw -B -q clean package -P "$p" -DskipTests -Dfmt.skip=true -Dmaven.compiler.release=23
  rm -rf "${OUT:?}/$p"
  mkdir -p "$OUT/$p"
  tar -xzf "target/benchbase-$p.tgz" -C "$OUT/$p" --strip-components=1
  echo "[✓] $OUT/$p"
done
