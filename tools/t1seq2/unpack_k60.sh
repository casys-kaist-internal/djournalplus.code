#!/bin/bash
# The k60 sample (10,100 seq-2 workloads, sample.py 60 with SEED 20261106, made on libra09 11-06) as
# run_seq2.sh takes it, on another host: unpacks k60.tar.xz (cpp/, sample.tsv, invalid.tsv) and
# builds each cpp/j-lang<N>.cpp into so/ with the rule sample.py builds with (g++-9, CrashMonkey's
# build/ objects; make CrashMonkey first). The cpp files are the sample, so no Ace generation here.
#   unpack_k60.sh <out dir>   then: run_seq2.sh <out dir>
{
set -u
H=$(cd "$(dirname "$0")" && pwd); C=$(cd "$H/../crashmonkey" && pwd); B=$C/build
OUT=${1:?out dir}
mkdir -p "$OUT/so" && tar xJf "$H/k60.tar.xz" -C "$OUT" || exit 1
OBJ=""; for o in tests/BaseTestCase.o user_tools/src/actions.o user_tools/src/wrapper.o user_tools/src/workload.o \
  utils/DiskMod.o utils/communication/BaseSocket.o utils/communication/ClientSocket.o \
  utils/communication/ClientCommandSender.o results/DataTestResult.o; do
  [ -f "$B/$o" ] || { echo "no $B/$o: build CrashMonkey first"; exit 1; }; OBJ="$OBJ $B/$o"
done
export C OBJ OUT
ls "$OUT"/cpp/j-lang*.cpp | xargs -P 32 -I{} bash -c 'n=$(basename {} .cpp); [ -f "$OUT/so/$n.so" ] ||
  g++-9 -std=c++11 -shared -fPIC -DNEW_XATTR_INC -I "$C/code/tests/seq1" -Wl,-soname,$n.so -o "$OUT/so/$n.so" {} $OBJ ||
  echo "FAILED $n"'
echo "$(ls "$OUT"/so/*.so | wc -l) .so of $(wc -l < "$OUT/sample.tsv") in sample.tsv"
exit
}
