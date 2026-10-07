#!/usr/bin/env bash
# 新增节点环境检查仅使用模拟命令，不安装软件、不访问网络。
set -euo pipefail
cd "$(dirname "$0")/.."
SCRIPT="$PWD/v2fly-auto-setup.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export SCRIPT ROOT
for test in ready missing-deps missing-ca refuse eof install-failure recheck-failure no-docker no-compose stopped-daemon old-compose invalid-compose podman optional-qr unsupported-os edit-no-install memory-high memory-existing-swap memory-refuse memory-create memory-failure; do
 status=0
 bash -s -- "$test" <<'BASH' || status=$?
set -euo pipefail
source "$SCRIPT"
TEST=$1; STACK_DIR="$ROOT/$TEST/stack"; LOG="$ROOT/$TEST.log"; : > "$LOG"
IN=0; HAVE_DEPS=yes; HAVE_CA=yes; HAVE_DOCKER=yes; HAVE_COMPOSE=yes; DAEMON=yes; COMPOSE_VERSION=2.24.7
case "$TEST" in
 missing-deps|refuse|eof|install-failure|recheck-failure|edit-no-install) HAVE_DEPS=no ;;
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
# Shared initializer remains real; host mutations in each stage are mocked.
eval "$(declare -f prepare_low_memory | sed '1s/prepare_low_memory/prepare_low_memory_fixture/')"
MEM_FILE="$ROOT/$TEST.mem"; SWAPS_FILE="$ROOT/$TEST.swaps"
printf 'MemTotal: 524288 kB\n' > "$MEM_FILE"
printf 'Filename Type Size Used Priority\n' > "$SWAPS_FILE"
[[ $TEST != memory-high ]] || printf 'MemTotal: 2097152 kB\n' > "$MEM_FILE"
[[ $TEST != memory-existing-swap ]] || printf '/existing file 1048576 0 -2\n' >> "$SWAPS_FILE"
prepare_low_memory(){
 printf 'prepare-memory\n' >> "$LOG"
 if [[ $TEST == memory-* ]]; then prepare_low_memory_fixture "$MEM_FILE" "$SWAPS_FILE"; fi
}
create_swap(){ printf 'create-swap\n' >> "$LOG"; [[ $TEST != memory-failure ]]; }
install_deps(){
 printf 'install-deps\n' >> "$LOG"
 [[ $TEST != install-failure ]] || return 1
 if [[ $TEST != recheck-failure ]]; then HAVE_DEPS=yes; HAVE_CA=yes; fi
}
install_docker(){ printf 'install-docker\n' >> "$LOG"; HAVE_DOCKER=yes; HAVE_COMPOSE=yes; DAEMON=yes; }
node_choice(){ printf 'node-type\n' >> "$LOG"; printf 0; }
open_firewall(){ printf 'FORBIDDEN firewall\n' >> "$LOG"; exit 99; }
# 记录真实 confirm 调用；不替代读取和默认值。
eval "$(declare -f confirm | sed '1s/confirm/confirm_fixture/')"
confirm(){ printf 'confirmation\n' >> "$LOG"; confirm_fixture "$@"; }
if [[ $TEST == edit-no-install ]]; then
 NODE_ID=1
 if cmd_node_add yes </dev/null > "$ROOT/$TEST.output"; then exit 1; fi
elif [[ $TEST == refuse || $TEST == memory-refuse ]]; then
 if cmd_node_add <<< 'n' > "$ROOT/$TEST.output"; then exit 1; fi
elif [[ $TEST == eof ]]; then
 if cmd_node_add </dev/null > "$ROOT/$TEST.output"; then exit 1; fi
elif [[ $TEST == install-failure || $TEST == recheck-failure || $TEST == old-compose || $TEST == invalid-compose || $TEST == memory-failure ]]; then
 if cmd_node_add <<< 'y' > "$ROOT/$TEST.output"; then exit 1; fi
else
 cmd_node_add <<< 'y' > "$ROOT/$TEST.output"
fi
[[ ! -e $STACK_DIR && $(cat "$LOG") != *FORBIDDEN* ]]
case "$TEST" in
 ready|optional-qr|memory-high|memory-existing-swap)
  [[ $(cat "$LOG") == *node-type* && $(cat "$LOG") != *confirmation* && $(cat "$LOG") != *install-* && $(rg -c '^prepare-memory$' "$LOG") == 1 ]]
  ;;
 missing-deps|missing-ca|no-docker|no-compose|stopped-daemon)
  [[ $(rg -c '^confirmation$' "$LOG") == 1 && $(rg -c '^install-deps$' "$LOG") == 1 && $(rg -c '^install-docker$' "$LOG") == 1 ]]
  [[ $(tail -1 "$LOG") == node-type && $(rg -c '^prepare-memory$' "$LOG") == 1 ]]
  [[ $(cat "$ROOT/$TEST.output") == *'创建节点前需要补齐'* ]]
  ;;
 refuse|eof|memory-refuse)
  [[ $(cat "$LOG") == *confirmation* && $(cat "$LOG") != *install-* && $(cat "$LOG") != *node-type* ]]
  ;;
 memory-create)
  [[ $(rg -c '^confirmation$' "$LOG") == 1 && $(rg -c '^create-swap$' "$LOG") == 1 && $(cat "$LOG") == *node-type* && $(cat "$LOG") != *install-* ]]
  ;;
 memory-failure)
  [[ $(cat "$LOG") == *create-swap* && $(cat "$LOG") != *node-type* && $(cat "$LOG") != *install-* ]]
  ;;
 install-failure)
  [[ $(cat "$LOG") == *install-deps* && $(cat "$LOG") != *install-docker* && $(cat "$LOG") != *node-type* ]]
  ;;
 recheck-failure)
  [[ $(cat "$LOG") == *install-docker* && $(cat "$LOG") != *node-type* && $(cat "$ROOT/$TEST.output") == *'环境复检未通过'* ]]
  ;;
 old-compose|invalid-compose)
  [[ $(cat "$LOG") != *confirmation* && $(cat "$LOG") != *install-* && $(cat "$LOG") != *node-type* && $(cat "$ROOT/$TEST.output") == *'请手动升级'* ]]
  ;;
 edit-no-install)
  [[ $(cat "$LOG") != *confirmation* && $(cat "$LOG") != *install-* && $(cat "$LOG") != *node-type* ]]
  ;;
esac
BASH
 case "$test" in
  podman|unsupported-os) [[ $status == 1 && $(cat "$ROOT/$test.log") != *install-* && $(cat "$ROOT/$test.log") != *confirmation* && ! -e $ROOT/$test/stack ]] ;;
  *) [[ $status == 0 ]] ;;
 esac
 printf 'PASS %s\n' "$test"
done
