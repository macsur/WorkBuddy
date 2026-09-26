#!/usr/bin/env bash
# =============================================================================
#  WorkBuddy2API + WorkBuddy-Manager 一键部署脚本（分享版）
#
#  做什么：一条命令在自有服务器上跑起「WorkBuddy 账号池反向代理 + 管理面板」，
#          让各种 OpenAI 兼容客户端（Cherry Studio / NextChat / 各类 AI 工具）
#          用一个自己的 API Key 调用，账号由面板扫码纳管、自动轮换。
#
#  一键效果：
#    · 拉取预构建镜像起两个容器（网关 7863 + 面板 7864，均只绑 127.0.0.1）
#    · 生成随机 api_key 与管理密码，写入 <BASE_DIR>/.credentials（0600）
#    · 可选：给一个域名自动装 Caddy、签 Let's Encrypt 证书、开外网 HTTPS
#    · 幂等：重复执行安全，已有凭据不会被覆盖；改密码也只需重跑
#
#  前置要求：
#    · 一台 Linux 服务器（Debian 12 / Ubuntu 22+ 验证通过），root 执行
#    · 已装 Docker + compose 插件（没装可先 curl -fsSL https://get.docker.com | sh）
#    · 内存 ≥ 1GB（脚本只在服务器上跑容器、不在本机编译；906MB 小机器也验证过）
#    · 能访问 ghcr.io（拉镜像）与 github.com（拉代码）；网络受限时先配好代理
#
#  用法（在服务器上以 root 执行）：
#    bash deploy-workbuddy-share.sh                          # 交互向导（问域名 / 密码）
#    bash deploy-workbuddy-share.sh --domain wb.example.com --auto   # 全自动
#    bash deploy-workbuddy-share.sh --help                   # 查看全部参数
#
#  一条命令装完（推荐）：
#    curl -fsSL <脚本地址> | sudo bash -s -- --domain wb.example.com --auto
#      · 机器上没装 Docker 会自动装（官方脚本 / 幂等）
#      · 给了 --domain 且 DNS 已指向本机 → 自动装 Caddy、签 Let's Encrypt 证书、开外网 HTTPS
#      · 不给 --domain → 只绑本机；若是在交互终端里跑的，部署完成后还会问一句
#        「要现在绑定域名吗？」，当场填域名即可配好（不用重跑）
#      · 域名 DNS 没生效时，交互终端下会显示「该加哪条 A 记录」并等你按回车复检
#
#  命令行参数（等价于同名环境变量）：
#    -d, --domain <域名>        面板 / 对外域名（DNS 需先指向本机）
#        --api-domain <域名>    独立 API 域名（只暴露 /v1，不含面板）
#    -p, --password <密码>      面板管理员密码（≥8 位）
#    -a, --auto                 跳过交互向导，用参数 / 默认值直接开跑
#        --base-dir <目录>      安装根目录（默认 /opt/wb2api）
#
#  也可用环境变量（等价写法）：
#    NONINTERACTIVE=1 DOMAIN=wb.example.com bash deploy-workbuddy-share.sh
#
#  可用环境变量覆盖默认值：
#    WB2API_IMAGE    上游网关镜像  默认 ghcr.io/yys9253462-gif/workbuddy2api:latest
#    MANAGER_IMAGE   面板镜像      默认 ghcr.io/yys9253462-gif/workbuddy-manager-multiarch:latest
#    BASE_DIR        安装根目录    默认 /opt/wb2api
#    API_KEY         上游 api_key  默认随机生成
#    ADMIN_PASSWORD  面板初始密码  默认随机生成
#    DOMAIN          面板/对外域名（DNS 需已解析到本机）。设置后自动：
#                    装 Caddy → 配反代 → 自动签 Let's Encrypt 证书 → 开外网访问
#                    例：DOMAIN=wb.example.com
#    API_DOMAIN      可选：独立 API 域名，**只暴露 /v1**（不暴露面板）
#                    不设则 API 随 DOMAIN 一起暴露（/v1 路径）
#    SYNC_CODE=0     跳过代码同步（保留你在代码目录里的本地改动）
#    NONINTERACTIVE=1 跳过交互向导，全用默认值/环境变量
#
#  常见问题：
#    · 「拉取镜像失败 / denied / unauthorized」
#        默认镜像由脚本作者构建并公开托管在 GHCR。若提示无权限，说明镜像被改回了
#        私有：找作者要访问权限后 `docker login ghcr.io`，或自行构建镜像并把
#        WB2API_IMAGE / MANAGER_IMAGE 指过去。
#    · 「面板打不开」
#        面板只绑 127.0.0.1，这是设计如此。要么给 DOMAIN 走 HTTPS 正式开放，
#        要么用隧道临时访问：ssh -L 7864:127.0.0.1:7864 <你的服务器>
#    · 「证书签不下来」
#        域名必须已用 A 记录解析到本机，且云厂商安全组放行 80/443。
#    · 「内存不足 / 容器被 OOM kill」
#        两个容器已限制 256m / 320m；机器更小时先停掉无关服务再跑。
#
#  安全须知（务必读完）：
#    · 面板容器挂载了 docker.sock 且持有账号明文凭证，**等于这台机器的高权限入口**。
#      请只绑本机 + 走 HTTPS + 用强密码，不要把面板端口暴露到公网。
#    · 凭据文件 <BASE_DIR>/.credentials 权限 0600、root 可读，请自行妥善保管。
#    · 请遵守对应服务的使用条款，仅用于纳管你自己的账号，勿作违规用途。
#
#  上游与许可（本文件只是部署脚本，程序本体来自以下开源项目）：
#    · 网关 workbuddy2api     https://github.com/Sliverkiss/workbuddy2api   (MIT)
#    · 面板 workbuddy-manager https://github.com/ithtelab/workbuddy-manager (MIT)
#    本脚本可按 MIT 许可自由使用/修改/再分发，保留上方版权与许可声明即可。
# =============================================================================
set -euo pipefail

WB2API_IMAGE="${WB2API_IMAGE:-ghcr.io/yys9253462-gif/workbuddy2api:latest}"
MANAGER_IMAGE="${MANAGER_IMAGE:-ghcr.io/yys9253462-gif/workbuddy-manager-multiarch:latest}"
BASE_DIR="${BASE_DIR:-/opt/wb2api}"
UP_DIR="$BASE_DIR/workbuddy2api"
MG_DIR="$BASE_DIR/workbuddy-manager"
# 与上面两个镜像变量保持一致：允许环境变量覆盖（自建 fork / 私服 / 排障时有用）
REPO_UP="${REPO_UP:-https://github.com/yys9253462-gif/workbuddy2api.git}"
REPO_MG="${REPO_MG:-https://github.com/yys9253462-gif/workbuddy-manager.git}"
UP_UID=10001                      # 上游容器内 app 用户的 uid，卷属主必须一致

# 以下都可覆盖（便于在同一台机器上并行部署第二套做验证，或避开端口冲突）
WB2API_PORT="${WB2API_PORT:-7863}"     # 宿主侧网关端口（容器内固定 7863）
MANAGER_PORT="${MANAGER_PORT:-7864}"   # 宿主侧面板端口（容器内固定 7864）
UP_NAME="${UP_NAME:-workbuddy2api}"    # 网关容器名
MG_NAME="${MG_NAME:-workbuddy-manager}" # 面板容器名
NET_NAME="${NET_NAME:-wbnet}"          # 两容器共享的网络名
# compose 项目名：compose 按「目录名」识别项目，若两个实例的目录同名
# （如 /opt/wb2api 与 /opt/wb2api-verify 下的 workbuddy-manager），
# 对其中一个 down 会连另一个实例的容器一起删 —— 血的教训，必须显式唯一。
PROJ_UP="${PROJ_UP:-$(basename "$BASE_DIR")-up}"
PROJ_MG="${PROJ_MG:-$(basename "$BASE_DIR")-mgr}"
# 重跑时是否把代码目录同步到远端最新。
# 注意：开启会用 git reset --hard，**丢弃你对代码目录的所有本地修改**
# （config.json / auths/ / data/ 是非跟踪文件，不受影响）。
# 如果你改过上游代码（比如调过脚本参数），设 SYNC_CODE=0。
SYNC_CODE="${SYNC_CODE:-1}"
DOMAIN="${DOMAIN:-}"                 # 面板/对外域名（可选；DNS 需先指向本机）
API_DOMAIN="${API_DOMAIN:-}"         # 独立 API 域名（可选，只暴露 /v1）

# 注意 1：脚本开了 set -u，所有用到的颜色变量必须在这里定义全。
#   （上一版漏了 C_BOLD —— 部署明明成功，最后的汇总却报 unbound variable）
# 注意 2：必须用 $'...'（ANSI-C 引用）让变量里存真正的转义字符。
#   （若写成 "\033[32m"，cat <<EOF 打印时 \033 会原样输出成字面量，终端不渲染颜色）
# 输出被重定向到文件 / 跑在 CI 里时自动关色：否则 ANSI 转义会污染日志、也没法 grep。
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_D=$'\033[2m'; C_BOLD=$'\033[1m'; C_0=$'\033[0m'
else
  C_G=""; C_Y=""; C_R=""; C_D=""; C_BOLD=""; C_0=""
fi

T0="$(date +%s)"
STEP_NO=0
elapsed() { local s=$(( $(date +%s) - T0 )); printf '%dm%02ds' $(( s / 60 )) $(( s % 60 )); }

ok()   { printf "  ${C_G}✓${C_0} %s\n" "$*"; }
# 警告与错误走 stderr：stdout 重定向到日志时不至于把告警吞掉
warn() { printf "  ${C_Y}!${C_0} %s\n" "$*" >&2; }
die()  { printf "  ${C_R}✗ %s${C_0}\n" "$*" >&2; exit 1; }
step() { STEP_NO=$(( STEP_NO + 1 )); printf "\n${C_G}[%02d]${C_0} %s\n" "$STEP_NO" "$*"; }
# 注意 3：info() 必须定义！它被「装 Caddy / 重置密码 / 建 API 密钥」三处调用，
#   漏定义时 set -e 会让脚本以 127 中断（全新机器上装 Caddy 会当场失败）。
info() { printf "  ${C_D}·${C_0} %s\n" "$*"; }

# 生成 16 位强密码。原实现是 `openssl rand -base64 15 | tr -dc … | head -c16`：
#   tr 过滤后的长度是随机的（实测只剩 14 位），head 只截断、不会补足 → 长度无保障。
gen_password() {
  local pw="" chunk=""
  while [ "${#pw}" -lt 16 ]; do
    if command -v openssl >/dev/null 2>&1; then chunk="$(openssl rand -base64 32 2>/dev/null || true)"; fi
    [ -n "$chunk" ] || chunk="$(head -c 32 /dev/urandom | base64 2>/dev/null || true)"
    [ -n "$chunk" ] || return 1
    # 明确列出可用字符（剔除易混的 I/L/O/l/0/1），不用区间写法避免歧义（shellcheck SC2020）
    pw="${pw}$(printf '%s' "$chunk" | tr -dc 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789')"
  done
  printf '%s' "${pw:0:16}"
}

# 自定义密码的安全字符集：要能同时安全地写进 compose 的 YAML 双引号与 .credentials。
# 注意 `$` / 反引号 / 空格 其实**是安全的**（compose 侧是变量展开、不二次求值；
# .credentials 侧用 printf %q 写出），早年把它们一起禁掉属于过严 —— 详见下面函数里的说明。
password_is_safe() {
  [ -n "$1" ] || return 1
  # 只禁真正会出事的字符 —— 别再用过严的白名单把 `#` `$` `!` 这类常见密码字符误伤：
  #   · 不可见字符（换行 / 制表 / 控制符）
  #   · `"`  → 会提前结束 compose 里 `WB_ADMIN_PASSWORD: "…"` 的 YAML 双引号标量
  #   · `\` → YAML 双引号标量里的转义引导符
  # 其余可打印字符都安全：.credentials 侧由 printf %q 写出，compose 侧是变量展开不二次求值。
  case "$1" in
    *[![:print:]]*) return 1 ;;
    *\"*)          return 1 ;;
    *\\*)         return 1 ;;
  esac
  return 0
}

# ---------------------------------------------------------------- 0.3) 命令行参数
# 支持「一条命令装完」（配合 --auto 不问任何问题）：
#   curl -fsSL <脚本地址> | bash -s -- --domain wb.example.com --auto
# 不带参数时行为不变：交互终端走向导，管道/CI 走环境变量默认值。
usage() {
  cat <<'USAGE'
用法: bash deploy-workbuddy.sh [选项]

选项（等价于同名环境变量；都不给时走交互向导）：
  -d, --domain <域名>       面板/对外域名，如 wb.example.com（DNS 需已指向本机）
      --api-domain <域名>   独立 API 域名（只暴露 /v1，不含面板）
  -p, --password <密码>     面板管理员密码（≥8 位；不能含双引号 " 或反斜杠 \)
  -a, --auto                全自动：跳过交互向导与域名/DNS 等待，用参数/默认值直接开跑
      --base-dir <目录>     安装根目录（默认 /opt/wb2api）
  -h, --help                显示本帮助并退出

示例：
  bash deploy-workbuddy.sh                                  # 交互式
  bash deploy-workbuddy.sh --domain wb.example.com --auto    # 全自动开外网 HTTPS
  curl -fsSL <脚本地址> | bash -s -- --auto                  # 仅本机访问（不配域名）
USAGE
}
while [ $# -gt 0 ]; do
  case "$1" in
    -d|--domain)        DOMAIN="${2:-}";         [ -n "$DOMAIN" ]         || die "--domain 需要跟一个域名"; shift 2 ;;
    --api-domain)       API_DOMAIN="${2:-}";     [ -n "$API_DOMAIN" ]     || die "--api-domain 需要跟一个域名"; shift 2 ;;
    -p|--password)      ADMIN_PASSWORD="${2:-}"; [ -n "$ADMIN_PASSWORD" ] || die "--password 需要跟一个密码"; shift 2 ;;
    -a|--auto|-y|--yes) NONINTERACTIVE=1; shift ;;
    --base-dir)         BASE_DIR="${2:-}";       [ -n "$BASE_DIR" ]       || die "--base-dir 需要跟一个目录"; shift 2 ;;
    -h|--help)          usage; exit 0 ;;
    *) die "未知参数：$1（用 --help 查看支持的选项）" ;;
  esac
done
# 参数可能在 BASE_DIR 赋值之后才生效，这里按最终值重算派生路径
UP_DIR="$BASE_DIR/workbuddy2api"
MG_DIR="$BASE_DIR/workbuddy-manager"
PROJ_UP="$(basename "$BASE_DIR")-up"
PROJ_MG="$(basename "$BASE_DIR")-mgr"
CRED_FILE="$BASE_DIR/.credentials"

[[ $EUID -eq 0 ]] || die "请用 root 运行（需要 docker 与写 /opt 的权限）"

# 本脚本的自动安装全部基于 apt（Debian / Ubuntu 系）。CentOS / Alma / Rocky / 宝塔面板
# 等系统没有 apt —— 与其后面报一堆 command not found，不如在这里一次说清楚。
if ! command -v apt-get >/dev/null 2>&1; then
  die "未检测到 apt-get：本脚本目前只支持 Debian / Ubuntu 系发行版（当前系统请改用手动安装）"
fi

# ---------------------------------------------------------------- 0.5) 交互式向导
# 只在「交互终端」时提问（ssh 登录后手敲运行）；管道 / CI / 定时任务里自动跳过，
# 全部使用环境变量默认值 —— 两种用法互不影响。
# 非交互要强制跳过提问：NONINTERACTIVE=1 bash deploy-workbuddy.sh
ask() { # $1=提示  $2=默认值；结果写入全局变量 REPLY_ASK
  local p="$1" d="${2:-}" r=""
  printf "  %s" "$p"
  [ -n "$d" ] && printf " ${C_D}[%s]${C_0}" "$d"
  printf "："
  if ! read -r r; then r="$d"; fi     # EOF（非交互）时回落到默认值
  r="${r%$'\r'}"                     # 防粘贴带 \r（Windows CRLF / 管道经 pty）
  REPLY_ASK="${r:-$d}"
}

# 检测系统是否已安装并运行 Nginx（原生 Nginx 或科技Lion Docker 版 Nginx）
HAS_NGINX=0
NGINX_CONF_DIR=""
NGINX_TEST_CMD=""
NGINX_RELOAD_CMD=""

if docker ps --format '{{.Names}}' 2>/dev/null | grep -qE '^nginx$'; then
  HAS_NGINX=1
  NGINX_CONF_DIR="/home/web/conf.d"
  [ -d "$NGINX_CONF_DIR" ] || NGINX_CONF_DIR="/etc/nginx/conf.d"
  NGINX_TEST_CMD="docker exec nginx nginx -t"
  NGINX_RELOAD_CMD="docker exec nginx nginx -s reload"
elif command -v nginx >/dev/null 2>&1 && (systemctl is-active nginx >/dev/null 2>&1 || ss -tlnp 2>/dev/null | grep -qE ':(80|443) .*nginx'); then
  HAS_NGINX=1
  NGINX_CONF_DIR="/etc/nginx/conf.d"
  [ -d "$NGINX_CONF_DIR" ] || NGINX_CONF_DIR="/home/web/conf.d"
  NGINX_TEST_CMD="nginx -t"
  NGINX_RELOAD_CMD="systemctl reload nginx || nginx -s reload"
elif ss -tlnp 2>/dev/null | grep -qE ':(80|443) '; then
  HAS_NGINX=1
  NGINX_CONF_DIR="/home/web/conf.d"
  [ -d "$NGINX_CONF_DIR" ] || NGINX_CONF_DIR="/etc/nginx/conf.d"
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qE 'nginx'; then
    NGINX_TEST_CMD="docker exec nginx nginx -t"
    NGINX_RELOAD_CMD="docker exec nginx nginx -s reload"
  else
    NGINX_TEST_CMD="nginx -t"
    NGINX_RELOAD_CMD="systemctl reload nginx || nginx -s reload"
  fi
fi

CRED_FILE="$BASE_DIR/.credentials"
if [ -t 0 ] && [ "${NONINTERACTIVE:-0}" != "1" ]; then
  step "部署配置向导"
  echo "  直接回车 = 用方括号里的默认值；Ctrl+C 取消部署"
  echo

  # --- 域名（已在环境变量里指定则不再问）---
  if [ -z "$DOMAIN" ]; then
    def_dom=""
    # 优先从已有的 Nginx（如科技Lion /home/web/conf.d 或 /etc/nginx/conf.d）提取默认域名
    if [ "$HAS_NGINX" = "1" ] && [ -n "$NGINX_CONF_DIR" ] && [ -d "$NGINX_CONF_DIR" ]; then
      for f in "$NGINX_CONF_DIR"/*.conf; do
        [ -f "$f" ] && [ "$(basename "$f")" != "map.conf" ] && def_dom="$(basename "$f" .conf)" && break
      done
    fi
    if [ -z "$def_dom" ]; then
      for f in /etc/caddy/conf.d/*.caddy; do
        [ -f "$f" ] && def_dom="$(basename "$f" .caddy)" && break   # conf.d 站点默认带出
      done
    fi
    # 主 Caddyfile 里手工配过的站点也认（否则手动配的域名不会出现在默认值里）
    if [ -z "$def_dom" ] && [ -f /etc/caddy/Caddyfile ]; then
      # 用 { … || true; } 兜住：grep 无匹配时退出码非 0，set -o pipefail 会让整个赋值失败
      def_dom=$( { grep -hoE '^[a-zA-Z0-9.-]+[[:space:]]+\{' /etc/caddy/Caddyfile 2>/dev/null || true; } | head -1 | awk '{print $1}')
    fi
    if [ "$HAS_NGINX" = "1" ]; then
      echo "  ${C_BOLD}域名${C_0}：检测到已运行 Nginx（科技Lion 环境），配置域名将自动生成 Nginx 反代配置，"
      echo "  不占用额外端口，直连 127.0.0.1:${MANAGER_PORT}。证书可通过科技Lion一键申请。"
    else
      echo "  ${C_BOLD}域名${C_0}：配了就能直接浏览器访问面板（自动 HTTPS 证书），"
      echo "  对外 API 也走同一域名（/v1）。前提：域名需已解析到本机 IP。"
    fi
    ask "  面板域名（留空 = 仅本机访问，之后也能再加）" "$def_dom"
    DOMAIN="$REPLY_ASK"
    if [ -n "$DOMAIN" ]; then
      ask "  独立 API 域名（可选，只暴露 /v1、不含面板；留空 = 与面板同域）" "$API_DOMAIN"
      API_DOMAIN="$REPLY_ASK"
    fi
    echo
  fi

  # --- 管理员密码 ---
  echo "  ${C_BOLD}管理员密码${C_0}"
  if [ -f "$CRED_FILE" ]; then
    echo "  已有密码保存在 $CRED_FILE"
    ask "  直接回车 = 沿用现有密码；输入新密码（≥8 位）= 重置面板密码" ""
    if [ -n "$REPLY_ASK" ]; then
      if [ ${#REPLY_ASK} -lt 8 ]; then
        warn "少于 8 位，沿用现有密码"
      elif ! password_is_safe "$REPLY_ASK"; then
        warn "含不安全字符（不能有双引号 \"、反斜杠 \\ 或不可见字符），沿用现有密码"
      else
        ADMIN_PASSWORD="$REPLY_ASK"
        PASSWD_RESET=1
        ok "部署完成后将重置面板管理员密码（所有已登录会话失效）"
      fi
    fi
  else
    ask "  管理员密码（直接回车 = 自动生成强密码；或输入 ≥8 位自定义）" ""
    if [ -z "$REPLY_ASK" ]; then
      ok "将自动生成强密码"
    elif [ ${#REPLY_ASK} -lt 8 ]; then
      warn "少于 8 位，改用自动生成"
    elif ! password_is_safe "$REPLY_ASK"; then
      warn "含不安全字符（不能有双引号 \"、反斜杠 \\ 或不可见字符），改用自动生成"
    else
      ADMIN_PASSWORD="$REPLY_ASK"
      ok "使用自定义密码"
    fi
  fi
  echo
fi


# ---------------------------------------------------------------- 0) 预检
step "环境预检"
# 一键部署全程约 1~5 分钟（裸机装 Docker 会更久）。SSH 断线会中断脚本 ——
# 脚本是幂等的，断了重跑即可，但会白等一遍，所以先提醒一句。
info "提示：全程约 1~5 分钟；建议在 tmux/screen 里执行，避免 SSH 断线中断（断了可直接重跑）"
# 缺哪个补哪个，且只做一次 apt-get update（小机器上 update 很慢，别重复跑）。
# curl / ca-certificates 要带上：下一步自动装 Docker 需要它们。
MISSING=""
for tool in git python3 openssl curl; do
  command -v "$tool" >/dev/null 2>&1 || MISSING="$MISSING $tool"
done
if [ -n "$MISSING" ]; then
  info "缺少依赖：$MISSING —— 正在 apt 安装（首次可能要 1-2 分钟）…"
  apt-get update -qq >/dev/null 2>&1 || warn "apt-get update 失败（软件源不可用？仍尝试直接安装）"
  # shellcheck disable=SC2086
  apt-get install -y -qq $MISSING ca-certificates >/dev/null 2>&1 || true
fi
# git / python3 是硬依赖（脚本必须用到）；openssl 缺失会自动退回 /dev/urandom
for tool in git python3; do
  command -v "$tool" >/dev/null 2>&1 || die "缺少 $tool 且自动安装失败，请手动安装后重跑"
done

# Docker / compose：缺失时自动安装（官方脚本，幂等）—— 让「裸机」也能一条命令跑完
if ! command -v docker >/dev/null 2>&1; then
  info "未检测到 Docker —— 用官方脚本安装（get.docker.com，约 1~2 分钟）…"
  if curl -fsSL https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null && sh /tmp/get-docker.sh >/dev/null 2>&1; then
    rm -f /tmp/get-docker.sh
    ok "Docker 安装脚本执行完成"
  else
    rm -f /tmp/get-docker.sh
    warn "Docker 官方安装脚本执行失败（网络不通 get.docker.com？）"
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
  sleep 2
fi
command -v docker >/dev/null 2>&1 || die "Docker 未安装成功。可手动执行：curl -fsSL https://get.docker.com | sh"
if ! docker compose version >/dev/null 2>&1; then
  info "缺少 docker compose 插件 —— 尝试 apt 安装 docker-compose-plugin…"
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1 || true
fi
docker compose version >/dev/null 2>&1 || die "缺少 docker compose 插件。可手动执行：apt-get install -y docker-compose-plugin"
ok "docker $(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) · compose $(docker compose version --short) · git $(git --version | awk '{print $3}') · $(python3 -V 2>&1)"

AVAIL=$(free -m | awk 'NR==2{print $7}')
[ -n "$AVAIL" ] || AVAIL=0
ok "可用内存 ${AVAIL}MB（网关+面板预计 150-250MB）"
if [ "$AVAIL" -lt 250 ]; then warn "可用内存偏少，建议先停掉不用的服务"; fi
# 磁盘也要看一眼：两个镜像解压后约 1.5GB，加数据/日志，建议留 3GB 以上（原来只查内存）
AVAIL_GB=$(df -Pk / 2>/dev/null | awk 'NR==2{printf "%d", $4/1048576}')
[ -n "$AVAIL_GB" ] || AVAIL_GB=0
if [ "$AVAIL_GB" -lt 3 ]; then
  die "根分区可用空间仅 ${AVAIL_GB}GB（镜像+数据约需 3~5GB），请先清理磁盘再重试"
fi
ok "根分区可用 ${AVAIL_GB}GB（镜像+数据约需 3~5GB）"

# 面板与网关必须同网 —— 面板容器经 host.docker.internal 访问时，
# 走的是网桥 IP（172.17.0.1），而网关只绑 127.0.0.1，必然连接失败
# （面板仪表盘报 ConnectError: All connection attempts failed）。
docker network inspect "$NET_NAME" >/dev/null 2>&1 || docker network create "$NET_NAME" >/dev/null
ok "共享网络 $NET_NAME 就绪"

for p in "$WB2API_PORT" "$MANAGER_PORT"; do
  if ss -tlnp 2>/dev/null | grep -q ":$p "; then
    # 端口被占时先看是不是我们自己上一次部署的容器 —— 是就视为「已部署」，跳过检查
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qxE "${UP_NAME}|${MG_NAME}"; then
      ok "端口 $p 已由本脚本部署的服务占用（视为已部署，继续）"
    else
      die "端口 $p 已被其它进程占用"
    fi
  else
    ok "端口 $p 空闲"
  fi
done

if [ "$HAS_NGINX" = "1" ]; then
  ok "检测到系统已安装运行 Nginx（科技Lion 环境已占用 80/443），后续外网反代将对接 Nginx，自动跳过 Caddy 避免端口冲突"
fi

# ---------------------------------------------------------------- 1) 凭据
step "生成/读取凭据"
CRED_FILE="$BASE_DIR/.credentials"
mkdir -p "$BASE_DIR"
# 先给「本次显式指定的密码」（向导输入 / 环境变量）留底：
# 下面 `source $CRED_FILE` 会把它覆盖成旧值 —— 不盖回去的话，「重置密码」全程空转，
# compose 里写进的仍是旧密码，用户看到的是「改了但没生效」。
EXPLICIT_ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
CRED_DIRTY=0
if [ -f "$CRED_FILE" ]; then
  # shellcheck disable=SC1090
  source "$CRED_FILE"
  # 兜底：凭据文件被手改/写坏而缺键时，set -u 会让后面直接 unbound 中断（报错还很难懂）。
  API_KEY="${API_KEY:-}"
  ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
  if [ -z "$API_KEY" ]; then
    API_KEY="$(openssl rand -hex 24 2>/dev/null || head -c48 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    warn "凭据文件里缺少 api_key —— 已重新生成（面板与网关会同步使用新值）"
    CRED_DIRTY=1
  fi
  if [ -z "$ADMIN_PASSWORD" ]; then
    ADMIN_PASSWORD="$(gen_password)"
    PASSWD_RESET=1
    warn "凭据文件里缺少管理密码 —— 已重新生成，部署末尾重建面板后生效"
    CRED_DIRTY=1
  fi
  RUN_MODE="增量更新"
  ok "沿用已保存的 api_key / 管理密码（$CRED_FILE）"
  if [ -n "$EXPLICIT_ADMIN_PASSWORD" ] && [ "$EXPLICIT_ADMIN_PASSWORD" != "$ADMIN_PASSWORD" ]; then
    ADMIN_PASSWORD="$EXPLICIT_ADMIN_PASSWORD"
    PASSWD_RESET=1
    ok "已采用本次指定的新密码（部署末尾重建面板后生效）"
  fi
else
  RUN_MODE="首次部署"
  # 尊重向导/环境变量预设的值；没预设才自动生成
  API_KEY="${API_KEY:-$(openssl rand -hex 24 2>/dev/null || head -c48 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
  ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(gen_password)}"
  if [ -z "$API_KEY" ] || [ -z "$ADMIN_PASSWORD" ]; then die "随机数生成失败"; fi
  # 凭据文件不存在，但机器上已有部署产物 —— 说明是「凭据丢了」而不是全新安装。
  # 这时必须把新凭据同步到两处，否则会出现「脚本说部署完成、实际两把钥匙都对不上」：
  #   · 网关 config.json 里还是旧 api_key（新 key 调网关会 401）
  #   · 面板 users.json 已存在 → 不会重新读取新的管理密码（新密码登录 401）
  if [ -f "$MG_DIR/data/users.json" ] || [ -f "$UP_DIR/config.json" ]; then
    CRED_LOST=1
    PASSWD_RESET=1
    RUN_MODE="凭据已重建"
    warn "检测到已有部署产物但凭据文件丢失：已重新生成 api_key 与管理员密码，"
    warn "  稍后会把它们同步进网关 config.json 与面板（原密钥/密码将失效）"
  fi
  umask 077
  # %q：写成 shell 可安全 source 的形式 —— 值里含特殊字符也不会破坏凭据文件
  { printf 'API_KEY=%q\n' "$API_KEY"; printf 'ADMIN_PASSWORD=%q\n' "$ADMIN_PASSWORD"; } > "$CRED_FILE"
  umask 022
  FIRST_RUN_NOTE="    · 这是首次部署：请立刻把上面的管理密码与 api_key 存进密码管理器。"
  ok "已生成并保存到 $CRED_FILE（0600，请妥善保管）"
fi

# ---------------------------------------------------------------- 1.5) 管理员密码策略兜底
# 密码要同时安全地写进两处：compose 的 `WB_ADMIN_PASSWORD: "..."`（YAML 双引号）
# 与 .credentials。所以策略是「≥8 位 + 禁掉会破坏它们的字符」。
# 早年只在交互向导里校验，`--password` / ADMIN_PASSWORD / 已有凭据这三条路径全绕过 ——
# 实测：`--password abc` 被静默接受；`--password 'ab"cd'` 生成的 compose 变成
#   WB_ADMIN_PASSWORD: "ab"cd"
# 被 go-yaml 判 `did not find expected key`，面板直接起不来，而报错完全看不出是密码问题。
if [ "${#ADMIN_PASSWORD}" -lt 8 ] || ! password_is_safe "$ADMIN_PASSWORD"; then
  PW_NOTE="含不安全字符（不能有双引号、反斜杠或不可见字符）"
  [ "${#ADMIN_PASSWORD}" -lt 8 ] && PW_NOTE="少于 8 位（当前 ${#ADMIN_PASSWORD} 位）"
  if [ -n "$EXPLICIT_ADMIN_PASSWORD" ]; then
    die "管理员密码${PW_NOTE}。面板容器挂载了 docker.sock，弱密码等于敞开高权限入口；且特殊字符会写坏 compose 的 YAML。请换一个密码后重试。"
  else
    warn "凭据文件里的管理密码${PW_NOTE} —— 继续使用，但建议尽快改掉："
    warn "  重跑时加 -p '新密码'（≥8 位、且不含双引号 / 反斜杠）即可重置。"
  fi
fi

# 上面若自动补齐过缺失项，落盘一次，避免下次又按"缺失"处理
if [ "$CRED_DIRTY" = "1" ]; then
  umask 077
  { printf 'API_KEY=%q\n' "$API_KEY"; printf 'ADMIN_PASSWORD=%q\n' "$ADMIN_PASSWORD"; } > "$CRED_FILE"
  if [ -n "${MANAGER_API_KEY:-}" ]; then printf 'MANAGER_API_KEY=%q\n' "$MANAGER_API_KEY" >> "$CRED_FILE"; fi
  umask 022
  ok "凭据文件已补齐缺失项（$CRED_FILE）"
fi

# 把 git clone 的失败原话翻译成人话。
# 最典型的是 "could not read Username for 'https://github.com'" —— 它其实是
# 「仓库不存在 / 私有仓库且无凭据」，但字面看起来像密码问题，新手 100% 会误解。
explain_clone_err() {
  local out="$1"
  case "$out" in
    *"could not read Username"*|*"Authentication failed"*|*"Repository not found"*|*"repository"*"not found"*)
      warn "  ↳ 上面这句通常表示【仓库不存在，或它是私有仓库、而本机没有访问凭据】；" ;;
    *"Could not resolve host"*|*"Connection timed out"*|*"Failed to connect"*|*"Network is unreachable"*|*"Could not resolve"*)
      warn "  ↳ 连不上 GitHub —— 检查本机 DNS / 出网 / 代理设置；" ;;
    *"already exists and is not an empty directory"*)
      warn "  ↳ 目标目录非空 —— 删掉它，或用 --base-dir 换一个安装位置；" ;;
    *)
      warn "  ↳ 以上为 git 原话，可据此搜索；" ;;
  esac
}

# ---------------------------------------------------------------- 2) 上游 workbuddy2api
step "安装上游 workbuddy2api"
if [ -d "$UP_DIR/.git" ]; then
  if [ "$SYNC_CODE" = "1" ]; then
    if git -C "$UP_DIR" fetch --depth 1 origin master >/dev/null 2>&1 \
       && git -C "$UP_DIR" reset --hard origin/master >/dev/null 2>&1; then
      ok "已同步到远端 master（不动 config.json / auths/ / data/）"
    else
      # 以前是 `|| true`：网络不通时静默沿用旧代码，用户以为已经是新版
      warn "上游代码同步失败（网络或仓库异常）—— 本次沿用本地既有代码继续部署"
    fi
  else
    ok "已存在，SYNC_CODE=0 —— 跳过代码同步，保留你的本地修改"
  fi
else
  # 上次中断运行可能留下一个「非 git 的残目录」，git clone 会因此失败；
  # 这里先识别并清掉，避免新手看到一句莫名其妙的 "already exists"。
  if [ -e "$UP_DIR" ] && [ ! -d "$UP_DIR/.git" ]; then
    warn "目标目录 $UP_DIR 已存在但不是 git 仓库（多为上次中断残留）—— 已移除后重新克隆"
    rm -rf "$UP_DIR"
  fi
  # 真实错误必须让用户看见：以前是 >/dev/null 2>&1，网络/权限问题全被吞掉
  CLONE_OUT="$(git clone --depth 1 -b master "$REPO_UP" "$UP_DIR" 2>&1)" || {
    if [ -n "$CLONE_OUT" ]; then printf '%s\n' "$CLONE_OUT" | sed 's/^/     /'; fi
    explain_clone_err "$CLONE_OUT"
    die "克隆上游仓库失败：$REPO_UP"
  }
  ok "已克隆 $REPO_UP"
fi

if [ ! -f "$UP_DIR/config.json" ]; then
  # 以仓库示例为底，只改 api_key 与监听地址（其余保持项目默认值）
  python3 - "$UP_DIR" "$API_KEY" <<'PY'
import json, sys
up, key = sys.argv[1], sys.argv[2]
with open(f"{up}/config.example.json", encoding="utf-8") as f:
    cfg = json.load(f)
cfg["api_key"] = key
cfg["listen"] = "0.0.0.0:7863"          # 容器内监听；宿主侧只绑 127.0.0.1
with open(f"{up}/config.json", "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  ok "生成 config.json（api_key 已设置）"
else
  # config.json 已存在 —— 核对它的 api_key 与本脚本用的是否一致。
  # 不一致有两种来源：① 凭据文件丢过（CRED_LOST=1，必须自动对齐）② 人为改过其中一边（只警告）
  CFG_KEY="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1],encoding='utf-8')).get('api_key',''))" "$UP_DIR/config.json" 2>/dev/null || echo "")"
  if [ "$CFG_KEY" = "$API_KEY" ]; then
    ok "config.json 已存在，api_key 一致"
  elif [ "${CRED_LOST:-0}" = "1" ]; then
    python3 - "$UP_DIR/config.json" "$API_KEY" <<'PY'
import json, sys
p, key = sys.argv[1], sys.argv[2]
cfg = json.load(open(p, encoding='utf-8'))
cfg['api_key'] = key
json.dump(cfg, open(p, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PY
    ok "config.json 已存在但 api_key 是旧的 —— 已同步为最新值"
  else
    warn "config.json 的 api_key 与 $CRED_FILE 不一致（配置 ${CFG_KEY:0:8}… / 凭据 ${API_KEY:0:8}…）"
    warn "  · 想保留 config.json 的值 → 把凭据文件里的 API_KEY 改成同一把"
    warn "  · 想让两边自动对齐   → 删掉 config.json 后重跑本脚本"
  fi
fi

mkdir -p "$UP_DIR/auths" "$UP_DIR/data"
cat > "$UP_DIR/docker-compose.yml" <<YAML
# 由本部署脚本生成 —— 用预构建镜像，不在本机编译（小内存机器会 OOM）
name: ${PROJ_UP}
services:
  wb2api:
    image: ${WB2API_IMAGE}
    container_name: ${UP_NAME}
    restart: unless-stopped
    mem_limit: 256m
    # 日志上限：json-file 默认不轮转，长期跑会慢慢把根分区写满（gcp 上踩过一次）
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    environment:
      - TZ=Asia/Shanghai
    ports:
      - "127.0.0.1:${WB2API_PORT}:7863"   # 只绑本机，面板/反代经宿主机访问
    volumes:
      - ./auths:/app/auths
      - ./data:/app/data
      - ./config.json:/app/config.json:ro
networks:
  default:
    name: ${NET_NAME}
    external: true
YAML
ok "生成上游 docker-compose.yml（image 拉取 + mem_limit 256m）"

# ---------------------------------------------------------------- 3) 面板 workbuddy-manager
step "安装面板 workbuddy-manager"
if [ -d "$MG_DIR/.git" ]; then
  if [ "$SYNC_CODE" = "1" ]; then
    if git -C "$MG_DIR" fetch --depth 1 origin main >/dev/null 2>&1 \
       && git -C "$MG_DIR" reset --hard origin/main >/dev/null 2>&1; then
      ok "已同步到远端 main（不动 data/）"
    else
      warn "面板代码同步失败（网络或仓库异常）—— 本次沿用本地既有代码继续部署"
    fi
  else
    ok "已存在，SYNC_CODE=0 —— 跳过代码同步，保留你的本地修改"
  fi
else
  if [ -e "$MG_DIR" ] && [ ! -d "$MG_DIR/.git" ]; then
    warn "目标目录 $MG_DIR 已存在但不是 git 仓库（多为上次中断残留）—— 已移除后重新克隆"
    rm -rf "$MG_DIR"
  fi
  CLONE_OUT="$(git clone --depth 1 -b main "$REPO_MG" "$MG_DIR" 2>&1)" || {
    if [ -n "$CLONE_OUT" ]; then printf '%s\n' "$CLONE_OUT" | sed 's/^/     /'; fi
    explain_clone_err "$CLONE_OUT"
    die "克隆面板仓库失败：$REPO_MG"
  }
  ok "已克隆 $REPO_MG"
fi
mkdir -p "$MG_DIR/data"

cat > "$MG_DIR/docker-compose.yml" <<YAML
# 由本部署脚本生成 —— 用预构建镜像，不在本机编译
name: ${PROJ_MG}
services:
  workbuddy-manager:
    image: ${MANAGER_IMAGE}
    container_name: ${MG_NAME}
    restart: unless-stopped
    mem_limit: 320m
    # 日志上限：面板会记录每一次 API 调用，没有上限就是慢性磁盘炸弹
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    environment:
      TZ: Asia/Shanghai
      WB_ADMIN_PASSWORD: "${ADMIN_PASSWORD}"
      WB2API_BASE: http://${UP_NAME}:7863
      WB2API_KEY: "${API_KEY}"
      WB2API_MODE: docker
      WB2API_CONTAINER: ${UP_NAME}
      WB_AUTH_DIR: /opt/workbuddy2api/auths
      WB_UPSTREAM_CONFIG: /opt/workbuddy2api/config.json
      WB_DATA_DIR: /app/data
      WB_SECURE_COOKIE: auto
      WB_TRUST_PROXY: "1"
      WB_ENABLE_DOCS: "0"
    ports:
      - "127.0.0.1:${MANAGER_PORT}:7864"   # 管理端必须藏在反代之后
    volumes:
      - ./data:/app/data
      - ../workbuddy2api:/opt/workbuddy2api
      - /var/run/docker.sock:/var/run/docker.sock
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:7864/api/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s

# networks 必须在顶层（不是 service 的子键）—— 上次的教训：嵌进 service 会报
# "additional properties 'external', 'name' not allowed"
networks:
  default:
    name: ${NET_NAME}
    external: true
YAML
ok "生成面板 docker-compose.yml（挂上游目录 + docker.sock）"

# ---------------------------------------------------------------- 4) 属主与拉取
step "修正卷属主（容器内 app=10001）"
chown -R ${UP_UID}:${UP_UID} "$UP_DIR/auths" "$UP_DIR/data" "$MG_DIR/data"
ok "auths/ data/ 已交给 uid 10001"

step "拉取镜像"
# 预检默认镜像是否可匿名获取：若作者把包设回了私有，这里先给人话提示，
# 而不是让用户在 docker 的一长串报错里猜。（预检失败不中断，由下面真正的 pull 决定）
probe_image() {
  local img="$1" err=""
  if ! docker manifest --help >/dev/null 2>&1; then return 0; fi   # 老版 CLI 无此子命令
  if err="$(docker manifest inspect "$img" 2>&1 >/dev/null)"; then return 0; fi
  case "$err" in
    *denied*|*unauthorized*|*"401"*|*"403"*|*"not found"*)
      warn "镜像 $img 无法匿名获取（可能已被设为私有）—— 处理方式见脚本头部「常见问题」" ;;
    *) warn "镜像 $img 预检未通过：$(printf '%s' "$err" | head -1)" ;;
  esac
  return 0
}
probe_image "$WB2API_IMAGE"
probe_image "$MANAGER_IMAGE"

# 失败时把 docker 的真实报错尾部打出来：只写"拉取失败"会让排错全靠猜
pull_image() {
  local img="$1" out=""
  if out="$(docker pull "$img" 2>&1)"; then return 0; fi
  printf '%s\n' "$out" | tail -n 6 | sed 's/^/      /' >&2
  return 1
}
# 离线/内网场景：镜像已用 `docker load` 导入时跳过联网拉取（配合「离线兜底包」使用）。
# 注意这里要主动校验本地确实有这两个镜像 —— 否则会一路跑到 compose up 才报难懂的错。
if [ "${SKIP_PULL:-0}" = "1" ]; then
  for _img in "$WB2API_IMAGE" "$MANAGER_IMAGE"; do
    docker image inspect "$_img" >/dev/null 2>&1 \
      || die "SKIP_PULL=1 但本地没有镜像 $_img —— 请先执行 docker load -i images.tar"
  done
  ok "SKIP_PULL=1：跳过拉取，使用本地已有镜像"
else
  pull_image "$WB2API_IMAGE" || die "拉取 $WB2API_IMAGE 失败（GHCR 包可能是私有的：去 GitHub 包页面改成 Public，或先 docker login ghcr.io）"
  pull_image "$MANAGER_IMAGE" || die "拉取 $MANAGER_IMAGE 失败（同上）"
  ok "两个镜像就绪"
fi

# ---------------------------------------------------------------- 5) 启动
step "启动服务"
if ! UP_OUT="$(docker compose -f "$UP_DIR/docker-compose.yml" up -d 2>&1)"; then
  printf '%s\n' "$UP_OUT" | tail -n 8 | sed 's/^/      /' >&2
  die "上游启动失败（上方为 docker compose 的真实报错）"
fi
ok "workbuddy2api 已启动"
# 凭据丢失重生成时，config.json 里的 api_key 刚被改写 —— 挂载的文件变了但容器不会自动重载，
# 必须重启一次，否则网关仍按内存里的旧 key 鉴权（新 key 一律 401）。
if [ "${CRED_LOST:-0}" = "1" ]; then
  info "config.json 的 api_key 已更新 —— 重启网关使其生效"
  docker restart "$UP_NAME" >/dev/null 2>&1 || true
fi
if ! MG_OUT="$(docker compose -f "$MG_DIR/docker-compose.yml" up -d 2>&1)"; then
  printf '%s\n' "$MG_OUT" | tail -n 8 | sed 's/^/      /' >&2
  die "面板启动失败（上方为 docker compose 的真实报错）"
fi
ok "workbuddy-manager 已启动"

# 密码变更落地：面板只在首启（users.json 不存在）时读取 WB_ADMIN_PASSWORD，
# 已部署实例改密码必须删 users.json 重建（所有已登录会话失效）。
if [ "${PASSWD_RESET:-0}" = "1" ]; then
  info "应用新密码：重置面板管理员…"
  docker rm -f "$MG_NAME" >/dev/null 2>&1 || true
  rm -f "$MG_DIR/data/users.json"
  docker compose -f "$MG_DIR/docker-compose.yml" up -d >/dev/null 2>&1 || die "面板重建失败"
  # 凭据文件同步（密码可能含特殊字符，用 python 改避免 sed 分隔符冲突）
  python3 - "$CRED_FILE" "$ADMIN_PASSWORD" <<'PY'
import sys, shlex
p, pw = sys.argv[1], sys.argv[2]
# shlex.quote：与写入时的 printf %q 同源，保证下次 source 能还原出原值
out = [f"ADMIN_PASSWORD={shlex.quote(pw)}" if l.startswith("ADMIN_PASSWORD=") else l
       for l in open(p).read().split("\n")]
open(p, "w").write("\n".join(out))
PY
  ok "面板管理员密码已更新（凭据文件已同步）"
fi

# ---------------------------------------------------------------- 6) 健康检查
step "健康检查（最长等 60 秒）"
# 先 5 次 2 秒快探（正常情况 1 秒内就绪），没起来再退避到 5 秒 —— 别让小机器白等
wait_http() {
  local url="$1" i body=""
  for i in 1 2 3 4 5; do
    body="$(curl -sS --max-time 5 "$url" 2>/dev/null || true)"
    [ -n "$body" ] && break
    sleep 2
  done
  while [ -z "$body" ] && [ "$i" -le 10 ]; do
    sleep 5
    body="$(curl -sS --max-time 5 "$url" 2>/dev/null || true)"
    i=$(( i + 1 ))
  done
  printf '%s' "$body"
}

# 网关「暂无账号」时的说明 —— 同时兜到最终摘要（新手最容易被 docker ps 的 unhealthy 吓到）
GW_HEALTH_NOTE=""

H="$(wait_http "http://127.0.0.1:${WB2API_PORT}/healthz")"
if [ -n "$H" ]; then
  ok "网关就绪：$(printf '%s' "$H" | head -c 120)"
  case "$H" in
    *'"healthy":0'*|*'"total":0'*)
      info "还没纳管账号 —— 网关 /healthz 现在返回 503，容器状态也会显示 unhealthy，"
      info "  这是正常现象；扫码加上账号后会自动转 healthy。别被 docker ps 的红字吓到。"
      GW_HEALTH_NOTE="
    · 网关当前还没有账号：docker ps 里 ${UP_NAME} 显示 (unhealthy) 属正常现象，
      因为 /healthz 如实反映「无可用账号」；扫码加上账号后会自动转为 healthy，不影响使用。"
      ;;
  esac
else
  warn "网关 /healthz 暂无响应（无账号时返回 503 属正常）"
fi

M="$(wait_http "http://127.0.0.1:${MANAGER_PORT}/api/healthz")"
if [ -n "$M" ]; then
  ok "面板就绪：$(printf '%s' "$M" | head -c 120)"
else
  warn "面板 /api/healthz 暂无响应，最近日志："
  docker logs --tail 5 "$MG_NAME" 2>&1 | sed 's/^/      /' >&2 || true
fi

# ---------------------------------------------------------------- 6.5) 可选的域名绑定（交互）
# 主流程跑完但没配域名时，交互式问一句要不要现在绑 —— 免去「事后重跑」。
# 非交互（--auto / CI / 管道）下整段跳过，行为与以前一致。
if [ -z "$DOMAIN" ] && [ -t 0 ] && [ "${NONINTERACTIVE:-0}" != "1" ]; then
  step "可选：绑定域名"
  echo "  现在面板只绑在 127.0.0.1，浏览器直接访问不了（要 SSH 隧道才行）。"
  echo "  给一个域名就能自动装 Caddy、签证书、开放外网 HTTPS。"
  ask "  要现在绑定域名吗？（输入域名 = 现在配好；留空 = 跳过，以后用 --domain 重跑）" ""
  DOMAIN="$REPLY_ASK"
  if [ -n "$DOMAIN" ]; then
    ask "  独立 API 域名（可选，只暴露 /v1、不含面板；留空 = 与面板同域）" "$API_DOMAIN"
    API_DOMAIN="$REPLY_ASK"
  else
    info "已跳过域名绑定（随时可用 --domain 你的域名 重跑本脚本）"
  fi
  echo
fi

# ---------------------------------------------------------------- 7.5) 域名与外网访问
if [ -n "$DOMAIN" ]; then
  step "域名与外网访问（$DOMAIN）"

  # --- DNS 预检：证书签发要求域名解析到本机（交互终端下会等你把记录加好）---
  # 只比 IPv4：本机开了 IPv6 时，getent hosts 可能回 AAAA，与 ipify 的
  # IPv4 一比必然不一致，会平白报一堆假警报。
  # 出口 IP 在这里取一次即可，最后的汇总复用，省一次外网请求。
  PUB_IP=$(curl -4 -sS --max-time 6 https://api.ipify.org 2>/dev/null \
           || curl -sS --max-time 6 https://api.ipify.org 2>/dev/null \
           || hostname -I | awk '{print $1}')
  DNS_OK=""
  for dns_try in 1 2 3 4 5; do
    # 注意：getent 查不到时退出码非 0，在 set -o pipefail 下会让赋值失败并触发 set -e
    # 直接中断（原来就是这个毛病：域名没解析好 → 脚本死在预检处，等不到交互复检）。
    DOM_IP=$( { getent ahostsv4 "$DOMAIN" 2>/dev/null || true; } | awk '{print $1}' | head -1)
    [ -n "$DOM_IP" ] || DOM_IP=$( { getent hosts "$DOMAIN" 2>/dev/null || true; } | awk '{print $1}' | head -1)
    if [ -n "$DOM_IP" ] && [ "$DOM_IP" = "$PUB_IP" ]; then
      DNS_OK=1
      ok "DNS 已指向本机（$PUB_IP）"
      break
    fi
    if [ -n "$DOM_IP" ]; then
      warn "DNS 指向 $DOM_IP，本机是 $PUB_IP —— 不一致，证书签发会失败"
    else
      warn "域名 $DOMAIN 还没有解析记录，本机公网 IP 是 $PUB_IP"
    fi
    # 交互终端：把要加的记录写清楚，用户加好按回车就立刻复检（最多 5 轮）
    if [ -t 0 ] && [ "${NONINTERACTIVE:-0}" != "1" ] && [ "$dns_try" -lt 5 ]; then
      echo "    ${C_BOLD}请到域名 DNS 服务商添加这条记录：${C_0}"
      echo "      ${C_G}A${C_0}    ${DOMAIN}    →    ${PUB_IP}"
      echo "    ${C_D}（域名若走了 Cloudflare 等代理，记得先关掉橙云，否则证书签不下来）${C_0}"
      ask "    加好并保存后按回车立即复检（输入 skip 跳过，稍后重跑本脚本补配）" ""
      [ "$REPLY_ASK" = "skip" ] && break
      continue
    fi
    break
  done
  if [ -z "$DNS_OK" ]; then
    warn "DNS 仍未就绪 —— 证书可能签不下来；补齐解析后重跑本脚本即可（已装的部分不会重装）"
  fi

  # --- 反向代理服务配置（优先复用已有 Nginx/科技Lion，无则安装 Caddy）---
  PROXY_OK=""
  SCHEME="https"
  if [ "$HAS_NGINX" = "1" ]; then
    info "检测到系统已安装运行 Nginx（科技Lion 环境），将通过 Nginx 配置反向代理，跳过 Caddy 安装（避免 80/443 端口冲突）"
    DOMAIN_SLUG="$(printf '%s' "$DOMAIN" | cut -d, -f1 | tr -d ' ')"
    [ -n "$NGINX_CONF_DIR" ] || NGINX_CONF_DIR="/etc/nginx/conf.d"
    mkdir -p "$NGINX_CONF_DIR"
    SITE_FILE="$NGINX_CONF_DIR/${DOMAIN_SLUG}.conf"

    if [ -f "$SITE_FILE" ]; then
      ok "$DOMAIN 站点 Nginx 配置已存在，跳过覆盖（$SITE_FILE）"
    else
      cat > "$SITE_FILE" <<NGINX
# 由 WorkBuddy 部署脚本生成（适配科技Lion / Nginx）
server {
    listen 80;
    server_name ${DOMAIN};

    client_max_body_size 50M;

    location / {
        proxy_pass http://127.0.0.1:${MANAGER_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Port \$server_port;

        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # AI 常用流式输出（SSE / Stream）与长连接强化
        proxy_buffering off;
        proxy_cache off;
        proxy_set_header X-Accel-Buffering no;
        chunked_transfer_encoding on;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        proxy_connect_timeout 60s;
    }
}
NGINX
      ok "已生成 Nginx 反代配置（已强化 SSE 流式响应）：$SITE_FILE"
    fi

    # --- 独立 API 域名（若有）---
    if [ -n "$API_DOMAIN" ] && [ "$API_DOMAIN" != "$DOMAIN" ]; then
      API_SLUG="$(printf '%s' "$API_DOMAIN" | cut -d, -f1 | tr -d ' ')"
      ASITE="$NGINX_CONF_DIR/${API_SLUG}.conf"
      if [ -f "$ASITE" ]; then
        ok "$API_DOMAIN 站点 Nginx 配置已存在，跳过覆盖"
      else
        cat > "$ASITE" <<NGINX
# 由 WorkBuddy 部署脚本生成（独立 API 域名，只暴露 /v1）
server {
    listen 80;
    server_name ${API_DOMAIN};

    client_max_body_size 50M;

    location /v1/ {
        proxy_pass http://127.0.0.1:${MANAGER_PORT}/v1/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Port \$server_port;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # AI 常用流式输出（SSE / Stream）与长连接强化
        proxy_buffering off;
        proxy_cache off;
        proxy_set_header X-Accel-Buffering no;
        chunked_transfer_encoding on;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        proxy_connect_timeout 60s;
    }

    location / {
        return 404;
    }
}
NGINX
        ok "已生成 $ASITE（仅 /v1，已强化 SSE 流式响应）"
      fi
    fi

    # 测试并重载 Nginx
    if eval "${NGINX_TEST_CMD:-nginx -t}" >/dev/null 2>&1; then
      eval "${NGINX_RELOAD_CMD:-systemctl reload nginx || nginx -s reload}" >/dev/null 2>&1 || true
      PROXY_OK=1
      CADDY_OK=1
      ok "Nginx 语法校验通过并已热重载生效"
    else
      warn "Nginx 配置文件测试有误，请排查（可用 ${NGINX_TEST_CMD:-nginx -t}）"
    fi

    # 检查连通性（优先看是否已有 HTTPS，否则回落到 HTTP）
    CERT_OK=""
    for scheme_try in "https" "http"; do
      C=$(curl -sS --max-time 5 -k -o /dev/null -w "%{http_code}" "${scheme_try}://${DOMAIN}/api/healthz" 2>/dev/null || echo "")
      if [ "$C" = "200" ]; then
        SCHEME="$scheme_try"
        CERT_OK=1
        ok "外网访问就绪: ${SCHEME}://${DOMAIN}"
        break
      fi
    done
    if [ -z "$CERT_OK" ]; then
      warn "域名暂未通（DNS 未生效或尚未申请 SSL 证书），可使用科技Lion工具箱一键添加 SSL 证书"
    fi

  else
    # --- 原生环境：安装 Caddy（缺了自动装；已有则跳过）---
    if ! command -v caddy >/dev/null 2>&1; then
      info "安装 Caddy（官方 apt 源）…"
      apt-get update -qq >/dev/null 2>&1 || true
      apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl gnupg >/dev/null 2>&1 || true
      command -v gpg >/dev/null 2>&1 || die "缺少 gpg(gnupg)，无法导入 Caddy 仓库签名；请先 apt-get install -y gnupg"
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
        || die "下载 Caddy 仓库签名失败（网络不通 dl.cloudsmith.io？）"
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        > /etc/apt/sources.list.d/caddy-stable.list \
        || die "下载 Caddy 官方 apt 源失败（网络不通 dl.cloudsmith.io？）"
      apt-get update -qq >/dev/null 2>&1 || warn "apt-get update 失败，仍尝试直接安装 caddy"
      if ! CADDY_OUT="$(apt-get install -y -qq caddy 2>&1)"; then
        printf '%s\n' "$CADDY_OUT" | tail -n 8 | sed 's/^/      /' >&2
        die "Caddy 安装失败（上方为 apt 的真实报错）"
      fi
    fi
    ok "Caddy $(caddy version 2>/dev/null | awk '{print $1}')"

    # --- 已知坑：Caddy 以 caddy 用户运行，日志目录必须存在且可写 ---
    mkdir -p /var/log/caddy && chown -R caddy:caddy /var/log/caddy
    mkdir -p /etc/caddy/conf.d

    # --- 多站点管理：主 Caddyfile 只负责引入 conf.d，新增域名不再改主文件 ---
    if [ ! -f /etc/caddy/Caddyfile ]; then
      printf 'import /etc/caddy/conf.d/*.caddy\n' > /etc/caddy/Caddyfile
      ok "新建 Caddyfile（conf.d 模式）"
    elif ! grep -q "conf.d" /etc/caddy/Caddyfile; then
      printf '\nimport /etc/caddy/conf.d/*.caddy\n' >> /etc/caddy/Caddyfile
      ok "主 Caddyfile 已追加 conf.d 引入（原有站点配置保留不动）"
    fi

    # --- 面板/对外站点（幂等：已配置过就跳过，避免同域名写两份导致校验失败）---
    DOMAIN_SLUG="$(printf '%s' "$DOMAIN" | cut -d, -f1 | tr -d ' ')"
    SITE_FILE="/etc/caddy/conf.d/${DOMAIN_SLUG}.caddy"
    if [ -f "$SITE_FILE" ] || grep -qE "^[[:space:]]*${DOMAIN} \{" /etc/caddy/Caddyfile 2>/dev/null; then
      ok "$DOMAIN 站点已配置，跳过"
    else
      cat > "$SITE_FILE" <<CADDY
${DOMAIN} {
	reverse_proxy 127.0.0.1:${MANAGER_PORT}
	encode zstd gzip
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "DENY"
		Referrer-Policy "no-referrer"
		-Server
	}
	log {
		output file /var/log/caddy/${DOMAIN}.log {
			roll_size 10MiB
			roll_keep 2
		}
	}
}
CADDY
      ok "已生成 $SITE_FILE"
    fi

    # --- 独立 API 域名：只暴露 /v1，其余一律 404（面板不在此域名上）---
    if [ -n "$API_DOMAIN" ] && [ "$API_DOMAIN" != "$DOMAIN" ]; then
      API_SLUG="$(printf '%s' "$API_DOMAIN" | cut -d, -f1 | tr -d ' ')"
      ASITE="/etc/caddy/conf.d/${API_SLUG}.caddy"
      if [ -f "$ASITE" ]; then
        ok "$API_DOMAIN 站点已配置，跳过"
      else
        cat > "$ASITE" <<CADDY
${API_DOMAIN} {
	handle /v1/* {
		reverse_proxy 127.0.0.1:${MANAGER_PORT}
	}
	handle {
		respond "Not Found" 404
	}
}
CADDY
        ok "已生成 $ASITE（仅 /v1，不含面板）"
      fi
    fi

    # 关键：先把站点日志文件按 caddy 身份建好，再校验
    if grep -hoE '/var/log/caddy/[^ {]+\.log' /etc/caddy/conf.d/*.caddy 2>/dev/null | sort -u | while read -r _logf; do
         [ -e "$_logf" ] || : > "$_logf" 2>/dev/null || true
         chown caddy:caddy "$_logf" 2>/dev/null || true
         chmod 640 "$_logf" 2>/dev/null || true
       done; then :; fi
    chown -R caddy:caddy /var/log/caddy 2>/dev/null || true

    # 校验并加载
    if ! CADDY_VALIDATE_OUT="$(caddy validate --config /etc/caddy/Caddyfile 2>&1)"; then
      printf '%s\n' "$CADDY_VALIDATE_OUT" | tail -6 | sed 's/^/      /' >&2
      die "Caddyfile 校验失败（上方为真实报错），请检查 /etc/caddy/conf.d/ 下的站点文件"
    fi
    systemctl enable --now caddy >/dev/null 2>&1 || true
    systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1 || true
    sleep 2
    CADDY_OK=""
    if systemctl is-active caddy >/dev/null 2>&1; then
      CADDY_OK=1
      PROXY_OK=1
      ok "caddy: active（80/443 已监听）"
    else
      warn "caddy 没能启动 —— 日志尾部："
      journalctl -u caddy --no-pager -n 8 2>/dev/null | sed 's/^/      /' >&2 || true
      warn "常见原因：80/443 被占用或安全组拦截"
    fi

    # 等证书签发 + 外网自检
    if [ -z "$CADDY_OK" ]; then
      warn "跳过证书等待（caddy 未运行）"
    else
      ok "等待证书签发（Let's Encrypt，通常 10~30 秒）…"
      CERT_OK=""
      for i in $(seq 1 12); do
        C=$(curl -sS --max-time 10 -o /dev/null -w "%{http_code}" "${SCHEME}://${DOMAIN}/api/healthz" 2>/dev/null || echo "")
        [ "$C" = "200" ] && { CERT_OK=1; break; }
        sleep 5
      done
      if [ -n "$CERT_OK" ]; then
        ok "外网访问就绪: ${SCHEME}://${DOMAIN}"
      else
        warn "域名暂未通（多为 DNS 未生效或 80/443 被安全组拦截），稍后手动验证：curl -I ${SCHEME}://${DOMAIN}"
      fi
      API_CERT_OK=""
      if [ -n "$API_DOMAIN" ] && [ "$API_DOMAIN" != "$DOMAIN" ] && [ -n "$CERT_OK" ]; then
        for i in $(seq 1 12); do
          AC=$(curl -sS --max-time 10 -o /dev/null -w "%{http_code}" "${SCHEME}://${API_DOMAIN}/v1/models" 2>/dev/null || echo "")
          case "$AC" in 200|401) API_CERT_OK=1; break ;; esac
          sleep 5
        done
        if [ -n "$API_CERT_OK" ]; then
          ok "API 域名证书就绪: ${SCHEME}://${API_DOMAIN}/v1"
        else
          warn "API 域名 ${API_DOMAIN} 暂未通（同样先查 A 记录与安全组）"
        fi
      fi
    fi
  fi   # 结束反向代理分支

  # --- 自动开启外网 API：无密钥就自动建一把 ---
  M=$(curl -sS --max-time 8 "http://127.0.0.1:${MANAGER_PORT}/api/healthz" 2>/dev/null || echo "")
  if [ -n "$M" ]; then
    if [ -n "${MANAGER_API_KEY:-}" ]; then
      ok "外网 API 密钥已存在（.credentials 的 MANAGER_API_KEY）"
    else
      info "自动创建对外 API 密钥（含重试机制）…"
      MKEY=""
      for attempt in 1 2 3; do
        CK="$(mktemp)"; chmod 600 "$CK"
        # 密码经 stdin + python JSON 转义传入：既不会出现在进程列表，也不会破坏 JSON
        if printf '%s' "$ADMIN_PASSWORD" \
          | python3 -c 'import json,sys; print(json.dumps({"username":"admin","password":sys.stdin.read()}))' \
          | curl -sS --max-time 10 -c "$CK" -X POST "http://127.0.0.1:${MANAGER_PORT}/api/login" \
              -H "Content-Type: application/json" -d @- >/dev/null 2>&1; then
          
          KR=$(curl -sS --max-time 10 -b "$CK" -X POST "http://127.0.0.1:${MANAGER_PORT}/api/keys" \
            -H "Content-Type: application/json" -d '{"name":"default"}' 2>/dev/null || echo "")
          rm -f "$CK"
          MKEY=$(printf '%s' "$KR" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('key') or '')
except Exception:
    print('')
" 2>/dev/null || echo "")
          [ -n "$MKEY" ] && break
        else
          rm -f "$CK"
        fi
        sleep 2
      done

      if [ -n "$MKEY" ]; then
        umask 077
        # 先删旧行再追加：同名键写两份会让下次 source 的结果变得难以预料
        if grep -q '^MANAGER_API_KEY=' "$CRED_FILE" 2>/dev/null; then
          grep -v '^MANAGER_API_KEY=' "$CRED_FILE" > "$CRED_FILE.tmp" || true
          mv "$CRED_FILE.tmp" "$CRED_FILE"
        fi
        printf 'MANAGER_API_KEY=%q\n' "$MKEY" >> "$CRED_FILE"
        umask 022
        ok "API 密钥已生成并保存（$CRED_FILE 的 MANAGER_API_KEY）"
      else
        warn "密钥自动创建失败（重试 3 次超时），可在面板「密钥」页手动创建"
      fi
    fi
  fi

  # --- 汇总里补充域名信息 ---
  if [ -n "$PROXY_OK" ] && [ -n "$CERT_OK" ]; then
    DOMAIN_SUMMARY="${SCHEME}://${DOMAIN}"
  elif [ "$HAS_NGINX" = "1" ] && [ -n "$PROXY_OK" ]; then
    DOMAIN_SUMMARY="http://${DOMAIN}（反代已就绪，可用科技Lion一键补配 SSL）"
  else
    DOMAIN_SUMMARY="https://${DOMAIN}   ← 尚未生效（见下方提示）"
  fi
  # 独立 API 域名要按实际签发情况标注（配了域名但证书没下来时不能显示成可用）
  if [ -n "$API_DOMAIN" ] && [ "$API_DOMAIN" != "$DOMAIN" ]; then
    if [ -n "$API_CERT_OK" ]; then
      API_SUMMARY="https://${API_DOMAIN}/v1"
    elif [ "$HAS_NGINX" = "1" ] && [ -n "$PROXY_OK" ]; then
      API_SUMMARY="http://${API_DOMAIN}/v1"
    else
      API_SUMMARY="https://${API_DOMAIN}/v1   ← 尚未生效（见下方提示）"
    fi
  else
    API_SUMMARY="${SCHEME:-https}://${DOMAIN}/v1"
  fi
fi

# ---------------------------------------------------------------- 6.8) 域名没生效时的兜底提示
# 域名不通时用户根本进不去面板 —— 必须把「SSH 隧道」这条临时通道说清楚。
if [ -n "$DOMAIN" ] && [ -z "$CERT_OK" ]; then
  if [ "$HAS_NGINX" = "1" ]; then
    warn "域名暂时还无法直接通过浏览器访问，排查与建议："
    warn "  1) 域名 A 记录是否已解析到本机公网 IP $PUB_IP（在 DNS 服务商处核对）"
    warn "  2) 云厂商的防火墙/安全组是否放行 80/443 端口"
    warn "  3) 科技Lion一键配置：直接在服务器运行 kejilion.sh，在【建站/反向代理】中为 $DOMAIN 申请 SSL 证书并反代到 127.0.0.1:${MANAGER_PORT}"
    warn "在此期间照样能进面板 —— 在本机执行下面这条命令，然后浏览器打开 http://localhost:${MANAGER_PORT}"
    warn "    ssh -L ${MANAGER_PORT}:127.0.0.1:${MANAGER_PORT} <你的服务器IP>"
  else
    warn "域名暂时还访问不了（证书未签发或 caddy 未运行），按下面顺序排查："
    warn "  1) 域名 A 记录是否指向本机公网 IP $PUB_IP（在 DNS 服务商处核对）"
    warn "  2) 云厂商的防火墙是否放行 80/443（AWS/阿里云/腾讯云叫「安全组」，Vultr/DO 叫「Firewall」；"
    warn "     机器上的 ufw/iptables 也要放行）"
    warn "  3) 修好后重跑本脚本即可，已装好的部分不会重装"
    warn "在此期间照样能进面板 —— 在本机执行下面这条命令，然后浏览器打开 http://localhost:${MANAGER_PORT}"
    warn "    ssh -L ${MANAGER_PORT}:127.0.0.1:${MANAGER_PORT} <你的服务器IP>"
  fi
fi

# ---------------------------------------------------------------- 7) 汇总
# PUB_IP 在上面域名分支已取过就复用，没走域名分支才现取（省一次外网请求）
IP="${PUB_IP:-$(curl -4 -sS --max-time 6 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')}"
step "部署完成"
# 「下一步」文案按有无域名分支：有域名 = 纯网页流程；无域名 = SSH 隧道流程
if [ -n "$DOMAIN" ]; then
  if [ "$HAS_NGINX" = "1" ]; then
    NEXT_STEPS="    1) 加账号：浏览器打开 ${DOMAIN_SUMMARY%% *} → 「账号」页 → 添加账号 → 扫码
    2) 证书/反代管理：服务器已安装科技Lion，若需开启 HTTPS，可在终端运行 kejilion.sh 申请 SSL 证书
    3) API 接入：Base URL = ${API_SUMMARY} ，Bearer 密钥见 $CRED_FILE 的 MANAGER_API_KEY
    4) 查看日志：docker logs -f ${UP_NAME} / ${MG_NAME}"
  else
    NEXT_STEPS="    1) 加账号：浏览器打开 https://${DOMAIN} → 「账号」页 → 添加账号 → 扫码（全程网页，无需命令行）
    2) API 接入：Base URL = ${API_SUMMARY} ，Bearer 密钥见 $CRED_FILE 的 MANAGER_API_KEY
    3) 查看日志：docker logs -f ${UP_NAME} / ${MG_NAME}"
  fi
  # 域名还没生效时，把「隧道」这条立即能用的通道补在下一步最前面（否则小白进不去面板）
  if [ -z "$CERT_OK" ]; then
    NEXT_STEPS="    ${C_Y}0)${C_0} 域名还没生效，想马上进面板就用隧道：
       本机执行 ssh -L ${MANAGER_PORT}:127.0.0.1:${MANAGER_PORT} <你的服务器IP>
       再开浏览器访问 http://localhost:${MANAGER_PORT}
${NEXT_STEPS}"
  fi
else
  if [ "$HAS_NGINX" = "1" ]; then
    NEXT_STEPS="    1) 加账号：本机执行 ssh -L ${MANAGER_PORT}:127.0.0.1:${MANAGER_PORT} <服务器> 后，
       浏览器打开 http://localhost:${MANAGER_PORT} → 「账号」→ 添加账号 → 扫码
    2) 绑定域名与外网访问（科技Lion 环境）：
       · 方式 A（推荐）：终端运行 kejilion.sh → 【建站】/【站点反向代理】→ 目标填 127.0.0.1:${MANAGER_PORT}
       · 方式 B：重跑本脚本并指定 DOMAIN=你的域名，脚本将自动写入 Nginx 反代配置
    3) 查看日志：docker logs -f ${UP_NAME} / ${MG_NAME}"
  else
    NEXT_STEPS="    1) 加账号：本机执行 ssh -L ${MANAGER_PORT}:127.0.0.1:${MANAGER_PORT} <服务器> 后，
       浏览器打开 http://localhost:${MANAGER_PORT} → 「账号」→ 添加账号 → 扫码
    2) 要一键开外网访问（Caddy + 证书 + API），重跑本脚本时加上 DOMAIN=你的域名
    3) 查看日志：docker logs -f ${UP_NAME} / ${MG_NAME}"
  fi
fi
# 动态读本机内存：以前写死 906MB，换台机器就报错误信息
MEM_MB="$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')"
MEM_MB="${MEM_MB:-?}"

cat <<SUM

  ${C_G}══════════════════════════════════════════════════${C_0}

  ${C_BOLD}${RUN_MODE:-部署完成}${C_0} · 总耗时 $(elapsed)

  网关   ${API_SUMMARY:-http://127.0.0.1:${WB2API_PORT}}   （API 端点，Bearer 密钥见 $CRED_FILE）
  面板   ${DOMAIN_SUMMARY:-http://127.0.0.1:${MANAGER_PORT}}   （管理面板）
  服务器 $IP

  ${C_BOLD}凭据（已存 $CRED_FILE，0600）${C_0}
    上游 api_key   : ${API_KEY:0:8}…（完整值看文件）
    面板管理员密码 : ${ADMIN_PASSWORD}

  ${C_BOLD}下一步${C_0}
${NEXT_STEPS}

  ${C_Y}注意${C_0}
${FIRST_RUN_NOTE:-    · 凭据以文件 $CRED_FILE 为准（0600，root 可读）。}
    · 面板容器挂载了 docker.sock 且持有账号明文凭证，等于本机高权限入口：
      只绑 127.0.0.1 + 走 HTTPS + 强密码，别把端口 ${MANAGER_PORT} 暴露到公网。
    · 内存较小的机器（1GB 级）：两个容器已限 256m/320m；要升级版本请拉新镜像，
      不要在面板里触发本机构建（会 OOM）。
    · 请遵守对应服务的使用条款，仅用于纳管你自己的账号。

  ${C_G}══════════════════════════════════════════════════${C_0}
SUM
