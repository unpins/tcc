# Changelog

## [Unreleased]

### Changed

- The Windows binary is now built by the same compiler as the Linux and macOS
  ones. It is about 8% smaller (12.1 MB to 11.1 MB). Checked on Windows 10
  against the previous binary: `-version`, compiling and running a program for
  Windows, and cross-compiling one for Linux, which comes out byte-identical.

  It now uses the Universal C Runtime, which is part of Windows 10 and later.
  On Windows 7 or 8.1 that runtime has to be installed first — it comes through
  Windows Update. The previous binary did not need it.

### Fixed

- A bare `tcc` compiles for the machine it runs on. It always compiled for
  x86_64 Linux instead, whatever the machine — so on Windows `tcc hello.c -o
  hello.exe` produced a Linux binary Windows refused to start, and on an ARM or
  macOS machine it produced an x86_64 Linux one. Naming the target explicitly
  (`-target=…`) always worked and still does.
- `tcc -run` works. It failed with `library 'x86_64-runmain.o' not found` on
  every release so far — the object `-run` needs was never built, because
  upstream builds it only for a compiler that targets its own machine, and
  every target here is cross-built. With it in place, running a C file straight
  from source works, `#!/path/to/tcc -run` shebang scripts included.
