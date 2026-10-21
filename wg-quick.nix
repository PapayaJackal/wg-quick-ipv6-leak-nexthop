# The bug in common use: a host on systemd-networkd behind a home router whose router
# advertisements carry a default route plus one route information option, with a full-tunnel
# wg-quick VPN (AllowedIPs = ::/0, i.e. wg-quick's `suppress_prefixlength 0` rule). Nothing here
# is configured by hand: networkd puts the two RA routes on one nexthop object, wg-quick adds the
# rules.
#
# The router answers HTTP on an "internet" address (and on one in the advertised route) with the
# source address it saw. Through the VPN that is the host's WireGuard address; anything else
# means the request left through the home line. Like the other checks, it passes only if the
# kernel routes everything correctly.
{
  pkgs,
  kernelPackages,
  nixpkgs,
}:
let
  keys = import "${nixpkgs}/nixos/tests/wireguard/snakeoil-keys.nix";

  raPrefix = "2001:db8:a::"; # the home LAN's SLAAC prefix
  raRoute = "2001:db8:64::/64"; # the router's extra route (route information option)
  lanService = "2001:db8:64::1"; # something inside the extra route
  internet = "2001:db8:ffff::1"; # anything else on the internet
  hostWg = "fd00:77::2";
  routerWg = "fd00:77::1";
in
pkgs.testers.runNixOSTest {
  name = "nexthop-suppress-wg-quick";

  nodes.router =
    { lib, ... }:
    {
      networking.firewall.enable = false;
      boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;
      networking.interfaces.eth1.ipv6.addresses = lib.mkAfter [
        {
          address = "${raPrefix}1";
          prefixLength = 64;
        }
      ];
      services.radvd = {
        enable = true;
        config = ''
          interface eth1 {
            AdvSendAdvert on;
            MinRtrAdvInterval 3;
            MaxRtrAdvInterval 10;
            prefix ${raPrefix}/64 { AdvOnLink on; AdvAutonomous on; };
            route ${raRoute} { AdvRoutePreference high; };
          };
        '';
      };

      # The VPN server. The same machine also plays the internet, so a request reaches it
      # whichever way the host routes it.
      networking.wireguard.interfaces.wg0 = {
        ips = [ "${routerWg}/64" ];
        listenPort = 51820;
        inherit (keys.peer0) privateKey;
        peers = [
          {
            inherit (keys.peer1) publicKey;
            allowedIPs = [ "${hostWg}/128" ];
          }
        ];
      };
      systemd.services.extra-addresses = {
        wantedBy = [ "multi-user.target" ];
        before = [ "nginx.service" ];
        serviceConfig.Type = "oneshot";
        path = [ pkgs.iproute2 ];
        script = ''
          ip link add internet type dummy
          ip link set internet up
          ip -6 addr add ${internet}/128 dev internet nodad
          ip -6 addr add ${lanService}/128 dev internet nodad
        '';
      };
      services.nginx = {
        enable = true;
        virtualHosts.default = {
          default = true;
          listen = [
            {
              addr = "[::]";
              port = 80;
            }
          ];
          locations."/".return = ''200 "$remote_addr\n"'';
        };
      };
    };

  nodes.host =
    { nodes, ... }:
    {
      boot.kernelPackages = kernelPackages;
      virtualisation.cores = 4;
      networking.useNetworkd = true;
      networking.firewall.enable = false;
      # Nothing else should look up IPv6 routes in the background.
      services.timesyncd.enable = false;
      systemd.network.networks."40-eth1".networkConfig.IPv6AcceptRA = true;
      # QEMU's user-mode network on eth0 sends RAs too: keep the home LAN's the only default.
      networking.useDHCP = false;
      systemd.network.networks."30-eth0" = {
        matchConfig.Name = "eth0";
        networkConfig = {
          IPv6AcceptRA = false;
          LinkLocalAddressing = "no";
        };
      };
      environment.systemPackages = [
        pkgs.curl
        pkgs.util-linux
      ];

      networking.wg-quick.interfaces.wg0 = {
        address = [ "${hostWg}/64" ];
        inherit (keys.peer1) privateKey;
        peers = [
          {
            inherit (keys.peer0) publicKey;
            endpoint = "${nodes.router.networking.primaryIPAddress}:51820";
            allowedIPs = [ "::/0" ];
          }
        ];
      };
    };

  testScript = ''
    import re

    start_all()
    router.wait_for_unit("nginx.service")
    router.wait_for_unit("radvd.service")
    host.wait_for_unit("wg-quick-wg0.service")

    def seen_from(cpu, addr):
        return host.succeed(f"taskset -c {cpu} curl -sf --max-time 5 'http://[{addr}]/'").strip()

    with subtest("networkd put the RA default route and the extra route on one nexthop object"):
        host.wait_until_succeeds("ip -6 route show default | grep -q 'proto ra'", timeout=60)
        assert "eth0" not in host.succeed("ip -6 route show default"), "a default route on eth0"
        host.wait_until_succeeds("ip -6 route show ${raRoute} | grep -q 'proto ra'", timeout=60)
        print(host.succeed("ip -6 route show; ip -6 nexthop show; ip -6 rule show"))
        nhids = []
        for dst in ["default", "${raRoute}"]:
            m = re.search(r"nhid (\d+)", host.succeed(f"ip -6 route show {dst} dev eth1"))
            assert m, f"networkd did not use a nexthop object for {dst}"
            nhids.append(m[1])
        assert nhids[0] == nhids[1], f"separate nexthops: {nhids}"

    with subtest("the VPN works"):
        host.wait_until_succeeds("curl -sf --max-time 5 'http://[${internet}]/' | grep -qx ${hostWg}", timeout=60)

    with subtest("after a wg-quick restart, a LAN request on CPU 0 makes CPU 0 bypass the VPN"):
        # Restarting wg-quick re-adds its rules, which resets the per-CPU route cache (as do
        # other everyday events: rule changes, some address changes). The first lookup through
        # the RA nexthop on each CPU decides what that CPU's later lookups see.
        cpus = int(host.succeed("nproc"))
        leaks = []
        for attempt in range(3):
            host.succeed("systemctl restart wg-quick-wg0")
            lan = seen_from(0, "${lanService}")
            print(f"attempt {attempt}: LAN service on CPU 0 saw {lan}")
            for cpu in range(cpus):
                src = seen_from(cpu, "${internet}")
                ok = src == "${hostWg}"
                note = "" if ok else " (LEAK: not through the VPN)"
                print(f"attempt {attempt}: internet on CPU {cpu} saw {src}{note}")
                if not ok:
                    leaks.append((attempt, cpu, src))
        assert not leaks, f"requests that should use the VPN left through the home line: {leaks}"
  '';
}
