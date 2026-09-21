# coturn 独立部署说明

大富翁的联机走 WebRTC。同一局域网/普通 NAT 下 STUN 就够用，但**对称 NAT / 严格企业网络 / 部分移动网络**必须靠 TURN 中继，所以 coturn 是「要稳定联机就得有」的组件。

## 为什么不能放在雨云 RCA 里

coturn 有两个硬性要求，和 RCA（基于 K8s）的模型冲突：

1. **需要一整段连续的 UDP 端口做中继**。coturn 默认用 `49152-65535`（16384 个端口），每个并发中继连接占 1 个。RCA 的服务只能按「单个端口 + tcp/udp 协议」暴露，没有端口段的概念。
2. **需要知道自己的公网 IP**。RCA 的容器跑在集群内网，Pod IP 不是公网 IP，`--external-ip` 无法可靠推导，分配出去的中继地址会是内网地址，客户端连不上。

所以：**monopoly 服务端放 RCA，coturn 放一台有公网 IP 的 VPS**（或者你后面用 Dokploy，也是同一台 VPS，用 Compose 部署即可）。

## 端口到底要开多少

coturn 只需要下面这些端口，其中真正"大量"的只有中继端口段，而且**可以缩到很小**：

| 端口 | 协议 | 用途 | 是否必需 |
| --- | --- | --- | --- |
| `3478` | **UDP** | STUN / TURN（明文） | **必需**，最常用 |
| `3478` | TCP | TURN over TCP | 建议开，UDP 被封的网络靠它 |
| `5349` | TCP | TURN over TLS（`turns:`） | 有域名证书时开 |
| `5349` | UDP | TURN over DTLS | 可选 |
| `49160-49200` | **UDP** | TURN 中继端口 | **必需**（范围可调） |
| `9641` | TCP | Prometheus 指标 | 可选，只给 Admin 面板看 |

关于中继端口：

- coturn 不设 `min-port`/`max-port` 时默认 `49152-65535`，也就是 **16384 个端口**——这就是"大量"的来源。
- 本仓库的 `docker-compose.yml` 已经把它限制成 **`49160-49200`，41 个端口**，够 ~40 个并发中继连接。开黑几十人完全够用；不够就把 `TURN_MAX_PORT` 调大。
- 中继端口的数量只影响**并发上限**，不影响画质/延迟。

> 服务端 `turn-credentials.ts` 会给每个登录用户同时下发：
> `turns:<TURN_URL>:5349?transport=tcp` 和 `turn:<TURN_URL>:3478?transport=udp`，
> ICE 会自动挑能通的那条。所以这两条随便哪条能通就能联机。

## 部署步骤

```bash
cd docker/coturn

# 1. 准备配置
cp .env.example .env
vim .env       # 至少改 EXTERNAL_IP 和 TURN_SECRET

# 2. 放行防火墙（以 ufw 为例）
sudo ufw allow 3478/udp
sudo ufw allow 3478/tcp
sudo ufw allow 49160:49200/udp

# 3. 启动
docker compose up -d
docker compose logs -f
```

云厂商的**安全组**也要放行上面这些端口，尤其是 UDP 段——这是最常见的"部署完了还是连不上"的原因。

如果用的是宝塔 / 1Panel，注意面板自带的防火墙是另一层。

### 启用 turns:（TLS）

把域名证书放到 `certs/` 目录（`fullchain.pem` + `privkey.pem`，见 `certs/README.md`），重启即可。没有证书时 coturn 也能正常启动，只是日志里会有：

```
ERROR tls-listening-port 5349 is configured, but the TLS and DTLS listeners are disabled
```

这条是**预期行为**，不影响 UDP TURN 使用。

### 在 Dokploy 上部署

Dokploy 底层就是 Docker Compose，可以直接：

1. 新建一个 Compose 类型的服务，把本目录的 `docker-compose.yml` 内容粘进去；
2. 在 Dokploy 的环境变量里填 `EXTERNAL_IP` / `TURN_SECRET` / `TURN_REALM` / `TURN_MIN_PORT` / `TURN_MAX_PORT`；
3. **网络模式必须是 host**（Dokploy 里选 Host / 或在 compose 里保留 `network_mode: host`），否则中继地址会变成容器内网地址。

## 和 monopoly 服务端对接

在雨云 RCA 的 monopoly 容器环境变量里填：

| 变量 | 值 |
| --- | --- |
| `TURN_URL` | coturn 的公网 IP 或域名，**不带协议和端口**，例如 `1.2.3.4` |
| `TURN_PORT` | `5349` |
| `STUN_PORT` | `3478` |
| `TURN_SECRET` | 和 coturn 的 `TURN_SECRET` **完全一致** |
| `TURN_TTL` | `86400`（凭证有效期，秒） |
| `COTURN_METRICS_URL` | `http://<coturn公网IP>:9641/metrics`，不想暴露 9641 就随便填个不可达地址，Admin 面板的 TURN 监控会显示拉取失败，不影响联机 |

> 用域名 + `turns:` 时，证书必须是**这个域名**的有效证书，否则浏览器会拒绝 TLS 连接。

## 验证

用 [Trickle ICE](https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/) 测试：
填 `turn:1.2.3.4:3478` + 用户名/密码，点 Gather candidates，能看到 `relay` 类型的候选就说明中继可用。

`use-auth-secret` 模式下的临时凭证可以用这个脚本生成（`TURN_SECRET` 换成你自己的）：

```bash
TURN_SECRET=your-secret
USERNAME="$(date +%s):test"           # 过期时间:用户名
CREDENTIAL="$(printf '%s' "$USERNAME" | openssl dgst -sha1 -hmac "$TURN_SECRET" -binary | base64)"
echo "username=$USERNAME"
echo "credential=$CREDENTIAL"
```
