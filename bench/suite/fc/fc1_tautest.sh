#!/bin/bash
# FC1: the tautest set the 11-15 kernel batch was verified with (b403): one write's
# untorn units, revoke tags, frees with pending tags, frees after a publish, freed blocks
# reused, truncate races, power cuts, journal pressure, write-during-commit stress; a write
# SIGKILLed part way (#81) and a source that faults part way (#24, #69).
# Env (bench/suite/fast_correct.sh): FC_OUT FC_KDIR FC_ROOT FC_DRY [FC_STRESS_ROUNDS=150]
# Out: cases.tsv, logs.list (console.log), plan.txt when FC_DRY=1. Exit 2 = harness error.
. "$(dirname "$0")/lib-tautest.sh"
: "${FC_KDIR:?FC_KDIR not set}"
TAUFS_KERNEL=$FC_KDIR
N=${FC_STRESS_ROUNDS:-150}
[ "$FC_DRY" = 1 ] && : > "$FC_OUT/plan.txt"
fc_setup
fc_boot_check fc1
fc_run split       2400 ./split-test.sh both all 1
fc_run split-ctl   1200 ./split-test.sh both "twotx-ctl onetx" 1
fc_run actdirty    1200 ./actdirty-test.sh both 2
fc_run revoke      1800 ./revoke-test.sh both all 1
fc_run freetags    1800 ./freetags-test.sh both
fc_run epoch-free  2400 ./epoch-test.sh both free-punch,free-trunc,free-punch-journal,free-overwrite 1
fc_run trunc-reuse 3600 ./trunc-reuse-test.sh both all
fc_run trunc-race   900 ./trunc-race-test.sh both 60
fc_run killwrite    900 ./killwrite-test.sh both 100
fc_run shortcopy    600 ./shortcopy-test.sh both
fc_run crash        900 ./crash-test.sh both
fc_run torn        3600 ./torn-test.sh both 1 300
fc_run stress-ext4 3600 ./stress-test.sh ext4 $N 6 5
fc_run stress-xfs  3600 ./stress-test.sh xfs $N 6 5
[ "$FC_DRY" = 1 ] && { echo "ESTIMATE_MIN 95" >> "$FC_OUT/plan.txt"; exit 0; }
vm_kill 9>&-
exit 0
