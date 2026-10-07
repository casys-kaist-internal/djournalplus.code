/* SPDX-License-Identifier: GPL-2.0
 *
 * Application atomic writes, recovered from a dm-log-writes log.
 *
 * `torner gen` writes each atomic unit W = (page, version) as sectors that say
 * which W they belong to.  So W can be followed through the log without
 * knowing anything about the file system: every byte-exact copy of one of its
 * sectors -- the in-place write, a journal copy, a checkpoint, a copy-on-write
 * relocation, even a copy embedded unaligned inside a log record -- is found
 * by content, verified by CRC, and pinned to the log entry that carried it.
 *
 * The shape of W is decided by where its sectors FIRST reach the device:
 *
 *   one entry            W travelled as one bio.  Only a device that tears a
 *                        bio can split that write.
 *   two or more entries  W travelled in pieces.  A crash between the pieces
 *                        -- a plain prefix of the log, which assumes nothing
 *                        about the device -- leaves part of W on disk, and
 *                        only the file system's recovery stands between that
 *                        and a torn unit.
 *
 * The crash states are planned over EVERY entry that carries a copy of W, not
 * only the first: a journal copy and its checkpoint, or a log record and the
 * in-place write it is replayed into, are separated by crash points too, and
 * those are where recovery has to put things right.
 *
 * This is the file-system-agnostic core of the suite: it decides which crash
 * states can break which application write, and `torner replay --strategy
 * atom-*` turns that into states for recovery to be judged on.
 */
#ifndef TORNER_ATOMS_H
#define TORNER_ATOMS_H

#include <stdint.h>
#include <stddef.h>

#include "logidx.h"

/* One byte-exact, CRC-verified copy of a torner sector found in the log. */
struct ahit {
	uint64_t page;
	uint64_t version;
	uint64_t entry;		/* log entry carrying the copy */
	uint64_t off;		/* byte offset of the copy within that payload */
	uint32_t sidx;
	uint32_t spu;
	uint32_t ssz;
	uint32_t pad;
};

enum atom_class {
	ATOM_ONE_BIO = 0,	/* first copies all in one entry */
	ATOM_SPLIT_WINDOW,	/* several entries, no FLUSH between them */
	ATOM_SPLIT_FLUSH,	/* several entries, a FLUSH between them */
	ATOM_PARTIAL,		/* some sectors never reach the device at all */
	ATOM__NCLASS
};

/* An application atomic write W = (page, version). */
struct atom {
	uint64_t page;
	uint64_t version;
	uint32_t spu;
	uint32_t ssz;
	size_t	 h_lo, h_hi;	/* its copies: [h_lo, h_hi) of the sorted hits */
	uint64_t seen;		/* sectors with at least one copy */
	uint32_t k;		/* distinct first-appearance entries */
	uint32_t nentries;	/* distinct log entries carrying any of its
				 * sectors: pieces and later copies alike */
	uint64_t g_first;	/* earliest first-appearance entry */
	uint64_t g_last;	/* latest first-appearance entry */
	uint64_t last_copy;	/* latest entry carrying any copy */
	uint64_t next_ver;	/* first entry of (page, version+1), or UINT64_MAX */
	enum atom_class cls;
	uint8_t	 workload;	/* version >= 1: written by the workload, not setup */
	uint8_t	 embedded;	/* a first copy is not sector-aligned in its entry */
	uint8_t	 reorderable;	/* an earlier piece is still volatile at a later one */
};

struct atoms {
	struct ahit *h;
	size_t hn;
	struct atom *a;
	size_t an;

	/* scan accounting, so a clean result can be told from a blind one */
	uint64_t bytes_scanned;
	uint64_t candidates;	/* magic matches */
	uint64_t rejected;	/* ...that failed geometry/CRC/fill checks */
	uint64_t embedded_copies;
};

int  atoms_scan(const struct rlog *l, uint64_t run_id, struct atoms *out);
void atoms_free(struct atoms *as);

/* Distinct first-appearance entries of @a, ascending, with the sector mask
 * each one carries.  Returns the count (== a->k). */
uint32_t atom_groups(const struct atoms *as, const struct atom *a,
		     uint64_t *g, uint64_t *gmask, uint32_t max);

const char *atom_class_name(enum atom_class c);

/*
 * State planning.  Each plan calls @emit once per crash state, with the spec,
 * the entry the crash happens after, and the application writes the state is
 * aimed at.  Every state a plan emits is legal under the log model described
 * in logidx.h:
 *
 *   atom-order    entry<=c                  a plain prefix; assumes nothing
 *                                           (model O)
 *   atom-reorder  entry<=c,drop=[...]       drops only writes still volatile
 *                                           at c (after the last FLUSH, and
 *                                           not FUA)               (model R)
 *   atom-tear     entry<=j,partial=[j:k]    the write in flight at the crash
 *                                           lands up to an atomic-unit
 *                                           boundary of the device (model T)
 */
struct plan_state {
	const char *strategy;
	const char *model;	/* O in-order prefix, R reordered cache, T torn bio */
	uint64_t crash_entry;
	const char *spec;
	const struct atom **targets;
	size_t ntargets;
};

typedef void (*plan_emit_fn)(void *ctx, const struct plan_state *st);

struct plan_opts {
	uint64_t max_states;	/* budget, 0 = none: whole writes are sampled
				 * until their states reach it */
	uint64_t seed;
	uint64_t atom_bytes;	/* device atomic unit, for atom-tear */
	uint32_t per_atom_barriers; /* atom-order: cap on barrier cuts per W */
	int	 first_copy_only; /* atom-tear: only tear the first copy */
	int	 prefer_split;	/* with a budget: split writes first (by shape),
				 * random within a shape -- for hunting a
				 * witness, not for estimating a rate */
	const char *const *sigs; /* only writes with these shape signatures, */
	size_t	 nsigs;		 /* sorted by strcmp; 0 = all writes        */
};

struct plan_stats {
	uint64_t atoms_eligible;	/* workload atoms the plan applies to */
	uint64_t atoms_targeted;	/* ...that at least one emitted state aims at */
	uint64_t candidates;		/* states before any sampling */
	uint64_t emitted;
};

int atoms_plan(const struct rlog *l, const struct atoms *as, const char *strategy,
	       const struct plan_opts *o, plan_emit_fn emit, void *ctx,
	       struct plan_stats *st);

int torner_atoms(int argc, char **argv);

#endif /* TORNER_ATOMS_H */
