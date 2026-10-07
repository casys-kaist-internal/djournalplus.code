// SPDX-License-Identifier: GPL-2.0
//
// The verifier of the SOSP-round QEMU kill experiment, ported from
// taujournal-test.code tests/src/fs.c (repo at 1c65ec9, file as of 65aba46).
// Kept as it was -- same data pattern, same verdict, same output -- so results
// stay comparable with that round.  Only the '.direct=direct' initializer typo
// is fixed; it worked by accident, as a positional initializer.  The rand
// workload bug was in the harness (run.exp never passed -R), not here.
// mt_fsync_stress_simple.c
// Build:   gcc -O2 -pthread -Wall -Wextra -o mt_fsync_stress mt_fsync_stress_simple.c
// Example: ./mt_fsync_stress -t 4 -s 256M -b 1M -F 1 -V -p /tmp/mtfsync

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <assert.h>

typedef struct {
    int          tid;
    const char*  prefix;
    size_t       total_bytes;
    size_t       chunk_size;
    size_t       total_chunks;
    int          fsync_every;
    bool         use_fdatasync;
    bool         verify;
    bool         zero_fill;
    bool         truncate;
    bool         rand_write;
    bool         tau_untorn;
    bool         direct;
    int          ret;
    double       seconds;
    size_t       num_chunks;
    size_t       verified;
    bool         torn;
} worker_t;

#define O_TAU_UNTORN 040000000

/* ---------- helpers ---------- */

static void die(const char* msg) {
    perror(msg);
    exit(EXIT_FAILURE);
}

static size_t parse_size(const char* s) {
    char* end;
    unsigned long long v = strtoull(s, &end, 10);
    if (*end) {
        switch (*end) {
            case 'K': case 'k': v *= 1024ULL; break;
            case 'M': case 'm': v *= 1024ULL*1024ULL; break;
            case 'G': case 'g': v *= 1024ULL*1024ULL*1024ULL; break;
            default: fprintf(stderr, "Bad size: %s\n", s); exit(1);
        }
    }
    return v;
}

static double now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static inline uint8_t pattern(size_t i, int tid) {
    // return 0xff;
    return (uint8_t)(((i * 1315423911u + ((size_t) tid) * 2654435761u) % 0xFBu) + 1u);
}

void shuffle(size_t *array, unsigned int *seedp, int n) {
    for (int i = n - 1; i > 0; i--) {
        int j = rand_r(seedp) % (i + 1); // random index 0..i
        // swap array[i] and array[j]
        size_t temp = array[i];
        array[i] = array[j];
        array[j] = temp;
    }
}

/* ---------- verification ---------- */

static void verify_file(worker_t* a) {
    char path[256];

    snprintf(path, sizeof(path), "%s.%d", a->prefix, a->tid);

    int fd = open(path, O_RDONLY);
    if (fd < 0) { a->ret = -1; return; }

    uint8_t* buf = malloc(a->chunk_size * sizeof(uint8_t));
    if (!buf) { close(fd); a->ret = -1; return; }

    double t0 = now_sec();

    for (size_t i = 0; i < a->total_chunks; i++) {
        size_t offset = i * a->chunk_size;

        ssize_t n = pread(fd, buf, a->chunk_size, offset);
        if (n != (ssize_t)a->chunk_size) {
            if (n != 0) {
                fprintf(stderr, "  thread %d: verify_file: short read (expected %zu bytes, read %zd bytes) (%zu/%zu total)\n", 
                        a->tid, a->chunk_size, n, offset + n, a->total_bytes);
                a->torn = true;
            }
            a->ret = -1;
            break;
        }

        uint8_t exp_init = a->zero_fill ? 0 : pattern(offset + 0, a->tid);
        bool diff_init = (buf[0] != exp_init)? true : false;
        bool diff = false;

        for (ssize_t j = 0; j < n; j++) {
            uint8_t exp = a->zero_fill ? 0 : pattern(offset + j, a->tid);
            if ((buf[j] != exp) != diff_init) {
                if (!a->torn && j != 0)
                    fprintf(stderr, "  thread %d: verify_file: inconsistent data (expected %u, got %u at offset %zd) (%zu/%zu total)\n", 
                            a->tid, (unsigned)exp, (unsigned)buf[j], j, offset + j, a->total_bytes);
                if (j != 0) a->torn = true;
                a->ret = -1;
                diff = true; 
                break;
            }
        }
        if (!diff_init && !diff) a->verified++;
        a->num_chunks++;
    }

    free(buf);
    close(fd);
    a->seconds = now_sec() - t0;
    return;
}

/* ---------- worker ---------- */

static void* worker(void* arg) {
    worker_t* a = arg;
    char path[256];

    snprintf(path, sizeof(path), "%s.%d", a->prefix, a->tid);

    int flags = O_RDWR | O_CREAT | (a->truncate ? O_TRUNC : 0) | (a->tau_untorn ? O_TAU_UNTORN : 0) | (a->direct ? O_DIRECT : 0);
    int fd = open(path, flags, 0644);
    if (fd < 0) { a->ret = -1; return NULL; }

    uint8_t* buf = malloc(a->chunk_size * sizeof(uint8_t));
    if (!buf) { close(fd); a->ret = -1; return NULL; }

    size_t* order = calloc(a->total_chunks, sizeof(size_t));
    if (!order) { free(buf); close(fd); a->ret = -1; return NULL; }

    for (size_t i = 0; i < a->total_chunks; i++) {
        order[i] = i;
    }
    if (a->rand_write) {
        unsigned int seed = time(NULL) + a->tid;
        shuffle(order, &seed, a->total_chunks);
    }

    double t0 = now_sec();

    for (size_t i = 0; i < a->total_chunks; i++) {
        size_t offset = order[i] * a->chunk_size;
        for (size_t j = 0; j < a->chunk_size; j++)
            buf[j] = a->zero_fill ? 0 : pattern(offset + j, a->tid);
        ssize_t w = pwrite(fd, buf, a->chunk_size, offset);
        if (w != (ssize_t)a->chunk_size) {
            fprintf(stderr, "  thread %d: write error (expected %zu bytes, wrote %zd bytes) at block %zu/%zu\n", 
                    a->tid, a->chunk_size, w, i, a->total_chunks);
            a->ret = -1; break;
        }

        a->num_chunks++;

        if (a->fsync_every > 0 && a->num_chunks % a->fsync_every == 0) {
            if ((a->use_fdatasync ? fdatasync(fd) : fsync(fd)) != 0) { a->ret = -1; break; }
        }
    }

    if (a->ret == 0) {
        if ((a->use_fdatasync ? fdatasync(fd) : fsync(fd)) != 0) a->ret = -1;
    }

    free(order);
    free(buf);
    close(fd);
    a->seconds = now_sec() - t0;
    return NULL;
}

/* ---------- CLI & main ---------- */

static void usage(const char* prog) {
    fprintf(stderr,
        "Usage: %s [-t threads] [-s size] [-b chunk] [-F N] [-p prefix] [--fdatasync] [-V] [-Z] [-C] [-R]\n",
        prog);
}

int main(int argc, char** argv) {
    int threads = 4;
    size_t size = 1024ULL*1024ULL*256ULL; // 256 MB default
    size_t chunk = 1024ULL*1024ULL;         // 1 MB
    int fsync_every = 0;
    const char* prefix = "./mtfsync.out";
    bool fdatasync_mode = false, verify = false, zero = false, trunc = false, rand = false, tau_untorn = false, direct = false;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-t")) threads = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-s")) size = parse_size(argv[++i]);
        else if (!strcmp(argv[i], "-b")) chunk = parse_size(argv[++i]);
        else if (!strcmp(argv[i], "-F")) fsync_every = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-p")) prefix = argv[++i];
        else if (!strcmp(argv[i], "--fdatasync")) fdatasync_mode = true;
        else if (!strcmp(argv[i], "-V")) verify = true;
        else if (!strcmp(argv[i], "-Z")) zero = true;
        else if (!strcmp(argv[i], "-C")) trunc = true;
        else if (!strcmp(argv[i], "-R")) rand = true;
        else if (!strcmp(argv[i], "-T")) tau_untorn = true;
        else if (!strcmp(argv[i], "-D")) direct = true;

        else { usage(argv[0]); return 1; }
    }

    size_t num_total_chunks = size / chunk;

    printf("mt_fsync_stress: threads=%d, size=%zu, chunk=%zu, num_total_chunks=%zu, fsync_every=%d, prefix=%s, fdatasync=%s, verify=%s, zero_fill=%s, truncate=%s, rand_write=%s, tau_untorn=%s, direct=%s\n",
           threads, size, chunk, num_total_chunks, fsync_every, prefix,
           fdatasync_mode ? "YES" : "NO",
           verify ? "YES" : "NO",
           zero ? "YES" : "NO",
           trunc ? "YES" : "NO",
           rand ? "YES" : "NO",
           tau_untorn ? "YES" : "NO",
           direct ? "YES" : "NO");

    pthread_t* th = calloc(threads, sizeof(*th));
    worker_t* args = calloc(threads, sizeof(*args));
    if (!th || !args) die("calloc");

    double t0 = now_sec();
    for (int i = 0; i < threads; i++) {
        args[i] = (worker_t){ .tid=i, .prefix=prefix, .total_bytes=size,
                              .chunk_size=chunk, .total_chunks=num_total_chunks, .fsync_every=fsync_every,
                              .use_fdatasync=fdatasync_mode, .verify=verify,
                              .zero_fill=zero, .truncate=trunc, .rand_write=rand, .tau_untorn=tau_untorn, .direct=direct,};
        if (verify) 
            verify_file(&args[i]);
        else
            pthread_create(&th[i], NULL, worker, &args[i]);
    }

    int exit_code = 0, torn = 0;
    for (int i = 0; i < threads; i++) {
        if (!verify) pthread_join(th[i], NULL);
        if (args[i].ret != 0) exit_code = 1;
        if (args[i].torn) torn++;
    }

    double elapsed = now_sec() - t0;
    printf("\nResults:\n");
    for (int i = 0; i < threads; i++) {
        printf("  thread %d: num_chunks=%lu, time=%.3f s, %s",
               i, args[i].num_chunks, args[i].seconds,
               args[i].ret ? "ERROR" : "OK");
        if (verify) printf(", verified=%lu, torn_write=%s", args[i].verified, args[i].torn ? "YES" : "NO");
        printf("\n");
    }
    if (torn) printf("*** %d/%d torn write(s) detected ***\n", torn, threads);

    double mb = (double)threads * size / (1024.0*1024.0);
    printf("Overall: %.3f s, %.2f MB/s\n", elapsed, mb/elapsed);

    free(th); free(args);
    return exit_code;
}
