#!/bin/bash

set -e
set -o pipefail

if [ -z "$TAUFS_ENV_SOURCED" ]; then
	echo "Do source set_env.sh first."
	exit
fi

cd $TAUFS_BENCH_WS

URL="https://github.com/TPC-Council/HammerDB/releases/download/v5.0/HammerDB-5.0-Prod-Lin-UBU24.tar.gz"
ARCHIVE_NAME="HammerDB-5.0-Prod-Lin-UBU24.tar.gz"

echo "Downloading HammerDB..."
if ! wget "$URL"; then
    echo "Error: Failed to download $URL"
    exit 1
fi

echo "Extracting $ARCHIVE_NAME..."
if ! tar -xzf "$ARCHIVE_NAME"; then
    echo "Error: Failed to extract $ARCHIVE_NAME"
    exit 1
fi

EXTRACTED_DIR="HammerDB-5.0"
rm -f "$ARCHIVE_NAME"

echo "HammerDB build complete."

cd $EXTRACTED_DIR
cp $TAUFS_BENCH/hammerDB/build_postgres_template.tcl ./
cp $TAUFS_BENCH/hammerDB/run_postgres_template.tcl ./
cp $TAUFS_BENCH/hammerDB/build_mysql_template.tcl ./
cp $TAUFS_BENCH/hammerDB/run_mysql_template.tcl ./

echo "Copy template from the repo, ALL_DONE!"
