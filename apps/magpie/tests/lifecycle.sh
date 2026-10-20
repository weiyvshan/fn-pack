#!/bin/bash
# Magpie FPK lifecycle self-test.
#
# Builds a throwaway sandbox that mimics the fnOS TRIM_* environment and drives
# cmd/main through every declared phase, asserting observable behaviour rather
# than exit codes alone.
set -u

SOURCE="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
PROJ="${MAGPIE_TEST_PROJECT:-$SOURCE}"
MAIN="$PROJ/cmd/main"
PROVENANCE="${MAGPIE_TEST_PROVENANCE:-$SOURCE/tests/fixtures/previous-main.provenance.json}"
VERSIONS="$(python3 - "$PROJ/manifest" "$PROVENANCE" <<'PY'
import json, re, sys
from pathlib import Path
fields = {}
for line in Path(sys.argv[1]).read_text().splitlines():
    if '=' in line and not line.lstrip().startswith(('#', ';')):
        key, value = line.split('=', 1)
        fields[key.strip()] = value.strip()
previous = json.loads(Path(sys.argv[2]).read_text())
if fields.get('appname') != 'magpie' or previous.get('appname') != 'magpie':
    raise SystemExit('Invalid Magpie test metadata')
versions = (fields.get('version', ''), previous.get('package_version', ''))
if not all(re.fullmatch(r'[0-9]+(?:\.[0-9]+)+(?:-[0-9]+)?', version) for version in versions):
    raise SystemExit('Invalid Magpie test versions')
print(*versions)
PY
)" || exit 2
read -r CURRENT_VERSION PREVIOUS_VERSION <<<"$VERSIONS"
# Fail closed outside the dedicated network namespace.
[ -n "${MAGPIE_TEST_HOST_NETNS:-}" ] || exit 2
[ "$(readlink /proc/self/ns/net)" != "$MAGPIE_TEST_HOST_NETNS" ] || exit 2
[ "$(id -u)" != 0 ] || exit 2
SB="$(mktemp -d "${TMPDIR:-/tmp}/mglife.XXXXXX")"

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
step() { printf '\n== %s ==\n' "$1"; }

cleanup() {
    # Only ever terminate processes whose executable lives inside this sandbox,
    # so a real installed magpie is never touched.
    for p in $(pgrep -x magpie 2>/dev/null); do
        exe="$(readlink "/proc/$p/exe" 2>/dev/null)"
        case "$exe" in
            "$SB"/*) kill -KILL "$p" 2>/dev/null ;;
        esac
    done
    if [ -f "$V/run/web.pid" ]; then
        p="$(head -n1 "$V/run/web.pid" 2>/dev/null | tr -d ' \r\n')"
        if [ -n "$p" ]; then
            exe="$(readlink "/proc/$p/exe" 2>/dev/null)"
            case "$exe" in
                "$SB"/*) kill -KILL "$p" 2>/dev/null ;;
            esac
        fi
    fi
    sleep 1
    rm -rf -- "$SB"
}
trap cleanup EXIT

WEB_PORT=3430
GW_PORT=3425

mkdir -p "$SB/appdest/bin" "$SB/varroot/apps/magpie/var" "$SB/etc" "$SB/tmp" "$SB/home" "$SB/meta"
cp "$PROJ/app/bin/magpie" "$SB/appdest/bin/magpie"
chmod 0755 "$SB/appdest/bin/magpie"

export TRIM_APPNAME=magpie
export TRIM_APPVER="$CURRENT_VERSION"
export TRIM_OLD_APPVER="$PREVIOUS_VERSION"
export TRIM_APP_STATUS=running
export TRIM_APPDEST="$SB/appdest"
export TRIM_PKGVAR="$SB/varroot/apps/magpie/var"
V="$TRIM_PKGVAR"
export TRIM_PKGETC="$SB/etc"
export TRIM_PKGTMP="$SB/tmp"
export TRIM_PKGHOME="$SB/home"
export TRIM_PKGMETA="$SB/meta"
export TRIM_UID="$(id -u)"
export TRIM_GID="$(id -g)"
export TRIM_USERNAME="$(id -un)"
export TRIM_GROUPNAME="$(id -gn)"
export TRIM_RUN_UID="$(id -u)"
export TRIM_RUN_GID="$(id -g)"
export TRIM_SERVICE_PORT="$WEB_PORT"
export TRIM_TEMP_LOGFILE="$SB/tmp/lifecycle.log"
unset wizard_web_key delete_data 2>/dev/null || true

PIDF="$V/run/web.pid"
KEYF="$V/web.key"

ports_free() {
    for checked_port in "$WEB_PORT" "$GW_PORT"; do
        [ -z "$(/usr/bin/ss -H -ltn "sport = :$checked_port" 2>/dev/null)" ] || return 1
    done
    return 0
}

printf '沙箱: %s\n' "$SB"

step '工具前置检查'
[ -x /usr/bin/kill ] && ok '/usr/bin/kill 存在' || bad '/usr/bin/kill 缺失'
[ -x /usr/bin/ss ] && ok '/usr/bin/ss 存在' || bad '/usr/bin/ss 缺失'
[ -x /usr/bin/setpriv ] && ok '/usr/bin/setpriv 存在' || bad '/usr/bin/setpriv 缺失'
ports_free && ok '目标端口初始空闲' || bad '目标端口初始被占用'

step '非白名单阶段必须失败'
bash "$MAIN" bogus >/dev/null 2>&1
[ $? -ne 0 ] && ok '未知阶段被拒绝' || bad '未知阶段未被拒绝'
bash "$MAIN" >/dev/null 2>&1
[ $? -ne 0 ] && ok '空阶段被拒绝' || bad '空阶段未被拒绝'

step 'install_init 不触碰任何路径'
before="$(find "$SB" -newermt '-1 seconds' 2>/dev/null | wc -l)"
bash "$MAIN" install_init; rc=$?
[ "$rc" = "0" ] && ok 'install_init 退出 0' || bad "install_init 退出 $rc"
[ ! -d "$V/run" ] && ok 'install_init 未创建运行目录' || bad 'install_init 过早创建了目录'

step '缺少必需环境变量时必须失败'
( env -u TRIM_APPDEST TRIM_PKGVAR="$V" TRIM_PKGETC="$SB/etc" TRIM_PKGTMP="$SB/tmp" \
    TRIM_PKGHOME="$SB/home" TRIM_UID=1 TRIM_GID=1 \
    bash "$MAIN" start ) >/dev/null 2>&1
[ $? -ne 0 ] && ok '缺少 TRIM_APPDEST 被拒绝' || bad '缺少 TRIM_APPDEST 未被拒绝'

step '安装向导密钥：非法值必须被拒绝'
wizard_web_key='short' bash "$MAIN" install_callback >/dev/null 2>&1
[ $? -ne 0 ] && ok '过短密钥被拒绝' || bad '过短密钥未被拒绝'
wizard_web_key='aaaaaaaaaaaaaaaa!!' bash "$MAIN" install_callback >/dev/null 2>&1
[ $? -ne 0 ] && ok '非法字符密钥被拒绝' || bad '非法字符密钥未被拒绝'
[ ! -f "$KEYF" ] && ok '非法密钥未落盘' || bad '非法密钥被写入'

step '安装向导密钥：合法值必须持久化'
GOODKEY='MgTest_Key.0123456789-abc~XYZ'
wizard_web_key="$GOODKEY" bash "$MAIN" install_callback; rc=$?
[ "$rc" = "0" ] && ok 'install_callback 退出 0' || bad "install_callback 退出 $rc"
[ -f "$KEYF" ] && ok '密钥文件已创建' || bad '密钥文件未创建'
stored="$(head -n1 "$KEYF" 2>/dev/null)"
[ "$stored" = "$GOODKEY" ] && ok '密钥内容正确' || bad "密钥内容不符: [$stored]"
perm="$(stat -c '%a' "$KEYF" 2>/dev/null)"
[ "$perm" = "600" ] && ok '密钥文件权限 0600' || bad "密钥文件权限为 $perm"
grep -qF "$GOODKEY" "$TRIM_TEMP_LOGFILE" 2>/dev/null && bad '密钥泄漏进日志' || ok '密钥未出现在日志中'

step 'start：冷启动'
bash "$MAIN" start; rc=$?
[ "$rc" = "0" ] && ok 'start 退出 0' || bad "start 退出 $rc"
[ -f "$PIDF" ] && ok 'PID 文件已写入' || bad 'PID 文件未写入'
PID="$(head -n1 "$PIDF" 2>/dev/null | tr -d ' \r\n')"
if [ -n "$PID" ] && [ -d "/proc/$PID" ]; then ok "进程存活 (pid $PID)"; else bad "进程不存活 (pid=[$PID])"; fi
exe="$(readlink "/proc/$PID/exe" 2>/dev/null)"
[ "$exe" = "$SB/appdest/bin/magpie" ] && ok 'PID 指向包内二进制' || bad "PID 指向 $exe"
owner="$(stat -c '%u' "/proc/$PID" 2>/dev/null)"
[ "$owner" = "$TRIM_UID" ] && ok "进程属主为包身份 ($owner)" || bad "进程属主为 $owner"
c1="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:$WEB_PORT/")"
[ "$c1" = "401" ] && ok '管理界面未认证返回 401' || bad "管理界面返回 $c1"
c2="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:$GW_PORT/v1/models")"
[ "$c2" = "200" ] && ok '回环网关返回 200' || bad "回环网关返回 $c2"

# Regression for 0.1.1275-1/-2: the controller left account discovery off and
# forced MAGPIE_NO_ACCOUNTS=1 at every start. With discovery off Magpie serves
# no subscription and lists no plugin account at all, so every plugin provider
# (OpenCode Zen Free and the rest) signed in and then never appeared.
if [ -r "/proc/$PID/environ" ]; then
    envdump="$(tr '\0' '\n' <"/proc/$PID/environ")"
    if printf '%s\n' "$envdump" | grep -qx 'MAGPIE_NO_ACCOUNTS=1'; then
        bad '服务环境仍注入 MAGPIE_NO_ACCOUNTS=1（插件账号将永远无法列出）'
    else
        ok '服务环境未注入 MAGPIE_NO_ACCOUNTS'
    fi
    printf '%s\n' "$envdump" | grep -qx 'MAGPIE_NO_STATS=1' \
        && ok '统计上报仍保持关闭' || bad '统计上报开关缺失'
else
    bad "无法读取服务进程环境 (proc/$PID/environ)"
fi

[ -f "$V/xdg/config/magpie/settings.json" ] && ok '设置文件已生成' || bad '设置文件未生成'
if [ -f "$V/xdg/config/magpie/settings.json" ]; then
    python3 -c "
import json
d=json.load(open('$V/xdg/config/magpie/settings.json'))
print('  settings: noAccountDiscovery=%s noAutoUpdate=%s' % (d.get('noAccountDiscovery'), d.get('noAutoUpdate')))
assert d.get('noAccountDiscovery') is not True, 'the package switched account discovery off'
assert d.get('noAutoUpdate') is True, 'auto update not disabled'
" && ok '自动更新已关闭，账号发现未被包关闭' || bad '隐私开关未按预期写入'
fi
grep -q "k=$GOODKEY" "$V/web-url.txt" 2>/dev/null && ok '恢复链接文件已生成' || bad '恢复链接文件缺失'
up="$(stat -c '%a' "$V/web-url.txt" 2>/dev/null)"
[ "$up" = "600" ] && ok '恢复链接文件权限 0600' || bad "恢复链接文件权限为 $up"
lg="$(stat -c '%a' "$V/logs" 2>/dev/null)"
[ "$lg" = "700" ] && ok '日志目录权限 0700' || bad "日志目录权限为 $lg"
lf="$(stat -c '%a' "$V/logs/web.log" 2>/dev/null)"
[ "$lf" = "600" ] && ok '日志文件权限 0600（启动横幅含管理密钥）' || bad "日志文件权限为 $lf"

step 'start：幂等（重复调用不重启）'
bash "$MAIN" start >/dev/null 2>&1; rc=$?
PID2="$(head -n1 "$PIDF" 2>/dev/null | tr -d ' \r\n')"
[ "$rc" = "0" ] && ok '重复 start 退出 0' || bad "重复 start 退出 $rc"
[ "$PID2" = "$PID" ] && ok '进程未被重启（PID 不变）' || bad "PID 变化: $PID -> $PID2"

# Regression: a log left loose by an older package version must be narrowed
# even on the idempotent path, where the service is healthy and keeps running.
chmod 0644 "$V/logs/web.log" 2>/dev/null
chmod 0755 "$V/logs" 2>/dev/null
bash "$MAIN" start >/dev/null 2>&1
lf2="$(stat -c '%a' "$V/logs/web.log" 2>/dev/null)"
[ "$lf2" = "600" ] && ok '旧版遗留日志经幂等 start 收敛为 0600' || bad "遗留日志权限为 $lf2"
lg2="$(stat -c '%a' "$V/logs" 2>/dev/null)"
[ "$lg2" = "700" ] && ok '旧版遗留日志目录收敛为 0700' || bad "遗留日志目录权限为 $lg2"
PID3="$(head -n1 "$PIDF" 2>/dev/null | tr -d ' \r\n')"
[ "$PID3" = "$PID" ] && ok '权限收敛过程未重启服务' || bad "收敛过程重启了服务: $PID -> $PID3"

step 'status：运行中返回 0'
bash "$MAIN" status >/dev/null 2>&1; rc=$?
[ "$rc" = "0" ] && ok 'status 返回 0' || bad "status 返回 $rc"

step 'stop：正常停止并释放端口'
bash "$MAIN" stop; rc=$?
[ "$rc" = "0" ] && ok 'stop 退出 0' || bad "stop 退出 $rc"
sleep 1
[ -d "/proc/$PID" ] && bad '进程仍在' || ok '进程已退出'
[ ! -f "$PIDF" ] && ok 'PID 文件已清理' || bad 'PID 文件残留'
ports_free && ok '端口已释放' || bad '端口未释放'

step 'status：已停止返回 3'
bash "$MAIN" status >/dev/null 2>&1; rc=$?
[ "$rc" = "3" ] && ok 'status 返回 3' || bad "status 返回 $rc"

step 'stop：对已停止服务是幂等的'
bash "$MAIN" stop >/dev/null 2>&1; rc=$?
[ "$rc" = "0" ] && ok '重复 stop 退出 0' || bad "重复 stop 退出 $rc"

step '冷启动（停止后重新启动）使用既有密钥'
bash "$MAIN" start >/dev/null 2>&1; rc=$?
[ "$rc" = "0" ] && ok '冷启动退出 0' || bad "冷启动退出 $rc"
PID3="$(head -n1 "$PIDF" 2>/dev/null | tr -d ' \r\n')"
[ "$PID3" != "$PID" ] && ok '冷启动产生新进程' || bad '冷启动复用了旧 PID'
stored2="$(head -n1 "$KEYF" 2>/dev/null)"
[ "$stored2" = "$GOODKEY" ] && ok '密钥在重启后保持不变' || bad '密钥被改写'
c3="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:$WEB_PORT/")"
[ "$c3" = "401" ] && ok '重启后管理界面正常' || bad "重启后管理界面返回 $c3"

step '端口被外部进程占用时必须拒绝启动'
ZPID=''
# Stop our own instance first so the port is genuinely free for the squatter.
bash "$MAIN" stop >/dev/null 2>&1
sleep 1
python3 -c "
import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('0.0.0.0',$WEB_PORT)); s.listen(5)
time.sleep(60)
" & ZPID=$!
sleep 3
bash "$MAIN" start >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok '端口被占用时 start 失败' || bad '端口被占用时 start 仍然成功'
# The squatter is still alive here, so status must report a fault, not "stopped".
bash "$MAIN" status >/dev/null 2>&1; rc=$?
[ "$rc" = "1" ] && ok '外部占用时 status 返回 1' || bad "外部占用时 status 返回 $rc"
[ -n "$ZPID" ] && kill -KILL "$ZPID" 2>/dev/null
sleep 2
ports_free && ok '抢占进程退出后端口释放' || bad '抢占进程退出后端口仍被占用'

step '残留 PID 文件（陈旧内容）不会被误判为运行中'
bash "$MAIN" stop >/dev/null 2>&1
mkdir -p "$V/run"
printf '%s\n' '999999' >"$PIDF"
bash "$MAIN" status >/dev/null 2>&1; rc=$?
[ "$rc" = "3" ] && ok '陈旧 PID 被识别为已停止' || bad "陈旧 PID 时 status 返回 $rc"
rm -f "$PIDF"

step 'upgrade_init 停止旧服务'
bash "$MAIN" start >/dev/null 2>&1
bash "$MAIN" upgrade_init >/dev/null 2>&1; rc=$?
[ "$rc" = "0" ] && ok 'upgrade_init 退出 0' || bad "upgrade_init 退出 $rc"
ports_free && ok '升级前端口已释放' || bad '升级前端口未释放'

step 'upgrade_callback 重新拉起新版本'
bash "$MAIN" upgrade_callback >/dev/null 2>&1; rc=$?
[ "$rc" = "0" ] && ok 'upgrade_callback 退出 0' || bad "upgrade_callback 退出 $rc"
c4="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:$GW_PORT/v1/models")"
[ "$c4" = "200" ] && ok '升级后网关正常' || bad "升级后网关返回 $c4"
stored3="$(head -n1 "$KEYF" 2>/dev/null)"
[ "$stored3" = "$GOODKEY" ] && ok '升级保留密钥与数据' || bad '升级改写了密钥'

# An installation carried over from 0.1.1275-1/-2 has noAccountDiscovery=true in
# settings.json, written by the package itself. Removing the environment
# variable alone would leave such a machine exactly as broken as before, so the
# controller must revert that persisted value once, then respect later choices.
SETF="$V/xdg/config/magpie/settings.json"
step '旧版遗留的账号发现关闭状态必须被一次性撤销'
bash "$MAIN" stop >/dev/null 2>&1
rm -f "$V/.account-discovery-restored"
python3 -c "
import json
p='$SETF'
d=json.load(open(p)); d['noAccountDiscovery']=True
json.dump(d, open(p,'w'))
"
bash "$MAIN" start >/dev/null 2>&1; rc=$?
[ "$rc" = "0" ] && ok '遗留状态场景 start 退出 0' || bad "遗留状态场景 start 退出 $rc"
python3 -c "
import json
d=json.load(open('$SETF'))
assert d.get('noAccountDiscovery') is not True, 'account discovery left off after upgrade'
" && ok '旧版写入的关闭状态已恢复为开启' || bad '账号发现仍为关闭'
[ -f "$V/.account-discovery-restored" ] && ok '迁移标记已写入' || bad '迁移标记缺失'
mk="$(stat -c '%a' "$V/.account-discovery-restored" 2>/dev/null)"
[ "$mk" = "600" ] && ok '迁移标记权限 0600' || bad "迁移标记权限为 $mk"

step '迁移只发生一次：用户此后自行关闭必须被尊重'
bash "$MAIN" stop >/dev/null 2>&1
python3 -c "
import json
p='$SETF'
d=json.load(open(p)); d['noAccountDiscovery']=True
json.dump(d, open(p,'w'))
"
bash "$MAIN" start >/dev/null 2>&1; rc=$?
[ "$rc" = "0" ] && ok '二次场景 start 退出 0' || bad "二次场景 start 退出 $rc"
python3 -c "
import json
d=json.load(open('$SETF'))
assert d.get('noAccountDiscovery') is True, 'the package overrode a later choice'
" && ok '用户后续自选设置被保留' || bad '包装层覆盖了用户选择'
PID4="$(head -n1 "$PIDF" 2>/dev/null | tr -d ' \r\n')"
[ -n "$PID4" ] && [ -d "/proc/$PID4" ] && ok '迁移流程后服务仍在运行' || bad '迁移流程后服务未运行'

step 'uninstall_init 停止服务'
bash "$MAIN" uninstall_init >/dev/null 2>&1; rc=$?
[ "$rc" = "0" ] && ok 'uninstall_init 退出 0' || bad "uninstall_init 退出 $rc"
ports_free && ok '卸载前端口已释放' || bad '卸载前端口未释放'

step 'uninstall_callback：保留数据'
delete_data=false bash "$MAIN" uninstall_callback >/dev/null 2>&1; rc=$?
[ "$rc" = "0" ] && ok 'uninstall_callback 退出 0' || bad "uninstall_callback 退出 $rc"
[ -d "$V" ] && ok '默认保留应用数据' || bad '数据被意外删除'
[ -f "$KEYF" ] && ok '密钥被保留' || bad '密钥被删除'

step 'uninstall_callback：异常路径必须拒绝删除'
mkdir -p "$SB/bogus/state"
( export TRIM_PKGVAR="$SB/bogus/state"
  delete_data=true bash "$MAIN" uninstall_callback ) >/dev/null 2>&1
[ $? -ne 0 ] && ok '非契约布局的路径被拒绝' || bad '非契约布局的路径被删除了'
[ -d "$SB/bogus/state" ] && ok '非契约布局目录仍然存在' || bad '非契约布局目录已被删除'

( export TRIM_PKGVAR="/"
  delete_data=true bash "$MAIN" uninstall_callback ) >/dev/null 2>&1
[ $? -ne 0 ] && ok '根路径被拒绝' || bad '根路径未被拒绝'

step 'uninstall_callback：显式删除数据'
delete_data=true bash "$MAIN" uninstall_callback >/dev/null 2>&1; rc=$?
[ "$rc" = "0" ] && ok '删除数据分支退出 0' || bad "删除分支退出 $rc"
[ ! -d "$V" ] && ok '应用数据已删除' || bad '应用数据未被删除'

printf '\n========== 结果 ==========\n'
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ] && printf '全部通过\n' || printf '存在失败项\n'
exit "$FAIL"
