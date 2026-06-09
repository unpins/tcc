# tcc

[TinyCC](https://repo.or.cz/tinycc.git) — the small, fast C compiler — as a single self-contained binary that compiles C for **eight targets** from whichever machine it runs on. Built natively for Linux, macOS, and Windows.

[![CI](https://github.com/unpins/tcc/actions/workflows/tcc.yml/badge.svg)](https://github.com/unpins/tcc/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install tcc`.

## Usage

Run `tcc` with [unpin](https://github.com/unpins/unpin) — bare, it compiles for the machine it runs on:

```bash
unpin tcc hello.c -o hello
```

Pick a different target with `-target=` and the same binary cross-compiles — no toolchain to install, no sysroot on disk:

```bash
unpin tcc -target=aarch64-linux   hello.c -o hello       # aarch64 Linux ELF
unpin tcc -target=riscv64-linux   hello.c -o hello       # riscv64 Linux ELF
unpin tcc -target=x86_64-windows  hello.c -o hello.exe   # x86_64 Windows PE
unpin tcc -target=aarch64-darwin  hello.c -o hello       # aarch64 macOS Mach-O
```

Target names follow the usual `arch-os` convention — the same spellings as the nix systems and release assets, and the only ones accepted: `x86_64-linux`, `i686-linux`, `armv7l-linux`, `aarch64-linux`, `riscv64-linux`, `x86_64-windows`, `x86_64-darwin` and `aarch64-darwin`. To put `tcc` on your PATH:

```bash
unpin install tcc
```

## Man pages

`tcc.1` is embedded in the binary — read it with `unpin man tcc`.

## Build locally

```bash
nix build github:unpins/tcc
./result/bin/tcc --version
```

Or run directly:

```bash
nix run github:unpins/tcc -- --version
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/tcc/releases) page has standalone binaries for manual download.

## Build notes

- **Eight targets, one binary, in-process.** tcc compiles one codegen backend per
  executable (`libtcc.c` includes a single `*-gen.c`), so each target is a full
  compile of tcc. Built `ONE_SOURCE`, each is a single object whose only global
  symbols are the ~34 libtcc API functions plus `main()`; those are prefixed per
  target (`objcopy --redefine-syms`) so all eight link into one binary. A small
  dispatcher reads `-target=` and calls the chosen backend with an ordinary
  function call — no `fexecve`, no child executables, one process.
- **Sysroots are embedded.** A C compiler also needs a sysroot (libc headers, crt,
  `libc.a`) plus an assembler and linker. tcc carries its own `as`+`ld`+`libtcc1`,
  and each target's sysroot lives in its own `/zip/<target>/` subtree of a ZIP
  inside the binary, served by a `--wrap=open` VFS (the same machinery as
  [unpins/perl](https://github.com/unpins/perl) and [vim](https://github.com/unpins/vim)).
  So the one file compiles **and links** real C with nothing on disk.
- **Sysroots are built from source — no per-target gcc, no cache dependency.** Each
  Linux target's musl `libc.a`, crt objects and headers are compiled from the musl
  sources at build time by a single multi-target `clang --target=…` (the `zig cc`
  model: one toolchain retargets via `--target`, instead of a full cross-gcc per
  arch). So a cold `nix build` reproduces every sysroot on any host — macOS
  included — from source, not from a warm binary cache. tcc itself can't bootstrap
  musl (no `_Complex`, only partial inline-asm/constraint support), and its archive
  reader only parses GNU `ar` indexes, so the musl build forces `llvm-ar
  --format=gnu` and skips the darwin strip phase (cctools `strip` would otherwise
  re-pack `libc.a` in BSD form, which tcc can't read). RISC-V needs one extra patch:
  clang coalesces the `auipc`/`addi` PC-relative pairs that tcc assumes alternate,
  so its reloc handler is taught clang's hoisted hi/lo scheme.
- **Self-contained, binary and output alike.** The tcc binary has no runtime
  dependencies — a static-musl ELF on Linux (no loader, no `/nix/store`), a
  crt-folded PE on Windows, a `libSystem`-only Mach-O on macOS — and what it
  produces is just as lean: static-musl Linux ELFs, system-DLL-only Windows PEs,
  and `libSystem`-only macOS Mach-Os. macOS output is emitted even from a Linux or
  Windows host, because tcc's modern Mach-O backend (`CONFIG_NEW_MACHO`) is
  unconditional.
- **No `ppc64le` *target*** — tcc has no PowerPC codegen, so it can't emit
  PowerPC. ppc64le is still a supported *host*: the binary runs there and emits the
  eight targets.
- **Header de-duplication keeps it small.** The five Linux sysroots carry ~7.5 MB
  of headers each, yet 1162 of their 1244 files are byte-identical across arches
  (the kernel UAPI; only `asm/` and `bits/` truly differ). The shared files are
  hoisted into one tier searched after each per-arch tier — Zig's trick for
  `zig cc` — so the embedded headers don't grow with the target count.
