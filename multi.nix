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
# it carries the compiler logic that runs on the host. The Linux target sysroots
# are host-independent machine code, taken from a fixed x86_64-linux pkgs (so a
# darwin host, where musl doesn't evaluate, still gets them).
pkgs:
let
  lib = pkgs.lib;
  hostPlat = pkgs.stdenv.hostPlatform;
  isWin = hostPlat.isWindows;
  isDarwin = hostPlat.isDarwin;

  # Host stdenv. Linux is static-musl (self-contained, `env -i`-clean, runs
  # under qemu-user with no loader); Windows/macOS keep their cross stdenv as-is
  # (the PE folds the crt via -static below; macOS has no static libc). `hp` also
  # carries the build-host toolchain via `.buildPackages`.
  hp = if isDarwin || isWin then pkgs else pkgs.pkgsStatic;
  hostStdenv = hp.stdenv;
  buildCC = "${hp.buildPackages.stdenv.cc}/bin/cc";
  buildAR = "${hp.buildPackages.stdenv.cc.bintools.bintools}/bin/ar";

  # Linux-target artifacts (tinycc source + the per-arch musl sysroots that
  # become each ELF backend's headers/crt/libc.a) are host-independent, so take
  # them from a fixed x86_64-linux pkgs: required on a darwin host, a cache hit
  # elsewhere.
  linuxPkgs = import pkgs.path { system = "x86_64-linux"; };
  inherit (linuxPkgs.tinycc) src version;

  # Symbol-table tools. A Mach-O host renames symbols with --redefine-sym(s),
  # which cctools' nm/objcopy can't do but LLVM's can; ELF/PE use stdenv binutils.
  llvmBin = "${hp.buildPackages.llvm}/bin";
  nmBin = if isDarwin then "${llvmBin}/llvm-nm" else "$NM";
  objcopyBin = if isDarwin then "${llvmBin}/llvm-objcopy" else "$OBJCOPY";
  binName = if isWin then "tcc.exe" else "tcc";

  # Targets. `t` = tcc make-target / /zip subtree name; `g` = the C symbol tag
  # (objcopy prefix + dispatch.c extern); `musl` = the cross musl supplying that
  # ELF target's headers + crt*.o + libc.a.
  linuxTargets = [
    { t = "x86_64";  g = "x86_64";  musl = linuxPkgs.pkgsStatic.musl; }
    { t = "i386";    g = "i386";    musl = linuxPkgs.pkgsCross.musl32.pkgsStatic.musl; }
    { t = "arm";     g = "arm";     musl = linuxPkgs.pkgsCross.armv7l-hf-multiplatform.pkgsStatic.musl; }
    { t = "arm64";   g = "arm64";   musl = linuxPkgs.pkgsCross.aarch64-multiplatform-musl.pkgsStatic.musl; }
    { t = "riscv64"; g = "riscv64"; musl = linuxPkgs.pkgsCross.riscv64-musl.pkgsStatic.musl; }
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
  # libSystem.tbd. Reach it from any host by re-instantiating nixpkgs for darwin
  # (eval-only; the SDK substitutes from cache). Both osx arches SHARE one
  # /zip/osx tier — the SDK headers are byte-identical across arches and
  # libSystem.tbd is a multi-arch stub; only the per-arch libtcc1.a differs. On a
  # darwin host the dispatcher also links against the host's own SDK (libSystem +
  # libc headers — the modern darwin stdenv carries none by default).
  sdkRoot = (import pkgs.path { system = "aarch64-darwin"; }).apple-sdk.sdkroot;
  hostSdk = lib.optional isDarwin hp.apple-sdk;

  # The host's executable format drives three knobs; vfs_miniz.c mirrors the same
  # three #if branches, so the blob symbol names must match the OS exactly:
  #   ELF (Linux)    _binary_incblob_* ; GNU `ld --wrap` reroutes open/stat/… ;
  #                  -static musl ; -ldl/-lpthread are tcc's glibc deps (musl stubs).
  #   PE (Windows)   incblob_* ; mingw `ld --wrap=open` (tcc reads every input via
  #                  open(), makes no stat on Windows) ; -static folds the crt.
  #   Mach-O (macOS) _incblob_* ; ld64 has no --wrap, so the VFS binds by
  #                  rewriting each object's open import to _unpinvfs_open (the
  #                  redefine pass below) ; dynamic against libSystem.
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
  '';
in
hostStdenv.mkDerivation {
  pname = "tcc";
  inherit version src;
  # zip/which run at build time → build-host tools (native in a cross build).
  nativeBuildInputs = [ pkgs.buildPackages.zip pkgs.buildPackages.which ];
  buildInputs = hostSdk; # the host SDK on darwin (libSystem + libc headers); [] elsewhere
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

    echo "=== build the eight ONE_SOURCE cross-compilers (build-host cc; run here) ==="
    make ${lib.concatMapStringsSep " " (t: "${t}-tcc") allTargets} $J ${allPv} CC=${buildCC}

    echo "=== build each libtcc1.a by running its cross-tcc ==="
    # XCC defaults to the target's cross-tcc → correct codegen, incl. arm's
    # armeabi.c divmod trick that gcc -O2 would miscompile. Each cross-tcc's baked
    # absolute INC-<t> dropped the {B}/include default, so feed the headers via
    # C_INCLUDE_PATH (musl per arch; in-tree mingw for PE; the SDK for osx).
    ${lib.concatMapStringsSep "\n    " (e:
      "C_INCLUDE_PATH=${e.musl.dev}/include make ${e.t}-libtcc1.a $J ${pvLine e.t}"
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
    # nm/objcopy are host tools (stdenv binutils, or LLVM on a Mach-O host). On
    # Mach-O every C symbol carries a leading underscore (main -> _main), so the
    # rename inserts the tag AFTER it (_main -> _x86_64_osx_main) to match
    # dispatch.c's (also-underscored) externs; ELF/PE have no leading underscore.
    prefix() {  # $1 = object stem   $2 = C symbol tag
      ${if isDarwin
        then ''${nmBin} -g --defined-only $1-tcc.o | awk -v p=$2 '{s=$NF; sub(/^_/,"",s); print $NF, "_" p "_" s}' > $2.map''
        else ''${nmBin} -g --defined-only $1-tcc.o | awk -v p=$2 '{print $NF, p"_"$NF}' > $2.map''}
      ${objcopyBin} --redefine-syms=$2.map $1-tcc.o $2-pfx.o
    }
    ${lib.concatMapStringsSep "\n    " (e: "prefix ${e.t} ${e.g}") (linuxTargets ++ osxTargets)}
    prefix ${winT} ${winG}
    ${lib.optionalString isDarwin ''
      # Mach-O host: bind the VFS by rewriting each backend object's open() import
      # to _unpinvfs_open (vfs_miniz.c's __APPLE__ branch defines it and calls the
      # real libc open). tcc reads all input via open() and never stat()s a /zip
      # path, so rerouting _open alone is the whole VFS.
      for o in ${lib.concatMapStringsSep " " (e: "${e.g}-pfx.o") (linuxTargets ++ osxTargets)} ${winG}-pfx.o; do
        ${objcopyBin} --redefine-sym _open=_unpinvfs_open "$o"
      done
    ''}

    echo "=== assemble ONE zip with per-target sysroot subtrees ==="
    rm -rf zroot
    mkLinux() {  # $1=target  $2=musl.dev  $3=musl.out
      mkdir -p zroot/$1/include zroot/$1/lib/tcc
      # cp -aL: dereference. musl.dev/include reaches the kernel UAPI (linux/,
      # drm/, asm/, …) through symlinks into a linux-headers store path; zip would
      # silently follow them and bake five full copies, so materialise them as
      # real files for the dedup pass to see and hoist.
      cp -aL $2/include/. zroot/$1/include/ && chmod -R u+w zroot/$1/include
      cp -af include/. zroot/$1/include/ && chmod -R u+w zroot/$1/include
      cp -a $3/lib/crt1.o $3/lib/crti.o $3/lib/crtn.o $3/lib/libc.a zroot/$1/lib/
      cp -a $1-libtcc1.a zroot/$1/lib/tcc/
    }
    ${lib.concatMapStringsSep "\n    " (e: "mkLinux ${e.t} ${e.musl.dev} ${e.musl.out}") linuxTargets}

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
    cat > blob.S <<'BLOBEOF'
${blobAsm}
BLOBEOF
    $CC -c blob.S -o blob.o
    $CC -O2 -c miniz.c -o miniz.o
    $CC -O2 -I. -c vfs_miniz.c -o vfs_miniz.o
    $CC -O2 -c ${./src}/dispatch.c -o dispatch.o

    $CC ${staticFlag} -o ${binName} dispatch.o \
      ${lib.concatMapStringsSep " " (e: "${e.g}-pfx.o") linuxTargets} ${winG}-pfx.o \
      ${lib.concatMapStringsSep " " (e: "${e.g}-pfx.o") osxTargets} \
      blob.o vfs_miniz.o miniz.o \
      ${wrapFlags} ${linkLibs}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 ${binName} $out/bin/${binName}
    # tcc.1 is host-independent roff; take it (uncompressed) from the fixed
    # x86_64-linux tinycc so `unpin man tcc` works on every host (withMan embeds it).
    mkdir -p $out/share/man/man1
    gzip -dc ${linuxPkgs.tinycc.man}/share/man/man1/tcc.1.gz > $out/share/man/man1/tcc.1
    runHook postInstall
  '';

  meta = {
    description = "TinyCC that cross-compiles C to eight targets from one binary";
    homepage = "https://repo.or.cz/tinycc.git";
    license = lib.licenses.lgpl21Only;
    platforms = lib.platforms.unix ++ lib.platforms.windows;
  };
}
