#!/bin/bash
set -e

if [ -z "$TAUFS_ENV_SOURCED" ]; then
	echo "Do source set_env.sh first."
	exit 1
fi

cd $TAUFS_BENCH/postgresql

sudo apt update
sudo apt install -y pkg-config build-essential libreadline-dev zlib1g-dev flex bison libxml2-dev libxslt1-dev libssl-dev

# PG_LZ4=1: the same commit built --with-lz4 into pg_install_lz4, from a clean copy
# (git archive), leaving this tree and pg_install alone: the run_main.sh/run_tpcc.sh
# VARIANT=walcomp reference point (wal_compression=lz4).
if [[ "${PG_LZ4:-0}" == 1 ]]; then
	sudo apt install -y liblz4-dev
	src=$TAUFS_BENCH_WS/pg_src_lz4
	rm -rf "$src" && mkdir -p "$src"
	git archive HEAD | tar -x -C "$src"
	cd "$src"
	./configure --prefix=$TAUFS_BENCH_WS/pg_install_lz4 --with-lz4
	make -j$(nproc)
	make install
	exit 0
fi

make distclean
# Stock relation segment size (1 GB) and block size (8 KiB).
./configure --prefix=$TAUFS_BENCH_WS/pg_install
make -j$(nproc)
make install

export PATH=$TAUFS_BENCH_WS/pg_install/bin:$PATH
