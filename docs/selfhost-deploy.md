# 自建服务器部署（直连 IP，不用 Dokploy / K8s）

一台普通 VPS，纯 Docker Compose 跑起**全量**：网页版客户端 + 服务端 + MySQL + coturn。

```
                 ┌──────────── 一台 VPS ────────────┐
  玩家浏览器 ──▶  │  web    nginx :80   网页版客户端   │
                 │  main   :8081 API / :8082 信令 /  │
                 │         :8083 Admin 面板           │
                 │  mysql  :3306（仅内网）            │
                 │  coturn :3478 + 49160-49200（联机中继）│
                 └───────────────────────────────────┘
```

参考配置（本仓库实际部署过的机器）：**4C / 4G / 40G 盘**。实测内存占用约 450 MB（`main` 35M + `mysql` 374M + `coturn` 7M + `web` 20M），2C2G 也够用，但不要在服务器上构建镜像。

---

## 1. 安全组 / 防火墙

| 端口 | 协议 | 用途 |
| --- | --- | --- |
| `22` | TCP | SSH |
| `80` | TCP | 网页版客户端（nginx） |
| `8081` | TCP | API |
| `8082` | TCP | WebRTC 信令（WebSocket） |
| `8083` | TCP | Admin 管理面板 |
| `3478` | **UDP** | STUN/TURN，**最容易漏** |
| `3478` | TCP | TURN over TCP |
| `49160-49200` | **UDP** | TURN 中继端口段 |

云厂商安全组和系统防火墙两层都要放行。腾讯云 CVM 默认 `ufw` 是关的，只需配安全组。

---

## 2. 部署

```bash
sudo mkdir -p /opt/mine-monopoly && sudo chown $USER:$USER /opt/mine-monopoly
cd /opt/mine-monopoly

# compose 文件
curl -fsSL https://raw.githubusercontent.com/Okysu/mine-monopoly/main/docker-compose.selfhost.yml -o docker-compose.yml
curl -fsSL https://raw.githubusercontent.com/Okysu/mine-monopoly/main/docker/nginx/frontend.conf -o nginx.conf

# 环境变量（见第 3 节）
cat > .env <<'EOF'
MONOPOLY_DOMAIN=你的公网IP
PROTOCOL=http
EXTERNAL_IP=你的公网IP
MYSQL_PASSWORD=用 openssl rand -hex 16 生成
MYSQL_ROOT_PASSWORD=用 openssl rand -hex 16 生成
MAP_ENCRYPT_KEY=用 openssl rand -hex 8 生成（必须正好16位）
TURN_SECRET=用 openssl rand -hex 32 生成
EOF
chmod 600 .env

docker compose up -d
```

`EXTERNAL_IP` 是**必填**的：coturn 在 bridge 网络里探测不到宿主机公网 IP，不填 compose 会直接报错——这是故意的，省得联机静默失败。

### 环境变量说明

| 变量 | 说明 |
| --- | --- |
| `MONOPOLY_DOMAIN` | 公网 IP 或域名，**不带协议不带端口** |
| `PROTOCOL` | 直连 IP 填 `http`；域名 + HTTPS 填 `https` |
| `EXTERNAL_IP` | 公网 IP，coturn 用 |
| `API_BASE_PREFIX` / `ICE_BASE_PREFIX` | **直连 IP 时留空**；只有 nginx 反代并剥前缀时才填 |
| `MAP_ENCRYPT_KEY` | 必须与客户端构建时用的值**完全一致** |
| `TURN_URL` | 留空自动跟随 `MONOPOLY_DOMAIN` |

---

## 3. 网页版客户端的静态产物

仓库里没有前端产物（是构建产物），需要用根目录的 [`Dockerfile.web`](../Dockerfile.web) 打出来再放到 `./web/`：

```bash
# 在开发机上（需要有 Docker）
docker build -f Dockerfile.web \
  --build-arg MONOPOLY_DOMAIN=你的公网IP \
  --build-arg PROTOCOL=http \
  --build-arg SERVER_PORT=8081 \
  --build-arg ICE_SERVER_PORT=8082 \
  --build-arg MONOPOLY_ADMIN_PORT=8083 \
  --build-arg MAP_ENCRYPT_KEY=和服务器一致的值 \
  --build-arg VITE_WEB_BASE_PATH=/ \
  --output type=local,dest=./web-dist .

# 上传（注意 tar 会带出导出目录的 700 权限，必须修）
tar -czf web-dist.tar.gz -C ./web-dist .
scp web-dist.tar.gz user@服务器:/tmp/
ssh user@服务器 'cd /opt/mine-monopoly && mkdir -p web && tar -xzf /tmp/webdist.tar.gz -C web && sudo chmod -R a+rX web'
```

⚠️ **客户端里的服务器地址是构建时写死的**（vite `envPlugin` 把值注入到 bundle）。改了 IP/端口/域名，必须重新构建产物再上传。`MAP_ENCRYPT_KEY` 也必须在两侧一致。

---

## 4. 第一个管理员账号

注册接口固定写死 `isAdmin=0`，而创建管理员的接口本身需要管理员 token，所以第一个管理员只能手动提权：

```bash
# 1. 先用网页版正常注册一个账号
# 2. 然后执行：
docker exec mine-monopoly-mysql-1 mysql -uroot -p"$MYSQL_ROOT_PASSWORD" monopoly \
  -e "UPDATE user SET isAdmin=1 WHERE useraccount='你的账号';"
```

注意表名是小写 `user`，字段是 `isAdmin`。

---

## 5. 日常运维

```bash
cd /opt/mine-monopoly
docker compose ps            # 状态
docker compose logs -f main  # 看服务端日志
docker compose pull && docker compose up -d   # 更新服务端镜像
```

`main` 带了 HEALTHCHECK，`docker compose ps` 里显示 `(healthy)` 才算真的正常。

容器都是 `restart: unless-stopped`，Docker 也是开机自启的，服务器重启后会自动恢复。

数据都在命名卷里：`mine-monopoly_monopoly-public`（头像/地图/日志）、`mine-monopoly_mysql-data`（数据库）。备份用 `docker run --rm -v mine-monopoly_mysql-data:/data -v $(pwd):/backup alpine tar czf /backup/mysql-$(date +%F).tar.gz -C /data .`。

---

## 6. 常见问题

**网页版打开是 403 Forbidden**

nginx 读不了文件。`sudo chmod -R a+rX /opt/mine-monopoly/web`（用 `tar` 解压导出目录时很容易踩到）。

**网页版打开白屏**

F12 看是不是 `/assets/*.js` 404。多半是 `VITE_WEB_BASE_PATH` 不是 `/`，或者构建时没传对变量。

**刷新 `/game` 变 404**

nginx 配置里的 SPA 回退丢了。确认 `nginx.conf` 里有 `try_files $uri $uri/ /index.html;`。

**服务端日志报 `数据库连接失败`**

排查顺序：`MYSQL_PASSWORD` 两边是否一致 → MySQL 数据卷是否用旧密码初始化过（改密码不会同步到已有卷，得删卷重来）。

**Admin 面板接口全 404**

`API_BASE_PREFIX` 填了值但 nginx 没有剥前缀。直连 IP 场景应当留空。

**联机连不上**

按顺序查：安全组 UDP `3478` 和 `49160-49200` → `EXTERNAL_IP` 填对了没 → `TURN_SECRET` 与 coturn 一致 → Admin 面板的 TURN 监控能不能抓到指标。

**日志里一直刷 `ERR_ERL_PERMISSIVE_TRUST_PROXY`**

`apps/server/app.ts` 里 `app.set("trust proxy", true)` 与 `express-rate-limit` v8 的校验冲突。只打日志不中断请求，不影响功能。要消掉就把 `true` 换成跳数（单层反代填 `1`）。

---

## 相关文件

| 文件 | 作用 |
| --- | --- |
| `docker-compose.selfhost.yml` | 四个容器的完整编排 |
| `Dockerfile.web` | 构建网页版客户端静态产物 |
| `docker/nginx/frontend.conf` | nginx 托管前端 + SPA 回退 |
| `docker-compose.dokploy.yml` | Dokploy 版本（把 nginx 换成 Traefik） |
| `docs/dokploy-deploy.md` | Dokploy 部署（域名 + HTTPS） |
| `docs/vercel-web-client.md` | 前端改挂 Vercel |
