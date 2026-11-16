#!/bin/bash
# FC2: lockdep kernel over the paths the 11-15 batch changed (b403 L-*): split twotx /
# onetx / inplace, activation flush, frees with pending tags, frees after a publish,
# truncate races, revoke. The splat check is fast_correct.sh's, over logs.list.
# Env: FC_OUT FC_KDIR_LOCKDEP FC_ROOT FC_DRY. Exit 2 = harness error.
. "$(dirname "$0")/lib-tautest.sh"
: "${FC_KDIR_LOCKDEP:?FC_KDIR_LOCKDEP not set}"
TAUFS_KERNEL=$FC_KDIR_LOCKDEP
[ "$FC_DRY" = 1 ] && : > "$FC_OUT/plan.txt"
fc_setup
fc_boot_check fc2
fc_run L-split      3600 ./split-test.sh both "twotx onetx inplace" 1
fc_run L-actdirty   1800 ./actdirty-test.sh both 1
fc_run L-freetags   1800 ./freetags-test.sh both
fc_run L-epoch-free 2400 ./epoch-test.sh both free-punch,free-trunc,free-punch-journal,free-overwrite 1
fc_run L-trunc-race  900 ./trunc-race-test.sh both 60
fc_run L-revoke     1800 ./revoke-test.sh both all 1
[ "$FC_DRY" = 1 ] && { echo "ESTIMATE_MIN 30" >> "$FC_OUT/plan.txt"; exit 0; }
vm_kill 9>&-
exit 0
