/* cpu: a fixed CPU workload. Builds for Windows (mingw, run under Wine) and natively for macOS, so the same
 * code can be compared: native arm64, native x86_64 under Rosetta, and x86_64 Windows under Wine + Rosetta.
 *
 *   cpu [scale]     scale multiplies every workload (default 1)
 */
#include "common.h"
#include <stdint.h>
#include <math.h>

#ifdef _WIN32
typedef HANDLE thread_t;
typedef DWORD (WINAPI *thread_fn)(void *);
#define THREAD_FN(name) static DWORD WINAPI name(void *arg)
static thread_t thread_start(thread_fn fn, void *arg) { return CreateThread(NULL, 0, fn, arg, 0, NULL); }
static void thread_join(thread_t t) { WaitForSingleObject(t, INFINITE); CloseHandle(t); }
static int cpu_count(void) { SYSTEM_INFO si; GetSystemInfo(&si); return (int)si.dwNumberOfProcessors; }
#else
#include <pthread.h>
#include <unistd.h>
typedef pthread_t thread_t;
typedef void *(*thread_fn)(void *);
#define THREAD_FN(name) static void *name(void *arg)
static thread_t thread_start(thread_fn fn, void *arg) { pthread_t t; pthread_create(&t, NULL, fn, arg); return t; }
static void thread_join(thread_t t) { pthread_join(t, NULL); }
static int cpu_count(void) { return (int)sysconf(_SC_NPROCESSORS_ONLN); }
#endif

static volatile uint64_t sink;

/* Integer: xorshift + multiply/rotate mixing. Serial dependency chain, no memory traffic. */
static uint64_t int_work(uint64_t iters, uint64_t seed) {
    uint64_t x = seed | 1, acc = 0;
    for (uint64_t i = 0; i < iters; i++) {
        x ^= x << 13; x ^= x >> 7; x ^= x << 17;
        acc += (x * 0x9E3779B97F4A7C15ull) ^ (acc >> 29);
        acc = (acc << 5) | (acc >> 59);
    }
    return acc;
}

/* Float: double-precision Mandelbrot. */
static uint64_t float_work(int size, int maxit) {
    uint64_t total = 0;
    for (int py = 0; py < size; py++) {
        double ci = (py / (double)size) * 2.4 - 1.2;
        for (int px = 0; px < size; px++) {
            double cr = (px / (double)size) * 3.2 - 2.2, zr = 0, zi = 0;
            int it = 0;
            while (it < maxit && zr * zr + zi * zi < 4.0) {
                double t = zr * zr - zi * zi + cr;
                zi = 2 * zr * zi + ci;
                zr = t;
                it++;
            }
            total += it;
        }
    }
    return total;
}

THREAD_FN(empty_thread) { (void)arg; sink++; return 0; }

typedef struct { uint64_t iters, seed, out; } mt_job;
THREAD_FN(mt_thread) { mt_job *j = arg; j->out = int_work(j->iters, j->seed); return 0; }

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    double scale = argc > 1 ? atof(argv[1]) : 1.0;
    if (scale <= 0) scale = 1.0;
    int cores = cpu_count();
#ifdef _WIN32
    printf("cpu: windows build, %d logical CPUs, scale %.2f\n", cores, scale);
#else
#if defined(__aarch64__)
    printf("cpu: macOS arm64 build, %d logical CPUs, scale %.2f\n", cores, scale);
#else
    printf("cpu: macOS x86_64 build, %d logical CPUs, scale %.2f\n", cores, scale);
#endif
#endif
    double t;

    /* 1. integer */
    uint64_t iters = (uint64_t)(400e6 * scale);
    t = now_ms();
    sink = int_work(iters, 12345);
    result("int", now_ms() - t, "ms");

    /* 2. float */
    t = now_ms();
    sink = float_work((int)(1000 * sqrt(scale)), 1000);
    result("float", now_ms() - t, "ms");

    /* 3. memcpy bandwidth: 64 MiB buffers, copied back and forth */
    size_t bytes = 64u << 20;
    int reps = (int)(32 * scale);
    if (reps < 1) reps = 1;
    char *a = malloc(bytes), *b = malloc(bytes);
    memset(a, 1, bytes); memset(b, 2, bytes);
    t = now_ms();
    for (int i = 0; i < reps; i++) {
        if (i & 1) memcpy(a, b, bytes); else memcpy(b, a, bytes);
    }
    double ms = now_ms() - t;
    sink = (uint64_t)a[12345] + (uint64_t)b[54321];
    result("memcpy", (double)bytes * reps / (ms / 1000.0) / 1e9, "GB/s");
    free(a); free(b);

    /* 4. many small allocations: a live set of 4096 blocks, each op frees one and allocates 16..2063 bytes */
    enum { SLOTS = 4096 };
    void *slot[SLOTS] = {0};
    uint64_t r = 88172645463325252ull, ops = (uint64_t)(4e6 * scale);
    t = now_ms();
    for (uint64_t i = 0; i < ops; i++) {
        r ^= r << 13; r ^= r >> 7; r ^= r << 17;
        unsigned s = (unsigned)(r % SLOTS);
        free(slot[s]);
        size_t sz = 16 + (size_t)((r >> 20) % 2048);
        slot[s] = malloc(sz);
        ((char *)slot[s])[0] = (char)i;
    }
    result("alloc", now_ms() - t, "ms");
    for (int i = 0; i < SLOTS; i++) free(slot[i]);

    /* 5. thread spawn + join, one at a time */
    int nthreads = (int)(1000 * scale);
    if (nthreads < 1) nthreads = 1;
    t = now_ms();
    for (int i = 0; i < nthreads; i++) thread_join(thread_start(empty_thread, NULL));
    result("thread_spawn", (now_ms() - t) * 1000.0 / nthreads, "us/thread");

    /* 6. the integer workload split over every core */
    mt_job jobs[256];
    thread_t th[256];
    int n = cores > 256 ? 256 : cores;
    uint64_t per = (uint64_t)(400e6 * scale);   /* each thread does what test 1 did alone */
    t = now_ms();
    for (int i = 0; i < n; i++) { jobs[i].iters = per; jobs[i].seed = 1000 + i; th[i] = thread_start(mt_thread, &jobs[i]); }
    for (int i = 0; i < n; i++) { thread_join(th[i]); sink += jobs[i].out; }
    result("int_all_cores", now_ms() - t, "ms");

    /* 7. cost of reading the clock (QueryPerformanceCounter under Wine, clock_gettime natively) */
    int calls = (int)(5e6 * scale);
    double acc = 0;
    t = now_ms();
    for (int i = 0; i < calls; i++) acc += now_ms();
    result("clock_call", (now_ms() - t) * 1e6 / calls, "ns/call");
    sink += (uint64_t)acc;

    printf("cpu: done (checksum %llu)\n", (unsigned long long)sink);
    return 0;
}
