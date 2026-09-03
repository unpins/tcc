/* The rename binding, on Windows.
 *
 * vfs.c's _WIN32 half offers two `--wrap` bindings and an explicit
 * unpin_vfs_* API, but no NOWRAP mode: the rename binding the engine uses on
 * linux and darwin (tcc's own open() rewritten in the IR to unpinvfs_open by
 * lib.vfsBindFns) has no implementation there. Supply it here rather than
 * carry a linker-global --wrap into a foldable module: it would reroute every
 * other applet's open() in the mega.
 *
 * unpinvfs_open IS the explicit API. __real_open is the pass-through vfs.c's
 * __wrap_open delegates to, which only `ld --wrap=open` would otherwise
 * define — here it is the plain CRT open. This TU is never renamed (vfsSed
 * touches the eight backend objects only), so _open below is genuine.
 */
#include <fcntl.h>
#include <io.h>
#include <stdarg.h>

int unpin_vfs_open(const char *path, int flags, ...);

int __real_open(const char *path, int oflag, ...) {
    if (oflag & _O_CREAT) {
        va_list ap; va_start(ap, oflag); int m = va_arg(ap, int); va_end(ap);
        return _open(path, oflag, m);
    }
    return _open(path, oflag);
}

int unpinvfs_open(const char *path, int oflag, ...) {
    if (oflag & _O_CREAT) {
        va_list ap; va_start(ap, oflag); int m = va_arg(ap, int); va_end(ap);
        return unpin_vfs_open(path, oflag, m);
    }
    return unpin_vfs_open(path, oflag);
}
