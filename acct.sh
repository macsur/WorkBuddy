#!/usr/bin/env bash
# acct.sh — 账号运维工具包装（临时停用 / 恢复 / 复活 / 定时任务补跑）
#
# 用法:
#   ./acct.sh list                     # 列出账号与双位状态
#   ./acct.sh disable <uid> [原因]     # 临时停用（对话流量摘除，保留在池里）
#   ./acct.sh enable  <uid>            # 解除手动停用
#   ./acct.sh revive  <uid>            # 解除系统自动禁用
#   ./acct.sh task    <name>           # 手动触发排程任务 (checkin/activity/keepalive/travel/school/cat)
#
# 需 config 里 admin.enabled = true（且 api_key 非空）。
set -euo pipefail
cd "$(dirname "$0")"

if command -v go >/dev/null 2>&1; then
  exec go run ./cmd/acct "$@"
fi

python3 - "$@" <<'PYEOF'
import sys, json, urllib.request, urllib.error, os

args = sys.argv[1:]
if not args or args[0] in ("-h", "--help"):
    print("用法:")
    print("  ./acct.sh list                     # 列出账号与双位状态")
    print("  ./acct.sh disable <uid> [原因]     # 临时停用")
    print("  ./acct.sh enable  <uid>            # 解除手动停用")
    print("  ./acct.sh revive  <uid>            # 解除系统自动禁用")
    print("  ./acct.sh task    <name>           # 手动触发排程任务 (checkin/activity/keepalive/travel/school/cat)")
    sys.exit(0)

cfg_path = "config.json"
if not os.path.isfile(cfg_path):
    print("错误: 找不到 config.json", file=sys.stderr)
    sys.exit(1)

try:
    with open(cfg_path, "r", encoding="utf-8") as f:
        cfg = json.load(f)
except Exception as e:
    print(f"错误: 解析 config.json 失败: {e}", file=sys.stderr)
    sys.exit(1)

listen = cfg.get("listen", "127.0.0.1:7863")
if ":" in listen:
    host, port = listen.rsplit(":", 1)
else:
    host, port = "127.0.0.1", listen
if host in ("", "0.0.0.0", "::"):
    host = "127.0.0.1"

base_url = f"http://{host}:{port}"
api_key = cfg.get("api_key", "")

def req(method, path, data=None):
    headers = {}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    body = None
    if data is not None:
        headers["Content-Type"] = "application/json"
        body = json.dumps(data).encode("utf-8")
    r = urllib.request.Request(f"{base_url}{path}", data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            return resp.status, resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8")
    except Exception as e:
        print(f"请求网关失败: {e}", file=sys.stderr)
        sys.exit(1)

cmd = args[0]
if cmd == "list":
    st, resp = req("GET", "/status")
    if st != 200:
        print(f"GET /status 返回 {st}: {resp}", file=sys.stderr)
        sys.exit(1)
    data = json.loads(resp)
    accts = data.get("accounts", [])
    if not accts:
        print("（池里没有账号）")
        sys.exit(0)
    print(f"{'UID':<38} {'REALM':<7} {'NICKNAME':<18} {'CREDITS':>8}  STATE")
    for a in accts:
        state = []
        if a.get("manual_disabled"): state.append(f"手动停用({a.get('manual_reason', '')})")
        if a.get("disabled"): state.append(f"自动禁用({a.get('disabled_reason', '')})")
        if a.get("cooling"): state.append("冷却中")
        state_str = " + ".join(state) if state else "正常"
        nick = (a.get("nickname") or "")[:18]
        print(f"{a.get('uid', ''):<38} {a.get('realm', '').upper():<7} {nick:<18} {a.get('credits', 0):>8}  {state_str}")

elif cmd == "task":
    if len(args) < 2:
        print("用法: ./acct.sh task <name> (可用: checkin / activity / keepalive / travel / school / cat)", file=sys.stderr)
        sys.exit(1)
    tname = args[1]
    valid = ["checkin", "activity", "keepalive", "travel", "school", "cat"]
    if tname not in valid:
        print(f"404：任务名不存在（可用: {' / '.join(valid)}）", file=sys.stderr)
        sys.exit(1)
    st, resp = req("POST", f"/admin/tasks/{tname}/run")
    if st == 202:
        print(f"已受理：{tname} 已在网关后台开跑（进度看网关日志）")
    elif st == 409:
        print(f"409：该任务已有一趟在跑，等它跑完再触发", file=sys.stderr)
        sys.exit(1)
    elif st == 404:
        print(f"404：{resp}（可能是 admin.enabled 未开启）", file=sys.stderr)
        sys.exit(1)
    elif st == 401:
        print("401：api_key 不对", file=sys.stderr)
        sys.exit(1)
    else:
        print(f"{st}: {resp}", file=sys.stderr)
        sys.exit(1)

elif cmd in ("disable", "enable", "revive"):
    if len(args) < 2:
        print(f"用法: ./acct.sh {cmd} <uid> [reason]", file=sys.stderr)
        sys.exit(1)
    uid = args[1]
    reason = args[2] if len(args) > 2 else "manual"
    body = {"reason": reason} if cmd == "disable" else None
    st, resp = req("POST", f"/admin/accounts/{uid}/{cmd}", body)
    if st == 200:
        d = json.loads(resp)
        verb = {"disable": "已停用", "enable": "已解除停用", "revive": "已复活"}[cmd]
        print(f"{verb} {uid}")
    else:
        print(f"{st}: {resp}", file=sys.stderr)
        sys.exit(1)
else:
    print(f"未知命令: {cmd}", file=sys.stderr)
    sys.exit(1)
PYEOF
