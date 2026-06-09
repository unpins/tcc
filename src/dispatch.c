/* tcc dispatcher: ONE binary, EIGHT backends, ONE process.
 *
 * tcc compiles exactly one codegen backend per executable (libtcc.c #includes a
 * single *-gen.c), so each target is a complete compile of tcc. With ONE_SOURCE
 * the whole compiler is one object whose only GLOBAL symbols are the ~34 libtcc
 * public-API functions plus main() (everything else is file-static), so the
 * eight objects are made collision-free by prefixing those globals per target
 * with `objcopy --redefine-syms` (main -> x86_64_main / i386_main / arm_main /
 * arm64_main / riscv64_main / win32_main / x86_64_osx_main / arm64_osx_main).
 * All are linked into this one binary; the dispatcher just CALLS the right entry
 * in-process -- no child process, no fexecve, one libc, one VFS. Each target's
 * sysroot lives in its own /zip/<target>/ subtree, served by a shared
 * --wrap=open VFS.
 *
 * Target on the command line:
 *   default (no flag) ........... native x86_64 ELF
 *   -m64  / -target=x86_64 ...... x86_64 ELF
 *   -m32  / -target=i386 ........ i386 ELF (runs here under IA32 emulation)
 *   -target=arm   (armv7l) ...... arm (eabihf) ELF
 *   -target=arm64 (aarch64) ..... arm64 ELF
 *   -target=riscv64 ............. riscv64 ELF
 *   -target=windows (win32) ..... x86_64 PE (.exe)
 *   -target=x86_64-osx .......... x86_64 macOS Mach-O   (aka x86_64-darwin)
 *   -target=arm64-osx ........... arm64  macOS Mach-O   (aka aarch64-darwin)
 * The selecting flag is consumed here and not forwarded (each backend is
 * already single-target). An unknown -target=<x> is a hard error.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern int x86_64_main(int, char **);
extern int i386_main(int, char **);
extern int arm_main(int, char **);
extern int arm64_main(int, char **);
extern int riscv64_main(int, char **);
extern int win32_main(int, char **);
extern int x86_64_osx_main(int, char **);
extern int arm64_osx_main(int, char **);

typedef int (*entry_t)(int, char **);

struct backend { const char *name; entry_t fn; };

static const struct backend backends[] = {
    { "x86_64",     x86_64_main     },
    { "i386",       i386_main       },
    { "arm",        arm_main        },
    { "arm64",      arm64_main      },
    { "riscv64",    riscv64_main    },
    { "windows",    win32_main      },
    { "x86_64-osx", x86_64_osx_main }, /* x86_64 macOS (Mach-O) */
    { "arm64-osx",  arm64_osx_main  }, /* arm64  macOS (Mach-O) */
};

/* user-facing alias -> canonical backend name */
struct alias { const char *from, *to; };
static const struct alias aliases[] = {
    { "x86-64",       "x86_64"  },
    { "amd64",        "x86_64"  },
    { "i686",         "i386"    },
    { "x86",          "i386"    },
    { "armv7l",       "arm"     },
    { "armhf",        "arm"     },
    { "aarch64",      "arm64"   },
    { "win32",        "windows" },
    { "x86_64-win32", "windows" },
    { "mingw",        "windows" },
    { "pe",           "windows" },
    /* macOS: accept the catalog/system spellings (arch-os and os-arch). */
    { "x86_64-darwin",  "x86_64-osx" },
    { "x86_64-macos",   "x86_64-osx" },
    { "darwin-x86_64",  "x86_64-osx" },
    { "arm64-darwin",   "arm64-osx"  },
    { "aarch64-darwin", "arm64-osx"  },
    { "aarch64-osx",    "arm64-osx"  },
    { "arm64-macos",    "arm64-osx"  },
    { "darwin-arm64",   "arm64-osx"  },
};

static entry_t resolve(const char *name)
{
    for (size_t i = 0; i < sizeof aliases / sizeof *aliases; i++)
        if (!strcmp(name, aliases[i].from)) { name = aliases[i].to; break; }
    for (size_t i = 0; i < sizeof backends / sizeof *backends; i++)
        if (!strcmp(name, backends[i].name)) return backends[i].fn;
    return NULL;
}

int main(int argc, char **argv)
{
    entry_t entry = x86_64_main; /* native default */

    char **out = calloc((size_t)argc + 1, sizeof *out);
    if (!out) return 1;
    int oi = 0;
    out[oi++] = argv[0];
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "-m64")) { entry = x86_64_main; continue; }
        if (!strcmp(a, "-m32")) { entry = i386_main;   continue; }
        if (!strncmp(a, "-target=", 8)) {
            entry_t e = resolve(a + 8);
            if (!e) {
                fprintf(stderr,
                    "tcc: error: unknown -target '%s' "
                    "(x86_64 i386 arm arm64 riscv64 windows x86_64-osx arm64-osx)\n",
                    a + 8);
                free(out);
                return 1;
            }
            entry = e;
            continue;
        }
        out[oi++] = argv[i];
    }
    out[oi] = NULL;
    return entry(oi, out);
}
