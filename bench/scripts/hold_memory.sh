#!/bin/bash
# Hold back more memory at run time as unused huge pages, so the benchmarks
# see <GB> of usable memory (MemTotal - Hugetlb), split evenly over the NUMA
# nodes -- a smaller machine, made like the boot-time TAU_BOOT_ARGS pool.
# `reset` releases what this script held.
#
#   bench/scripts/hold_memory.sh 40      # usable ~40 GB
#   bench/scripts/hold_memory.sh reset
#   bench/scripts/hold_memory.sh         # show the current state
#
# Run with TAU_MEM_GB and TAU_DB_CACHE_GB (= 25%) set to match, e.g.
# TAU_MEM_GB=40 TAU_DB_CACHE_GB=10.
#
# The extra pages are 2 MiB ones: at run time the kernel rarely finds free
# 1 GiB-aligned ranges (on libra09 it found none with 56 GB free). 2 MiB is
# the default huge page size, which PostgreSQL's huge_pages=try would take for
# shared_buffers -- run PostgreSQL with huge_pages=off while memory is held
# (vectordb/run_pgvector.sh does). InnoDB uses large pages only if asked.
set -e

HP1G=hugepages/hugepages-1048576kB
HP2M=hugepages/hugepages-2048kB
NODES=$(ls -d /sys/devices/system/node/node[0-9]* | xargs -n1 basename)

usable_gib() {   # usable_gib <node>: MemTotal of the node minus its huge pages
  local d=/sys/devices/system/node/$1
  awk -v g="$(cat $d/$HP1G/nr_hugepages)" -v m="$(cat $d/$HP2M/nr_hugepages)" \
    '/MemTotal/ { printf "%.2f", $4 / 1048576 - g - m / 512 }' $d/meminfo
}

show() {
  local d
  for n in $NODES; do
    d=/sys/devices/system/node/$n
    echo "$n: $(cat $d/$HP1G/nr_hugepages) x 1 GiB (boot) + $(cat $d/$HP2M/nr_hugepages) x 2 MiB held, $(usable_gib $n) GiB usable"
  done
  awk '/^MemTotal/{t=$2} /^Hugetlb/{h=$2} END{printf "usable: %.2f GiB (MemTotal - Hugetlb)\n", (t-h)/1048576}' /proc/meminfo
}

set_2m() {       # set_2m <node> <count>
  echo "$2" | sudo tee /sys/devices/system/node/$1/$HP2M/nr_hugepages > /dev/null
  local got
  got=$(cat /sys/devices/system/node/$1/$HP2M/nr_hugepages)
  [ "$got" = "$2" ] || { echo "❌ $1: asked for $2 x 2 MiB pages, got $got"; exit 1; }
}

case "${1:-}" in
  "")
    show
    ;;
  reset)
    for n in $NODES; do set_2m "$n" 0; done
    show
    ;;
  *[!0-9]*)
    echo "Usage: $0 [<usable GB> | reset]"; exit 1
    ;;
  *)
    per_node=$(awk -v t="$1" -v n="$(echo $NODES | wc -w)" 'BEGIN { print t / n }')
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    echo 1 | sudo tee /proc/sys/vm/compact_memory > /dev/null
    for n in $NODES; do
      have=$(cat /sys/devices/system/node/$n/$HP2M/nr_hugepages)
      extra=$(awk -v u="$(usable_gib $n)" -v p="$per_node" 'BEGIN { x = int((u - p) * 512); print (x > 0 ? x : 0) }')
      set_2m "$n" $((have + extra))
    done
    show
    ;;
esac
