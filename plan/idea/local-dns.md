# Local DNS Server

## Problem

LAN devices cannot resolve machine hostnames (e.g., `builder`, `house`)
without manual `/etc/hosts` entries or mDNS. Accessing services requires
knowing the IP address, which can change if DHCP leases rotate.

## Proposal

Run a local DNS server on the LAN that resolves homelab hostnames to their
static IPs. All LAN devices would use this DNS server (configured via DHCP
from the router), making services accessible by name.

## Options

- **CoreDNS** — lightweight, config-file driven, packaged in nixpkgs
  (`services.coredns`). Good for static zones with a simple Corefile.
- **dnsmasq** — doubles as DHCP + DNS. If the router's DHCP is replaced by
  dnsmasq on a homelab machine, hostnames are registered automatically.
  Packaged in nixpkgs (`services.dnsmasq`).
- **Avahi/mDNS** — zero-config, no server needed. Each machine advertises
  its own `<hostname>.local`. Works natively on Apple devices and most Linux.
  Poor support on Android and some smart TVs. Simplest but least universal.

## Where to Host

The DNS server should run on a machine that is always on. Candidates:
- **builder** — already the most stable LAN machine
- **Dedicated VM** — cleanest, but another VM to manage
- **Router** — if it supports custom DNS (many consumer routers do not)

## Scope

A minimal setup would cover:
- `builder` -> builder's LAN IP
- Any future machines (e.g., `media` if the streaming stack is refactored
  out of builder)

Upstream DNS (for internet resolution) would be forwarded to the router or
a public resolver (1.1.1.1, 8.8.8.8).

## Decision

Not yet. Revisit when the number of machines or services makes IP-based
access unwieldy. For now, using direct IPs or SSH tunnels is sufficient.
