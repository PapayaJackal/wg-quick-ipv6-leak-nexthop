# IPv6 `suppress_prefixlength` misroutes with a shared nexthop object

An IPv6 `suppress_prefixlength` rule judges a lookup by the per-CPU cached dst of the matched
route's nexthop, not by the matched route. When two routes share a nexthop object, that dst may
have been created for the other route. The rule then keeps or suppresses the wrong answer. Which
answer depends on the CPU, and on which route that CPU looked up first since the cache was last
reset. IPv4 is not affected.

**Affected:** 6.18.57, 7.3.0, and netdev `net` at abeacca61eea (7.3-rc7). Results were identical on all three.

## In common use

A host behind a router whose RAs carry a default route plus a route information option is
affected out of the box:
- systemd-networkd (tested: 260.5) puts both RA routes on one nexthop object.
- A full-tunnel wg-quick VPN (`AllowedIPs = ::/0`) adds `table main suppress_prefixlength 0`.

After a cache reset (a VPN restart, any rule change, some address changes), one connection into
the advertised route is enough. From then on, that CPU sends all IPv6 traffic meant for the tunnel
out through the LAN. The `wg-quick` check shows this in 3 of 3 attempts.

NetworkManager 1.56.1 was seen adding RA routes without nexthop objects, so it shouldn't be
affected.

## Reproducing

    nix build -L .#checks.x86_64-linux.linux-6_18     # 6.18.57
    nix build -L .#checks.x86_64-linux.linux-latest   # 7.3.0
    nix build -L .#checks.x86_64-linux.linux-net      # net, abeacca61eea
    nix build -L .#checks.x86_64-linux.wg-quick-6_18  # systemd-networkd + wg-quick, 6.18.57

Each check passes only on a correct kernel. A failing check is the reproduction: its log shows the
`BUG`/`LEAK` lines.

`repro.sh` runs on its own on any Linux machine with at least 2 CPUs. It needs root, iproute2
and taskset, and works in a network namespace it creates and removes. Exit status: 0 not
reproduced, 1 reproduced, 2 setup or control failure.

- **Main table:** `default nhid 1` and `2001:db8:64::/64 nhid 1`, with nexthop 1
  `via 2001:db8:1::1 dev uplink`.
- **Table 100:** `default via 2001:db8:2::1 dev vpn`.
- **Rules:** `5999: table main suppress_prefixlength 0`, then `6000: table 100`.

Lookups are `ip -6 route get`, pinned to one CPU with `taskset`, both locally generated and
forwarded. Before each case an IPv6 rule add/del resets the cache. A control runs the same routes
without nexthop objects.

| Case (CPU 0) | Result |
| --- | --- |
| looks up `2001:db8:64::1` first | `2001:db8:ffff::1` goes via **uplink** instead of vpn |
| then `ip -6 route flush cache` | no effect |
| looks up `2001:db8:ffff::1` first | `2001:db8:64::1` goes via **vpn** instead of uplink |
| looks up `2001:db8:64::1`, which is then deleted | `2001:db8:ffff::1` fails: **Network is unreachable** |
| control, no nexthop objects | all correct |

The same lookups on CPU 1 were correct every time, and forwarded traffic behaved the same as
locally generated.

## Cause (net/ipv6)

1. `rt6_get_pcpu_route()` returns `res->nh->rt6i_pcpu`, the cache slot of the shared nexthop. It
   doesn't check that the dst's `from` is the matched route `res->f6i`.
2. `ip6_rt_copy_init()` copies the creating route's prefix into the dst (`rt6i_dst`).
3. `fib6_rule_suppress()` tests `rt->rt6i_dst.plen`, the prefix stored in that dst.
   `fib4_rule_suppress()` tests `result->prefixlen`, the matched route's prefix.
4. These dsts stay valid while `sernum == rt_genid_ipv6(net)`. Adding or deleting routes, and
   `ip -6 route flush cache` (`fib6_run_gc()`), don't bump the genid. Rule changes, some
   address events, and nexthop changes do.
5. Deleting a route only clears its dsts' `from` (`__fib6_drop_pcpu_from()`). The dst stays in
   its slot, which leads to the "Network is unreachable" (exact path not traced).

**Possible fixes:**
- Reuse a per-CPU dst only if its `from` is `res->f6i`.
- Or test `res->f6i->fib6_dst.plen` in `fib6_rule_suppress()`.

## Workaround

Keep routes off the default route's nexthop object. With systemd-networkd, set
`UseRoutePrefix=false` under `[IPv6AcceptRA]`. Clearing an already-poisoned cache needs a genid
bump, for example adding and deleting any IPv6 rule.
