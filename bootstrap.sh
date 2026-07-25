#!/usr/bin/env bash
# Create an account on the control plane, hand it the backhaul credentials, mint an
# enrollment key and start the nodes.
#
# Reads CF_API_TOKEN, CF_ACCOUNT_ID and TS_API_TOKEN from .env.secrets.
set -euo pipefail
cd "$(dirname "$0")"

[ -f .env.secrets ] || { echo "create .env.secrets with CF_API_TOKEN, CF_ACCOUNT_ID, TS_API_TOKEN"; exit 1; }
# shellcheck disable=SC1091
source .env.secrets

EMAIL=${MESH_EMAIL:-dev@example.com}
PASSWORD=${MESH_PASSWORD:-devpassword}
SUBNET=${MESH_SUBNET:-10.201.0.0/16}
export MESH_CP_URL=${MESH_CP_URL:-http://127.0.0.1:8080}
CTL=./target-linux/release/meshctl
command -v "$CTL" >/dev/null 2>&1 || CTL="docker exec -e MESH_CP_URL=http://meshcp:8080 -e MESH_SESSION meshcp /opt/mesh/meshctl"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

say "starting the control plane"
docker compose up -d meshcp
until curl -sf "$MESH_CP_URL/health" >/dev/null 2>&1; do sleep 1; done
echo "control plane is up"

say "creating the account"
OUT=$(docker exec -e MESH_CP_URL=http://meshcp:8080 meshcp /opt/mesh/meshctl \
        signup "$EMAIL" "$PASSWORD" "$SUBNET" 2>&1) || \
OUT=$(docker exec -e MESH_CP_URL=http://meshcp:8080 meshcp /opt/mesh/meshctl \
        login "$EMAIL" "$PASSWORD")
SESSION=$(echo "$OUT" | grep -o 'MESH_SESSION=.*' | cut -d= -f2)
[ -n "$SESSION" ] || { echo "could not get a session:"; echo "$OUT"; exit 1; }
echo "session acquired"

cpctl() { docker exec -e MESH_CP_URL=http://meshcp:8080 -e MESH_SESSION="$SESSION" meshcp /opt/mesh/meshctl "$@"; }

say "handing over the backhaul credentials"
cpctl set-cloudflare "$CF_API_TOKEN" "$CF_ACCOUNT_ID"
cpctl set-tailscale "$TS_API_TOKEN"

say "network"
cpctl network

say "minting an enrollment key"
KEY=$(cpctl enrollment-key | head -1)
echo "MESH_ENROLLMENT_KEY=$KEY" > .env
echo "MESH_CP_SECRET=${MESH_CP_SECRET:-dev-secret-change-me}" >> .env
echo "key written to .env"

say "starting the nodes"
docker compose up -d mesh-a mesh-b
echo "run ./demo.sh once they settle, or: docker exec mesh-a meshctl status"
