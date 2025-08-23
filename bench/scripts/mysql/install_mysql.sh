#!/bin/bash
set -e

if [ -z "$TAUFS_ENV_SOURCED" ]; then
	echo "Do source set_env.sh first."
	exit
fi

SRC_DIR="$TAUFS_BENCH/mysql-server"
INSTALL_PREFIX="$TAUFS_BENCH_WS/mysql"

sudo apt update
sudo apt-get install -y build-essential cmake ninja-build git bison pkg-config \
  libncurses5-dev libssl-dev zlib1g-dev libaio-dev libtirpc-dev libsasl2-dev libudev-dev

mkdir -p "$SRC_DIR/build"
cd "$SRC_DIR/build"

cmake .. \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
  -DTAU_JOURNAL=1

make -j"$(nproc)"

echo "✅ Installed Done"
