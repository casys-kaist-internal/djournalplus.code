/*
 * LD_PRELOAD wrapper that opens files with O_TAU_UNTORN for programs that
 * cannot pass that flag themselves (fio).
 *
 * An open of a regular file under $TAU_PREFIX for writing gets O_TAU_UNTORN
 * (040000000) ORed into its flags, unless it carries O_DIRECT (tau rejects
 * that with EINVAL), O_DIRECTORY or O_PATH. Wrapped: open, open64, openat,
 * openat64, creat, creat64 and the fortified __open_2, __open64_2,
 * __openat_2, __openat64_2. Without TAU_PREFIX nothing is changed.
 *
 * TAU_PRELOAD_DEBUG=1 prints every flagged open; TAU_PRELOAD_DEBUG set to
 * anything prints the number of flagged opens at exit (both on stderr).
 *
 *   gcc -O2 -Wall -shared -fPIC -o tau_preload.so tau_preload.c -ldl
 *   LD_PRELOAD=./tau_preload.so TAU_PREFIX=/mnt/temp fio job.fio
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef O_TAU_UNTORN
#define O_TAU_UNTORN 040000000
#endif

static const char *prefix;
static size_t prefix_len;
static int debug;		/* 0 off, 1 summary at exit, 2 every open */
static unsigned long flagged, seen;

static void __attribute__((constructor)) tp_init(void)
{
	const char *d = getenv("TAU_PRELOAD_DEBUG");

	prefix = getenv("TAU_PREFIX");
	if (prefix && *prefix) {
		prefix_len = strlen(prefix);
		while (prefix_len > 1 && prefix[prefix_len - 1] == '/')
			prefix_len--;
	} else {
		prefix = NULL;
	}
	if (d)
		debug = strcmp(d, "1") ? 1 : 2;
}

static void __attribute__((destructor)) tp_fini(void)
{
	if (debug && prefix)
		fprintf(stderr, "tau_preload: %lu of %lu write opens under %.*s flagged O_TAU_UNTORN\n",
			__atomic_load_n(&flagged, __ATOMIC_RELAXED),
			__atomic_load_n(&seen, __ATOMIC_RELAXED), (int)prefix_len, prefix);
}

/* absolute form of (dirfd, path) in buf, or NULL */
static const char *absolute(int dirfd, const char *path, char *buf, size_t n)
{
	char base[PATH_MAX];

	if (path[0] == '/')
		return path;
	if (dirfd == AT_FDCWD) {
		if (!getcwd(base, sizeof(base)))
			return NULL;
	} else {
		char link[64];
		ssize_t len;

		snprintf(link, sizeof(link), "/proc/self/fd/%d", dirfd);
		len = readlink(link, base, sizeof(base) - 1);
		if (len < 0)
			return NULL;
		base[len] = '\0';
	}
	if ((size_t)snprintf(buf, n, "%s/%s", base, path) >= n)
		return NULL;
	return buf;
}

static int tau_flags(int dirfd, const char *path, int flags)
{
	char buf[2 * PATH_MAX];
	const char *abs;
	struct stat st;

	if (!prefix || !path || (flags & O_ACCMODE) == O_RDONLY ||
	    (flags & (O_DIRECT | O_DIRECTORY | O_PATH | O_TAU_UNTORN)))
		return flags;
	abs = absolute(dirfd, path, buf, sizeof(buf));
	if (!abs || strncmp(abs, prefix, prefix_len) || abs[prefix_len] != '/')
		return flags;
	__atomic_fetch_add(&seen, 1, __ATOMIC_RELAXED);
	if (stat(abs, &st) == 0 ? !S_ISREG(st.st_mode) : !(flags & O_CREAT))
		return flags;
	__atomic_fetch_add(&flagged, 1, __ATOMIC_RELAXED);
	if (debug == 2)
		fprintf(stderr, "tau_preload: O_TAU_UNTORN on %s\n", abs);
	return flags | O_TAU_UNTORN;
}

static void *real(const char *name)
{
	void *f = dlsym(RTLD_NEXT, name);

	if (!f) {
		fprintf(stderr, "tau_preload: no %s in libc\n", name);
		abort();
	}
	return f;
}

#define MODE_ARG(flags, mode)                                   \
	do {                                                    \
		if ((flags) & (O_CREAT | O_TMPFILE)) {          \
			va_list ap;                             \
			va_start(ap, flags);                    \
			mode = va_arg(ap, mode_t);              \
			va_end(ap);                             \
		}                                               \
	} while (0)

int open(const char *path, int flags, ...)
{
	static int (*f)(const char *, int, ...);
	mode_t mode = 0;

	MODE_ARG(flags, mode);
	if (!f)
		f = real("open");
	return f(path, tau_flags(AT_FDCWD, path, flags), mode);
}

int open64(const char *path, int flags, ...)
{
	static int (*f)(const char *, int, ...);
	mode_t mode = 0;

	MODE_ARG(flags, mode);
	if (!f)
		f = real("open64");
	return f(path, tau_flags(AT_FDCWD, path, flags), mode);
}

int openat(int dirfd, const char *path, int flags, ...)
{
	static int (*f)(int, const char *, int, ...);
	mode_t mode = 0;

	MODE_ARG(flags, mode);
	if (!f)
		f = real("openat");
	return f(dirfd, path, tau_flags(dirfd, path, flags), mode);
}

int openat64(int dirfd, const char *path, int flags, ...)
{
	static int (*f)(int, const char *, int, ...);
	mode_t mode = 0;

	MODE_ARG(flags, mode);
	if (!f)
		f = real("openat64");
	return f(dirfd, path, tau_flags(dirfd, path, flags), mode);
}

int creat(const char *path, mode_t mode)
{
	return open(path, O_CREAT | O_WRONLY | O_TRUNC, mode);
}

int creat64(const char *path, mode_t mode)
{
	return open64(path, O_CREAT | O_WRONLY | O_TRUNC, mode);
}

int __open_2(const char *path, int flags)
{
	static int (*f)(const char *, int);

	if (!f)
		f = real("__open_2");
	return f(path, tau_flags(AT_FDCWD, path, flags));
}

int __open64_2(const char *path, int flags)
{
	static int (*f)(const char *, int);

	if (!f)
		f = real("__open64_2");
	return f(path, tau_flags(AT_FDCWD, path, flags));
}

int __openat_2(int dirfd, const char *path, int flags)
{
	static int (*f)(int, const char *, int);

	if (!f)
		f = real("__openat_2");
	return f(dirfd, path, tau_flags(dirfd, path, flags));
}

int __openat64_2(int dirfd, const char *path, int flags)
{
	static int (*f)(int, const char *, int);

	if (!f)
		f = real("__openat64_2");
	return f(dirfd, path, tau_flags(dirfd, path, flags));
}
