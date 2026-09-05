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

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
say()  { printf '%s==>%s %s\n' "$BLD" "$RST" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s warn%s %s\n' "$YLW" "$RST" "$*"; }
die()  { printf '%s fail%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: sudo ./install-node.sh --panel <url> --token <token> [options]

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
        --panel)    PANEL=$2; shift 2 ;;
        --token)    TOKEN=$2; shift 2 ;;
        --domain)   DOMAIN=$2; shift 2 ;;
        --email)    EMAIL=$2; shift 2 ;;
        --cf-token) CF_TOKEN=$2; shift 2 ;;
        --no-cert)  SKIP_CERT=1; shift ;;
        --src)      SRC_DIR=$2; shift 2 ;;
        --fork)     FORK_DIR=$2; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

ask() { # ask <var> <prompt>
    local __var=$1 __prompt=$2 __reply=""
    [ -n "${!__var}" ] && return 0
    [ -t 0 ] || die "$__prompt is required (no terminal to ask on)"
    printf '  %s: ' "$__prompt"
    read -r __reply
    printf -v "$__var" '%s' "$__reply"
    [ -n "${!__var}" ] || die "$__prompt is required"
}

say "node configuration"
ask PANEL "Panel URL (https://panel.example.com)"
ask TOKEN "Join token"
if [ -z "$DOMAIN" ] && [ -t 0 ]; then
    printf "  This node's domain (blank to skip AnyTLS): "
    read -r DOMAIN
fi
[ -n "$DOMAIN" ] && [ -z "$EMAIL" ] && EMAIL="admin@$DOMAIN"

# ─────────────────────────────── preflight ────────────────────────────────

say "preflight"
[ "$(id -u)" = 0 ] || die "run as root"

command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl; }
for p in git dig; do
    command -v "$p" >/dev/null || apt-get install -y -qq git dnsutils
done

if [ -n "$DOMAIN" ]; then
    PUBLIC_IP=$(curl -fsS --max-time 10 https://api.ipify.org || echo "")
    RESOLVED=$(dig +short "$DOMAIN" A @1.1.1.1 | tail -1)
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

fetch() { # fetch <repo> <dest>
    local repo=$1 dest=$2
    local url="https://github.com/${GH_OWNER}/${repo}.git"
    [ -n "$GH_TOKEN" ] && url="https://${GH_TOKEN}@github.com/${GH_OWNER}/${repo}.git"
    rm -rf "$dest"
    git clone -q --branch "$REF" --depth 1 "$url" "$dest" \
        || die "cannot clone ${GH_OWNER}/${repo} (a private repo needs GITHUB_TOKEN)"
    ok "${repo}@$(git -C "$dest" rev-parse --short HEAD)"
}

say "sources"
if [ -n "$SRC_DIR" ]; then
    rm -rf "$BUILD/skysbx-node"; cp -a "$SRC_DIR" "$BUILD/skysbx-node"; ok "using $SRC_DIR"
else
    fetch skysbx-node "$BUILD/skysbx-node"
fi
if [ -n "$FORK_DIR" ]; then
    rm -rf "$BUILD/sing-box-fork"; cp -a "$FORK_DIR" "$BUILD/sing-box-fork"; ok "using $FORK_DIR"
else
    fetch sing-box-fork "$BUILD/sing-box-fork"
fi

find "$BUILD" -type f -name '*.sh' -exec sed -i 's/\r$//' {} + 2>/dev/null || true

if ! command -v docker >/dev/null; then
    say "installing docker (used only to build; nothing runs in it)"
    curl -fsSL https://get.docker.com | sh >/dev/null
fi

say "building"
# The build tags are not optional: without them the binary compiles but exits at
# startup on "clash api is not included in this build". Go must be 1.26.x —
# 1.27 fails to link, because sing-box reaches an unexported http2 field through
# go:linkname.
docker run --rm -v "$BUILD:/src" -w /src/skysbx-node \
    -e GOFLAGS=-buildvcs=false -e CGO_ENABLED=0 -e GOOS=linux \
    golang:1.26.5 \
    go build -trimpath \
        -tags 'with_clash_api,with_v2ray_api,with_utls,with_acme,with_quic' \
        -ldflags '-s -w -X github.com/sagernet/sing-box/constant.Version=1.14.0' \
        -o /src/skysbx-node/skysbx-node ./cmd/node
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
