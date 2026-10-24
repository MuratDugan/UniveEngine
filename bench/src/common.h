/* Shared helpers for the bench programs: a monotonic clock in milliseconds, frame-time statistics and
 * (on Windows) a plain window for the graphics tests. Every result is printed as one line:
 *     RESULT <name> <value> <unit>
 * which bench/run.sh collects. Anything else on stdout is informational. */
#ifndef BENCH_COMMON_H
#define BENCH_COMMON_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static double now_ms(void) {
    static LARGE_INTEGER freq;
    LARGE_INTEGER c;
    if (!freq.QuadPart) QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart * 1000.0 / (double)freq.QuadPart;
}
#else
#include <time.h>
static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}
#endif

static void result(const char *name, double value, const char *unit) {
    printf("RESULT %s %.3f %s\n", name, value, unit);
    fflush(stdout);
}

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

/* Percentile (0..100) of an already sorted array. */
static double pct(const double *sorted, int n, double p) {
    if (n <= 0) return 0;
    int i = (int)(p / 100.0 * (n - 1) + 0.5);
    if (i < 0) i = 0;
    if (i >= n) i = n - 1;
    return sorted[i];
}

/* Prints fps / frame-time results for `n` frame times (ms) measured over `span_ms`, names prefixed by `phase`. */
static void frame_report(const char *phase, double *ft, int n, double span_ms) {
    char k[64];
    if (n <= 0) { printf("ERROR %s: no frames measured\n", phase); return; }
    qsort(ft, n, sizeof(double), cmp_double);
#define R(name, v, unit) (snprintf(k, sizeof k, "%s_%s", phase, name), result(k, v, unit))
    R("fps", n * 1000.0 / span_ms, "fps");
    R("frame_avg", span_ms / n, "ms");
    R("frame_p50", pct(ft, n, 50), "ms");
    R("frame_p95", pct(ft, n, 95), "ms");
    R("frame_p99", pct(ft, n, 99), "ms");
    R("frame_max", ft[n - 1], "ms");
#undef R
}

/* Frame-timing loop shared by the graphics tests. `frame(present)` renders one frame and returns 0 on failure.
 * Phase "present": Present every frame (what a game sees, includes any display-rate cap).
 * Phase "offscreen": no Present; `frame` keeps at most 3 frames in flight with event queries, so this is the
 * CPU+GPU throughput without the presentation path. Each phase: 1 s warm-up, then `seconds` measured. */
static int frame_phase(const char *phase, int present, double seconds, int (*frame)(int present), int (*pump)(void)) {
    const double warmup = 1000;
    int cap = (int)((seconds + 2) * 20000), n = 0;
    double *ft = malloc(sizeof(double) * cap);
    double t0 = now_ms(), last = t0, from = 0;
    for (;;) {
        if (pump && !pump()) break;
        if (!frame(present)) { free(ft); return 0; }
        double t = now_ms(), el = t - t0;
        if (el >= warmup) {
            if (n == 0) from = last;
            if (n < cap) ft[n++] = t - last;
        }
        last = t;
        if (el >= warmup + seconds * 1000) break;
    }
    frame_report(phase, ft, n, last - from);
    free(ft);
    return 1;
}

#ifdef _WIN32
static LRESULT CALLBACK bench_wndproc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_CLOSE) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(h, m, w, l);
}

/* A visible, non-resizable window with a client area of w x h. */
static HWND bench_window(const char *title, int w, int h) {
    WNDCLASSA wc = {0};
    wc.lpfnWndProc = bench_wndproc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.lpszClassName = "UniveBench";
    RegisterClassA(&wc);
    DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
    RECT r = {0, 0, w, h};
    AdjustWindowRect(&r, style, FALSE);
    HWND hwnd = CreateWindowA("UniveBench", title, style, 40, 40, r.right - r.left, r.bottom - r.top,
                              NULL, NULL, wc.hInstance, NULL);
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);
    return hwnd;
}

/* Returns 0 when the window was closed. */
static int bench_pump(void) {
    MSG msg;
    while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) {
        if (msg.message == WM_QUIT) return 0;
        TranslateMessage(&msg);
        DispatchMessageA(&msg);
    }
    return 1;
}

static void wide_to_utf8(const WCHAR *in, char *out, int size) {
    if (!WideCharToMultiByte(CP_UTF8, 0, in, -1, out, size, NULL, NULL)) out[0] = 0;
}
#endif

#endif
