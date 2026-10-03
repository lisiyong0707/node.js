#!/usr/bin/env bash
# vless-ws 终端部署脚本（无需 root）
#
# 用法一（app.js 与本脚本在同一目录；文件名不同时加 APP_FILE=xxx.js）：
#   UUID=你的uuid PORT=可用端口 DOMAIN=你的域名 bash deploy.sh
#
# 用法二（从你自己的仓库下载 vless-ws.js）：
#   APP_URL=https://raw.githubusercontent.com/你的用户名/仓库/main/app.js \
#   UUID=你的uuid PORT=可用端口 DOMAIN=你的域名 bash deploy.sh
#
# 可选变量：APP_FILE  WS_PATH  SUB_PATH  NAME  PUBLIC_PORT  APP_DIR  ALLOW_PRIVATE
# 重复运行即可更新并重启；UUID/路径会保存在 $APP_DIR/.env，未指定时沿用旧值。

set -euo pipefail

APP_DIR="${APP_DIR:-$HOME/vless}"
APP_URL="${APP_URL:-}"
APP_FILE="${APP_FILE:-app.js}"   # 程序文件名，默认 app.js
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
rand_hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# ---- 环境检查 ----
command -v node >/dev/null || die "未找到 node，请先在面板或系统中安装 Node.js 18+"
command -v npm  >/dev/null || die "未找到 npm"
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" -ge 16 ] || die "Node 版本过低（当前 $NODE_MAJOR），需要 16 以上，建议 18/20"

mkdir -p "$APP_DIR"
cd "$APP_DIR"

# ---- 读取旧配置（如有），命令行变量优先 ----
if [ -f .env ]; then
  OLD_UUID="$(grep -E '^UUID=' .env | cut -d= -f2- | tr -d '"' || true)"
  OLD_WS="$(grep -E '^WS_PATH=' .env | cut -d= -f2- | tr -d '"' || true)"
  OLD_SUB="$(grep -E '^SUB_PATH=' .env | cut -d= -f2- | tr -d '"' || true)"
  OLD_PORT="$(grep -E '^PORT=' .env | cut -d= -f2- | tr -d '"' || true)"
fi

DOMAIN="${DOMAIN:-}"
[ -n "$DOMAIN" ] || die "请设置 DOMAIN，例如 DOMAIN=example.com"
UUID="${UUID:-${OLD_UUID:-$(cat /proc/sys/kernel/random/uuid)}}"
PORT="${PORT:-${OLD_PORT:-$((RANDOM % 50001 + 10000))}}"
WS_PATH="${WS_PATH:-${OLD_WS:-/ws-$(rand_hex 6)}}"
SUB_PATH="${SUB_PATH:-${OLD_SUB:-$(rand_hex 12)}}"
NAME="${NAME:-vless-node}"
PUBLIC_PORT="${PUBLIC_PORT:-443}"
ALLOW_PRIVATE="${ALLOW_PRIVATE:-0}"

# ---- 获取程序文件 ----
if [ -n "$APP_URL" ]; then
  say "下载 $APP_FILE"
  if command -v wget >/dev/null; then wget -qO "$APP_FILE" "$APP_URL"
  elif command -v curl >/dev/null; then curl -fsSL "$APP_URL" -o "$APP_FILE"
  else die "需要 wget 或 curl"; fi
elif [ -f "$SRC_DIR/$APP_FILE" ]; then
  [ "$SRC_DIR" = "$APP_DIR" ] || cp "$SRC_DIR/$APP_FILE" "$APP_FILE"
elif [ -f "$SRC_DIR/vless-ws.js" ]; then
  say "未找到 $APP_FILE，改用 vless-ws.js"
  [ "$SRC_DIR" = "$APP_DIR" ] && APP_FILE="vless-ws.js" || cp "$SRC_DIR/vless-ws.js" "$APP_FILE"
elif [ -f "$APP_FILE" ]; then
  :
else
  die "找不到 $APP_FILE：请放在脚本同目录，或设置 APP_URL / APP_FILE"
fi

# ---- 依赖 ----
cat > package.json <<EOF
{
  "name": "site",
  "version": "1.0.0",
  "main": "$APP_FILE",
  "scripts": { "start": "node $APP_FILE" },
  "dependencies": { "ws": "^8.14.2" }
}
EOF
say "安装依赖"
npm install --omit=dev --no-audit --no-fund >/dev/null 2>&1 || die "npm install 失败，请检查网络或 npm 源"

# ---- 写配置 ----
umask 077
cat > .env <<EOF
UUID="$UUID"
PORT="$PORT"
DOMAIN="$DOMAIN"
PUBLIC_PORT="$PUBLIC_PORT"
NAME="$NAME"
WS_PATH="$WS_PATH"
SUB_PATH="$SUB_PATH"
ALLOW_PRIVATE="$ALLOW_PRIVATE"
EOF
chmod 600 .env

# ---- 停止旧进程 ----
if [ -f app.pid ] && kill -0 "$(cat app.pid)" 2>/dev/null; then
  say "停止旧进程 $(cat app.pid)"
  kill "$(cat app.pid)" || true
  sleep 1
fi

# ---- 后台启动 ----
say "启动服务"
set -a; . ./.env; set +a
nohup node "$APP_FILE" > run.log 2>&1 &
echo $! > app.pid
sleep 2

if ! kill -0 "$(cat app.pid)" 2>/dev/null; then
  echo "---- 最近日志 ----"; tail -n 20 run.log
  die "进程启动失败，请根据日志排查"
fi

say "运行中（PID $(cat app.pid)），目录：$APP_DIR"
echo "----------------------------------------"
echo "分享链接："
grep '^分享链接' run.log | sed 's/^分享链接: //' || true
echo "订阅地址：https://$DOMAIN/$SUB_PATH"
echo "日志：tail -f $APP_DIR/run.log    停止：kill \$(cat $APP_DIR/app.pid)"
echo "----------------------------------------"
echo "请妥善保存 $APP_DIR/.env，里面含有 UUID 和路径。"
