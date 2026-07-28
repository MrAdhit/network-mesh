#!/usr/bin/env bash
# End-to-end demonstration: a control plane, two nodes, three racing paths, a real kernel
# interface, and a TCP connection that survives losing its path.
#
# Run ./bootstrap.sh first to create the account and enroll the nodes.
set -euo pipefail
cd "$(dirname "$0")"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

say "the network, from the control plane"
# bootstrap.sh already logged in and meshctl stored the session, so this only needs to point at
# the same config.
cpctl() {
    docker exec -e MESH_CP_URL=http://meshcp:8080 -e MESH_CONFIG=/var/lib/meshcp/cli.json \
        meshcp /opt/mesh/meshctl "$@"
}
cpctl login "${MESH_EMAIL:-dev@example.com}" "${MESH_PASSWORD:-devpassword}" >/dev/null
cpctl network
cpctl nodes

say "node status"
docker exec mesh-a meshctl status

say "three paths to mesh-b, raced"
docker exec mesh-a meshctl ping mesh-b 4
docker exec mesh-a meshctl peers

say "the kernel interface"
docker exec mesh-a ip addr show mesh0 | sed -n '1p;4p'
docker exec mesh-a ip route | grep mesh0

say "real ICMP over the mesh"
docker exec mesh-a ping -c 4 10.201.0.3

say "real TCP over the mesh: 2MB"
docker exec -d mesh-b sh -c 'dd if=/dev/zero bs=1024 count=2048 2>/dev/null | nc -l -p 9100 -q1'
sleep 2
docker exec mesh-a bash -c '
  START=$(date +%s%N)
  BYTES=$(nc -w 30 10.201.0.3 9100 | wc -c)
  MS=$(( ($(date +%s%N)-START)/1000000 ))
  echo "received $BYTES bytes in ${MS}ms ($(( BYTES*8/MS/1000 )) Mbit/s)"'

say "a live TCP stream survives losing its path"
docker exec -d mesh-b sh -c 'i=0; while [ $i -lt 60 ]; do echo "tick $i"; i=$((i+1)); sleep 1; done | nc -l -p 9110 -q1'
sleep 2
docker exec -d mesh-a sh -c 'nc -w 60 10.201.0.3 9110 > /tmp/stream.txt'
sleep 6
echo "path in use: $(docker exec mesh-a meshctl peers | grep -o 'best=[a-z-]*')"
echo "ticks received: $(docker exec mesh-a sh -c 'wc -l < /tmp/stream.txt')"

echo "-> dropping the direct path"
docker exec mesh-a iptables -A OUTPUT -p udp --dport 47778 -j DROP
docker exec mesh-a iptables -A INPUT -p udp --dport 47778 -j DROP
sleep 20
echo "path in use: $(docker exec mesh-a meshctl peers | grep -o 'best=[a-z-]*')"
echo "ticks received: $(docker exec mesh-a sh -c 'wc -l < /tmp/stream.txt')  <- kept counting, no reconnect"
docker exec mesh-a iptables -D OUTPUT -p udp --dport 47778 -j DROP
docker exec mesh-a iptables -D INPUT -p udp --dport 47778 -j DROP

say "done"
echo "the direct path returns within about 20s; check with: docker exec mesh-a meshctl peers"
