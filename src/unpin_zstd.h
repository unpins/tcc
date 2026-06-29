/* unpin_zstd.h -- thin Zstandard shim used by the patched miniz (method 93).
 *
 * miniz never sees <zstd.h>; it only calls these four functions. That keeps the
 * choice of zstd implementation (link libzstd at build time vs. vendor the
 * decompress-only single-file `zstddeclib.c` at runtime) an implementation
 * detail of unpin_zstd.c, not of the container reader.
 *
 * A process-wide shared dictionary (optional) is set once with
 * unpin_zstd_set_dict(); every (de)compress call after that uses it. This is how
 * the VFS gets cross-file compression while keeping per-entry random access --
 * the dict bytes live in the blob as one reserved entry, loaded at init.
 */
#ifndef UNPIN_ZSTD_H
#define UNPIN_ZSTD_H

#include <stddef.h>

/* Fully decompress one zstd frame from src[0..srclen) into dst (capacity
 * dstcap). Returns the uncompressed byte count, or 0 on any error. Uses the
 * shared dictionary if one was set. Runtime path (decompress-only is enough). */
size_t unpin_zstd_decompress(void *dst, size_t dstcap, const void *src, size_t srclen);

/* Worst-case compressed bound for srclen input bytes. Build-time (packer). */
size_t unpin_zstd_bound(size_t srclen);

/* Compress src[0..srclen) into dst (capacity dstcap) at `level`, using the
 * shared dictionary if set. Returns the compressed size, or 0 on error.
 * Build-time only (the packer); the runtime binary does not need this. */
size_t unpin_zstd_compress(void *dst, size_t dstcap, const void *src, size_t srclen, int level);

/* Install a process-wide raw zstd dictionary (or NULL/0 to clear). The pointer
 * must stay valid for the process lifetime; it is held by reference. */
void unpin_zstd_set_dict(const void *dict, size_t dictlen);

#endif /* UNPIN_ZSTD_H */
