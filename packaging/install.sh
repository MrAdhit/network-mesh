#!/bin/sh
# Install meshd and meshctl, and set them up to run as a service.
#
# The control plane already serves the binaries nodes update themselves from, hashed and
# unauthenticated, so this fetches from there rather than from a release page: one place holds
# the build a network expects its nodes to be running, and this is that place.
#
#   curl -fsSL https://your-control-plane/install.sh | sh
#   curl -fsSL https://your-control-plane/install.sh | sh -s -- --key mkey_...
#
# meshcp fills in its own URL when it serves this file. Anywhere else, pass --cp-url.
set -eu

CP_URL="${MESH_CP_URL:-@CP_URL@}"
PREFIX="${MESH_PREFIX:-/usr/local}"
ENROLLMENT_KEY=""
WITH_SERVICE=1
STATE_DIR="${MESH_STATE_DIR:-/var/lib/mesh}"

usage() {
    cat <<EOF
install.sh - install the mesh node daemon and CLI

    --cp-url <url>   control plane to fetch from and enrol with
    --key <key>      enrollment key; joins the network once the daemon is up
    --prefix <dir>   install root, default /usr/local
    --no-service     install the binaries only, no systemd unit or launchd job
    -h, --help

Environment: MESH_CP_URL, MESH_PREFIX and MESH_STATE_DIR do the same as the flags.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --cp-url) CP_URL="${2:?--cp-url needs a URL}"; shift 2 ;;
        --key) ENROLLMENT_KEY="${2:?--key needs an enrollment key}"; shift 2 ;;
        --prefix) PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
        --no-service) WITH_SERVICE=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option $1" >&2; usage >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

# An unsubstituted placeholder still starts with `@`, and no URL does. Matching on that rather
# than on the placeholder itself matters: meshcp substitutes every occurrence, so a guard
# spelling the token out would be rewritten into a test against the real URL and reject it.
case "$CP_URL" in
    ""|@*) die "no control plane to install from; pass --cp-url https://..." ;;
esac
CP_URL="${CP_URL%/}"

[ "$(id -u)" = 0 ] || die "run this as root: it writes to $PREFIX/bin, $STATE_DIR and the service manager"

# ---- what are we ----

os=$(uname -s)
arch=$(uname -m)
case "$os:$arch" in
    Linux:x86_64|Linux:amd64)     TARGET=x86_64-unknown-linux-gnu ;;
    Linux:aarch64|Linux:arm64)    TARGET=aarch64-unknown-linux-gnu ;;
    Darwin:arm64)                 TARGET=aarch64-apple-darwin ;;
    Darwin:x86_64)                die "Intel Macs are not a target; Apple Silicon only" ;;
    *)                            die "no build for $os $arch" ;;
esac
say "installing for $TARGET from $CP_URL"

# ---- tools ----

if command -v curl >/dev/null 2>&1; then
    fetch() { curl -fsSL "$1" -o "$2"; }
    fetch_stdout() { curl -fsSL "$1"; }
elif command -v wget >/dev/null 2>&1; then
    fetch() { wget -qO "$2" "$1"; }
    fetch_stdout() { wget -qO- "$1"; }
else
    die "need curl or wget"
fi

# Verification is the whole reason the manifest exists, so a machine with no way to hash a file
# does not get a quiet install, it gets a refusal.
if command -v sha256sum >/dev/null 2>&1; then
    sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
    sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
elif command -v openssl >/dev/null 2>&1; then
    sha256() { openssl dgst -sha256 "$1" | sed 's/.*= *//'; }
else
    die "need sha256sum, shasum or openssl to verify what we download"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/mesh-install.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM

# ---- fetch and verify ----

MANIFEST_URL="$CP_URL/v1/updates/$TARGET"
manifest=$(fetch_stdout "$MANIFEST_URL") || die "could not reach $MANIFEST_URL"
# One object per line, whitespace removed, so a name and its hash can be read off together.
manifest=$(printf '%s' "$manifest" | tr -d ' \t\n' | tr '{' '\n')

want_sha() {
    printf '%s\n' "$manifest" | grep "\"name\":\"$1\"" |
        sed -n 's/.*"sha256":"\([0-9a-fA-F]*\)".*/\1/p' | head -1
}

for bin in meshd meshctl; do
    sha=$(want_sha "$bin")
    [ -n "$sha" ] || die "$CP_URL has no $bin build for $TARGET"
    fetch "$MANIFEST_URL/$bin" "$TMP/$bin" || die "downloading $bin failed"
    got=$(sha256 "$TMP/$bin")
    [ "$got" = "$sha" ] || die "$bin does not match what $CP_URL promised ($got, wanted $sha)"
    chmod 0755 "$TMP/$bin"
    say "$bin  verified $(echo "$sha" | cut -c1-12)"
done

# ---- install ----

mkdir -p "$PREFIX/bin"
for bin in meshd meshctl; do
    # Renamed into place rather than written over, because the running daemon may be this very
    # file: replacing the inode leaves the running process on the old one, writing into it does
    # not and would corrupt a live binary.
    mv -f "$TMP/$bin" "$PREFIX/bin/$bin.new"
    mv -f "$PREFIX/bin/$bin.new" "$PREFIX/bin/$bin"
done
say "installed into $PREFIX/bin"

mkdir -p "$STATE_DIR"
chmod 0700 "$STATE_DIR"

# The key is staged rather than passed on a command line: meshd reads it on first start and
# deletes it, so a node an operator later removes cannot quietly re-enrol itself on reboot.
if [ -n "$ENROLLMENT_KEY" ]; then
    umask 077
    printf '%s\n' "$ENROLLMENT_KEY" > "$STATE_DIR/enrollment-key"
    say "enrollment key staged in $STATE_DIR"
fi

# Where the operator puts anything else the daemon needs. Kept even when empty, because the
# systemd unit references it and an operator looking for "where do I set that" should find it.
mkdir -p /etc/mesh
if [ ! -f /etc/mesh/meshd.env ]; then
    cat > /etc/mesh/meshd.env <<EOF
# Environment for meshd. Everything here is optional.
#
# MESH_CP_URL=$CP_URL
# MESH_NODE_NAME=$(hostname 2>/dev/null || echo mesh-node)
# MESH_LOG=info,mesh_core=debug
# MESH_AUTOUPDATE=0
EOF
    chmod 0644 /etc/mesh/meshd.env
fi

# ---- service ----

start_systemd() {
    cat > /etc/systemd/system/meshd.service <<EOF
[Unit]
Description=mesh node daemon
Documentation=$CP_URL
# The backhauls need routable addresses, and coming up before there are any just means the
# first minute is spent retrying.
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$PREFIX/bin/meshd
EnvironmentFile=-/etc/mesh/meshd.env
# Creates and owns /var/lib/mesh, which holds the node's keys and registration.
StateDirectory=mesh
# The interface is the only thing here that needs privilege.
AmbientCapabilities=CAP_NET_ADMIN
DeviceAllow=/dev/net/tun rw
# A node that dies should come back: an unattended machine has nobody to restart it, and a
# mesh member that stays down is the failure this project exists to avoid.
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now meshd.service
    say "meshd.service enabled and started"
}

start_launchd() {
    cat > /Library/LaunchDaemons/net.mesh.meshd.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>net.mesh.meshd</string>
    <key>ProgramArguments</key>
    <array><string>$PREFIX/bin/meshd</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/var/log/meshd.log</string>
    <key>StandardErrorPath</key><string>/var/log/meshd.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>MESH_CP_URL</key><string>$CP_URL</string>
    </dict>
</dict>
</plist>
EOF
    chmod 0644 /Library/LaunchDaemons/net.mesh.meshd.plist
    # bootout first so a reinstall reloads rather than failing on an already-loaded label.
    launchctl bootout system/net.mesh.meshd 2>/dev/null || true
    launchctl bootstrap system /Library/LaunchDaemons/net.mesh.meshd.plist
    say "net.mesh.meshd loaded"
}

if [ "$WITH_SERVICE" = 1 ]; then
    if [ "$os" = Linux ] && command -v systemctl >/dev/null 2>&1; then
        start_systemd
    elif [ "$os" = Darwin ]; then
        start_launchd
    else
        WITH_SERVICE=0
        say "no systemd or launchd here; start meshd yourself"
    fi
fi

# ---- did it work ----

if [ "$WITH_SERVICE" = 1 ]; then
    # Enrolling takes a round trip to the control plane and both backhauls take longer, so wait
    # for the answer rather than printing "installed" and leaving the user to discover it did
    # not come up.
    i=0
    while [ "$i" -lt 20 ]; do
        if "$PREFIX/bin/meshctl" status >/dev/null 2>&1; then
            say ""
            "$PREFIX/bin/meshctl" status
            break
        fi
        i=$((i + 1))
        sleep 1
    done
    if [ "$i" -ge 20 ]; then
        say "the daemon did not answer within 20s; check its log"
    fi
fi

say ""
if [ -z "$ENROLLMENT_KEY" ]; then
    say "next: meshctl join <enrollment-key>   (mint one with 'meshctl enrollment-key')"
fi
say "uninstall: curl -fsSL $CP_URL/uninstall.sh | sh"
