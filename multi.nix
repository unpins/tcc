# The multi-target tcc: ONE binary that compiles C to eight targets — five Linux
# ELF archs (x86_64, i386, arm/eabihf, arm64, riscv64), x86_64 Windows PE, and
# x86_64/arm64 macOS Mach-O — in the same process.
#
# tcc is one-backend-per-binary (libtcc.c #includes a single *-gen.c), so each
# target is a full ONE_SOURCE compile of tcc (`<t>-tcc.o` = the whole compiler
# in one object). Its only GLOBAL symbols are the ~34 libtcc public-API functions
# plus main(); everything else is file-static. We rename those globals per
# target in the IR (main -> x86_64_main / win32_main / …), link all eight
# renamed objects + src/dispatch.c into one executable, and the dispatcher
# CALLS the selected backend in-process — no fexecve, one libc, one VFS. Each
# target's sysroot (libc headers + crt + libc.a) lives in its own /zip/<target>/
# subtree, served by the shared unpin-vfs core (nix-lib's vfsCore) in SELF-EOF
# mode: the sysroot ZIP is appended to the binary's EOF by the nix build (the
# same scheme `file` uses for magic.mgc — runtimeEmbed → unpinEmbedWrap), NOT
# compiled in via `.incbin`. That keeps the data out of the bitcode module, so
# the binary stays foldable into a catalog mega (a `.incbin` would leave an
# unresolved blob in module.bc that a mega link can't satisfy). The sysroot
# tree itself is host-independent, so it is built ONCE here (`sysrootTree`) and
# embedded by every host arch + the mega alike.
#
# `pkgs` is the HOST pkgs set — the system the binary itself runs on.
# mkStandaloneFlake hands a different one per catalog system (native, a musl
# cross set for the other Linux archs, a darwin set; flake.nix's windowsBuild
# supplies the mingw set). The host binary probes the OBJECT FORMAT it is being
# compiled to (bitcode = engine) for the VFS binding — rename on the engine,
# `--wrap=open` off it — and the host format (ELF / PE / Mach-O) for the link
# tail; the eight TARGETS and the embedded sysroot tree are identical everywhere.
{ vfsCore, vfsBindFns }:
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
  # exactly the convention grep & every other engine package uses. Windows takes
  # the mingw cross set as handed in — the engine one under `multicall.windows`,
  # plain mingw-gcc without it (the PE folds the crt via -static below either way).
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
  # musl ships no BSD compat headers; nixpkgs' musl installs Alpine's three in
  # postInstall, which this from-source build skips. Same Alpine pin as nixpkgs
  # (and nix-lib's toolchain); re-check when pkgs/by-name/mu/musl moves.
  bsdHeaders = {
    cdefs = linuxPkgs.fetchurl {
      name = "sys-cdefs.h";
      url = "https://git.alpinelinux.org/aports/plain/main/libc-dev/sys-cdefs.h?id=7ca0ed62d4c0d713d9c7dd5b9a077fba78bce578";
      sha256 = "16l3dqnfq0f20rzbkhc38v74nqcsh9n3f343bpczqq8b1rz6vfrh";
    };
    queue = linuxPkgs.fetchurl {
      name = "sys-queue.h";
      url = "http://git.alpinelinux.org/aports/plain/main/libc-dev/sys-queue.h?id=7ca0ed62d4c0d713d9c7dd5b9a077fba78bce578";
      sha256 = "12qm82id7zys92a1qh2l1qf2wqgq6jr4qlbjmqyfffz3s3nhfd61";
    };
    tree = linuxPkgs.fetchurl {
      name = "sys-tree.h";
      url = "http://git.alpinelinux.org/aports/plain/main/libc-dev/sys-tree.h?id=7ca0ed62d4c0d713d9c7dd5b9a077fba78bce578";
      sha256 = "14igk6k00bnpfw660qhswagyhvr0gfqg4q55dxvaaq7ikfkrir71";
    };
  };
  mkSysroot = { cross }:
    let cp = linuxPkgs.pkgsCross.${cross};
        triple = cp.stdenv.hostPlatform.config;
    in linuxPkgs.stdenv.mkDerivation {
      pname = "tcc-musl-sysroot-${triple}";
      # `patches` too, not just `src`: nixpkgs keeps musl on a pinned 1.2.5 and
      # closes its CVEs by backport (iconv OOB write CVE-2025-26519 ×2,
      # CVE-2026-6042, CVE-2026-40200), so taking the tarball alone builds a libc
      # the version string says is current.
      inherit (cp.musl) version src patches;
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
        install -m644 ${bsdHeaders.cdefs} $out/include/sys/cdefs.h
        install -m644 ${bsdHeaders.queue} $out/include/sys/queue.h
        install -m644 ${bsdHeaders.tree}  $out/include/sys/tree.h
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
  # taught clang's hoisted hi/lo scheme (patches/riscv64-pcrel-hi-table.patch).
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

  # Source patches, shared by sysrootTree (libtcc1.a generation) and the host
  # binary build. Each carries its reason in its header.
  tccPatches = map (n: ./patches/${n}.patch) [
    "libtcc1-udivmoddi4-global"
    "armeabi-weak-mem-fallbacks"
    "static-link-by-default"
    "libc-rescan-after-libtcc1"
    "i386-static-plt"
    "riscv64-pcrel-hi-table"
    "long-double-zero-constant"
  ];

  # ---------------------------------------------------------------------------
  # sysrootTree: the embedded /zip tree (per-target headers + crt + libc.a +
  # libtcc1.a), assembled into one directory whose CONTENTS map to /zip/ (i.e.
  # $out/<target>/include/..., $out/common/include/..., $out/osx/lib/...). This is
  # HOST-INDEPENDENT — every libtcc1.a is target machine code emitted by tcc, the
  # musl sysroots are clang-built, the osx tier is the apple-sdk — so one build
  # serves x86_64/aarch64/armv7l Linux, the mingw PE, and both darwin arches, and
  # is shared by the standalone binary (runtimeEmbed) AND any mega that folds
  # tcc (multicall.runtimeDataRoot). Built with the vanilla build-host stdenv (no
  # engine): nothing here is host-arch code. flake.nix appends it to the binary's
  # EOF; the unpin-vfs SELF reader serves it at runtime.
  sysrootTree = linuxPkgs.stdenv.mkDerivation {
    pname = "tcc-sysroot-tree";
    inherit version src;
    nativeBuildInputs = [ linuxPkgs.buildPackages.which ];
    patches = tccPatches;

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
      # `Nat=`: lib/Makefile puts tcov.o (the -ftest-coverage runtime) in the
      # archive only for a native compiler; every target here is a cross.
      # `Cbt=no Cbc=no` keep it from building the backtrace/bcheck objects,
      # which need per-target flags and are built below.
      # XCC defaults to the target's cross-tcc → correct codegen, incl. arm's
      # armeabi.c divmod trick that gcc -O2 would miscompile. Each cross-tcc's baked
      # absolute INC-<t> dropped the {B}/include default, so feed the headers via
      # C_INCLUDE_PATH (musl per arch; in-tree mingw for PE; the SDK for osx).
      ${lib.concatMapStringsSep "\n    " (e:
        "C_INCLUDE_PATH=${e.sysroot}/include make ${e.t}-libtcc1.a $J Nat= Cbt=no Cbc=no ${pvLine e.t}"
      ) linuxTargets}
      C_INCLUDE_PATH=$(pwd)/win32/include:$(pwd)/win32/include/winapi make ${winT}-libtcc1.a $J Nat= Cbt=no Cbc=no ${pvLine winT}
      ${lib.concatMapStringsSep "\n    " (e:
        "C_INCLUDE_PATH=${sdkRoot}/usr/include make ${e.t}-libtcc1.a $J Nat= Cbt=no Cbc=no ${pvLine e.t}"
      ) osxTargets}

      echo "=== build each target's runmain.o (the -run support object) ==="
      # lib/Makefile emits runmain.o only for a NATIVE compiler ($(Nat)); every
      # target here is a cross from the build's point of view, so `-run` shipped
      # without its support object and died with "library '<t>-runmain.o' not
      # found" on the one target that does run natively. runmain.c includes no
      # headers, so each cross-tcc compiles it as is.
      for t in ${lib.concatStringsSep " " allTargets}; do
        ./$t-tcc -c lib/runmain.c -o $t-runmain.o
      done

      echo "=== build each target's -b / -bt / -ftest-coverage support objects ==="
      # lib/Makefile builds these only for a native compiler, like runmain.o.
      # bt-exe.c includes tccrun.c, which takes its target from config.h (the
      # build host's) unless TCC_TARGET_* is given, so each gets its target's
      # DEF-<t> flags. They are linked by name (tcov.o, which belongs in
      # libtcc1.a, comes from `Nat=` above). No bcheck.o on the Linux targets: it swaps
      # malloc for its own through dlsym(RTLD_NEXT), which a static musl
      # executable cannot do ("Cannot redirect malloc/free" at startup).
      supp() {  # $1=target  $2=C_INCLUDE_PATH  $3=defines  $4=objects
        for o in $4; do
          extra=; [ $o = bcheck ] && extra=-bt
          C_INCLUDE_PATH=$2:$(pwd)/include ./$1-tcc -I. $3 $extra -c lib/$o.c -o $1-$o.o
        done
      }
      supp x86_64 ${(builtins.elemAt linuxTargets 0).sysroot}/include "-DTCC_TARGET_X86_64" "bt-exe bt-log"
      supp i386 ${(builtins.elemAt linuxTargets 1).sysroot}/include "-DTCC_TARGET_I386" "bt-exe bt-log"
      supp arm ${(builtins.elemAt linuxTargets 2).sysroot}/include "-DTCC_TARGET_ARM -DTCC_ARM_VFP -DTCC_ARM_EABI -DTCC_ARM_HARDFLOAT" "bt-exe bt-log"
      supp arm64 ${(builtins.elemAt linuxTargets 3).sysroot}/include "-DTCC_TARGET_ARM64" "bt-exe bt-log"
      supp riscv64 ${(builtins.elemAt linuxTargets 4).sysroot}/include "-DTCC_TARGET_RISCV64" "bt-exe bt-log"
      supp ${winT} $(pwd)/win32/include:$(pwd)/win32/include/winapi "-DTCC_TARGET_X86_64 -DTCC_TARGET_PE" "bt-exe bt-log bcheck bt-dll"
      supp x86_64-osx ${sdkRoot}/usr/include "-DTCC_TARGET_X86_64 -DTCC_TARGET_MACHO" "bt-exe bt-log bcheck"
      supp arm64-osx ${sdkRoot}/usr/include "-DTCC_TARGET_ARM64 -DTCC_TARGET_MACHO" "bt-exe bt-log bcheck"

      echo "=== assemble the /zip tree with per-target sysroot subtrees ==="
      rm -rf zroot
      mkLinux() {  # $1=target  $2=sysroot (clang-built musl: include/ + lib/)
        mkdir -p zroot/$1/include zroot/$1/lib/tcc
        # cp -aL: dereference any symlink (the kernel UAPI may link into a
        # linux-headers store path) so the dedup pass sees real files to hoist.
        cp -aL $2/include/. zroot/$1/include/ && chmod -R u+w zroot/$1/include
        cp -af include/. zroot/$1/include/ && chmod -R u+w zroot/$1/include
        cp -a $2/lib/crt1.o $2/lib/crti.o $2/lib/crtn.o $2/lib/libc.a zroot/$1/lib/
        # musl keeps all of libm/libpthread/… in libc.a and installs these as
        # empty archives, only so `-lm`, `-pthread` and friends resolve.
        for l in m pthread dl rt crypt util xnet resolv; do
          cp -a $2/lib/lib$l.a zroot/$1/lib/
        done
        cp -a $1-libtcc1.a $1-runmain.o $1-bt-exe.o $1-bt-log.o zroot/$1/lib/tcc/
      }
      ${lib.concatMapStringsSep "\n    " (e: "mkLinux ${e.t} ${e.sysroot}") linuxTargets}

      # win32 subtree: mingw headers + tcc intrinsics + .def + PE libtcc1.a.
      mkdir -p zroot/${winT}/include zroot/${winT}/lib/tcc
      cp -a win32/include/. zroot/${winT}/include/
      cp -a include/*.h     zroot/${winT}/include/
      cp -a win32/lib/*.def zroot/${winT}/lib/
      cp -a ${winT}-libtcc1.a ${winT}-runmain.o ${winT}-bt-exe.o ${winT}-bt-log.o \
        ${winT}-bcheck.o ${winT}-bt-dll.o zroot/${winT}/lib/tcc/

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
        "mkdir -p zroot/${e.t}/lib/tcc && cp -a ${e.t}-libtcc1.a ${e.t}-runmain.o ${e.t}-bt-exe.o ${e.t}-bt-log.o ${e.t}-bcheck.o zroot/${e.t}/lib/tcc/"
      ) osxTargets}
      chmod -R u+w zroot

      echo "=== Zig-style header dedup (src/dedup-headers.sh) ==="
      bash ${./src/dedup-headers.sh} zroot common ${lib.concatMapStringsSep " " (e: e.t) linuxTargets}
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      # Contents map to /zip/ (no wrapping dir): $out/<target>/..., $out/common/...,
      # $out/osx/... — the embed copies $out/. into the ZIP root, and the VFS
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
  patches = tccPatches;

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
    # appends -flto), which keeps tcc foldable into a bitcode-LTO mega.
    # objcopy can't rename symbols in bitcode, and a mega link can't carry tcc's
    # per-package `--wrap`, so we bind the VFS and de-collide the eight backends
    # by REWRITING IR symbols (see the prefix() ENGINE branch +
    # -DUNPIN_VFS_NOWRAP below). Every host, Windows included, is on the engine;
    # the objcopy + --wrap branch only serves a host built off it. Probe rather
    # than trust a platform flag. $MT is
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
    #   ENGINE: rename binding (unpinvfs_*) — the prefix() sed rewrites each
    #     backend's open/stat/... IR symbols to unpinvfs_*. Mega-safe, no --wrap.
    #     vfs.c defines those shims under -DUNPIN_VFS_NOWRAP on linux/darwin; its
    #     _WIN32 half has no NOWRAP mode, so there we select the explicit
    #     unpin_vfs_* API (-DUNPIN_VFS_WIN_WRAPOPEN, strict /zip prefix match) and
    #     src/vfs_win_bind.c names it unpinvfs_open. Still no --wrap.
    #   off-engine (no current host; a non-engine PE): `ld --wrap=open` on open()
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
      VFSBIND="${if isWin then "-DUNPIN_VFS_WIN_WRAPOPEN" else "-DUNPIN_VFS_NOWRAP"}"
      WRAPFLAGS=""
    else
      VFSBIND="-DUNPIN_VFS_WIN_WRAPOPEN"
      WRAPFLAGS="-Wl,--wrap=open"
    fi
    echo "ENGINE=$ENGINE MT=''${MT:-} VFSBIND=$VFSBIND"

    ${vfsBindFns { }}

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
    #   dispatcher calls eight distinct mains, so main -> <g>_main (tcc's own
    #   rename, done here); the VFS binds by rename (mega-safe, no --wrap) via
    #   nix-lib's shared vfsSed, which knows every spelling a libc file op can
    #   carry -- the plain form, 32-bit musl's __*_time64 aliases, and darwin's
    #   raw asm labels including the x86_64 $INODE64 variants. Then opt
    #   -internalize localizes everything but <g>_main. `@sym` is a FUNCTION
    #   symbol (sigil differs from `%struct.sym`), so renaming @stat never
    #   touches `struct stat`. The Mach-O `_` is added only at object emission.
    # OFF-ENGINE (no current host): nm + objcopy --redefine-syms prefixes every
    #   defined global. ELF/PE have no leading underscore.
    prefix() {  # $1 = target stem   $2 = C symbol tag (g)
      if [ "$ENGINE" = 1 ]; then
        $MT opt -S $1-tcc.o -o $1.ll
        # tcc's OWN rename: the dispatcher calls eight distinct mains.
        sed -i -e 's/@main\b/@'"$2"'_main/g' $1.ll
        # The VFS rename comes from nix-lib (lib.vfsBindFns) — ONE home for the
        # spelling logic, instead of the private copy that used to live here and
        # had drifted two rules behind it (the plain `\01_stat`/`\01_lstat`, the
        # arm64-darwin spelling). Same default symbol set as before; in practice
        # only open() ever matches, since tcc reads every include through
        # tcc_open() -> open() and its one fopen() is the `-E` OUTPUT file, which
        # must reach the real filesystem.
        vfsSed $1.ll
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
    # unpin-vfs core, shared from nix-lib; -I. so vfs.c finds miniz.h/vfs.h/
    # unpin_zstd.h, and unpin_zstd.c #includes zstddeclib.c (decompress-only,
    # -DUNPIN_ZSTD_VENDORED).
    cp ${vfsCore}/*.c ${vfsCore}/*.h .
    MZ='-DMINIZ_USE_ZSTD -DMINIZ_NO_TIME -DMINIZ_NO_ARCHIVE_WRITING_APIS -DMINIZ_NO_ZLIB_APIS -DMINIZ_NO_ZLIB_COMPATIBLE_NAMES'
    $CC -O2 -I. $MZ -w -c miniz.c -o miniz.o
    $CC -O2 -I. -DMINIZ_USE_ZSTD -DUNPIN_ZSTD_VENDORED -w -c unpin_zstd.c -o unpin_zstd.o
    $CC -O2 -I. -DUNPIN_VFS_SELF -DUNPIN_VFS_ROOT='"/zip/"' -DMINIZ_USE_ZSTD $VFSBIND -c vfs.c -o vfs.o
    $CC -O2 -c ${./src/dispatch.c} -o dispatch.o
    ${lib.optionalString isWin ''
      # On the engine the windows binding needs one adapter object (see the
      # VFSBIND comment above); off it, --wrap does the whole job.
      BINDOBJ=
      if [ "$ENGINE" = 1 ]; then
        $CC -O2 -c ${./src/vfs_win_bind.c} -o vfs_win_bind.o
        BINDOBJ=vfs_win_bind.o
      fi
    ''}

    echo "=== link ONE binary (host=${hostPlat.system}; no blob — sysroot rides the EOF) ==="
    # On darwin everything is bitcode, so the engine's ELF ld.lld LTO-compiles it
    # straight to Mach-O; on linux it is a static-musl LTO link; on the mingw PE
    # -static folds the crt, and the VFS is reached by rename or by --wrap=open
    # depending on the engine (BINDOBJ / WRAPFLAGS above).
    $CC ${if isDarwin then "" else "-static"} -o ${binName} dispatch.o \
      ${lib.concatMapStringsSep " " (e: "${e.g}-pfx.o") linuxTargets} ${winG}-pfx.o \
      ${lib.concatMapStringsSep " " (e: "${e.g}-pfx.o") osxTargets} \
      vfs.o miniz.o unpin_zstd.o ${lib.optionalString isWin "$BINDOBJ "}\
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
