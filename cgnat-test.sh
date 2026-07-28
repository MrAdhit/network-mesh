#!/usr/bin/env bash
# Put mesh-a behind a simulated CGNAT and see whether a direct path still forms.
#
# Topology:
#   meshcp, mesh-b, router   on  "cp"       (the far side of the NAT)
#   router, mesh-a           on  "private"  (behind it)
# mesh-a's default route points at the router, which masquerades. Nothing on cp can open a
# connection into private; mesh-a has to punch its way out.
set -euo pipefail
cd "$(dirname "$0")"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

say "building the NAT topology"
docker compose -f docker-compose.cgnat.yml down -v >/dev/null 2>&1 || true
docker compose -f docker-compose.cgnat.yml up -d router meshcp
sleep 3

# NAT_MODE=random forces the router to randomise source ports, which turns a port-preserving
# NAT into an endpoint-dependent one. That is the case prediction cannot solve by arithmetic and
# where peer observation of the punch has to carry it.
NAT_MODE=${NAT_MODE:-preserve}

say "configuring the router to masquerade (${NAT_MODE})"
RANDOM_FLAG=""
[ "$NAT_MODE" = "random" ] && RANDOM_FLAG="--random-fully"
docker exec cgnat-router sh -c "
  echo 1 > /proc/sys/net/ipv4/ip_forward
  iptables -t nat -F POSTROUTING
  iptables -t nat -A POSTROUTING -s 10.99.0.0/16 -j MASQUERADE $RANDOM_FLAG
  echo \"ip_forward=\$(cat /proc/sys/net/ipv4/ip_forward), masquerading 10.99.0.0/16 $RANDOM_FLAG\"
"

say "starting the control plane account"
until curl -sf http://127.0.0.1:8080/health >/dev/null 2>&1; do sleep 1; done
source .env.secrets
cpctl() {
    docker exec -e MESH_CP_URL=http://meshcp:8080 -e MESH_CONFIG=/var/lib/meshcp/cli.json \
        meshcp /opt/mesh/meshctl "$@"
}
# meshctl stores the session itself; MESH_CONFIG keeps it in the control plane's volume.
cpctl signup dev@example.com devpassword 10.201.0.0/16 >/dev/null 2>&1 || \
    cpctl login dev@example.com devpassword >/dev/null
cpctl set-cloudflare "$CF_API_TOKEN" "$CF_ACCOUNT_ID" >/dev/null
cpctl set-tailscale "$TS_API_TOKEN" >/dev/null
KEY=$(cpctl enrollment-key | head -1)
echo "MESH_ENROLLMENT_KEY=$KEY" > .env.cgnat

say "starting the nodes"
MESH_ENROLLMENT_KEY=$KEY docker compose -f docker-compose.cgnat.yml up -d mesh-a mesh-b

say "cutting the shortcut"
# OrbStack routes between bridges, so without this mesh-b can simply reach 10.99.0.10 and no
# punching is needed. Dropping the private range at mesh-b leaves it only one way in: the
# router's public address, which requires a NAT binding that only mesh-a can create.
docker exec mesh-b sh -c '
  iptables -C OUTPUT -d 10.99.0.0/16 -j DROP 2>/dev/null \
    || iptables -A OUTPUT -d 10.99.0.0/16 -j DROP
  echo "mesh-b can no longer reach 10.99.0.0/16 directly"
'

say "waiting for both nodes"
until docker exec mesh-a meshctl status >/dev/null 2>&1 && docker exec mesh-b meshctl status >/dev/null 2>&1; do sleep 3; done
sleep 40

say "mesh-a is behind the NAT"
docker exec mesh-a ip -br addr | grep -v lo
docker exec mesh-a ip route | head -2

say "confirming mesh-b really cannot take a shortcut"
docker exec mesh-b ping -c 2 -W 2 10.99.0.10 2>&1 | tail -2 || true

say "did a direct path form through the NAT?"
docker exec mesh-a meshctl peers
echo
docker exec mesh-a meshctl status | grep -E 'node|address'

say "what the node worked out about its NAT"
docker logs mesh-a 2>&1 | grep -i 'nat profile' | tail -1

say "reflexive address as seen by the STUN responder"
docker logs mesh-a 2>&1 | grep -i 'reflexive address' | tail -2
docker logs meshcp 2>&1 | grep -i 'told a node' | tail -3
