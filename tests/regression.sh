#!/usr/bin/env bash
# 仅模拟初始化、CLI、Docker 与网络，不安装依赖、不修改系统。
set -euo pipefail
cd "$(dirname "$0")/.."
SCRIPT="$PWD/v2fly-auto-setup.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export SCRIPT ROOT
bash <<'BASH'
set -euo pipefail
source "$SCRIPT"
STACK_DIR="$ROOT/stack"
step(){ :; }; grn(){ :; }; ylw(){ :; }; red(){ :; }
LOG="$ROOT/effects"
# 初始化拒绝与接受：仅准备环境，不创建节点或改防火墙。
preflight(){ printf 'preflight\n' >> "$LOG"; }
collect_environment_plan(){ PLAN_CORE=yes; PLAN_SWAP=yes; PLAN_QR=skip; ENV_MISSING=(deps); }
plan_low_memory(){ :; }; plan_qrencode(){ :; }; check_node_environment(){ return 0; }
execute_low_memory(){ printf 'memory\n' >> "$LOG"; }
install_deps(){ printf 'deps\n' >> "$LOG"; }
install_docker(){ printf 'docker\n' >> "$LOG"; }
open_firewall(){ printf 'FORBIDDEN firewall\n' >> "$LOG"; return 1; }
confirm(){ return 1; }
cmd_init
[[ $(cat "$LOG") == preflight && ! -e $STACK_DIR ]]
echo 'PASS init-refusal-no-mutation'
: > "$LOG"
confirm(){ return 0; }
cmd_init
[[ $(cat "$LOG" | tr '\n' ' ') == 'preflight memory deps docker ' && ! -e $STACK_DIR ]]
echo 'PASS init-only-environment-in-order'
# 初始化失败不能继续安装 Docker。
: > "$LOG"
install_deps(){ printf 'deps-failure\n' >> "$LOG"; return 1; }
if cmd_init; then exit 1; fi
[[ $(cat "$LOG") != *docker* ]]
echo 'PASS init-stops-after-dependency-failure'
# CLI 统一分派；更新先选节点、检查 Docker。
need_root(){ printf 'root %s\n' "${1:-menu}" >> "$LOG"; }
need_docker(){ printf 'need-docker\n' >> "$LOG"; }
node_select(){ NODE_ID=7; printf 'select\n' >> "$LOG"; }
cmd_init(){ printf 'init\n' >> "$LOG"; }
cmd_node_add(){ printf 'add\n' >> "$LOG"; }
cmd_node_manage(){ printf 'manage\n' >> "$LOG"; }
cmd_nodes_status(){ printf 'nodes\n' >> "$LOG"; }
cmd_node_update(){ [[ $NODE_ID == 7 ]]; printf 'update\n' >> "$LOG"; }
cmd_node_delete(){ printf 'delete\n' >> "$LOG"; }
node_menu(){ printf 'menu\n' >> "$LOG"; }
for action in init node-add node-manage nodes node-update node-delete ''; do main "$action"; done
[[ $(cat "$LOG") == *$'root node-update\nneed-docker\nselect\nupdate'* ]]
[[ $(cat "$LOG") == *$'root menu\nmenu'* ]]
echo 'PASS unified-cli-and-selected-update'
for old in install update status show uninstall; do
 if (main "$old") > "$ROOT/unknown" 2>&1; then exit 1; fi
 [[ $(cat "$ROOT/unknown") == *'init node-add node-manage nodes node-update node-delete'* ]]
done
echo 'PASS legacy-cli-removed'
# 新服务器没有 Python 也能进入初始化入口。
eval "$(sed -n '/^node_menu() {/,/^}/p' "$SCRIPT")"
command(){ if [[ $* == '-v python3' ]]; then return 1; else builtin command "$@"; fi; }
printf '6\n0\n' > "$ROOT/menu-choices"
node_choice(){ local next; next=$(head -1 "$ROOT/menu-choices"); tail -n +2 "$ROOT/menu-choices" > "$ROOT/menu-choices.next"; mv "$ROOT/menu-choices.next" "$ROOT/menu-choices"; printf '%s' "$next"; }
node_python(){ return 99; }
node_menu > "$ROOT/menu"
[[ $(cat "$ROOT/menu") == *$'\n------------------------------\n\n1) 新增节点'* && $(cat "$ROOT/menu") == *'6) 初始化环境'* && $(cat "$LOG") == *init* ]]
echo 'PASS menu-without-python-permits-init'
BASH

# 独立进程验证临时测试资源与镜像下载校验。
for test in temp e2e run plugin engine checksum; do
 status=0
 bash -s -- "$test" <<'BASH' || status=$?
set -euo pipefail
source "$SCRIPT"
TEST=$1; OS_FAMILY=debian; LOG="$ROOT/$TEST.log"; : > "$LOG"
step(){ :; }; grn(){ :; }; ylw(){ :; }; red(){ :; }
if [[ $TEST == temp ]]; then
 mktmp temporary
 [[ -d $temporary && ${#TMP_DIRS[@]} == 1 ]]
 cleanup
 [[ ! -e $temporary ]]
 exit 0
fi
if [[ $TEST == e2e || $TEST == run ]]; then
 DOMAIN=test.example.com; UUID=test-only; WS_PATH=/test; E2E_IMAGE=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
 sleep(){ :; }; curl(){ echo 204; }
 docker(){
  printf '%s\n' "$*" >> "$LOG"
  case "$1" in
   run) local previous='' argument; for argument in "$@"; do [[ $previous != --cidfile ]] || echo owned-container > "$argument"; previous=$argument; done; [[ $TEST != run ]] ;;
   port) echo 127.0.0.1:12345 ;;
  esac
 }
 if e2e_ok; then [[ $TEST == e2e ]]; else [[ $TEST == run ]]; fi
 [[ $(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode&0o777))' "${TMP_DIRS[0]}") == 0o700 ]]
 [[ $(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode&0o777))' "${TMP_DIRS[0]}/config.json") == 0o600 ]]
 cleanup
 [[ $(cat "$LOG") == *'rm -f owned-container'* ]]
 [[ $(cat "$LOG") == *"$E2E_IMAGE"* ]]
 exit 0
fi
# 所有安装、网络、服务命令由 mock 拦截。
command(){ if [[ $* == '-v docker' ]]; then [[ $TEST != engine ]]; else builtin command "$@"; fi; }
systemctl(){ printf 'systemctl %s\n' "$*" >> "$LOG"; }
uname(){ echo x86_64; }
sh(){ printf 'engine-install\n' >> "$LOG"; cat >/dev/null; }
install(){ printf 'install %s\n' "$*" >> "$LOG"; }
sha256sum(){ [[ $TEST != checksum ]]; }
apt-get(){ exit 99; }
curl(){
 printf 'download %s\n' "$*" >> "$LOG"
 local previous='' argument target=''
 for argument in "$@"; do [[ $previous != -o ]] || target=$argument; previous=$argument; done
 [[ -z $target ]] || printf mock > "$target"
}
docker(){
 printf 'docker %s\n' "$*" >> "$LOG"
 if [[ $* == 'compose version' ]]; then [[ $(cat "$LOG") == *'install -m 755'* ]];
 elif [[ $* == 'compose version --short' ]]; then echo 2.24.7;
 else echo 'Docker version 20.10'; fi
}
install_docker
[[ $(cat "$LOG") == *'/usr/local/lib/docker/cli-plugins/docker-compose'* ]]
if [[ $TEST == engine ]]; then
 [[ $(cat "$LOG") == *'install -d -m 755 /etc/apt/sources.list.d'* && $(cat "$LOG") == *engine-install* ]]
else [[ $(cat "$LOG") != *engine-install* ]]; fi
BASH
 if [[ $test == checksum ]]; then
  [[ $status == 1 && $(cat "$ROOT/$test.log") != *'install -m 755'* ]]
 else [[ $status == 0 ]]; fi
 printf 'PASS %s\n' "$test"
done

bash <<'BASH'
set -euo pipefail
source "$SCRIPT"
[[ $STACK_DIR == /root/v2fly-stack ]]
for removed in legacy load_env save_env cmd_install cmd_update cmd_uninstall select_stack_dir node_legacy_guard; do
 if declare -f "$removed" >/dev/null; then exit 1; fi
done
# Root .env 内容作为文本存在，不执行、不导入、不保留旧端口。
STACK_DIR="$ROOT/no-import"; mkdir -p "$STACK_DIR"
printf 'DOMAIN=old.example.com\nFRONT=nginx\nWS_PATH=/old\n$(touch "%s")\n' "$ROOT/forbidden" > "$STACK_DIR/.env"
printf 'old compose\n' > "$STACK_DIR/compose.yaml"
[[ $(node_python allocate) == 1 ]]
node_python create 1 new.example.com caddy direct 2333 /new 11111111-2222-4333-8444-555555555555 v2fly/v2fly-core:latest
node_python list > "$ROOT/list"
node_python entries > "$ROOT/entries"
node_python ingress
[[ ! -e $ROOT/forbidden && $(cat "$ROOT/list") != *old.example.com* ]]
[[ $(cat "$ROOT/entries") == $'new.example.com\tcaddy' ]]
[[ $(cat "$STACK_DIR/ingress/Caddyfile") != *old.example.com* ]]
[[ $(cat "$STACK_DIR/compose.yaml") == 'old compose' ]]
echo 'PASS fixed-root-no-old-helpers-or-import'
BASH

# 直接菜单动作：正常查看/操作后循环，0/EOF 退出；成功动作释放临时资源。
bash <<'BASH'
set -euo pipefail
source "$SCRIPT"
STACK_DIR="$ROOT/menu-stack"; IN=0; MENU_LOG="$ROOT/menu-actions"
node_python(){ :; }
network_status(){ printf 'status\n' >> "$MENU_LOG"; }
docker(){ [[ $* == 'rm -f mock-menu-test' ]] || return 1; printf 'removed-test-container\n' >> "$MENU_LOG"; }
cmd_network_enable(){
 local action_tmp
 printf 'enable\n' >> "$MENU_LOG"
 mktmp action_tmp
 printf '%s\n' "$action_tmp" > "$ROOT/menu-temp-path"
 printf 'mock-menu-test\n' > "$action_tmp/container.cid"
 E2E_CID_FILES+=("$action_tmp/container.cid")
 mkdir -p "$STACK_DIR"
 touch "$STACK_DIR/successful-transaction"
}
printf '9\n8\n0\n' > "$ROOT/menu-input"
node_menu < "$ROOT/menu-input" > "$ROOT/menu-loop.out"
[[ $(cat "$MENU_LOG") == $'status\nenable\nremoved-test-container' ]] || exit 1
[[ $(grep -c '======== V2Fly 多节点管理' "$ROOT/menu-loop.out") -eq 3 ]] || exit 1
[[ ! -e $(cat "$ROOT/menu-temp-path") && -f $STACK_DIR/successful-transaction ]] || exit 1
[[ ${#TMP_DIRS[@]} -eq 0 && ${#E2E_CID_FILES[@]} -eq 0 && $- == *e* ]] || exit 1
: > "$MENU_LOG"
node_menu < /dev/null > "$ROOT/menu-eof.out"
[[ ! -s $MENU_LOG ]] || exit 1
printf '9\n' > "$ROOT/menu-input"
node_menu < "$ROOT/menu-input" > "$ROOT/menu-status-eof.out"
[[ $(cat "$MENU_LOG") == status ]] || exit 1
echo 'PASS menu-loop-status-enable-exit-eof-and-temp-cleanup'
BASH
# 使用真实 network 入口和预检：缺少模块工具时安全退出，不继续更改网络或容器。
menu_preflight_status=0
bash <<'BASH' || menu_preflight_status=$?
set -euo pipefail
source "$SCRIPT"
IN=0; STACK_DIR="$ROOT/menu-preflight-stack"
node_python(){ :; }
need_docker(){ :; }
command(){ if [[ $* == '-v modprobe' ]]; then return 1; fi; builtin command "$@"; }
network_apply(){ printf 'FORBIDDEN-apply\n' >> "$ROOT/menu-preflight.log"; }
network_status(){ printf 'FORBIDDEN-status\n' >> "$ROOT/menu-preflight.log"; }
node_menu <<< $'8\n9\n0' > "$ROOT/menu-preflight.out"
BASH
[[ $menu_preflight_status -ne 0 && ! -e $ROOT/menu-preflight.log && ! -e $ROOT/menu-preflight-stack ]] || exit 1
grep -q '缺少 modprobe' "$ROOT/menu-preflight.out" || exit 1
echo 'PASS menu-real-network-preflight-failure-stops-safely'
# 普通 fatal 错误保留原有立即退出行为，false 后的写入和下一菜单项均不能执行。
menu_fatal_status=0
bash <<'BASH' || menu_fatal_status=$?
set -euo pipefail
source "$SCRIPT"
IN=0
node_python(){ :; }
cmd_network_enable(){ printf 'before-failure\n' >> "$ROOT/menu-fatal.log"; false; printf 'FORBIDDEN-write\n' >> "$ROOT/menu-fatal.log"; }
network_status(){ printf 'FORBIDDEN-status\n' >> "$ROOT/menu-fatal.log"; }
node_menu <<< $'8\n9\n0' > "$ROOT/menu-fatal.out"
BASH
[[ $menu_fatal_status -ne 0 && $(cat "$ROOT/menu-fatal.log") == before-failure ]] || exit 1
echo 'PASS menu-fatal-error-does-not-continue-writing'
