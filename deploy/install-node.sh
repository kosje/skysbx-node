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
FROM_SOURCE=0
# Empty means whatever the newest release is. Pin it to reinstall the exact
# version a working host is already running.
SKYSBX_VERSION=${SKYSBX_VERSION:-}
LAUNCHER_SRC=${SKYSBX_LAUNCHER_SRC:-}

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
say()  { printf '%s==>%s %s\n' "$BLD" "$RST" "$*"; }
ok()   { printf '%s 完成%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s 警告%s %s\n' "$YLW" "$RST" "$*"; }
die()  { printf '%s 错误%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

ACTION=install

usage() {
    cat <<EOF
用法：sudo ./install-node.sh [--panel <地址> --token <token>] [选项]

动作（默认是安装）
  --version         查看已安装的版本，包括内嵌的 sing-box 版本。
  --upgrade         取得新版并重启。面板地址和 token 会从 ${ROOT}/node.env
                    读回来，所以不需要任何参数。升级 sing-box 核心也是走这条：
                    核心是链接进节点二进制的，重新构建就是升级。
  --uninstall       停止并移除服务和二进制。保留证书和 ${ROOT}/node.env，
                    所以装回来只需要一条不带参数的 --upgrade。
  --purge           在 --uninstall 的基础上，删除本安装器创建的其余所有东西：
                    环境文件、证书、构建缓存、Go 工具链，以及这个节点域名
                    对应的 Let's Encrypt 账户。

安装选项
  --panel <地址>    面板地址，例如 https://panel.example.com
  --token <token>   接入 token，在面板里添加该节点时只显示一次。

  --domain <域名>   这个节点自己的域名。只有 AnyTLS 需要它 —— Reality 和
                    Shadowsocks 不用证书也能认证 —— 所以是可选的。必须是
                    DNS only（灰云）：三个协议都不是 HTTP，前面套 CDN 会让
                    它们全部失效。
  --email <邮箱>    Let's Encrypt 联系邮箱（默认 admin@<域名>）。
  --cf-token <tok>  Cloudflare API token，80 端口不可达时用 DNS-01 验证。
  --no-cert         跳过证书签发。

  --src <目录>      用本地已有的检出编译，不再克隆。
  --from-source     从源码编译，不下载已发布的二进制。
  --fork <目录>     打过补丁的 sing-box 路径；默认使用同级的克隆。
  -h, --help        显示本说明。
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
        --from-source) FROM_SOURCE=1; shift ;;
        --fork)      FORK_DIR=$2; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *) die "无法识别的参数：$1（试试 --help）" ;;
    esac
done

# ───────────────────────── version / uninstall / purge ─────────────────────

if [ "$ACTION" = version ]; then
    if [ -x "$ROOT/skysbx-node" ]; then
        "$ROOT/skysbx-node" -version
        printf '安装于    %s\n' "$(stat -c %y "$ROOT/skysbx-node" 2>/dev/null | cut -d. -f1)"
        systemctl is-active --quiet skysbx-node \
            && printf '服务      运行中\n' || printf '服务      已停止\n'
    else
        printf '%s 下没有安装 skysbx-node\n' "$ROOT"
    fi
    exit 0
fi

if [ "$ACTION" = uninstall ] || [ "$ACTION" = purge ]; then
    [ "$(id -u)" = 0 ] || die "请用 root 运行"

    say "正在移除服务"
    systemctl disable --now skysbx-node >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/skysbx-node.service
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed 2>/dev/null || true
    ok "skysbx-node 已停止并移除"

    rm -f "$ROOT/skysbx-node"
    # The build tree is this installer's scratch space, not data: it is a fresh
    # clone on every run.
    rm -rf "$ROOT/build/skysbx-node" "$ROOT/build/skysbx-core"
    ok "二进制和构建缓存已删除"

    if [ "$ACTION" = purge ]; then
        say "正在清除"
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
                && ok "$PURGE_DOMAIN 的证书已删除" || true
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
            say "正在卸载 docker（是本脚本的旧版本装的）"
            systemctl disable --now docker docker.socket containerd >/dev/null 2>&1 || true
            apt-get purge -y -qq docker-ce docker-ce-cli containerd.io \
                docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1 || true
            apt-get autoremove -y -qq >/dev/null 2>&1 || true
            rm -rf /var/lib/docker /var/lib/containerd /etc/docker
            rm -f "$ROOT/.docker-installed-by-skysbx"
            ok "docker 已卸载"
        fi
    fi

    # The shortcut manages both halves, so it goes only when the other one is
    # not still relying on it.
    if [ ! -x "$ROOT/skysbx-panel" ]; then
        rm -f /usr/local/bin/skysbx
    fi

    # Shared with the panel when both are on one host, so it goes only if this
    # was the last thing in it.
    rmdir "$ROOT/build" 2>/dev/null || true
    if rmdir "$ROOT" 2>/dev/null; then
        ok "$ROOT 已删除"
    else
        warn "$ROOT 保留 —— 里面还有别的文件（面板的，或你自己的）："
        (ls -A "$ROOT" 2>/dev/null || true) | sed 's/^/       /'
    fi

    printf '\n%sskysbx 节点已移除。%s\n' "$GRN" "$RST"
    [ "$ACTION" = uninstall ] && printf \
        '证书和 %s/node.env 保留了下来；--purge 会把它们也删掉。\n' "$ROOT"
    exit 0
fi

if [ "$ACTION" = upgrade ]; then
    [ -f "$ROOT/node.env" ] || die "$ROOT 下没有已安装的节点（请先不带 --upgrade 安装一次）"
    # shellcheck disable=SC1090
    PANEL=${PANEL:-$(sed -n 's/^SKYSBX_PANEL=//p' "$ROOT/node.env")}
    TOKEN=${TOKEN:-$(sed -n 's/^SKYSBX_TOKEN=//p' "$ROOT/node.env")}
    [ -n "$PANEL" ] && [ -n "$TOKEN" ] || die "无法从 $ROOT/node.env 读回面板地址和 token"
    # certbot renews on its own timer; an upgrade has no business reissuing.
    SKIP_CERT=1
    say "正在升级 —— 面板 $PANEL"
fi

ask() { # ask <var> <prompt>
    local __var=$1 __prompt=$2 __reply=""
    [ -n "${!__var}" ] && return 0
    [ -t 0 ] || die "必须提供$__prompt（当前没有终端可以询问）"
    printf '  %s: ' "$__prompt"
    read -r __reply
    printf -v "$__var" '%s' "$__reply"
    [ -n "${!__var}" ] || die "必须提供$__prompt"
}

# An upgrade already knows all of this: it read the panel URL and token out of
# node.env, and the certificate is certbot's business, not this run's.
if [ "$ACTION" != upgrade ]; then
    say "节点配置"
    ask PANEL "面板地址（如 https://panel.example.com）"
    ask TOKEN "接入 token"
    if [ -z "$DOMAIN" ] && [ -t 0 ]; then
        printf '  这个节点自己的域名（留空则不启用 AnyTLS）：'
        read -r DOMAIN
    fi
    [ -n "$DOMAIN" ] && [ -z "$EMAIL" ] && EMAIL="admin@$DOMAIN"
fi

# ─────────────────────────────── preflight ────────────────────────────────

say "环境检查"
[ "$(id -u)" = 0 ] || die "请用 root 运行"

command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl; }
for p in git dig; do
    command -v "$p" >/dev/null || apt-get install -y -qq git dnsutils
done

if [ -n "$DOMAIN" ]; then
    PUBLIC_IP=$(curl -fsS --max-time 10 https://api.ipify.org || echo "")
    RESOLVED=$( (dig +short "$DOMAIN" A @1.1.1.1 || true) | tail -1)
    if [ -z "$RESOLVED" ]; then
        warn "$DOMAIN 没有 A 记录；AnyTLS 拿不到证书"
    elif [ -n "$PUBLIC_IP" ] && [ "$RESOLVED" != "$PUBLIC_IP" ]; then
        warn "$DOMAIN 解析到 $RESOLVED，而本机是 $PUBLIC_IP"
        warn "如果这条记录开了代理，请改成 DNS only（灰云）：三个协议都不是"
        warn "HTTP，前面套一层 CDN 会让它们全部失效"
    else
        ok "$DOMAIN -> $RESOLVED（就是本机）"
    fi
fi

# The panel has to be reachable before anything is built.
STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${PANEL%/}/login" || echo 000)
[ "$STATUS" = 000 ] && die "连不上面板 $PANEL"
ok "面板可达"

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
            || die "无法克隆 ${GH_OWNER}/${repo}@${ref}
  该分支可能不存在，或者 GITHUB_TOKEN 没有访问这个仓库的权限。"
    else
        git clone -q --branch "$ref" --depth 1 "$url" "$dest" \
            || die "无法克隆 ${GH_OWNER}/${repo}@${ref}
  该分支可能不存在；如果是私有仓库，请设置 GITHUB_TOKEN。"
    fi
    ok "${repo}@$(git -C "$dest" rev-parse --short HEAD)"
}

# ─────────────────────────── a published binary ───────────────────────────
#
# This build is the expensive one — sing-box with every tag, measured at 3m12s
# on a single core — and it is the reason a small VPS feels slow to set up. A
# published build is ~40MB and lands in seconds.
#
# Tried before the sources are fetched, not after: when it succeeds there is
# nothing to compile, so there is no reason to clone this repository and the
# whole of the sing-box fork first — and no reason to need git at all.
#
# It is a preference, not a requirement: no release, an unpublished
# architecture, or no route to GitHub's CDN all fall through to building, which
# always works. --from-source goes straight there.
try_release() {
    [ "$FROM_SOURCE" = 1 ] && return 1
    [ -n "$SRC_DIR" ] && return 1   # asked for this checkout specifically
    [ -n "$FORK_DIR" ] && return 1  # asked for this fork specifically

    case $(uname -m) in
        x86_64|amd64)  rel_arch=amd64 ;;
        aarch64|arm64) rel_arch=arm64 ;;
        *) return 1 ;;
    esac

    local base="https://github.com/${GH_OWNER}/skysbx-node/releases"
    # GitHub serves the newest release's assets from this path, so resolving a
    # version through the API — and its rate limit, and its JSON — is avoidable.
    local from="$base/latest/download"
    [ -n "$SKYSBX_VERSION" ] && from="$base/download/$SKYSBX_VERSION"

    local tmp; tmp=$(mktemp -d)
    local asset="skysbx-node-linux-$rel_arch"
    say "正在查找已发布的构建"
    if ! curl -fsSL --max-time 180 -o "$tmp/$asset" "$from/$asset" \
      || ! curl -fsSL --max-time 30 -o "$tmp/SHA256SUMS" "$from/SHA256SUMS"; then
        rm -rf "$tmp"
        return 1
    fi
    # Same rule as the toolchain tarball: nothing unverified gets installed and
    # run as root. A mismatch stops the install rather than falling back — a
    # release that does not match its own checksums is worth looking at.
    if ! ( cd "$tmp" && grep " $asset\$" SHA256SUMS | sha256sum -c - >/dev/null 2>&1 ); then
        rm -rf "$tmp"
        die "已发布的节点二进制与校验和不符。
  拒绝安装。可以加 --from-source 改为从源码编译。"
    fi
    install -m 0755 "$tmp/$asset" "$ROOT/skysbx-node"
    rm -rf "$tmp"
    ok "已安装发布版二进制（$rel_arch）"
    return 0
}

HAVE_BINARY=0
try_release && HAVE_BINARY=1

if [ "$HAVE_BINARY" = 0 ]; then
    say "准备源码"
    # LAUNCHER_SRC is the clone install.sh already made to find this script. It
    # is reused rather than re-cloned, but it is deliberately not --src: only an
    # operator passing --src means "do not look for a published binary".
    if [ -n "$SRC_DIR" ]; then
        rm -rf "$BUILD/skysbx-node"; cp -a "$SRC_DIR" "$BUILD/skysbx-node"; ok "使用 $SRC_DIR"
    elif [ -n "$LAUNCHER_SRC" ] && [ -d "$LAUNCHER_SRC" ]; then
        rm -rf "$BUILD/skysbx-node"; cp -a "$LAUNCHER_SRC" "$BUILD/skysbx-node"
        ok "复用启动器已经克隆好的源码"
    else
        fetch skysbx-node "$BUILD/skysbx-node" "$REF"
    fi
    if [ -n "$FORK_DIR" ]; then
        rm -rf "$BUILD/skysbx-core"; cp -a "$FORK_DIR" "$BUILD/skysbx-core"; ok "使用 $FORK_DIR"
    else
        fetch skysbx-core "$BUILD/skysbx-core" "$FORK_REF"
    fi

    find "$BUILD" -type f -name '*.sh' -exec sed -i 's/\r$//' {} + 2>/dev/null || true
fi

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
        ok "go $GO_VERSION 已经解包过了"
        return
    fi
    case $(uname -m) in
        x86_64|amd64)  go_arch=amd64; go_sha=$GO_SHA256_amd64 ;;
        aarch64|arm64) go_arch=arm64; go_sha=$GO_SHA256_arm64 ;;
        *) die "不支持的架构：$(uname -m)" ;;
    esac
    say "正在下载 go $GO_VERSION（$go_arch）"
    mkdir -p "$ROOT/toolchain"
    go_tgz="$ROOT/toolchain/go.tar.gz"
    rm -f "$go_tgz"
    if ! curl -fsSL -o "$go_tgz" "https://go.dev/dl/go$GO_VERSION.linux-$go_arch.tar.gz"; then
        rm -f "$go_tgz"
        die "无法下载 go 工具链"
    fi
    # A tarball unpacked as root is not something to wave through unverified.
    # The rejected bytes go with it: 64MB of unexplained file left in $ROOT by
    # a failed install is how this becomes a mystery to whoever looks next.
    if ! printf '%s  %s\n' "$go_sha" "$go_tgz" | sha256sum -c - >/dev/null 2>&1; then
        rm -f "$go_tgz"
        die "go 压缩包校验和不符 —— 拒绝解包"
    fi
    rm -rf "$ROOT/toolchain/go"
    tar -C "$ROOT/toolchain" -xzf "$go_tgz"
    rm -f "$go_tgz"
    [ -x "$GO" ] || die "go 工具链解包结果不符合预期"
    ok "go $GO_VERSION 就绪"
}

if [ "$HAVE_BINARY" = 0 ]; then
    ensure_go

    # Stamped into the binary so `--version` can answer what is running without
    # anyone reading a build log.
    VER=$(git -C "$BUILD/skysbx-node" rev-parse --short HEAD 2>/dev/null || echo unknown)

    say "正在编译"
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
    ok "节点二进制已安装"
fi

# ────────────────────────────── certificate ───────────────────────────────

# Only AnyTLS needs one. Reality authenticates with its own key pair and
# Shadowsocks 2022 has no TLS layer, so a node without a certificate still
# serves two of the three protocols.
if [ -n "$DOMAIN" ] && [ "$SKIP_CERT" = 0 ]; then
    say "为 $DOMAIN 申请证书"
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
            || warn "certbot 失败；Reality 和 Shadowsocks 仍然可用"
    else
        # shellcheck disable=SC2086
        certbot $ARGS --standalone \
            || warn "certbot 失败；Reality 和 Shadowsocks 仍然可用"
    fi
    # --keep-until-expiring makes a re-run a no-op, and a no-op does not fire
    # the deploy hook, so copy here too.
    "$ROOT/certbot-deploy.sh" || true
    systemctl enable -q --now certbot.timer 2>/dev/null || true
    [ -f "$ROOT/cert.pem" ] && ok "证书已放在 $ROOT/cert.pem"
fi

# ─────────────────────────────── service ──────────────────────────────────

say "配置服务"
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

# The `skysbx` command, for maintaining whatever is on this host without having
# to remember a raw.githubusercontent URL. It is kept in the panel repository
# because it manages both halves and belongs to neither; a node-only host still
# wants it. Best effort: a host that could not fetch one convenience script
# still has a working node, and the installer below is unaffected either way.
# Refreshed on every run, not just when missing: an upgrade is exactly when a
# shortcut that has fallen behind should be brought up to date, and skipping it
# when one already exists means it never is.
if curl -fsSL --max-time 30 -o /tmp/skysbx.$$ \
        "https://raw.githubusercontent.com/${GH_OWNER}/skysbx-panel/main/skysbx.sh" \
   && [ -s /tmp/skysbx.$$ ]; then
    install -m 0755 /tmp/skysbx.$$ /usr/local/bin/skysbx
    ok "skysbx 命令已安装"
else
    warn "无法安装 skysbx 快捷命令；不影响节点本身"
fi
rm -f /tmp/skysbx.$$

systemctl daemon-reload
systemctl enable -q skysbx-node
# restart, not `enable --now`: on an upgrade the binary has just been replaced
# and --now would leave the old process running.
systemctl restart skysbx-node
sleep 5

if systemctl is-active --quiet skysbx-node; then
    ok "节点正在运行"
else
    warn "节点没有启动：journalctl -u skysbx-node -n 50"
fi

cat <<EOF

${GRN}skysbx 节点
==========
面板    ${PANEL}
$([ -n "$DOMAIN" ] && echo "域名    ${DOMAIN}")
数据    ${ROOT}

日志    journalctl -u skysbx-node -f

维护    skysbx（菜单）、skysbx version、skysbx upgrade

节点是主动去连面板的，所以不需要开放任何控制端口，面板也不需要能路由到它。
在面板里添加入站即可，几秒内生效。${RST}
EOF
