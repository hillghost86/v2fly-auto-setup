#!/usr/bin/env bash
# 二维码按需安装入口：系统、APT、DNF、Swap 均模拟，不访问网络。
set -euo pipefail
cd "$(dirname "$0")/.."
SCRIPT="$PWD/v2fly-auto-setup.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export SCRIPT ROOT
for test in installed refuse eof debian debian-failure el9-native el9-epel el9-epel-refuse el9-epel-failure el9-package-failure unknown-os memory-refuse repeat plain previous-attempt; do
 bash -s -- "$test" <<'BASH'
set -euo pipefail
source "$SCRIPT"
TEST=$1; STACK_DIR="$ROOT/$TEST"; NODE_ID=1; LOG="$ROOT/$TEST.log"; : > "$LOG"
U=11111111-2222-4333-8444-555555555555
node_python create 1 one.example.com nginx direct 2333 /one "$U" v2fly/v2fly-core:latest
IN=0; HAVE_QR=no; HAVE_EPEL=no; OS_FAMILY=''
[[ $TEST != installed ]] || HAVE_QR=yes
[[ $TEST != previous-attempt ]] || QR_INSTALL_ATTEMPTED=yes
command(){ if [[ $* == '-v qrencode' ]]; then [[ $HAVE_QR == yes ]]; else builtin command "$@"; fi; }
detect_os(){ printf 'detect-os\n' >> "$LOG"; if [[ $TEST == unknown-os ]]; then return 1; elif [[ $TEST == el9-* ]]; then OS_FAMILY=el9; else OS_FAMILY=debian; fi; }
prepare_low_memory(){ printf 'memory-check\n' >> "$LOG"; [[ $TEST != memory-refuse ]]; }
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
# 记录提示，保留真实默认N与EOF行为。
eval "$(declare -f confirm | sed '1s/confirm/confirm_original/')"
confirm(){ printf 'confirm %s\n' "$1" >> "$LOG"; confirm_original "$@"; }
case "$TEST" in
 plain) node_show plain </dev/null > "$ROOT/$TEST.output" ;;
 refuse) node_show <<< 'n' > "$ROOT/$TEST.output" ;;
 eof) node_show </dev/null > "$ROOT/$TEST.output" ;;
 el9-epel-refuse) node_show > "$ROOT/$TEST.output" <<'INPUT'
y
n
INPUT
 ;;
 *) node_show > "$ROOT/$TEST.output" <<'INPUT'
y
y
INPUT
 ;;
esac
[[ $(cat "$ROOT/$TEST.output") == *vmess://* ]]
case "$TEST" in
 installed) [[ $(cat "$LOG") == *'qr -l M -t ANSIUTF8'* && $(cat "$LOG") != *confirm* && $(cat "$LOG") != *memory-check* ]] ;;
 plain|previous-attempt) [[ ! -s $LOG ]] ;;
 refuse|eof) [[ $(cat "$LOG") == *'confirm 是否安装二维码工具'* && $(cat "$LOG") != *memory-check* && $(cat "$LOG") != *apt* && $(cat "$LOG") != *dnf* ]] ;;
 debian) [[ $(cat "$LOG") == *'apt install -y -qq qrencode'* && $(cat "$LOG") == *'qr -l M -t ANSIUTF8'* && $(cat "$LOG") != *docker* ]] ;;
 el9-native) [[ $(cat "$LOG") == *'dnf install -y qrencode'* && $(cat "$LOG") != *EPEL* && $(cat "$LOG") == *'qr -l M -t ANSIUTF8'* ]] ;;
 el9-epel) [[ $(cat "$LOG") == *'confirm 当前源无可用 qrencode'* && $(cat "$LOG") == *'dnf install -y https://dl.fedoraproject.org/'* && $(cat "$LOG") == *'qr -l M -t ANSIUTF8'* ]] ;;
 el9-epel-refuse) [[ $(cat "$LOG") != *'dnf install -y https://'* && $(cat "$LOG") != *'qr -l '* ]] ;;
 unknown-os)
  [[ $(cat "$LOG") != *memory-check* && $(cat "$LOG") != *apt* && $(cat "$LOG") != *dnf* && $(cat "$LOG") != *'qr -l '* && -z $OS_FAMILY ]]
  ;;
 memory-refuse) [[ $(cat "$LOG") != *apt* && $(cat "$LOG") != *dnf* && $(cat "$LOG") != *'qr -l '* ]] ;;
 debian-failure|el9-epel-failure|el9-package-failure) [[ $(cat "$LOG") != *'qr -l '* ]] ;;
 repeat)
  HAVE_QR=no
  : > "$LOG"
  node_show </dev/null >/dev/null
  [[ ! -s $LOG ]]
  ;;
esac
BASH
 printf 'PASS %s\n' "$test"
done
