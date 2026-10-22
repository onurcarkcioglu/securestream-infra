# ADR-0001: Tailscale subnet router instead of port forwarding

**Status:** accepted · **Date:** 2026-10-20

## Context
The server sits behind an ISP using CGNAT: there is no public IPv4 to forward ports to. The admin works
remotely for months, so access must be reliable and must not expose management interfaces.

## Decision
Run Tailscale on the Proxmox host as a subnet router for `10.10.10.0/24`; the admin laptop joins the
tailnet. Split DNS sends `securestream.lab` queries to the lab DNS. No port is opened on the router.

## Consequences
- Zero inbound attack surface; WireGuard encryption end to end.
- Dependency on the Tailscale control plane and account security (MFA required).
- Network changes on the host are made with an `at`-scheduled rollback in case the tunnel breaks.
- Production equivalent: AWS SSM Session Manager or a private VPN gateway.
