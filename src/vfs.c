/* unpin-vfs core -- see vfs.h.
 *
 * Derived from the proven perl/biber/tcc `vfs_miniz.c` (open/stat/lstat/access
 * across Linux memfd / macOS mkstemp / Windows materialise-temp), generalised
 * into the reusable core and extended with shared-zstd-dict auto-load. The
 * directory-iteration superset (opendir/readdir/closedir, fopen) that vim needs
 * lands in vfs_dir.c once it is integration-tested in a real vim build.
 *
 * A matched open() inflates one entry and hands back a real, seekable fd; the
 * mechanism differs only in how each OS makes that fd:
 *   - Linux  : memfd_create. perl-style open/stat/... routed via `ld --wrap`.
 *   - macOS  : mkstemp + immediate unlink (no memfd). libc symbols renamed with
 *              objcopy --redefine-sym; this TU keeps the real libc.
 *   - Windows: materialise to a temp file once (cached by index) and delegate
 *              to the program's own real win32_* (wrapped via mingw `ld --wrap`).
 *
 * Build-time perls/pythons (Configure probes, install steps) export
 * UNPIN_VFS_OFF=1, turning every wrapper into a pure passthrough.
 */
#define _GNU_SOURCE
#include "vfs.h"
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include "miniz.h"
#ifdef MINIZ_USE_ZSTD
#include "unpin_zstd.h"
#endif

#ifdef UNPIN_VFS_SELF
/* Self-EOF mode: the ZIP is the single metadata/runtime container the nix
 * build appends to the executable (one ZIP per binary, ABSOLUTE file-adjusted
 * offsets — the sfx convention, docs/embedded-metadata.md). miniz finds the
 * EOCD by scanning back from EOF, and absolute offsets mean the whole file IS
 * the archive: no base adjustment, no blob symbols, no relink to change data.
 *
 * The file handle stays open for the process lifetime; extraction seeks+reads
 * it on demand (these consumers' VFS paths are single-threaded, like the rest
 * of this reader). Reading our own image is fine everywhere: Linux via
 * /proc/self/exe (works even unlinked), macOS via _NSGetExecutablePath, and
 * Windows loaders open images with FILE_SHARE_READ, so a read-only CRT open
 * succeeds while running. */
#if defined(_WIN32)
#include <windows.h>
static FILE *self_open(mz_uint64 *size) {
    /* Wide-char API + _wfopen so a unicode install path survives (miniz's
     * mz_zip_reader_init_file would route through the ANSI fopen). */
    static wchar_t p[4096];
    DWORD n = GetModuleFileNameW(NULL, p, (DWORD)(sizeof p / sizeof p[0]));
    if (n == 0 || n >= sizeof p / sizeof p[0]) return NULL;
    FILE *f = _wfopen(p, L"rb");
    if (!f) return NULL;
    if (_fseeki64(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long long sz = _ftelli64(f);
    /* Rewind: mz_zip_reader_init_cfile treats the CURRENT file position as
     * the archive start (m_file_archive_start_ofs), and ours is offset 0. */
    if (sz <= 0 || _fseeki64(f, 0, SEEK_SET) != 0) { fclose(f); return NULL; }
    *size = (mz_uint64)sz;
    return f;
}
#else
#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif
static FILE *self_open(mz_uint64 *size) {
#if defined(__APPLE__)
    char p[4096];
    uint32_t n = sizeof p;
    if (_NSGetExecutablePath(p, &n) != 0) return NULL;
    FILE *f = fopen(p, "rb");
#else
    FILE *f = fopen("/proc/self/exe", "rb");
#endif
    if (!f) return NULL;
    if (fseeko(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    off_t sz = ftello(f);
    /* Rewind: mz_zip_reader_init_cfile treats the CURRENT file position as
     * the archive start (m_file_archive_start_ofs), and ours is offset 0. */
    if (sz <= 0 || fseeko(f, 0, SEEK_SET) != 0) { fclose(f); return NULL; }
    *size = (mz_uint64)sz;
    return f;
}
#endif

/* The `unpin/` and `.unpin/` namespaces of the shared container belong to
 * unpin's metadata reader (aliases, man); hide them from VFS lookups and
 * listings so the mount only ever shows the runtime tree. (The shared zstd
 * dict ".unpin/zdict" is still loaded at init — by exact name, not through
 * the lookup path.) */
static int vfs_hidden(const char *key) {
    if (key[0] == '.') key++;
    /* Case-insensitive: miniz's locate_file is case-insensitive by default
     * (flags 0), so "UNPIN/aliases" would otherwise reach the metadata. */
    for (const char *m = "unpin"; *m; m++, key++)
        if ((*key | 0x20) != *m) return 0;
    return *key == '/' || *key == '\0';
}
#else /* blob mode */
/* Blob symbols produced by blob.S (`.incbin`). Linux uses the objcopy-style
 * _binary_<name>_{start,end}; macOS/Windows assemblers emit the bare
 * <name>_{start,end}. <name> defaults to "incblob"; override with
 * -DUNPIN_VFS_BLOB_SYM=<bare identifier> (must match the labels in blob.S). */
#ifndef UNPIN_VFS_BLOB_SYM
#define UNPIN_VFS_BLOB_SYM incblob
#endif
#define UVFS_CAT_(a, b) a##b
#define UVFS_CAT(a, b)  UVFS_CAT_(a, b)
#if defined(__APPLE__) || defined(_WIN32)
extern const unsigned char UVFS_CAT(UNPIN_VFS_BLOB_SYM, _start)[];
extern const unsigned char UVFS_CAT(UNPIN_VFS_BLOB_SYM, _end)[];
#  define BLOB_BEG UVFS_CAT(UNPIN_VFS_BLOB_SYM, _start)
#  define BLOB_END UVFS_CAT(UNPIN_VFS_BLOB_SYM, _end)
#else
extern const unsigned char UVFS_CAT(_binary_, UVFS_CAT(UNPIN_VFS_BLOB_SYM, _start))[];
extern const unsigned char UVFS_CAT(_binary_, UVFS_CAT(UNPIN_VFS_BLOB_SYM, _end))[];
#  define BLOB_BEG UVFS_CAT(_binary_, UVFS_CAT(UNPIN_VFS_BLOB_SYM, _start))
#  define BLOB_END UVFS_CAT(_binary_, UVFS_CAT(UNPIN_VFS_BLOB_SYM, _end))
#endif

/* A private blob never carries the unpin metadata namespaces. */
#define vfs_hidden(key) 0
#endif /* UNPIN_VFS_SELF */

#define VFS_ROOT     UNPIN_VFS_ROOT
#define VFS_ROOT_LEN (sizeof(VFS_ROOT) - 1)
#define ZDICT_ENTRY  ".unpin/zdict"

/* ---- shared miniz core ------------------------------------------------- */

static mz_zip_archive g_zip;
static int g_state;            /* 0=uninit, 1=ready, 2=failed */
static int g_disabled = -1;

static int vfs_off(void) {
    if (g_disabled < 0) g_disabled = (getenv("UNPIN_VFS_OFF") != NULL);
    return g_disabled;
}

int unpin_vfs_init(void) {
    if (g_state) return g_state == 1;
    memset(&g_zip, 0, sizeof g_zip);
#ifdef UNPIN_VFS_SELF
    mz_uint64 self_size = 0;
    FILE *self = self_open(&self_size);
    g_state = (self && mz_zip_reader_init_cfile(&g_zip, self, self_size, 0)) ? 1 : 2;
    if (g_state != 1 && self) fclose(self);
    /* On success `self` is owned by g_zip for the process lifetime. */
#else
    size_t size = (size_t)(BLOB_END - BLOB_BEG);
    g_state = mz_zip_reader_init_mem(&g_zip, BLOB_BEG, size, 0) ? 1 : 2;
#endif
#ifdef MINIZ_USE_ZSTD
    if (g_state == 1) {
        /* Auto-load the shared dictionary: it is STORED, so it reads without
         * itself. Held for the process lifetime (single blob per process). */
        int di = mz_zip_reader_locate_file(&g_zip, ZDICT_ENTRY, NULL, 0);
        if (di >= 0) {
            size_t dlen = 0;
            void *d = mz_zip_reader_extract_to_heap(&g_zip, (mz_uint)di, &dlen, 0);
            if (d) unpin_zstd_set_dict(d, dlen);
        }
    }
#endif
    return g_state == 1;
}

/* zip lookup by /zip-stripped, forward-slash key. Returns file index or -1. */
static int vfs_find(const char *key) {
    if (vfs_hidden(key)) return -1;
    if (!unpin_vfs_init()) return -1;
    return mz_zip_reader_locate_file(&g_zip, key, NULL, 0);
}

static uint64_t entry_size(int idx) {
    mz_zip_archive_file_stat st;
    if (!mz_zip_reader_file_stat(&g_zip, (mz_uint)idx, &st)) return 0;
    return (uint64_t)st.m_uncomp_size;
}

/* Lexically resolve "." and ".." in a '/'-separated relative key, in place.
 * tcc emits relative #includes literally ("#include \"../math.h\"" from
 * .../tcc/tcc_libm.h opens ".../tcc/../math.h"), but the ZIP keys are clean
 * (".../math.h"), so the VFS must canonicalise. Inert for already-clean keys
 * (file/perl/python carry no "." / ".." segments), so applied to every virtual
 * key unconditionally. */
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

int unpin_vfs_is_virtual(const char *path) {
    if (!path) return 0;
#if defined(_WIN32) && defined(UNPIN_VFS_WIN_MARKER)
    /* vim/gvim canonicalise "/<marker>/x" into "C:\<marker>\x" (current drive
     * prepended, separators flipped), so the strict prefix test below would
     * miss it. The marker is chosen unique, so match it anywhere in the path. */
    return strstr(path, UNPIN_VFS_WIN_MARKER) != NULL;
#else
    /* Match VFS_ROOT minus its trailing slash, then require a separator or
     * end-of-string: "<root>/x" and the bare mount point "<root>" both count,
     * but "<root>foo" does not. (VFS_ROOT ends in '/' by contract.) */
    if (strncmp(path, VFS_ROOT, VFS_ROOT_LEN - 1) != 0) return 0;
    char c = path[VFS_ROOT_LEN - 1];
    return c == '/' || c == '\0';
#endif
}

/* ======================================================================= */
#if defined(_WIN32)
/* ----- Windows: materialise to a temp file, then hand back a real fd ----
 * Two integration modes share the materialise core below:
 *   - default (perl): `ld --wrap=win32_*` redirects the program's win32_open/
 *     stat/... into the __wrap_win32_* shims, which delegate to the program's
 *     own __real_win32_*. Matching is strict-prefix (win_key).
 *   - UNPIN_VFS_WIN_MARKER (vim/gvim): the consumer has no win32_* layer to
 *     wrap and canonicalises virtual paths to "C:\<marker>\..."; it patches its
 *     own mch_open/mch_fopen to call the explicit unpin_vfs_* below for virtual
 *     paths. Matching is marker-strstr; reads go straight onto the CRT. */
#include <io.h>
#include <windows.h>
#include <stdio.h>

static char **tmpcache;         /* materialised temp path per entry, or NULL */
static int cleanup_registered;
static void vfs_cleanup(void);

static const char *materialize(int idx) {
    if (!tmpcache) {
        tmpcache = calloc(mz_zip_reader_get_num_files(&g_zip), sizeof(char *));
        if (!tmpcache) return NULL;
    }
    if (tmpcache[idx]) return tmpcache[idx];

    char dir[MAX_PATH], path[MAX_PATH];
    DWORD dl = GetTempPathA(sizeof(dir), dir);
    if (dl == 0 || dl > sizeof(dir)) return NULL;
    if (GetTempFileNameA(dir, "uvf", 0, path) == 0) return NULL;

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

#ifdef UNPIN_VFS_WIN_MARKER
/* ---- vim/gvim mode: marker match + explicit API straight onto the CRT --- */
/* No win32_* layer to --wrap; the consumer patches its own mch_open/mch_fopen
 * to call unpin_vfs_open/unpin_vfs_fopen for virtual paths (gated on
 * unpin_vfs_is_virtual). Extract the ZIP key from a (possibly drive-prefixed,
 * backslash-separated) marker path and serve from a materialised temp file. */
static int marker_key(const char *p, char *out, size_t n) {
    if (vfs_off() || !p) return 0;
    const char *m = strstr(p, UNPIN_VFS_WIN_MARKER);
    if (!m) return 0;
    const char *rest = m + (sizeof(UNPIN_VFS_WIN_MARKER) - 1);
    while (*rest == '/' || *rest == '\\') rest++;  /* skip the separator(s) */
    size_t i = 0;
    for (; rest[i] && i + 1 < n; i++)
        out[i] = (rest[i] == '\\') ? '/' : rest[i];  /* ZIP keys use '/' */
    if (rest[i]) return 0;                            /* key too long */
    out[i] = '\0';
    path_canon(out);
    return 1;
}

/* Materialise a virtual path to a (cached) temp file and return that real
 * path, or NULL if `path` isn't a hit. Lets a consumer route a virtual path
 * back through its own native open/stat/...; used by vim's vim_stat patch so
 * the program's own code fills its platform stat struct. */
const char *unpin_vfs_winpath(const char *path) {
    char key[MAX_PATH];
    if (!marker_key(path, key, sizeof key)) return NULL;
    int i = vfs_find(key);
    if (i < 0) return NULL;
    return materialize(i);
}

int unpin_vfs_open(const char *path, int flags, ...) {
    char key[MAX_PATH];
    if (marker_key(path, key, sizeof key)) {
        int i = vfs_find(key);
        if (i < 0) { errno = ENOENT; return -1; }
        const char *m = materialize(i);
        if (!m) { errno = EIO; return -1; }
        return _open(m, _O_RDONLY | _O_BINARY, 0);
    }
    if (flags & _O_CREAT) {
        va_list ap; va_start(ap, flags); int mode = va_arg(ap, int); va_end(ap);
        return _open(path, flags, mode);
    }
    return _open(path, flags);
}

FILE *unpin_vfs_fopen(const char *path, const char *mode) {
    char key[MAX_PATH];
    if (marker_key(path, key, sizeof key)) {
        if (mode && mode[0] != 'r') { errno = EROFS; return NULL; }  /* read-only blob */
        int i = vfs_find(key);
        if (i < 0) { errno = ENOENT; return NULL; }
        const char *m = materialize(i);
        if (!m) { errno = EIO; return NULL; }
        return fopen(m, "rb");
    }
    return fopen(path, mode);
}

int unpin_vfs_stat(const char *path, struct stat *st) {
    char key[MAX_PATH];
    if (marker_key(path, key, sizeof key)) {
        int i = vfs_find(key);
        if (i < 0) { errno = ENOENT; return -1; }
        const char *m = materialize(i);
        if (!m) { errno = EIO; return -1; }
        return stat(m, st);
    }
    return stat(path, st);
}
int unpin_vfs_lstat(const char *path, struct stat *st) { return unpin_vfs_stat(path, st); }
int unpin_vfs_access(const char *path, int mode) {
    char key[MAX_PATH];
    if (marker_key(path, key, sizeof key))
        return vfs_find(key) >= 0 ? 0 : (errno = ENOENT, -1);
    return _access(path, mode);
}

#else /* non-marker windows: strict /zip prefix (win_key) + materialise */

/* Normalise into a /zip-rooted forward-slash key (path munging can emit
 * backslashes) and canonicalise. Returns 1 and writes the lookup key into out.
 * Shared by the plain-open (tcc) and win32_* (perl) bindings below. */
static int win_key(const char *p, char *out, size_t n) {
    if (vfs_off() || !p) return 0;
    char norm[MAX_PATH];
    size_t i = 0;
    for (; p[i] && i + 1 < sizeof(norm); i++)
        norm[i] = (p[i] == '\\') ? '/' : p[i];
    norm[i] = '\0';
    /* Match the root, tolerating the bare mount point (see unpin_vfs_is_virtual). */
    if (strncmp(norm, VFS_ROOT, VFS_ROOT_LEN - 1) != 0) return 0;
    char c = norm[VFS_ROOT_LEN - 1];
    const char *key;
    if (c == '/')       key = norm + VFS_ROOT_LEN;       /* "<root>/rest" -> "rest" */
    else if (c == '\0') key = norm + VFS_ROOT_LEN - 1;   /* bare "<root>"  -> ""     */
    else                return 0;
    size_t kl = strlen(key);
    if (kl + 1 > n) return 0;
    memcpy(out, key, kl + 1);
    path_canon(out);
    return 1;
}

#ifdef UNPIN_VFS_WIN_WRAPOPEN
/* ---- tcc mode: `ld --wrap=open` on plain msvcrt open() ------------------ */
/* tcc reads every source/header/archive/.def through open(path,O_RDONLY|
 * O_BINARY) and makes NO stat/lstat/access calls, so a single __wrap_open is
 * the whole VFS here. Output files (.exe/.def) go through fopen()/CreateFile and
 * never carry the /zip prefix, so they fall through untouched. */
extern int __real_open(const char *path, int oflag, ...);

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

/* Explicit API maps onto __wrap_open / the CRT; tcc makes no stat on Windows. */
int unpin_vfs_open(const char *path, int flags, ...) {
    if (flags & _O_CREAT) {
        va_list ap; va_start(ap, flags); int m = va_arg(ap, int); va_end(ap);
        return __wrap_open(path, flags, m);
    }
    return __wrap_open(path, flags);
}
int unpin_vfs_stat(const char *path, struct stat *st) {
    char key[MAX_PATH];
    if (win_key(path, key, sizeof key)) {
        int i = vfs_find(key);
        if (i < 0) { errno = ENOENT; return -1; }
        const char *m = materialize(i);
        if (!m) { errno = EIO; return -1; }
        return stat(m, st);
    }
    return stat(path, st);
}
int unpin_vfs_lstat(const char *path, struct stat *st) { return unpin_vfs_stat(path, st); }
int unpin_vfs_access(const char *path, int mode) {
    char key[MAX_PATH];
    if (win_key(path, key, sizeof key))
        return vfs_find(key) >= 0 ? 0 : (errno = ENOENT, -1);
    return _access(path, mode);
}

#else /* default (perl): --wrap=win32_* delegating to the program's real win32_* */

extern int __real_win32_open(const char *path, int oflag, ...);
extern int __real_win32_stat(const char *name, void *stbuf);
extern int __real_win32_lstat(const char *name, void *stbuf);
extern int __real_win32_access(const char *path, int mode);

int __wrap_win32_open(const char *path, int oflag, ...) {
    char key[MAX_PATH];
    if (win_key(path, key, sizeof(key))) {
        int i = vfs_find(key);
        if (i < 0) { errno = ENOENT; return -1; }
        const char *m = materialize(i);
        if (!m) { errno = EIO; return -1; }
        return __real_win32_open(m, _O_RDONLY | _O_BINARY, 0);
    }
    if (oflag & _O_CREAT) {
        va_list ap; va_start(ap, oflag);
        int mode = va_arg(ap, int);
        va_end(ap);
        return __real_win32_open(path, oflag, mode);
    }
    return __real_win32_open(path, oflag);
}

int __wrap_win32_stat(const char *name, void *st) {
    char key[MAX_PATH];
    if (win_key(name, key, sizeof(key))) {
        int i = vfs_find(key);
        if (i < 0) { errno = ENOENT; return -1; }
        const char *m = materialize(i);
        if (!m) { errno = EIO; return -1; }
        return __real_win32_stat(m, st);
    }
    return __real_win32_stat(name, st);
}

int __wrap_win32_lstat(const char *name, void *st) {
    char key[MAX_PATH];
    if (win_key(name, key, sizeof(key))) {
        int i = vfs_find(key);
        if (i < 0) { errno = ENOENT; return -1; }
        const char *m = materialize(i);
        if (!m) { errno = EIO; return -1; }
        return __real_win32_lstat(m, st);
    }
    return __real_win32_lstat(name, st);
}

int __wrap_win32_access(const char *path, int mode) {
    char key[MAX_PATH];
    if (win_key(path, key, sizeof(key)))
        return vfs_find(key) >= 0 ? 0 : (errno = ENOENT, -1);
    return __real_win32_access(path, mode);
}

/* Explicit API maps onto the win32 wrappers' behaviour. */
int unpin_vfs_open(const char *path, int flags, ...) {
    if (flags & _O_CREAT) {
        va_list ap; va_start(ap, flags); int m = va_arg(ap, int); va_end(ap);
        return __wrap_win32_open(path, flags, m);
    }
    return __wrap_win32_open(path, flags);
}
int unpin_vfs_stat(const char *path, struct stat *st)  { return __wrap_win32_stat(path, st); }
int unpin_vfs_lstat(const char *path, struct stat *st) { return __wrap_win32_lstat(path, st); }
int unpin_vfs_access(const char *path, int mode)       { return __wrap_win32_access(path, mode); }
#endif /* UNPIN_VFS_WIN_WRAPOPEN */
#endif /* UNPIN_VFS_WIN_MARKER */

/* ======================================================================= */
#else /* POSIX: Linux (memfd) and macOS (mkstemp) */
#include <unistd.h>
#include <sys/syscall.h>
#ifdef UNPIN_VFS_DIRS
#include <stdio.h>
#include <dirent.h>
#include <limits.h>
#ifndef PATH_MAX
#define PATH_MAX 4096
#endif
#endif

/* POSIX key: path with the leading VFS_ROOT stripped (no backslashes), then
 * canonicalised. Copies into a static buffer (single-threaded per lookup; the
 * key is consumed immediately by vfs_find) so path_canon can rewrite in place. */
static const char *posix_key(const char *p) {
    static char keybuf[VFS_PATHMAX];
    if (vfs_off() || !p) return NULL;
    /* Match the root, tolerating the bare mount point (see unpin_vfs_is_virtual). */
    if (strncmp(p, VFS_ROOT, VFS_ROOT_LEN - 1) != 0) return NULL;
    char c = p[VFS_ROOT_LEN - 1];
    const char *k;
    if (c == '/')       k = p + VFS_ROOT_LEN;      /* "<root>/rest" -> "rest" */
    else if (c == '\0') k = p + VFS_ROOT_LEN - 1;  /* bare "<root>"  -> ""     */
    else return NULL;
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

/* anon_fd: a fresh anonymous SEEKABLE fd — the PLATFORM axis, independent of the
 * VFS binding below. Linux has a real anonymous kernel fd (memfd); macOS has no
 * memfd, so a temp file unlinked immediately. */
#if defined(__APPLE__)
#include <stdio.h>
static int anon_fd(const unsigned char *data, size_t len) {
    const char *t = getenv("TMPDIR");
    if (!t || !*t) t = "/tmp/";
    char tmpl[1024];
    /* TMPDIR may or may not end in '/'; insert a separator only when missing. */
    snprintf(tmpl, sizeof tmpl, "%s%sunpinvfsXXXXXX",
             t, t[strlen(t) - 1] == '/' ? "" : "/");
    int fd = mkstemp(tmpl);
    if (fd < 0) return -1;
    unlink(tmpl);
    if (write_all(fd, data, len) < 0) { close(fd); return -1; }
    return fd;
}
#else
static int anon_fd(const unsigned char *data, size_t len) {
    int fd = (int)syscall(SYS_memfd_create, "unpinvfs", 0u);
    if (fd < 0) return -1;
    if (write_all(fd, data, len) < 0) { close(fd); return -1; }
    return fd;
}
#endif

/* VFS binding — how a consumer's open/stat/lstat/access reach the VFS. Distinct
 * from the platform axis above: a Linux engine build (memfd) still takes the
 * rename binding.
 *   rename (unpinvfs_*): the consumer's libc open/stat/... symbols are renamed
 *     to unpinvfs_* — objcopy on Mach-O imports (ld64 has no --wrap), or the
 *     bitcode engine rewriting the IR symbols (-DUNPIN_VFS_NOWRAP, tcc). This TU
 *     is NEVER renamed, so it NAMES its interceptors unpinvfs_* and calls the
 *     genuine libc directly. No linker-global --wrap → never reroutes another
 *     applet's open: the only binding safe to fold into the unpinbox mega.
 *   --wrap (__wrap_*): a standalone GNU-ld link passes -Wl,--wrap=open,… so
 *     __wrap_* intercept and __real_* are the genuine libc. NOT mega-safe. */
#if defined(__APPLE__) || defined(UNPIN_VFS_NOWRAP)
#  define OPEN_FN    unpinvfs_open
#  define STAT_FN    unpinvfs_stat
#  define LSTAT_FN   unpinvfs_lstat
#  define ACCESS_FN  unpinvfs_access
#  define REAL_OPEN(p, ...)   open((p), __VA_ARGS__)
#  define REAL_STAT(p, s)     stat((p), (s))
#  define REAL_LSTAT(p, s)    lstat((p), (s))
#  define REAL_ACCESS(p, m)   access((p), (m))
#  ifdef UNPIN_VFS_DIRS
#    define OPENDIR_FN  unpinvfs_opendir
#    define READDIR_FN  unpinvfs_readdir
#    define CLOSEDIR_FN unpinvfs_closedir
#    define FOPEN_FN    unpinvfs_fopen
#    define REAL_OPENDIR(p)   opendir((p))
#    define REAL_READDIR(d)   readdir((d))
#    define REAL_CLOSEDIR(d)  closedir((d))
#    define REAL_FOPEN(p, m)  fopen((p), (m))
#  endif
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
#  ifdef UNPIN_VFS_DIRS
extern DIR *__real_opendir(const char *path);
extern struct dirent *__real_readdir(DIR *dirp);
extern int __real_closedir(DIR *dirp);
extern FILE *__real_fopen(const char *path, const char *mode);
#    define OPENDIR_FN  __wrap_opendir
#    define READDIR_FN  __wrap_readdir
#    define CLOSEDIR_FN __wrap_closedir
#    define FOPEN_FN    __wrap_fopen
#    define REAL_OPENDIR(p)   __real_opendir((p))
#    define REAL_READDIR(d)   __real_readdir((d))
#    define REAL_CLOSEDIR(d)  __real_closedir((d))
#    define REAL_FOPEN(p, m)  __real_fopen((p), (m))
#  endif
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

#ifdef UNPIN_VFS_DIRS
/* Locate by exact name, then with a trailing slash (directory records). */
static int find_entry(const char *key) {
    int i = mz_zip_reader_locate_file(&g_zip, key, NULL, 0);
    if (i >= 0) return i;
    char slashed[PATH_MAX];
    int n = snprintf(slashed, sizeof slashed, "%s/", key);
    if (n < 0 || (size_t)n >= sizeof slashed) return -1;
    return mz_zip_reader_locate_file(&g_zip, slashed, NULL, 0);
}
/* Is `key` the implicit parent of some entry (a dir with no own record)? */
static int is_implicit_dir(const char *key) {
    size_t kl = strlen(key);
    if (kl == 0) return 1;  /* the mount root */
    mz_uint n = mz_zip_reader_get_num_files(&g_zip);
    char name[PATH_MAX];
    for (mz_uint i = 0; i < n; i++) {
        mz_uint fl = mz_zip_reader_get_filename(&g_zip, i, name, sizeof name);
        if (fl <= kl) continue;
        if (memcmp(name, key, kl) == 0 && name[kl] == '/') return 1;
    }
    return 0;
}
static int fill_dir_stat(struct stat *st) {
    memset(st, 0, sizeof *st);
    st->st_mode = S_IFDIR | 0555;
    st->st_nlink = 2;
    return 0;
}
#endif /* UNPIN_VFS_DIRS */

/* Virtual-path handlers shared by the wrap shims and the explicit API. */
static int vfs_open_virtual(const char *key) {
    int i = vfs_find(key);
    if (i >= 0) return fd_for(i);
    errno = ENOENT; return -1;
}
static int vfs_stat_virtual(const char *key, struct stat *st) {
#ifdef UNPIN_VFS_DIRS
    if (vfs_hidden(key)) { errno = ENOENT; return -1; }
    if (!unpin_vfs_init()) { errno = EIO; return -1; }  /* find_entry needs g_zip */
    int i = find_entry(key);
    if (i >= 0) {
        if (mz_zip_reader_is_file_a_directory(&g_zip, (mz_uint)i)) return fill_dir_stat(st);
        return fill_stat(st, entry_size(i));
    }
    if (is_implicit_dir(key)) return fill_dir_stat(st);
    errno = ENOENT; return -1;
#else
    int i = vfs_find(key);
    if (i >= 0) return fill_stat(st, entry_size(i));
    errno = ENOENT; return -1;
#endif
}

int OPEN_FN(const char *path, int flags, ...) {
    const char *key = posix_key(path);
    if (key) return vfs_open_virtual(key);
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
    if (key) return vfs_stat_virtual(key, st);
    return REAL_STAT(path, st);
}

int LSTAT_FN(const char *path, struct stat *st) {
    const char *key = posix_key(path);
    if (key) return vfs_stat_virtual(key, st);
    return REAL_LSTAT(path, st);
}

int ACCESS_FN(const char *path, int mode) {
    const char *key = posix_key(path);
    if (key) return vfs_find(key) >= 0 ? 0 : (errno = ENOENT, -1);
    return REAL_ACCESS(path, mode);
}

#ifdef UNPIN_VFS_DIRS
/* ---- directory iteration + fopen (the vim superset) ------------------- */

/* A synthetic DIR* for virtual directories. The leading magic word lets
 * readdir/closedir tell our DIR* from a real one (a real glibc/musl DIR
 * starts with a small fd, never this value), so a single set of wrappers
 * handles both virtual and real directories. */
struct vfs_dir {
    uint64_t magic;
#define VFS_DIR_MAGIC 0x5546535644495220ULL  /* "UFSVDIR " */
    char     prefix[PATH_MAX];   /* ZIP key, no trailing slash */
    size_t   prefix_len;
    mz_uint  cursor;             /* central-directory walk position */
    char     last_emitted[256];  /* single-slot dedup of child segments */
    struct dirent ent;
};

DIR *OPENDIR_FN(const char *path) {
    const char *key = posix_key(path);
    if (!key) return REAL_OPENDIR(path);
    if (!unpin_vfs_init()) { errno = EIO; return NULL; }

    /* Strip trailing slash(es): callers (e.g. vim's unix_expandpath) open
     * "dir/", but child entries are "dir/<name>", matched against prefix "dir"
     * with a separating '/'. A "dir/" prefix would make that separator test
     * fire on the child's first char and skip every entry. */
    char keybuf[PATH_MAX];
    size_t kl = strlen(key);
    while (kl > 0 && key[kl - 1] == '/') kl--;
    if (kl >= sizeof keybuf) { errno = ENAMETOOLONG; return NULL; }
    memcpy(keybuf, key, kl);
    keybuf[kl] = '\0';
    if (vfs_hidden(keybuf)) { errno = ENOENT; return NULL; }

    int idx = find_entry(keybuf);
    int is_dir = (idx >= 0 && mz_zip_reader_is_file_a_directory(&g_zip, (mz_uint)idx));
    if (!is_dir && !is_implicit_dir(keybuf)) { errno = ENOENT; return NULL; }

    struct vfs_dir *d = calloc(1, sizeof *d);
    if (!d) { errno = ENOMEM; return NULL; }
    d->magic = VFS_DIR_MAGIC;
    d->prefix_len = kl;
    memcpy(d->prefix, keybuf, kl + 1);
    return (DIR *)d;
}

struct dirent *READDIR_FN(DIR *dir) {
    if (!dir) { errno = EBADF; return NULL; }
    struct vfs_dir *d = (struct vfs_dir *)dir;
    if (d->magic != VFS_DIR_MAGIC) return REAL_READDIR(dir);

    mz_uint n = mz_zip_reader_get_num_files(&g_zip);
    char name[PATH_MAX];
    while (d->cursor < n) {
        mz_uint i = d->cursor++;
        mz_uint fl = mz_zip_reader_get_filename(&g_zip, i, name, sizeof name);
        if (fl <= d->prefix_len + 1) continue;  /* fl counts the NUL: skips name <= prefix */
        if (vfs_hidden(name)) continue;  /* keep the unpin namespaces unlisted */

        /* Children of the mount root (prefix_len == 0) have no leading
         * separator to strip; deeper dirs match "<prefix>/" then the child. */
        const char *seg;
        if (d->prefix_len == 0) {
            seg = name;
        } else {
            if (memcmp(name, d->prefix, d->prefix_len) != 0) continue;
            if (name[d->prefix_len] != '/') continue;
            seg = name + d->prefix_len + 1;
        }
        const char *seg_end = strchr(seg, '/');
        size_t seg_len = seg_end ? (size_t)(seg_end - seg) : strlen(seg);
        if (seg_len == 0 || seg_len >= sizeof d->ent.d_name) continue;

        /* ZIP entries under a subdir cluster together, so single-slot dedup
         * collapses the repeated parent into one child entry. */
        if (d->last_emitted[0] &&
            strncmp(d->last_emitted, seg, seg_len) == 0 &&
            d->last_emitted[seg_len] == '\0')
            continue;
        memcpy(d->last_emitted, seg, seg_len);
        d->last_emitted[seg_len] = '\0';

        memcpy(d->ent.d_name, seg, seg_len);
        d->ent.d_name[seg_len] = '\0';
        d->ent.d_ino = i + 1;                       /* nonzero, stable */
        d->ent.d_type = seg_end ? DT_DIR : DT_REG;
        return &d->ent;
    }
    return NULL;
}

int CLOSEDIR_FN(DIR *dir) {
    if (!dir) { errno = EBADF; return -1; }
    struct vfs_dir *d = (struct vfs_dir *)dir;
    if (d->magic != VFS_DIR_MAGIC) return REAL_CLOSEDIR(dir);
    free(d);
    return 0;
}

/* fopen: inflate to an anonymous fd, then fdopen it. Avoids fopencookie,
 * whose seek-callback signature differs between glibc and musl. */
FILE *FOPEN_FN(const char *path, const char *mode) {
    const char *key = posix_key(path);
    if (!key) return REAL_FOPEN(path, mode);
    if (mode && mode[0] != 'r') { errno = EROFS; return NULL; }
    int fd = vfs_open_virtual(key);
    if (fd < 0) return NULL;
    FILE *fp = fdopen(fd, "rb");
    if (!fp) { int e = errno; close(fd); errno = e; return NULL; }
    return fp;
}

/* Explicit API for these (style 2). */
DIR           *unpin_vfs_opendir(const char *p)               { return OPENDIR_FN(p); }
struct dirent *unpin_vfs_readdir(DIR *d)                      { return READDIR_FN(d); }
int            unpin_vfs_closedir(DIR *d)                     { return CLOSEDIR_FN(d); }
FILE          *unpin_vfs_fopen(const char *p, const char *m) { return FOPEN_FN(p, m); }
#endif /* UNPIN_VFS_DIRS */

#ifdef UNPIN_WRAP_TIME64
/* 32-bit musl (armv7l, i686) is _REDIR_TIME64: <sys/stat.h> renames stat/lstat
 * to __stat_time64/__lstat_time64 via __asm__ labels, so the program's stat()
 * references THOSE symbols. Wrap them too (struct stat is already time64). */
extern int __real___stat_time64(const char *path, struct stat *st);
extern int __real___lstat_time64(const char *path, struct stat *st);
int __wrap___stat_time64(const char *path, struct stat *st) {
    const char *key = posix_key(path);
    if (key) return vfs_stat_virtual(key, st);
    return __real___stat_time64(path, st);
}
int __wrap___lstat_time64(const char *path, struct stat *st) {
    const char *key = posix_key(path);
    if (key) return vfs_stat_virtual(key, st);
    return __real___lstat_time64(path, st);
}
#endif /* UNPIN_WRAP_TIME64 */

/* Explicit API (style 2). On Linux these resolve to the same __wrap_* symbols
 * --wrap already redirects; on macOS they call the unpinvfs_* definitions. */
int unpin_vfs_open(const char *path, int flags, ...) {
    if (flags & O_CREAT) {
        va_list ap; va_start(ap, flags); int m = va_arg(ap, int); va_end(ap);
        return OPEN_FN(path, flags, m);
    }
    return OPEN_FN(path, flags);
}
int unpin_vfs_stat(const char *path, struct stat *st)  { return STAT_FN(path, st); }
int unpin_vfs_lstat(const char *path, struct stat *st) { return LSTAT_FN(path, st); }
int unpin_vfs_access(const char *path, int mode)       { return ACCESS_FN(path, mode); }

#endif /* _WIN32 vs POSIX */
