# The multi-target tcc: ONE binary that compiles C to eight targets — five Linux
# ELF archs (x86_64, i386, arm/eabihf, arm64, riscv64), x86_64 Windows PE, and
# x86_64/arm64 macOS Mach-O — in the same process.
#
# tcc is one-backend-per-binary (libtcc.c #includes a single *-gen.c), so each
# target is a full ONE_SOURCE compile of tcc (`<t>-tcc.o` = the whole compiler
# in one object). Its only GLOBAL symbols are the ~34 libtcc public-API functions
# plus main(); everything else is file-static. We prefix those globals per target
# with `objcopy --redefine-syms` (main -> x86_64_main / win32_main / …), link all
# eight prefixed objects + src/dispatch.c into one executable, and the dispatcher
# CALLS the selected backend in-process — no fexecve, one libc, one VFS. Each
# target's sysroot (libc headers + crt + libc.a) lives in its own /zip/<target>/
# subtree, all served by one --wrap=open VFS (src/vfs_miniz.c), so the single
# file compiles AND links real C with nothing on disk.
#
# `pkgs` is the HOST pkgs set — the system the binary itself runs on.
# mkStandaloneFlake hands a different one per catalog system (native, a musl
# cross set for the other Linux archs, a darwin set; flake.nix's windowsBuild
# supplies the mingw set). Everything branches on the host's executable FORMAT
# (ELF / PE / Mach-O), the only axis that changes the blob, the VFS binding and
# the link tail; the eight TARGETS are identical everywhere.
#
# build-host vs host: generating each libtcc1.a means RUNNING tcc at build time,
# so the `<t>-tcc` tools build with the build-host cc (`pkgs.buildPackages`) and
# run here, while each `<t>-tcc.o` is recompiled with the host cc (`$CC`), since
# it carries the compiler logic that runs on the host. The embedded Linux sysroots
# are likewise built here from source (see mkSysroot) — never fetched-only — so a
# cold `nix build` reproduces them on any host, macOS included, with no per-target
# gcc and no dependence on a warm cache.
pkgs:
let
  lib = pkgs.lib;
  hostPlat = pkgs.stdenv.hostPlatform;
  isWin = hostPlat.isWindows;
  isDarwin = hostPlat.isDarwin;

  # Host stdenv. Linux AND macOS go through pkgsStatic, where mkStandaloneFlake's
  # unpin-llvm engine swap lives (it activates for any isStatic||isMusl host) — so
  # `$CC` is the engine clang and every host object comes out as LLVM bitcode, the
  # prerequisite for the bitcode-LTO multicall module. On Linux that yields a fully
  # static-musl binary; on macOS pkgsStatic is "soft static" (static libc++ +
  # compiler-rt, libSystem still dynamic — a darwin host can't fully static-link),
  # exactly the convention grep & every other engine package uses. Windows keeps
  # its plain mingw cross set (off-engine; the PE folds the crt via -static below).
  # `hp` also carries the build-host toolchain via `.buildPackages`.
  hp = if isWin then pkgs else pkgs.pkgsStatic;
  hostStdenv = hp.stdenv;
  buildCC_cc = hp.buildPackages.stdenv.cc;
  # buildCC builds tcc's BUILD-TIME tools (c2str + the eight cross-tccs that run
  # here to emit each libtcc1.a) — the vanilla build-host clang, never the engine.
  # On a NATIVE darwin build (build == host), the engine's bare `ld` (ELF lld)
  # shadows this cc's cctools ld64 on PATH because build & host share the same
  # apple-darwin salt (the linux salt-separation collapses) → a build-time LINK
  # sends ld64 args (-arch/-syslibroot/…) to ELF lld, which rejects them. Pin to
  # the real cctools ld64 with --ld-path (only on link steps, so compiles don't
  # warn) via a 1-line wrapper — a single token that drops cleanly into
  # `--cc=`/`CC=`. Mirrors nix-lib's unpinBashBuildFix. Only on native darwin: in a
  # cross (e.g. x86_64→aarch64 darwin) the salts differ so the build cc's ld64 is
  # never shadowed, and writeShellScript would resolve a wrong-platform bash. Inert
  # on linux. CI builds BOTH darwin arches natively, so each gets the wrapper.
  isNativeDarwin =
    isDarwin && pkgs.stdenv.buildPlatform.system == pkgs.stdenv.hostPlatform.system;
  buildCC =
    if isNativeDarwin
    then "${pkgs.buildPackages.writeShellScript "tcc-build-cc" ''
      for a in "$@"; do case "$a" in -c|-E|-S) exec ${buildCC_cc}/bin/cc "$@" ;; esac; done
      exec ${buildCC_cc}/bin/cc --ld-path=${buildCC_cc.bintools.bintools}/bin/ld "$@"
    ''}"
    else "${buildCC_cc}/bin/cc";
  buildAR = "${buildCC_cc.bintools.bintools}/bin/ar";

  # A pkgs native to the BUILD machine — darwin included, never a foreign system a
  # host can't build. tinycc's source/man and the per-target sysroots (mkSysroot)
  # are taken/cross-built from here, so every runner (x86_64/arm Linux, the Linux
  # build host of the Windows cross, and macOS) produces them from source.
  linuxPkgs = import pkgs.path { system = pkgs.stdenv.buildPlatform.system; };
  inherit (linuxPkgs.tinycc) src version;

  # Symbol-table tools. A Mach-O host renames symbols with --redefine-sym(s),
  # which cctools' nm/objcopy can't do but LLVM's can; ELF/PE use stdenv binutils.
  llvmBin = "${hp.buildPackages.llvm}/bin";
  nmBin = if isDarwin then "${llvmBin}/llvm-nm" else "$NM";
  objcopyBin = if isDarwin then "${llvmBin}/llvm-objcopy" else "$OBJCOPY";
  binName = if isWin then "tcc.exe" else "tcc";

  # Each Linux target's sysroot (libc headers + crt + libc.a) is built HERE by one
  # multi-target clang compiling musl from source — the zig-cc model. tcc itself
  # can't build musl (no _Complex, only partial inline-asm/constraint support), and
  # gcc would mean a full cross-gcc toolchain PER target (~30 min each, darwin
  # included); clang is a single toolchain that retargets via --target=, so all
  # five share it. The per-arch kernel UAPI headers (linux/, asm/, …) come from
  # linuxHeaders — pure data, no compiler. The derivation runs on the build host
  # and emits target machine code, so every host (Linux, the Windows cross's Linux
  # build host, and macOS) produces real libc.a from source with no per-target gcc.
  mkSysroot = { cross }:
    let cp = linuxPkgs.pkgsCross.${cross};
        triple = cp.stdenv.hostPlatform.config;
    in linuxPkgs.stdenv.mkDerivation {
      pname = "tcc-musl-sysroot-${triple}";
      inherit (cp.musl) version src;
      nativeBuildInputs = [ linuxPkgs.llvmPackages.clang-unwrapped linuxPkgs.llvm ];
      dontConfigure = true;
      # tcc's archive reader only understands a GNU `ar` (the symbol index is the
      # member named `/`; tcc_load_alacarte fires on that name alone). A BSD/Darwin
      # archive (first member `#1/20`, index `__.SYMDEF`) is opened and walked but
      # NO member is ever pulled, so every libc symbol — first `__libc_start_main`,
      # referenced by crt1.o — comes up undefined. On a macOS build host TWO things
      # try to hand tcc a BSD archive, and BOTH must be defeated:
      #   1. llvm-ar defaults to the build host's native format (BSD on darwin), so
      #      `make` itself would write a BSD libc.a -> AR="llvm-ar --format=gnu".
      #   2. nixpkgs' fixup strip phase re-archives every .a through cctools strip,
      #      which rewrites the (now GNU) libc.a back to BSD -> dontStrip. (musl is
      #      built without -g, so there is nothing to strip anyway.)
      # Both are no-ops on a Linux host (already GNU, GNU strip preserves it).
      dontStrip = true;
      buildPhase = ''
        runHook preBuild
        CC="clang --target=${triple}" AR="llvm-ar --format=gnu" RANLIB=llvm-ranlib \
          ./configure --target=${triple} --disable-shared --prefix=/
        make -j''${NIX_BUILD_CORES:-1}
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        make install DESTDIR=$out prefix=/
        cp -aL ${cp.linuxHeaders}/include/. $out/include/   # kernel UAPI (per-arch)
        chmod -R u+w $out/include
        runHook postInstall
      '';
      # Guard the invariant tcc depends on: libc.a MUST stay a GNU archive (its
      # 9th byte — first of member 1's name — is `/`, not `#`). Runs after fixup,
      # so it catches any future host/strip regression that flips the format.
      postFixup = ''
        b=$(od -An -c -j8 -N1 $out/lib/libc.a | tr -d ' \n')
        [ "$b" = "/" ] || { echo "ERROR: $out/lib/libc.a is not a GNU archive (byte8='$b'); tcc cannot read it"; exit 1; }
      '';
    };

  # Targets. `t` = tcc make-target / /zip subtree name; `g` = the C symbol tag
  # (objcopy prefix + dispatch.c extern); `sysroot` = the clang-built musl tree
  # (`/include` + `/lib`) supplying that ELF target's headers + crt*.o + libc.a.
  # All five — riscv64 included — link clean once tcc's RISC-V reloc handler is
  # taught clang's hoisted hi/lo scheme (the riscv64-link.c patch in commonPatch).
  linuxTargets = map (e: e // { sysroot = mkSysroot { inherit (e) cross; }; }) [
    { t = "x86_64";  g = "x86_64";  cross = "musl64"; }
    { t = "i386";    g = "i386";    cross = "musl32"; }
    { t = "arm";     g = "arm";     cross = "armv7l-hf-multiplatform"; }
    { t = "arm64";   g = "arm64";   cross = "aarch64-multiplatform-musl"; }
    { t = "riscv64"; g = "riscv64"; cross = "riscv64-musl"; }
  ];
  # Windows (PE): a Linux ELF tcc that emits x86_64 PE; its sysroot is the
  # in-tree win32/ mingw headers + .def import descriptors + a PE libtcc1.a (crt
  # folded in), not a musl tree.
  winT = "x86_64-win32";
  winG = "win32";
  # macOS (Mach-O): Linux ELF tccs that emit x86_64/arm64 Mach-O. tcc's macho
  # backend needs ZERO source patches, and CONFIG_NEW_MACHO defaults to 1 in
  # tcc.h unconditionally (configure only ever disables it), so a Linux-built
  # cross-tcc emits modern chained-fixups Mach-O exactly like a Mac-built one.
  osxTargets = [
    { t = "x86_64-osx"; g = "x86_64_osx"; }
    { t = "arm64-osx";  g = "arm64_osx";  }
  ];
  allTargets = map (e: e.t) linuxTargets ++ [ winT ] ++ map (e: e.t) osxTargets;
  isOsx = lib.hasSuffix "-osx";

  # apple-sdk gives the macOS C headers (no /usr/include since 10.14) +
  # libSystem.tbd for the embedded /zip/osx cross sysroot. Reach it from any host
  # by re-instantiating nixpkgs for darwin (eval-only; the SDK substitutes from
  # cache). Both osx arches SHARE one /zip/osx tier — the SDK headers are
  # byte-identical across arches and libSystem.tbd is a multi-arch stub; only the
  # per-arch libtcc1.a differs. This is the NATIVE (non-static) apple-sdk on
  # purpose: `hp` is pkgsStatic on darwin, and `hp.apple-sdk` would be the
  # apple-sdk-STATIC variant, whose Csu (crt) rebuild trips the engine's ld64.lld
  # (no `ld -r`). The host's OWN SDK (for compiling the dispatcher + linking
  # libSystem) is NOT needed as a buildInput: the engine darwin stdenv exports
  # SDKROOT (-> the native apple-sdk) and `$CC` honours it as -isysroot, exactly
  # like grep & every other engine package — so there is no apple-sdk buildInput.
  sdkRoot = (import pkgs.path { system = "aarch64-darwin"; }).apple-sdk.sdkroot;

  # The host's executable format drives three knobs; vfs_miniz.c mirrors the same
  # three #if branches, so the blob symbol names must match the OS exactly:
  #   ELF (Linux)    _binary_incblob_* ; the engine renames open/stat/… to
  #                  unpinvfs_* in the IR (prefix() below) ; -static musl.
  #   PE (Windows)   incblob_* ; mingw is off-engine, so `ld --wrap=open` reroutes
  #                  (tcc reads every input via open(), never stat()s) ; -static
  #                  folds the crt.
  #   Mach-O (macOS) _incblob_* ; on the engine the VFS binds the same way as Linux
  #                  (the IR rename), and the blob is emitted as a BITCODE object
  #                  via module-level .incbin (see the link step) rather than this
  #                  native `.S` ; dynamic against libSystem. (blobAsm's Mach-O case
  #                  below is only for a hypothetical off-engine darwin.)
  blobAsm =
    if isWin then ''
      .section .rodata
      .global incblob_start
      .global incblob_end
      incblob_start:
      .incbin "incblob"
      incblob_end:
    ''
    else if isDarwin then ''
      .section __TEXT,__const
      .global _incblob_start
      .global _incblob_end
      _incblob_start:
      .incbin "incblob"
      _incblob_end:
    ''
    else ''
      .section .rodata
      .global _binary_incblob_start
      .global _binary_incblob_end
      _binary_incblob_start:
      .incbin "incblob"
      _binary_incblob_end:
      # `@` starts a comment on 32-bit ARM, so spell the note type %progbits there.
      .section .note.GNU-stack,"",${if hostPlat.isAarch32 then "%" else "@"}progbits
    '';
  staticFlag = if isDarwin then "" else "-static";
  wrapFlags =
    if isWin then "-Wl,--wrap=open"
    else if isDarwin then ""
    else "-Wl,--wrap=open,--wrap=stat,--wrap=lstat,--wrap=access";
  linkLibs = if isDarwin || isWin then "-lm" else "-lm -ldl -lpthread";

  # tcc splits CONFIG_TCC_LIBPATHS / SYSINCLUDEPATHS on PATHSEP — `;` on a
  # Windows host, `:` elsewhere (tcc.h). Every backend runs on the SAME host, so
  # the baked dir LISTS must use the host's separator, or a Windows host reads
  # the whole list as one bogus path. (CRT-<t> is a single dir, never a list, so
  # it always resolved — which is why only -lc / libtcc1 / <header> search broke.)
  ps = if isWin then ";" else ":";
  # win32's mingw headers split the Win32 API into include/winapi, so the PE
  # backend's include path carries both dirs (so a runtime `#include <windows.h>`
  # resolves). osx arches share /zip/osx for headers and libSystem.
  incPath = t:
    if t == winT then "/zip/${t}/include${ps}/zip/${t}/include/winapi"
    else if isOsx t then "/zip/osx/include"
    else "/zip/${t}/include${ps}/zip/common/include";
  pvLine = t:
    let
      crt = if isOsx t then "/zip/osx/lib" else "/zip/${t}/lib";
      libl =
        if isOsx t then "/zip/${t}/lib/tcc${ps}/zip/osx/lib"
        else "/zip/${t}/lib/tcc${ps}/zip/${t}/lib";
    in
    "CRT-${t}='${crt}' LIB-${t}='${libl}' INC-${t}='${incPath t}'"; # single-quote so a ';' sep isn't a shell terminator
  allPv = lib.concatMapStringsSep " " pvLine allTargets;

  # Source patches. Single-line --replace-fail anchors only (a multi-line search
  # pattern gets re-indented inside a Nix ''-string and fails to match; multi-line
  # replacements are fine — C is whitespace-insensitive). Each anchor occurs once.
  commonPatch = ''
    cp ${./src}/vfs_miniz.c ${./src}/miniz.c ${./src}/miniz.h .

    # i386: tcc emits a named local reloc for __udivmoddi4 — promote it to global.
    substituteInPlace lib/libtcc1.c \
      --replace-fail 'static UDWtype __udivmoddi4 ' 'UDWtype __udivmoddi4 '

    # arm: armeabi.c's __aeabi_mem* are fallbacks "for targets that do not have
    # all eabi calls" (its own comment), but musl's ARM port DEFINES them (strong).
    # Two strong defs collide the moment armeabi.o is pulled (for __aeabi_idivmod).
    # Make the fallbacks weak so musl's win when present and they still cover a
    # libc that lacks them. armeabi.c is compiled only for the arm backend.
    substituteInPlace lib/armeabi.c \
      --replace-fail '__aeabi_memcpy (void *dest, const void *src, size_t n)'   '__attribute__((weak)) __aeabi_memcpy (void *dest, const void *src, size_t n)' \
      --replace-fail '__aeabi_memmove (void *dest, const void *src, size_t n)'  '__attribute__((weak)) __aeabi_memmove (void *dest, const void *src, size_t n)' \
      --replace-fail '__aeabi_memmove4 (void *dest, const void *src, size_t n)' '__attribute__((weak)) __aeabi_memmove4 (void *dest, const void *src, size_t n)' \
      --replace-fail '__aeabi_memmove8 (void *dest, const void *src, size_t n)' '__attribute__((weak)) __aeabi_memmove8 (void *dest, const void *src, size_t n)' \
      --replace-fail '__aeabi_memset (void *s, size_t n, int c)'                '__attribute__((weak)) __aeabi_memset (void *s, size_t n, int c)'

    # Default to portable static executables — but NOT for PE/Mach-O, which have
    # no static libc (a PE links msvcrt.dll, a Mach-O links libSystem).
    substituteInPlace libtcc.c \
      --replace-fail 'tcc_set_lib_path(s, CONFIG_TCCDIR);' '
    #if !defined TCC_TARGET_PE && !defined TCC_TARGET_MACHO
        s->static_link = 1;
    #endif
        tcc_set_lib_path(s, CONFIG_TCCDIR);'

    # Re-scan libc after libtcc1 (ELF static circular dep: printf <-> __udivdi3).
    # Skipped for Mach-O — it is dynamic, so a second libc would only duplicate
    # the libSystem load command.
    substituteInPlace tccelf.c \
      --replace-fail 'tcc_add_support(s1, TCC_LIBTCC1);' 'tcc_add_support(s1, TCC_LIBTCC1);
    #ifndef TCC_TARGET_MACHO
        tcc_add_library(s1, "c");
    #endif'

    # i386: relocate the PLT for static EXEs (no PC32 collapse on i386).
    substituteInPlace tccelf.c \
      --replace-fail 'relocate_syms(s1, s1->symtab, 0);' 'if (!dynamic && s1->plt && file_type == TCC_OUTPUT_EXE) relocate_plt(s1); relocate_syms(s1, s1->symtab, 0);'

    # riscv64: tcc pairs PCREL_HI20/LO12 through a single `last_hi` slot, assuming
    # the relocs alternate HI,LO,HI,LO (as gcc emits). clang hoists/coalesces the
    # `auipc`s — several HI20 before their LO12, one HI20 shared by several LO12 —
    # so `last_hi` is the wrong HI by the time a LO12 arrives ("unsupported hi/lo
    # pcrel reloc scheme"). Record every HI20 in a table and, on each LO12, refresh
    # last_hi from the HI at address `val` (the LO12's target). A strict superset of
    # the old behaviour: gcc's paired relocs still resolve. Needed so the riscv64
    # backend links clang-built musl — keeping every target on the single clang.
    substituteInPlace riscv64-link.c \
      --replace-fail 'ST_FUNC void relocate(TCCState *s1, ElfW_Rel *rel, int type, unsigned char *ptr,' '
    static struct pcrel_hi *rv_his; static int rv_his_n;
    static void rv_rec_hi(addr_t a, addr_t v){ rv_his = tcc_realloc(rv_his, (rv_his_n+1)*sizeof(*rv_his)); rv_his[rv_his_n].addr = a; rv_his[rv_his_n].val = v; rv_his_n++; }
    static int rv_find_hi(addr_t a){ int i; for (i = rv_his_n; --i >= 0; ) if (rv_his[i].addr == a) return i; return -1; }
    ST_FUNC void relocate(TCCState *s1, ElfW_Rel *rel, int type, unsigned char *ptr,' \
      --replace-fail 'last_hi.val = val;' 'last_hi.val = val; rv_rec_hi(addr, val);' \
      --replace-fail 'if (val != last_hi.addr)' '{ int rvi = rv_find_hi(val); if (rvi >= 0) last_hi = rv_his[rvi]; } if (val != last_hi.addr)'

    # libtcc1 is built by RUNNING each cross-tcc on the build host. tcc emits a
    # long double CONSTANT by copying the host long double's bytes, which only
    # works when the host long double is at least as wide as the target's
    # (LDOUBLE_SIZE). On an aarch64-macOS build host long double is 64-bit, so for
    # every target whose LDOUBLE_SIZE > 8 (x86_64/i386/arm64/riscv64 and x86_64-osx)
    # tcc aborts libtcc1.c with "can't cross compile long double constants". The
    # ONLY long double constant in libtcc1.c / lib-arm64.c is the implicit 0.0L of
    # comparisons like `a1 >= 0` (verified: no other float-suffixed or negative-zero
    # long double literal exists), and 0.0L is all-zero bytes on every target. So
    # teach that path to recognise a zero value and write LDOUBLE_SIZE zero bytes
    # rather than memcmp the (narrower) host bytes; any future NON-zero constant
    # still hits the original error, loudly, instead of silently corrupting. This
    # keeps libtcc1 fully tcc-built (correct codegen) on every host — clang can't
    # substitute: tcc's i386 static linker mishandles clang's constant-pool relocs.
    substituteInPlace tccgen.c \
      --replace-fail 'else if (0 == memcmp(ptr, &vtop->c.ld, LDOUBLE_SIZE))' 'else if (vtop->c.ld == 0.0)' \
      --replace-fail '; /* nothing to do for 0.0 */' 'memset(ptr, 0, LDOUBLE_SIZE); /* 0.0L is all-zero on every target; host long double may be narrower */'
  '';
in
hostStdenv.mkDerivation {
  pname = "tcc";
  inherit version src;
  # zip/which run at build time → build-host tools (native in a cross build).
  # perl (+ its pod2man) generates tcc.1 from tcc-doc.texi in-tree; zip/which run
  # at build time. All build-host tools (native in a cross build).
  nativeBuildInputs = [ pkgs.buildPackages.zip pkgs.buildPackages.which pkgs.buildPackages.perl ];
  # No buildInputs: the host SDK (libSystem + libc headers) reaches darwin via the
  # engine stdenv's SDKROOT, and the embedded /zip/osx tier comes from sdkRoot.
  postPatch = commonPatch;

  # configure with the BUILD-host cc: ./configure builds c2str (run at build
  # time) and probes the build compiler. The host cc enters only at the recompile
  # + final link.
  configurePhase = ''
    runHook preConfigure
    ./configure --cc=${buildCC} --ar=${buildAR}
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    J=-j''${NIX_BUILD_CORES:-1}

    # The unpin-llvm engine compiles every host object to LLVM BITCODE (it
    # appends -flto), the prerequisite for folding tcc into the bitcode-LTO
    # unpinbox mega. objcopy can't rename symbols in bitcode, and the mega link
    # can't carry tcc's per-package `--wrap`, so on the engine we bind the VFS
    # and de-collide the eight backends by REWRITING IR symbols instead (see the
    # prefix() ENGINE branch + -DUNPIN_VFS_NOWRAP below). Off the engine (the
    # mingw Windows cross, or a plain gcc build) keep the objcopy + --wrap path.
    # Probe rather than trust a platform flag, so a future off-engine build is
    # handled correctly. $MT is the engine multitool (opt/llvm-as), reached via
    # the cc-wrapper's objcopy symlink (-> ''${toolchain}/bin/llvm). The probe
    # accepts BOTH bitcode magics the engine emits: raw `4243c0de` (linux) and
    # its wrapper `dec0170b` (darwin wraps the bitcode in a thin header), matching
    # the engine's own _unpin_natkind classifier — without the wrapper case the
    # darwin build false-negatives to the objcopy path and the renamed mains come
    # out wrong (`ld: _x86_64_main not found`).
    echo 'int _unpin_probe(void){return 0;}' > _probe.c
    $CC -c _probe.c -o _probe.o 2>/dev/null || true
    case "$(od -An -tx1 -N4 _probe.o 2>/dev/null | tr -d ' \n')" in
      4243c0de|dec0170b) ENGINE=1 ;;
      *) ENGINE=0 ;;
    esac
    if [ "$ENGINE" = 1 ]; then
      # The engine multitool (opt/internalize live here, as `<llvm> opt …`). The
      # adapter exposes nm/objcopy/ld.lld as SHELL SCRIPTS that `exec
      # <toolchain>/bin/llvm <subcmd> "$@"` (not symlinks, and $OBJCOPY is a
      # standalone llvm-objcopy), so neither readlink nor a subcommand-less
      # invocation reaches the bare driver. Recover its path by grepping the
      # `/bin/llvm` literal out of one of those wrapper scripts — or, on darwin
      # where nm/objcopy may be cctools, out of the cc/opt wrapper itself.
      MT=""
      for __c in nm objcopy "$NM" "$OBJCOPY" "$CC" cc clang opt; do
        __f=$(readlink -f "$(command -v "$__c" 2>/dev/null)" 2>/dev/null) || continue
        [ -f "$__f" ] || continue
        __p=$(grep -aoE '/nix/store/[^ "]*/bin/llvm' "$__f" 2>/dev/null | head -1) || true
        [ -n "$__p" ] && { MT=$__p; break; }
      done
      [ -n "$MT" ] || { echo "tcc multi.nix: could not locate the engine llvm multitool" >&2; exit 1; }
      VFSDEF=-DUNPIN_VFS_NOWRAP
      WRAPFLAGS=""
    else
      ENGINE=0
      VFSDEF=""
      WRAPFLAGS="${wrapFlags}"
    fi
    echo "ENGINE=$ENGINE MT=''${MT:-} VFSDEF=$VFSDEF"

    echo "=== build the eight ONE_SOURCE cross-compilers (build-host cc; run here) ==="
    make ${lib.concatMapStringsSep " " (t: "${t}-tcc") allTargets} $J ${allPv} CC=${buildCC}

    echo "=== build each libtcc1.a by running its cross-tcc ==="
    # XCC defaults to the target's cross-tcc → correct codegen, incl. arm's
    # armeabi.c divmod trick that gcc -O2 would miscompile. Each cross-tcc's baked
    # absolute INC-<t> dropped the {B}/include default, so feed the headers via
    # C_INCLUDE_PATH (musl per arch; in-tree mingw for PE; the SDK for osx).
    ${lib.concatMapStringsSep "\n    " (e:
      "C_INCLUDE_PATH=${e.sysroot}/include make ${e.t}-libtcc1.a $J ${pvLine e.t}"
    ) linuxTargets}
    C_INCLUDE_PATH=$(pwd)/win32/include:$(pwd)/win32/include/winapi make ${winT}-libtcc1.a $J ${pvLine winT}
    ${lib.concatMapStringsSep "\n    " (e:
      "C_INCLUDE_PATH=${sdkRoot}/usr/include make ${e.t}-libtcc1.a $J ${pvLine e.t}"
    ) osxTargets}

    echo "=== recompile every <t>-tcc.o for the host (${hostPlat.system}; \$CC) ==="
    # The objects above are build-host; the shipped binary runs on the host, so
    # its compiler logic must be host-arch. The ONE_SOURCE object only compiles
    # correctly through the `%-tcc` rule (it sets the right DEF-<t>/CONFIG_TCC_*
    # defines), whose object recipe has no FORCE — so rm the build-host .o first.
    # `CC="$CC"` (the make command line wins over config.mak's build cc, which
    # ./configure baked in); a wrong cc would fail the final link below. touch
    # tccdefs_.h so make won't regenerate it with the build-only c2str. -k so a
    # wasted host-executable relink can't abort the run — we only want the .o.
    touch tccdefs_.h 2>/dev/null || true
    rm -f *-tcc.o
    make -k ${lib.concatMapStringsSep " " (t: "${t}-tcc") allTargets} $J ${allPv} CC="$CC" || true
    echo "host objects:"; file ${lib.concatMapStringsSep " " (t: "${t}-tcc.o") allTargets}

    echo "=== prefix every defined global per target (collision-free in-process) ==="
    # Each backend is the SAME ONE_SOURCE compile, so all eight define `main` +
    # the ~34 libtcc API globals identically. To link them into one binary every
    # backend's globals must be made unique, and each backend's open/stat/lstat/
    # access must reach the VFS.
    #
    # ENGINE (bitcode): rewrite IR symbols (opt -S -> sed on the .ll -> opt). The
    #   dispatcher calls eight distinct mains, so main -> <g>_main; the VFS binds
    #   by rename (mega-safe, no --wrap), so open/stat/lstat/access -> unpinvfs_*
    #   (incl. 32-bit musl's __stat_time64/__lstat_time64). Then opt -internalize
    #   localizes everything but <g>_main, so the eight backends' identical libtcc
    #   API globals can't collide at the fold. `@sym` is a FUNCTION symbol and a
    #   type is `%struct.sym` (different sigil), so renaming @stat never touches
    #   `struct stat`. The Mach-O `_` is added only at object emission, matching
    #   dispatch.c's externs. The libc IMPORT names differ by target, though:
    #   Linux IR names them plainly (`@open`, `@stat`), but darwin's SDK headers
    #   give them raw-symbol asm labels — `@"\01_open"`, and the 64-bit-inode
    #   `@"\01_stat$INODE64"` / `@"\01_lstat$INODE64"` — so the VFS rename needs a
    #   second set of rules for those, or the rename silently no-ops and LTO drops
    #   the now-unreferenced unpinvfs_* (tcc then reads the real FS, not /zip).
    #   Each rule that can't match a given target's IR is a harmless no-op there,
    #   so all rules run on every target and the Linux output stays byte-identical.
    # OFF-ENGINE (PE on the mingw Windows cross — the only off-engine host now;
    #   the awk underscore-strip branch and the _open rewrite below stay only for a
    #   hypothetical off-engine darwin): nm + objcopy --redefine-syms prefixes every
    #   defined global. On Mach-O every C symbol carries a leading underscore
    #   (main -> _main), so the rename inserts the tag AFTER it (_main ->
    #   _x86_64_osx_main) to match dispatch.c's (also-underscored) externs; ELF/PE
    #   have no leading underscore. The VFS binds with --wrap on PE; on Mach-O ld64
    #   has no --wrap, so a post-pass rewrites each object's _open import.
    prefix() {  # $1 = target stem   $2 = C symbol tag (g)
      if [ "$ENGINE" = 1 ]; then
        $MT opt -S $1-tcc.o -o $1.ll
        sed -i \
          -e 's/@main\b/@'"$2"'_main/g' \
          -e 's/@open\b/@unpinvfs_open/g' \
          -e 's/@stat\b/@unpinvfs_stat/g' \
          -e 's/@lstat\b/@unpinvfs_lstat/g' \
          -e 's/@access\b/@unpinvfs_access/g' \
          -e 's/@__stat_time64\b/@unpinvfs_stat/g' \
          -e 's/@__lstat_time64\b/@unpinvfs_lstat/g' \
          -e 's/@"\\01__stat_time64"/@unpinvfs_stat/g' \
          -e 's/@"\\01__lstat_time64"/@unpinvfs_lstat/g' \
          -e 's/@"\\01_open"/@unpinvfs_open/g' \
          -e 's/@"\\01_access"/@unpinvfs_access/g' \
          -e 's/@"\\01_stat\$INODE64"/@unpinvfs_stat/g' \
          -e 's/@"\\01_lstat\$INODE64"/@unpinvfs_lstat/g' \
          $1.ll
        $MT opt -passes=internalize -internalize-public-api-list="$2"_main $1.ll -o $2-pfx.o
      else
        ${nmBin} -g --defined-only $1-tcc.o | awk -v p=$2 ${
          if isDarwin
          then "'{s=$NF; sub(/^_/,\"\",s); print $NF, \"_\" p \"_\" s}'"
          else "'{print $NF, p\"_\"$NF}'"} > $2.map
        ${objcopyBin} --redefine-syms=$2.map $1-tcc.o $2-pfx.o
      fi
    }
    ${lib.concatMapStringsSep "\n    " (e: "prefix ${e.t} ${e.g}") (linuxTargets ++ osxTargets)}
    prefix ${winT} ${winG}
    ${lib.optionalString isDarwin ''
      # Mach-O VFS bind for an OFF-ENGINE darwin build (objcopy path): rewrite each
      # backend object's open() import to _unpinvfs_open. Dead on the engine — there
      # the sed pass already renamed @open -> @unpinvfs_open in the IR, and objcopy
      # can't touch bitcode anyway — so guard it on ENGINE=0. darwin now always goes
      # through the engine (pkgsStatic), so this only fires if that ever regresses.
      if [ "$ENGINE" = 0 ]; then
        for o in ${lib.concatMapStringsSep " " (e: "${e.g}-pfx.o") (linuxTargets ++ osxTargets)} ${winG}-pfx.o; do
          ${objcopyBin} --redefine-sym _open=_unpinvfs_open "$o"
        done
      fi
    ''}

    echo "=== assemble ONE zip with per-target sysroot subtrees ==="
    rm -rf zroot
    mkLinux() {  # $1=target  $2=sysroot (clang-built musl: include/ + lib/)
      mkdir -p zroot/$1/include zroot/$1/lib/tcc
      # cp -aL: dereference any symlink (the kernel UAPI may link into a
      # linux-headers store path) so the dedup pass sees real files to hoist.
      cp -aL $2/include/. zroot/$1/include/ && chmod -R u+w zroot/$1/include
      cp -af include/. zroot/$1/include/ && chmod -R u+w zroot/$1/include
      cp -a $2/lib/crt1.o $2/lib/crti.o $2/lib/crtn.o $2/lib/libc.a zroot/$1/lib/
      cp -a $1-libtcc1.a zroot/$1/lib/tcc/
    }
    ${lib.concatMapStringsSep "\n    " (e: "mkLinux ${e.t} ${e.sysroot}") linuxTargets}

    # win32 subtree: mingw headers + tcc intrinsics + .def + PE libtcc1.a.
    mkdir -p zroot/${winT}/include zroot/${winT}/lib/tcc
    cp -a win32/include/. zroot/${winT}/include/
    cp -a include/*.h     zroot/${winT}/include/
    cp -a win32/lib/*.def zroot/${winT}/lib/
    cp -a ${winT}-libtcc1.a zroot/${winT}/lib/tcc/

    # osx subtree (shared by both arches at /zip/osx): SDK C headers + tcc
    # intrinsics, and libSystem.tbd under every name tcc may resolve. The VFS
    # can't store symlinks, so dereference the SDK include tree; it has a few
    # self-cyclic links (ncurses/) that can't be, so swallow that nonzero exit and
    # chmod unconditionally (a chained && would leave the tree read-only and break
    # the tcc-header overwrite). Each arch's libtcc1.a goes in its own subtree.
    mkdir -p zroot/osx/include zroot/osx/lib
    cp -aL ${sdkRoot}/usr/include/. zroot/osx/include/ 2>/dev/null || true
    chmod -R u+w zroot/osx/include
    cp -a include/*.h zroot/osx/include/   # tcc's own intrinsics (va_arg/…) must win
    chmod -R u+w zroot/osx/include
    real=$(readlink -f ${sdkRoot}/usr/lib/libSystem.tbd)
    for n in libSystem libSystem.B libc libm libpthread libdl libinfo; do
      cp -a "$real" zroot/osx/lib/$n.tbd
    done
    ${lib.concatMapStringsSep "\n    " (e:
      "mkdir -p zroot/${e.t}/lib/tcc && cp -a ${e.t}-libtcc1.a zroot/${e.t}/lib/tcc/"
    ) osxTargets}
    chmod -R u+w zroot

    echo "=== Zig-style header dedup (src/dedup-headers.sh) ==="
    bash ${./src}/dedup-headers.sh zroot common ${lib.concatMapStringsSep " " (e: e.t) linuxTargets}

    ( cd zroot && zip -9 -X -r ../incblob . >/dev/null )
    [ -f incblob ] || mv incblob.zip incblob

    echo "=== blob + VFS + dispatcher → link ONE binary (host=${hostPlat.system}) ==="
    ${if isDarwin then ''
      # Darwin: emit the blob as a BITCODE object (engine `$CC` adds -flto), NOT a
      # native Mach-O `.S`. The engine bintools `ld` is hardcoded to ELF `ld.lld`,
      # which LTO-compiles darwin bitcode into Mach-O fine (so a pure-bitcode link
      # links clean — this is how grep links) but CANNOT read a pre-existing native
      # Mach-O object, and the multitool's `ld64.lld` LTO path falls back to ELF
      # mode when bitcode is mixed with one. Wrapping the `.incbin` in module-level
      # __asm__ keeps the blob in the bitcode so the whole link stays pure bitcode —
      # no linker override needed. The `.incbin` is resolved at LTO codegen (link
      # time); the link runs from this dir, so the RELATIVE `incblob` path resolves
      # and no build-sandbox path leaks into the bitcode.
      cat > blob.c <<'BLOBEOF'
__asm__(
".section __TEXT,__const\n"
".globl _incblob_start\n"
".globl _incblob_end\n"
"_incblob_start:\n"
".incbin \"incblob\"\n"
"_incblob_end:\n"
);
BLOBEOF
      $CC -O2 -c blob.c -o blob.o
    '' else ''
      cat > blob.S <<'BLOBEOF'
${blobAsm}
BLOBEOF
      $CC -c blob.S -o blob.o
    ''}
    $CC -O2 -c miniz.c -o miniz.o
    $CC -O2 -I. $VFSDEF -c vfs_miniz.c -o vfs_miniz.o
    $CC -O2 -c ${./src}/dispatch.c -o dispatch.o

    # One LTO link. On darwin everything is bitcode (blob included, above), so the
    # engine's ELF ld.lld LTO-compiles it straight to Mach-O — no linker override.
    $CC ${staticFlag} -o ${binName} dispatch.o \
      ${lib.concatMapStringsSep " " (e: "${e.g}-pfx.o") linuxTargets} ${winG}-pfx.o \
      ${lib.concatMapStringsSep " " (e: "${e.g}-pfx.o") osxTargets} \
      blob.o vfs_miniz.o miniz.o \
      $WRAPFLAGS ${linkLibs}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 ${binName} $out/bin/${binName}
    # Generate tcc.1 from the in-tree texinfo doc (perl + pod2man) — host-independent
    # roff built from source, so `unpin man tcc` works on every host (withMan embeds
    # it). Avoids pulling nixpkgs' tinycc just for its man output, whose darwin build
    # fails its own test suite.
    perl texi2pod.pl tcc-doc.texi tcc-doc.pod
    pod2man --section=1 --center="Tiny C Compiler" --release="tcc ${version}" tcc-doc.pod > tcc.1
    install -Dm644 tcc.1 $out/share/man/man1/tcc.1
    runHook postInstall
  '';

  meta = {
    description = "TinyCC that cross-compiles C to eight targets from one binary";
    homepage = "https://repo.or.cz/tinycc.git";
    license = lib.licenses.lgpl21Only;
    platforms = lib.platforms.unix ++ lib.platforms.windows;
  };
}
