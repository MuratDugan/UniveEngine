/* files: file I/O throughput. Under Wine it runs on the bottle's C: drive; natively on a Mac folder.
 *
 *   files [dir] [MiB]     dir defaults to C:\bench\io (Windows) or ./io (macOS); MiB defaults to 256
 */
#include "common.h"

#ifdef _WIN32
typedef HANDLE fh;
#define BAD_FH INVALID_HANDLE_VALUE
static fh f_create(const char *p) { return CreateFileA(p, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL); }
static fh f_open(const char *p) { return CreateFileA(p, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL); }
static long f_write(fh f, const void *b, long n) { DWORD w = 0; return WriteFile(f, b, (DWORD)n, &w, NULL) ? (long)w : -1; }
static long f_read(fh f, void *b, long n) { DWORD r = 0; return ReadFile(f, b, (DWORD)n, &r, NULL) ? (long)r : -1; }
static void f_sync(fh f) { FlushFileBuffers(f); }
static void f_close(fh f) { CloseHandle(f); }
static void f_unlink(const char *p) { DeleteFileA(p); }
static void mkdir_p(const char *p) { CreateDirectoryA(p, NULL); }
static void rmdir_p(const char *p) { RemoveDirectoryA(p); }
static int list_dir(const char *dir) {
    char pat[1100];
    snprintf(pat, sizeof pat, "%s\\*", dir);
    WIN32_FIND_DATAA fd;
    HANDLE h = FindFirstFileA(pat, &fd);
    if (h == INVALID_HANDLE_VALUE) return 0;
    int n = 0;
    do n++; while (FindNextFileA(h, &fd));
    FindClose(h);
    return n;
}
#define SEP "\\"
#define DEFAULT_DIR "C:\\bench\\io"
#else
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/stat.h>
typedef int fh;
#define BAD_FH (-1)
static fh f_create(const char *p) { return open(p, O_WRONLY | O_CREAT | O_TRUNC, 0644); }
static fh f_open(const char *p) { return open(p, O_RDONLY); }
static long f_write(fh f, const void *b, long n) { return (long)write(f, b, (size_t)n); }
static long f_read(fh f, void *b, long n) { return (long)read(f, b, (size_t)n); }
static void f_sync(fh f) { fsync(f); }
static void f_close(fh f) { close(f); }
static void f_unlink(const char *p) { unlink(p); }
static void mkdir_p(const char *p) { mkdir(p, 0755); }
static void rmdir_p(const char *p) { rmdir(p); }
static int list_dir(const char *dir) {
    DIR *d = opendir(dir);
    if (!d) return 0;
    int n = 0;
    while (readdir(d)) n++;
    closedir(d);
    return n;
}
#define SEP "/"
#define DEFAULT_DIR "io"
#endif

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *dir = argc > 1 ? argv[1] : DEFAULT_DIR;
    long mib = argc > 2 ? atol(argv[2]) : 256;
    if (mib < 1) mib = 256;
    mkdir_p(dir);
    char big[1024], small_dir[1024], path[1200];
    snprintf(big, sizeof big, "%s" SEP "big.bin", dir);
    snprintf(small_dir, sizeof small_dir, "%s" SEP "small", dir);
    printf("files: %s, %ld MiB sequential, 2000 small files\n", dir, mib);

    const long chunk = 1 << 20;
    char *buf = malloc(chunk);
    for (long i = 0; i < chunk; i++) buf[i] = (char)(i * 31);

    /* 1. sequential write, 1 MiB chunks, including the final flush to disk */
    double t = now_ms();
    fh f = f_create(big);
    if (f == BAD_FH) { printf("ERROR can't create %s\n", big); return 2; }
    for (long i = 0; i < mib; i++) if (f_write(f, buf, chunk) != chunk) { printf("ERROR write failed\n"); return 2; }
    f_sync(f);
    f_close(f);
    result("seq_write", mib / ((now_ms() - t) / 1000.0), "MiB/s");

    /* 2. sequential read (mostly from the page cache) */
    t = now_ms();
    f = f_open(big);
    long total = 0, got;
    while ((got = f_read(f, buf, chunk)) > 0) total += got;
    f_close(f);
    result("seq_read", (total >> 20) / ((now_ms() - t) / 1000.0), "MiB/s");
    f_unlink(big);

    /* 3. small files: create+write 4 KiB, list the folder, read each, delete each */
    enum { N = 2000, SMALL = 4096 };
    mkdir_p(small_dir);
    t = now_ms();
    for (int i = 0; i < N; i++) {
        snprintf(path, sizeof path, "%s" SEP "f%05d.dat", small_dir, i);
        fh s = f_create(path);
        f_write(s, buf, SMALL);
        f_close(s);
    }
    result("small_create", (now_ms() - t) * 1000.0 / N, "us/file");

    t = now_ms();
    int listed = 0;
    for (int r = 0; r < 20; r++) listed += list_dir(small_dir);
    result("dir_list", (now_ms() - t) / 20, "ms/listing");
    if (listed / 20 < N) printf("ERROR listed %d of %d files\n", listed / 20, N);

    t = now_ms();
    for (int i = 0; i < N; i++) {
        snprintf(path, sizeof path, "%s" SEP "f%05d.dat", small_dir, i);
        fh s = f_open(path);
        f_read(s, buf, SMALL);
        f_close(s);
    }
    result("small_read", (now_ms() - t) * 1000.0 / N, "us/file");

    t = now_ms();
    for (int i = 0; i < N; i++) {
        snprintf(path, sizeof path, "%s" SEP "f%05d.dat", small_dir, i);
        f_unlink(path);
    }
    result("small_delete", (now_ms() - t) * 1000.0 / N, "us/file");
    rmdir_p(small_dir);
    rmdir_p(dir);
    free(buf);
    printf("files: done\n");
    return 0;
}
