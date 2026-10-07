#!/usr/bin/env bash
# 二维码按需安装入口：系统、APT、DNF、Swap 均模拟，不访问网络。
set -euo pipefail
cd "$(dirname "$0")/.."
SCRIPT="$PWD/v2fly-auto-setup.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export SCRIPT ROOT
for test in installed skip missing-show debian debian-failure el9-native el9-epel el9-native-skip el9-epel-failure el9-package-failure show-no-os show-no-swap repeat plain skip-pure; do
 bash -s -- "$test" <<'BASH'
set -euo pipefail
source "$SCRIPT"
TEST=$1; STACK_DIR="$ROOT/$TEST"; NODE_ID=1; LOG="$ROOT/$TEST.log"; : > "$LOG"
U=11111111-2222-4333-8444-555555555555
node_python create 1 one.example.com nginx direct 2333 /one "$U" v2fly/v2fly-core:latest
IN=0; HAVE_QR=no; HAVE_EPEL=no; OS_FAMILY=''
[[ $TEST != installed ]] || HAVE_QR=yes
command(){ if [[ $* == '-v qrencode' ]]; then [[ $HAVE_QR == yes ]]; else builtin command "$@"; fi; }
detect_os(){ printf 'detect-os\n' >> "$LOG"; if [[ $TEST == show-no-os ]]; then return 1; elif [[ $TEST == el9-* ]]; then OS_FAMILY=el9; else OS_FAMILY=debian; fi; }
needs_swap(){ printf 'memory-check\n' >> "$LOG"; [[ $TEST != show-no-swap ]]; }
tput(){ echo 120; }
qrencode(){ cat >/dev/null; printf 'qr %s\n' "$*" >> "$LOG"; if [[ $* == *ASCII* ]]; then printf '%060d\n' 0; else echo rendered-qr; fi; }
apt-get(){
 printf 'apt %s\n' "$*" >> "$LOG"
 [[ $TEST != debian-failure ]] || return 1
 [[ $* != 'install -y -qq qrencode' ]] || HAVE_QR=yes
}
rpm(){ [[ $HAVE_EPEL == yes ]]; }
dnf(){
 printf 'dnf %s\n' "$*" >> "$LOG"
 if [[ $* == *epel-release-latest-9.noarch.rpm* ]]; then
  [[ $TEST != el9-epel-failure ]] || return 1
  HAVE_EPEL=yes
 elif [[ $TEST == el9-native || $HAVE_EPEL == yes ]]; then
  [[ $TEST != el9-package-failure ]] || return 1
  HAVE_QR=yes
 else return 1; fi
}
confirm(){ printf 'FORBIDDEN confirm\n' >> "$LOG"; return 99; }
# 显式执行已确认的策略；展示函数始终只读。
policy=native
case "$TEST" in
 skip|missing-show|plain|skip-pure|show-no-os|show-no-swap) policy=skip ;;
 el9-epel|el9-epel-failure|el9-package-failure) policy=allow ;;
esac
if [[ $TEST == el9-* ]]; then OS_FAMILY=el9; else OS_FAMILY=debian; fi
if [[ $TEST != installed && $TEST != plain ]]; then install_optional_qr "$policy" || exit 1; fi
node_show > "$ROOT/$TEST.output" </dev/null || exit 1
[[ $(cat "$ROOT/$TEST.output") == *vmess://* && $(cat "$LOG") != *FORBIDDEN* && $(cat "$LOG") != *memory-check* ]] || exit 1
case "$TEST" in
 installed) [[ $(cat "$LOG") == *'qr -l M -t ANSIUTF8'* && $(cat "$LOG") != *apt* ]] || exit 1 ;;
 plain)
  : > "$LOG"; node_show plain </dev/null >/dev/null || exit 1; [[ ! -s $LOG ]] || exit 1 ;;
 skip|missing-show|skip-pure|show-no-os|show-no-swap) [[ ! -s $LOG ]] || exit 1 ;;
 debian) [[ $(cat "$LOG") == *'apt install -y -qq qrencode'* && $(cat "$LOG") == *'qr -l M -t ANSIUTF8'* ]] || exit 1 ;;
 el9-native) [[ $(cat "$LOG") == *'dnf install -y qrencode'* && $(cat "$LOG") != *epel-release* && $(cat "$LOG") == *'qr -l M -t ANSIUTF8'* ]] || exit 1 ;;
 el9-epel) [[ $(cat "$LOG") == *'dnf install -y https://dl.fedoraproject.org/'* && $(cat "$LOG") == *'qr -l M -t ANSIUTF8'* ]] || exit 1 ;;
 el9-native-skip) [[ $(cat "$LOG") != *'dnf install -y https://'* && $(cat "$LOG") != *'qr -l '* ]] || exit 1 ;;
 debian-failure|el9-epel-failure|el9-package-failure) [[ $(cat "$LOG") != *'qr -l '* ]] || exit 1 ;;
 repeat)
  HAVE_QR=no; : > "$LOG"; node_show </dev/null >/dev/null || exit 1
  [[ ! -s $LOG ]] || exit 1 ;;
esac

BASH
 printf 'PASS %s\n' "$test"
done
