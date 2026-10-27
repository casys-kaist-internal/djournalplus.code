#!/bin/bash
# migrate-probes.sh on|report   (run as root)
# Counts what the XFS tau migrate hook does, with kretprobes -- no kernel change:
#   tau_mig  xfs_tau_migrate_folio()   0 = moved, -11 = refused
#   tau_fmf  filemap_migrate_folio()   its own -11 is the refcount check, not tau
#   tau_tf   tau_slot_try_free()       0 = the slot was busy (migrate, release, invalidate)
T=/sys/kernel/tracing
E="tau_mig tau_fmf tau_tf"

count() {	# <event> <ret, a regex>: hits with that return value
	sed -nE "s/^\{ ret: *($2) \} hitcount: *([0-9]+).*/\2/p" $T/events/kprobes/$1/hist | head -1
}
EAGAIN='-11|18446744073709551605|4294967285'	# however the histogram prints a negative

case "${1:-}" in
on)
	for e in $E; do
		[ -d $T/events/kprobes/$e ] || continue
		echo '!hist:keys=ret' > $T/events/kprobes/$e/trigger 2>/dev/null
		echo "-:$e" >> $T/kprobe_events
	done
	echo 'r:tau_mig xfs_tau_migrate_folio ret=$retval:s32' >> $T/kprobe_events || exit 1
	echo 'r:tau_fmf filemap_migrate_folio ret=$retval:s32' >> $T/kprobe_events || exit 1
	echo 'r:tau_tf tau_slot_try_free ret=$retval:u8' >> $T/kprobe_events || exit 1
	for e in $E; do
		echo 'hist:keys=ret' > $T/events/kprobes/$e/trigger || exit 1
	done
	;;
report)
	moved=$(count tau_mig 0);	refused=$(count tau_mig "$EAGAIN")
	fmf_refused=$(count tau_fmf "$EAGAIN"); busy=$(count tau_tf 0)
	moved=${moved:-0}; refused=${refused:-0}; fmf_refused=${fmf_refused:-0}; busy=${busy:-0}
	echo "  xfs_tau_migrate_folio: moved $moved, refused $refused"
	echo "  of the refusals, filemap_migrate_folio's own (refcount): $fmf_refused"
	echo "  -> refused because the slot was busy: $((refused - fmf_refused))"
	echo "  tau_slot_try_free said busy (all callers): $busy"
	grep -E "tau_mig|tau_fmf|tau_tf" $T/kprobe_profile | awk '{print "  probe " $1 ": hits " $2 ", missed " $3}'
	echo "MIG_MOVED=$moved MIG_REFUSED_BUSY=$((refused - fmf_refused))"
	;;
*)	echo "usage: $0 on|report" >&2; exit 2 ;;
esac
