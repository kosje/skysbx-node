# skysbx-node

skysbx 的数据面：内嵌 sing-box，由 [`skysbx-panel`](https://github.com/kosje/skysbx-panel)
驱动。

**没有配置文件，没有监听的控制端口。** 只需要面板地址和一个 token；服务什么、给谁服务、
拦什么，全部由面板决定。

## 它做什么

启动后主动连面板，然后：

| 收到 | 做什么 |
|---|---|
| `config` | 应用 sing-box 配置（重建监听器，会断连）。失败则**回滚到上一份**并把原因报回去 |
| `users` | 热插拔用户 —— 不重启监听器、不断开现有连接，同时刷新计费白名单和 IP 上限 |
| `ping` | 回 `pong` |

主动上报：

| 每隔 | 内容 |
|---|---|
| 30s | 流量**增量**（不是累计值，节点重启不会让用量倒退）+ CPU / 内存 / 运行时长 |
| 30s | 在线用户、每人的来源地址数、用量形状（连接数 / 对端数 / 端口数） |
| 5s | 检查每用户同时在线地址数，超出上限的地址直接断开 |
| 每次 apply 后 | 当前真正在跑的入站 tag 列表，以及配置被拒的原因 |

最后一条是面板「已生效 / 未生效」那个状态的来源。节点拒绝一份配置之后仍在跑上一份，
面板这边入站照样显示启用，唯一的症状是客户端连不上那一个端口 —— 所以入站列表由节点
直接给出，而不是从错误消息里反解 tag。

支持三个协议：**VLESS + Reality + XTLS-Vision**、**AnyTLS**、**Shadowsocks 2022**。
只有 AnyTLS 需要证书。

节点还可能替**别的节点**开一个 L4 转发口（面板里的「站内中转」）—— 那只是配置里多一个
`direct` 入站，纯字节转发，不解密也不认证。节点这边没有任何特殊处理。

## 安装

先在面板里 **节点 → 新增**，复制那个只显示一次的接入 token，然后在这台服务器上：

```bash
wget -qO- https://raw.githubusercontent.com/kosje/skysbx-node/main/install.sh | sh
```

它会问面板地址和 token。带参数要加 `-s --`：

```bash
N=https://raw.githubusercontent.com/kosje/skysbx-node/main/install.sh

wget -qO- $N | sh -s -- --panel https://panel.example.com --token <token>
wget -qO- $N | sh -s -- --version      # 节点版本 + 内嵌的 sing-box 版本
wget -qO- $N | sh -s -- --upgrade      # 重新构建并重启，含 sing-box 核心升级
wget -qO- $N | sh -s -- --uninstall    # 卸载服务，保留证书和 node.env
wget -qO- $N | sh -s -- --purge        # 连证书、构建缓存、脚本装的 Docker 一起清掉
```

`--upgrade` 不需要任何参数：面板地址和 token 从 `/opt/skysbx/node.env` 读回来。

**sing-box 核心怎么升级：** 核心是编进这个二进制里的，所以 `--upgrade` 重新构建一次
就是升级 —— 它会重新拉 [`skysbx-core`](https://github.com/kosje/skysbx-core) 再编。
没有单独的核心版本要管，也没有第二个进程要重启。

`--domain` 是可选的：只有 AnyTLS 需要证书，Reality 用自己的密钥对认证、Shadowsocks
没有 TLS 层，所以没证书的节点照样服务另外两个协议。给了域名脚本就用 certbot 签
（`--cf-token` 可走 DNS-01），证书写到 `/opt/skysbx/cert.pem` 和 `key.pem`，面板里
AnyTLS 入站默认就指这两个路径。

> 节点域名必须是 **DNS-only（灰云）**。三个协议都不是 HTTP，套 CDN 会全部失效。

直接跑：

```bash
skysbx-node -panel https://panel.example.com -token <token>
# 或用环境变量，避免 token 出现在命令行里
SKYSBX_PANEL=... SKYSBX_TOKEN=... skysbx-node
```

## 构建

```bash
GOTOOLCHAIN=go1.26.5 CGO_ENABLED=0 go build -trimpath \
  -tags 'with_clash_api,with_v2ray_api,with_utls,with_acme,with_quic' \
  -ldflags '-s -w -X main.version=$VER -X github.com/sagernet/sing-box/constant.Version=1.14.0' \
  ./cmd/node
```

两点不可省：

- **build tags** —— 缺了能编译，但启动时报 `clash api is not included in this build`
- **Go 1.26.x** —— 1.27 链接失败（sing-box 用 `go:linkname` 访问 http2 未导出字段）

测试同样要带 tags —— `internal/engine` 的测试会真的起 sing-box：

```bash
go test -tags 'with_clash_api,with_v2ray_api,with_utls,with_acme,with_quic' ./...
```

`go.mod` 里的 `replace` 指向 [`skysbx-core`](https://github.com/kosje/skysbx-core)，
带热插拔补丁的 sing-box 分支。

```
cmd/node/           入口
internal/
  link/             连面板的 WebSocket 客户端，含重连与上报节拍
  engine/           内嵌 sing-box：应用配置、热插拔、统计、IP 限制
  proto/            控制协议的线格式类型
```

`internal/proto/` 的结构体是重新定义的，不从面板 import —— 两者之间的契约是线格式，
不是共享的 Go 包。

## 由节点决定、而非面板决定的事

三处刻意不让面板管，因为它们是「怎么跑 sing-box」的细节：

- **本地 API 端口**（clash_api / v2ray_api）由节点向内核要空闲端口。写死会让同机两个
  节点撞车。

- **Shadowsocks 占位用户**。sing-box 在构造时按 `len(users)` 决定建单用户还是多用户
  监听器，而单用户那个类型**根本没有**更新用户的方法 —— 建成那样之后所有热添加静默
  失效。面板按设计发空列表（用户走独立消息才能热插拔），所以节点在应用前补一个随机
  密钥的占位用户。单用户模式还有个更糟的后果：配置里的共享密码本身就是完整凭据，不
  属于任何用户，那部分流量不计入任何人。

- **配置回滚**。先构造新实例，成功了才停旧的、启新的。构造失败不花任何代价；**启动**
  失败则旧实例已经没了，一个打错的端口会让整台节点上所有入站下线，直到某次无关的编辑
  碰巧推了新配置。所以启动失败时节点自己滚回上一份配置，并把失败原因报上去。

## IP 限制

面板给出每用户「同时在线的不同来源地址数」上限，节点执行。

数的是**地址**不是连接 —— 一台机器就会开几十条连接。判定在节点上做，因为连接在这里：
面板最晚 30 秒才知道，而且它唯一的手段是吊销整个账号，那会把付费的那个人一起踢下线。

- 每 5 秒从自己的 clash API 拉一次连接列表，超出的地址直接断开。
- 保住位置的是**最早出现**的那些地址，跨轮稳定，不会两台设备互相把对方踢掉。
- 一个地址在最后一条连接关闭后还保留 **5 分钟**位置，否则短暂空闲就会把位置让给下一个
  连上来的人。

已知边界：5 秒一轮，完全发生在两轮之间的突发看不见；限制按节点各自执行。

## 许可

**GPL-3.0**，见 [`LICENSE`](LICENSE)。

另见 [`NOTICE`](NOTICE)：**本项目与 sing-box 官方无关联、未获其背书**，请勿向他们报告
本项目的问题。

面板是独立的程序，不链接这里的任何代码，许可单独适用（AGPL-3.0）。
