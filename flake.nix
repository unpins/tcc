{
  description = "TinyCC that cross-compiles C to eight targets from one self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # One tcc binary that compiles C to EIGHT targets — five Linux ELF archs
  # (x86_64, i386, arm/eabihf, arm64, riscv64), x86_64 Windows PE, and
  # x86_64/arm64 macOS Mach-O — selected with `-target=`. ./multi.nix links all
  # eight ONE_SOURCE tcc backends + a dispatcher into one executable; each
  # target's sysroot is served by the shared unpin-vfs core as a /zip VFS. The
  # sysroot tree rides the binary's EOF ZIP (the same self-EOF scheme file uses
  # for magic.mgc — runtimeDataRoot/runtimeEmbed → withRuntimeData), NOT compiled
  # in via `.incbin`, so the binary folds into the unpinbox mega cleanly. Linux
  # output defaults to static (portable). mkStandaloneFlake hands ./multi.nix the
  # host pkgs set per catalog system; it branches on the host's ELF/PE/Mach-O
  # format. tcc has no PowerPC codegen, so a ppc64le *host* emits the eight
  # non-ppc targets — ppc64le is a host, never a target.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;
      multi = import ./multi.nix;
      # The per-target sysroot /zip tree — host-independent, exposed by ./multi.nix
      # as passthru.sysrootTree (built once, shared by every host + the mega).
      sysrootTreeFor = pkgs: (multi pkgs).sysrootTree;
      # Stage that tree into the binary's EOF ZIP (standalone embed) — the same
      # tree the mega merges via multicall.runtimeDataRoot. Contents map to /zip/.
      stageSysroot = pkgs: ''
        cp -rL --no-preserve=mode ${sysrootTreeFor pkgs}/. "$__unpin_stage/"
        chmod -R u+w "$__unpin_stage" 2>/dev/null || true
      '';
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "tcc";

      # Build via the unpin-llvm engine + emit a bitcode multicall module.
      engine = "unpin-llvm";
      multicall = {
        programs = [{ name = "tcc"; }];
        # Merge tcc's /zip sysroot tree into the mega's EOF ZIP (like file's
        # magic.mgc). No `.incbin`/blob, so nothing is left unresolved in the
        # bitcode module for the mega-link to satisfy.
        runtimeDataRoot = pkgs: sysrootTreeFor pkgs;
      };
      # nixpkgs ships TinyCC as `tinycc`; used for the man page + license.
      pkgsAttr = "tinycc";
      license = "LGPL-2.1-only";
      smoke = [ "--version" ];
      smokePattern = "tcc version";
      # ./multi.nix is host-format aware, so the native, the other-Linux-arch
      # cross, and the darwin builds are all the same closure; Windows just hands
      # it the mingw cross set.
      build = multi;
      # Append the sysroot ZIP to the EOF of the shipped standalone binary
      # (unpinEmbedWrap); man is auto-harvested. Windows uses the same tree.
      runtimeEmbed = {
        native = pkgs: base: { runtimeStage = stageSysroot pkgs; };
        windows = pkgs: base: { runtimeStage = stageSysroot pkgs; };
      };
      windowsBuild = pkgs: multi pkgs.pkgsCross.mingwW64;
    };
}
