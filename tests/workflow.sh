#!/usr/bin/env bash
# 实际分阶段入口 + 模拟系统执行，断言最终确认之前零写操作、之后零输入。
set -euo pipefail
cd "$(dirname "$0")/.."
SCRIPT="$PWD/v2fly-auto-setup.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export SCRIPT ROOT
for test in port-race same-domain qr-default ready cancel eof type-return invalid-fields occupied-port duplicate-path mixed-front no-python no-python-menu invalid-link remote-invalid no-python-invalid-link missing-core core-failure recheck-failure swap-accept swap-refuse swap-failure qr-allow qr-native qr-skip qr-failure edit-relay nginx-result init-ready init-cancel init-missing; do
 status=0
 bash -s -- "$test" <<'BASH' || status=$?
set -euo pipefail
source "$SCRIPT"
TEST=$1; STACK_DIR="$ROOT/$TEST/stack"; LOG="$ROOT/$TEST.events"; : > "$LOG"
IN=0; HAVE_PY=yes; HAVE_CORE=yes; HAVE_DOCKER=yes; HAVE_QR=yes; EPEL=no
case "$TEST" in no-python|no-python-menu|no-python-invalid-link|missing-core|core-failure|recheck-failure|init-missing) HAVE_PY=no; HAVE_CORE=no; HAVE_DOCKER=no ;; esac
case "$TEST" in qr-*|init-missing) HAVE_QR=no ;; esac
U=11111111-2222-4333-8444-555555555555
OLD=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
assert(){ "$@" || { printf 'assertion failed: %s\n' "$*" >&2; exit 1; }; }
contains(){ [[ $(cat "$LOG") == *"$1"* ]]; }
not_contains(){ [[ $(cat "$LOG") != *"$1"* ]]; }
event(){ printf '%s\n' "$*" >> "$LOG"; }
mutate(){
 contains 'FINAL-CONFIRM' || { event 'FORBIDDEN before-confirm'; return 99; }
 touch "$ROOT/$TEST.executing"
 event "MUTATE $*"
}
eval "$(declare -f node_ask | sed '1s/node_ask/node_ask_original/')"
node_ask(){
 [[ ! -e $ROOT/$TEST.executing ]] || { event 'FORBIDDEN input-after-mutation'; return 99; }
 event "INPUT $1 DEFAULT=${2:-}"
 node_ask_original "$@"
}
eval "$(declare -f confirm | sed '1s/confirm/confirm_original/')"
confirm(){
 [[ ! -e $ROOT/$TEST.executing ]] || { event 'FORBIDDEN confirm-after-mutation'; return 99; }
 event "CONFIRM $1"
 [[ $1 != '确认执行以上'* ]] || event FINAL-CONFIRM
 confirm_original "$@"
}
command(){
 if [[ ${1:-} == -v ]]; then
  case "$2" in
   python3) [[ $HAVE_PY == yes ]] ;;
   curl|openssl|ss|ip) [[ $HAVE_CORE == yes ]] ;;
   docker) [[ $HAVE_DOCKER == yes ]] ;;
   qrencode) [[ $HAVE_QR == yes ]] ;;
   *) builtin command "$@" ;;
  esac
 else builtin command "$@"; fi
}
preflight(){ OS_FAMILY=debian; [[ $TEST != qr-* ]] || OS_FAMILY=el9; }
dpkg(){ [[ $HAVE_CORE == yes ]] && echo 'Status: install ok installed'; }
rpm(){ if [[ $2 == epel-release ]]; then [[ $EPEL == yes ]]; elif [[ $2 == podman-docker ]]; then return 1; else [[ $HAVE_CORE == yes ]]; fi; }
docker(){
 case "$1" in
  --version) event READ-docker; echo 'Docker version 20.10' ;;
  info) event READ-docker ;;
  inspect)
   event READ-inspect
   if [[ $* == *'{{.Image}}'* ]]; then echo "$OLD";
   elif [[ $* == *com.docker.compose.project* ]]; then echo "${*: -1}";
   else return 1; fi ;;
  logs) event READ-logs ;;
  volume) event READ-volume; return 1 ;;
  compose)
   if [[ $* == 'compose version --short' ]]; then echo 2.24.7;
   elif [[ $* == 'compose version' ]]; then :;
   else mutate "docker $*"; fi ;;
  *) mutate "docker $*" ;;
 esac
}
ss(){ :; }
curl(){ event READ-curl; return 7; }
timeout(){ shift; "$@"; }
port_in_use(){
 if [[ $TEST == port-race && -e $ROOT/$TEST.executing && $1 -ge 2333 ]]; then return 0; fi
 [[ $TEST == occupied-port && $1 == 2999 ]]
}
MEM="$ROOT/$TEST.mem"; SWAPS="$ROOT/$TEST.swaps"
printf 'MemTotal: 2097152 kB\n' > "$MEM"
printf 'Filename Type Size Used Priority\n' > "$SWAPS"
[[ $TEST != swap-* ]] || printf 'MemTotal: 524288 kB\n' > "$MEM"
eval "$(declare -f needs_swap | sed '1s/needs_swap/needs_swap_original/')"
needs_swap(){ needs_swap_original "$MEM" "$SWAPS"; }
create_swap(){ mutate Swap; [[ $TEST != swap-failure ]]; }
install_deps(){ mutate core-deps; [[ $TEST != core-failure ]] || return 1; HAVE_CORE=yes; [[ $TEST == recheck-failure ]] || HAVE_PY=yes; }
install_docker(){ mutate Docker; HAVE_DOCKER=yes; }
apt-get(){ mutate "apt $*"; HAVE_QR=yes; }
dnf(){
 mutate "dnf $*"
 [[ $TEST != qr-failure ]] || return 1
 if [[ $* == *epel-release-latest-9.noarch.rpm* ]]; then EPEL=yes;
 elif [[ $EPEL == yes ]]; then HAVE_QR=yes;
 else return 1; fi
}
qrencode(){ cat >/dev/null; if [[ $* == *ASCII* ]]; then printf '%060d\n' 0; else echo rendered; fi; }
tput(){ echo 100; }
open_firewall(){ mutate "firewall $1"; }
node_ingress_apply(){ [[ $TEST != same-domain ]] || node_python ingress; }
node_ready(){ :; }
eval "$(declare -f execute_environment_plan | sed '1s/execute_environment_plan/execute_environment_plan_original/')"
execute_environment_plan(){
 execute_environment_plan_original "$@" || return 1
 [[ $TEST != port-race ]] || touch "$ROOT/$TEST.executing"
}

INPUT="$ROOT/$TEST.input"
if [[ $TEST == same-domain ]]; then
 node_python create 1 one.example.com caddy direct 2333 /first "$U" v2fly/v2fly-core:latest
 cp "$STACK_DIR/nodes/1/metadata.json" "$ROOT/$TEST.first"
fi
if [[ $TEST == duplicate-path || $TEST == mixed-front ]]; then
 node_python create 1 existing.example.com nginx direct 2333 /taken "$U" v2fly/v2fly-core:latest
 if [[ $TEST == duplicate-path ]]; then
  node_python create 1 one.example.com nginx direct 2333 /taken "$U" v2fly/v2fly-core:latest
 fi
fi
LINK=$(python3 - "$U" <<'PY'
import json,base64,sys
print('vmess://'+base64.b64encode(json.dumps(dict(add='jp.example.com',port=443,id=sys.argv[1],path='/remote',net='ws',tls='tls')).encode()).decode())
PY
)
if [[ $TEST == same-domain ]]; then
 printf '1\n名称\n1\nn\ny\n' > "$INPUT"
elif [[ $TEST == edit-relay ]]; then
 node_python create 1 one.example.com nginx relay 2333 /one "$U" v2fly/v2fly-core:5.41.0 manual jp.example.com 443 "$U" /remote
 node_python label 1 名称
 NODE_ID=1
 printf '\n\n\nn\n\ny\n' > "$INPUT"
elif [[ $TEST == init-* ]]; then
 if [[ $TEST == init-missing ]]; then printf '3\ny\n' > "$INPUT"; elif [[ $TEST == init-cancel ]]; then printf 'n\n' > "$INPUT"; else printf 'y\n' > "$INPUT"; fi
elif [[ $TEST == type-return ]]; then printf '0\n' > "$INPUT"
elif [[ $TEST == duplicate-path ]]; then
 printf '1\n名称\n1\ny\nauto\n/taken\n/new-path\nauto\nlatest\ny\n' > "$INPUT"
elif [[ $TEST == mixed-front ]]; then
 printf '1\n名称\n2\n3\none.example.com\nn\ny\n' > "$INPUT"
elif [[ $TEST == invalid-fields ]]; then
 printf '1\n名称\n2\nbad domain\none.example.com\ny\n80\n2334\nbad path\n/valid\nbad uuid\n%s\nbad/tag\nlatest\ny\n' "$U" > "$INPUT"
elif [[ $TEST == occupied-port ]]; then
 printf '1\n名称\n2\none.example.com\ny\n2999\n2334\n/valid\n%s\nlatest\ny\n' "$U" > "$INPUT"
elif [[ $TEST == remote-invalid ]]; then
 printf '2\n名称\n2\none.example.com\nn\n2\nbad domain\njp.example.com\n65536\n443\nauto\n%s\nauto\n/remote\n\n\ny\n' "$U" > "$INPUT"
elif [[ $TEST == invalid-link || $TEST == no-python-invalid-link ]]; then
 printf '2\n名称\n2\none.example.com\nn\n1\nvmess://bad\n' > "$INPUT"
 if [[ $TEST == invalid-link ]]; then printf '%s\ny\n' "$LINK" >> "$INPUT"; else printf 'y\n' >> "$INPUT"; fi
else
 printf '1\n名称\n2\none.example.com\nn\n' > "$INPUT"
 case "$TEST" in
  swap-refuse) printf 'n\n' >> "$INPUT" ;;
  swap-accept|swap-failure) printf 'y\ny\n' >> "$INPUT" ;;
  qr-default) printf '\ny\n' >> "$INPUT" ;;
  qr-allow) printf '1\ny\n' >> "$INPUT" ;;
  qr-native|qr-failure) printf '2\ny\n' >> "$INPUT" ;;
  qr-skip) printf '3\ny\n' >> "$INPUT" ;;
  cancel) printf 'n\n' >> "$INPUT" ;;
  eof) : ;;
  *) printf 'y\n' >> "$INPUT" ;;
 esac
fi
if [[ $TEST == no-python-menu ]]; then
 cp "$INPUT" "$INPUT.tmp"; { echo 1; cat "$INPUT.tmp"; } > "$INPUT"
 node_menu < "$INPUT" > "$ROOT/$TEST.out" 2> "$ROOT/$TEST.err" || exit 1
elif [[ $TEST == init-* ]]; then
 cmd_init < "$INPUT" > "$ROOT/$TEST.out" 2> "$ROOT/$TEST.err" || exit 1
elif [[ $TEST == port-race || $TEST == core-failure || $TEST == recheck-failure || $TEST == swap-failure || $TEST == no-python-invalid-link ]]; then
 if cmd_node_add < "$INPUT" > "$ROOT/$TEST.out" 2> "$ROOT/$TEST.err"; then exit 1; fi
else
 cmd_node_add "$(if [[ $TEST == edit-relay ]]; then echo yes; else echo no; fi)" < "$INPUT" > "$ROOT/$TEST.out" 2> "$ROOT/$TEST.err" || exit 1
fi
assert not_contains FORBIDDEN
case "$TEST" in
 cancel|eof|type-return|swap-refuse|init-cancel)
  assert not_contains MUTATE
  assert test ! -e "$STACK_DIR/nodes"
  ;;
 port-race|core-failure|recheck-failure|swap-failure|no-python-invalid-link)
  assert test ! -e "$STACK_DIR/nodes"
  assert not_contains 'docker compose --project-directory'
  if [[ $TEST == port-race ]]; then assert not_contains 'MUTATE firewall'; assert test ! -e "$STACK_DIR/.node-sequence"; fi
  ;;
 init-ready) assert not_contains MUTATE ;;
 init-missing) assert contains 'MUTATE core-deps'; assert contains 'MUTATE Docker'; assert test ! -e "$STACK_DIR/nodes" ;;
 *)
  expected_id=1
  [[ $TEST != duplicate-path && $TEST != mixed-front && $TEST != same-domain ]] || expected_id=2
  assert test -f "$STACK_DIR/nodes/$expected_id/metadata.json"
  NODE_ID=$expected_id
  assert test "$(node_get label)" = 名称
  if [[ $TEST == same-domain ]]; then assert test "$(node_get front)" = caddy; else assert test "$(node_get front)" = nginx; fi
  assert test "$(node_get domain)" = one.example.com
  assert test "$(node_get port)" -ge 2333
  assert test "$(node_get path)" != auto
  assert test "$(node_get uuid)" != auto
  assert contains FINAL-CONFIRM
  assert test "$(rg -c '^CONFIRM ' "$LOG")" -le 2
  assert test "$(cat "$ROOT/$TEST.out")" != ''
  if [[ $TEST == edit-relay ]]; then
   assert test "$(node_get outbound)" = relay
   assert test "$(node_get image)" = "$OLD"
  fi
  ;;
esac
if [[ $TEST == qr-allow || $TEST == qr-default ]]; then assert contains epel-release-latest-9.noarch.rpm;
elif [[ $TEST == qr-native || $TEST == qr-failure ]]; then assert not_contains epel-release-latest-9.noarch.rpm;
elif [[ $TEST == qr-skip ]]; then assert not_contains 'MUTATE dnf'; fi
if [[ $TEST == swap-accept ]]; then assert contains 'MUTATE Swap'; fi
if [[ $TEST == ready || $TEST == nginx-result ]]; then
 assert not_contains core-deps
 assert not_contains 'MUTATE Docker'
 assert test "$(cat "$ROOT/$TEST.out")" != *'qrencode 安装'*
 assert test "$(cat "$ROOT/$TEST.out")" != ''
 [[ $(cat "$ROOT/$TEST.out") == *'Nginx HTTPS 转发待手工配置'* ]] || exit 1
fi
if [[ $TEST == same-domain ]]; then
 assert cmp "$ROOT/$TEST.first" "$STACK_DIR/nodes/1/metadata.json"
 assert test "$(node_get port)" != 2333
 assert test "$(node_get path)" != /first
 for route in v2ray-node-1:2333 v2ray-node-2:2333; do
  [[ $(cat "$STACK_DIR/ingress/Caddyfile") == *"$route"* ]] || exit 1
 done
fi
if [[ $TEST == ready || $TEST == no-python || $TEST == same-domain ]]; then
 [[ $(cat "$ROOT/$TEST.out") == *"本地端口：$(node_get port)"* ]] || exit 1
 [[ $(cat "$ROOT/$TEST.out") == *"路径：$(node_get path)"* ]] || exit 1
 [[ $(cat "$ROOT/$TEST.out") == *"UUID：$(node_get uuid)"* ]] || exit 1
fi
if [[ $TEST == invalid-fields ]]; then
 assert not_contains 'INPUT 本地端口 DEFAULT=auto'
 assert not_contains 'INPUT WebSocket 路径 DEFAULT=auto'
 assert not_contains 'INPUT UUID DEFAULT=auto'
fi
if [[ $TEST == invalid-fields ]]; then assert test "$(node_get path)" = /valid; assert test "$(node_get port)" = 2334; fi
if [[ $TEST == occupied-port ]]; then assert test "$(node_get port)" = 2334; fi
if [[ $TEST == duplicate-path ]]; then assert test "$(node_get path)" = /new-path; fi
if [[ $TEST == mixed-front ]]; then [[ $(cat "$ROOT/$TEST.err") == *'另一种 HTTPS 管理方式'* ]] || exit 1; fi
BASH
 [[ $status == 0 ]] || { printf 'FAIL %s\n' "$test" >&2; exit 1; }
 printf 'PASS %s\n' "$test"
done

# 实际 HTTPS 失败诊断不泄露响应正文，并保留 TLS 校验。
bash -s <<'BASH'
set -euo pipefail
source "$SCRIPT"
DOMAIN=example.com; WS_PATH=/redacted
caddy_rate_limit_hint(){ :; }
for status in 0 7 28 35 60; do
 curl(){ [[ $* != *' -k '* && $* != *--insecure* ]] || exit 99; printf '%s' 502; return "$status"; }
 result=$(ws_diagnose)
 case $status in
  0) [[ $result == *'HTTP 502'* ]] ;;
  7) [[ $result == *'无法连接本机 443'* ]] ;;
  28) [[ $result == *'超时'* ]] ;;
  35|60) [[ $result == *'TLS 握手或证书验证失败'* ]] ;;
 esac
 [[ $result != *"$WS_PATH"* ]] || exit 1
 printf 'PASS https-diagnostic-%s\n' "$status"
done
# 就绪等待超时后实际调用诊断，保持失败返回。
node_get(){ case $1 in front) echo caddy ;; domain) echo example.com ;; path) echo /redacted ;; esac; }
wait_for(){ [[ $1 == node_local_ok ]]; }
if node_ready > "$ROOT/readiness.out"; then exit 1; fi
[[ $(cat "$ROOT/readiness.out") == *'TLS 握手或证书验证失败'* ]]
echo 'PASS readiness-failure-diagnostic'
curl(){ printf 101; return 28; }
result=$(ws_diagnose)
[[ $result == *'追加诊断已返回 101'* ]]
echo 'PASS readiness-late-101-diagnostic'
BASH

# 证书预检仅执行读取；HTTP 错误不等同证书错误。
bash -s <<'BASH'
set -euo pipefail
source "$SCRIPT"
STACK_DIR="$ROOT/certificate-check"
LOG="$ROOT/certificate-read.events"
: > "$LOG"
CERT_STATUS=0; CERT_CODE=502; OWNER=v2ray-ingress; PRESENT=yes; VOLUME=yes
RAW=''; HAVE_PY=yes
command(){
 if [[ ${1:-} == -v ]]; then
  case "$2" in
   docker|curl|timeout) return 0 ;;
   openssl) return 1 ;;
   python3) [[ $HAVE_PY == yes ]] ;;
   *) builtin command "$@" ;;
  esac
 else builtin command "$@"; fi
}
timeout(){ shift; "$@"; }
curl(){
 [[ $1 == -q && $* == *"--noproxy *"* && $* == *'--resolve selected.example.com:443:127.0.0.1'* ]] || exit 99
 [[ $* != *--insecure* && $* != *--fail* ]] || exit 99
 echo "READ curl" >> "$LOG"
 printf '%s' "$CERT_CODE"; return "$CERT_STATUS"
}
docker(){
 echo "READ docker $1" >> "$LOG"
 case "$1" in
  inspect)
   [[ $PRESENT == yes ]] || return 1
   if [[ $* == *Config.Labels* ]]; then echo "$OWNER"; else echo 'volume custom_certificate_volume /var/lib/docker/volumes/custom_certificate_volume/_data'; fi ;;
  volume) [[ $VOLUME == yes ]] ;;
  logs) printf '%s\n' "$RAW" ;;
  *) exit 99 ;;
 esac
}
check(){ node_certificate_preflight selected.example.com "$1" 2>/dev/null; }
result=$(check caddy)
[[ $result == *'信任链验证（HTTP 502）'* && $result == *'custom_certificate_volume'* ]]
echo PASS certificate-trusted-http502-actual-volume
CERT_STATUS=60
result=$(check caddy)
[[ $result == *'证书可能过期'* ]]
echo PASS certificate-untrusted
CERT_STATUS=7; PRESENT=no; VOLUME=yes
result=$(check caddy)
[[ $result == *'预期证书卷 v2ray-ingress_node_caddy_data 已存在'* && $result == *'无法判断磁盘是否已有证书'* ]]
echo PASS certificate-offline-volume-exists
VOLUME=no
result=$(check caddy)
[[ $result == *'未确认存在'* ]]
echo PASS certificate-offline-volume-unknown
PRESENT=yes; OWNER=foreign
result=$(check caddy)
[[ $result == *'不是本项目资源'* && $result != *'custom_certificate_volume'* ]]
echo PASS certificate-foreign-container
OWNER=v2ray-ingress
: > "$LOG"
result=$(check nginx)
[[ $result == *'由现有 Nginx / 宝塔管理'* && $(cat "$LOG") != *docker* ]]
echo PASS certificate-nginx-no-caddy-read
RAW='{"identifier":"other.example.com","error":"urn:ietf:params:acme:error:rateLimited: retry after 2099-01-01 12:00:00 UTC"}'
result=$(check caddy)
[[ $result != *'最近有证书签发限流'* ]]
echo PASS certificate-limit-other-domain-ignored
RAW='{"identifier":"selected.example.com","error":"urn:ietf:params:acme:error:rateLimited: retry after 2099-01-01 12:00:00 UTC"}'
result=$(check caddy)
[[ $result == *'尚未到达'* && $result != *urn:ietf* ]]
echo PASS certificate-limit-selected-active
RAW=$'{"logger":"tls.obtain","identifier":"SELECTED.EXAMPLE.COM","error":"rateLimited: retry after 2099-01-01 12:00:00 UTC"}\n{"identifier":"selected.example.com","msg":"downloaded certificate chains"}'
result=$(check caddy)
[[ $result == *'尚未到达'* ]]
echo PASS certificate-limit-staging-download-not-success
RAW='{"identifier":"selected.example.com","error":"rateLimited: retry after 2000-01-01 12:00:00 UTC"}'
result=$(check caddy)
[[ $result == *'不能据此判断仍在限流'* ]]
echo PASS certificate-limit-past
RAW='{"identifier":"selected.example.com","error":"rateLimited"}'
result=$(check caddy)
[[ $result == *'当前状态需核实'* ]]
echo PASS certificate-limit-time-unknown
RAW=$'{"identifier":"selected.example.com","error":"rateLimited"}\n{"identifier":"selected.example.com","msg":"certificate obtained successfully"}'
result=$(check caddy)
[[ $result != *'当前状态需核实'* ]]
echo PASS certificate-limit-newer-success
RAW='{"identifier":"selected.example.com","error":"rateLimited"}'; CERT_STATUS=0
result=$(check caddy)
[[ $result == *'信任链验证'* && $result != *'限流记录'* ]]
echo PASS certificate-current-trust-supersedes-limit
CERT_STATUS=7; HAVE_PY=no
result=$(check caddy)
[[ $result != *'限流记录'* ]]
echo PASS certificate-no-python-unknown
[[ ! -e $STACK_DIR ]]
echo PASS certificate-readonly-no-stack-write
BASH
