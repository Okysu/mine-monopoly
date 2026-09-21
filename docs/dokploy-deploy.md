# Dokploy 部署指南

用 [Dokploy](https://docs.dokploy.com/docs/core/docker-compose) 的 **Compose / Stack**，一条 compose 把 **服务端 + MySQL + coturn** 全部部署上去。

- `main`：API + ICE/PeerJS 信令 + Admin 管理面板
- `mysql`：内网数据库
- `coturn`：STUN/TURN 中继（联机必需，bridge 网络 + 端口段发布）

```
                        ┌──────── Dokploy / 同一台 VPS ────────┐
  浏览器 ──HTTPS──▶     │  Traefik ──▶ main :8081 :8082 :8083  │
                        │                  │                    │
   游戏客户端 ──WSS──▶   │                  └──▶ mysql :3306     │
                        │  coturn  3478/udp + 49160-49200/udp   │
                        └───────────────────────────────────────┘
```

---

## 0. 前置：镜像已构建并公开

```bash
docker pull ghcr.io/okysu/mine-monopoly-server:latest
```

拉得下来就行。拉不动的话：GitHub → 头像 → **Your packages** → `mine-monopoly-server` → **Package settings** → **Change visibility → Public**；镜像没构建过就去 **Actions → Docker Image → Run workflow**。

---

## 1. 创建 Compose 服务

Dokploy → 你的项目 → **Create Service → Compose**

| 字段 | 值 |
| --- | --- |
| Name | `mine-monopoly`（随意） |
| Source Type | **Git**（推荐）或 **Raw** |
| Repository | 你的 fork，例如 `Okysu/mine-monopoly` |
| Branch | `main` |
| Compose Path | `docker-compose.dokploy.yml` |

用 **Raw** 就把 [`docker-compose.dokploy.yml`](../docker-compose.dokploy.yml) 内容整段粘进编辑器。

> compose 用 `image:` 拉预构建镜像，**Dokploy 不会构建**，所以用 Git 源也起得很快。

---

## 2. 针对 `rich.oky.su` 的具体配置

假设你要把域名 `rich.oky.su` 反代成 HTTPS 访问，**yml 一个字都不用改**，只要在 Dokploy 的 **Environment** 标签页里填下面这段：

```dotenv
MONOPOLY_DOMAIN=rich.oky.su
PROTOCOL=https
API_BASE_PREFIX=/monopoly-server
ICE_BASE_PREFIX=/monopoly-ice

MYSQL_PASSWORD=换成强密码
MYSQL_ROOT_PASSWORD=换成另一个强密码
MAP_ENCRYPT_KEY=换成16位密钥
TURN_SECRET=换成强密钥
EXTERNAL_IP=你的服务器公网IP
```

几点说明：

- **`MONOPOLY_DOMAIN` 不带协议、不带端口**，只写域名。
- **`TURN_URL` 不用填**，留空时会自动跟随 `MONOPOLY_DOMAIN`（compose 里写的是 `${TURN_URL:-${MONOPOLY_DOMAIN:-127.0.0.1}}`）。想单独用别的 TURN 地址再覆盖。
- **`EXTERNAL_IP` 必填**：服务器公网 IP。coturn 跑在 bridge 网络里，看不到宿主机公网地址，不填的话它分配出去的中继地址会是容器内网 IP（`172.x`），客户端连不上。不填的话 compose 会直接报错，不会带着坏配置跑起来。
- `ADMIN_BASE_PREFIX` 保持留空（Admin 挂在根路径 `/`，它用的是 `createWebHistory('/')`）。

如果非要硬编码进 yml 而不是用环境变量，改 `docker-compose.dokploy.yml` 里 `main.environment` 的这几行：

```yaml
      PROTOCOL: https                                  # 原为 ${PROTOCOL:-http}
      MONOPOLY_DOMAIN: rich.oky.su                     # 原为 ${MONOPOLY_DOMAIN:-localhost}
      API_BASE_PREFIX: /monopoly-server                # 原为 ${API_BASE_PREFIX:-}
      ICE_BASE_PREFIX: /monopoly-ice                   # 原为 ${ICE_BASE_PREFIX:-}
```

（不推荐，因为密码之类的也都要硬编码进去，而 Dokploy 的 Environment 变量本来就会覆盖。）

---

## 3. 配置域名（Dokploy Domains）

> 前置：`rich.oky.su` 的 DNS **A 记录**已经指向这台服务器。

Dokploy → 你的 Compose 服务 → **Domains** 标签页 → **Add Domain**，加 **3 条**：

| Host | Path | Strip Path | Container Port | HTTPS |
| --- | --- | --- | --- | --- |
| `rich.oky.su` | `/monopoly-server` | ✅ 开 | `8081` | ✅ |
| `rich.oky.su` | `/monopoly-ice` | ✅ 开 | `8082` | ✅ |
| `rich.oky.su` | `/` | ❌ 关 | `8083` | ✅ |

为什么要这样拆（对应 `apps/server/app.ts` 和客户端 `global.config.ts`）：

| 请求 | Traefik 处理 | 容器收到 |
| --- | --- | --- |
| `https://rich.oky.su/monopoly-server/user/login` | 剥掉 `/monopoly-server` | `/user/login` → 8081 ✓ |
| `https://rich.oky.su/monopoly-ice/peerjs/id` | 剥掉 `/monopoly-ice` | `/peerjs/id` → 8082 ✓ |
| `https://rich.oky.su/`、`/assets/*`、`/env.js` | 不剥 | `/...` → 8083 ✓ |

服务端在**没有前缀**时会生成带 `:端口` 的 URL（`http://域名:8081`），而 Traefik 只监听 443，所以走域名就**必须**用前缀模式。

> ⚠️ **改完域名必须重新 Deploy**。Dokploy 对 Compose 是靠注入 Docker labels 配 Traefik 的，没有热重载（只有 Application 类型才有）。
>
> 点 **Preview Compose** 可以看最终生成的 compose，确认 `main` 上有 Traefik labels。

---

## 4. 部署

点 **Deploy**。日志里出现下面这些就是成功了：

```
[entrypoint] MySQL mysql:3306 已就绪（第 1 次尝试）
[entrypoint] 启动：node server.js
 SERVER  INFO :  数据库连接成功
 SERVER  INFO :  API服务启动成功 8081端口
 SERVER  INFO :  Admin服务启动成功 8083端口
 SERVER  INFO :  ICE服务启动成功 8082端口
```

访问：

| 服务 | 地址 |
| --- | --- |
| Admin 管理面板 | `https://rich.oky.su` |
| API 健康检查 | `https://rich.oky.su/monopoly-server/health` → `OK` |
| 联机信令 | `wss://rich.oky.su/monopoly-ice` |

同时 8081/8082/8083 端口也是直接发布的，调试时可以用 `http://<IP>:8083` 绕过 Traefik 排查问题。

### 需要放行的端口

| 端口 | 协议 | 用途 |
| --- | --- | --- |
| 80、443 | TCP | Traefik（Dokploy 自己管） |
| **3478** | **UDP** | STUN/TURN，最常用，**别漏** |
| 3478 | TCP | TURN over TCP |
| **49160-49200** | **UDP** | TURN 中继端口段 |

> 9641（Prometheus 指标）**不用对公网开放**：coturn 和 main 在同一个 compose 内网，Admin 面板直接用 `http://coturn:9641/metrics` 抓。
>
> 「49160-49200 是 41 个端口，够约 40 个并发中继」。这是把 coturn 默认的 49152-65535（16384 个端口）压到最小的结果，人多就调大 `TURN_MAX_PORT`（记得同步放行新范围）。
> 云厂商**安全组**和系统防火墙两层都要放行，尤其是 UDP —— 这是「部署完了还是连不上」最常见的原因。

---

## 5. 数据持久化与备份

| 卷 | 容器路径 | 内容 |
| --- | --- | --- |
| `monopoly-public` | `/app/public` | 头像、地图、日志 |
| `mysql-data` | `/var/lib/mysql` | 数据库 |

命名卷可以在 Dokploy 的 **Volume Backups** 里配 S3 自动备份。

> 别改成绝对路径的 bind mount —— Dokploy 每次部署会清掉。要用 bind mount 必须写成 `../files/xxx`。

---

## 6. 一次性部署 vs 独立部署 coturn

`docker-compose.dokploy.yml` 已经把 coturn 合并进去了，**默认就是一次性部署**。关于这个选择：

**合并（默认，推荐给单机自用）**

- 一个 Compose 应用、一个 Deploy 按钮，`TURN_URL` 自动跟随 `MONOPOLY_DOMAIN`。
- coturn 用 **bridge 网络 + 端口段发布**（`49160-49200:49160-49200/udp`），和 main 在同一个 compose 内网，Admin 面板能直接抓 `coturn:9641` 的指标。
- **不用 `network_mode: host`**：host 网络和 Dokploy 注入的 `dokploy-network` 无法共存，一旦冲突会让整个应用起不来；而且 host 网络下 main 也够不到 coturn 的指标端口。
- 代价：容器内探测不到公网 IP，所以 `EXTERNAL_IP` 是必填项。

**独立部署（想分开管理 / 放到另一台机器时）**

用 `docker/coturn/docker-compose.yml` 单独开一个 Compose 应用：

| 场景 | 建议 |
| --- | --- |
| 就想一台机器一个应用，联机也能用 | 用默认的合并版 |
| coturn 放到另一台机器 / 多个服务共用 | 拆开用 `docker/coturn/docker-compose.yml` |
| 需要 `turns:`（TLS 中继） | 拆开（合并版不挂证书） |

拆开的话记得在 main 的环境变量里手动填 `TURN_URL=<coturn 的公网 IP 或域名>`，并把 `COTURN_METRICS_URL` 改成 `http://<coturn IP>:9641/metrics`（跨机器时服务名 `coturn` 不通）。

### 关于 `turns:`（TLS 中继 / 5349）

合并版**没有启用 TLS 中继**，只提供 UDP（3478）和 TCP（3478）—— 覆盖绝大多数家用和移动网络。日志里这几行是**预期行为**，不是错误：

```
WARNING cannot find certificate file: turn_server_cert.pem (1)
WARNING cannot start TLS and DTLS listeners because certificate file is not set properly
```

需要 TLS 中继（企业网/严格防火墙场景）时，用独立部署版并在 `docker/coturn/certs/` 放 `fullchain.pem` + `privkey.pem`（见 [docker/coturn/README.md](../docker/coturn/README.md)）。

> 服务端会给每个用户同时下发 `turns:域名:5349?transport=tcp` 和 `turn:域名:3478?transport=udp`，ICE 会自动挑能通的那条。没有 TLS 就只是少了一条路，不影响 UDP 可用时的联机。

---

## 7. ⚠️ 客户端必须用匹配的配置重新构建

自建服务器最容易踩的坑：**客户端（网页版 / Electron / Android）的服务器地址是构建时写死的**。客户端源码里 `global.config.ts` 全部走 `env()` 构建期注入，没有 `env.js`，UI 里也没有「填写服务器地址」的设置项 —— 官方发布的客户端**只能连 `fatpaper.site`**。

两条路：

- **省事**：把网页版丢到 Vercel，玩家直接用浏览器玩 → 见 [用 Vercel 部署网页版客户端](vercel-web-client.md)
- **要桌面/安卓包**：自己构建，往下看

改仓库的 **Settings → Secrets and variables → Actions → Variables**：

| Variable | 值（对应上面的 HTTPS 域名模式） |
| --- | --- |
| `MONOPOLY_DOMAIN` | `rich.oky.su` |
| `PROTOCOL` | `https` |
| `SERVER_PORT` | `8081` |
| `ICE_SERVER_PORT` | `8082` |
| `API_BASE_PREFIX` | `/monopoly-server` |
| `ICE_BASE_PREFIX` | `/monopoly-ice` |
| `MONOPOLY_ADMIN_PORT` | `8083` |

然后打个 `client-v*` tag 触发 `release.yml`，产出指向你自己服务器的 Electron 安装包 / APK / Web 包。

只想快速验证，本地构建网页版最省事：

```bash
cp .env.example .env    # 填上面的值
pnpm install
pnpm --filter @mine-monopoly/env run build
pnpm --filter @mine-monopoly/client run build:web   # 产物在 apps/client/dist/frontend
```

---

## 8. 常见问题

**`main` 一直重启，日志停在「等待 MySQL」**

入口脚本最多等 300 秒（可用 `DB_WAIT_TIMEOUT` 调）。看 mysql 容器日志确认它在正常启动；密码不一致最常见。

**`数据库连接失败` / `ECONNREFUSED mysql:3306`**

- 配了 Domain 之后 Dokploy 会给 `main` 额外挂 `dokploy-network`。用 **Preview Compose** 确认 `main` 同时还在 `monopoly` 网络上；如果只剩 `dokploy-network`，把 `mysql` 也加到同一个网络。
- MySQL 数据卷是用旧密码初始化的：**改密码不会同步到已初始化的卷**。要么删掉 `mysql-data` 卷重来（丢数据），要么用 `MYSQL_ROOT_PASSWORD` 登进去 `ALTER USER`。

**部署报 `coturn 需要 EXTERNAL_IP，请在 Dokploy 的 Environment 里填服务器公网 IP`**

就是字面意思，去 Environment 补 `EXTERNAL_IP=<服务器公网 IP>`。这是故意做成硬失败的 —— 不填的话 coturn 会分配容器内网地址，联机静默失败，比直接报错难查得多。

**只想先不要 coturn**

把 `docker-compose.dokploy.yml` 里的 `coturn:` 整段删掉，再把 main 的 `COTURN_METRICS_URL` 随便填个不可达地址即可（Admin 的 TURN 监控会报错，不影响其它功能）。

**Admin 面板白屏 / 请求发到 localhost**

`MONOPOLY_DOMAIN` 没改。改完**重新 Deploy**。

**Admin 面板能开，但接口 404 或返回 HTML**

Traefik 的 Path 与 `API_BASE_PREFIX` 不一致，或者 `Strip Path` 没开。两者必须严格对应。如果 `/monopoly-server/...` 返回的是 Admin 的 HTML，说明路由优先级不对，改用两个子域：`rich.oky.su` 只放 API/ICE 两条，Admin 单独用 `admin.oky.su` → `8083`（服务端已开启 CORS，跨域可用）。

**头像/图片上传后显示不出来**

本地存储的 URL 用 `PROTOCOL://MONOPOLY_DOMAIN + API_BASE_PREFIX + /static/...` 拼接，三个值要和实际访问方式完全一致。

**TURN 监控显示拉取失败**

默认 `COTURN_METRICS_URL=http://coturn:9641/metrics`，依赖 coturn 和 main 在同一个 compose 网络里。测一下：

```bash
docker exec <main容器> wget -qO- http://coturn:9641/metrics | head
```

出来 `stun_binding_request` 之类的指标就说明正常。如果自己改成了别的地址（比如跨机器部署），要确保 main 能访问到。

**重启后所有人掉登录**

服务端 RSA 签名密钥是进程启动时随机生成的（`apps/server/src/utils/rsaKey.ts`），重启即失效。单副本自建场景问题不大，别频繁重启。

---

## 相关文件

| 文件 | 作用 |
| --- | --- |
| `docker-compose.dokploy.yml` | Dokploy 一次性部署（main + mysql + coturn） |
| `docker/Dockerfile` | 镜像定义（服务端 + Admin 面板） |
| `docker/entrypoint.sh` | 启动前等待 MySQL、初始化目录 |
| `.github/workflows/docker-image.yml` | 构建并推送镜像到 GHCR |
| `docker/coturn/` | coturn 独立部署（拆开时用，或部署到另一台机器） |
| `docs/rainyun-deploy.md` | 雨云 RCA 部署指南（另一条路线） |
