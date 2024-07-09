#!/bin/bash
source run_vm.sh

(cd $OXBOW_KERNEL && gdb -ex "file vmlinux" -ex "target remote localhost:$QEMU_GDB_PORT")
