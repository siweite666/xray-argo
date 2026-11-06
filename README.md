# Xray-Argo

在 VPS 上一条命令部署 **VLESS + XHTTP**，经 **Cloudflare 固定 Argo 隧道**对外提供服务。

**VPS 不对外开放任何代理端口，真实 IP 不暴露。**

---

## 方案说明

流量路径：

```
客户端 ──TLS──▶ Cloudflare 边缘 ──隧道──▶ cloudflared ──HTTP──▶ Xray (127.0.0.1:8001)
```

Xray 只监听 `127.0.0.1`，外网唯一入口是你的 Cloudflare 域名。VPS 上不开任何代理端口，扫描器看不到东西。

### h2 与 h3 节点怎么选

| 节点 | 传输 | 什么时候用 |
| :--- | :--- | :--- |
| **H3** | QUIC / UDP | **日常首选**。没有 TCP 队头阻塞，抗丢包。跨境晚高峰丢包 5-10% 时差距最明显 |
| **H2** | TCP | 备用。网络封 UDP 时用这个 |

两个节点用的是同一个隧道、同一个端口、同一个 UUID，只是 `alpn` 不同。客户端里都加上，哪个能跑用哪个。

具体差异：h2 是 HTTP/2 over TCP，一条流丢包会让后续所有数据排队等重传（队头阻塞）；h3 是 HTTP/3 over QUIC/UDP，每条流独立处理，且支持 0-RTT 重连和连接迁移。代价是 h3 依赖 UDP 443 不被拦。

> 建议：H3 放在第一位。**连不上 / 一直转圈**基本可以断定是 UDP 被运营商或公司网络拦了；**速度突然掉到几百 KB/s** 通常是 UDP 被 QoS 限速。这两种情况都切 H2。
> 反过来说，H2 在晚高峰抖得厉害时，切 H3 通常有改善。

---

## Cloudflare 准备

### 1. 创建固定隧道

1. 登录 [Cloudflare Zero Trust](https://one.dash.cloudflare.com/)
2. 左侧 **Networks → Tunnels → Create a tunnel**
3. 选 **Cloudflared**，起个名字，保存
4. 在安装页面上**复制 Token**（形如 `eyJhIjoi...` 的一长串）—— 后面安装要用
   - 安装命令不用执行，我们的脚本会自己跑 cloudflared

### 2. 配置 Public Hostname

在隧道详情页 → **Public Hostnames** → **Add a public hostname**：

| 字段 | 填什么 |
| :--- | :--- |
| Subdomain | 例如 `node`（或留空用根域名） |
| Domain | 选你的域名 |
| **Service · Type** | **HTTP** ← 注意不是 HTTPS |
| **Service · URL** | `localhost:8001` ← 端口必须和安装时 `port` 参数一致 |

保存后，`node.example.com` 就指向了本机的 `127.0.0.1:8001`。

### 3. 打开 HTTP/3（用 h3 节点必须）

**注意：这个开关不在隧道页面里**，而在域名（zone）的设置里：

1. Cloudflare 控制台 → 选中你的**域名**（不是 Zero Trust 面板）
2. 左侧 **Speed → Settings**（有的界面显示为 Speed → Optimization）
3. 找到 **Protocol Optimization**
4. 把 **HTTP/3 (with QUIC)** 打开

> 如果你的域名下已经能找到这个开关并且是 On 状态，说明本来就开着，跳过这步。

**怎么确认真的开了**：在任意 Linux 机器上跑

```bash
curl --http3-only -o /dev/null -w 'HTTP=%{http_code} 协议=%{http_version}\n' https://你的域名/
```

输出里 `协议=3` 就是开了。看到 `协议=2` 或直接报错就是没开。
（`HTTP=404` 或 `502` 是正常的 —— 说明 QUIC 握手成功、请求到达了后端，只是路径不存在。）

### 4. （可选）为 VMess 备用入站加一条 Hostname

如果你打算用 `vmess="y"`，再加一条 Public Hostname：

| 字段 | 填什么 |
| :--- | :--- |
| Subdomain | `vmess` |
| Domain | 你的域名 |
| Service · Type | HTTP |
| Service · URL | `localhost:8002` ← 默认是 `port + 1` |

---

## 一键安装

以 `root` 身份运行：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/siweite666/xray-argo/main/install.sh) \
  token="你的隧道Token" \
  domain="node.example.com" \
  port="8001" \
  protocol="quic" \
  path="" \
  uuid="" \
  vmess="n" \
  cfip=""
```

> 想换成自己的 fork？把 URL 里 `siweite666/xray-argo` 换成你的 `用户名/仓库名` 即可。

### 参数表

| 参数 | 必填 | 默认 | 说明 |
| :--- | :--- | :--- | :--- |
| `token` | ✅ | — | Cloudflare 固定隧道 Token。留空会交互式询问 |
| `domain` | ✅ | — | 隧道 Public Hostname 的完整域名。留空会交互式询问 |
| `port` | | `8001` | Xray 本地监听端口。**必须和隧道 Service URL 里的端口一致** |
| `protocol` | | `quic` | cloudflared 隧道协议：`quic` 或 `http2` |
| `path` | | 自动 | XHTTP 路径。留空自动生成 24 位随机串 |
| `uuid` | | 自动 | 客户端 UUID。留空用 `xray uuid` 生成 |
| `vmess` | | `n` | `y` 则额外部署 VMess + WS 备用入站 |
| `cfip` | | 同 `domain` | 客户端链接里的优选 IP / 优选域名 |

**重复运行是安全的（幂等）**：会覆盖更新二进制和配置，UUID 和路径会沿用上次的值，不会产生重复服务。想换 UUID 就显式传 `uuid="..."`。

### 用代理下载

如果 VPS 直连 GitHub 很慢，可以自己指定代理：

```bash
GH_PROXY="https://your-proxy.example.com/" \
bash <(curl -Ls ...) token="..." domain="..."
```

脚本默认**只从官方 GitHub Release 下载**，并在下载后用 Release 附带的 `.dgst` 文件校验 SHA256。校验不通过会立即退出。

---

## 优选 IP（提高连接速度）

默认链接里用的是你的域名，走 Cloudflare 普通解析，速度可能一般。做一次优选能明显改善：

1. 在**本地**（不是 VPS）下载 [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest)
2. **晚高峰**（20:00–23:00）运行，测速结果才有代表性
3. 取结果里延迟最低、速度最快的几个 IP
4. 两种用法任选：
   - 安装时传：`cfip="104.16.x.x"`
   - 或者装完之后，直接把客户端地址里的 `@你的域名:443` 改成 `@优选IP:443`
     （`sni` 和 `host` 参数**保持不变**，仍然是你的域名）

> 优选 IP 会失效，建议每隔一段时间重测。

---

## 客户端要求

XHTTP 是较新的传输方式，**必须用支持它的客户端版本**：

| 平台 | 客户端 | 备注 |
| :--- | :--- | :--- |
| Windows | v2rayN | 需要较新版本（支持 XHTTP 的版本） |
| Android | v2rayNG | 同上 |
| iOS / macOS | Shadowrocket、Stash | 需支持 XHTTP |
| 全平台 | sing-box、mihomo | 需支持 `xhttp` |

**客户端版本太老会导入失败或连不上**，先更新客户端。

导入方式：安装结束会打印节点链接和一段 Base64。可以直接把链接粘进客户端，也可以把 Base64 内容存成文件后导入订阅。

---

## 管理命令

安装完会提供一个 `xa` 命令：

| 命令 | 作用 |
| :--- | :--- |
| `xa links` | 重新显示节点链接和 Base64 订阅 |
| `xa status` | 查看 xray 与 cloudflared 服务状态 |
| `xa restart` | 重启两个服务 |
| `xa proto quic` | 切换隧道协议为 QUIC 并重启 |
| `xa proto http2` | 切换隧道协议为 HTTP/2 并重启 |
| `xa update` | 更新 Xray-core 与 cloudflared 到最新版 |

> `xa proto` 只改隧道传输协议，**不影响** h2/h3 节点链接 —— 那两个是客户端侧的 `alpn`，互不相关。

---

## 卸载

```bash
bash <(curl -Ls https://raw.githubusercontent.com/siweite666/xray-argo/main/uninstall.sh)
```

会停止并删除 `xray-argo`、`cloudflared-argo` 两个服务，删除 `/etc/xray-argo/` 目录和 `xa` 命令。**不动系统其他内容。**

---

## 文件位置

```
/etc/xray-argo/
├── xray              Xray-core 二进制
├── cloudflared       cloudflared 二进制
├── geoip.dat         路由规则依赖（屏蔽私有地址与国内 IP）
├── geosite.dat
├── config.json       Xray 配置（600）
├── cloudflared.env   隧道 Token（600）
├── install.env       安装参数，供 xa 使用（600）
├── url.txt           节点链接（600）
└── sub.txt           Base64 订阅（600）

/etc/systemd/system/xray-argo.service
/etc/systemd/system/cloudflared-argo.service
/usr/local/bin/xa
```

Alpine 系统上服务脚本在 `/etc/init.d/` 下（OpenRC）。

---

## 安全说明

- **只从官方 GitHub Release 下载**，下载后用官方 `.dgst` 校验 SHA256，不匹配立即退出
- **不使用任何第三方 Workers / 镜像代理**；需要代理时由你通过 `GH_PROXY` 自行指定
- **Token 不进命令行**：通过 `EnvironmentFile`（600 权限）注入，`ps aux` 看不到
- **配置、链接文件权限 600**，只有 root 可读
- **节点链接不含 `allowInsecure=1`**：TLS 由 Cloudflare 边缘提供有效证书
- 路由规则屏蔽 `geoip:cn` 与 `geoip:private`，节点不会被用来访问国内或内网地址
- 脚本不含任何统计、上报或广告接口

---

## 常见问题

**服务起不来，怎么看原因？**

```bash
xa status
journalctl -u xray-argo -n 50 --no-pager
journalctl -u cloudflared-argo -n 50 --no-pager
```

**cloudflared 起来了但客户端连不上？**

按顺序检查：

1. Public Hostname 的 Service Type 是不是 **HTTP**（不是 HTTPS）
2. Service URL 端口是不是和 `port` 参数一致
3. 用 h3 节点的话，Network 里 **HTTP/3 打开了没**
4. 换 h2 节点试一次 —— 能通说明是 UDP/QUIC 被挡

**端口 8001 被占了？**

换一个：`port="9001"`，并且**同步修改** Cloudflare 里 Public Hostname 的 Service URL。

**能同时装多个吗？**

不能。脚本固定使用 `/etc/xray-argo`、`xray-argo`、`cloudflared-argo` 这几个名字，重复安装是覆盖而不是并存。

---

## License

MIT
