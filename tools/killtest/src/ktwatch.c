// SPDX-License-Identifier: GPL-2.0
//
// ktwatch -- the guest half of killtest's writeback-triggered kill
// (killtest.py db --kill-on writeback).
//
// Polls the test device's in-flight request counts (/sys/block/<dev>/inflight:
// "reads writes") and, once armed, asks the host to kill the VM the first
// time at least KILL writes have been in flight for HOLD_US (0: at once).
// The request is a store into memory the host shares with the VM (QEMU's
// ivshmem-plain BAR 2, mapped through sysfs, -m): the host spins on it and
// sends SIGKILL a few microseconds later.  No VM exit is involved -- an I/O
// port or a serial line would be served under QEMU's big lock, which its
// NVMe emulation holds while it takes a whole batch of requests off the
// queue, so the kill would wait until the batch is on its way and the
// writes it was aimed at are done.  Without -m the request goes to stdout
// (a test outside the VM).
//
// Armed once ARM_MS have passed and, with -l, while the last line of LOG
// that contained START or END contained START, for GATE_MS or more
// (PostgreSQL: "checkpoint starting" and "checkpoint complete"; when the
// database fits in shared_buffers, checkpoints are all that write its data
// pages, and outside them the device sees WAL writes).
//
// Every REPORT_MS it prints how many in-flight writes it saw, as a histogram,
// with the device's writes in that interval and the page cache's dirty and
// writeback amounts ("@@KT WATCH ..." lines on stdout), so that a run with
// -k 0 (never kill) shows what a threshold would catch.  With them go
// "@@KT WATCH_BURSTS" lines: the episodes of BURST_W (8) or more writes in
// flight, by the most writes they had in flight and by how long they lasted
// -- a log write and a burst of data-page writeback look different there.
//
//   ktwatch [-i inflight] [-k writes] [-d hold_us] [-a arm_ms]
//           [-l log -s start -e end] [-g gate_ms] [-m shm] [-p poll_us]
//           [-r report_ms] [-t timeout_ms] [-b burst_w] [-F rt_prio]
//
// -F runs it SCHED_FIFO at that priority: the database's threads keep every
// vCPU busy, and a watcher they preempt for milliseconds would leave a stale
// sample in the shared page.
//
// The shared page: the request text at offset 64, then a nonzero word at 0.
// Words 2-7 always hold the latest sample, for a host that kills at a time
// of its own (--kill-on random) and wants to know what was in flight: writes,
// reads, checkpoint open, the current burst's most writes and age in us (0
// outside a burst of BURST_W or more), and a sample count.

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sched.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <time.h>
#include <unistd.h>

// in-flight writes: 0 | 1-3 | 4-7 | 8-15 | 16-31 | 32-63 | 64-127 | 128+
#define NBUCKET 8
// burst durations: <100us | <300us | <1ms | <3ms | <10ms | longer
#define NDUR 6

static int dur_bucket(double s)
{
	static const double lim[NDUR - 1] = { 100e-6, 300e-6, 1e-3, 3e-3, 10e-3 };
	int i;

	for (i = 0; i < NDUR - 1; i++)
		if (s < lim[i])
			return i;
	return NDUR - 1;
}

static int bucket(int w)
{
	int b = 2, lim = 8;

	if (w <= 0)
		return 0;
	if (w < 4)
		return 1;
	while (b < NBUCKET - 1 && w >= lim) {
		b++;
		lim <<= 1;
	}
	return b;
}

static double clock_s(clockid_t clk)
{
	struct timespec ts;

	clock_gettime(clk, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

// CLOCK_BOOTTIME is what /proc/uptime counts, as guest.sh's TIME stamps do
static double uptime(void) { return clock_s(CLOCK_BOOTTIME); }
static double now(void) { return clock_s(CLOCK_MONOTONIC); }

static int read_inflight(int fd, int *r, int *w)
{
	char buf[64];
	ssize_t n = pread(fd, buf, sizeof(buf) - 1, 0);

	if (n <= 0)
		return -1;
	buf[n] = 0;
	return sscanf(buf, "%d %d", r, w) == 2 ? 0 : -1;
}

struct gate {
	const char *path, *start, *end;
	int fd;
	off_t off;
	char line[4096];
	size_t len;
	int open;	// the last START/END line was START
	double since;	// when it opened
	int opened;	// how many times
};

static void gate_line(struct gate *g, double t)
{
	g->line[g->len] = 0;
	if (strstr(g->line, g->start)) {
		if (!g->open) {
			g->open = 1;
			g->since = t;
			g->opened++;
			printf("@@KT WATCH_GATE open t=%.3f n=%d\n", uptime(), g->opened);
		}
	} else if (strstr(g->line, g->end)) {
		if (g->open) {
			g->open = 0;
			printf("@@KT WATCH_GATE close t=%.3f open_s=%.1f\n", uptime(),
			       t - g->since);
		}
	}
	g->len = 0;
}

// read what the log has gained since the last call, line by line
static void gate_poll(struct gate *g, double t)
{
	char buf[65536];
	ssize_t n, i;

	if (g->fd < 0 && (g->fd = open(g->path, O_RDONLY)) < 0)
		return;
	while ((n = pread(g->fd, buf, sizeof(buf), g->off)) > 0) {
		g->off += n;
		for (i = 0; i < n; i++) {
			if (buf[i] == '\n')
				gate_line(g, t);
			else if (g->len < sizeof(g->line) - 1)
				g->line[g->len++] = buf[i];
		}
	}
}

// /sys/block/<dev>/stat: writes completed and sectors written
static int read_stat(const char *path, unsigned long long *ios,
		     unsigned long long *sectors)
{
	unsigned long long v[7];
	FILE *f = fopen(path, "r");
	int n;

	if (!f)
		return -1;
	n = fscanf(f, "%llu %llu %llu %llu %llu %llu %llu", &v[0], &v[1],
		   &v[2], &v[3], &v[4], &v[5], &v[6]);
	fclose(f);
	if (n != 7)
		return -1;
	*ios = v[4];
	*sectors = v[6];
	return 0;
}

// /proc/meminfo, in kB
static long meminfo(const char *key)
{
	char line[256];
	size_t len = strlen(key);
	long v = -1;
	FILE *f = fopen("/proc/meminfo", "r");

	if (!f)
		return -1;
	while (fgets(line, sizeof(line), f))
		if (!strncmp(line, key, len) && line[len] == ':') {
			v = atol(line + len + 1);
			break;
		}
	fclose(f);
	return v;
}

static void print_hist(const char *name, const long *h)
{
	int i;

	printf(" %s=", name);
	for (i = 0; i < NBUCKET; i++)
		printf("%s%ld", i ? "," : "", h[i]);
}

// a row of the burst table, named for the lowest count of its bucket
static void print_row(int b, const long *d)
{
	int i;

	printf(" w%d=", b == 0 ? 0 : b == 1 ? 1 : 2 << (b - 1));
	for (i = 0; i < NDUR; i++)
		printf("%s%ld", i ? "," : "", d[i]);
}

static void usage(const char *prog)
{
	fprintf(stderr,
		"usage: %s [-i inflight] [-k writes] [-d hold_us] [-a arm_ms]"
		" [-l log -s start -e end] [-g gate_ms] [-m shm] [-p poll_us]"
		" [-r report_ms] [-t timeout_ms] [-b burst_w] [-F rt_prio]\n", prog);
	exit(2);
}

int main(int argc, char **argv)
{
	const char *inflight = "/sys/block/nvme0n1/inflight";
	int kill_w = 0, fd, opt, r, w, maxw = 0, gate_ok, armed;
	const char *shm_path = NULL;
	volatile unsigned int *shm = NULL;
	long arm_ms = 0, gate_ms = 0, poll_us = 20, report_ms = 10000;
	long timeout_ms = 0, samples = 0, hist[NBUCKET] = { 0 };
	long ghist[NBUCKET] = { 0 }, bursts[NBUCKET][NDUR] = { { 0 } };
	int burst_w = 8, in_burst = 0, b_max = 0, b, above = 0, rt_prio = 0;
	double b_start = 0, hold = 0, above_since = 0;
	struct gate g = { .fd = -1 };
	struct timespec nap;
	double t0, t, next_report, next_gate;
	char statpath[256];
	unsigned long long ios0 = 0, sec0 = 0, ios, sec;
	unsigned int seq = 0;

	while ((opt = getopt(argc, argv, "i:k:a:l:s:e:g:p:r:t:m:b:d:F:")) != -1) {
		switch (opt) {
		case 'i': inflight = optarg; break;
		case 'k': kill_w = atoi(optarg); break;
		case 'a': arm_ms = atol(optarg); break;
		case 'l': g.path = optarg; break;
		case 's': g.start = optarg; break;
		case 'e': g.end = optarg; break;
		case 'g': gate_ms = atol(optarg); break;
		case 'p': poll_us = atol(optarg); break;
		case 'r': report_ms = atol(optarg); break;
		case 't': timeout_ms = atol(optarg); break;
		case 'm': shm_path = optarg; break;
		case 'b': burst_w = atoi(optarg) > 0 ? atoi(optarg) : 8; break;
		case 'd': hold = atol(optarg) / 1e6; break;
		case 'F': rt_prio = atoi(optarg); break;
		default: usage(argv[0]);
		}
	}
	if (g.path && (!g.start || !g.end))
		usage(argv[0]);
	setvbuf(stdout, NULL, _IOLBF, 0);
	// the default 50 us of timer slack would triple the poll interval
	prctl(PR_SET_TIMERSLACK, 1UL);
	if (rt_prio > 0) {
		struct sched_param sp = { .sched_priority = rt_prio };

		if (sched_setscheduler(0, SCHED_FIFO, &sp) != 0)
			printf("@@KT WATCH_ERR SCHED_FIFO %d: %s\n", rt_prio,
			       strerror(errno));
	}

	if ((fd = open(inflight, O_RDONLY)) < 0) {
		printf("@@KT WATCH_ERR open %s: %s\n", inflight, strerror(errno));
		return 2;
	}
	// the stat file next to it
	snprintf(statpath, sizeof(statpath), "%s", inflight);
	if (strrchr(statpath, '/'))
		strcpy(strrchr(statpath, '/') + 1, "stat");
	read_stat(statpath, &ios0, &sec0);
	if (shm_path) {
		int sfd = open(shm_path, O_RDWR | O_SYNC);
		void *m = sfd < 0 ? MAP_FAILED :
			mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, sfd, 0);

		if (m == MAP_FAILED) {
			printf("@@KT WATCH_ERR map %s: %s\n", shm_path, strerror(errno));
			return 2;
		}
		shm = m;
		if (shm[0])
			printf("@@KT WATCH_ERR %s: request already set\n", shm_path);
	}
	printf("@@KT WATCH_START t=%.3f kill_w=%d hold_us=%.0f arm_ms=%ld gate=%d"
	       " gate_ms=%ld poll_us=%ld rt_prio=%d\n", uptime(), kill_w,
	       hold * 1e6, arm_ms, g.path != NULL, gate_ms, poll_us, rt_prio);

	nap.tv_sec = poll_us / 1000000;
	nap.tv_nsec = (poll_us % 1000000) * 1000;
	t0 = now();
	next_report = t0 + report_ms / 1e3;
	next_gate = t0;
	for (;;) {
		t = now();
		if (read_inflight(fd, &r, &w)) {
			printf("@@KT WATCH_ERR read %s\n", inflight);
			return 2;
		}
		if (g.path && t >= next_gate) {
			gate_poll(&g, t);
			next_gate = t + 0.01;
		}
		samples++;
		hist[bucket(w)]++;
		if (g.open)
			ghist[bucket(w)]++;
		if (w > maxw)
			maxw = w;
		if (w >= burst_w) {
			if (!in_burst) {
				in_burst = 1;
				b_start = t;
				b_max = 0;
			}
			if (w > b_max)
				b_max = w;
		} else if (in_burst) {
			in_burst = 0;
			bursts[bucket(b_max)][dur_bucket(t - b_start)]++;
		}
		if (shm) {
			shm[2] = w;
			shm[3] = r;
			shm[4] = g.open;
			shm[5] = in_burst ? b_max : 0;
			shm[6] = in_burst ? (unsigned int)((t - b_start) * 1e6) : 0;
			shm[7] = ++seq;
		}

		gate_ok = !g.path || (g.open && t - g.since >= gate_ms / 1e3);
		armed = t - t0 >= arm_ms / 1e3 && gate_ok;
		// how long the writes in flight have stayed at KILL or more
		if (kill_w > 0 && w >= kill_w) {
			if (!above) {
				above = 1;
				above_since = t;
			}
		} else {
			above = 0;
		}
		if (armed && above && t - above_since >= hold) {
			char msg[64] = { 0 };

			snprintf(msg, sizeof(msg), "K w=%d r=%d\n", w, r);
			if (shm) {
				memcpy((char *)shm + 64, msg, sizeof(msg));
				__sync_synchronize();
				shm[0] = 1;
				__sync_synchronize();
			} else {
				fputs(msg, stdout);
			}
			// the host is killing the VM; this line rarely gets out
			printf("@@KT WATCH_KILL w=%d r=%d t=%.6f since_start_ms=%.1f"
			       " since_gate_ms=%.1f held_us=%.0f gates=%d\n", w, r,
			       uptime(), (t - t0) * 1e3,
			       g.path ? (t - g.since) * 1e3 : -1.0,
			       (t - above_since) * 1e6, g.opened);
			return 0;
		}
		if (t >= next_report) {
			if (read_stat(statpath, &ios, &sec))
				ios = ios0, sec = sec0;
			printf("@@KT WATCH t=%.3f armed=%d gate=%d samples=%ld max_w=%d"
			       " wr_ios=%llu wr_mib=%.1f dirty_kb=%ld writeback_kb=%ld",
			       uptime(), armed, g.open, samples, maxw, ios - ios0,
			       (sec - sec0) / 2048.0, meminfo("Dirty"),
			       meminfo("Writeback"));
			ios0 = ios;
			sec0 = sec;
			print_hist("hist", hist);
			if (g.path)
				print_hist("gate_hist", ghist);
			printf("\n");
			// by the most writes in flight (8-15, 16-31, ...), each by
			// duration
			printf("@@KT WATCH_BURSTS t=%.3f", uptime());
			for (b = bucket(burst_w); b < NBUCKET; b++)
				print_row(b, bursts[b]);
			printf("\n");
			samples = maxw = 0;
			memset(hist, 0, sizeof(hist));
			memset(ghist, 0, sizeof(ghist));
			memset(bursts, 0, sizeof(bursts));
			next_report += report_ms / 1e3;
		}
		if (timeout_ms && t - t0 >= timeout_ms / 1e3) {
			printf("@@KT WATCH_TIMEOUT t=%.3f gates=%d\n", uptime(), g.opened);
			return 1;
		}
		if (poll_us > 0)
			clock_nanosleep(CLOCK_MONOTONIC, 0, &nap, NULL);
	}
}
