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
  # eight ONE_SOURCE tcc backends + a dispatcher into one executable and embeds
  # each target's sysroot as a /zip VFS (the --wrap=open machinery of
  # unpins/perl), so the single file compiles AND links real C with nothing on
  # disk; Linux output defaults to static (portable). mkStandaloneFlake hands
  # ./multi.nix the host pkgs set per catalog system, and it branches on the
  # host's ELF/PE/Mach-O format. tcc has no PowerPC codegen, so a ppc64le *host*
  # emits the eight non-ppc targets — ppc64le is a host, never a target.
  outputs = { self, unpins-lib }:
    let ulib = unpins-lib.lib;
    in ulib.mkStandaloneFlake {
      inherit self;
      name = "tcc";

      # Build via the unpin-llvm engine + emit a bitcode multicall module.
      engine = "unpin-llvm";
      multicall = {
        programs = [{ name = "tcc"; }];
      };
      # nixpkgs ships TinyCC as `tinycc`; used for the man page + license.
      pkgsAttr = "tinycc";
      license = "LGPL-2.1-only";
      smoke = [ "--version" ];
      smokePattern = "tcc version";
      # ./multi.nix is host-format aware, so the native, the other-Linux-arch
      # cross, and the darwin builds are all the same closure; Windows just hands
      # it the mingw cross set.
      build = import ./multi.nix;
      windowsBuild = pkgs: import ./multi.nix pkgs.pkgsCross.mingwW64;
    };
}
