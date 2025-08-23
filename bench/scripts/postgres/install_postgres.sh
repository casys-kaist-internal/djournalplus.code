#!/bin/bash
set -e

if [ -z "$TAUFS_ENV_SOURCED" ]; then
	echo "Do source set_env.sh first."
	exit
fi

cd $TAUFS_BENCH/postgresql

sudo apt update
sudo apt install -y pkg-config build-essential libreadline-dev zlib1g-dev flex bison libxml2-dev libxslt1-dev libssl-dev

./configure --prefix=$TAUFS_BENCH_WS/pg_install
make -j$(nproc)
make install

export PATH=$TAUFS_BENCH_WS/pg_install/bin:$PATH
