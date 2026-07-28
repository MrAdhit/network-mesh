#!/bin/sh
# Remove every trace of the mesh software from this machine.
#
#   curl -fsSL https://your-control-plane/uninstall.sh | sh
#
# Order matters. Deregistering comes first, because a node whose files are gone still holds a
# roster entry and an allocated address, and the credential that proves we may remove it is one
# of the things about to be deleted.
#
# Package removal hooks call this too, so there is one teardown path rather than three that
# drift apart.
set -eu

PREFIX="${MESH_PREFIX:-/usr/local}"
STATE_DIR="${MESH_STATE_DIR:-/var/lib/mesh}"
PURGE=0
KEEP_ACCOUNT=0

usage() {
    cat <<EOF
uninstall.sh - remove the mesh software from this machine

    --purge          also delete the control plane's database, if meshcp is installed here
    --keep-account   do not deregister from the control plane, just remove the local software
    --prefix <dir>   install root, default /usr/local
    -h, --help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --purge) PURGE=1; shift ;;
        --keep-account) KEEP_ACCOUNT=1; shift ;;
        --prefix) PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option $1" >&2; usage >&2; exit 2 ;;
    esac
done

say() { printf '%s\n' "$*"; }
gone() { say "  removed $*"; }

[ "$(id -u)" = 0 ] || { echo "run this as root" >&2; exit 1; }

os=$(uname -s)

# ---- 1. leave the network ----

# Read before anything is deleted, so we can still name the node if the control plane is
# unreachable and its record has to be removed by hand.
NODE_ID=""
if [ -f "$STATE_DIR/state.json" ]; then
    NODE_ID=$(tr -d ' \t\n' < "$STATE_DIR/state.json" |
        sed -n 's/.*"node_id":"\([^"]*\)".*/\1/p' | head -1)
fi

if [ "$KEEP_ACCOUNT" = 0 ] && [ -x "$PREFIX/bin/meshctl" ]; then
    say "leaving the network"
    if "$PREFIX/bin/meshctl" leave 2>/dev/null; then
        NODE_ID=""
    else
        say "  the daemon did not answer; the control plane may still hold this node's record"
    fi
fi

# ---- 2. stop the service ----

say "stopping the service"
if [ "$os" = Linux ] && command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now meshd.service 2>/dev/null || true
    if [ -f /etc/systemd/system/meshd.service ]; then
        rm -f /etc/systemd/system/meshd.service
        gone /etc/systemd/system/meshd.service
    fi
    if [ "$PURGE" = 1 ] || [ -f /etc/systemd/system/meshcp.service ]; then
        systemctl disable --now meshcp.service 2>/dev/null || true
        rm -f /etc/systemd/system/meshcp.service
    fi
    systemctl daemon-reload 2>/dev/null || true
elif [ "$os" = Darwin ]; then
    launchctl bootout system/net.mesh.meshd 2>/dev/null || true
    if [ -f /Library/LaunchDaemons/net.mesh.meshd.plist ]; then
        rm -f /Library/LaunchDaemons/net.mesh.meshd.plist
        gone /Library/LaunchDaemons/net.mesh.meshd.plist
    fi
fi
# Whatever the service manager did or did not do, nothing of ours should still be running.
pkill -x meshd 2>/dev/null || true

# ---- 3. binaries ----

say "removing binaries"
for bin in meshd meshctl meshcp tuncheck; do
    if [ -e "$PREFIX/bin/$bin" ]; then
        rm -f "$PREFIX/bin/$bin"
        gone "$PREFIX/bin/$bin"
    fi
done

# ---- 4. machine state ----

say "removing state"
# Holds the node's keys, its registration, and the control socket.
if [ -d "$STATE_DIR" ]; then
    rm -rf "$STATE_DIR"
    gone "$STATE_DIR"
fi
for f in /etc/mesh/meshd.env; do
    [ -e "$f" ] && rm -f "$f" && gone "$f"
done
rmdir /etc/mesh 2>/dev/null || true
# The CLI's throttle marker for update checks. Worthless, but it is ours.
rm -f "${TMPDIR:-/tmp}/mesh-update-check" /tmp/mesh-update-check 2>/dev/null || true
rm -f /var/log/meshd.log 2>/dev/null || true

# ---- 5. per-user sessions ----

# The account session belongs to whoever logged in, so it is in a home directory rather than in
# the state directory. Only the people we can identify are touched: deleting inside every home
# on the machine is a bigger claim than an uninstall gets to make.
say "removing stored sessions"

# `~user` is not expanded from a variable in POSIX sh, so ask the system where a home is
# rather than assembling a path and hoping.
home_of() {
    if command -v getent >/dev/null 2>&1; then
        getent passwd "$1" | cut -d: -f6
    elif [ -d "/Users/$1" ]; then
        echo "/Users/$1"
    elif [ -d "/home/$1" ]; then
        echo "/home/$1"
    fi
}

user_config() {
    [ -n "${1:-}" ] || return 0
    for p in "$1/.config/mesh" "$1/Library/Application Support/mesh"; do
        if [ -d "$p" ]; then
            rm -rf "$p"
            gone "$p"
        fi
    done
}

# Whoever is running this, and whoever they sudo'd from: those are the two we can say belong to
# this uninstall.
MINE="${HOME:-/root}"
THEIRS=""
if [ -n "${SUDO_USER:-}" ]; then
    THEIRS=$(home_of "$SUDO_USER")
fi
user_config "$MINE"
user_config "$THEIRS"

others=""
for home in /home/* /Users/*; do
    [ -d "$home" ] || continue
    [ "$home" = "$MINE" ] && continue
    [ "$home" = "$THEIRS" ] && continue
    if [ -d "$home/.config/mesh" ] || [ -d "$home/Library/Application Support/mesh" ]; then
        others="$others $home"
    fi
done
if [ -n "$others" ]; then
    say "  other users still have a stored session:$others"
    say "  they are that user's to delete, so this left them alone"
fi

# ---- 6. the control plane, if this machine is one ----

if [ -d /var/lib/meshcp ]; then
    if [ "$PURGE" = 1 ]; then
        rm -rf /var/lib/meshcp
        gone "/var/lib/meshcp"
        rm -f /etc/meshcp/meshcp.env
        rmdir /etc/meshcp 2>/dev/null || true
    else
        # Removing the software from a server is not the same statement as destroying the
        # network it runs. That database holds every account, every node and the sealed vendor
        # credentials, and nothing else has a copy.
        say ""
        say "left /var/lib/meshcp alone: it holds the accounts and the sealed backhaul"
        say "credentials for this network. Re-run with --purge to destroy it."
    fi
fi

say ""
if [ -n "$NODE_ID" ]; then
    say "this node was not deregistered. Remove its record with:"
    say "    meshctl remove-node $NODE_ID"
else
    say "done; nothing of ours is left on this machine"
fi
