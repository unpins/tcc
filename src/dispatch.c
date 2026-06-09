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
 * Target on the command line. Names follow the project's arch-os convention —
 * the exact spellings of the nix systems and release assets, and the ONLY ones
 * accepted (no abbreviations or alternative spellings):
 *   default (no flag) ............ native x86_64 ELF
 *   -target=x86_64-linux ......... x86_64 ELF
 *   -target=i686-linux ........... i686 ELF (runs here under IA32 emulation)
 *   -target=armv7l-linux ......... armv7l (eabihf) ELF
 *   -target=aarch64-linux ........ aarch64 ELF
 *   -target=riscv64-linux ........ riscv64 ELF
 *   -target=x86_64-windows ....... x86_64 PE (.exe)
 *   -target=x86_64-darwin ........ x86_64 macOS Mach-O
 *   -target=aarch64-darwin ....... aarch64 macOS Mach-O
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
    { "x86_64-linux",   x86_64_main     },
    { "i686-linux",     i386_main       },
    { "armv7l-linux",   arm_main        },
    { "aarch64-linux",  arm64_main      },
    { "riscv64-linux",  riscv64_main    },
    { "x86_64-windows", win32_main      }, /* x86_64 Windows (PE) */
    { "x86_64-darwin",  x86_64_osx_main }, /* x86_64 macOS (Mach-O) */
    { "aarch64-darwin", arm64_osx_main  }, /* aarch64 macOS (Mach-O) */
};

static entry_t resolve(const char *name)
{
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
        if (!strncmp(a, "-target=", 8)) {
            entry_t e = resolve(a + 8);
            if (!e) {
                fprintf(stderr,
                    "tcc: error: unknown -target '%s' (x86_64-linux i686-linux "
                    "armv7l-linux aarch64-linux riscv64-linux x86_64-windows "
                    "x86_64-darwin aarch64-darwin)\n",
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
