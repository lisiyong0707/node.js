#!/usr/bin/env bash
# 面板托管 Node.js 应用的部署脚本（无需 root）
#
# 用法：
#   DOMAIN=你的域名 bash deploy-panel.sh
#
# 可选变量：
#   APP_URL    程序下载地址，默认指向 lisiyong0707/node.js 仓库的 app.js
#   APP_ROOT   应用目录，默认 ~/domains/$DOMAIN/public_html
#   UUID / WS_PATH / SUB_PATH / NAME   不填则随机生成并记住
#
# 本脚本做：激活 Node 环境 → 下载 app.js → 写 package.json → npm install → 生成并保存配置
# 之后只需在面板里 SAVE + RESTART，不用再填环境变量

set -euo pipefail

say() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
rand_hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

DOMAIN="${DOMAIN:-}"
[ -n "$DOMAIN" ] || die "请设置 DOMAIN，例如 DOMAIN=example.com"
APP_URL="${APP_URL:-https://raw.githubusercontent.com/lisiyong0707/node.js/main/app.js}"
APP_ROOT="${APP_ROOT:-$HOME/domains/$DOMAIN/public_html}"
[ -d "$APP_ROOT" ] || die "应用目录不存在：$APP_ROOT（可用 APP_ROOT=... 指定）"

# ---- 激活面板的 Node 环境 ----
REL_ROOT="${APP_ROOT#"$HOME"/}"   # 面板命令行工具要求相对主目录的路径
find_activate() {
  ls -d "$HOME"/nodevenv/domains/"$DOMAIN"/public_html/*/bin/activate 2>/dev/null | sort -V | tail -n1 || true
}
if ! command -v node >/dev/null 2>&1; then
  ACTIVATE="${ACTIVATE:-$(find_activate)}"
  if [ -z "$ACTIVATE" ] && command -v cloudlinux-selector >/dev/null 2>&1; then
    say "未找到应用，尝试用 cloudlinux-selector 创建（不一定可用）"
    cloudlinux-selector create --json --interpreter nodejs --app-root "$REL_ROOT" \
      --app-uri "" --version 20 --app-mode production --startup-file app.js 2>&1 | tail -n 5 || true
    ACTIVATE="$(find_activate)"
  fi
  [ -n "$ACTIVATE" ] && [ -f "$ACTIVATE" ] || die "找不到 Node 环境：请先在面板里创建 Node.js 应用，或用 ACTIVATE=/路径/bin/activate 指定"
  say "激活 Node 环境：$ACTIVATE"
  set +u
  # shellcheck disable=SC1090
  source "$ACTIVATE"
  set -u
fi
command -v node >/dev/null && command -v npm >/dev/null || die "仍然找不到 node/npm"
say "Node $(node -v)"

# ---- 凭据：优先沿用，放在 public_html 之外 ----
CRED="$HOME/.vless-panel.env"
if [ -f "$CRED" ]; then
  # shellcheck disable=SC1090
  . "$CRED"
fi
UUID="${UUID:-$(cat /proc/sys/kernel/random/uuid)}"
WS_PATH="/${WS_PATH:-ws-$(rand_hex 6)}"; WS_PATH="/${WS_PATH#/}"
SUB_PATH="${SUB_PATH:-$(rand_hex 12)}"
NAME="${NAME:-vless-node}"
( umask 077; cat > "$CRED" <<EOF
UUID="$UUID"
DOMAIN="$DOMAIN"
WS_PATH="$WS_PATH"
SUB_PATH="$SUB_PATH"
NAME="$NAME"
EOF
)
chmod 600 "$CRED"

# ---- 程序与依赖 ----
cd "$APP_ROOT"
say "下载 app.js"
if command -v wget >/dev/null; then wget -qO app.js "$APP_URL"
elif command -v curl >/dev/null; then curl -fsSL "$APP_URL" -o app.js
else die "需要 wget 或 curl"; fi
[ -s app.js ] || die "app.js 下载失败或为空"

cat > package.json <<'EOF'
{
  "name": "site",
  "version": "1.0.0",
  "main": "app.js",
  "dependencies": { "ws": "^8.14.2" }
}
EOF

say "安装依赖"
if ! UV_THREADPOOL_SIZE=1 NODE_OPTIONS=--max-old-space-size=256 \
     npm install --omit=dev --no-audit --no-fund --maxsockets=1 >/tmp/npm-install.log 2>&1; then
  tail -n 20 /tmp/npm-install.log
  die "npm install 失败（可能是资源限额或网络），可改用面板的 Run NPM Install 按钮"
fi
node -e "require('ws')" || die "ws 安装异常"

if [ -f index.html ] || [ -f index.php ]; then
  echo "[!] 目录里有 index.html/index.php，可能盖住程序页面，请自行确认是否删除"
fi

# 尝试自动重启（两种方式都不一定被你的主机支持，失败不影响后续）
mkdir -p tmp && touch tmp/restart.txt
RESTARTED=0
if command -v cloudlinux-selector >/dev/null 2>&1; then
  say "尝试用 cloudlinux-selector 重启应用"
  if cloudlinux-selector restart --json --interpreter nodejs --app-root "$REL_ROOT" >/tmp/cl-restart.log 2>&1 \
     && grep -q '"result": *"success"' /tmp/cl-restart.log; then
    RESTARTED=1
  fi
fi

# ---- 自检：看网站是不是已经是我们的程序 ----
sleep 3
CHECK="$(curl -s -m 10 "https://$DOMAIN/" 2>/dev/null | grep -c 'Field Notes' || true)"

cat <<EOF

========================================================
文件、依赖和配置都已就绪，配置保存在 $CRED（权限 600）。
程序会自己读取该文件，面板里不需要再填环境变量。

EOF
if [ "$CHECK" -ge 1 ]; then
  say "自检通过：https://$DOMAIN/ 已是新程序，无需再操作面板。"
else
  cat <<EOF
自检：网站暂时还不是新程序（可能还没重启或 DNS/CF 未生效）。
请到面板：Application mode 选 Production，Startup file 为 app.js，
点 SAVE，再点 RESTART，十几秒后访问下面的地址。
EOF
fi
cat <<EOF

订阅地址：https://$DOMAIN/$SUB_PATH
（如果之前在面板里手填过环境变量，它们优先于配置文件，建议删除。）
========================================================
EOF
