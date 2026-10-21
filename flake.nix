{
  description = "Reproducer: IPv6 suppress_prefixlength misroutes with a shared nexthop object";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/cd4ea8d57de16f4810bc5f14207bac45fbf19f67";

  # The netdev "net" tree (fixes for the current release), for checking the bug is still there.
  # Update with `nix flake update net-tree` after changing the rev.
  inputs.net-tree = {
    url = "git+https://git.kernel.org/pub/scm/linux/kernel/git/netdev/net.git?ref=main&rev=abeacca61eea4f6803df4a595b656ea45c2d3249&shallow=1";
    flake = false;
  };

  outputs =
    { nixpkgs, net-tree, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # net is 7.3-rc7 at the pinned rev: NixOS's config for linux_latest (7.3) fits it.
      linuxNet = pkgs.linux_latest.override {
        argsOverride = rec {
          src = net-tree;
          version = "7.3.0-rc7";
          modDirVersion = version;
        };
      };

      # One VM test per kernel. It passes only if the kernel routes every lookup correctly, so on
      # an affected kernel the check FAILS: that failure is the reproduction (see its log).
      reproTest =
        name: kernelPackages:
        pkgs.testers.runNixOSTest {
          name = "nexthop-suppress-${name}";
          nodes.machine = {
            boot.kernelPackages = kernelPackages;
            virtualisation.cores = 4;
            virtualisation.vlans = [ ];
            networking.useDHCP = false;
            environment.systemPackages = [
              pkgs.iproute2
              pkgs.util-linux
            ];
          };
          testScript = ''
            machine.wait_for_unit("multi-user.target")
            status, out = machine.execute("bash ${./repro.sh} 2>&1")
            print(out)
            assert status != 2, "setup or control case failed, see the output above"
            assert status == 0, "bug reproduced, see the output above"
          '';
        };
    in
    {
      checks.${system} = {
        linux-6_18 = reproTest "linux-6_18" pkgs.linuxPackages_6_18;
        linux-latest = reproTest "linux-latest" pkgs.linuxPackages_latest;
        linux-net = reproTest "linux-net" (pkgs.linuxPackagesFor linuxNet);
        wg-quick-6_18 = import ./wg-quick.nix {
          inherit pkgs nixpkgs;
          kernelPackages = pkgs.linuxPackages_6_18;
        };
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
