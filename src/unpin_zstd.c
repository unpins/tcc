/* unpin_zstd.c -- the one translation unit that pulls in zstd.
 *
 * Two ways to supply zstd, chosen at compile time:
 *
 *   default            link the system libzstd (`#include <zstd.h>`). Used by the
 *                      dev build and the build-time packer, which need to compress.
 *   -DUNPIN_ZSTD_VENDORED
 *                      compile zstd's decompress-only amalgamation (zstddeclib.c)
 *                      straight into this TU, so the shipped single-binary carries
 *                      zstd with no runtime closure. Decompress-only, so the
 *                      compress helpers are forced off.
 *
 * Either way miniz only ever calls the four unpin_zstd_* functions below; the
 * choice never reaches the container reader.
 *
 * Contexts are created lazily and reused; they are not thread-safe, which
 * matches the VFS (single-threaded init/open path). The shared dictionary is a
 * raw zstd dictionary (from `zstd --train`), applied via the *_usingDict APIs.
 */
#include "unpin_zstd.h"
#ifdef UNPIN_ZSTD_VENDORED
#  define UNPIN_ZSTD_NO_COMPRESS          /* the amalgamation decodes only */
#  include "zstddeclib.c"                 /* brings in zstd.h + the impl, one TU */
#else
#  include <zstd.h>
#endif

static const void *g_dict;
static size_t g_dict_len;

void unpin_zstd_set_dict(const void *dict, size_t dictlen) {
    g_dict = dict;
    g_dict_len = dictlen;
}

size_t unpin_zstd_decompress(void *dst, size_t dstcap, const void *src, size_t srclen) {
    static ZSTD_DCtx *dctx;
    if (!dctx) {
        dctx = ZSTD_createDCtx();
        if (!dctx) return 0;
    }
    size_t r = g_dict
        ? ZSTD_decompress_usingDict(dctx, dst, dstcap, src, srclen, g_dict, g_dict_len)
        : ZSTD_decompressDCtx(dctx, dst, dstcap, src, srclen);
    return ZSTD_isError(r) ? 0 : r;
}

#ifndef UNPIN_ZSTD_NO_COMPRESS
size_t unpin_zstd_bound(size_t srclen) {
    return ZSTD_compressBound(srclen);
}

size_t unpin_zstd_compress(void *dst, size_t dstcap, const void *src, size_t srclen, int level) {
    static ZSTD_CCtx *cctx;
    if (!cctx) {
        cctx = ZSTD_createCCtx();
        if (!cctx) return 0;
    }
    size_t r = g_dict
        ? ZSTD_compress_usingDict(cctx, dst, dstcap, src, srclen, g_dict, g_dict_len, level)
        : ZSTD_compressCCtx(cctx, dst, dstcap, src, srclen, level);
    return ZSTD_isError(r) ? 0 : r;
}
#endif /* UNPIN_ZSTD_NO_COMPRESS */
