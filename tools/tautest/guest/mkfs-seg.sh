#!/bin/bash
# mkfs-seg.sh <xfs|ext4> <size> <mkfs> <args...>: run mkfs with journal segment
# size <size> unless the args name one (common.sh's TAU_SEGSIZE stubs call this;
# mkfs runs under sudo, which drops the environment). Each call leaves a line in
# the kernel log, so a run can count which mkfs got the size.
fs=$1 size=$2 mkfs=$3
shift 3
case "$*" in
*tjsegsize=*|*tau_segsize=*)
	echo "tautest mkfs $fs: the test's own segment size" 2>/dev/null > /dev/kmsg
	exec "$mkfs" "$@" ;;
esac
echo "tautest mkfs $fs: segment size $size" 2>/dev/null > /dev/kmsg
[ "$fs" = xfs ] && exec "$mkfs" -l tjsegsize="$size" "$@"
# mke2fs keeps only the last -E, so the size joins every -E list
args=() e=
while [ $# -gt 0 ]; do
	case $1 in
	-E) args+=(-E "$2,tau_segsize=$size"); e=1; shift ;;
	-E?*) args+=("$1,tau_segsize=$size"); e=1 ;;
	*) args+=("$1") ;;
	esac
	shift
done
[ -n "$e" ] || args=(-E "tau_segsize=$size" "${args[@]}")
exec "$mkfs" "${args[@]}"
