#!/usr/bin/env bash
# 实际分阶段入口 + 模拟系统执行，断言最终确认之前零写操作、之后零输入。
set -euo pipefail
cd "$(dirname "$0")/.."
SCRIPT="$PWD/v2fly-auto-setup.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export SCRIPT ROOT
for test in ready cancel eof type-return invalid-fields occupied-port duplicate-path mixed-front no-python no-python-menu invalid-link remote-invalid no-python-invalid-link missing-core core-failure recheck-failure swap-accept swap-refuse swap-failure qr-allow qr-native qr-skip qr-failure edit-relay nginx-result init-ready init-cancel init-missing; do
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
 event "INPUT $1"
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
  compose)
   if [[ $* == 'compose version --short' ]]; then echo 2.24.7;
   elif [[ $* == 'compose version' ]]; then :;
   else mutate "docker $*"; fi ;;
  *) mutate "docker $*" ;;
 esac
}
ss(){ :; }
port_in_use(){ [[ $TEST == occupied-port && $1 == 2999 ]]; }
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
node_ingress_apply(){ :; }
node_ready(){ :; }
INPUT="$ROOT/$TEST.input"
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
if [[ $TEST == edit-relay ]]; then
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
elif [[ $TEST == core-failure || $TEST == recheck-failure || $TEST == swap-failure || $TEST == no-python-invalid-link ]]; then
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
 core-failure|recheck-failure|swap-failure|no-python-invalid-link)
  assert test ! -e "$STACK_DIR/nodes"
  assert not_contains 'docker compose --project-directory'
  ;;
 init-ready) assert not_contains MUTATE ;;
 init-missing) assert contains 'MUTATE core-deps'; assert contains 'MUTATE Docker'; assert test ! -e "$STACK_DIR/nodes" ;;
 *)
  expected_id=1
  [[ $TEST != duplicate-path && $TEST != mixed-front ]] || expected_id=2
  assert test -f "$STACK_DIR/nodes/$expected_id/metadata.json"
  NODE_ID=$expected_id
  assert test "$(node_get label)" = 名称
  assert test "$(node_get front)" = nginx
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
if [[ $TEST == qr-allow ]]; then assert contains epel-release-latest-9.noarch.rpm;
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
if [[ $TEST == invalid-fields ]]; then assert test "$(node_get path)" = /valid; assert test "$(node_get port)" = 2334; fi
if [[ $TEST == occupied-port ]]; then assert test "$(node_get port)" = 2334; fi
if [[ $TEST == duplicate-path ]]; then assert test "$(node_get path)" = /new-path; fi
if [[ $TEST == mixed-front ]]; then [[ $(cat "$ROOT/$TEST.err") == *'另一种 HTTPS 管理方式'* ]] || exit 1; fi
BASH
 [[ $status == 0 ]] || { printf 'FAIL %s\n' "$test" >&2; exit 1; }
 printf 'PASS %s\n' "$test"
done
