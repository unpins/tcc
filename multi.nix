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
# subtree, served by the shared unpin-vfs core (src/vfs.c) in SELF-EOF mode: the
# sysroot ZIP is appended to the binary's EOF by the nix build (the same scheme
# `file` uses for magic.mgc — runtimeDataRoot/runtimeEmbed → withRuntimeData),
# NOT compiled in via `.incbin`. That keeps the data out of the bitcode module so
# the binary folds into the unpinbox mega cleanly (a `.incbin` would leave an
# unresolved blob in module.bc that the mega-link can't satisfy). The sysroot
# tree itself is host-independent, so it is built ONCE here (`sysrootTree`) and
# embedded by every host arch + the mega alike.
#
# `pkgs` is the HOST pkgs set — the system the binary itself runs on.
# mkStandaloneFlake hands a different one per catalog system (native, a musl
# cross set for the other Linux archs, a darwin set; flake.nix's windowsBuild
# supplies the mingw set). The host binary branches on the host's executable
# FORMAT (ELF / PE / Mach-O) for the VFS binding (rename on the bitcode engine,
# `--wrap=open` on the off-engine mingw PE) and the link tail; the eight TARGETS
# and the embedded sysroot tree are identical everywhere.
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
  # per-arch libtcc1.a differs.
  sdkRoot = (import pkgs.path { system = "aarch64-darwin"; }).apple-sdk.sdkroot;

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
  # Shared by sysrootTree (libtcc1.a generation) and the host binary build.
  commonPatch = ''
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

  # ---------------------------------------------------------------------------
  # sysrootTree: the embedded /zip tree (per-target headers + crt + libc.a +
  # libtcc1.a), assembled into one directory whose CONTENTS map to /zip/ (i.e.
  # $out/<target>/include/..., $out/common/include/..., $out/osx/lib/...). This is
  # HOST-INDEPENDENT — every libtcc1.a is target machine code emitted by tcc, the
  # musl sysroots are clang-built, the osx tier is the apple-sdk — so one build
  # serves x86_64/aarch64/armv7l Linux, the mingw PE, and both darwin arches, and
  # is shared by the standalone binary (runtimeEmbed) AND the unpinbox mega
  # (multicall.runtimeDataRoot). Built with the vanilla build-host stdenv (no
  # engine): nothing here is host-arch code. flake.nix appends it to the binary's
  # EOF; the unpin-vfs SELF reader serves it at runtime.
  sysrootTree = linuxPkgs.stdenv.mkDerivation {
    pname = "tcc-sysroot-tree";
    inherit version src;
    nativeBuildInputs = [ linuxPkgs.buildPackages.which ];
    postPatch = commonPatch;

    configurePhase = ''
      runHook preConfigure
      ./configure --cc=${buildCC} --ar=${buildAR}
      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild
      J=-j''${NIX_BUILD_CORES:-1}

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

      echo "=== assemble the /zip tree with per-target sysroot subtrees ==="
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
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      # Contents map to /zip/ (no wrapping dir): $out/<target>/..., $out/common/...,
      # $out/osx/... — withRuntimeData copies $out/. into the ZIP root, and the VFS
      # strips the "/zip/" prefix on lookup.
      cp -a zroot/. "$out/"
      runHook postInstall
    '';

    meta.description = "Embedded per-target sysroot tree for the multi-target tcc";
  };
in
hostStdenv.mkDerivation {
  pname = "tcc";
  inherit version src;
  passthru = { inherit sysrootTree; };
  # which runs at build time (configure); perl (+ pod2man) generates tcc.1 from
  # tcc-doc.texi in-tree. All build-host tools (native in a cross build). No zip:
  # the sysroot ZIP is appended at the binary's EOF by the nix build, not here.
  nativeBuildInputs = [ pkgs.buildPackages.which pkgs.buildPackages.perl ];
  # No buildInputs: the host SDK (libSystem + libc headers) reaches darwin via the
  # engine stdenv's SDKROOT.
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
    # mingw Windows cross) keep the objcopy + --wrap path. Probe rather than trust
    # a platform flag, so a future off-engine build is handled correctly. $MT is
    # the engine multitool (opt/llvm-as), reached via the cc-wrapper's objcopy
    # symlink. The probe accepts BOTH bitcode magics the engine emits: raw
    # `4243c0de` (linux) and its wrapper `dec0170b` (darwin wraps the bitcode in a
    # thin header), matching the engine's own _unpin_natkind classifier.
    echo 'int _unpin_probe(void){return 0;}' > _probe.c
    $CC -c _probe.c -o _probe.o 2>/dev/null || true
    case "$(od -An -tx1 -N4 _probe.o 2>/dev/null | tr -d ' \n')" in
      4243c0de|dec0170b) ENGINE=1 ;;
      *) ENGINE=0 ;;
    esac

    # VFS binding. The data flags are inlined at the compile below; only the
    # quote-free binding selector goes through a shell var.
    #   ENGINE (linux/darwin): rename binding (unpinvfs_*) — the prefix() sed
    #     rewrites each backend's open/stat/... IR symbols to unpinvfs_*, which
    #     vfs.c defines under -DUNPIN_VFS_NOWRAP. Mega-safe, no --wrap.
    #   off-engine (mingw PE): `ld --wrap=open` on plain msvcrt open()
    #     (-DUNPIN_VFS_WIN_WRAPOPEN selects vfs.c's __wrap_open mode).
    if [ "$ENGINE" = 1 ]; then
      MT=""
      for __c in nm objcopy "$NM" "$OBJCOPY" "$CC" cc clang opt; do
        __f=$(readlink -f "$(command -v "$__c" 2>/dev/null)" 2>/dev/null) || continue
        [ -f "$__f" ] || continue
        __p=$(grep -aoE '/nix/store/[^ "]*/bin/llvm' "$__f" 2>/dev/null | head -1) || true
        [ -n "$__p" ] && { MT=$__p; break; }
      done
      [ -n "$MT" ] || { echo "tcc multi.nix: could not locate the engine llvm multitool" >&2; exit 1; }
      VFSBIND="-DUNPIN_VFS_NOWRAP"
      WRAPFLAGS=""
    else
      VFSBIND="-DUNPIN_VFS_WIN_WRAPOPEN"
      WRAPFLAGS="-Wl,--wrap=open"
    fi
    echo "ENGINE=$ENGINE MT=''${MT:-} VFSBIND=$VFSBIND"

    echo "=== build with the build-host cc first (c2str + tccdefs_.h; run here) ==="
    # c2str and tccdefs_.h are build-host tools/artifacts: build them with the
    # vanilla build cc so they RUN here (a $CC-built c2str is host-arch and can't
    # run in a cross/darwin build). libtcc1.a + the sysroots are NOT built here —
    # they live in sysrootTree.
    make ${lib.concatMapStringsSep " " (t: "${t}-tcc") allTargets} $J ${allPv} CC=${buildCC}

    echo "=== recompile every <t>-tcc.o for the host (${hostPlat.system}; \$CC) ==="
    # The shipped binary runs on the host, so its compiler logic must be host-arch.
    # The ONE_SOURCE object only compiles correctly through the `%-tcc` rule (right
    # DEF-<t>/CONFIG_TCC_* defines), whose object recipe has no FORCE — so rm the
    # build-host .o first. touch tccdefs_.h so make won't regenerate it with the
    # build-only c2str. -k so a wasted host-executable relink can't abort the run —
    # we only want the .o. `CC="$CC"` wins over config.mak's build cc.
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
    #   localizes everything but <g>_main. `@sym` is a FUNCTION symbol (sigil
    #   differs from `%struct.sym`), so renaming @stat never touches `struct stat`.
    #   The Mach-O `_` is added only at object emission. darwin's SDK headers give
    #   the libc imports raw-symbol asm labels (`@"\01_open"`, the 64-bit-inode
    #   `@"\01_stat$INODE64"`), so the VFS rename needs a second rule set for those;
    #   each rule that can't match a target's IR is a harmless no-op there.
    # OFF-ENGINE (PE on the mingw Windows cross): nm + objcopy --redefine-syms
    #   prefixes every defined global. ELF/PE have no leading underscore.
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
      # backend object's open() import to _unpinvfs_open. Dead on the engine — the
      # sed pass already renamed @open -> @unpinvfs_open in the IR, and objcopy
      # can't touch bitcode anyway — so guard on ENGINE=0. darwin always goes
      # through the engine now, so this only fires if that ever regresses.
      if [ "$ENGINE" = 0 ]; then
        for o in ${lib.concatMapStringsSep " " (e: "${e.g}-pfx.o") (linuxTargets ++ osxTargets)} ${winG}-pfx.o; do
          ${objcopyBin} --redefine-sym _open=_unpinvfs_open "$o"
        done
      fi
    ''}

    echo "=== compile the shared unpin-vfs core (self-EOF) + dispatcher ==="
    # Vendored unpin-vfs core; -I. so vfs.c finds miniz.h/vfs.h/unpin_zstd.h, and
    # unpin_zstd.c #includes zstddeclib.c (decompress-only, -DUNPIN_ZSTD_VENDORED).
    cp ${./src}/vfs.c ${./src}/vfs.h ${./src}/miniz.c ${./src}/miniz.h \
       ${./src}/unpin_zstd.c ${./src}/unpin_zstd.h ${./src}/zstddeclib.c .
    MZ='-DMINIZ_USE_ZSTD -DMINIZ_NO_TIME -DMINIZ_NO_ARCHIVE_WRITING_APIS -DMINIZ_NO_ZLIB_APIS -DMINIZ_NO_ZLIB_COMPATIBLE_NAMES'
    $CC -O2 -I. $MZ -w -c miniz.c -o miniz.o
    $CC -O2 -I. -DMINIZ_USE_ZSTD -DUNPIN_ZSTD_VENDORED -w -c unpin_zstd.c -o unpin_zstd.o
    $CC -O2 -I. -DUNPIN_VFS_SELF -DUNPIN_VFS_ROOT='"/zip/"' -DMINIZ_USE_ZSTD $VFSBIND -c vfs.c -o vfs.o
    $CC -O2 -c ${./src}/dispatch.c -o dispatch.o

    echo "=== link ONE binary (host=${hostPlat.system}; no blob — sysroot rides the EOF) ==="
    # On darwin everything is bitcode, so the engine's ELF ld.lld LTO-compiles it
    # straight to Mach-O; on linux it is a static-musl LTO link; on the mingw PE
    # -static folds the crt and --wrap=open routes reads through the VFS.
    $CC ${if isDarwin then "" else "-static"} -o ${binName} dispatch.o \
      ${lib.concatMapStringsSep " " (e: "${e.g}-pfx.o") linuxTargets} ${winG}-pfx.o \
      ${lib.concatMapStringsSep " " (e: "${e.g}-pfx.o") osxTargets} \
      vfs.o miniz.o unpin_zstd.o \
      $WRAPFLAGS ${if isDarwin || isWin then "-lm" else "-lm -ldl -lpthread"}
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
