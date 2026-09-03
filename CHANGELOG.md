# Changelog

## [Unreleased]

### Changed

- The Windows binary is now built by the same compiler as the Linux and macOS
  ones (10.1 MB to 11.1 MB — the code the new compiler generates is larger).
  Checked on Windows 10 against the previous binary: `-version`, compiling and
  running a program for Windows, and cross-compiling one for Linux, which comes
  out byte-identical.

  It now uses the Universal C Runtime, which is part of Windows 10 and later.
  On Windows 7 or 8.1 that runtime has to be installed first — it comes through
  Windows Update. The previous binary did not need it.
