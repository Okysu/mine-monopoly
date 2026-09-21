# 用 Vercel 部署网页版客户端

**可以。** 网页版客户端是纯静态 SPA（Vite 产物），很适合丢给 Vercel；后端留在 Dokploy 上，两边通过 HTTPS/WSS 跨域通信。

```
  玩家浏览器
      │
      ├── https://play.oky.su            ← Vercel：网页版客户端（静态 SPA）
      │
      └── https://rich.oky.su            ← Dokploy：后端
             ├── /monopoly-server  → 8081  API       (CORS 已开启)
             └── /monopoly-ice     → 8082  WebRTC 信令 (WSS)
```

---

## 1. 前置

后端已经在 Dokploy 上跑起来（见 [dokploy-deploy.md](dokploy-deploy.md)），并且满足：

- `https://rich.oky.su/monopoly-server/health` 返回 `OK`
- `rich.oky.su` 在 Cloudflare 上是 **DNS only（灰色云朵）**

---

## 2. 在 Vercel 建项目

Vercel → **Add New → Project** → 选你的 fork `Okysu/mine-monopoly`。

**Root Directory 保持仓库根目录不要改**（构建要用 pnpm workspace）。其余交给仓库根目录的 [`vercel.json`](../vercel.json)：

| 项 | 值（vercel.json 已写死，无需手填） |
| --- | --- |
| Build Command | `pnpm --filter @mine-monopoly/env run build && pnpm --filter @mine-monopoly/client run build:web` |
| Output Directory | `apps/client/dist/frontend` |
| Install Command | 默认（Vercel 识别到 `pnpm-lock.yaml` 会自动用 pnpm） |

> `@mine-monopoly/env` 必须先构建：客户端的 `vite.config.ts` 直接 `import { envPlugin } from "@mine-monopoly/env/vite-plugin"`，这个子路径指向 `packages/env/dist/`，不构建就解析不到。这和仓库里 `release.yml` 的步骤是一致的。

### 环境变量

Vercel → Project → **Settings → Environment Variables**，把下面这些加到 **Production**（想让 Preview 也能用就三个环境都加）：

| Key | Value |
| --- | --- |
| `MONOPOLY_DOMAIN` | `rich.oky.su` |
| `PROTOCOL` | `https` |
| `SERVER_PORT` | `8081` |
| `ICE_SERVER_PORT` | `8082` |
| `API_BASE_PREFIX` | `/monopoly-server` |
| `ICE_BASE_PREFIX` | `/monopoly-ice` |
| `MAP_ENCRYPT_KEY` | 和 `dokploy.env` 里的保持**完全一致** |
| `VITE_WEB_BASE_PATH` | `/` |

`ADMIN_BASE_PREFIX` 不用填（客户端用不到）。

> ⚠️ **千万不要把 `TURN_SECRET`、`MYSQL_PASSWORD`、`MYSQL_ROOT_PASSWORD` 配到 Vercel 项目里。**
> 客户端的 `envPlugin` 会把构建时 `process.env` 里的变量**打进前端 bundle**，而它配置的 `exclude` 只排除了 `MYSQL_PASSWORD` 和 `TC_KEY`
> —— `TURN_SECRET` 不在排除列表里，配了就会跟着前端一起发到公网。
> 客户端只认上面表里那 8 个变量，其余一个都不要加。

### 关于 `MAP_ENCRYPT_KEY`

它**必须**放进前端：客户端要用它加解密地图产物。所以它本质上是"客户端共享密钥"，不是真正的服务端密钥，放进前端 bundle 是这个项目本来的设计（上游的 `release.yml` 也是这么构建的）。只要和你后端 `dokploy.env` 里的值一致就行，不一致会导致地图功能异常。

---

## 3. 绑定域名

Vercel → Project → **Settings → Domains** → 添加 `play.oky.su`。

然后去 **Cloudflare → oky.su → DNS** 加记录：

| 类型 | 名称 | 内容 | 代理状态 |
| --- | --- | --- | --- |
| CNAME | `play` | `cname.vercel-dns.com` | **仅 DNS（灰色云朵）** |

Vercel 会提示它期望的 CNAME 目标，以 Vercel 面板显示的为准。Vercel 会自动签发并续期 HTTPS 证书。

> 灰云是为了省事。想让 Cloudflare 代理也行（要设成 **Full (strict)**），但那层代理对纯静态站点没什么收益，还多一层排错成本。

只想先试试、不绑域名也可以：直接用 Vercel 给的 `xxx.vercel.app` 地址，但记得把 `VITE_WEB_BASE_PATH` 保持 `/`，并且 `rich.oky.su` 的 CORS 不受影响（服务端 `cors()` 是允许所有来源的）。

---

## 4. 部署

Push 到 `main` 后 Vercel 自动构建。第一次会比较慢（要装完整 pnpm workspace + 打包 three.js / pixi.js / monaco）。

构建完成后打开 `https://play.oky.su`：

1. 出现登录页 → 说明静态资源和 SPA 路由正常
2. 注册/登录成功 → 说明 **CORS 通了**（前端在 play 域，API 在 rich 域）
3. 建房、第二台设备加入 → 说明 **WSS 信令通了**（连的是 `wss://rich.oky.su/monopoly-ice`）
4. 两台设备不在同一局域网还能互相看到 → 说明 **TURN 通了**

---

## 5. vercel.json 里做了什么

```json
"rewrites": [
  { "source": "/room-router", "destination": "/index.html" },
  { "source": "/room",        "destination": "/index.html" },
  { "source": "/game",        "destination": "/index.html" }
]
```

客户端 Web 版用的是 **history 路由**（`createWebHistory`，只有 Electron 才用 hash）。这类路由在刷新页面或直接粘贴 `/game` 链接时会向服务器请求 `/game`，Vercel 上没有这个文件就会 404，所以必须回退到 `index.html` 交给前端路由处理。

这里**故意只列了具体路由，没有用 `/(.*)` 通配**——通配虽然更省事，但一旦它抢先于静态资源匹配，`/assets/*.js`、`/logo.ico` 都会被换成 HTML，页面直接白屏。列具体路由是稳的。

**以后在 `apps/client/src/router/index.ts` 里加了新路由，记得往 `vercel.json` 里补一条。**

`headers` 那段是给带 hash 的构建产物加长缓存，非必需但能省流量。

---

## 6. 常见问题

**构建失败：`Cannot find module '.../packages/env/dist/vite-plugin-env.js'`**

Build Command 里少了 `pnpm --filter @mine-monopoly/env run build`。别改 Root Directory，改回仓库根目录。

**构建失败：装依赖时报错 / 卡住**

确认 Root Directory 是仓库根目录（不是 `apps/client`）。pnpm workspace 必须在根目录安装。另外仓库里还躺着 `apps/admin/package-lock.json`、`apps/server/yarn.lock` 这些别的包管理器的 lockfile —— 根目录有 `pnpm-lock.yaml`，Vercel 会优先认 pnpm，正常不受影响。

**打开是白屏，Network 里 `assets/*.js` 返回的是 HTML**

`vercel.json` 的 rewrites 被改成了通配。改回列具体路由的形式。

**登录报跨域错误（CORS）**

后端 `app.ts` 里 `app.use(cors())` 是允许所有来源的，正常不该出现。检查是不是把 `PROTOCOL`/`API_BASE_PREFIX` 配错了，导致前端请求打到了别的地址（F12 看 Request URL）。

**登录能过，但建房后连不上对手**

信令或 TURN 的问题，不是 Vercel 的问题。用后端那套排查：`ICE_BASE_PREFIX` 要和 Dokploy Domains 里的 `/monopoly-ice` 一致，UDP 3478 和 49160-49200 要在安全组放行。

**想直接用官方发布的客户端连我的服务器**

做不到。官方客户端里的服务器地址是**构建时写死的**，连的是 `fatpaper.site`。要么按 `docs/dokploy-deploy.md` 第 7 节自己重新打包 Electron/Android 客户端，要么用这个 Vercel 网页版。

---

## 相关文件

| 文件 | 作用 |
| --- | --- |
| `vercel.json` | Vercel 构建命令、产物目录、SPA 路由回退、缓存头 |
| `apps/client/vite.config.ts` | `VITE_WEB_BASE_PATH`、`envPlugin` 注入逻辑 |
| `docs/dokploy-deploy.md` | 后端部署 |
| `dokploy.env` | 后端变量（含 `MAP_ENCRYPT_KEY`，要和 Vercel 保持一致） |
