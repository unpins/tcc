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
unpin tcc -target=arm64    hello.c -o hello       # arm64 Linux ELF
unpin tcc -target=riscv64  hello.c -o hello       # riscv64 Linux ELF
unpin tcc -target=windows  hello.c -o hello.exe   # x86_64 Windows PE
unpin tcc -target=arm64-osx hello.c -o hello      # arm64 macOS Mach-O
```

The full target set is `x86_64`, `i386` (also `-m32`), `arm`, `arm64`, `riscv64`, `windows`, `x86_64-osx` and `arm64-osx`; the catalog/system spellings (`aarch64`, `x86_64-darwin`, …) work too. To put `tcc` on your PATH:

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

- **Eight targets, one binary, in-process.** tcc compiles exactly one codegen
  backend per executable (`libtcc.c` includes a single `*-gen.c`), so each target
  is a full compile of tcc. Built `ONE_SOURCE`, each is one object whose only
  global symbols are the ~34 libtcc API functions plus `main()`; those are
  prefixed per target (`objcopy --redefine-syms`) and all eight link into one
  binary. A small dispatcher reads `-target=` and calls the chosen backend with a
  plain function call — no `fexecve`, no embedded child executables, one process.
- **Sysroots are embedded.** A C compiler needs a sysroot (libc headers + crt +
  `libc.a`) and an assembler+linker; tcc carries its own `as`+`ld`+`libtcc1`, and
  each target's sysroot lives in its own `/zip/<target>/` subtree of a ZIP
  embedded in the binary, served by a `--wrap=open` VFS (the same machinery as
  [unpins/perl](https://github.com/unpins/perl)/[vim](https://github.com/unpins/vim)).
  So the single file compiles **and links** real C with nothing on disk.
- **Linux output defaults to static** (the targets are musl), so what `tcc`
  produces is as portable as `tcc` itself. Windows output is a PE linking only the
  system DLLs; macOS output is a Mach-O linking only `/usr/lib/libSystem.B.dylib`.
- **No `ppc64le` *target*** — tcc has no PowerPC codegen backend, so it can't emit
  PowerPC. ppc64le is still a supported *host*: the binary runs on ppc64le and
  emits the other eight targets.
- **The binary itself** is self-contained per OS: a static-musl ELF on Linux (no
  loader, no `/nix/store`), a PE with the crt folded in on Windows, a
  `libSystem`-only Mach-O on macOS. macOS Mach-O output is generated even from a
  Linux or Windows host — `CONFIG_NEW_MACHO` is unconditional in tcc, so a
  cross-built tcc emits the same modern chained-fixups binaries a Mac-built one
  does.
- **Header de-duplication keeps it small.** The five Linux sysroots are ~7.5 MB of
  headers each, but 1162 of 1244 files are byte-identical across arches (the
  kernel UAPI); only `asm/` and `bits/` genuinely differ. Those identical files
  are hoisted into one shared tier searched after each per-arch tier — Zig's
  strategy for `zig cc` — so the embedded headers don't grow with the arch count.
