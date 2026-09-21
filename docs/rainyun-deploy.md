# 雨云云应用 RCA 部署指南

把 Mine Monopoly 服务端（API + ICE + Admin 管理面板）部署到[雨云云应用 RCA](https://www.rainyun.com/docs/products/rca/start)。

- 服务端 → **雨云 RCA**
- MySQL → **同一个 RCA 应用里的第二个容器**
- coturn（WebRTC 中继）→ **一台有公网 IP 的 VPS**（RCA 跑不了，原因见 [coturn 说明](../docker/coturn/README.md)）

```
                    ┌──────────── 雨云 RCA 应用 ────────────┐
   浏览器/客户端 ──▶ │  main  :8081 API   :8082 ICE   :8083 Admin │
                    │    │                                       │
                    │    └──▶ mysql :3306（仅内网）              │
                    └───────────────────────────────────────────┘
                                    │ TURN 凭证
                                    ▼
                            coturn（你的 VPS）
```

---

## 一、构建镜像

镜像由 GitHub Actions 自动构建并推送到 GHCR：

```
ghcr.io/<你的GitHub用户名小写>/mine-monopoly-server
```

### 触发构建

工作流文件：`.github/workflows/docker-image.yml`

| 触发方式 | 说明 |
| --- | --- |
| push 到 `main` / `dev` | 自动构建，产出 `latest` / `main` / `dev` 标签 |
| push tag `server-v1.2.3` | 产出 `1.2.3`、`1.2`、`latest` |
| 手动触发 | 仓库 **Actions → Docker Image → Run workflow**，可勾选"是否推送" |

> Fork 之后如果 Actions 是关的，先去仓库 **Actions** 标签页点一下启用。
> 想立刻构建一次：**Actions → Docker Image → Run workflow → Run workflow**（保持 `push_image = true`）。

构建完成后在仓库右侧 **Packages**（或个人主页 → Packages）能看到 `mine-monopoly-server`。

### ⚠️ 把镜像设为公开

GHCR 的包**默认是私有的**，雨云拉取会失败。第一次构建完必须改一次：

> 个人头像 → **Your packages** → `mine-monopoly-server` → **Package settings** → 页面底部 **Change visibility** → **Public** → 输入包名确认

（如果仓库本身是 public，这一步同样需要手动做一次，只有后续推送会自动保持 public。）

改完可以直接验证：

```bash
docker pull ghcr.io/<owner>/mine-monopoly-server:latest
```

### 国内拉取慢怎么办

雨云拉 GHCR 偶尔会慢或超时。两个办法：

1. 在雨云 RCA 里配置镜像加速/代理（面板支持自定义 registry 时）。
2. 改用国内 registry：把 workflow 里 `Log in to GHCR` 和 `Compute image name and tags` 换成阿里云 ACR / 腾讯云 TCR 的地址与密钥即可，镜像名在 `docker-compose.rainyun.yml` 里改一处。

---

## 二、在 RCA 上创建应用

### 方式 A：Compose 导入（推荐）

1. 雨云控制台 → **我的项目** → 新建项目（或使用已有项目）
2. **应用商店 → 应用模板 → 创建应用模板**，填个名字，进入**版本编辑**
3. 点 **从 Docker 导入**，把仓库根目录的 [`docker-compose.rainyun.yml`](../docker-compose.rainyun.yml) 内容整段粘进去
4. 导入后会生成两个容器：`main`（服务端）和 `mysql`（数据库）
5. 按下面的表格核对/修改环境变量
6. 保存版本 → 安装应用

### 方式 B：手动添加多个容器

在版本编辑页点 **添加容器**，逐个建：

**容器 1：`main`**

| 项 | 值 |
| --- | --- |
| 镜像 | `ghcr.io/<owner>/mine-monopoly-server:latest` |
| Command | 留空 |
| Args | 留空 |
| 最小 CPU | `1` 核 |
| 最小内存 | `1024` MB（建议 2048） |

服务：

| 服务名称 | 显示名称 | 服务类型 | 内部端口 | 外部端口 | 协议 |
| --- | --- | --- | --- | --- | --- |
| `http` | API 服务 | 外部访问 | `8081` | `8081` | tcp |
| `ice` | 联机服务 | 外部访问 | `8082` | `8082` | tcp |
| `admin` | 管理面板 | 外部访问 | `8083` | `8083` | tcp |

持久化卷：

| 名称 | 挂载路径 | 子路径 | 内容类型 |
| --- | --- | --- | --- |
| `monopoly-public` | `/app/public` | `monopoly-public` | 目录 |

环境变量：

| Key | Value |
| --- | --- |
| `SERVER_PORT` | `8081` |
| `ICE_SERVER_PORT` | `8082` |
| `MONOPOLY_ADMIN_PORT` | `8083` |
| `PROTOCOL` | `http`（走 HTTPS 域名时改 `https`） |
| `MONOPOLY_DOMAIN` | **RCA 分配给你的地址**，见第三步 |
| `API_BASE_PREFIX` | 留空 |
| `ICE_BASE_PREFIX` | 留空 |
| `ADMIN_BASE_PREFIX` | 留空 |
| `MYSQL_HOST` | `${rca_svc_mysql_db}` |
| `MYSQL_PORT` | `3306` |
| `MYSQL_DATABASE` | `monopoly` |
| `MYSQL_USERNAME` | `monopoly` |
| `MYSQL_PASSWORD` | 自己设一个强密码 |
| `NODE_ENV` | `production` |
| `TURN_URL` | coturn 的公网 IP 或域名（不带端口） |
| `TURN_PORT` | `5349` |
| `STUN_PORT` | `3478` |
| `TURN_SECRET` | 与 coturn 一致 |
| `TURN_TTL` | `86400` |
| `COTURN_METRICS_URL` | `http://<coturn IP>:9641/metrics` |
| `MAP_ENCRYPT_KEY` | **16 位 ASCII 字符**，例如 `ChangeMe16Char!!` |
| `AVATAR_STORAGE_PATH` | `monopoly/user-avatar` |
| `GAME_MAP_STORAGE_PATH` | `monopoly/game-map` |

> `${rca_svc_mysql_db}` 是 RCA 的容器互连变量：`mysql` = 数据库容器名，`db` = 数据库容器的服务名。
> 只在你手动建容器时才需要；用 Compose 导入的话直接写 `mysql` 就行（compose 服务名）。
> 注意这个变量**只给地址不带端口**，所以 `MYSQL_PORT` 要单独填。

**容器 2：`mysql`**

| 项 | 值 |
| --- | --- |
| 镜像 | `mysql:8.0` |
| 最小 CPU | `1` 核 |
| 最小内存 | `512` MB |

服务：`db` / 数据库 / **内部访问** / 内部端口 `3306` / 外部端口留空 / tcp

持久化卷：`mysql-data` → `/var/lib/mysql`（目录）

环境变量：

| Key | Value |
| --- | --- |
| `MYSQL_ROOT_PASSWORD` | 自己设一个强密码 |
| `MYSQL_DATABASE` | `monopoly` |
| `MYSQL_USER` | `monopoly` |
| `MYSQL_PASSWORD` | 与 main 容器里的 `MYSQL_PASSWORD` 完全一致 |

> **数据库名必须是 `monopoly`**。服务端 `apps/server/src/db/dbConnecter.ts` 里数据库名是硬编码的，
> 改成别的名字会连不上。建表由 TypeORM `synchronize: true` 自动完成，不需要手动导入 SQL。

### 建议暴露给用户的 Options

如果你要把这个应用做成模板给别人用，建议把这些做成 Options（标签 + 环境变量键 + 默认值 + 是否必填）：

| 标签 | 环境变量键 | 类型 | 默认值 | 必填 | 备注 |
| --- | --- | --- | --- | --- | --- |
| 访问地址 | `MONOPOLY_DOMAIN` | 文本 | 空 | 是 | 域名或节点 IP |
| 协议 | `PROTOCOL` | 单选 | `http` | 是 | `http` / `https` |
| TURN 服务器 | `TURN_URL` | 文本 | 空 | 是 | coturn 地址 |
| TURN 密钥 | `TURN_SECRET` | 文本 | 空 | 是 | 与 coturn 一致，建议启用随机生成 |
| 地图加密密钥 | `MAP_ENCRYPT_KEY` | 文本 | `ChangeMe16Char!!` | 是 | 校验 `^.{16}$` |
| 数据库密码 | `MYSQL_PASSWORD` | 文本 | 空 | 是 | 建议启用随机生成 |
| 数据库 root 密码 | `MYSQL_ROOT_PASSWORD` | 文本 | 空 | 是 | 建议启用随机生成 |

---

## 三、把访问地址填对

`MONOPOLY_DOMAIN` / `PROTOCOL` 是**运行时**变量，改完重启容器生效（Admin 面板通过服务端注入的 `/env.js` 读取）。它们决定：

- Admin 面板里所有 API 请求打到哪
- 客户端拿到的 ICE 服务器地址
- 本地上传文件的返回 URL

### 纯端口访问

RCA 会给你 `节点IP:端口`。那就填：

```
PROTOCOL=http
MONOPOLY_DOMAIN=<节点IP>
```

访问：

- Admin 面板 `http://<节点IP>:8083`
- API 健康检查 `http://<节点IP>:8081/health`
- 联机服务 `ws://<节点IP>:8082`

### 域名 + HTTPS（推荐）

在项目里 **网站管理 → 添加网站 → 应用代理**，指向 `main` 容器的 `8083` 端口，雨云会自动签 HTTPS 证书。然后：

```
PROTOCOL=https
MONOPOLY_DOMAIN=<雨云分配的域名>
```

> ⚠️ **客户端联机端口 8082 走的是 WebSocket**。如果你用的是网页版客户端（HTTPS 页面），
> 浏览器会拦截 `ws://` 明文连接（mixed content）。这种情况要么用 Electron / Android 客户端，
> 要么给 8082 也配一个带 TLS 的代理。
>
> `API_BASE_PREFIX` 这类路径前缀只有在反代会**剥掉前缀**时才有用；
> 雨云的应用代理默认不剥前缀，所以**保持留空**。

---

## 四、验证

1. **健康检查**：浏览器打开 `http://<地址>:8081/health`，返回 `OK`
2. **数据库**：`main` 容器日志里出现 `数据库连接成功`。连不上时看下面的常见问题
3. **Admin 面板**：打开 `http://<地址>:8083`，用管理员账号登录
4. **首次注册**：第一个注册的用户不一定自动是管理员，`isAdmin` 需要按项目自身规则处理
5. **联机**：客户端填好服务器地址后建房、第二台设备加入

---

## 常见问题

**容器一直在重启 / 日志里只有"等待 MySQL"**

入口脚本会先探测 `MYSQL_HOST:MYSQL_PORT`，最多等 300 秒（`DB_WAIT_TIMEOUT` 可调）。
确认 MySQL 容器状态是"运行中"，以及密码一致。调试时可以设 `SKIP_DB_WAIT=1` 跳过等待。

**日志出现 `数据库连接失败` / `ECONNREFUSED`**

- `MYSQL_HOST` 填错。用 Compose 导入填 `mysql`；手动建容器填 `${rca_svc_mysql_db}`。
- `MYSQL_DATABASE` 不是 `monopoly`。
- 密码在 main 和 mysql 两个容器里不一致。改 `MYSQL_PASSWORD` 后 MySQL 已初始化的数据卷**不会**同步改密码，
  要么用 `MYSQL_ROOT_PASSWORD` 登进去 `ALTER USER`，要么删掉 `mysql-data` 重新初始化（会丢数据）。

**Admin 面板打开是白屏 / 请求全部失败**

`MONOPOLY_DOMAIN` 和 `PROTOCOL` 没改成实际访问地址。改完重启容器。

**镜像拉不下来**

GHCR 包还是私有（见"把镜像设为公开"），或者雨云节点访问 GHCR 超时（见"国内拉取慢"）。

**重启后所有人都掉登录**

服务端的 RSA 签名密钥是**每次进程启动随机生成的**（`apps/server/src/utils/rsaKey.ts`），
重启会让已签发的 token 全部失效。RCA 上单副本问题不大，但要注意别频繁重启；
需要彻底解决要把密钥改成从环境变量/持久化卷读取。

**Admin 面板的 TURN 监控一直是错误**

`COTURN_METRICS_URL` 指向的 9641 端口是内网/不可达。这只影响监控展示，不影响联机。
如果确实要看指标，就在 coturn 的 VPS 上放行 9641（不建议暴露公网），或者忽略它。

---

## 相关文件

| 文件 | 作用 |
| --- | --- |
| `.github/workflows/docker-image.yml` | 构建并推送镜像到 GHCR |
| `docker/Dockerfile` | 镜像定义（服务端 + Admin 面板） |
| `docker/entrypoint.sh` | 启动前等待 MySQL、初始化目录 |
| `docker-compose.rainyun.yml` | 雨云 RCA 导入用 compose（main + mysql） |
| `docker/coturn/` | coturn 独立部署（VPS / Dokploy） |
| `docker/docker-compose.yml` | 传统自建服务器 + coturn 的 compose |
| `apps/server/src/utils/role-validation.ts` | 把 `/health` 加进免鉴权白名单，容器探针才能用 |
