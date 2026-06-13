#!/usr/bin/env bash
# Host firewall for a launchpad Base mainnet node on a bare-metal / dedicated host.
#
# This is the AUTHORITATIVE network gate. The node binds its RPC to 0.0.0.0 inside
# the container with permissive CORS and the debug/txpool namespaces enabled, so the
# ONLY thing keeping it private is this firewall. Apply it BEFORE the node syncs on a
# public IP.
#
# Rule of thumb:
#   - P2P ports        -> open to the world (needed to find peers).
#   - RPC / WS / metrics -> reachable ONLY from the launchpad backend hosts.
#   - Engine authrpc (8551) -> never published; not handled here.
#
# Usage:
#   sudo BACKEND_CIDRS="10.0.0.0/24,203.0.113.10/32" bash ops/firewall/ufw.sh
#
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

# Comma-separated CIDRs allowed to reach the RPC. Default is empty = nobody.
BACKEND_CIDRS="${BACKEND_CIDRS:-}"

# Your SSH source(s). Lock SSH down too — replace with your admin IP/CIDR.
SSH_CIDR="${SSH_CIDR:-0.0.0.0/0}"

echo "Resetting ufw to a default-deny posture..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# SSH (consider changing the port and using key-only auth).
ufw allow from "${SSH_CIDR}" to any port 22 proto tcp

# Base node P2P — must be public so the node can peer.
#   execution P2P (docker-compose maps 30303), consensus P2P (9222).
ufw allow 30303/tcp
ufw allow 30303/udp
ufw allow 9222/tcp
ufw allow 9222/udp

# RPC / WS / metrics — private to the backend only.
if [[ -n "${BACKEND_CIDRS}" ]]; then
  IFS=',' read -ra CIDRS <<< "${BACKEND_CIDRS}"
  for cidr in "${CIDRS[@]}"; do
    echo "Allowing RPC/WS/metrics from ${cidr}"
    ufw allow from "${cidr}" to any port 8545 proto tcp   # HTTP RPC
    ufw allow from "${cidr}" to any port 8546 proto tcp   # WS RPC
    ufw allow from "${cidr}" to any port 7300 proto tcp   # op-node metrics
    ufw allow from "${cidr}" to any port 7301 proto tcp   # reth metrics
  done
else
  echo "WARNING: BACKEND_CIDRS is empty — RPC/WS/metrics will be reachable from NOBODY."
  echo "         Set BACKEND_CIDRS to your backend host(s) before the launchpad can use it."
fi

ufw --force enable
ufw status verbose
