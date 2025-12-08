#!/bin/bash

if [ -z "$TAUFS_ENV_SOURCED" ]; then
	echo "Do source set_env.sh first."
	exit
fi

HAMMERDB="$TAUFS_BENCH_WS/HammerDB-5.0"
RESULT_DIR="$TAUFS_BENCH_WS/results/tpcc"

APP_USER="tpccuser"
APP_PASS="tpccpass"
DBNAME="tpccdb"

TARGET_FILESYSTEM="taujournal"
WAREHOUSE_LIST=(2000)

command -v $HAMMERDB/hammerdbcli >/dev/null || { echo "hammerdbcli not found"; exit 1; }
command -v partclone.ext4 >/dev/null || { echo "partclone.ext4 not found"; exit 1; }

function render_tcl_template() {
    template_path=$1
    output_path=$2
    local -n replacements=$3

    cp "$template_path" "$output_path"
    for key in "${!replacements[@]}"; do
        sed -i "s|__${key}__|${replacements[$key]}|g" "$output_path"
    done
}
