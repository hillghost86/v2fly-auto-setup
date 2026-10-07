#!/usr/bin/env bash
# 管理功能模拟：不运行真实容器、网络或软件安装。
set -euo pipefail
cd "$(dirname "$0")/.."
SCRIPT="$PWD/v2fly-auto-setup.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export SCRIPT ROOT
for test in success pull validate up health cancel foreign missing nginx signal rollback-failure status status-missing status-certificate-failure qr-wide qr-fallback qr-narrow qr-missing qr-failure qr-render-failure; do
 status=0
 bash -s -- "$test" <<'BASH' || status=$?
set -euo pipefail
source "$SCRIPT"
TEST=$1; STACK_DIR="$ROOT/$TEST"; mkdir -p "$STACK_DIR"
LOG="$STACK_DIR/effects"; : > "$LOG"
OLD=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
U=11111111-2222-4333-8444-555555555555
step(){ :; }; grn(){ printf '%s\n' "$*"; }; ylw(){ printf '%s\n' "$*"; }; red(){ printf '%s\n' "$*"; }
need_docker(){ :; }; sleep(){ :; }
confirm(){ [[ $TEST != cancel ]]; }
docker(){
 printf '%s\n' "$*" >> "$LOG"
 if [[ $1 == inspect && ( $TEST == missing || $TEST == status-missing ) ]]; then return 1; fi
 case "$*" in
  *com.docker.compose.project*) if [[ $TEST == foreign ]]; then echo unrelated; elif [[ ${*: -1} == v2ray-ingress ]]; then echo v2ray-ingress; else echo "${*: -1}"; fi ;;
  *'{{.Image}}'*) echo "$OLD" ;;
  *'{{.State.Status}}'*) echo running ;;
  'exec '*version) echo 'mock version 1' ;;
  'run '*)
   local previous='' argument
   for argument in "$@"; do [[ $previous != --cidfile ]] || echo own-caddy-check > "$argument"; previous=$argument; done
   [[ $* != *"$STACK_DIR/ingress:/managed"* && $* == *'--network none'* && $* == *'--cidfile'* ]] || return 99
   [[ $TEST != validate ]]
   ;;
  'inspect '*) [[ $TEST != missing && $TEST != status-missing ]] ;;
 esac
}
ingress_compose(){
 printf 'ingress %s\n' "$*" >> "$LOG"
 case "$1" in
  pull) [[ $TEST != pull ]] ;;
  run) [[ $TEST != validate ]] ;;
  up)
   if [[ $TEST == signal && $(cat "$STACK_DIR/ingress.yaml") != *"$OLD"* ]]; then kill -TERM "$$"; fi
   if [[ $TEST == rollback-failure ]]; then return 1; fi
   [[ $TEST != up || $(cat "$STACK_DIR/ingress.yaml") == *"$OLD"* ]]
   ;;
 esac
}
ingress_ready(){ [[ $TEST != health || $(cat "$STACK_DIR/ingress.yaml") == *"$OLD"* ]]; }
if [[ $TEST == qr-* ]]; then
 NODE_ID=1
 node_python create 1 one.example.com nginx direct 2333 /one "$U" v2fly/v2fly-core:latest
 command(){ if [[ $* == '-v qrencode' ]]; then [[ $TEST != qr-missing ]]; else builtin command "$@"; fi; }
 tput(){ case "$TEST" in qr-wide|qr-failure|qr-render-failure) echo 100 ;; qr-fallback) echo 30 ;; *) echo 10 ;; esac; }
 qrencode(){
  cat >/dev/null
  printf 'qr %s\n' "$*" >> "$LOG"
  [[ $TEST != qr-failure ]] || return 1
  if [[ $* == *ASCII* ]]; then
   if [[ $* == *'-l M'* ]]; then printf '%080d\n' 0; else printf '%050d\n' 0; fi
  elif [[ $TEST == qr-render-failure ]]; then return 1
  else printf 'QR image\n'; fi
 }
 node_show > "$STACK_DIR/display"
 [[ $(cat "$STACK_DIR/display") == *vmess://* ]]
 case "$TEST" in
  qr-wide) [[ $(cat "$LOG") == *'qr -l M -t ANSIUTF8'* ]] ;;
  qr-fallback) [[ $(cat "$LOG") == *'qr -l L -t ANSIUTF8'* ]] ;;
  qr-narrow) [[ $(cat "$LOG") != *ANSIUTF8* && $(cat "$STACK_DIR/display") == *'终端宽度不足'* ]] ;;
  qr-missing) [[ ! -s $LOG ]] ;;
  qr-failure) [[ $(cat "$STACK_DIR/display") == *'二维码生成失败'* ]] ;;
  qr-render-failure) [[ $(cat "$STACK_DIR/display") == *'二维码显示失败'* ]] ;;
 esac
 : > "$LOG"
 node_show plain >/dev/null
 [[ ! -s $LOG ]]
 exit 0
fi
front=caddy; [[ $TEST != nginx ]] || front=nginx
node_python create 1 one.example.com "$front" direct 2333 /one "$U" v2fly/v2fly-core:latest
node_python create 2 one.example.com "$front" direct 2334 /two "$U" v2fly/v2fly-core:latest
node_python ingress
if [[ $TEST == status || $TEST == status-missing || $TEST == status-certificate-failure ]]; then
 timeout(){ printf 'timeout %s\n' "$*" >> "$LOG"; [[ $TEST != status-certificate-failure ]] || return 124; shift; "$@"; }
 openssl(){
  printf 'openssl %s\n' "$*" >> "$LOG"
  if [[ $1 == s_client ]]; then echo 'mock certificate'; else cat >/dev/null; printf 'issuer=mock\nnotAfter=tomorrow\n'; fi
 }
 cmd_nodes_status > "$STACK_DIR/status"
 [[ $(cat "$LOG") != *'compose '* && $(cat "$LOG") != *' pull '* && $(cat "$LOG") != *' run '* ]]
 if [[ $TEST != status-certificate-failure ]]; then
  [[ $(rg -c 'openssl s_client.*-servername one.example.com' "$LOG") == 1 ]]
 fi
 [[ $(rg -c 'timeout 8 openssl s_client.*-servername one.example.com' "$LOG") == 1 ]]
 if [[ $TEST == status ]]; then
  [[ $(cat "$STACK_DIR/status") == *'程序版本：mock version 1'* && $(cat "$STACK_DIR/status") == *issuer=mock* && $(cat "$STACK_DIR/status") == *v2ray-ingress* ]]
 elif [[ $TEST == status-missing ]]; then [[ $(cat "$STACK_DIR/status") == *'容器不存在或无法读取'* ]]
 else [[ $(cat "$STACK_DIR/status") == *'证书读取失败'* ]]; fi
 exit 0
fi
if cmd_ingress_update > "$STACK_DIR/output"; then
 [[ $TEST == success || $TEST == cancel || $TEST == nginx ]]
else
 [[ $TEST != success && $TEST != cancel && $TEST != nginx && $TEST != signal ]]
fi
case "$TEST" in
 success)
  [[ $(cat "$LOG") == *'ingress up -d --no-deps --force-recreate --pull never caddy'* ]]
  [[ $(cat "$LOG") != *'node=2'* && $(cat "$LOG") != *' down'* ]]
  [[ $(cat "$LOG") == *'--network none --cidfile'* && $(cat "$LOG") != *"$STACK_DIR/ingress:/managed"* ]]
  [[ ${#E2E_CID_FILES[@]} == 1 && $(cat "${E2E_CID_FILES[0]}") == own-caddy-check ]]
  [[ $(cat "$STACK_DIR/ingress/metadata.json") == *caddy:2* ]]
  [[ $(find "$STACK_DIR" -name '.ingress-recovery.*' | wc -l | tr -d ' ') == 0 ]]
  ;;
 cancel|foreign|missing|nginx) [[ $(cat "$LOG") != *'ingress pull'* && $(cat "$LOG") != *'ingress up'* ]] ;;
 pull|validate|up|health|rollback-failure)
  [[ $INGRESS_TX_ACTIVE == no && -d $INGRESS_TX_BACKUP ]]
  [[ $(cat "$STACK_DIR/ingress/metadata.json") == *"$OLD"* ]]
  node_python ingress
  [[ $(cat "$STACK_DIR/ingress.yaml") == *"$OLD"* ]]
  if [[ $TEST == pull ]]; then [[ $(cat "$LOG") != *'ingress up'* ]]; fi
  if [[ $TEST == rollback-failure ]]; then [[ $(cat "$STACK_DIR/output") == *'共享入口恢复失败'* ]]; fi
  ;;
esac
BASH
 if [[ $test == signal ]]; then
  [[ $status == 143 ]]
  [[ $(cat "$ROOT/$test/ingress/metadata.json") == *sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa* ]]
  [[ $(rg -c '^ingress up ' "$ROOT/$test/effects") == 2 ]]
 else [[ $status == 0 ]]; fi
 printf 'PASS %s\n' "$test"
done
