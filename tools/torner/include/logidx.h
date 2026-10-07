/* SPDX-License-Identifier: GPL-2.0
 *
 * In-memory index of a dm-log-writes log, shared by replay and atoms.
 *
 * HOW THE LOG IS ORDERED -- read this before reasoning about crash states.
 * It is not "the order writes completed" (drivers/md/dm-log-writes.c):
 *
 *   - a plain write, on completion, waits on an "unflushed" list;
 *   - a FLUSH, when it is *submitted*, takes that whole list, and when it
 *     *completes* the list is logged followed by the flush entry itself;
 *   - a FUA write is logged the moment it completes;
 *   - a MARK is logged when the message arrives.
 *
 * So every flush window reads
 *
 *     [FUA writes and marks, in completion order] [plain-write batch] [FLUSH]
 *
 * and the plain writes of a batch completed at unknown times relative to the
 * FUA writes logged ahead of them.  What that means for the crash model:
 *
 *   - any prefix of the log is a state that can really happen (everything
 *     logged so far happened to persist, in order);
 *   - within the current window, any subset of the plain-write batch may be
 *     missing (a volatile cache), but a FUA write that was logged is durable;
 *   - a FUA is NOT a barrier.  It makes itself durable, nothing else.  Only a
 *     FLUSH orders what came before it.  Treating FUA as a barrier (as the
 *     legacy `epoch` does, and as CrashMonkey's permuter does) hides states in
 *     which a plain write before an unrelated FUA is lost.
 *
 * Two epoch numberings are kept:
 *
 *   epoch   +1 after every FLUSH or FUA entry.  Legacy; the epoch<=N spec and
 *           the older enumeration strategies are defined on it.
 *   fepoch  +1 after every FLUSH entry only.  The durability order: data d is
 *           guaranteed on media before x is iff fepoch(x) > fepoch(d), or d
 *           itself carries FUA.
 */
#ifndef TORNER_LOGIDX_H
#define TORNER_LOGIDX_H

#include <stdint.h>
#include <sys/types.h>

struct lent {
	uint64_t sector;	/* in log sectorsize units */
	uint64_t nr_sectors;
	uint64_t flags;		/* LOG_*_FLAG */
	uint64_t epoch;		/* legacy: FLUSH|FUA-separated */
	uint64_t fepoch;	/* FLUSH-separated */
	off_t	 payload;	/* byte offset of payload in the log, 0 if none */
};

enum lmark_kind {
	LMARK_PROG = 0,		/* torner:prog=N  progress-log watermark */
	LMARK_BEGIN,		/* torner:begin   workload starts */
	LMARK_END,		/* torner:end     workload finished */
	LMARK_OTHER
};

struct lmark {
	uint64_t entry;
	uint64_t slot;		/* LMARK_PROG only */
	enum lmark_kind kind;
};

struct rlog {
	int fd;
	uint32_t sectorsize;
	uint64_t nr_entries;	/* as declared by the log superblock */

	struct lent *e;
	size_t n;
	uint64_t epochs;	/* legacy epochs that hold entries */
	uint64_t fepochs;

	/* lastflush[i]: index of the last FLUSH entry at or before i, or -1 */
	int64_t *lastflush;

	struct lmark *m;
	size_t mark_n;
	int64_t begin_entry;	/* -1 when the capture predates begin marks */
	int64_t end_entry;
};

int  rlog_open(struct rlog *l, const char *path, const char *who);
void rlog_close(struct rlog *l);

/*
 * Highest progress slot marked at or before log entry @last.  A replayed state
 * is only answerable for progress records below it: the progress log lives off
 * the stack under test and survives whole, so without this bound every write
 * after the cut would read as a lost durable write.
 */
uint64_t rlog_progress_limit(const struct rlog *l, uint64_t last);

/* Index of the last entry whose legacy epoch is <= @epoch (0 if none). */
uint64_t rlog_last_entry_of_epoch(const struct rlog *l, uint64_t epoch);

/* Is entry @i a write that a volatile cache could still lose at a crash
 * right after entry @c?  (plain data or discard, logged after the last FLUSH
 * at or before @c, and at or before @c itself) */
int rlog_volatile_at(const struct rlog *l, uint64_t i, uint64_t c);

void *xrealloc(void *p, size_t n);

static inline uint64_t splitmix(uint64_t *s)
{
	uint64_t z = (*s += 0x9E3779B97F4A7C15ULL);

	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
	z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
	return z ^ (z >> 31);
}

#endif /* TORNER_LOGIDX_H */
