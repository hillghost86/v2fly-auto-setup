#!/usr/bin/env bash
# =============================================================================
# v2fly-auto-setup.sh — V2Fly v5 + Caddy 2（VMess + WebSocket + TLS）一键安装与管理
#
# 用法（在服务器上以 root 运行）:
#   bash <(curl -fsSL https://raw.githubusercontent.com/hillghost86/v2fly-auto-setup/main/v2fly-auto-setup.sh)
#   curl -fsSL .../v2fly-auto-setup.sh | bash -s -- install
#   支持的子命令: install | update | status | show | uninstall
#
# 两种前端模式（安装时选择，存在 .env 的 FRONT 里）:
#   caddy  脚本自带 Caddy 占 80/443，自动申请证书（默认）
#   nginx  机器上已有 Nginx（宝塔面板等）占着 80/443：只跑 V2Ray，端口绑在
#          127.0.0.1:2333，证书和 443 交给 Nginx，由用户在 Nginx 里反代过来
#
# 文件位置:
#   /root/v2ray-stack/.env          域名、UUID、路径、前端模式、镜像版本（脚本与 compose 共用）
#   /root/v2ray-stack/compose.yaml  容器定义（V2Ray 与 Caddy 配置内嵌其中）
#   Docker 数据卷 caddy_data         HTTPS 证书（仅 caddy 模式）
# =============================================================================
# 换行符自愈：Windows 格式（CRLF）会让脚本无法运行，这里自动去掉 \r 后重新执行。
# 必须先确认脚本是磁盘上的普通文件：通过 bash <(curl ...) 运行时脚本来自管道，
# 再去读它会把数据从 bash 自己手里抢走，导致脚本被截断（管道场景也不会有 CRLF）。
# 下面这行必须保持单行，行尾注释用来兜住可能存在的 \r
_s=${BASH_SOURCE[0]:-$0}; if [[ -f $_s ]] && IFS= read -r _l < "$_s" 2>/dev/null && [[ $_l == *$'\r' ]]; then _f=$(mktemp); sed 's/\r$//' "$_s" > "$_f"; exec bash "$_f" "$@"; fi; unset -v _s _l # crlf-guard

set -euo pipefail

STACK_DIR=/root/v2ray-stack
ENV_FILE="$STACK_DIR/.env"
COMPOSE_FILE="$STACK_DIR/compose.yaml"
MIN_COMPOSE=2.23.1
OS_FAMILY=""

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die()  { red "✗ $*"; exit 1; }

# 交互输入：优先从终端读取，兼容 bash <(curl ...) 和 curl | bash 两种写法
if { exec 3</dev/tty; } 2>/dev/null; then IN=3; else IN=0; fi

ask() {  # ask "提示" "默认值" → 输出用户输入或默认值
  local reply
  read -r -u "$IN" -p "$1${2:+ [$2]}: " reply || true
  printf '%s' "${reply:-$2}"
}

confirm() {  # confirm "提示" y|n
  local def=${2:-n} reply
  read -r -u "$IN" -p "$1 $([[ $def == y ]] && echo '[Y/n]' || echo '[y/N]'): " reply || true
  reply=${reply:-$def}
  [[ $reply =~ ^[Yy]$ ]]
}

compose() { docker compose --project-directory "$STACK_DIR" "$@"; }

# ---------------------------------------------------------------------------
# 退出时的清理：临时网页服务、临时测试容器、被停掉的 Caddy
# ---------------------------------------------------------------------------
CHECK_PID=""
CADDY_STOPPED=no
TMP_DIRS=()
E2E_CID_FILE=""
E2E_CID_FILES=()
RECOVERY_DIR=""
RECOVERY_ACTIVE=no
RECOVERY_UP=no
RECOVERY_V2="" RECOVERY_CADDY=""
NODE_TX_ACTIVE=no NODE_TX_BACKUP="" NODE_TX_ID="" NODE_TX_IMAGE="" NODE_TX_EXISTED=no
SWAP_SOURCE="" SWAP_TARGET="" SWAP_CREATED_ID="" SWAP_ACTIVE=no SWAP_PERSISTED=no
SWAP_STATUS_FILE=/proc/swaps
SWAP_FSTAB_CANDIDATE="" SWAP_FSTAB_BACKUP=""

cleanup() {
  # 清理不能因为某一步失败就中断：docker rm 在容器本来就不存在时会返回非 0，
  # 若保留 set -e，后面「恢复 Caddy」就被跳过了，服务会一直停着
  set +e
  cleanup_swap
  if [[ $NODE_TX_ACTIVE == yes ]]; then
    NODE_ID=$NODE_TX_ID
    node_recover "$NODE_TX_BACKUP" "$NODE_TX_IMAGE" "$NODE_TX_EXISTED" || red "节点恢复失败，备份：$NODE_TX_BACKUP"
  fi
  [[ -n $CHECK_PID ]] && kill "$CHECK_PID" 2>/dev/null
  if [[ $RECOVERY_ACTIVE == yes ]]; then
    recover_stack || red "恢复失败，备份保留在 $RECOVERY_DIR"
  fi
  if [[ $CADDY_STOPPED == yes ]]; then
    ylw "正在恢复 Caddy 运行…"
    compose start caddy >/dev/null 2>&1
  fi
  local cid_file
  if ((${#E2E_CID_FILES[@]})); then
    for cid_file in "${E2E_CID_FILES[@]}"; do
      if [[ -s $cid_file ]]; then docker rm -f "$(cat "$cid_file")" >/dev/null 2>&1; fi
    done
  fi
  ((${#TMP_DIRS[@]})) && rm -rf "${TMP_DIRS[@]}"
  return 0
}
# 只把 cleanup 挂在 EXIT 上。INT / TERM 若直接调 cleanup，处理完会从被打断的
# 地方继续往下跑——按了 Ctrl-C 却照样把安装做完。改成主动 exit，由 EXIT 统一清理
trap 'rc=$?; cleanup; exit "$rc"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mktmp() { local tmp_created; tmp_created=$(mktemp -d) || return 1; TMP_DIRS+=("$tmp_created"); printf -v "$1" '%s' "$tmp_created"; }

# 备份不属于临时目录：恢复失败时必须留下配置与旧镜像 ID。
begin_recovery() {
  mkdir -p "$STACK_DIR" || return 1
  RECOVERY_DIR=$(mktemp -d "$STACK_DIR/.recovery.XXXXXX") || return 1
  [[ ! -f $ENV_FILE ]] || cp -p "$ENV_FILE" "$RECOVERY_DIR/env" || return 1
  [[ ! -f $COMPOSE_FILE ]] || cp -p "$COMPOSE_FILE" "$RECOVERY_DIR/compose.yaml" || return 1
  local service project
  for service in v2ray caddy; do
    if docker inspect "$service" >/dev/null 2>&1; then
      project=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$service" 2>/dev/null || true)
      [[ $project == v2ray ]] || { red "同名容器 $service 不属于本项目，停止修改；备份：$RECOVERY_DIR"; return 1; }
    fi
  done
  RECOVERY_V2=$(docker inspect -f '{{.Image}}' v2ray 2>/dev/null || true)
  RECOVERY_CADDY=$(docker inspect -f '{{.Image}}' caddy 2>/dev/null || true)
  printf '%s\n%s\n' "$RECOVERY_V2" "$RECOVERY_CADDY" > "$RECOVERY_DIR/images" || return 1
  RECOVERY_UP=no
  RECOVERY_ACTIVE=yes
}

finish_recovery() {
  RECOVERY_ACTIVE=no
  rm -rf "$RECOVERY_DIR"
  RECOVERY_DIR=""
}

recover_stack() {
  # 先关闭自动重试，避免 EXIT 再覆盖恢复失败现场。
  RECOVERY_ACTIVE=no
  if [[ ! -f $RECOVERY_DIR/compose.yaml ]]; then
    ylw "首次安装失败，保留当前配置供排查；备份目录：$RECOVERY_DIR"
    return 1
  fi
  ylw "正在恢复原配置和旧镜像…"
  if [[ -f $RECOVERY_DIR/env ]]; then
    cp -p "$RECOVERY_DIR/env" "$ENV_FILE" || return 1
  else
    rm -f "$ENV_FILE" || return 1
  fi
  cp -p "$RECOVERY_DIR/compose.yaml" "$COMPOSE_FILE" || return 1
  load_env || return 1
  if [[ $RECOVERY_UP == no ]]; then
    if [[ $CADDY_STOPPED == yes ]]; then
      compose start caddy || return 1
      CADDY_STOPPED=no
    fi
    finish_recovery
    return 0
  fi
  [[ -n $RECOVERY_V2 ]] || { red "找不到原 V2Ray 镜像 ID；备份：$RECOVERY_DIR"; return 1; }
  docker tag "$RECOVERY_V2" v2fly/v2fly-core:rollback || return 1
  V2FLY_TAG=rollback
  if [[ $FRONT == caddy ]]; then
    [[ -n $RECOVERY_CADDY ]] || { red "找不到原 Caddy 镜像 ID；备份：$RECOVERY_DIR"; return 1; }
    docker tag "$RECOVERY_CADDY" caddy:rollback || return 1
    CADDY_TAG=rollback
  fi
  save_env || return 1
  compose up -d --force-recreate --remove-orphans --pull never || return 1
  CADDY_STOPPED=no
  wait_ready || return 1
  grn "✓ 已恢复原配置和更新前镜像"
  finish_recovery
}

fail_change() {
  red "$1"
  if ! recover_stack; then red "恢复未完成，备份保留在 $RECOVERY_DIR"; fi
  return 1
}

# ---------------------------------------------------------------------------
# 状态
# ---------------------------------------------------------------------------
load_env() {
  DOMAIN="" UUID="" WS_PATH="" CDN="no" FRONT="caddy" V2FLY_TAG="latest" CADDY_TAG="2"
  if [[ -f $ENV_FILE ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  fi
  : "${V2FLY_TAG:=latest}" "${CADDY_TAG:=2}"
  # 旧版 .env 没有 FRONT，等价于 caddy 模式
  [[ $FRONT == nginx ]] || FRONT=caddy
}

save_env() {
  mkdir -p "$STACK_DIR" || return 1
  cat > "$ENV_FILE" <<EOF || return 1
DOMAIN=$DOMAIN
UUID=$UUID
WS_PATH=$WS_PATH
CDN=$CDN
FRONT=$FRONT
V2FLY_TAG=$V2FLY_TAG
CADDY_TAG=$CADDY_TAG
EOF
  chmod 600 "$ENV_FILE" || return 1
}

container_running() { [[ -n "$(docker ps -q --filter "name=^$1\$" 2>/dev/null)" ]]; }

# ---------------------------------------------------------------------------
# 环境准备
# ---------------------------------------------------------------------------
# 所有子命令都要 root：配置在 /root/v2ray-stack 下（.env 是 600，里面的 UUID
# 等同密码），Docker、apt、systemd、80/443 端口也都要。放在 main() 里统一拦，
# 比在各个子命令里分别调更难漏——尤其是无参数进菜单时，menu() 第一行就是
# load_env，非 root 下有可能连报错都来不及打就被 set -e 终止
need_root() {
  [[ $EUID -eq 0 ]] || die "需要 root 运行。配置在 /root/v2ray-stack 下，普通用户读不到。
  请用: sudo -i 切到 root，或 curl -fsSL <脚本地址> | sudo bash -s -- ${1:-install}"
}

detect_os() {
  local os_file=${1:-/etc/os-release} ID="" VERSION_ID="" NAME="" PRETTY_NAME=""
  [[ -r $os_file ]] || die "无法读取系统版本：$os_file"
  # shellcheck disable=SC1090
  source "$os_file"
  case "$ID" in
    debian|ubuntu) OS_FAMILY=debian ;;
    rocky|almalinux)
      [[ ${VERSION_ID%%.*} == 9 ]] || die "仅支持 Rocky Linux / AlmaLinux 9"
      OS_FAMILY=el9
      ;;
    centos)
      [[ ${VERSION_ID%%.*} == 9 && ( $NAME == *"CentOS Stream"* || $PRETTY_NAME == *"CentOS Stream"* ) ]] \
        || die "仅支持 CentOS Stream 9，不支持 CentOS Linux 或 Stream 8"
      OS_FAMILY=el9
      ;;
    *) die "仅支持 Debian / Ubuntu、Rocky Linux 9、AlmaLinux 9 和 CentOS Stream 9" ;;
  esac
}

preflight() {
  detect_os
  command -v systemctl >/dev/null || die "需要 systemd"
  if [[ $OS_FAMILY == el9 ]]; then
    command -v dnf >/dev/null || die "没有检测到 dnf"
    command -v rpm >/dev/null || die "没有检测到 rpm"
  else
    command -v apt-get >/dev/null || die "没有检测到 apt-get"
  fi
}

check_docker_engine() {
  local version
  version=$(docker --version 2>/dev/null) || die "Docker 命令无法运行"
  if [[ $version == *[Pp][Oo][Dd][Mm][Aa][Nn]* ]] || \
      { [[ $OS_FAMILY == el9 ]] && rpm -q podman-docker >/dev/null 2>&1; }; then
    die "检测到 podman-docker / Podman 兼容命令，需要真正的 Docker Engine；请先自行处理冲突，本脚本不会卸载现有软件"
  fi
}

need_docker() {
  command -v docker >/dev/null || die "没有检测到 Docker，请先运行本脚本的「安装」"
  check_docker_engine
  docker compose version >/dev/null 2>&1 || die "没有检测到 Docker Compose，请先运行本脚本的「安装」"
  docker info >/dev/null 2>&1 || die "Docker 没有运行，请执行: systemctl start docker"
}

# Swap 的文件归属用本次临时文件的 inode 判断；已启用的文件绝不删除。
swap_is_active() {
  local target=$1 swaps_file=${2:-/proc/swaps} entry rest
  [[ -r $swaps_file ]] || return 2
  while read -r entry rest; do
    [[ $entry != "$target" ]] || return 0
  done < "$swaps_file"
  return 1
}

cleanup_swap() {
  local active_status=1 target_id=""
  if [[ $SWAP_ACTIVE == yes ]]; then
    active_status=0
  elif [[ -n $SWAP_TARGET ]]; then
    # swapon 已完成但尚未设置标志时，仍以实际活动状态保护整个 inode。
    if swap_is_active "$SWAP_TARGET" "$SWAP_STATUS_FILE"; then active_status=0; else active_status=$?; fi
  fi
  if [[ $active_status == 0 ]]; then
    SWAP_ACTIVE=yes
    # Linux 禁止 unlink 活动 Swap 的任何硬链接；旧失败现场的 source 也保留。
  elif [[ $active_status == 1 ]]; then
    if [[ -n $SWAP_TARGET && -n $SWAP_CREATED_ID && ! -L $SWAP_TARGET ]]; then
      target_id=$(stat -c '%d:%i' -- "$SWAP_TARGET" 2>/dev/null || true)
      [[ $target_id != "$SWAP_CREATED_ID" ]] || rm -f -- "$SWAP_TARGET"
    fi
    if [[ -n $SWAP_SOURCE ]]; then
      rm -f -- "$SWAP_SOURCE" && SWAP_SOURCE=""
    fi
  fi
  [[ -z $SWAP_FSTAB_CANDIDATE ]] || rm -f -- "$SWAP_FSTAB_CANDIDATE"
  SWAP_FSTAB_CANDIDATE=""
  if [[ $SWAP_ACTIVE == yes && $SWAP_PERSISTED == no ]]; then
    ylw "Swap 已启用并保留，但重启自动启用可能未完成；请核对 fstab。备份：$SWAP_FSTAB_BACKUP"
  fi
}

create_swap() {
  # 参数仅用于本地 fixture 测试；安装入口使用固定 /swapfile 与 /etc/fstab。
  local swap_file=${1:-/swapfile} fstab_file=${2:-/etc/fstab} parent fs available entry rest tool
  [[ ! -e $swap_file && ! -L $swap_file ]] || { red "$swap_file 已存在，不会覆盖；请自行检查 Swap"; return 1; }
  [[ -f $fstab_file && ! -L $fstab_file ]] || { red "$fstab_file 不是普通文件，停止创建 Swap"; return 1; }
  for tool in findmnt df dd mkswap swapon mktemp cp chmod ln mv cmp awk stat systemctl; do
    command -v "$tool" >/dev/null || { red "缺少 $tool，无法安全创建 Swap；请自行准备，不会自动安装工具"; return 1; }
  done
  while read -r entry rest || [[ -n $entry ]]; do
    [[ $entry != "$swap_file" ]] || { red "$fstab_file 已有 $swap_file 条目，请先自行核对"; return 1; }
  done < "$fstab_file"
  parent=${swap_file%/*}; parent=${parent:-/}
  fs=$(findmnt -n -o FSTYPE -T "$parent") || { red "无法确定 Swap 所在文件系统"; return 1; }
  [[ $fs == ext4 || $fs == xfs ]] || { red "自动创建 Swap 仅支持 ext4 / xfs，当前为 $fs"; return 1; }
  available=$(df -Pk "$parent" | awk 'NR==2 {print $4}') || return 1
  [[ $available =~ ^[0-9]+$ ]] && (( available >= 2097152 )) || { red "磁盘至少需要 2 GiB 可用空间（Swap 1 GiB，另留 1 GiB）"; return 1; }

  SWAP_FSTAB_BACKUP=$(mktemp "$fstab_file.v2fly-backup.XXXXXX") || return 1
  cp -- "$fstab_file" "$SWAP_FSTAB_BACKUP" || { red "fstab 备份失败：$SWAP_FSTAB_BACKUP"; return 1; }
  SWAP_SOURCE=$(mktemp "$swap_file.tmp.XXXXXX") || return 1
  chmod 600 "$SWAP_SOURCE" || return 1
  dd if=/dev/zero of="$SWAP_SOURCE" bs=1M count=1024 conv=fsync || { red "Swap 文件写入失败；fstab 备份：$SWAP_FSTAB_BACKUP"; return 1; }
  SWAP_CREATED_ID=$(stat -c '%d:%i' -- "$SWAP_SOURCE") || return 1
  [[ $SWAP_CREATED_ID =~ ^[0-9]+:[0-9]+$ ]] || return 1
  # ln 不覆盖任何已有路径，包括检测之后才出现的文件/符号链接。
  SWAP_TARGET=$swap_file
  ln -T -- "$SWAP_SOURCE" "$SWAP_TARGET" || { red "Swap 路径已占用，停止创建"; return 1; }
  if command -v restorecon >/dev/null; then
    restorecon "$SWAP_TARGET" || { red "Swap 的 SELinux 标签恢复失败"; return 1; }
  fi
  mkswap "$SWAP_TARGET" || { red "Swap 初始化失败；fstab 备份：$SWAP_FSTAB_BACKUP"; return 1; }
  # 必须在启用前删去临时硬链接；Linux 不允许 unlink 活动 Swap inode。
  rm -f -- "$SWAP_SOURCE" || { red "临时链接清理失败，未启用 Swap；fstab 备份：$SWAP_FSTAB_BACKUP"; return 1; }
  SWAP_SOURCE=""
  swapon "$SWAP_TARGET" || { red "Swap 启用失败；fstab 备份：$SWAP_FSTAB_BACKUP"; return 1; }
  SWAP_ACTIVE=yes
  # swapon 返回成功后保留文件，后续失败不能通过 swapoff 增加内存压力。
  swap_is_active "$SWAP_TARGET" "$SWAP_STATUS_FILE" || { red "无法确认 Swap 状态，请检查 $SWAP_TARGET；文件保留"; return 1; }
  SWAP_FSTAB_CANDIDATE=$(mktemp "$fstab_file.v2fly-new.XXXXXX") || return 1
  cp --preserve=all -- "$fstab_file" "$SWAP_FSTAB_CANDIDATE" || { red "fstab 候选文件准备失败；备份：$SWAP_FSTAB_BACKUP"; return 1; }
  if command -v selinuxenabled >/dev/null && selinuxenabled; then
    chcon --reference="$fstab_file" "$SWAP_FSTAB_CANDIDATE" || { red "fstab 的 SELinux 标签复制失败；备份：$SWAP_FSTAB_BACKUP"; return 1; }
  fi
  printf '\n%s none swap defaults,nofail 0 0\n' "$swap_file" >> "$SWAP_FSTAB_CANDIDATE" || return 1
  cmp -s -- "$fstab_file" "$SWAP_FSTAB_BACKUP" || { red "fstab 已被其他操作修改，不覆盖；备份：$SWAP_FSTAB_BACKUP"; return 1; }
  mv -T -- "$SWAP_FSTAB_CANDIDATE" "$fstab_file" || { red "fstab 写入失败；Swap 已启用，备份：$SWAP_FSTAB_BACKUP"; return 1; }
  SWAP_FSTAB_CANDIDATE=""
  SWAP_PERSISTED=yes
  systemctl daemon-reload || { red "Swap 已启用，但 systemd 配置重载失败；请核对 fstab；备份：$SWAP_FSTAB_BACKUP"; return 1; }
  grn "✓ 1 GiB Swap 已启用，并写入 fstab；备份：$SWAP_FSTAB_BACKUP"
}

prepare_low_memory() {
  local mem_file=${1:-/proc/meminfo} swaps_file=${2:-/proc/swaps} key value rest total="" entry
  [[ -r $mem_file && -r $swaps_file ]] || { red "无法读取内存 / Swap 状态，停止安装"; return 1; }
  while read -r key value rest; do
    if [[ $key == MemTotal: ]]; then total=$value; break; fi
  done < "$mem_file"
  [[ $total =~ ^[0-9]+$ ]] && (( total > 0 )) || { red "无法确定物理内存大小，停止安装"; return 1; }
  (( total < 1048576 )) || return 0
  while read -r entry rest; do
    [[ -z $entry || $entry == Filename ]] || return 0
  done < "$swaps_file"
  ylw "物理内存不足 1 GiB 且没有活动 Swap，安装依赖可能耗尽内存并导致 SSH 断连。"
  if ! confirm "是否创建并启用 1 GiB Swap，写入 /etc/fstab 供重启后使用？" n; then
    red "未创建 Swap，已停止此次安装。请先自行增加 Swap 或内存后重试。"
    return 1
  fi
  if ! create_swap; then
    red "Swap 创建或持久化未完成，停止安装；已启用的 Swap 会保留。${SWAP_FSTAB_BACKUP:+ fstab 备份：$SWAP_FSTAB_BACKUP}"
    cleanup_swap
    return 1
  fi
}

install_qrencode_el9() {
  command -v qrencode >/dev/null && return 0
  dnf install -y qrencode && return 0
  if ! rpm -q epel-release >/dev/null 2>&1; then
    if ! confirm "当前源无可用 qrencode。是否添加 Fedora 官方 EPEL 9 外部软件源后安装二维码工具？" n; then
      ylw "未添加 EPEL，跳过二维码；客户端链接仍可使用。"
      return 0
    fi
    if ! dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm; then
      ylw "EPEL 软件源安装失败，跳过二维码；客户端链接仍可使用。"
      return 0
    fi
  fi
  if ! dnf install -y qrencode; then
    ylw "qrencode 仍无法安装，请检查 EPEL 是否启用或软件包是否可用；客户端链接仍可使用。"
  fi
}

install_deps() {
  step "安装基础依赖"
  local pkgs=() p
  if [[ $OS_FAMILY == el9 ]]; then
    for p in curl ca-certificates openssl python3 iproute; do
      if [[ $p == curl ]]; then
        # EL9 最小安装常有 curl-minimal，所需的 HTTP(S) 功能已经齐全。
        rpm -q curl &>/dev/null || rpm -q curl-minimal &>/dev/null || pkgs+=(curl)
      else
        rpm -q "$p" &>/dev/null || pkgs+=("$p")
      fi
    done
    if ((${#pkgs[@]})); then
      dnf install -y "${pkgs[@]}" || die "基础依赖安装失败"
    fi
    install_qrencode_el9 || return 1
  else
    for p in curl ca-certificates qrencode openssl python3 iproute2; do
      dpkg -s "$p" &>/dev/null || pkgs+=("$p")
    done
    if ((${#pkgs[@]})); then
      apt-get update -qq || die "APT 更新失败"
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" >/dev/null || die "基础依赖安装失败"
    fi
  fi
  step "核验已安装的依赖"
  local missing=no
  for p in curl openssl python3 ss ip; do
    if command -v "$p" >/dev/null; then grn "✓ $p";
    else red "✗ $p 不可用"; missing=yes; fi
  done
  if { [[ $OS_FAMILY == el9 ]] && rpm -q ca-certificates >/dev/null 2>&1; } || \
      { [[ $OS_FAMILY == debian ]] && dpkg -s ca-certificates 2>/dev/null | grep -q '^Status: install ok installed'; }; then
    grn "✓ ca-certificates"
  else
    red "✗ ca-certificates 未安装"; missing=yes
  fi
  if command -v qrencode >/dev/null; then grn "✓ qrencode（二维码）";
  else ylw "⚠ qrencode 不可用，跳过二维码；客户端链接仍可使用。"; fi
  [[ $missing == no ]] || die "核心依赖核验失败，停止安装；请修复上面标记的项目后重试"
  grn "✓ 核心依赖已就绪"
}

install_docker() {
  step "安装 Docker"
  if ! command -v docker >/dev/null; then
    if [[ $OS_FAMILY == el9 ]]; then
      dnf install -y dnf-plugins-core || die "Docker 软件源工具安装失败"
      dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || die "添加 Docker 官方软件源失败"
      dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin \
        || die "Docker 安装失败，请检查软件包冲突；本脚本不会卸载现有软件或使用 --allowerasing"
    else
      install -d -m 755 /etc/apt/sources.list.d || die "创建 APT 源目录失败"
      curl -fsSL https://get.docker.com | sh || die "Docker 安装失败"
    fi
  fi
  check_docker_engine
  systemctl enable --now docker >/dev/null 2>&1 || die "Docker 服务启动失败"
  docker info >/dev/null 2>&1 || die "Docker 服务未就绪，请检查 systemctl status docker"
  if ! docker compose version >/dev/null 2>&1; then
    # 固定版本兼容 Docker 20.10，不更换已有 Docker；手动插件不会自动更新。
    local arch dir asset version=2.24.7
    case $(uname -m) in
      x86_64|aarch64|armv7l|ppc64le|s390x) arch=$(uname -m) ;;
      *) die "不支持此架构的 Compose 手动安装：$(uname -m)" ;;
    esac
    mktmp dir
    asset="docker-compose-linux-$arch"
    curl -fsSL "https://github.com/docker/compose/releases/download/v$version/$asset" -o "$dir/$asset"
    curl -fsSL "https://github.com/docker/compose/releases/download/v$version/$asset.sha256" -o "$dir/checksum"
    (cd "$dir" && sha256sum -c checksum) || die "Compose 校验失败，未安装"
    install -d -m 755 /usr/local/lib/docker/cli-plugins
    install -m 755 "$dir/$asset" /usr/local/lib/docker/cli-plugins/docker-compose
  fi
  local v
  v=$(docker compose version --short 2>/dev/null | sed 's/^v//' || true)
  [[ -n $v ]] || die "Docker Compose 安装失败"
  [[ "$(printf '%s\n%s\n' "$MIN_COMPOSE" "$v" | sort -V | head -1)" == "$MIN_COMPOSE" ]] \
    || die "Docker Compose 版本 $v 太旧，需要 $MIN_COMPOSE 以上"
  grn "✓ $(docker --version)，Compose $v"
}

public_ip() {
  curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -fsS4 --max-time 5 https://ifconfig.me 2>/dev/null || echo "未知"
}

port_in_use() { [[ -n "$(ss -Htln "sport = :$1" 2>/dev/null)" ]]; }

open_ufw() {
  [[ $FRONT == caddy ]] || return 0
  if command -v ufw >/dev/null && LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow 80/tcp >/dev/null || return 1
    ufw allow 443/tcp >/dev/null || return 1
    grn "✓ ufw 已放行 80、443"
  fi
}

# 只修改公网出口网卡实际使用的区域，不启动防火墙、不做全局 reload。
open_firewall() {
  [[ $FRONT == caddy ]] || return 0
  open_ufw || die "ufw 规则添加失败"
  [[ $OS_FAMILY == el9 ]] || return 0
  command -v firewall-cmd >/dev/null || return 0
  firewall-cmd --state >/dev/null 2>&1 || return 0
  local interface zone port
  interface=$(ip -4 route get 1.1.1.1 | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}') \
    || die "无法确定公网出口网卡，请检查路由"
  [[ -n $interface ]] || die "无法确定公网出口网卡，请检查路由"
  zone=$(firewall-cmd --get-zone-of-interface="$interface" 2>/dev/null || true)
  if [[ -z $zone || $zone == "no zone" ]]; then
    zone=$(firewall-cmd --get-default-zone) || die "无法读取 firewalld 默认区域"
  fi
  [[ -n $zone ]] || die "无法确定 firewalld 区域"
  for port in 80 443; do
    firewall-cmd --zone="$zone" --add-port="$port/tcp" >/dev/null || die "firewalld 临时规则添加失败"
    firewall-cmd --permanent --zone="$zone" --add-port="$port/tcp" >/dev/null || die "firewalld 永久规则添加失败"
  done
  grn "✓ firewalld 已在网卡 $interface 的 $zone 区域放行 80、443"
}

# ---------------------------------------------------------------------------
# 域名检查：临时开一个网页服务，再从外部经域名访问它
# 一次验证了 DNS 解析、Lightsail 防火墙 80 端口、Cloudflare 转发是否正常
# ---------------------------------------------------------------------------
check_ipv6() {
  local aaaa local6
  aaaa=$(getent ahostsv6 "$DOMAIN" 2>/dev/null | awk '{print $1}' | grep -v '^::ffff:' | sort -u | tr '\n' ' ' || true)
  [[ -z $aaaa ]] && return 0
  local6=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1 | tr '\n' ' ' || true)
  echo "域名 IPv6 解析: $aaaa"
  if [[ $CDN == yes ]]; then
    echo "  （CDN 模式下这是 Cloudflare 的地址，正常）"
    return 0
  fi
  local a
  for a in $aaaa; do
    if [[ " $local6 " == *" $a "* ]]; then return 0; fi
  done
  ylw "⚠ 域名的 IPv6 解析（AAAA 记录）不是本机地址。本机 IPv6: ${local6:-无}"
  ylw "  建议在 DNS 里删掉这条 AAAA 记录，否则证书申请或客户端连接可能失败"
}

show_dns() {
  local resolved
  PUBLIC_IP=$(public_ip)
  resolved=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)
  echo "本机公网 IP:   $PUBLIC_IP"
  echo "域名当前解析: ${resolved:-（解析失败）}"
  check_ipv6
}

check_domain() {
  step "检查域名 $DOMAIN 是否指向本机"
  local ip token dir got
  show_dns
  ip=$PUBLIC_IP

  port_in_use 80 && die "80 端口被占用，无法检查。先查明占用程序：ss -tlnp | grep ':80 '
  如果占用的是宝塔面板或其他 Nginx，请重新运行安装，前端模式选「已有 Nginx」"

  token=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
  mktmp dir || return 1
  mkdir -p "$dir/.well-known/v2ray-check"
  printf '%s' "$token" > "$dir/.well-known/v2ray-check/token"
  python3 -m http.server 80 --bind 0.0.0.0 --directory "$dir" >/dev/null 2>&1 &
  CHECK_PID=$!
  sleep 1
  got=$(curl -fsS --max-time 10 "http://$DOMAIN/.well-known/v2ray-check/token" 2>/dev/null || true)
  kill "$CHECK_PID" 2>/dev/null || true
  wait "$CHECK_PID" 2>/dev/null || true
  CHECK_PID=""

  if [[ "$got" == "$token" ]]; then
    grn "✓ 通过域名能访问到本机，可以申请证书"
    return 0
  fi

  red "✗ 通过域名访问不到本机"
  if [[ $CDN == yes ]]; then
    echo "  请检查: 1) Cloudflare 里域名的 A 记录是否指向 $ip"
    echo "          2) Lightsail 防火墙是否放行 TCP 80"
    echo "          3) Cloudflare 的「始终使用 HTTPS」是否已关闭"
  else
    echo "  请检查: 1) 域名 A 记录是否已改成 $ip（刚改的话等几分钟再试）"
    echo "          2) Lightsail 防火墙是否放行 TCP 80"
    echo "          3) 如果域名在 Cloudflare，云朵是否为灰色（仅 DNS）"
  fi
  confirm "仍然继续安装？（证书可能申请失败）" n || exit 1
}

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------
prompt_config() {
  step "填写配置（直接回车使用方括号里的值）"
  local d u p
  while :; do
    d=$(ask "域名" "$DOMAIN")
    [[ $d =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] && break
    red "域名格式不对，请重新输入"
  done
  while :; do
    u=$(ask "UUID（回车随机生成）" "${UUID:-$(cat /proc/sys/kernel/random/uuid)}")
    [[ $u =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] && break
    red "UUID 格式不对，请重新输入"
  done
  while :; do
    p=$(ask "WebSocket 路径（回车随机生成）" "${WS_PATH:-/$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')}")
    [[ $p != /* ]] && p="/$p"
    [[ $p =~ ^/[A-Za-z0-9._~-]+$ ]] && break
    red "路径只能包含字母、数字和 . _ ~ -，请重新输入"
  done
  if confirm "是否通过 Cloudflare CDN 转发？" "$([[ $CDN == yes ]] && echo y || echo n)"; then CDN=yes; else CDN=no; fi

  # 前端模式。首次安装时如果 443 已经被别的程序占着（宝塔面板之类），
  # 默认就选 nginx，免得用户选了 caddy 再撞到端口冲突
  local def=$FRONT
  if [[ ! -f $ENV_FILE ]] && port_in_use 443 && ! container_running caddy; then
    ylw "检测到 443 端口已被其他程序占用（宝塔面板 / Nginx？），默认选择「已有 Nginx」模式"
    def=nginx
  fi
  echo "HTTPS 由谁负责："
  echo "  1) 脚本自带 Caddy，自动申请证书（需要 80、443 端口空闲）"
  echo "  2) 已有 Nginx（宝塔面板等）：只跑 V2Ray，证书和 443 交给 Nginx，需要你加一段反代"
  while :; do
    case "$(ask "请选择" "$([[ $def == nginx ]] && echo 2 || echo 1)")" in
      1) FRONT=caddy; break ;;
      2) FRONT=nginx; break ;;
      *) red "请输入 1 或 2" ;;
    esac
  done

  DOMAIN_CHANGED=no
  [[ "$d" != "$DOMAIN" ]] && DOMAIN_CHANGED=yes
  DOMAIN=$d UUID=${u,,} WS_PATH=$p

  echo
  echo "  域名:  $DOMAIN"
  echo "  UUID:  $UUID"
  echo "  路径:  $WS_PATH"
  echo "  CDN:   $CDN"
  if [[ $FRONT == nginx ]]; then
    echo "  前端:  已有 Nginx（宝塔），V2Ray 监听 127.0.0.1:2333"
    echo "  镜像:  v2fly/v2fly-core:$V2FLY_TAG"
  else
    echo "  前端:  Caddy 自动证书"
    echo "  镜像:  v2fly/v2fly-core:$V2FLY_TAG , caddy:$CADDY_TAG"
  fi
  confirm "确认以上配置？" y || exit 1
}

# Compose 2.24.7 的 inline configs 通过 CopyToContainer 注入，不是宿主 bind，
# 保留容器默认 SELinux 隔离；只有 e2e 的独占临时 bind 文件使用 :Z 重标记。
# compose.yaml 按模式拼装：V2Ray 服务和它的配置两种模式都有；Caddy 服务、
# Caddyfile、证书卷只在 caddy 模式写入。nginx 模式下 V2Ray 的 2333 端口发布到
# 127.0.0.1，由宿主机上的 Nginx 反代，外网直接碰不到
write_compose() {
  mkdir -p "$STACK_DIR" || return 1
  {
    cat <<'EOF'
# 由 v2fly-auto-setup.sh 生成。域名、UUID、路径、前端模式、镜像版本读取同目录的 .env
name: v2ray

services:
  v2ray:
    image: v2fly/v2fly-core:${V2FLY_TAG}
    container_name: v2ray
    restart: unless-stopped
    command: run -c /etc/v2ray/config.json
    configs:
      - source: v2ray_config
        target: /etc/v2ray/config.json
EOF
    if [[ $FRONT == nginx ]]; then
      cat <<'EOF'
    ports:
      - "127.0.0.1:2333:2333"
EOF
    else
      cat <<'EOF'

  caddy:
    image: caddy:${CADDY_TAG}
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    configs:
      - source: caddyfile
        target: /etc/caddy/Caddyfile
    volumes:
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - v2ray
EOF
    fi
    cat <<'EOF'

configs:
  v2ray_config:
    content: |
      {
        "log": { "loglevel": "warning" },
        "inbounds": [{
          "port": 2333,
          "listen": "0.0.0.0",
          "protocol": "vmess",
          "settings": { "clients": [{ "id": "${UUID}", "alterId": 0 }] },
          "streamSettings": { "network": "ws", "wsSettings": { "path": "${WS_PATH}" } }
        }],
        "outbounds": [{ "protocol": "freedom", "settings": {} }]
      }
EOF
    if [[ $FRONT == caddy ]]; then
      cat <<'EOF'
  caddyfile:
    content: |
      ${DOMAIN} {
      	handle ${WS_PATH} {
      		reverse_proxy v2ray:2333
      	}
      	handle {
      		header Content-Type "text/html; charset=utf-8"
      		respond "<!doctype html><html><head><title>It works!</title></head><body><h1>It works!</h1></body></html>" 200
      	}
      }

volumes:
  caddy_data:
    name: caddy_data
  caddy_config:
    name: caddy_config
EOF
    fi
  } > "$COMPOSE_FILE" || return 1
  compose config -q || die "compose.yaml 校验失败"
}

# nginx 模式下用户要在宝塔 / Nginx 里做的事。安装时打印，自检失败时也打印
nginx_hint() {
  step "宝塔 / Nginx 侧需要的配置"
  echo "1) 在宝塔里为 $DOMAIN 添加站点（纯静态即可），申请 SSL 证书并部署"
  echo "2) 打开该站点的「配置文件」，在 443 的 server 块里加入下面这段，保存后重载 Nginx："
  cat <<EOF

    location $WS_PATH {
        proxy_pass http://127.0.0.1:2333;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 300s;
    }

EOF
  echo "   不要用面板的「反向代理」功能整站反代，那会把根路径也转给 V2Ray；只加上面这个 location"
  echo "3) 证书续期由宝塔负责；路径或域名改了要同步改这段配置"
  if [[ $CDN == yes ]]; then
    echo "4) Cloudflare 侧：云朵橙色、SSL/TLS 选「完全（严格）」、WebSockets 开启"
  fi
}

vmess_link() {
  local json
  json=$(printf '{"v":"2","ps":"%s","add":"%s","port":"443","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"%s","tls":"tls","sni":"%s"}' \
    "$DOMAIN" "$DOMAIN" "$UUID" "$DOMAIN" "$WS_PATH" "$DOMAIN")
  printf 'vmess://%s' "$(printf '%s' "$json" | base64 -w0)"
}

# ---------------------------------------------------------------------------
# 自检
# ---------------------------------------------------------------------------
# 一、证书与 WebSocket：本机模拟一次握手，返回 101 说明 Caddy→V2Ray 链路正常
# Sec-WebSocket-Key 必须是 16 字节随机值的 base64（RFC 6455），V2Ray 用的
# gorilla/websocket 会校验解码后的长度，不是 16 字节一律回 400。下面用的是
# RFC 里的示例值（解码为 the sample nonce，正好 16 字节）。
# 不能用管道接 grep：握手成功后 curl 会一直等着读隧道数据，直到 --max-time
# 超时并以 28 退出，而脚本开了 pipefail，管道整体就成了失败——越成功越判失败。
# 无论哪种模式，本机 443 上都有反代（Caddy 或 Nginx），所以统一打 127.0.0.1:443
ws_ok() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --http1.1 --max-time 5 \
    --resolve "$DOMAIN:443:127.0.0.1" \
    -H "Connection: Upgrade" -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
    "https://$DOMAIN$WS_PATH" 2>/dev/null) || true
  [[ ${code//[[:space:]]/} == 101 ]]
}

# nginx 模式专用：绕过 Nginx 直接打 V2Ray 的 2333，把「V2Ray 没起来」和
# 「Nginx 反代 / 证书没配好」区分开，否则排查时不知道该看哪边
v2ray_ok() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --http1.1 --max-time 5 \
    -H "Host: $DOMAIN" -H "Connection: Upgrade" -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
    "http://127.0.0.1:2333$WS_PATH" 2>/dev/null) || true
  [[ ${code//[[:space:]]/} == 101 ]]
}

# 二、真实连接：启动一个临时 V2Ray 客户端，用当前 UUID 走一遍代理访问外网
#    能通过说明 UUID、路径、TLS 全部正确，而不只是端口通
#    caddy 模式：放进 Caddy 所在的 Docker 网络，直接连容器名 caddy
#    nginx 模式：Nginx 在宿主机上，用 host-gateway 让容器能连到宿主机的 443
e2e_ok() {
  local net dir hostport code server run_opts=()
  if [[ $FRONT == nginx ]]; then
    server=host.docker.internal
    run_opts=(--add-host "host.docker.internal:host-gateway")
  else
    net=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' caddy 2>/dev/null | awk '{print $1}')
    [[ -n $net ]] || return 1
    server=caddy
    run_opts=(--network "$net")
  fi
  mktmp dir || return 1
  chmod 700 "$dir" || return 1
  cat > "$dir/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{ "listen": "0.0.0.0", "port": 10808, "protocol": "socks", "settings": { "udp": false } }],
  "outbounds": [{
    "protocol": "vmess",
    "settings": { "vnext": [{ "address": "$server", "port": 443,
      "users": [{ "id": "$UUID", "alterId": 0, "security": "auto" }] }] },
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "tlsSettings": { "serverName": "$DOMAIN", "allowInsecure": true },
      "wsSettings": { "path": "$WS_PATH", "headers": { "Host": "$DOMAIN" } }
    }
  }]
}
EOF
  chmod 600 "$dir/config.json" || return 1
  E2E_CID_FILE="$dir/container.cid"
  E2E_CID_FILES+=("$E2E_CID_FILE")
  docker run -d --cidfile "$E2E_CID_FILE" --user 0:0 "${run_opts[@]}" -p 127.0.0.1::10808 \
    -v "$dir/config.json:/etc/v2ray/config.json:ro,Z" \
    "${E2E_IMAGE:-v2fly/v2fly-core:$V2FLY_TAG}" run -c /etc/v2ray/config.json >/dev/null 2>&1 || return 1
  sleep 3
  hostport=$(docker port "$(cat "$E2E_CID_FILE")" 10808/tcp 2>/dev/null | head -1 | sed 's/.*://')
  if [[ -n $hostport ]]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
      --socks5-hostname "127.0.0.1:$hostport" http://cp.cloudflare.com/generate_204 2>/dev/null || true)
    [[ $code != 204 ]] && code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
      --socks5-hostname "127.0.0.1:$hostport" http://www.gstatic.com/generate_204 2>/dev/null || true)
  fi
  docker rm -f "$(cat "$E2E_CID_FILE")" >/dev/null 2>&1 || true
  E2E_CID_FILE=""
  [[ ${code:-} == 204 ]]
}

# 三、CDN 边缘：上面两项都刻意绕开了 Cloudflare（ws_ok 用 --resolve 打本机，
#    e2e_ok 走 Docker 内网直连 caddy），源站再正常也照不出边缘的毛病。
#    这里按域名真实解析做一次 WebSocket 握手，客户端实际走的就是这条路：
#    既验边缘证书，也验 Cloudflare 的 WebSockets 开关和到源站的回程。
#    不加 -f，也不把 stderr 扔掉：失败时状态码和 curl 的原话就是线索，
#    以前只看成败、一律归咎于「多级子域」，一级子域撞上别的原因就把人带偏了。
CDN_CODE="" CDN_ERR=""
cdn_ok() {
  local out
  # 超时要给够：Cloudflare 回源连不上要等 15 秒以上才回 522，超时比它短就只能
  # 拿到 000，把「云防火墙没开 443」误判成证书或出网问题
  out=$(curl -sS -o /dev/null -w '\n%{http_code}' --http1.1 --max-time 35 \
    -H "Connection: Upgrade" -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
    "https://$DOMAIN$WS_PATH" 2>&1) || true
  CDN_CODE=${out##*$'\n'}; CDN_CODE=${CDN_CODE//[[:space:]]/}
  CDN_ERR=""
  # stderr 可能有多行、末尾带换行，压成一行方便嵌进提示里
  [[ $out == *$'\n'* ]] && CDN_ERR=$(printf '%s\n' "${out%$'\n'*}" | sed '/^[[:space:]]*$/d' | paste -sd ' ')
  # 握手成功后 curl 会等隧道数据直到超时，stderr 会多一条 timeout，不算错
  [[ $CDN_CODE == 101 ]]
}

cdn_hint() {
  local dots
  red "✗ 经 Cloudflare 握手失败，但源站是好的——问题在 CDN 这一跳"
  case ${CDN_CODE:-000} in
    000)
      echo "  没拿到 HTTP 响应，curl 的原话：${CDN_ERR:-（无）}"
      dots=$(tr -cd '.' <<<"$DOMAIN" | wc -c)
      if [[ $CDN_ERR == *"(28)"* ]]; then
        # TLS 已完成、请求发出后一直没回应：边缘收到了请求，卡在回源。
        # 前面的自检打 127.0.0.1 和 Docker 网桥，都不经过云厂商防火墙，所以是绿的
        echo "  请求发出后一直没有回应：Cloudflare 边缘收到了请求，但连不上你的源站 443。"
        echo "  前面几项自检走的是本机回环和 Docker 网桥，不经过云厂商防火墙，所以照不出这个问题。"
        echo "  1) 云厂商防火墙（Lightsail 控制台里的 Networking / 安全组）是否对所有来源放行 TCP 443，"
        echo "     系统里的 ufw 和它是两回事"
        echo "  2) Cloudflare 里如果还有指向本机的 AAAA 记录，IPv6 防火墙也要放行 443，或删掉该记录"
        echo "  3) 宝塔「安全」页的端口规则是否放行 443"
      elif (( dots >= 3 )); then
        echo "  域名看起来是多级子域。免费版 Universal SSL 只签 example.com 和 *.example.com，"
        echo "  通配符不覆盖 a.b.example.com，边缘拿不出证书就直接握手失败。"
        echo "  解决: 1) 换成一级子域（推荐，如 xxx.example.com）"
        echo "        2) 云朵改灰（仅 DNS），同时把本脚本的 CDN 选项改成 no"
        echo "        3) 购买 Advanced Certificate Manager 开启 Total TLS"
      else
        echo "  域名是一级子域，通配符证书应能覆盖。常见原因："
        echo "  1) 域名刚加进 Cloudflare，Universal SSL 还在签发中（最长 24 小时）：SSL/TLS → 边缘证书 里看状态"
        echo "  2) 本机到 Cloudflare 的出网不通或超时：换台机器或手机流量访问 https://$DOMAIN 对比"
      fi
      echo "  自查: curl -sSv -o /dev/null --max-time 60 https://$DOMAIN$WS_PATH 2>&1 | tail -20"
      ;;
    200|400|404|426)
      echo "  边缘返回 HTTP $CDN_CODE 而不是 101：请求没有被当作 WebSocket 升级转到 V2Ray。"
      echo "  1) Cloudflare 网络 → WebSockets 是否开启"
      echo "  2) 路径 $WS_PATH 在源站是否真的转给了 V2Ray（本机 443 已通过，多半是 1）"
      ;;
    403|503)
      echo "  边缘返回 HTTP $CDN_CODE：多半是 Cloudflare 的 WAF / Bot Fight Mode / Under Attack 模式拦下了。"
      echo "  给路径 $WS_PATH 加一条 WAF 跳过规则，或关掉这些功能"
      ;;
    520|521|522|523|524)
      echo "  边缘返回 HTTP $CDN_CODE：Cloudflare 连不上源站。前面的自检走本机回环和 Docker 网桥，"
      echo "  不经过云厂商防火墙，所以照不出来。检查 Lightsail 控制台 / 安全组是否对所有来源放行 TCP 443"
      echo "  （系统里的 ufw 和它是两回事），Cloudflare 里有指向本机的 AAAA 记录的话 IPv6 防火墙同样要放行"
      ;;
    525|526)
      echo "  边缘返回 HTTP $CDN_CODE：Cloudflare 到源站的 TLS 失败。"
      echo "  SSL/TLS 模式选「完全（严格）」时源站证书必须有效且未过期，SNI 要能匹配 $DOMAIN"
      ;;
    530)
      echo "  边缘返回 HTTP 530：源站侧 DNS / Tunnel 错误，看 Cloudflare 的错误页里的 1xxx 子码"
      ;;
    *)
      echo "  边缘返回 HTTP $CDN_CODE${CDN_ERR:+，curl: $CDN_ERR}"
      ;;
  esac
  echo "  排查后运行本脚本选「查看运行状态」即可重测"
}

# 等 fn 返回成功，最多 n 次，每次间隔 5 秒
wait_for() {
  local fn=$1 n=$2 i
  for ((i = 0; i < n; i++)); do
    if "$fn"; then echo; return 0; fi
    printf '.'; sleep 5
  done
  echo
  return 1
}

wait_caddy() {
  step "等待证书申请和服务启动（最多 3 分钟）"
  if ! wait_for ws_ok 36; then
    red "✗ 3 分钟内没有就绪，Caddy 最近的日志："
    docker logs --tail 20 caddy 2>&1 | grep -iE 'error|obtain|challenge' || docker logs --tail 20 caddy
    return 1
  fi
  grn "✓ HTTPS 证书有效，WebSocket 握手成功"
}

wait_nginx() {
  step "等待 V2Ray 启动"
  if ! wait_for v2ray_ok 6; then
    red "✗ V2Ray 在 127.0.0.1:2333 上没有响应，最近的日志："
    docker logs --tail 20 v2ray 2>&1 | tail -20
    return 1
  fi
  grn "✓ V2Ray 已在 127.0.0.1:2333 就绪"

  step "检查 Nginx 反代和证书（经本机 443）"
  port_in_use 443 || ylw "⚠ 443 端口上没有程序在监听，宝塔站点是不是还没建？"
  if ! wait_for ws_ok 6; then
    red "✗ 经 443 握手失败。V2Ray 本身是好的，问题在 Nginx 这一跳："
    echo "  1) 站点证书是否已申请并部署（curl -vI https://$DOMAIN 看证书）"
    echo "  2) location $WS_PATH 是否已加进 443 的 server 块并重载（nginx -t && nginx -s reload）"
    echo "  3) Upgrade / Connection 头是否带上（少了会返回 200 或 400 而不是 101）"
    return 1
  fi
  grn "✓ 证书有效，Nginx → V2Ray 握手成功"
}

wait_ready() {
  if [[ $FRONT == nginx ]]; then wait_nginx || return 1; else wait_caddy || return 1; fi

  step "真实连接测试（用当前 UUID 走一遍代理）"
  if e2e_ok; then
    grn "✓ 代理连通，UUID、路径、TLS 均正确"
    [[ $CDN != yes ]] && return 0
    step "经 Cloudflare 边缘测试（客户端实际走的路径）"
    if cdn_ok; then
      grn "✓ 经 Cloudflare 边缘握手成功，客户端走的这条路是通的"
      return 0
    fi
    cdn_hint
    return 1
  fi
  red "✗ 代理连不通。端口和证书没问题，多半是 UUID 或路径没生效"
  echo "  V2Ray 日志："
  docker logs --tail 20 v2ray 2>&1 | tail -20
  return 1
}

# ---------------------------------------------------------------------------
# 子命令
# ---------------------------------------------------------------------------
cmd_show() {
  local mode=${1:-auto} cols need ec ec_ok=""
  load_env
  [[ -n $DOMAIN ]] || die "还没有安装，请先运行「安装」"
  step "客户端配置"
  cat <<EOF
  地址:     $DOMAIN
  端口:     443
  UUID:     $UUID
  Alter Id: 0
  加密:     auto
  传输:     websocket
  路径:     $WS_PATH
  Host/SNI: $DOMAIN
  TLS:      开启
EOF
  echo
  echo "导入链接（v2rayN / Shadowrocket 可直接粘贴）："
  vmess_link; echo
  [[ $mode == plain ]] && return 0
  command -v qrencode >/dev/null || return 0
  # 纠错等级自适应：优先 M（容错 15%，能兜住终端渲染时个别行的错位），
  # 终端装不下就退回 L（7%，二维码小 8 列左右）。宽度按真实尺寸算，不能写死
  # 80 列——ASCII 输出每模块占 2 列，ANSIUTF8 占 1 列，所以需要的列数是前者的一半
  cols=$(tput cols 2>/dev/null || echo 80)
  for ec in M L; do
    need=$(vmess_link | qrencode -l "$ec" -t ASCII 2>/dev/null \
      | awk '{ if (length($0) > m) m = length($0) } END { print int(m / 2) }' || true)
    need=${need:-0}
    (( need == 0 )) && { ec_ok=L; break; }   # 量不出来就照旧画，别把二维码整个吞掉
    (( cols >= need )) && { ec_ok=$ec; break; }
  done
  if [[ -z $ec_ok ]]; then
    ylw "二维码至少需要 $need 列，当前终端 $cols 列，已跳过。拉宽窗口后运行「显示链接」即可"
    return 0
  fi
  echo
  echo "Shadowrocket 扫码导入（显示错乱时可只用上面的链接）："
  vmess_link | qrencode -l "$ec_ok" -t ANSIUTF8
}

cmd_install() {
  node_legacy_guard install || return 1
  preflight
  ylw "开始前请确认：Lightsail 防火墙已放行 TCP 80 和 443；域名 A 记录已指向本机静态 IP"
  load_env
  prompt_config
  prepare_low_memory || return 1
  install_deps
  install_docker
  open_firewall
  begin_recovery || return 1

  if [[ $FRONT == nginx ]]; then
    # 80/443 在 Nginx 手里，起不了临时网页服务，域名只能打印解析结果供人眼核对；
    # DNS 是否真的正确，由宝塔申请证书那一步来验证
    step "域名解析（nginx 模式不做 80 端口检查，DNS 由宝塔申请证书时验证）"
    show_dns
  else
    if container_running caddy && [[ $DOMAIN_CHANGED == yes ]]; then
      ylw "域名有变化，先停止 Caddy 以便检查新域名（脚本中途退出会自动恢复）"
      CADDY_STOPPED=yes
      compose stop caddy >/dev/null || return 1
    fi
    if ! container_running caddy; then
      # 从 nginx 模式切回来、或者机器上本来就有别的 web 服务时，443 也可能被占着，
      # check_domain 只查 80，这里把 443 一起拦下，免得 compose up 才报端口冲突
      port_in_use 443 && die "443 端口被占用（宝塔面板 / Nginx？）。要么停掉占用程序，要么前端模式选「已有 Nginx」"
      check_domain
    fi
  fi

  step "写入配置并启动"
  save_env || { fail_change "配置写入失败"; return 1; }
  write_compose || { fail_change "容器配置写入失败"; return 1; }
  if ! pull_images; then fail_change "拉取镜像失败"; return 1; fi
  # 配置内嵌在 compose.yaml 里，只改内容时 Compose 不会重建容器，
  # 会导致新 UUID / 路径不生效，所以这里强制重建。--remove-orphans 顺带处理
  # 模式切换：从 caddy 切到 nginx 时 compose.yaml 里没了 caddy 服务，旧容器会被删掉
  RECOVERY_UP=yes
  if ! compose up -d --force-recreate --remove-orphans; then
    fail_change "启动失败"; return 1
  fi
  CADDY_STOPPED=no

  if [[ $FRONT == nginx ]]; then
    nginx_hint
    if ! confirm "宝塔 / Nginx 侧已经配置好，现在开始自检？" y; then
      finish_recovery
      cmd_show
      echo
      ylw "配置好 Nginx 反代后，运行本脚本选「查看运行状态」即可自检。"
      grn "安装完成。以后重新运行本脚本即可更新、查看状态或修改配置。"
      return 0
    fi
  fi

  if ! wait_ready; then
    fail_change "安装自检未通过"; return 1
  fi
  finish_recovery

  cmd_show
  echo
  if [[ $CDN == yes && $FRONT == caddy ]]; then
    ylw "Cloudflare 设置：云朵改为橙色（已代理）；SSL/TLS 模式选「完全（严格）」；网络里 WebSockets 保持开启；不要开启「始终使用 HTTPS」"
  fi
  grn "安装完成。以后重新运行本脚本即可更新、查看状态或修改配置。"
}

# 拉镜像。回退过的标签是 rollback——那是本地打的，Docker Hub 上没有，
# 照常 compose pull 会整个失败。安装 / 改配置不该顺手换版本，所以
# 带 rollback 标签的服务跳过不拉，用本地已有的镜像
pull_images() {
  if [[ $V2FLY_TAG != rollback ]]; then compose pull -q v2ray || return 1; fi
  if [[ $FRONT == caddy && $CADDY_TAG != rollback ]]; then compose pull -q caddy || return 1; fi
}

cmd_update() {
  node_legacy_guard update || return 1
  preflight; need_docker
  [[ -f $COMPOSE_FILE ]] || die "还没有安装，请先运行「安装」"
  load_env
  begin_recovery || return 1
  if [[ $V2FLY_TAG == rollback ]]; then V2FLY_TAG=latest; fi
  if [[ $CADDY_TAG == rollback ]]; then CADDY_TAG=2; fi
  save_env || { fail_change "配置写入失败"; return 1; }
  step "拉取最新镜像并重建容器"
  if ! compose pull -q; then fail_change "拉取新镜像失败"; return 1; fi
  RECOVERY_UP=yes
  if ! compose up -d --force-recreate --remove-orphans; then fail_change "重建失败"; return 1; fi
  if ! wait_ready; then fail_change "新版本自检未通过"; return 1; fi
  finish_recovery
  cmd_status
}

cmd_status() {
  need_docker
  [[ -f $COMPOSE_FILE ]] || die "还没有安装"
  load_env
  step "容器状态"
  compose ps --format 'table {{.Name}}\t{{.Status}}'
  step "版本"
  docker exec v2ray v2ray version 2>/dev/null | head -1 || true
  if [[ $FRONT == nginx ]]; then
    echo "前端: 已有 Nginx（宝塔），V2Ray 监听 127.0.0.1:2333"
    echo "配置中的镜像标签: v2fly/v2fly-core:$V2FLY_TAG"
  else
    docker exec caddy caddy version 2>/dev/null | head -1 || true
    echo "配置中的镜像标签: v2fly/v2fly-core:$V2FLY_TAG , caddy:$CADDY_TAG"
  fi
  step "证书$([[ $FRONT == nginx ]] && echo '（由宝塔 / Nginx 管理）')"
  echo | openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN" 2>/dev/null \
    | openssl x509 -noout -issuer -enddate 2>/dev/null || red "读取证书失败"
  step "链路自检"
  if [[ $FRONT == nginx ]]; then
    if v2ray_ok; then grn "✓ V2Ray 在 127.0.0.1:2333 正常"; else red "✗ V2Ray 无响应: docker logs --tail 50 v2ray"; fi
    if ws_ok; then grn "✓ 证书和 Nginx 反代正常"; else red "✗ 经 443 握手失败: 检查站点证书和 location $WS_PATH 反代（nginx -t）"; fi
  else
    if ws_ok; then grn "✓ 证书和 WebSocket 正常"; else red "✗ WebSocket 握手失败: docker logs --tail 50 caddy"; fi
  fi
  if e2e_ok; then grn "✓ 代理连通"; else red "✗ 代理连不通: docker logs --tail 50 v2ray"; fi
  if [[ $CDN == yes ]]; then
    if cdn_ok; then grn "✓ 经 Cloudflare 边缘握手正常"; else cdn_hint; fi
  fi
}

cmd_uninstall() {
  node_legacy_guard uninstall || return 1
  preflight; need_docker
  [[ -f $COMPOSE_FILE ]] || die "没有找到安装"
  confirm "确认卸载 v2ray 和 caddy 容器？" n || exit 0
  compose down
  if confirm "同时删除 HTTPS 证书？（重装会重新申请）" n; then
    docker volume rm caddy_data caddy_config >/dev/null 2>&1 || true
  fi
  if confirm "同时删除配置目录 $STACK_DIR？" n; then
    rm -rf "$STACK_DIR"
  fi
  grn "已卸载。Docker 本身保留。"
}

# ---------------------------------------------------------------------------
# 多节点：每个节点独立项目；元数据只按 JSON 解析，不执行配置中的代码。
# ---------------------------------------------------------------------------
node_python() {
  command -v python3 >/dev/null || { red '多节点管理需要 python3，请先手动安装。'; return 1; }
  python3 - "$STACK_DIR" "$@" <<'PY'
import sys,os,json,re,uuid,base64,pathlib,fcntl
root=pathlib.Path(sys.argv[1]); action=sys.argv[2]; args=sys.argv[3:]
nodes=root/'nodes'
def fail(s): raise ValueError(s)
def domain(s):
 if not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?',s) or '.' not in s or '..' in s: fail('域名格式不正确')
 return s.lower()
def path(s):
 if not re.fullmatch(r'/[A-Za-z0-9._~-]+',s): fail('路径只能包含字母、数字和 . _ ~ -')
 return s
def ident(s):
 if not re.fullmatch(r'(?:[1-9][0-9]*|[a-z][a-z0-9-]{0,31})',s): fail('节点标识须为小写字母开头，最多 32 个字母、数字或横线')
 return s
def port(s):
 n=int(s)
 if not 1024<=n<=65535: fail('本地端口必须在 1024–65535 之间')
 return n
def write(p,data):
 p.parent.mkdir(parents=True,exist_ok=True); os.chmod(p.parent,0o700)
 with open(p,'w') as f:f.write(data)
 os.chmod(p,0o600)
def allnodes():
 return [json.loads(p.read_text()) for p in sorted(nodes.glob('*/metadata.json'))]
def legacy():
 env={}
 p=root/'.env'
 if p.exists():
  for line in p.read_text().splitlines():
   if '=' in line and not line.lstrip().startswith('#'):
    k,v=line.split('=',1);env[k]=v.strip().strip('"\'')
 return env
def remote(address,p,u,ws,host='',sni=''):
 p=int(p)
 if not 1<=p<=65535:fail('远端端口不正确')
 return dict(domain=domain(address),port=p,uuid=str(uuid.UUID(u)),path=path(ws),host=domain(host or address),sni=domain(sni or address))
def readnode(s):
 ident(s);return json.loads((nodes/s/'metadata.json').read_text())
def render(n):
 outbound={'protocol':'freedom','settings':{}}
 if n['outbound']=='relay':
  r=n['remote'];outbound={'tag':'relay','protocol':'vmess','settings':{'vnext':[{'address':r['domain'],'port':r['port'],'users':[{'id':r['uuid'],'alterId':0,'security':'auto'}]}]},'streamSettings':{'network':'ws','security':'tls','tlsSettings':{'serverName':r['sni'],'allowInsecure':False},'wsSettings':{'path':r['path'],'headers':{'Host':r['host']}}}}
 config={'log':{'loglevel':'warning'},'inbounds':[{'listen':'0.0.0.0','port':2333,'protocol':'vmess','settings':{'clients':[{'id':n['uuid'],'alterId':0}]},'streamSettings':{'network':'ws','wsSettings':{'path':n['path']}}}],'outbounds':[outbound]}
 folder=nodes/n['id'];write(folder/'config.json',json.dumps(config,ensure_ascii=False,indent=2)+'\n')
 # inline content 沿用现有 Compose 的 SELinux 隔离；域名等经过白名单校验。
 text='name: v2ray-node-'+n['id']+'\nservices:\n  v2ray:\n    image: '+json.dumps(n['image'])+'\n    container_name: v2ray-node-'+n['id']+'\n    restart: unless-stopped\n    command: run -c /etc/v2ray/config.json\n    ports:\n      - "127.0.0.1:'+str(n['port'])+':2333"\n    configs:\n      - source: node_config\n        target: /etc/v2ray/config.json\nconfigs:\n  node_config:\n    content: |\n'+''.join('      '+line+'\n' for line in json.dumps(config,ensure_ascii=False,indent=2).splitlines())
 write(folder/'compose.yaml',text)
def ingress():
 env=legacy(); ns=allnodes(); caddy=[n for n in ns if n['front']=='caddy']; haslegacy=env.get('DOMAIN') and env.get('FRONT','caddy')!='nginx'
 if not caddy and not haslegacy:return
 domains={}
 if haslegacy:
  domains.setdefault(domain(env['DOMAIN']),[]).append((path(env['WS_PATH']),'v2ray:2333'))
 for n in caddy:domains.setdefault(n['domain'],[]).append((n['path'],'v2ray-node-'+n['id']+':2333'))
 text=''
 for d,routes in sorted(domains.items()):
  text+=d+' {\n'
  for p,up in routes:text+='  handle '+p+' {\n    reverse_proxy '+up+'\n  }\n'
  text+='  handle {\n    respond "It works!" 200\n  }\n}\n'
 write(root/'ingress'/'Caddyfile',text)
 # 网络由 Caddy 项目创建，各个节点连接同一个网络；只有 Caddy 入口共享。
 if haslegacy:
  text='services:\n  caddy:\n    command: caddy run --config /managed/Caddyfile --adapter caddyfile\n    volumes:\n      - ./ingress:/managed:ro,Z\n'
 else:
  tag=env.get('CADDY_TAG','2')
  if not re.fullmatch(r'[A-Za-z0-9_.-]+',tag):fail('Caddy 镜像标签不正确')
  text='name: v2ray-ingress\nservices:\n  caddy:\n    image: caddy:'+tag+'\n    container_name: v2ray-ingress\n    restart: unless-stopped\n    command: caddy run --config /managed/Caddyfile --adapter caddyfile\n    ports:\n      - "80:80"\n      - "443:443"\n    volumes:\n      - ./ingress:/managed:ro,Z\n      - node_caddy_data:/data\n      - node_caddy_config:/config\nvolumes:\n  node_caddy_data:\n  node_caddy_config:\n'
 write(root/'ingress.yaml',text)
try:
 if action=='allocate':
  nodes.mkdir(parents=True,exist_ok=True);os.chmod(nodes,0o700)
  with open(nodes/'.id-sequence','a+') as f:
   os.chmod(nodes/'.id-sequence',0o600);fcntl.flock(f,fcntl.LOCK_EX);f.seek(0)
   saved=f.read().strip();high=int(saved or '0')
   high=max([high]+[int(p.name) for p in nodes.iterdir() if p.name.isdigit()])
   while (nodes/str(high+1)).exists():high+=1
   s=str(high+1);(nodes/s).mkdir(mode=0o700)
   f.seek(0);f.truncate();f.write(s+'\n');f.flush();os.fsync(f.fileno());print(s)
 elif action=='validate-label':
  label=args[0].strip()
  if not label or len(label)>80 or any(ord(c)<32 for c in label):fail('节点名称须为 1–80 个可见字符')
  print(label)
 elif action=='validate-domain':print(domain(args[0].strip()))
 elif action=='entries':
  env=legacy();entries={(n['domain'].lower(),n['front']) for n in allnodes()}
  if env.get('DOMAIN'):entries.add((domain(env['DOMAIN']),env.get('FRONT','caddy')))
  for d,front in sorted(entries):print(d+'\t'+front)
 elif action=='create':
  s,d,front,out,p,ws,u,image=args[:8];ident(s);d=domain(d);path(ws);port(p);uuid.UUID(u)
  if front not in ('nginx','caddy') or out not in ('direct','relay'):fail('入口或出口方式不正确')
  if not re.fullmatch(r'(?:v2fly/v2fly-core:[A-Za-z0-9_.-]+|sha256:[a-f0-9]{64})',image):fail('镜像标签不正确')
  ns=allnodes();env=legacy()
  for n in ns:
   if n['id']!=s and (n['port']==int(p) or (n['domain']==d and n['path']==ws)):fail('端口或入口路径已被其他节点使用')
   if n['domain']==d and n['front']!=front:fail('同一域名不能同时使用 Caddy 和 Nginx')
  if env.get('DOMAIN'):
   if int(p)==2333 or (d==env['DOMAIN'] and ws==env.get('WS_PATH')):fail('端口或路径与旧节点冲突')
   if (env.get('FRONT','caddy')=='nginx') != (front=='nginx'):fail('已有入口占用 80/443，新增节点须沿用相同的 HTTPS 管理方式')
  if ns and any(n['front']!=front for n in ns):fail('Caddy 与 Nginx 会争用 80/443，须使用同一种入口管理方式')
  n=dict(id=s,domain=d,front=front,outbound=out,port=int(p),path=ws,uuid=str(uuid.UUID(u)),image=image)
  if out=='relay':
   if args[8]=='link':
    link=args[9]
    if not link.startswith('vmess://'):fail('仅支持 vmess:// 链接')
    raw=link[8:];v=json.loads(base64.b64decode(raw+'='*((-len(raw))%4),validate=True))
    if any(v.get(k) not in (None,'',False,'false','0',0) for k in ('allowInsecure','alpn','fp','packetEncoding')):fail('链接包含暂不支持的 TLS 或传输选项')
    if v.get('net')!='ws' or v.get('tls')!='tls' or str(v.get('aid','0'))!='0' or v.get('scy','auto') not in ('auto','aes-128-gcm','chacha20-poly1305') or v.get('type','none') not in ('none',''):fail('仅支持 alterId=0 的 VMess + WS + TLS 链接')
    n['remote']=remote(v['add'],v['port'],v['id'],v['path'],v.get('host'),v.get('sni'))
   elif args[8]=='preserve':n['remote']=readnode(s)['remote']
   else:n['remote']=remote(*args[9:15])
  write(nodes/s/'metadata.json',json.dumps(n,ensure_ascii=False,indent=2)+'\n');render(n)
 elif action=='get':
  n=readnode(args[0]);v=n[args[1]];print(v if not isinstance(v,(dict,list)) else json.dumps(v))
 elif action=='list':
  env=legacy()
  if env.get('DOMAIN'):print('旧节点\t'+env['DOMAIN']+' '+env.get('WS_PATH','')+'\t保留原配置，使用旧菜单管理')
  for n in allnodes():print(n['id']+' ('+n.get('label',n['id'])+')\t'+n['domain']+' '+n['path']+'\t'+('本机直出' if n['outbound']=='direct' else '中转 '+n['remote']['domain'])+'\t'+n['front'])
 elif action=='ids':
  for n in allnodes():print(n['id'])
 elif action=='ingress':ingress()
 elif action=='link':
  n=readnode(args[0]);v=dict(v='2',ps=n.get('label',n['id']),add=n['domain'],port='443',id=n['uuid'],aid='0',scy='auto',net='ws',type='none',host=n['domain'],path=n['path'],tls='tls',sni=n['domain']);print('vmess://'+base64.b64encode(json.dumps(v).encode()).decode())
 elif action=='label':
  n=readnode(args[0]);label=args[1]
  if not label or len(label)>80 or any(ord(c)<32 for c in label):fail('节点名称须为 1–80 个可见字符')
  n['label']=label;write(nodes/n['id']/'metadata.json',json.dumps(n,ensure_ascii=False,indent=2)+'\n')
 elif action=='image':
  n=readnode(args[0]);n['image']=args[1];write(nodes/n['id']/'metadata.json',json.dumps(n,indent=2));render(n)
 else:fail('未知元数据操作')
except (ValueError,KeyError,OSError,TypeError,IndexError) as e:
 print('节点配置错误：'+str(e),file=sys.stderr);sys.exit(1)
PY
}

node_compose() { docker compose --project-directory "$STACK_DIR/nodes/$NODE_ID" "$@"; }
node_get() { node_python get "$NODE_ID" "$1"; }
node_legacy_guard() {
  if [[ -f $STACK_DIR/ingress.yaml ]] || { [[ -d $STACK_DIR/nodes ]] && [[ -n $(node_python ids) ]]; }; then
    red '存在独立节点。旧安装/更新/卸载会影响共享入口，请使用节点管理；旧配置已保留。'
    return 1
  fi
  return 0
}

node_ingress_apply() {
  local force=${1:-no} legacy=no name network project ids previous='' changed=yes caddy_image checkdir
  ids=$(node_python ids) || return 1
  if [[ -z $ids && ! -f $COMPOSE_FILE && -f $STACK_DIR/ingress.yaml ]]; then
    project=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' v2ray-ingress 2>/dev/null || true)
    [[ -z $project || $project == v2ray-ingress ]] || return 1
    docker compose --project-directory "$STACK_DIR" -f "$STACK_DIR/ingress.yaml" down || return 1
    rm -f "$STACK_DIR/ingress.yaml" "$STACK_DIR/ingress/Caddyfile"
    return 0
  fi
  if [[ -f $COMPOSE_FILE ]]; then
    # 仅读取旧 FRONT，禁止执行 .env 内容。
    if ! grep -q '^FRONT=nginx$' "$ENV_FILE"; then legacy=yes; fi
  fi
  if [[ -f $STACK_DIR/ingress/Caddyfile ]]; then previous=$(cat "$STACK_DIR/ingress/Caddyfile"); fi
  node_python ingress || return 1
  if [[ -n $previous && $previous == $(cat "$STACK_DIR/ingress/Caddyfile" 2>/dev/null) ]]; then changed=no; fi
  [[ -f $STACK_DIR/ingress.yaml ]] || return 0
  if [[ -n ${NODE_INGRESS_IMAGE:-} && $legacy == no ]]; then
    python3 - "$STACK_DIR/ingress.yaml" "$NODE_INGRESS_IMAGE" <<'PYIMAGE'
import sys,re
p=sys.argv[1];s=open(p).read();s=re.sub(r'    image: .*','    image: "'+sys.argv[2]+'"',s);open(p,'w').write(s)
PYIMAGE
  fi
  if [[ $legacy == yes ]]; then
    name=caddy;
    project=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' caddy 2>/dev/null || true)
    [[ $project == v2ray ]] || { red '已有 caddy 容器不属于旧项目，停止修改入口'; return 1; }
    network=v2ray_default
    if ! docker inspect -f '{{.Config.Cmd}}' "$name" 2>/dev/null | grep -q /managed/Caddyfile; then
      caddy_image=$(docker inspect -f '{{.Image}}' caddy) || return 1
      mktmp checkdir || return 1
      E2E_CID_FILES+=("$checkdir/caddy-check.cid")
      docker run --rm --cidfile "$checkdir/caddy-check.cid" --network none -v "$STACK_DIR/ingress:/managed:ro,Z" "$caddy_image" caddy validate --config /managed/Caddyfile --adapter caddyfile || return 1
      ylw '首次接管标准 Caddy 入口需要重建 Caddy，现有连接会短暂中断。'
      if [[ $NODE_TX_ACTIVE == yes ]]; then touch "$NODE_TX_BACKUP/caddy.changed"; fi
      docker compose --project-directory "$STACK_DIR" -f "$COMPOSE_FILE" -f "$STACK_DIR/ingress.yaml" up -d --no-deps --pull never caddy || return 1
    fi
  else
    name=v2ray-ingress; network=v2ray-ingress_default
    node_owner "$name" v2ray-ingress || return 1
    if ! container_running "$name"; then
      docker compose --project-directory "$STACK_DIR" -f "$STACK_DIR/ingress.yaml" up -d caddy || return 1
    fi
  fi
  local id
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    if [[ $(node_python get "$id" front) == caddy ]]; then
      if ! docker inspect -f '{{json .NetworkSettings.Networks}}' "v2ray-node-$id" | grep -q "\"$network\""; then
        docker network connect "$network" "v2ray-node-$id" || return 1
      fi
    fi
  done < <(node_python ids)
  [[ $changed != no || $force == yes ]] || return 0
  ylw '共享 Caddy 入口配置变化，现有 WebSocket 连接可能需要重连。'
  docker exec "$name" caddy validate --config /managed/Caddyfile --adapter caddyfile || return 1
  docker exec "$name" caddy reload --config /managed/Caddyfile --adapter caddyfile
}

node_hint() {
  local d p port
  d=$(node_get domain); p=$(node_get path); port=$(node_get port)
  echo "请在 $d 的 HTTPS server 块加入以下内容并重载 Nginx："
  cat <<EOF
    location = $p {
        proxy_pass http://127.0.0.1:$port;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 300s;
    }
EOF
}

node_owner() {
  local name=$1 expected=$2 project
  if docker inspect "$name" >/dev/null 2>&1; then
    project=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$name" 2>/dev/null || true)
    [[ $project == "$expected" ]] || { red "同名容器 $name 不属于本项目，停止操作"; return 1; }
  fi
}

node_ask() {
  local reply
  read -r -u "$IN" -p "$1${2:+ [$2]}: " reply || return 1
  printf '%s' "${reply:-$2}"
}

node_option() {
  if [[ $advanced == yes ]]; then ask "$1" "$2"; else printf '%s' "$2"; fi
}

node_select() {
  local choice i=0 id listing
  local ids=()
  listing=$(node_python ids) || return 1
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    ids+=("$id"); i=$((i+1))
    printf '%s) %s (%s)\n' "$i" "$(node_python get "$id" label 2>/dev/null || printf '%s' "$id")" "$id"
  done <<< "$listing"
  if (( ${#ids[@]} == 0 )); then ylw '暂无可管理的新节点；旧节点使用旧菜单管理。'; return 1; fi
  echo '0) 返回'
  while true; do
    choice=$(node_ask '选择节点' '1') || return 1
    [[ $choice != 0 ]] || return 1
    if [[ $choice =~ ^[1-9][0-9]*$ ]] && (( ${#choice} < 10 && choice <= ${#ids[@]} )); then break; fi
    ylw '选择无效，请输入列表中的编号。'
  done
  NODE_ID=${ids[choice-1]}
  node_get id >/dev/null || return 1
  node_owner "v2ray-node-$NODE_ID" "v2ray-node-$NODE_ID" || return 1
}

node_choice() {
  local choice
  while true; do
    choice=$(node_ask "$1" "$2") || { printf 0; return; }
    if [[ $choice =~ ^[0-9]$ && $3 == *"$choice"* ]]; then printf '%s' "$choice"; return; fi
    ylw '选择无效，请输入列表中的编号。' >&2
  done
}

node_ingress_select() {
  local entry domain choice listing i=0 default='' current_domain='' current_front='' busy=no
  local domains=() fronts=()
  if [[ $edit == yes ]]; then current_domain=$(node_get domain); current_front=$(node_get front); fi
  listing=$(node_python entries) || return 1
  while IFS=$'\t' read -r domain front; do
    [[ -n $domain ]] || continue
    domains+=("$domain"); fronts+=("$front"); i=$((i+1))
    printf '%s) 复用 %s (%s)\n' "$i" "$domain" "$front"
    if [[ $domain == "$current_domain" && $front == "$current_front" ]]; then default=$i; fi
  done <<< "$listing"
  if (( i == 0 )); then ylw '暂无已登记的入口，请选择新域名；已有手工配置不会自动导入。'; fi
  local caddy=$((i+1)) nginx=$((i+2))
  printf '%s) Caddy 新域名\n%s) 已有 Nginx 新域名\n0) 返回\n' "$caddy" "$nginx"
  if port_in_use 80 || port_in_use 443; then busy=yes; fi
  if [[ -z $default ]]; then
    if (( i > 0 )); then default=1
    elif [[ $busy == yes ]]; then default=$nginx
    else default=$caddy; fi
  fi
  while true; do
    choice=$(node_ask '入口选择' "$default") || return 1
    [[ $choice != 0 ]] || return 1
    if [[ ! $choice =~ ^[1-9][0-9]*$ ]] || (( ${#choice} >= 10 || choice > nginx )); then ylw '选择无效，请输入列表中的编号。'; continue; fi
    if (( choice <= i )); then d=${domains[choice-1]}; front=${fronts[choice-1]}; return; fi
    if (( choice == caddy )); then front=caddy; else front=nginx; fi
    if [[ $front == caddy && $busy == yes ]] && ! container_running caddy && ! container_running v2ray-ingress; then
      ylw '80/443 已被占用，请选择已有 Nginx 或复用已登记入口。'; continue
    fi
    while true; do
      d=$(node_ask '入口域名（0 返回）' "$current_domain") || return 1
      [[ $d != 0 ]] || return 1
      if d=$(node_python validate-domain "$d"); then return; fi
    done
  done
}

node_show() {
  local link
  link=$(node_python link "$NODE_ID") || return 1
  echo "$link"
  if command -v qrencode >/dev/null; then printf '%s' "$link" | qrencode -t ANSIUTF8; fi
  [[ $(node_get front) != nginx ]] || node_hint
}

node_test() {
  local DOMAIN UUID WS_PATH FRONT V2FLY_TAG code
  DOMAIN=$(node_get domain); UUID=$(node_get uuid); WS_PATH=$(node_get path); FRONT=nginx
  V2FLY_TAG=$(node_get image)
  local E2E_IMAGE=$V2FLY_TAG
  V2FLY_TAG=${V2FLY_TAG#*:}
  if ws_ok; then grn '✓ HTTPS / WebSocket 入口正常'; else red '✗ HTTPS 入口失败，请检查证书及反向代理'; return 1; fi
  if e2e_ok; then grn '✓ 此节点代理链路连通；请用 Shadowrocket 核对出口 IP'; else red '✗ 出口链路不通，请查看此节点日志'; return 1; fi
}

# 变更只影响选定节点；失败保留备份并使用原镜像 ID 恢复。
node_local_ok() {
  local code p ws
  p=$(node_get port); ws=$(node_get path)
  code=$(curl -s -o /dev/null -w '%{http_code}' --http1.1 --max-time 2 \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    "http://127.0.0.1:$p$ws" 2>/dev/null || true)
  [[ $code == 101 ]]
}

node_ready() {
  wait_for node_local_ok 6 || return 1
  if [[ $(node_get front) == caddy ]]; then
    local DOMAIN WS_PATH
    DOMAIN=$(node_get domain); WS_PATH=$(node_get path)
    wait_for ws_ok 36 || return 1
    node_test || return 1
  else
    ylw 'V2Fly 本地入口已就绪；Nginx 反代配置完成后请在管理菜单测试连接。'
  fi
}

node_apply() {
  local backup=$1 oldimage=$2 existed=$3
  if node_compose config -q && node_compose run --rm --no-deps --pull never v2ray test -c /etc/v2ray/config.json && node_compose up -d --no-deps --force-recreate --pull never v2ray; then
    if { [[ $(node_get front) != caddy ]] || node_ingress_apply; } && node_ready; then return 0; fi
  fi
  red '节点变更失败，正在恢复。'
  node_recover "$backup" "$oldimage" "$existed" || red "恢复失败，备份：$backup"
  return 1
}

node_snapshot() {
  local backup=$1
  [[ ! -f $STACK_DIR/ingress.yaml ]] || cp -p "$STACK_DIR/ingress.yaml" "$backup/shared.yaml" || return 1
  [[ ! -f $STACK_DIR/ingress/Caddyfile ]] || cp -p "$STACK_DIR/ingress/Caddyfile" "$backup/shared.Caddyfile" || return 1
  docker inspect -f '{{.Image}}' caddy > "$backup/caddy.image" 2>/dev/null || true
  docker inspect -f '{{.Config.Cmd}}' caddy > "$backup/caddy.command" 2>/dev/null || true
  docker inspect -f '{{.Image}}' v2ray-ingress > "$backup/ingress.image" 2>/dev/null || true
  chmod 600 "$backup/"* || return 1
  NODE_TX_BACKUP=$backup NODE_TX_ID=$NODE_ID NODE_TX_IMAGE=${2:-} NODE_TX_EXISTED=${3:-no} NODE_TX_ACTIVE=yes
}

node_restore_files() {
  local backup=$1 file
  for file in metadata.json config.json compose.yaml; do
    [[ ! -f $backup/$file ]] || cp -p "$backup/$file" "$STACK_DIR/nodes/$NODE_ID/$file" || return 1
  done
}

node_recover() {
  local backup=$1 oldimage=$2 existed=$3
  NODE_TX_ACTIVE=no
  if [[ $existed == yes ]]; then
    mkdir -p "$STACK_DIR/nodes/$NODE_ID"
    node_restore_files "$backup" || return 1
    [[ -n $oldimage ]] || { red "找不到旧镜像 ID，备份：$backup"; return 1; }
    node_python image "$NODE_ID" "$oldimage" || return 1
    node_compose up -d --no-deps --force-recreate --pull never v2ray || return 1
  else
    if [[ -f $STACK_DIR/nodes/$NODE_ID/compose.yaml ]]; then node_compose down || return 1; fi
    rm -rf "$STACK_DIR/nodes/$NODE_ID"
  fi
  # 首次接管旧 Caddy 失败：原 compose 未变，使用原镜像 ID 恢复命令和挂载。
  if [[ -f $backup/caddy.changed && -s $backup/caddy.image ]] && ! grep -q /managed/Caddyfile "$backup/caddy.command"; then
    printf 'services:\n  caddy:\n    image: "%s"\n' "$(cat "$backup/caddy.image")" > "$backup/caddy-rollback.yaml"
    chmod 600 "$backup/caddy-rollback.yaml"
    docker compose --project-directory "$STACK_DIR" -f "$COMPOSE_FILE" -f "$backup/caddy-rollback.yaml" up -d --no-deps --force-recreate --pull never caddy || return 1
  elif [[ ! -s $backup/ingress.image && ! -s $backup/caddy.image && -f $STACK_DIR/ingress.yaml ]]; then
    docker compose --project-directory "$STACK_DIR" -f "$STACK_DIR/ingress.yaml" down || return 1
  fi
  if [[ -f $backup/shared.yaml ]]; then cp -p "$backup/shared.yaml" "$STACK_DIR/ingress.yaml"; else rm -f "$STACK_DIR/ingress.yaml"; fi
  if [[ -f $backup/shared.Caddyfile ]]; then
    mkdir -p "$STACK_DIR/ingress"; cp -p "$backup/shared.Caddyfile" "$STACK_DIR/ingress/Caddyfile"
    local NODE_INGRESS_IMAGE=''
    [[ ! -s $backup/ingress.image ]] || NODE_INGRESS_IMAGE=$(cat "$backup/ingress.image")
    node_ingress_apply yes || return 1
  else rm -f "$STACK_DIR/ingress/Caddyfile"; fi
  ylw "已恢复；变更备份保留在 $backup"
}

cmd_node_add() {
  local edit=${1:-no} d front out p ws u image mode link rd rp ru rw oldimage='' backup existed=no label advanced=no previousimage='' rh rs
  preflight
  command -v docker >/dev/null || { red '新增节点需要先手动准备 Docker Engine 和 Docker Compose。'; return 1; }
  need_docker
  local tool
  for tool in python3 curl openssl ss; do command -v "$tool" >/dev/null || { red "缺少 ${tool}，请先手动安装再新增节点。"; return 1; }; done
  command -v python3 >/dev/null || { red '请手动安装 python3 后再管理多节点。'; return 1; }
  if [[ $edit == yes ]]; then existed=yes; previousimage=$(node_get image) || return 1; else NODE_ID=''; fi
  while true; do
    label=$(node_ask '节点名称，例如 韩国直出 / 韩国转日本（0 返回）' "$(if [[ $edit == yes ]]; then node_get label 2>/dev/null || node_get id; fi)") || return 0
    [[ $label != 0 ]] || return 0
    if label=$(node_python validate-label "$label"); then break; fi
  done
  node_ingress_select || return 0
  if confirm '是否修改高级设置（端口、UUID、路径、镜像）？' n; then advanced=yes; fi
  p=$(node_option '本地端口' "$(if [[ $edit == yes ]]; then node_get port; else python3 - "$STACK_DIR" <<'PY'
import sys,json,pathlib,socket
used={2333}
for p in (pathlib.Path(sys.argv[1])/'nodes').glob('*/metadata.json'):used.add(json.loads(p.read_text())['port'])
for port in range(2334,65536):
 if port in used:continue
 s=socket.socket()
 try:s.bind(('127.0.0.1',port));print(port);break
 except OSError:pass
 finally:s.close()
PY
fi)")
  if [[ $edit != yes || $p != $(node_get port) ]] && port_in_use "$p"; then red '本地端口已被占用'; return 1; fi
  ws=$(node_option 'WebSocket 路径' "$(if [[ $edit == yes ]]; then node_get path; else printf '/%s' "$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"; fi)")
  u=$(node_option 'UUID' "$(if [[ $edit == yes ]]; then node_get uuid; else python3 -c 'import uuid;print(uuid.uuid4())'; fi)")
  image=$(node_option 'V2Fly 镜像标签' "$(if [[ $edit == yes ]]; then node_get image | sed 's|v2fly/v2fly-core:||'; else echo latest; fi)"); [[ $image == sha256:* ]] || image="v2fly/v2fly-core:$image"
  printf '%s\n' '1) 本机直出' '2) 远端 VMess + WS + TLS 中转（失败不直出）' '0) 返回'
  mode=$(node_choice '出口选择' "$(if [[ $edit == yes && $(node_get outbound) == relay ]]; then echo 2; else echo 1; fi)" '012'); out=direct
  local remote_args=()
  case $mode in
    1) ;;
    2)
      out=relay
      printf '%s\n' '1) 导入 vmess:// 链接' '2) 手动填写'
      local remote_choices=012
      if [[ $edit == yes && $(node_get outbound) == relay ]]; then echo '3) 保留现有远端'; remote_choices=0123; fi
      echo '0) 返回'
      mode=$(node_choice '远端配置' "$(if [[ $edit == yes && $(node_get outbound) == relay ]]; then echo 3; else echo 1; fi)" "$remote_choices")
      [[ $mode != 0 ]] || return 0
      if [[ $mode == 1 ]]; then link=$(ask '日本节点 vmess:// 链接' ''); remote_args=(link "$link")
      elif [[ $mode == 2 ]]; then
        rd=$(ask '远端域名' ''); rp=$(ask '远端端口' '443'); ru=$(ask '远端 UUID' ''); rw=$(ask '远端 WS 路径' '')
        rh=$(ask '远端 WebSocket Host' "$rd"); rs=$(ask '远端 TLS SNI' "$rd")
        remote_args=(manual "$rd" "$rp" "$ru" "$rw" "$rh" "$rs")
      elif [[ $mode == 3 && $edit == yes && $(node_get outbound) == relay ]]; then
        remote_args=(preserve)
      else return 1; fi ;;
    0) return 0 ;;
    *) return 1 ;;
  esac
  echo "节点 ${label} (${NODE_ID:-自动编号})；入口 ${d}${ws} (${front})；本地端口 ${p}；出口 ${out}"
  [[ $front != nginx ]] || ylw '创建后仍需手动添加 Nginx 路径配置。'
  confirm '确认应用此节点？' n || return 0
  if [[ $edit == no ]]; then NODE_ID=$(node_python allocate) || return 1; fi
  mkdir -p "$STACK_DIR/nodes"; chmod 700 "$STACK_DIR/nodes"
  node_owner "v2ray-node-$NODE_ID" "v2ray-node-$NODE_ID" || return 1
  backup=$(mktemp -d "$STACK_DIR/.node-recovery.XXXXXX"); chmod 700 "$backup"
  if [[ $existed == yes ]]; then
    cp -p "$STACK_DIR/nodes/$NODE_ID/"* "$backup/" || return 1
    oldimage=$(docker inspect -f '{{.Image}}' "v2ray-node-$NODE_ID" 2>/dev/null || true)
  fi
  node_snapshot "$backup" "$oldimage" "$existed" || return 1
  if [[ $existed == yes && $image == "$previousimage" ]]; then
    [[ -n $oldimage ]] || { NODE_TX_ACTIVE=no; red "无法读取旧镜像 ID，停止修改；备份：$backup"; return 1; }
    image=$oldimage
  fi
  if ! node_python create "$NODE_ID" "$d" "$front" "$out" "$p" "$ws" "$u" "$image" ${remote_args[@]+"${remote_args[@]}"}; then
    if [[ $existed == yes ]]; then
      node_restore_files "$backup" || return 1
    else rm -rf "$STACK_DIR/nodes/$NODE_ID"; fi
    NODE_TX_ACTIVE=no
    return 1
  fi
  # 下载镜像为明确的创建节点操作所需，不涉及主机依赖安装。
  if [[ $image != sha256:* ]] && ! node_compose pull -q v2ray; then
    NODE_TX_ACTIVE=no
    if [[ $existed == yes ]]; then node_restore_files "$backup"; else rm -rf "$STACK_DIR/nodes/$NODE_ID"; fi
    red "拉取失败，旧节点未改变；备份：$backup"; return 1
  fi
  if ! node_python label "$NODE_ID" "$label"; then node_recover "$backup" "$oldimage" "$existed"; return 1; fi
  if ! node_apply "$backup" "$oldimage" "$existed"; then return 1; fi
  NODE_TX_ACTIVE=no
  rm -rf "$backup"
  node_show
  grn '节点配置已应用。分别导入各节点链接，在客户端切换。'
}

cmd_node_manage() {
  need_docker; node_select || return 1
  printf '%s\n' '1) 链接/二维码' '2) 修改' '3) 测试连接' '4) 日志' '5) 重启' '6) 删除' '7) 更新镜像' '0) 返回'
  case "$(node_choice '操作' '1' '01234567')" in
    1) node_show ;;
    2) cmd_node_add yes ;;
    3) node_test ;;
    4) docker logs --tail 100 "v2ray-node-$NODE_ID" ;;
    5) node_compose restart v2ray ;;
    6)
      confirm "删除节点 ${NODE_ID}？" n || return 0
      local backup oldimage
      backup=$(mktemp -d "$STACK_DIR/.node-recovery.XXXXXX")
      cp -p "$STACK_DIR/nodes/$NODE_ID/"* "$backup/" || return 1
      oldimage=$(docker inspect -f '{{.Image}}' "v2ray-node-$NODE_ID" 2>/dev/null || true)
      node_snapshot "$backup" "$oldimage" yes || return 1
      if ! node_compose down; then node_recover "$backup" "$oldimage" yes; return 1; fi
      # 元数据暂移出列表，Compose 和原镜像 ID 留在受保护的备份中供恢复。
      mv "$STACK_DIR/nodes/$NODE_ID/metadata.json" "$backup/removed-metadata.json" || { node_recover "$backup" "$oldimage" yes; return 1; }
      if ! node_ingress_apply; then node_recover "$backup" "$oldimage" yes; return 1; fi
      NODE_TX_ACTIVE=no
      rm -rf "$STACK_DIR/nodes/$NODE_ID" "$backup"
      ylw '节点已删除；已有 Nginx 的对应 location 需要手动移除。' ;;
    7) cmd_node_update ;;
  esac
}

cmd_node_update() {
  local backup oldimage image
  image=$(ask '新镜像标签' 'latest')
  [[ $image =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
  backup=$(mktemp -d "$STACK_DIR/.node-recovery.XXXXXX")
  cp -p "$STACK_DIR/nodes/$NODE_ID/"* "$backup/" || return 1
  oldimage=$(docker inspect -f '{{.Image}}' "v2ray-node-$NODE_ID" 2>/dev/null || true)
  node_snapshot "$backup" "$oldimage" yes || return 1
  node_python image "$NODE_ID" "v2fly/v2fly-core:$image" || return 1
  if ! node_compose pull -q v2ray; then NODE_TX_ACTIVE=no; node_restore_files "$backup"; red "拉取失败；备份：$backup"; return 1; fi
  node_apply "$backup" "$oldimage" yes || return 1
  NODE_TX_ACTIVE=no
  rm -rf "$backup"
}

cmd_nodes_status() {
  need_docker; node_python list || return 1
  local id
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    NODE_ID=$id; node_compose ps
  done < <(node_python ids)
  [[ ! -f $COMPOSE_FILE ]] || compose ps
}

node_menu() {
  echo '======== V2Fly 多节点管理 ========'
  node_python list || return 1
  printf '%s\n' '1) 新增节点' '2) 管理节点' '3) 所有节点状态' '4) 更新指定节点' '5) 卸载（逐个选择节点删除）' '6) 旧单节点菜单' '0) 退出'
  case "$(node_choice '请选择' '0' '0123456')" in
    1) cmd_node_add ;;
    2|5) cmd_node_manage ;;
    3) cmd_nodes_status ;;
    4) node_select && cmd_node_update ;;
    6) menu ;;
  esac
}

menu() {
  load_env
  echo
  echo "======== V2Ray 管理 ========"
  if [[ -n $DOMAIN ]]; then
    echo " 当前: $DOMAIN  路径 $WS_PATH  CDN $CDN  前端 $([[ $FRONT == nginx ]] && echo '已有 Nginx' || echo Caddy)"
  else
    echo " 当前: 未安装"
  fi
  echo " 1) 安装 / 修改配置"
  echo " 2) 更新到最新版"
  echo " 3) 查看运行状态"
  echo " 4) 显示客户端链接和二维码"
  echo " 5) 只显示链接（不显示二维码）"
  echo " 6) 卸载"
  echo " 0) 退出"
  case "$(ask "请选择" "")" in
    1) cmd_install ;;
    2) cmd_update ;;
    3) cmd_status ;;
    4) cmd_show ;;
    5) cmd_show plain ;;
    6) cmd_uninstall ;;
    *) exit 0 ;;
  esac
}

main() {
  # 每个有效子命令都先过 need_root。未知命令不用拦——那只是提示用法，
  # 非 root 也该看到「未知命令」而不是「需要 root」
  case "${1:-}" in
    install)   need_root install;   cmd_install ;;
    update)    need_root update;    cmd_update ;;
    status)    need_root status;    cmd_status ;;
    show)      need_root show;      cmd_show "${2:-auto}" ;;
    uninstall) need_root uninstall; cmd_uninstall ;;
    node-add) need_root; cmd_node_add ;;
    node-manage) need_root; cmd_node_manage ;;
    nodes) need_root; cmd_nodes_status ;;
    "")        need_root;           node_menu ;;
    *)         die "未知命令: $1（可用: install update status show uninstall）" ;;
  esac
}

# 直接运行时执行 main；被 source 时不执行。
# 这一行同时兼容 bash <(curl ...) 和 curl | bash 两种写法。
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
