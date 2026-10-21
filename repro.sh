#!/usr/bin/env bash
# Reproducer: IPv6 `suppress_prefixlength` judges a route lookup by the per-CPU cached dst of the
# matched route's nexthop. With a nexthop object shared by two routes, that dst can belong to the
# other route, so the rule keeps or suppresses the wrong answer depending on which CPU does the
# lookup and which destination was looked up first on that CPU since the last IPv6 genid bump.
#
# Runs in its own network namespace (needs root, iproute2, taskset). Exit status: 0 if every
# lookup is routed as expected, 1 if the bug reproduced, 2 if the setup or a control case failed.
set -euo pipefail

ns="nhbug-$$"
ip netns add "$ns"
trap 'ip netns del "$ns"' EXIT

nsip() { ip -n "$ns" "$@"; }

default_dst=2001:db8:ffff::1 # only covered by the default routes
specific_dst=2001:db8:64::1  # covered by the specific route in the main table
lan_src=2001:db8:3::5        # a forwarded packet's source, arriving on "lan"

bugs=0
control_failures=0

setup() {
	local mode=$1 # "nexthop": both main-table routes share one nexthop object; "classic": no nhid
	ip netns exec "$ns" sysctl -qw net.ipv6.conf.all.forwarding=1
	nsip link set lo up
	for dev in uplink vpn lan; do
		nsip link add "$dev" type dummy
		nsip link set "$dev" up
	done
	nsip -6 addr add 2001:db8:1::2/64 dev uplink nodad
	nsip -6 addr add 2001:db8:2::2/64 dev vpn nodad
	nsip -6 addr add 2001:db8:3::1/64 dev lan nodad

	# Main table, like a host that took its IPv6 default route and one extra route (an RA route
	# information option) from the LAN router: networkd puts both on one nexthop object.
	if [[ $mode == nexthop ]]; then
		nsip nexthop add id 1 via 2001:db8:1::1 dev uplink
		nsip -6 route add default nhid 1
		nsip -6 route add 2001:db8:64::/64 nhid 1
	else
		nsip -6 route add default via 2001:db8:1::1 dev uplink
		nsip -6 route add 2001:db8:64::/64 via 2001:db8:1::1 dev uplink
	fi

	# Everything the main table only has a default route for goes through the VPN instead
	# (the wg-quick pattern).
	nsip -6 route add default via 2001:db8:2::1 dev vpn table 100
	nsip -6 rule add pref 5999 table main suppress_prefixlength 0
	nsip -6 rule add pref 6000 table 100
}

teardown() {
	for dev in uplink vpn lan; do
		nsip link del "$dev"
	done
	nsip nexthop flush >/dev/null 2>&1 || true
	nsip -6 rule del pref 5999
	nsip -6 rule del pref 6000
}

# Any IPv6 rule change bumps the netns's IPv6 route genid, invalidating every per-CPU dst that
# belongs to a nexthop-object route: the next lookup on each CPU creates a fresh one.
reset_cache() {
	nsip -6 rule add pref 7000 table 100
	nsip -6 rule del pref 7000
}

# Prints the device a lookup on CPU $1 resolves to ("error: ..." if it fails).
# $2: "out" (locally generated) or "fwd" (forwarded from "lan"); $3: destination.
route_dev() {
	local cpu=$1 kind=$2 dst=$3 out
	local args=("$dst")
	[[ $kind == fwd ]] && args+=(from "$lan_src" iif lan)
	if out=$(taskset -c "$cpu" ip -n "$ns" -6 route get "${args[@]}" 2>&1); then
		sed -n 's/.* dev \([^ ]*\).*/\1/p' <<<"$out" | head -n1
	else
		echo "error: $out"
	fi
}

expect() {
	local label=$1 want=$2 got=$3 mode=$4
	if [[ $got == "$want" ]]; then
		echo "  ok    $label: $got"
	elif [[ $mode == nexthop ]]; then
		echo "  BUG   $label: $got (expected $want)"
		bugs=$((bugs + 1))
	else
		echo "  FAIL  $label: $got (expected $want; control case without nexthop objects)"
		control_failures=$((control_failures + 1))
	fi
}

cpus=$(nproc)
if ((cpus < 2)); then
	echo "need at least 2 CPUs (to show that only the CPU with the poisoned cache misroutes)" >&2
	exit 2
fi

echo "kernel $(uname -r), $cpus CPUs"
for mode in nexthop classic; do
	setup "$mode"
	echo
	echo "== main-table routes $([[ $mode == nexthop ]] && echo "sharing nexthop object 1" || echo "without nexthop objects (control)")"
	for kind in out fwd; do
		if [[ $kind == out ]]; then
			echo "-- locally generated traffic"
		else
			echo "-- traffic forwarded from lan"
		fi

		reset_cache
		echo " CPU 0 looks up the specific destination first, then the default one:"
		expect "CPU 0 $specific_dst" uplink "$(route_dev 0 "$kind" "$specific_dst")" "$mode"
		expect "CPU 0 $default_dst" vpn "$(route_dev 0 "$kind" "$default_dst")" "$mode"
		expect "CPU 1 $default_dst" vpn "$(route_dev 1 "$kind" "$default_dst")" "$mode"
		nsip -6 route flush cache
		expect "CPU 0 $default_dst after 'ip -6 route flush cache'" vpn \
			"$(route_dev 0 "$kind" "$default_dst")" "$mode"

		reset_cache
		echo " CPU 0 looks up the default destination first, then the specific one:"
		expect "CPU 0 $default_dst" vpn "$(route_dev 0 "$kind" "$default_dst")" "$mode"
		expect "CPU 0 $specific_dst" uplink "$(route_dev 0 "$kind" "$specific_dst")" "$mode"
		expect "CPU 1 $specific_dst" uplink "$(route_dev 1 "$kind" "$specific_dst")" "$mode"
	done

	reset_cache
	echo "-- after CPU 0 looked up the specific destination, the specific route is deleted:"
	route_dev 0 out "$specific_dst" >/dev/null
	nsip -6 route del 2001:db8:64::/64
	expect "CPU 0 $default_dst" vpn "$(route_dev 0 out "$default_dst")" "$mode"
	expect "CPU 1 $default_dst" vpn "$(route_dev 1 out "$default_dst")" "$mode"
	teardown
done

echo
if ((control_failures)); then
	echo "RESULT: $control_failures control lookup(s) failed: the setup is wrong, not the kernel"
	exit 2
elif ((bugs)); then
	echo "RESULT: bug reproduced ($bugs misrouted lookup(s) with a shared nexthop object)"
	exit 1
fi
echo "RESULT: not reproduced, every lookup was routed as expected"
