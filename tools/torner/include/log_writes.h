/* SPDX-License-Identifier: GPL-2.0
 *
 * dm-log-writes on-disk log format.
 *
 * Transcribed from the kernel (drivers/md/dm-log-writes.c) and cross-checked
 * against xfstests src/log-writes/log-writes.h, which the kernel header names
 * as the userspace copy.  Both agree in this tree: version 1, magic
 * 0x6a736677736872, and identical struct layouts.
 *
 * Disk layout:
 *
 *   byte 0          struct log_write_super_d, padded to sectorsize
 *   per entry       struct log_write_entry_d, padded to sectorsize
 *                   followed by nr_sectors * sectorsize of data
 *
 * The one asymmetry worth remembering: DISCARD entries have a non-zero
 * nr_sectors but carry NO payload, because dm-log-writes only writes the data
 * out when !(flags & LOG_DISCARD_FLAG).  Treating them as payload-bearing
 * desynchronises every entry that follows.
 */
#ifndef TORNER_LOG_WRITES_H
#define TORNER_LOG_WRITES_H

#include <stdint.h>

/* drivers/md/dm-log-writes.c:56-63 */
#define LOG_FLUSH_FLAG		(1 << 0)
#define LOG_FUA_FLAG		(1 << 1)
#define LOG_DISCARD_FLAG	(1 << 2)
#define LOG_MARK_FLAG		(1 << 3)
#define LOG_METADATA_FLAG	(1 << 4)

#define WRITE_LOG_VERSION	1ULL
#define WRITE_LOG_MAGIC		0x6a736677736872ULL

struct log_write_super_d {
	uint64_t magic;
	uint64_t version;
	uint64_t nr_entries;
	uint32_t sectorsize;
} __attribute__((packed));

struct log_write_entry_d {
	uint64_t sector;
	uint64_t nr_sectors;
	uint64_t flags;
	uint64_t data_len;
} __attribute__((packed));

#endif /* TORNER_LOG_WRITES_H */
