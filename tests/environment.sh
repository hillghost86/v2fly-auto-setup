#!/usr/bin/env bash
# 新增节点环境检查仅使用模拟命令，不安装软件、不访问网络。
set -euo pipefail
cd "$(dirname "$0")/.."
SCRIPT="$PWD/v2fly-auto-setup.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export SCRIPT ROOT
for test in ready missing-deps missing-ca missing-python missing-curl missing-openssl missing-ss missing-ip no-docker no-compose stopped-daemon old-compose invalid-compose podman optional-qr unsupported-os compose-v-prefix memory-high memory-existing-swap memory-refuse memory-create memory-failure; do
 status=0
 bash -s -- "$test" <<'BASH' || status=$?
set -euo pipefail
source "$SCRIPT"
TEST=$1; STACK_DIR="$ROOT/$TEST/stack"; LOG="$ROOT/$TEST.log"; : > "$LOG"
MISSING_COMMAND=''
IN=0; HAVE_DEPS=yes; HAVE_CA=yes; HAVE_DOCKER=yes; HAVE_COMPOSE=yes; DAEMON=yes; COMPOSE_VERSION=2.24.7
case "$TEST" in
 missing-deps) HAVE_DEPS=no ;;
 missing-python|missing-curl|missing-openssl|missing-ss|missing-ip) MISSING_COMMAND=${TEST#missing-} ;;
 compose-v-prefix) COMPOSE_VERSION=v2.24.7 ;;
 missing-ca) HAVE_CA=no ;;
 no-docker) HAVE_DOCKER=no; HAVE_COMPOSE=no ;;
 no-compose) HAVE_COMPOSE=no ;;
 stopped-daemon) DAEMON=no ;;
 old-compose) COMPOSE_VERSION=2.20.0 ;;
 invalid-compose) COMPOSE_VERSION=invalid ;;
esac
OS_FILE="$ROOT/$TEST.os"
if [[ $TEST == unsupported-os ]]; then printf 'ID=arch\nVERSION_ID=rolling\n' > "$OS_FILE";
else printf 'ID=debian\nVERSION_ID=13\n' > "$OS_FILE"; fi
eval "$(declare -f detect_os | sed '1s/detect_os/detect_os_fixture/')"
detect_os(){ detect_os_fixture "$OS_FILE"; }
command(){
 if [[ ${1:-} == -v ]]; then
  [[ $2 != "$MISSING_COMMAND" ]] || return 1
  case "$2" in
   python3|curl) [[ $HAVE_DEPS == yes ]] ;;
   docker) [[ $HAVE_DOCKER == yes ]] ;;
   qrencode) [[ $TEST != optional-qr ]] ;;
   openssl|ss|ip|systemctl|apt-get) return 0 ;;
   *) builtin command "$@" ;;
  esac
 else builtin command "$@"; fi
}
dpkg(){ [[ $HAVE_CA == yes ]] && printf 'Status: install ok installed\n'; }
docker(){
 printf 'docker %s\n' "$*" >> "$LOG"
 case "$*" in
  --version) if [[ $TEST == podman ]]; then echo 'podman version 4'; else echo 'Docker version 20.10'; fi ;;
  'compose version') [[ $HAVE_COMPOSE == yes ]] ;;
  'compose version --short') echo "$COMPOSE_VERSION" ;;
  info) [[ $DAEMON == yes ]] ;;
  *) printf 'FORBIDDEN docker mutation\n' >> "$LOG"; exit 99 ;;
 esac
}
assert(){ "$@" || exit 1; }
# 检测入口不再读取用户输入或安装；执行计划由上层最终确认后调用。
if [[ $TEST == memory-* ]]; then
 MEM_FILE="$ROOT/$TEST.mem"; SWAPS_FILE="$ROOT/$TEST.swaps"
 printf 'MemTotal: 524288 kB\n' > "$MEM_FILE"
 printf 'Filename Type Size Used Priority\n' > "$SWAPS_FILE"
 [[ $TEST != memory-high ]] || printf 'MemTotal: 2097152 kB\n' > "$MEM_FILE"
 [[ $TEST != memory-existing-swap ]] || printf '/existing file 1048576 0 -2\n' >> "$SWAPS_FILE"
 eval "$(declare -f needs_swap | sed '1s/needs_swap/needs_swap_fixture/')"
 needs_swap(){ needs_swap_fixture "$MEM_FILE" "$SWAPS_FILE"; }
 PLAN_SWAP=no
 create_swap(){ printf 'create-swap\n' >> "$LOG"; [[ $TEST != memory-failure ]]; }
 if [[ $TEST == memory-refuse ]]; then
  if plan_low_memory <<< n; then exit 1; fi
  [[ $(cat "$LOG") != *create-swap* ]] || exit 1
 else
  plan_low_memory <<< y || exit 1
  [[ $(cat "$LOG") != *create-swap* ]] || exit 1
  if [[ $TEST == memory-failure ]]; then
   if execute_low_memory; then exit 1; fi
  else execute_low_memory || exit 1; fi
  if [[ $TEST == memory-high || $TEST == memory-existing-swap ]]; then [[ ! -s $LOG ]] || exit 1; fi
 fi
else
 preflight
 if [[ $TEST == old-compose || $TEST == invalid-compose ]]; then
  if check_node_environment; then exit 1; else assert test "$?" = 2; fi
 elif [[ $TEST == ready || $TEST == optional-qr || $TEST == compose-v-prefix ]]; then
  check_node_environment || exit 1
  assert test "${#ENV_MISSING[@]}" = 0
 else
  if check_node_environment; then exit 1; else assert test "$?" = 1; fi
  assert test "${#ENV_MISSING[@]}" -gt 0
 fi
 [[ $(cat "$LOG") != *FORBIDDEN* && $(cat "$LOG") != *confirmation* ]] || exit 1
fi
[[ ! -e $STACK_DIR ]] || exit 1

BASH
 case "$test" in
  podman|unsupported-os) [[ $status == 1 && $(cat "$ROOT/$test.log") != *install-* && $(cat "$ROOT/$test.log") != *confirmation* && ! -e $ROOT/$test/stack ]] ;;
  *) [[ $status == 0 ]] ;;
 esac
 printf 'PASS %s\n' "$test"
done
