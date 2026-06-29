/* unpin-vfs -- a single-binary virtual filesystem served from an embedded ZIP.
 *
 * One reusable core behind every unpin single-binary that embeds a runtime tree
 * (perl/biber @INC, python stdlib, tcc sysroot, vim runtime, ...). The tree is
 * a ZIP carried by the executable; a matched path under UNPIN_VFS_ROOT is
 * inflated on demand and handed to the program as a real, seekable fd. Misses
 * under the root are ENOENT (a reserved mount, never the host FS); everything
 * else falls through to libc untouched.
 *
 * Two ways the executable carries the ZIP:
 *   - blob (default): compiled in as a section (.incbin via blob.S), exposed
 *     through <sym>_{start,end} labels.
 *   - self-EOF (-DUNPIN_VFS_SELF): the single metadata/runtime ZIP appended to
 *     the binary by the nix build (docs/embedded-metadata.md — absolute,
 *     file-adjusted offsets). init locates the running executable, opens it
 *     read-only and serves entries straight from the file; the `unpin/` and
 *     `.unpin/` namespaces belong to unpin's metadata reader and are hidden
 *     from VFS lookups (the shared zstd dict is still auto-loaded).
 *
 * Container: a structurally standard .zip. Entries may be DEFLATE (method 8) or,
 * when built with -DMINIZ_USE_ZSTD, Zstandard (method 93) -- see README. An
 * optional shared zstd dictionary rides in the blob as the reserved STORED entry
 * ".unpin/zdict" and is auto-loaded at init.
 *
 * Two integration styles, one core:
 *   1. Transparent  -- GNU `ld --wrap` redirects libc open/stat/... into the
 *      __wrap_* shims below. No call-site edits (perl/biber/python/tcc/vim).
 *   2. Explicit API -- call unpin_vfs_* directly (for code paths --wrap can't
 *      reach). Both share the same lookup/inflate/materialise core.
 *
 * Build-time knobs (all optional):
 *   UNPIN_VFS_ROOT      mount prefix, default "/zip/"
 *   UNPIN_VFS_SELF      read the ZIP from the running executable's EOF instead
 *                       of a compiled-in blob (no blob.S, no *_start/_end syms)
 *   UNPIN_VFS_BLOB_SYM  blob symbol base name (bare identifier), default incblob
 *   MINIZ_USE_ZSTD      accept method-93 (zstd) entries + dict auto-load
 *   UNPIN_WRAP_TIME64   also wrap __stat_time64/__lstat_time64 (32-bit musl)
 *   UNPIN_VFS_NOWRAP    name the interceptors unpinvfs_* (not __wrap_*) so the
 *                       consumer's libc open/stat/... are rerouted by SYMBOL
 *                       RENAME (objcopy/IR rewrite) instead of `ld --wrap` --
 *                       the mega-safe binding the bitcode engine uses (tcc).
 *                       Implied on macOS (ld64 has no --wrap).
 *   UNPIN_VFS_WIN_WRAPOPEN  Windows: `ld --wrap=open` on plain msvcrt open()
 *                       (for a consumer that calls open() directly, e.g. tcc),
 *                       instead of the perl win32_* layer or vim marker mode.
 */
#ifndef UNPIN_VFS_H
#define UNPIN_VFS_H

#include <stddef.h>
#include <sys/stat.h>

#ifndef UNPIN_VFS_ROOT
#define UNPIN_VFS_ROOT "/zip/"
#endif

/* Initialise the reader from the embedded ZIP (blob section or self-EOF, see
 * above) and auto-load the shared dict if present. Idempotent; called lazily by
 * the shims, so consumers normally never call it. Returns 1 on success, 0 if
 * the ZIP is unusable (or, in self-EOF mode, absent). */
int unpin_vfs_init(void);

/* 1 if `path` is under UNPIN_VFS_ROOT (a path the VFS owns), else 0. */
int unpin_vfs_is_virtual(const char *path);

/* Explicit-API surface (style 2). For virtual paths these serve the blob; for
 * real paths they fall through to libc. Returns mirror the libc calls. */
int unpin_vfs_open(const char *path, int flags, ...);
int unpin_vfs_stat(const char *path, struct stat *st);
int unpin_vfs_lstat(const char *path, struct stat *st);
int unpin_vfs_access(const char *path, int mode);

#if defined(_WIN32) && defined(UNPIN_VFS_WIN_MARKER)
/* Windows marker mode only: materialise a virtual path to a (cached) temp file
 * and return that real path (NULL if not a hit). Lets a consumer route the path
 * back through its OWN native open/stat so its platform stat struct is filled
 * correctly -- vim's vim_stat patch uses this so :runtime/:syntax resolve. */
const char *unpin_vfs_winpath(const char *path);
#endif

/* Directory-iteration + fopen superset, compiled in with -DUNPIN_VFS_DIRS.
 * Off by default: it makes stat() directory-aware (synthesises S_IFDIR and
 * scans for implicit parents), which the file-only consumers (perl/biber/
 * python/tcc) don't need and shouldn't pay for. vim opts in -- it globs the
 * runtime tree and calls opendir/readdir directly. Virtual dirs are
 * synthesised from the ZIP central directory; reads go through the same
 * inflate->fd core (fopen = open + fdopen). */
#ifdef UNPIN_VFS_DIRS
#include <stdio.h>
#include <dirent.h>
FILE          *unpin_vfs_fopen(const char *path, const char *mode);
DIR           *unpin_vfs_opendir(const char *path);
struct dirent *unpin_vfs_readdir(DIR *d);
int            unpin_vfs_closedir(DIR *d);
#endif

#endif /* UNPIN_VFS_H */
