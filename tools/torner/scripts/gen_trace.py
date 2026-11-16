#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""
gen_trace.py TRACE DEV INO LOST -- what the page cache did during gen's workload

capture.sh traces mm_filemap_add_to_page_cache and balance_dirty_pages in a tracefs
instance of its own while `torner gen` runs; gen writes "torner:begin" and
"torner:end" to the instance's trace_marker around the workload (after setup, so
a prefill's folios do not count).  Between the two markers this counts

  folio_orders   the target file's new folios by order (DEV "maj:min", INO decimal):
                 order 0 everywhere means a 16 KiB write spans four folios, and
                 writeback can take some of them without the rest
  dirty_pauses   balance_dirty_pages events of gen's threads ("torner-<pid>") with
                 pause > 0: a writer put to sleep for dirty pages, possibly
                 halfway through a write (dirty_pause_ms: how long, in all);
                 dirty_checks counts the events with pause <= 0 too (throttled
                 but not slept: the kernel traces those with pause clamped to 0)

and prints one JSON object.  LOST is the ring buffer's overrun count: events the
buffer dropped, which the counts above then miss.
"""
import json
import re
import sys

FOLIO = re.compile(r"mm_filemap_add_to_page_cache: dev (\d+:\d+) ino ([0-9a-f]+) .*order=(\d+)")
PAUSE = re.compile(r" pause=(-?\d+) ")


def main():
    path, dev, ino, lost = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    on = seen_begin = False
    orders, pauses, checks, pause_ms, other = {}, 0, 0, 0, 0
    with open(path, errors="replace") as f:
        for line in f:
            if "tracing_mark_write: torner:begin" in line:
                on = seen_begin = True
            elif "tracing_mark_write: torner:end" in line:
                on = False
            elif on:
                m = FOLIO.search(line)
                if m:
                    if m.group(1) == dev and int(m.group(2), 16) == ino:
                        orders[m.group(3)] = orders.get(m.group(3), 0) + 1
                    else:
                        other += 1
                elif "balance_dirty_pages:" in line and line.lstrip().startswith("torner-"):
                    checks += 1
                    p = PAUSE.search(line)
                    if p and int(p.group(1)) > 0:
                        pauses += 1
                        pause_ms += int(p.group(1))
    out = {"folio_orders": {o: orders[o] for o in sorted(orders, key=int)},
           "folios": sum(orders.values()),
           "folio_pages": sum(n << int(o) for o, n in orders.items()),
           "other_folios": other, "dirty_pauses": pauses, "dirty_pause_ms": pause_ms,
           "dirty_checks": checks, "trace_lost": lost,
           "markers": seen_begin}
    json.dump(out, sys.stdout)
    print()


if __name__ == "__main__":
    main()
