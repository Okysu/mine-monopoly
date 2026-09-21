#!/bin/sh
# ============================================================================
# Mine Monopoly 服务端容器入口脚本
#
# 主要做两件事：
#   1. 等待 MySQL 就绪 —— 应用启动时如果连不上数据库，bootstrap() 只会打印错误
#      然后静默退出（容器看起来是 Running，实际没有任何服务）。在 RCA / Docker
#      Compose / K8s 里数据库容器往往比应用慢，所以这里先探测 TCP 端口。
#   2. 创建运行时需要的上传/日志目录（挂载持久化卷后目录可能是空的）。
#
# 可用环境变量：
#   DB_WAIT_TIMEOUT   等待 MySQL 的最长秒数，默认 300
#   SKIP_DB_WAIT=1    跳过等待（调试用）
# ============================================================================
set -eu

log() {
	printf '%s [entrypoint] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

# ---------------------------------------------------------------------------
# 运行目录
# ---------------------------------------------------------------------------
mkdir -p /app/public/logs/game /app/public/logs/server /app/public/temp 2>/dev/null || true

# ---------------------------------------------------------------------------
# 等待 MySQL
# ---------------------------------------------------------------------------
wait_for_mysql() {
	host="${MYSQL_HOST:-mysql}"
	port="${MYSQL_PORT:-3306}"
	timeout="${DB_WAIT_TIMEOUT:-300}"

	log "等待 MySQL ${host}:${port}（最多 ${timeout}s）..."

	# 用 node 做 TCP 探测：镜像里一定有 node，不依赖 nc/curl
	node - "$host" "$port" "$timeout" <<'NODE_EOF'
const net = require("node:net");

const [host, portArg, timeoutArg] = process.argv.slice(2);
const port = Number(portArg);
const timeoutMs = Number(timeoutArg) * 1000;
const deadline = Date.now() + timeoutMs;
let attempt = 0;

function tryConnect() {
	attempt += 1;
	const socket = net.connect({ host, port });
	socket.setTimeout(3000);

	const retry = (reason) => {
		socket.destroy();
		if (Date.now() >= deadline) {
			console.error(`[entrypoint] 等待 MySQL ${host}:${port} 超时（${attempt} 次尝试）：${reason}`);
			process.exit(1);
		}
		setTimeout(tryConnect, 2000);
	};

	socket.once("connect", () => {
		socket.destroy();
		console.log(`[entrypoint] MySQL ${host}:${port} 已就绪（第 ${attempt} 次尝试）`);
		process.exit(0);
	});
	socket.once("error", (err) => retry(err.message));
	socket.once("timeout", () => retry("连接超时"));
}

tryConnect();
NODE_EOF
}

if [ "${SKIP_DB_WAIT:-0}" = "1" ]; then
	log "SKIP_DB_WAIT=1，跳过数据库等待"
elif [ -n "${MYSQL_HOST:-}" ]; then
	if ! wait_for_mysql; then
		# 明确失败退出：交给 Docker / K8s 的重启策略重试，
		# 避免容器"看起来在跑但其实没有服务"。
		log "MySQL 不可用，退出并由编排器重启重试"
		exit 1
	fi
else
	log "未设置 MYSQL_HOST，跳过数据库等待"
fi

# ---------------------------------------------------------------------------
# 启动主进程
# ---------------------------------------------------------------------------
log "启动：$*"
exec "$@"
