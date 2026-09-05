# skysbx-node

skysbx 的数据面：内嵌 sing-box，由 [`skysbx-panel`](https://github.com/kosje/skysbx-panel)
驱动。

## 许可

**GPL-3.0**（见 [`LICENSE`](LICENSE)）。这不是选择 —— 本程序链接 sing-box，属于其
衍生作品。另见 [`NOTICE`](NOTICE)：**本项目与 sing-box 官方无关联、未获其背书**，
请勿向他们报告本项目的问题。

面板是**独立的程序**，不链接这里的任何代码，许可单独适用。

## 安装

先在面板里 **Nodes → 新增**，复制那个只显示一次的接入 token，然后在这台服务器上：

```bash
sudo sh -c "$(wget -qO- https://raw.githubusercontent.com/kosje/skysbx-node/main/install.sh)"
```

它会问面板地址和 token。非交互：

```bash
sudo sh -c "$(wget -qO- https://raw.githubusercontent.com/kosje/skysbx-node/main/install.sh)" \
  -- --panel https://panel.example.com --token <token>
```

`--domain` 是可选的：只有 AnyTLS 需要证书，Reality 用自己的密钥对认证、Shadowsocks
没有 TLS 层，所以没证书的节点照样服务另外两个协议。给了域名脚本就用 certbot 签
（`--cf-token` 可走 DNS-01）。

> 节点域名必须是 **DNS-only（灰云）**。三个协议都不是 HTTP，套 CDN 会全部失效。

## 它做什么

启动后主动连面板，然后：

- 收到 `config` → 应用 sing-box 配置（会重建监听器）
- 收到 `users` → 热插拔用户，**不重启监听器、不断开现有连接**
- 每 30 秒上报流量增量和在线用户

**没有配置文件，没有监听的控制端口。** 只需要面板地址和一个 token；服务什么由面板决定。

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

`go.mod` 里的 `replace` 指向带热插拔补丁的 sing-box fork，发布前需换成已发布模块。

测试同样要带 tags —— `internal/engine` 的测试会真的起 sing-box：

```bash
go test -tags 'with_clash_api,with_v2ray_api,with_utls,with_acme,with_quic' ./...
```

## 由节点决定、而非面板决定的事

两处刻意不让面板管，因为它们是「怎么跑 sing-box」的细节：

- **本地 API 端口**（clash_api / v2ray_api）由节点向内核要空闲端口。写死会让同机
  两个节点撞车 —— 从旧节点迁移时正好会遇到。
- **Shadowsocks 占位用户**。sing-box 在构造时按 `len(users)` 决定建单用户还是多用户
  监听器，而单用户那个类型**根本没有**更新用户的方法。面板按设计发空列表（用户走
  独立消息才能热插拔），所以节点在应用前补一个随机密钥的占位用户。
  单用户模式还有个更糟的后果：配置里的共享密码本身就是完整凭据，不属于任何用户，
  那部分流量不计入任何人。
