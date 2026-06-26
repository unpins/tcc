/* Linker-level sysroot VFS for the single-binary tcc -- ZIP + miniz.
 *
 * Each tcc backend's sysroot (libc headers + crt + libc.a + libtcc1.a) lives in
 * its own /zip/<target>/ subtree of one embedded ZIP (built with `zip -9`);
 * miniz handles the central-directory lookup and DEFLATE inflate. It is the same
 * format the vim/perl packages ship, so there is one VFS container in the
 * catalog, not a bespoke one.
 *
 * tcc reads every input -- source, header, archive, .def -- through open(); a
 * matched open() inflates the entry and hands tcc a real, seekable fd. The
 * mechanism differs only in how each OS produces that fd:
 *   - Linux  : memfd_create (anonymous kernel fd). open/stat/lstat/access are
 *              routed here by GNU `ld --wrap` (__wrap_* -> __real_*).
 *              Blob symbols: _binary_incblob_{start,end}.
 *   - macOS  : mkstemp + immediate unlink (no memfd). ld64 has no `--wrap`, so
 *              each backend object's open import is renamed to _unpinvfs_open
 *              with `llvm-objcopy --redefine-sym`; this TU is NOT renamed, so it
 *              defines unpinvfs_open and calls the genuine libc open.
 *              Blob symbols: incblob_{start,end}.
 *   - Windows: no memfd and no anonymous fd, so materialise each requested entry
 *              into a temp file once (cached by index) and delegate to the real
 *              open(). tcc makes no stat on Windows, so one __wrap_open (mingw
 *              `ld --wrap=open`) is the whole VFS. Blob symbols: incblob_{start,end}.
 *
 * The ZIP stores entries WITHOUT the "/zip/" prefix (e.g. "x86_64/include/stdio.h");
 * we strip it on lookup. `/zip` is a reserved virtual mount (the Cosmopolitan
 * zipos model): a miss is ENOENT, never the host FS. UNPIN_VFS_OFF=1 turns every
 * wrapper into a pure passthrough (unused by tcc itself; kept for parity).
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/stat.h>
#include "miniz.h"

#if defined(__APPLE__) || defined(_WIN32)
extern const unsigned char incblob_start[];
extern const unsigned char incblob_end[];
#  define BLOB_BEG incblob_start
#  define BLOB_END incblob_end
#else
extern const unsigned char _binary_incblob_start[];
extern const unsigned char _binary_incblob_end[];
#  define BLOB_BEG _binary_incblob_start
#  define BLOB_END _binary_incblob_end
#endif

#define VFS_ROOT "/zip/"
#define VFS_ROOT_LEN (sizeof(VFS_ROOT) - 1)

/* ---- shared miniz core ------------------------------------------------- */

static mz_zip_archive g_zip;
static int g_state;            /* 0=uninit, 1=ready, 2=failed */
static int g_disabled = -1;

static int vfs_off(void) {
    if (g_disabled < 0) g_disabled = (getenv("UNPIN_VFS_OFF") != NULL);
    return g_disabled;
}

static void vfs_init(void) {
    if (g_state) return;
    memset(&g_zip, 0, sizeof g_zip);
    size_t size = (size_t)(BLOB_END - BLOB_BEG);
    g_state = mz_zip_reader_init_mem(&g_zip, BLOB_BEG, size, 0) ? 1 : 2;
}

/* zip lookup by /zip-stripped, forward-slash key. Returns file index or -1. */
static int vfs_find(const char *key) {
    vfs_init();
    if (g_state != 1) return -1;
    return mz_zip_reader_locate_file(&g_zip, key, NULL, 0);
}

static uint64_t entry_size(int idx) {
    mz_zip_archive_file_stat st;
    if (!mz_zip_reader_file_stat(&g_zip, (mz_uint)idx, &st)) return 0;
    return (uint64_t)st.m_uncomp_size;
}

/* Lexically resolve "." and ".." in a '/'-separated relative key, in place.
 * tcc emits relative #includes literally: "#include \"../math.h\"" from
 * /zip/<t>/include/tcc/tcc_libm.h opens ".../tcc/../math.h", but the ZIP keys
 * are clean (".../include/math.h"), so the VFS must canonicalise. Needed on
 * EVERY OS branch here, not just Windows: the multi binary's win32 PE backend
 * is itself a Linux ELF, so its header opens go through the POSIX wrap. */
#define VFS_PATHMAX 4096
static void path_canon(char *s) {
    const char *segs[256];
    size_t lens[256];
    int sp = 0;
    const char *p = s;
    while (*p) {
        if (*p == '/') { p++; continue; }
        const char *seg = p;
        while (*p && *p != '/') p++;
        size_t len = (size_t)(p - seg);
        if (len == 1 && seg[0] == '.') continue;
        if (len == 2 && seg[0] == '.' && seg[1] == '.') { if (sp > 0) sp--; continue; }
        if (sp < 256) { segs[sp] = seg; lens[sp] = len; sp++; }
    }
    char buf[VFS_PATHMAX];
    size_t o = 0;
    for (int i = 0; i < sp && o + lens[i] + 1 < sizeof(buf); i++) {
        if (i) buf[o++] = '/';
        memcpy(buf + o, segs[i], lens[i]);
        o += lens[i];
    }
    buf[o] = '\0';
    memcpy(s, buf, o + 1);
}

/* ======================================================================= */
#if defined(_WIN32)
/* ----- Windows: materialise to a temp file, delegate to real open() ------ */
/* tcc reads every source/header/archive/.def through open(path,O_RDONLY|
 * O_BINARY) (msvcrt _open; libtcc.c:_tcc_open) and makes NO stat/lstat/access
 * calls, so a single __wrap_open is the whole VFS here. Output files (the .exe,
 * .def) go through fopen()/CreateFile and never carry the /zip prefix, so they
 * fall through untouched. mingw's `open` is a real symbol (not a macro), so
 * `ld --wrap=open` intercepts it cleanly. */
#include <io.h>
#include <windows.h>

extern int __real_open(const char *path, int oflag, ...);

static char **tmpcache;         /* materialised temp path per entry, or NULL */
static int cleanup_registered;
static void vfs_cleanup(void);

/* Normalise into a /zip-rooted forward-slash key (win path munging can emit
 * backslashes). Returns 1 and writes the stripped, canonicalised lookup key
 * into out (no leading "/zip/") if it is a /zip path, 0 otherwise. */
static int win_key(const char *p, char *out, size_t n) {
    if (vfs_off() || !p) return 0;
    char norm[MAX_PATH];
    size_t i = 0;
    for (; p[i] && i + 1 < sizeof(norm); i++)
        norm[i] = (p[i] == '\\') ? '/' : p[i];
    norm[i] = '\0';
    if (strncmp(norm, VFS_ROOT, VFS_ROOT_LEN) != 0) return 0;
    const char *key = norm + VFS_ROOT_LEN;
    size_t kl = strlen(key);
    if (kl + 1 > n) return 0;
    memcpy(out, key, kl + 1);
    path_canon(out);
    return 1;
}

static const char *materialize(int idx) {
    if (!tmpcache) {
        tmpcache = calloc(mz_zip_reader_get_num_files(&g_zip), sizeof(char *));
        if (!tmpcache) return NULL;
    }
    if (tmpcache[idx]) return tmpcache[idx];

    char dir[MAX_PATH], path[MAX_PATH];
    DWORD dl = GetTempPathA(sizeof(dir), dir);
    if (dl == 0 || dl > sizeof(dir)) return NULL;
    if (GetTempFileNameA(dir, "uvf", 0, path) == 0) return NULL;  /* creates the file */

    size_t outlen = 0;
    void *buf = NULL;
    if (entry_size(idx) > 0) {
        buf = mz_zip_reader_extract_to_heap(&g_zip, (mz_uint)idx, &outlen, 0);
        if (!buf) { DeleteFileA(path); return NULL; }
    }
    int fd = _open(path, _O_WRONLY | _O_BINARY | _O_TRUNC, _S_IREAD | _S_IWRITE);
    if (fd < 0) { mz_free(buf); DeleteFileA(path); return NULL; }
    size_t off = 0;
    while (off < outlen) {
        int w = _write(fd, (const char *)buf + off, (unsigned)(outlen - off));
        if (w <= 0) { _close(fd); mz_free(buf); DeleteFileA(path); return NULL; }
        off += (size_t)w;
    }
    _close(fd);
    mz_free(buf);

    if (!cleanup_registered) { atexit(vfs_cleanup); cleanup_registered = 1; }
    tmpcache[idx] = _strdup(path);
    return tmpcache[idx];
}

static void vfs_cleanup(void) {
    if (!tmpcache) return;
    mz_uint n = mz_zip_reader_get_num_files(&g_zip);
    for (mz_uint i = 0; i < n; i++)
        if (tmpcache[i]) DeleteFileA(tmpcache[i]);
}

int __wrap_open(const char *path, int oflag, ...) {
    char key[MAX_PATH];
    if (win_key(path, key, sizeof(key))) {
        int i = vfs_find(key);
        if (i < 0) { errno = ENOENT; return -1; }
        const char *m = materialize(i);
        if (!m) { errno = EIO; return -1; }
        return __real_open(m, _O_RDONLY | _O_BINARY, 0);
    }
    if (oflag & _O_CREAT) {
        va_list ap; va_start(ap, oflag);
        int mode = va_arg(ap, int);
        va_end(ap);
        return __real_open(path, oflag, mode);
    }
    return __real_open(path, oflag);
}

/* ======================================================================= */
#else /* POSIX: Linux (memfd) and macOS (mkstemp) */
#include <unistd.h>

/* On POSIX the lookup key is the path with the leading "/zip/" stripped, then
 * canonicalised (a win32 PE compile inside the multi binary opens relative
 * "../math.h" includes that resolve to ".../tcc/../math.h"). Copies into a
 * static buffer -- tcc is single-threaded per compile and the key is consumed
 * immediately by vfs_find. Returns the key, or NULL if not a /zip path. */
static const char *posix_key(const char *p) {
    static char keybuf[VFS_PATHMAX];
    if (vfs_off() || !p) return NULL;
    if (strncmp(p, VFS_ROOT, VFS_ROOT_LEN) != 0) return NULL;
    const char *k = p + VFS_ROOT_LEN;
    size_t kl = strlen(k);
    if (kl + 1 > sizeof keybuf) return NULL;
    memcpy(keybuf, k, kl + 1);
    path_canon(keybuf);
    return keybuf;
}

static int write_all(int fd, const unsigned char *data, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t w = write(fd, data + off, len - off);
        if (w < 0) return -1;
        off += (size_t)w;
    }
    lseek(fd, 0, SEEK_SET);
    return 0;
}

/* anon_fd: a fresh anonymous SEEKABLE fd — platform-specific, INDEPENDENT of the
 * VFS binding below. Linux has a real anonymous kernel fd (memfd); macOS has no
 * memfd, so a temp file unlinked immediately. */
#if defined(__APPLE__)
#include <stdio.h>
#include <sys/syscall.h>
static int anon_fd(const unsigned char *data, size_t len) {
    const char *t = getenv("TMPDIR");
    char tmpl[1024];
    snprintf(tmpl, sizeof tmpl, "%sunpinvfsXXXXXX", (t && *t) ? t : "/tmp/");
    int fd = mkstemp(tmpl);
    if (fd < 0) return -1;
    unlink(tmpl);
    if (write_all(fd, data, len) < 0) { close(fd); return -1; }
    return fd;
}
#else
#include <sys/syscall.h>
static int anon_fd(const unsigned char *data, size_t len) {
    int fd = (int)syscall(SYS_memfd_create, "unpinvfs", 0u);
    if (fd < 0) return -1;
    if (write_all(fd, data, len) < 0) { close(fd); return -1; }
    return fd;
}
#endif

/* VFS binding — how a backend's open/stat/lstat/access reach the VFS:
 *   rename  (unpinvfs_*): the backend objects' open/stat/lstat/access symbols are
 *     renamed to unpinvfs_*, so this TU NAMES its interceptors unpinvfs_* and
 *     calls the GENUINE libc directly. No linker-global `--wrap`, so it never
 *     reroutes any OTHER applet's open — the only binding safe to fold into the
 *     unpinbox mega. Used on macOS (objcopy renames the Mach-O imports; ld64 has
 *     no --wrap) AND on the bitcode engine path (the IR symbols are rewritten,
 *     -DUNPIN_VFS_NOWRAP), where stat is mega-safe and 32-bit musl's
 *     __stat_time64/__lstat_time64 are renamed to unpinvfs_stat/lstat too.
 *   --wrap  (__wrap_*): a standalone GNU-ld link passes -Wl,--wrap=open,… so
 *     __wrap_* intercept and __real_* are the genuine libc fns. NOT mega-safe.
 * REAL_* therefore call the real libc plainly under rename (this TU is never
 * renamed) and via __real_* under --wrap. */
#if defined(__APPLE__) || defined(UNPIN_VFS_NOWRAP)
#  define OPEN_FN    unpinvfs_open
#  define STAT_FN    unpinvfs_stat
#  define LSTAT_FN   unpinvfs_lstat
#  define ACCESS_FN  unpinvfs_access
#  define REAL_OPEN(p, ...)   open((p), __VA_ARGS__)
#  define REAL_STAT(p, s)     stat((p), (s))
#  define REAL_LSTAT(p, s)    lstat((p), (s))
#  define REAL_ACCESS(p, m)   access((p), (m))
#else
extern int __real_open(const char *path, int flags, ...);
extern int __real_stat(const char *path, struct stat *st);
extern int __real_lstat(const char *path, struct stat *st);
extern int __real_access(const char *path, int mode);
#  define OPEN_FN    __wrap_open
#  define STAT_FN    __wrap_stat
#  define LSTAT_FN   __wrap_lstat
#  define ACCESS_FN  __wrap_access
#  define REAL_OPEN(p, ...)   __real_open((p), __VA_ARGS__)
#  define REAL_STAT(p, s)     __real_stat((p), (s))
#  define REAL_LSTAT(p, s)    __real_lstat((p), (s))
#  define REAL_ACCESS(p, m)   __real_access((p), (m))
#endif

/* inflate entry idx into a fresh anonymous fd */
static int fd_for(int idx) {
    if (entry_size(idx) == 0) return anon_fd((const unsigned char *)"", 0);
    size_t outlen = 0;
    void *buf = mz_zip_reader_extract_to_heap(&g_zip, (mz_uint)idx, &outlen, 0);
    if (!buf) { errno = EIO; return -1; }
    int fd = anon_fd((const unsigned char *)buf, outlen);
    mz_free(buf);
    return fd;
}

static int fill_stat(struct stat *st, uint64_t len) {
    memset(st, 0, sizeof(*st));
    st->st_mode = S_IFREG | 0444;
    st->st_size = (off_t)len;
    st->st_nlink = 1;
    return 0;
}

int OPEN_FN(const char *path, int flags, ...) {
    const char *key = posix_key(path);
    if (key) {
        int i = vfs_find(key);
        if (i >= 0) return fd_for(i);
        errno = ENOENT; return -1;
    }
    if ((flags & O_CREAT)
#ifdef O_TMPFILE
        || (flags & O_TMPFILE) == O_TMPFILE
#endif
       ) {
        va_list ap; va_start(ap, flags);
        int mode = va_arg(ap, int);
        va_end(ap);
        return REAL_OPEN(path, flags, mode);
    }
    return REAL_OPEN(path, flags);
}

int STAT_FN(const char *path, struct stat *st) {
    const char *key = posix_key(path);
    if (key) {
        int i = vfs_find(key);
        if (i >= 0) return fill_stat(st, entry_size(i));
        errno = ENOENT; return -1;
    }
    return REAL_STAT(path, st);
}

int LSTAT_FN(const char *path, struct stat *st) {
    const char *key = posix_key(path);
    if (key) {
        int i = vfs_find(key);
        if (i >= 0) return fill_stat(st, entry_size(i));
        errno = ENOENT; return -1;
    }
    return REAL_LSTAT(path, st);
}

int ACCESS_FN(const char *path, int mode) {
    const char *key = posix_key(path);
    if (key) return vfs_find(key) >= 0 ? 0 : (errno = ENOENT, -1);
    return REAL_ACCESS(path, mode);
}

#if defined(UNPIN_WRAP_TIME64) && !defined(UNPIN_VFS_NOWRAP)
/* 32-bit musl (armv7l, i686, ...) is _REDIR_TIME64: <sys/stat.h> renames stat/
 * lstat to __stat_time64/__lstat_time64 via an __asm__ label, so perl's stat()
 * call references THOSE symbols, not `stat`. --wrap=stat then wraps a symbol
 * nobody calls and the real statx escapes the VFS. Wrap the time64 names too
 * (struct stat is already the time64 layout on these arches, so fill_stat is
 * correct). Linux-only; passed via -DUNPIN_WRAP_TIME64 for 32-bit hosts.
 * The NOWRAP (rename) binding handles these by rewriting the backend's
 * __stat_time64/__lstat_time64 IR symbols straight to unpinvfs_stat/lstat, so
 * this --wrap-only shim is compiled out there. */
extern int __real___stat_time64(const char *path, struct stat *st);
extern int __real___lstat_time64(const char *path, struct stat *st);

int __wrap___stat_time64(const char *path, struct stat *st) {
    const char *key = posix_key(path);
    if (key) {
        int i = vfs_find(key);
        if (i >= 0) return fill_stat(st, entry_size(i));
        errno = ENOENT; return -1;
    }
    return __real___stat_time64(path, st);
}

int __wrap___lstat_time64(const char *path, struct stat *st) {
    const char *key = posix_key(path);
    if (key) {
        int i = vfs_find(key);
        if (i >= 0) return fill_stat(st, entry_size(i));
        errno = ENOENT; return -1;
    }
    return __real___lstat_time64(path, st);
}
#endif /* UNPIN_WRAP_TIME64 */

#endif /* _WIN32 vs POSIX */
