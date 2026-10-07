#!/usr/bin/env bash
# 本地标准 Bash mock；不访问网络、不启动 Docker、不修改系统配置。
set -euo pipefail
cd "$(dirname "$0")/.."
SCRIPT="$PWD/v2fly-auto-setup.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export SCRIPT ROOT
run_case() {
  local status=0
  bash -s -- "$1" <<'BASH' || status=$?
set -euo pipefail
source "$SCRIPT"
OS_FAMILY=debian
STACK_DIR="$ROOT/$1"; mkdir -p "$STACK_DIR"
ENV_FILE="$STACK_DIR/.env"; COMPOSE_FILE="$STACK_DIR/compose.yaml"
LOG="$STACK_DIR/log"
step(){ :; }; grn(){ :; }; ylw(){ :; }; red(){ :; }
apt-get(){ printf 'FORBIDDEN apt-get %s\n' "$*" >> "$LOG"; return 1; }
prepare_low_memory(){ :; }; preflight(){ :; }; need_docker(){ :; }; install_deps(){ :; }; install_docker(){ :; }; open_ufw(){ :; }; open_firewall(){ :; }
cmd_status(){ :; }; cmd_show(){ :; }; nginx_hint(){ :; }; show_dns(){ :; }
sleep(){ :; }; port_in_use(){ return 1; }; confirm(){ return 0; }
docker(){
  printf '%s\n' "$*" >> "$LOG"
  case "$1" in
    inspect) if [[ $* == *com.docker.compose.project* ]]; then echo v2ray; elif [[ ${*: -1} == v2ray ]]; then echo sha256:old-v2; else echo sha256:old-caddy; fi ;;
    tag) [[ ${FAIL:-} != rollback ]] ;;
    run) local prev='' arg; for arg in "$@"; do if [[ $prev == --cidfile ]]; then echo own-container > "$arg"; fi; prev=$arg; done; [[ ${FAIL:-} != run ]] ;;
    port) echo 127.0.0.1:12345 ;;
  esac
}
compose(){
  printf 'compose %s\n' "$*" >> "$LOG"
  case "$1" in
    pull) [[ ${FAIL:-} != pull ]] ;;
    up) [[ ${FAIL:-} != up || " $* " == *' --pull never '* ]] ;;
    *) return 0 ;;
  esac
}
wait_ready(){ [[ ${FAIL:-} != ready || ${V2FLY_TAG:-} == rollback ]]; }
prompt_config(){ DOMAIN=new.example.com; FRONT=nginx; DOMAIN_CHANGED=yes; }
curl(){ echo 204; }
container_running(){ return 1; }
load_env
DOMAIN=old.example.com; UUID=old-uuid; WS_PATH=/old; FRONT=caddy
if [[ $1 != first ]]; then save_env || exit 1; write_compose || exit 1; fi
: > "$LOG"
case "$1" in
  temp)
    local_dir=''; mktmp local_dir || exit 1; [[ ${#TMP_DIRS[@]} == 1 && -d $local_dir ]] || exit 1
    cleanup; [[ ! -e $local_dir ]] || exit 1
    ;;
  e2e|run)
    FRONT=nginx; FAIL=${1/e2e/none}
    if e2e_ok; then [[ $1 == e2e ]] || exit 1; else [[ $1 == run ]] || exit 1; fi
    [[ $(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "${TMP_DIRS[0]}") == 700 ]] || exit 1
    [[ $(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "${TMP_DIRS[0]}/config.json") == 600 ]] || exit 1
    cleanup
    [[ $(cat "$LOG") != *v2ray-e2e* ]] || exit 1
    [[ $(cat "$LOG") == *'rm -f own-container'* ]] || exit 1
    ;;
  success)
    cmd_update || exit 1; [[ $RECOVERY_ACTIVE == no && -z $RECOVERY_DIR ]] || exit 1
    ;;
  pull|up|ready|rollback)
    FAIL=$1; [[ $1 != rollback ]] || FAIL=pull
    if [[ $1 == rollback ]]; then
      FAIL=up
      docker(){
        case "$1" in
          tag) return 1 ;;
          inspect) if [[ $* == *com.docker.compose.project* ]]; then echo v2ray; else echo sha256:old; fi ;;
          *) return 0 ;;
        esac
      }
    fi
    if cmd_update; then exit 1; fi
    if [[ $1 == rollback ]]; then [[ -d $RECOVERY_DIR ]] || exit 1; else
      [[ $DOMAIN == old.example.com && -z $RECOVERY_DIR ]] || exit 1
      if [[ $1 == pull ]]; then [[ $V2FLY_TAG == latest ]] || exit 1; else [[ $V2FLY_TAG == rollback && $(cat "$LOG") == *'--pull never'* ]] || exit 1; fi
    fi
    ;;
  install_pull)
    cp "$ENV_FILE" "$STACK_DIR/expected.env"
    cp "$COMPOSE_FILE" "$STACK_DIR/expected.compose"
    FAIL=pull
    if cmd_install; then exit 1; fi
    cmp "$ENV_FILE" "$STACK_DIR/expected.env" || exit 1
    cmp "$COMPOSE_FILE" "$STACK_DIR/expected.compose" || exit 1
    [[ $(cat "$LOG") != *'compose up'* ]] || exit 1
    ;;
  install)
    FAIL=ready
    if cmd_install; then exit 1; fi
    [[ $DOMAIN == old.example.com && $FRONT == caddy && $UUID == old-uuid ]] || exit 1
    ;;
  ownership)
    docker(){ if [[ $* == *com.docker.compose.project* ]]; then echo other; else echo sha256:other; fi; }
    if begin_recovery; then exit 1; fi
    [[ $RECOVERY_ACTIVE == no ]] || exit 1
    ;;
  cancel)
    prompt_config(){ exit 17; }
    cmd_install
    ;;
  signal)
    begin_recovery
    RECOVERY_UP=yes
    DOMAIN=new.example.com; save_env
    trap 'rc=$?; cleanup; [[ $DOMAIN == old.example.com && $V2FLY_TAG == rollback ]] || exit 1; exit "$rc"' EXIT
    kill -TERM $$
    ;;
  plugin|checksum|engine)
    unset -f install_docker
    # 重新载入实际函数，随后重新指定测试目录/日志；其余 mock 保留。
    eval "$(sed -n '/^install_docker() {/,/^}/p' "$SCRIPT")"
    command(){ if [[ $* == '-v docker' ]]; then [[ $1 != impossible && $TEST != engine ]]; else builtin command "$@"; fi; }
    systemctl(){ printf 'systemctl %s\n' "$*" >> "$LOG"; }
    uname(){ echo x86_64; }
    sh(){ printf 'engine-install\n' >> "$LOG"; cat >/dev/null; }
    install(){ printf 'install %s\n' "$*" >> "$LOG"; }
    sha256sum(){ [[ $TEST != checksum ]]; }
    curl(){
      printf 'download %s\n' "$*" >> "$LOG"
      local prev='' arg target=''
      for arg in "$@"; do [[ $prev != -o ]] || target=$arg; prev=$arg; done
      [[ -z $target ]] || printf 'mock\n' > "$target"
    }
    docker(){
      printf 'docker %s\n' "$*" >> "$LOG"
      if [[ $* == 'compose version' ]]; then [[ $(cat "$LOG") == *'install -m 755'* ]];
      elif [[ $* == 'compose version --short' ]]; then echo 2.24.7;
      else echo 'Docker version 20.10'; fi
    }
    TEST=$1
    install_docker
    [[ $(cat "$LOG") == *'/usr/local/lib/docker/cli-plugins/docker-compose'* ]] || exit 1
    [[ $(cat "$LOG") != *apt-get* ]] || exit 1
    if [[ $TEST == engine ]]; then
      [[ $(sed -n '/install -d -m 755 \/etc\/apt\/sources.list.d/=' "$LOG") -lt $(sed -n '/engine-install/=' "$LOG") ]] || exit 1
    else [[ $(cat "$LOG") != *engine-install* ]] || exit 1; fi
    ;;
  first)
    FAIL=pull
    if cmd_install; then exit 1; fi
    [[ -f $ENV_FILE && -f $COMPOSE_FILE && -d $RECOVERY_DIR ]] || exit 1
    ;;
esac
BASH
  case "$1" in
    checksum) [[ $status == 1 && $(cat "$ROOT/$1/log") != *'install -m 755'* ]] || return 1 ;;
    cancel) [[ $status == 17 && ! -s "$ROOT/$1/log" ]] || return 1 ;;
    signal) [[ $status == 143 && $(cat "$ROOT/$1/log") == *'--pull never'* ]] || return 1 ;;
    *) [[ $status == 0 ]] || return 1 ;;
  esac
  printf 'PASS %s\n' "$1"
}
for test in temp e2e run success pull up ready rollback install install_pull first ownership plugin engine checksum cancel signal; do run_case "$test" || { printf 'FAIL %s\n' "$test" >&2; exit 1; }; done

# 部署目录选择仅检查存在性，不创建、搬移或覆盖目录。
bash <<'DIRECTORY'
set -euo pipefail
source "$SCRIPT"
base="$ROOT/stack-directory"
declare -f check_domain >/dev/null
select_stack_dir "$base"
[[ $STACK_DIR == "$base/v2fly-stack" && $ENV_FILE == "$STACK_DIR/.env" && $COMPOSE_FILE == "$STACK_DIR/compose.yaml" ]]
[[ ! -e $base ]]
echo 'PASS stack-directory-fresh-default-readonly'
mkdir -p "$base/v2ray-stack"
printf 'original configuration\n' > "$base/v2ray-stack/.env"
select_stack_dir "$base" 2> "$ROOT/legacy-directory-warning"
[[ $STACK_DIR == "$base/v2ray-stack" && $ENV_FILE == "$STACK_DIR/.env" && $COMPOSE_FILE == "$STACK_DIR/compose.yaml" ]]
[[ $(cat "$ENV_FILE") == 'original configuration' && ! -e $base/v2fly-stack ]]
[[ $(cat "$ROOT/legacy-directory-warning") == *'继续使用'* && $(cat "$ROOT/legacy-directory-warning") == *'不自动搬移'* ]]
echo 'PASS stack-directory-legacy-retained-readonly'
mkdir "$base/v2fly-stack"
printf 'new configuration\n' > "$base/v2fly-stack/.env"
if select_stack_dir "$base" 2> "$ROOT/directory-conflict"; then exit 1; fi
[[ $(cat "$base/v2ray-stack/.env") == 'original configuration' && $(cat "$base/v2fly-stack/.env") == 'new configuration' ]]
[[ $(cat "$ROOT/directory-conflict") == *'同时存在'* ]]
echo 'PASS stack-directory-conflict-stops-without-overwrite'
# main 实际调用目录选择，并在冲突时不分派管理动作。
eval "$(declare -f select_stack_dir | sed '1s/select_stack_dir/select_test_stack_dir/')"
select_stack_dir(){ select_test_stack_dir "$base"; }
need_root(){ :; }
cmd_status(){ printf 'called\n' > "$ROOT/selected-status"; }
if main status 2>/dev/null; then exit 1; fi
[[ ! -e $ROOT/selected-status ]]
rmdir "$base/v2fly-stack" 2>/dev/null || { rm "$base/v2fly-stack/.env"; rmdir "$base/v2fly-stack"; }
main status 2>/dev/null
[[ -f $ROOT/selected-status && $STACK_DIR == "$base/v2ray-stack" ]]
echo 'PASS stack-directory-main-selection-and-conflict-guard'
DIRECTORY
