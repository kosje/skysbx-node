#!/usr/bin/env bash
# Install a skysbx node on a Debian/Ubuntu host and point it at a panel.
#
#   sudo ./install-node.sh --panel https://panel.example.com --token <token>
#
# Re-running upgrades the binary in place.
set -euo pipefail

ROOT=${SKYSBX_ROOT:-/opt/skysbx}
PANEL=""
TOKEN=""
DOMAIN=""
EMAIL=""
CF_TOKEN=""
SKIP_CERT=0
SRC_DIR=""
FORK_DIR=""
GH_TOKEN=${GITHUB_TOKEN:-}
GH_OWNER=${SKYSBX_GH_OWNER:-kosje}
REF=${SKYSBX_REF:-main}
# The fork is a separate repository on its own release line and does not carry
# this one's branches. It deliberately does not inherit SKYSBX_REF: pointing
# the node at a branch used to try to clone a same-named branch of the fork,
# which does not exist, and the failure was reported as a missing token.
FORK_REF=${SKYSBX_FORK_REF:-main}

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
say()  { printf '%s==>%s %s\n' "$BLD" "$RST" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s warn%s %s\n' "$YLW" "$RST" "$*"; }
die()  { printf '%s fail%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

ACTION=install

usage() {
    cat <<EOF
Usage: sudo ./install-node.sh [--panel <url> --token <token>] [options]

Actions (default: install)
  --version         What is installed, including the sing-box it embeds.
  --upgrade         Rebuild from the current sources and restart. Reads the
                    panel URL and token back from ${ROOT}/node.env, so it needs
                    no arguments. This is also how the sing-box core is updated:
                    the node links it, so a rebuild is the upgrade.
  --uninstall       Stop and remove the service and the binary. Keeps the
                    certificate and ${ROOT}/node.env, so a reinstall is a
                    no-argument --upgrade away.
  --purge           --uninstall, and delete everything else this installer
                    created: the environment file, the certificate, the build
                    cache, the Go toolchain, and the Let's Encrypt account for
                    this node's domain.

Install options
  --panel <url>     Panel base URL, e.g. https://panel.example.com
  --token <token>   Join token, shown once when the node was added in the panel.

  --domain <fqdn>   This node's own domain. Only AnyTLS needs it — Reality and
                    Shadowsocks authenticate without a certificate — so it is
                    optional. Must be DNS-only: none of the three protocols is
                    HTTP, and a CDN in front breaks all of them.
  --email <addr>    Let's Encrypt contact address (default admin@<domain>).
  --cf-token <tok>  Cloudflare API token, to validate over DNS-01 when port 80
                    is not reachable.
  --no-cert         Skip certificate issuance.

  --src <dir>       Build from a checkout on disk instead of cloning.
  --fork <dir>      Path to the patched sing-box; defaults to a sibling clone.
  -h, --help        This text.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version)   ACTION=version; shift ;;
        --upgrade)   ACTION=upgrade; shift ;;
        --uninstall) ACTION=uninstall; shift ;;
        --purge)     ACTION=purge; shift ;;
        --panel)     PANEL=$2; shift 2 ;;
        --token)     TOKEN=$2; shift 2 ;;
        --domain)    DOMAIN=$2; shift 2 ;;
        --email)     EMAIL=$2; shift 2 ;;
        --cf-token)  CF_TOKEN=$2; shift 2 ;;
        --no-cert)   SKIP_CERT=1; shift ;;
        --src)       SRC_DIR=$2; shift 2 ;;
        --fork)      FORK_DIR=$2; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

# ───────────────────────── version / uninstall / purge ─────────────────────

if [ "$ACTION" = version ]; then
    if [ -x "$ROOT/skysbx-node" ]; then
        "$ROOT/skysbx-node" -version
        printf 'installed  %s\n' "$(stat -c %y "$ROOT/skysbx-node" 2>/dev/null | cut -d. -f1)"
        systemctl is-active --quiet skysbx-node \
            && printf 'service    running\n' || printf 'service    not running\n'
    else
        printf 'skysbx-node is not installed at %s\n' "$ROOT"
    fi
    exit 0
fi

if [ "$ACTION" = uninstall ] || [ "$ACTION" = purge ]; then
    [ "$(id -u)" = 0 ] || die "run as root"

    say "removing the service"
    systemctl disable --now skysbx-node >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/skysbx-node.service
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed 2>/dev/null || true
    ok "skysbx-node stopped and removed"

    rm -f "$ROOT/skysbx-node"
    # The build tree is this installer's scratch space, not data: it is a fresh
    # clone on every run.
    rm -rf "$ROOT/build/skysbx-node" "$ROOT/build/skysbx-core"
    ok "binary and build cache removed"

    if [ "$ACTION" = purge ]; then
        say "purging"
        # Read the domain back before deleting the hook that names it.
        #
        # Guarded, because there may be no hook: with pipefail a failing sed
        # makes the whole pipeline fail, a failing pipeline makes the
        # assignment fail, and set -e then ends the script — silently, halfway
        # through a purge, having removed the service but nothing else.
        PURGE_DOMAIN=""
        if [ -f "$ROOT/certbot-deploy.sh" ]; then
            PURGE_DOMAIN=$( (sed -n 's|^LIVE=/etc/letsencrypt/live/||p' \
                "$ROOT/certbot-deploy.sh" || true) | head -1)
        fi
        rm -f "$ROOT/node.env" "$ROOT/cert.pem" "$ROOT/key.pem" "$ROOT/certbot-deploy.sh"
        if [ -n "$PURGE_DOMAIN" ] && command -v certbot >/dev/null 2>&1; then
            certbot delete --cert-name "$PURGE_DOMAIN" --non-interactive >/dev/null 2>&1 \
                && ok "certificate for $PURGE_DOMAIN deleted" || true
        fi
        # The toolchain and its caches are shared when a panel lives on this
        # host too, so they go only if nothing else is using them. Rebuildable
        # either way.
        if ! systemctl is-enabled --quiet skysbx-panel 2>/dev/null; then
            rm -rf "$ROOT/toolchain" "$ROOT/go-mod-cache" "$ROOT/go-build-cache"
        fi
        # Only ever true on a host set up by an older version of this script,
        # which installed Docker to build in. Nothing installs it any more, but
        # leaving a daemon behind that we put there would be rude.
        if [ -f "$ROOT/.docker-installed-by-skysbx" ] && command -v docker >/dev/null 2>&1; then
            say "removing docker (an older version of this script installed it)"
            systemctl disable --now docker docker.socket containerd >/dev/null 2>&1 || true
            apt-get purge -y -qq docker-ce docker-ce-cli containerd.io \
                docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1 || true
            apt-get autoremove -y -qq >/dev/null 2>&1 || true
            rm -rf /var/lib/docker /var/lib/containerd /etc/docker
            rm -f "$ROOT/.docker-installed-by-skysbx"
            ok "docker removed"
        fi
    fi

    # Shared with the panel when both are on one host, so it goes only if this
    # was the last thing in it.
    rmdir "$ROOT/build" 2>/dev/null || true
    if rmdir "$ROOT" 2>/dev/null; then
        ok "$ROOT removed"
    else
        warn "$ROOT kept — it still holds files (the panel's, or your own):"
        (ls -A "$ROOT" 2>/dev/null || true) | sed 's/^/       /'
    fi

    printf '\n%sskysbx node removed.%s\n' "$GRN" "$RST"
    [ "$ACTION" = uninstall ] && printf \
        'The certificate and %s/node.env were kept; --purge removes those too.\n' "$ROOT"
    exit 0
fi

if [ "$ACTION" = upgrade ]; then
    [ -f "$ROOT/node.env" ] || die "nothing installed at $ROOT (run without --upgrade first)"
    # shellcheck disable=SC1090
    PANEL=${PANEL:-$(sed -n 's/^SKYSBX_PANEL=//p' "$ROOT/node.env")}
    TOKEN=${TOKEN:-$(sed -n 's/^SKYSBX_TOKEN=//p' "$ROOT/node.env")}
    [ -n "$PANEL" ] && [ -n "$TOKEN" ] || die "cannot read the panel URL and token from $ROOT/node.env"
    # certbot renews on its own timer; an upgrade has no business reissuing.
    SKIP_CERT=1
    say "upgrading — panel $PANEL"
fi

ask() { # ask <var> <prompt>
    local __var=$1 __prompt=$2 __reply=""
    [ -n "${!__var}" ] && return 0
    [ -t 0 ] || die "$__prompt is required (no terminal to ask on)"
    printf '  %s: ' "$__prompt"
    read -r __reply
    printf -v "$__var" '%s' "$__reply"
    [ -n "${!__var}" ] || die "$__prompt is required"
}

# An upgrade already knows all of this: it read the panel URL and token out of
# node.env, and the certificate is certbot's business, not this run's.
if [ "$ACTION" != upgrade ]; then
    say "node configuration"
    ask PANEL "Panel URL (https://panel.example.com)"
    ask TOKEN "Join token"
    if [ -z "$DOMAIN" ] && [ -t 0 ]; then
        printf "  This node's domain (blank to skip AnyTLS): "
        read -r DOMAIN
    fi
    [ -n "$DOMAIN" ] && [ -z "$EMAIL" ] && EMAIL="admin@$DOMAIN"
fi

# ─────────────────────────────── preflight ────────────────────────────────

say "preflight"
[ "$(id -u)" = 0 ] || die "run as root"

command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl; }
for p in git dig; do
    command -v "$p" >/dev/null || apt-get install -y -qq git dnsutils
done

if [ -n "$DOMAIN" ]; then
    PUBLIC_IP=$(curl -fsS --max-time 10 https://api.ipify.org || echo "")
    RESOLVED=$( (dig +short "$DOMAIN" A @1.1.1.1 || true) | tail -1)
    if [ -z "$RESOLVED" ]; then
        warn "$DOMAIN has no A record; AnyTLS will not get a certificate"
    elif [ -n "$PUBLIC_IP" ] && [ "$RESOLVED" != "$PUBLIC_IP" ]; then
        warn "$DOMAIN resolves to $RESOLVED but this host is $PUBLIC_IP"
        warn "if the record is proxied, switch it to DNS only: none of the three"
        warn "protocols is HTTP, and a CDN in front breaks all of them"
    else
        ok "$DOMAIN -> $RESOLVED (this host)"
    fi
fi

# The panel has to be reachable before anything is built.
STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${PANEL%/}/login" || echo 000)
[ "$STATUS" = 000 ] && die "cannot reach $PANEL"
ok "panel reachable"

# ──────────────────────────────── build ───────────────────────────────────

install -d -m 0700 "$ROOT"
BUILD=$ROOT/build
mkdir -p "$BUILD"

fetch() { # fetch <repo> <dest> <ref>
    local repo=$1 dest=$2 ref=$3
    local url="https://github.com/${GH_OWNER}/${repo}.git"
    rm -rf "$dest"
    # The token goes in a per-command header, not in the URL: git writes the
    # remote URL into the clone's .git/config, and a token in it would sit on
    # disk for as long as the build directory does.
    #
    # The failure names the ref it asked for rather than blaming the token: a
    # branch that does not exist fails exactly like a repository you cannot
    # see, and saying "needs GITHUB_TOKEN" to someone whose branch name is
    # simply wrong sends them somewhere there is nothing to find.
    if [ -n "$GH_TOKEN" ]; then
        git -c "http.extraHeader=Authorization: Basic $(printf 'x-access-token:%s' \
            "$GH_TOKEN" | base64 -w0)" \
            clone -q --branch "$ref" --depth 1 "$url" "$dest" \
            || die "cannot clone ${GH_OWNER}/${repo}@${ref}
  The branch may not exist, or GITHUB_TOKEN may not grant access to this repo."
    else
        git clone -q --branch "$ref" --depth 1 "$url" "$dest" \
            || die "cannot clone ${GH_OWNER}/${repo}@${ref}
  The branch may not exist; if the repository is private, set GITHUB_TOKEN."
    fi
    ok "${repo}@$(git -C "$dest" rev-parse --short HEAD)"
}

say "sources"
if [ -n "$SRC_DIR" ]; then
    rm -rf "$BUILD/skysbx-node"; cp -a "$SRC_DIR" "$BUILD/skysbx-node"; ok "using $SRC_DIR"
else
    fetch skysbx-node "$BUILD/skysbx-node" "$REF"
fi
if [ -n "$FORK_DIR" ]; then
    rm -rf "$BUILD/skysbx-core"; cp -a "$FORK_DIR" "$BUILD/skysbx-core"; ok "using $FORK_DIR"
else
    fetch skysbx-core "$BUILD/skysbx-core" "$FORK_REF"
fi

find "$BUILD" -type f -name '*.sh' -exec sed -i 's/\r$//' {} + 2>/dev/null || true

# ────────────────────────────── go toolchain ──────────────────────────────
#
# Go is needed to build and for nothing else. This used to install Docker for
# it: a package repository, a daemon and a ~350MB image, to run one compiler
# once. The official tarball is 64MB, leaves nothing running, and unpacks
# inside $ROOT where --purge already looks.
#
# 1.26.x is not a preference: sing-box reaches an unexported http2 field
# through go:linkname and 1.27 refuses to link it. The panel pins the same
# version, so a host running both downloads one toolchain instead of two.
GO_VERSION=1.26.5
GO_SHA256_amd64=5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053
GO_SHA256_arm64=fe4789e92b1f33358680864bbe8704289e7bb5fc207d80623c308935bd696d49

ensure_go() {
    GO="$ROOT/toolchain/go/bin/go"
    if [ -x "$GO" ] && "$GO" version 2>/dev/null | grep -q "go$GO_VERSION "; then
        ok "go $GO_VERSION already unpacked"
        return
    fi
    case $(uname -m) in
        x86_64|amd64)  go_arch=amd64; go_sha=$GO_SHA256_amd64 ;;
        aarch64|arm64) go_arch=arm64; go_sha=$GO_SHA256_arm64 ;;
        *) die "unsupported architecture: $(uname -m)" ;;
    esac
    say "fetching go $GO_VERSION ($go_arch)"
    mkdir -p "$ROOT/toolchain"
    go_tgz="$ROOT/toolchain/go.tar.gz"
    rm -f "$go_tgz"
    if ! curl -fsSL -o "$go_tgz" "https://go.dev/dl/go$GO_VERSION.linux-$go_arch.tar.gz"; then
        rm -f "$go_tgz"
        die "could not download the go toolchain"
    fi
    # A tarball unpacked as root is not something to wave through unverified.
    # The rejected bytes go with it: 64MB of unexplained file left in $ROOT by
    # a failed install is how this becomes a mystery to whoever looks next.
    if ! printf '%s  %s\n' "$go_sha" "$go_tgz" | sha256sum -c - >/dev/null 2>&1; then
        rm -f "$go_tgz"
        die "the go tarball failed its checksum — refusing to unpack it"
    fi
    rm -rf "$ROOT/toolchain/go"
    tar -C "$ROOT/toolchain" -xzf "$go_tgz"
    rm -f "$go_tgz"
    [ -x "$GO" ] || die "the go toolchain did not unpack as expected"
    ok "go $GO_VERSION ready"
}

ensure_go

# Stamped into the binary so `--version` can answer what is running without
# anyone reading a build log.
VER=$(git -C "$BUILD/skysbx-node" rev-parse --short HEAD 2>/dev/null || echo unknown)

say "building"
# The build tags are not optional: without them the binary compiles but exits at
# startup on "clash api is not included in this build".
#
# GOTOOLCHAIN=local is what makes the version pin real: without it Go reads the
# `go` line in a go.mod and will silently fetch and use a newer toolchain —
# here that would be the 1.27 this build cannot be linked with.
( cd "$BUILD/skysbx-node" && env \
    GOTOOLCHAIN=local GOFLAGS=-buildvcs=false CGO_ENABLED=0 GOOS=linux \
    GOMODCACHE="$ROOT/go-mod-cache" GOCACHE="$ROOT/go-build-cache" \
    "$GO" build -trimpath \
        -tags 'with_clash_api,with_v2ray_api,with_utls,with_acme,with_quic' \
        -ldflags "-s -w -X main.version=$VER \
                  -X github.com/sagernet/sing-box/constant.Version=1.14.0" \
        -o skysbx-node ./cmd/node )
install -m 0755 "$BUILD/skysbx-node/skysbx-node" "$ROOT/skysbx-node"
ok "node binary installed"

# ────────────────────────────── certificate ───────────────────────────────

# Only AnyTLS needs one. Reality authenticates with its own key pair and
# Shadowsocks 2022 has no TLS layer, so a node without a certificate still
# serves two of the three protocols.
if [ -n "$DOMAIN" ] && [ "$SKIP_CERT" = 0 ]; then
    say "certificate for $DOMAIN"
    command -v certbot >/dev/null || apt-get install -y -qq certbot

    cat > "$ROOT/certbot-deploy.sh" <<EOF
#!/bin/sh
# sing-box reads certificates once, at start, so copying the files is not
# enough — the node has to be restarted to pick them up.
set -eu
LIVE=/etc/letsencrypt/live/$DOMAIN
[ -f "\$LIVE/fullchain.pem" ] || exit 0
install -m 0644 "\$LIVE/fullchain.pem" "$ROOT/cert.pem"
install -m 0600 "\$LIVE/privkey.pem"   "$ROOT/key.pem"
systemctl is-active --quiet skysbx-node && systemctl restart skysbx-node || true
EOF
    chmod 0755 "$ROOT/certbot-deploy.sh"

    ARGS="certonly --non-interactive --agree-tos -m $EMAIL -d $DOMAIN
          --deploy-hook $ROOT/certbot-deploy.sh --keep-until-expiring"
    if [ -n "$CF_TOKEN" ]; then
        apt-get install -y -qq python3-certbot-dns-cloudflare
        mkdir -p /etc/letsencrypt
        printf 'dns_cloudflare_api_token = %s\n' "$CF_TOKEN" > /etc/letsencrypt/cloudflare.ini
        chmod 600 /etc/letsencrypt/cloudflare.ini
        # shellcheck disable=SC2086
        certbot $ARGS --dns-cloudflare \
            --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
            --dns-cloudflare-propagation-seconds 30 \
            || warn "certbot failed; Reality and Shadowsocks still work"
    else
        # shellcheck disable=SC2086
        certbot $ARGS --standalone \
            || warn "certbot failed; Reality and Shadowsocks still work"
    fi
    # --keep-until-expiring makes a re-run a no-op, and a no-op does not fire
    # the deploy hook, so copy here too.
    "$ROOT/certbot-deploy.sh" || true
    systemctl enable -q --now certbot.timer 2>/dev/null || true
    [ -f "$ROOT/cert.pem" ] && ok "certificate at $ROOT/cert.pem"
fi

# ─────────────────────────────── service ──────────────────────────────────

say "service"
# The token goes in an environment file rather than the command line, which is
# readable by every process on the host.
cat > "$ROOT/node.env" <<EOF
SKYSBX_PANEL=${PANEL}
SKYSBX_TOKEN=${TOKEN}
SKYSBX_LOG=info
EOF
chmod 600 "$ROOT/node.env"

cat > /etc/systemd/system/skysbx-node.service <<EOF
[Unit]
Description=skysbx node (embedded sing-box data plane)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${ROOT}
EnvironmentFile=${ROOT}/node.env
ExecStart=${ROOT}/skysbx-node
Restart=always
RestartSec=3
LimitNOFILE=1048576

# Binding low ports is what Reality on 443 needs; the rest is for the packet
# path.
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable -q skysbx-node
# restart, not `enable --now`: on an upgrade the binary has just been replaced
# and --now would leave the old process running.
systemctl restart skysbx-node
sleep 5

if systemctl is-active --quiet skysbx-node; then
    ok "node is running"
else
    warn "node did not start: journalctl -u skysbx-node -n 50"
fi

cat <<EOF

${GRN}skysbx node
==========
Panel     ${PANEL}
$([ -n "$DOMAIN" ] && echo "Domain    ${DOMAIN}")
Data      ${ROOT}

Logs      journalctl -u skysbx-node -f

The node dials the panel, so it needs no inbound control port and no route from
it. Add inbounds in the panel; they take effect within seconds.${RST}
EOF
