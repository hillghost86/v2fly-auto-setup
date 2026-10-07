#!/usr/bin/env bash
# =============================================================================
# v2fly-auto-setup.sh — 多节点 V2Fly + Caddy / Nginx 管理
# 子命令: init | node-add | node-manage | nodes | node-update | node-delete | ingress-update
# 配置: /root/v2fly-stack/nodes/<数字编号>/；Caddy 入口由独立项目共享。
# =============================================================================
# 换行符自愈：Windows 格式（CRLF）会让脚本无法运行，这里自动去掉 \r 后重新执行。
# 必须先确认脚本是磁盘上的普通文件：通过 bash <(curl ...) 运行时脚本来自管道，
# 再去读它会把数据从 bash 自己手里抢走，导致脚本被截断（管道场景也不会有 CRLF）。
# 下面这行必须保持单行，行尾注释用来兜住可能存在的 \r
_s=${BASH_SOURCE[0]:-$0}; if [[ -f $_s ]] && IFS= read -r _l < "$_s" 2>/dev/null && [[ $_l == *$'\r' ]]; then _f=$(mktemp); sed 's/\r$//' "$_s" > "$_f"; exec bash "$_f" "$@"; fi; unset -v _s _l # crlf-guard

set -euo pipefail

STACK_DIR=/root/v2fly-stack
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


# ---------------------------------------------------------------------------
# 退出时清理临时测试容器，并恢复未完成的节点变更。
# ---------------------------------------------------------------------------
TMP_DIRS=()
E2E_CID_FILE=""
E2E_CID_FILES=()
NODE_TX_ACTIVE=no NODE_TX_BACKUP="" NODE_TX_ID="" NODE_TX_IMAGE="" NODE_TX_EXISTED=no
INGRESS_TX_ACTIVE=no INGRESS_TX_BACKUP="" INGRESS_TX_IMAGE="" INGRESS_TX_RESTART=no
SWAP_SOURCE="" SWAP_TARGET="" SWAP_CREATED_ID="" SWAP_ACTIVE=no SWAP_PERSISTED=no
SWAP_STATUS_FILE=/proc/swaps
SWAP_FSTAB_CANDIDATE="" SWAP_FSTAB_BACKUP=""

cleanup() {
  # 清理中的单步失败不能阻止其他临时资源被释放。
  set +e
  cleanup_swap
  if [[ $NODE_TX_ACTIVE == yes ]]; then
    NODE_ID=$NODE_TX_ID
    node_recover "$NODE_TX_BACKUP" "$NODE_TX_IMAGE" "$NODE_TX_EXISTED" || red "节点恢复失败，备份：$NODE_TX_BACKUP"
  fi
  if [[ $INGRESS_TX_ACTIVE == yes ]]; then
    ingress_recover || red "共享入口恢复失败，备份：$INGRESS_TX_BACKUP"
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

container_running() { [[ -n "$(docker ps -q --filter "name=^$1\$" 2>/dev/null)" ]]; }

need_root() {
  [[ $EUID -eq 0 ]] || die "需要 root 运行。配置在 ${STACK_DIR} 下，普通用户读不到。
  请用: sudo -i 切到 root，或 curl -fsSL <脚本地址> | sudo bash -s -- ${1:-init}"
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
  command -v docker >/dev/null || die "没有检测到 Docker，请先运行本脚本的「初始化环境」"
  check_docker_engine
  docker compose version >/dev/null 2>&1 || die "没有检测到 Docker Compose，请先运行本脚本的「初始化环境」"
  docker info >/dev/null 2>&1 || die "Docker 没有运行，请执行: systemctl start docker"
}

has_ca_certificates() {
  if [[ $OS_FAMILY == el9 ]]; then
    rpm -q ca-certificates >/dev/null 2>&1
  else
    dpkg -s ca-certificates 2>/dev/null | grep -q '^Status: install ok installed'
  fi
}

# 只读检查；缺项返回 1，不可自动修复的情况返回 2。
check_node_environment() {
  ENV_MISSING=()
  local tool version
  for tool in python3 curl openssl ss ip; do
    command -v "$tool" >/dev/null || ENV_MISSING+=("命令 $tool")
  done
  has_ca_certificates || ENV_MISSING+=(ca-certificates)
  if ! command -v docker >/dev/null; then
    ENV_MISSING+=("Docker Engine / Docker Compose")
  else
    check_docker_engine
    if ! docker compose version >/dev/null 2>&1; then
      ENV_MISSING+=("Docker Compose")
    else
      version=$(docker compose version --short 2>/dev/null | sed 's/^v//') || version=''
      if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || \
          [[ "$(printf '%s\n%s\n' "$MIN_COMPOSE" "$version" | sort -V | head -1)" != "$MIN_COMPOSE" ]]; then
        red "Docker Compose 版本 ${version:-无法识别}，需要 $MIN_COMPOSE 以上；请手动升级后重试，脚本不会升级已有 Compose。"
        return 2
      fi
    fi
    docker info >/dev/null 2>&1 || ENV_MISSING+=("Docker 服务未运行")
  fi
  (( ${#ENV_MISSING[@]} == 0 ))
}

prepare_environment() {
  prepare_low_memory || return 1
  install_deps || return 1
  install_docker || return 1
}

ensure_node_environment() {
  local status
  if check_node_environment; then return 0; else status=$?; fi
  [[ $status != 2 ]] || return 1
  ylw '创建节点前需要补齐以下环境：'
  printf '  - %s\n' "${ENV_MISSING[@]}"
  if ! confirm '是否初始化缺少的环境，然后继续新增节点？' n; then
    ylw '已取消新增节点，未安装环境。'; return 1
  fi
  prepare_environment || return 1
  if ! check_node_environment; then
    red '环境复检未通过，停止新增节点。'
    if (( ${#ENV_MISSING[@]} )); then printf '  - %s\n' "${ENV_MISSING[@]}"; fi
    return 1
  fi
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
  if has_ca_certificates; then
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
  local FRONT=${1:-${FRONT:-nginx}}
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
# 经本机 HTTPS 入口检查 WebSocket 握手。
# ---------------------------------------------------------------------------
ws_ok() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --http1.1 --max-time 5 \
    --resolve "$DOMAIN:443:127.0.0.1" \
    -H "Connection: Upgrade" -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
    "https://$DOMAIN$WS_PATH" 2>/dev/null) || true
  [[ ${code//[[:space:]]/} == 101 ]]
}

e2e_ok() {
  local dir hostport code server run_opts=()
  server=host.docker.internal
  run_opts=(--add-host "host.docker.internal:host-gateway")
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
    "$E2E_IMAGE" run -c /etc/v2ray/config.json >/dev/null 2>&1 || return 1
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

cmd_init() {
  preflight
  ylw '初始化将按需准备系统依赖、Docker / Compose；低内存机器可选择创建 Swap。'
  confirm '确认初始化环境？' n || return 0
  prepare_environment || return 1
  grn '环境已就绪，请使用新增节点配置入口与出口。'
}

# 元数据只按 JSON 解析，不执行配置中的代码。
node_python() {
  command -v python3 >/dev/null || { red '多节点管理需要 python3，请先运行初始化环境。'; return 1; }
  python3 - "$STACK_DIR" "$@" <<'PY'
import base64
import fcntl
import json
import os
import pathlib
import re
import sys
import uuid

root = pathlib.Path(sys.argv[1])
nodes = root / 'nodes'


def fail(message):
    raise ValueError(message)


def domain(value):
    if not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?', value) or '.' not in value or '..' in value:
        fail('域名格式不正确')
    return value.lower()


def ws_path(value):
    if not re.fullmatch(r'/[A-Za-z0-9._~-]+', value):
        fail('路径只能包含字母、数字和 . _ ~ -')
    return value


def ident(value):
    if not re.fullmatch(r'[1-9][0-9]*', value):
        fail('节点编号须为正整数')
    return value


def local_port(value):
    number = int(value)
    if not 1024 <= number <= 65535:
        fail('本地端口必须在 1024–65535 之间')
    return number


def image_name(value):
    if not re.fullmatch(r'(?:v2fly/v2fly-core:[A-Za-z0-9_.-]+|sha256:[a-f0-9]{64})', value):
        fail('镜像标签不正确')
    return value


def label_name(value):
    value = value.strip()
    if not value or len(value) > 80 or any(ord(c) < 32 for c in value):
        fail('节点名称须为 1–80 个可见字符')
    return value


def write(target, data):
    target.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(target.parent, 0o700)
    # 创建时就使用受保护权限，避免凭据在 chmod 前短暂公开。
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as stream:
        os.fchmod(stream.fileno(), 0o600)
        stream.write(data)


def allnodes():
    folders = (folder for folder in nodes.iterdir()
               if re.fullmatch(r'[1-9][0-9]*', folder.name) and folder.is_dir()
               and (folder / 'metadata.json').exists()) if nodes.exists() else []
    return [read_node(folder.name) for folder in sorted(folders, key=lambda p: int(p.name))]


def read_node(node_id):
    return json.loads((nodes / ident(node_id) / 'metadata.json').read_text())


def save_node(node):
    write(nodes / node['id'] / 'metadata.json', json.dumps(node, ensure_ascii=False, indent=2) + '\n')


def remote_config(address, port, user_id, path, host='', sni=''):
    port = int(port)
    if not 1 <= port <= 65535:
        fail('远端端口不正确')
    return dict(domain=domain(address), port=port, uuid=str(uuid.UUID(user_id)), path=ws_path(path),
                host=domain(host or address), sni=domain(sni or address))


def parse_remote_link(link):
    if not link.startswith('vmess://'):
        fail('仅支持 vmess:// 链接')
    raw = link[8:]
    value = json.loads(base64.b64decode(raw + '=' * ((-len(raw)) % 4), validate=True))
    if any(value.get(key) not in (None, '', False, 'false', '0', 0)
           for key in ('allowInsecure', 'alpn', 'fp', 'packetEncoding')):
        fail('链接包含暂不支持的 TLS 或传输选项')
    if (value.get('net') != 'ws' or value.get('tls') != 'tls' or str(value.get('aid', '0')) != '0'
            or value.get('scy', 'auto') not in ('auto', 'aes-128-gcm', 'chacha20-poly1305')
            or value.get('type', 'none') not in ('none', '')):
        fail('仅支持 alterId=0 的 VMess + WS + TLS 链接')
    return remote_config(value['add'], value['port'], value['id'], value['path'], value.get('host'), value.get('sni'))


def make_config(node):
    outbound = {'protocol': 'freedom', 'settings': {}}
    if node['outbound'] == 'relay':
        remote = node['remote']
        outbound = {
            'tag': 'relay', 'protocol': 'vmess',
            'settings': {'vnext': [{'address': remote['domain'], 'port': remote['port'],
                                    'users': [{'id': remote['uuid'], 'alterId': 0, 'security': 'auto'}]}]},
            'streamSettings': {
                'network': 'ws', 'security': 'tls',
                'tlsSettings': {'serverName': remote['sni'], 'allowInsecure': False},
                'wsSettings': {'path': remote['path'], 'headers': {'Host': remote['host']}},
            },
        }
    return {
        'log': {'loglevel': 'warning'},
        'inbounds': [{'listen': '0.0.0.0', 'port': 2333, 'protocol': 'vmess',
                      'settings': {'clients': [{'id': node['uuid'], 'alterId': 0}]},
                      'streamSettings': {'network': 'ws', 'wsSettings': {'path': node['path']}}}],
        'outbounds': [outbound],
    }


def render_node(node):
    folder = nodes / node['id']
    config = json.dumps(make_config(node), ensure_ascii=False, indent=2) + '\n'
    write(folder / 'config.json', config)
    # Compose 内嵌配置避免宿主文件挂载造成 SELinux 标签冲突。
    embedded = ''.join('      ' + line + '\n' for line in config.splitlines())
    compose = f'''name: v2ray-node-{node['id']}
services:
  v2ray:
    image: {json.dumps(node['image'])}
    container_name: v2ray-node-{node['id']}
    restart: unless-stopped
    command: run -c /etc/v2ray/config.json
    ports:
      - "127.0.0.1:{node['port']}:2333"
    configs:
      - source: node_config
        target: /etc/v2ray/config.json
configs:
  node_config:
    content: |
{embedded}'''
    write(folder / 'compose.yaml', compose)


def ingress_image():
    target = root / 'ingress' / 'metadata.json'
    value = json.loads(target.read_text())['image'] if target.exists() else 'caddy:2'
    if not re.fullmatch(r'(?:caddy:[A-Za-z0-9_.-]+|sha256:[a-f0-9]{64})', value):
        fail('Caddy 镜像不正确')
    return value


def set_ingress_image(image):
    if not re.fullmatch(r'(?:caddy:[A-Za-z0-9_.-]+|sha256:[a-f0-9]{64})', image):
        fail('Caddy 镜像不正确')
    write(root / 'ingress' / 'metadata.json', json.dumps({'image': image}) + '\n')


def ingress_checks():
    for node in allnodes():
        if node['front'] == 'caddy':
            print(node['domain'] + '\t' + node['path'])


def render_ingress():
    domains = {}
    for node in allnodes():
        if node['front'] == 'caddy':
            domains.setdefault(node['domain'], []).append((node['path'], f"v2ray-node-{node['id']}:2333"))
    if not domains:
        return
    sections = []
    for address, routes in sorted(domains.items()):
        lines = [address + ' {']
        for path, upstream in routes:
            lines.extend([f'  handle {path} {{', f'    reverse_proxy {upstream}', '  }'])
        lines.extend(['  handle {', '    respond "It works!" 200', '  }', '}'])
        sections.append('\n'.join(lines))
    write(root / 'ingress' / 'Caddyfile', '\n'.join(sections) + '\n')
    write(root / 'ingress.yaml', f'''name: v2ray-ingress
services:
  caddy:
    image: {json.dumps(ingress_image())}
    container_name: v2ray-ingress
    restart: unless-stopped
    command: caddy run --config /managed/Caddyfile --adapter caddyfile
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./ingress:/managed:ro,Z
      - node_caddy_data:/data
      - node_caddy_config:/config
volumes:
  node_caddy_data:
  node_caddy_config:
''')


def allocate_node():
    nodes.mkdir(parents=True, exist_ok=True)
    os.chmod(nodes, 0o700)
    sequence = nodes / '.id-sequence'
    fd = os.open(sequence, os.O_RDWR | os.O_CREAT, 0o600)
    with os.fdopen(fd, 'r+') as stream:
        os.fchmod(stream.fileno(), 0o600)
        fcntl.flock(stream, fcntl.LOCK_EX)
        saved = int(stream.read().strip() or '0')
        high = max([saved] + [int(p.name) for p in nodes.iterdir() if p.name.isdigit()])
        node_id = str(high + 1)
        (nodes / node_id).mkdir(mode=0o700)
        stream.seek(0)
        stream.truncate()
        stream.write(node_id + '\n')
        stream.flush()
        os.fsync(stream.fileno())
        print(node_id)


def create_node(node_id, address, front, outbound, port, path, user_id, image, remote_mode='', *remote_values):
    node_id, address, port, path = ident(node_id), domain(address), local_port(port), ws_path(path)
    if front not in ('nginx', 'caddy') or outbound not in ('direct', 'relay'):
        fail('入口或出口方式不正确')
    existing = allnodes()
    for node in existing:
        if node['id'] != node_id and (node['port'] == port or (node['domain'] == address and node['path'] == path)):
            fail('端口或入口路径已被其他节点使用')
        if node['domain'] == address and node['front'] != front:
            fail('同一域名不能同时使用 Caddy 和 Nginx')
    if any(node['front'] != front for node in existing):
        fail('Caddy 与 Nginx 会争用 80/443，须使用同一种入口管理方式')
    node = dict(id=node_id, domain=address, front=front, outbound=outbound, port=port,
                path=path, uuid=str(uuid.UUID(user_id)), image=image_name(image))
    if outbound == 'relay':
        if remote_mode == 'link':
            (link,) = remote_values
            node['remote'] = parse_remote_link(link)
        elif remote_mode == 'preserve':
            if remote_values:
                fail('保留远端不接受额外参数')
            node['remote'] = read_node(node_id)['remote']
        elif remote_mode == 'manual':
            node['remote'] = remote_config(*remote_values)
        else:
            fail('远端配置方式不正确')
    save_node(node)
    render_node(node)


def get_node(node_id, field):
    value = read_node(node_id)[field]
    print(json.dumps(value) if isinstance(value, (dict, list)) else value)


def node_fields(node_id):
    node = read_node(node_id)
    for field in ('id', 'domain', 'front', 'outbound', 'port', 'path', 'uuid', 'image', 'label'):
        print(node.get(field, node['id'] if field == 'label' else ''))


def list_nodes():
    for node in allnodes():
        outlet = '本机直出' if node['outbound'] == 'direct' else '中转 ' + node['remote']['domain']
        print(f"{node['id']} ({node.get('label', node['id'])})\t{node['domain']} {node['path']}\t{outlet}\t{node['front']}")


def node_ids():
    for node in allnodes():
        print(node['id'])


def entry_list():
    for address, front in sorted({(node['domain'], node['front']) for node in allnodes()}):
        print(address + '\t' + front)


def generate_link(node_id):
    node = read_node(node_id)
    value = dict(v='2', ps=node.get('label', node['id']), add=node['domain'], port='443', id=node['uuid'],
                 aid='0', scy='auto', net='ws', type='none', host=node['domain'], path=node['path'], tls='tls', sni=node['domain'])
    print('vmess://' + base64.b64encode(json.dumps(value).encode()).decode())


def set_label(node_id, label):
    node = read_node(node_id)
    node['label'] = label_name(label)
    save_node(node)


def set_image(node_id, image):
    node = read_node(node_id)
    node['image'] = image_name(image)
    save_node(node)
    render_node(node)


HANDLERS = {
    'allocate': allocate_node,
    'validate-label': lambda value: print(label_name(value)),
    'validate-domain': lambda value: print(domain(value.strip())),
    'create': create_node,
    'get': get_node,
    'fields': node_fields,
    'list': list_nodes,
    'ids': node_ids,
    'entries': entry_list,
    'ingress': render_ingress,
    'link': generate_link,
    'label': set_label,
    'image': set_image,
    'ingress-image': set_ingress_image,
    'ingress-checks': ingress_checks,
}

try:
    handler = HANDLERS.get(sys.argv[2])
    if handler is None:
        fail('未知元数据操作')
    handler(*sys.argv[3:])
except (ValueError, KeyError, OSError, TypeError, IndexError) as error:
    print('节点配置错误：' + str(error), file=sys.stderr)
    sys.exit(1)
PY
}

node_compose() { docker compose --project-directory "$STACK_DIR/nodes/$NODE_ID" "$@"; }
node_get() { node_python get "$NODE_ID" "$1"; }
node_ingress_apply() {
  local force=${1:-no} name=v2ray-ingress network=v2ray-ingress_default ids previous='' changed=yes
  ids=$(node_python ids) || return 1
  if [[ -z $ids && -f $STACK_DIR/ingress.yaml ]]; then
    node_owner v2ray-ingress v2ray-ingress || return 1
    docker compose --project-directory "$STACK_DIR" -f "$STACK_DIR/ingress.yaml" down || return 1
    rm -f "$STACK_DIR/ingress.yaml" "$STACK_DIR/ingress/Caddyfile"
    return 0
  fi
  if [[ -f $STACK_DIR/ingress/Caddyfile ]]; then previous=$(cat "$STACK_DIR/ingress/Caddyfile"); fi
  node_python ingress || return 1
  if [[ -n $previous && $previous == $(cat "$STACK_DIR/ingress/Caddyfile" 2>/dev/null) ]]; then changed=no; fi
  [[ -f $STACK_DIR/ingress.yaml ]] || return 0
  if [[ -n ${NODE_INGRESS_IMAGE:-} ]]; then
    node_python ingress-image "$NODE_INGRESS_IMAGE" || return 1
    node_python ingress || return 1
  fi
  node_owner "$name" v2ray-ingress || return 1
  if ! container_running "$name"; then
    docker compose --project-directory "$STACK_DIR" -f "$STACK_DIR/ingress.yaml" up -d caddy || return 1
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
  if (( ${#ids[@]} == 0 )); then ylw '暂无可管理的节点。'; return 1; fi
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
    if [[ $front == caddy && $busy == yes ]] && ! container_running v2ray-ingress; then
      ylw '80/443 已被占用，请选择已有 Nginx 或复用已登记入口。'; continue
    fi
    while true; do
      d=$(node_ask '入口域名（0 返回）' "$current_domain") || return 1
      [[ $d != 0 ]] || return 1
      if d=$(node_python validate-domain "$d"); then return; fi
    done
  done
}

show_qr() {
  local link=$1 cols width level selected='' output
  command -v qrencode >/dev/null || return 0
  cols=$(tput cols 2>/dev/null || printf 80)
  [[ $cols =~ ^[0-9]+$ ]] || cols=80
  for level in M L; do
    if ! output=$(printf '%s' "$link" | qrencode -l "$level" -t ASCII 2>/dev/null); then
      ylw '二维码生成失败，请复制上面的链接。'; return 0
    fi
    width=$(printf '%s\n' "$output" | awk '{if(length($0)>m)m=length($0)} END{print int((m+1)/2)}')
    if (( width > 0 && cols >= width )); then selected=$level; break; fi
  done
  if [[ -z $selected ]]; then
    ylw "终端宽度不足，二维码需要至少 $width 列；请复制链接或拉宽窗口。"
    return 0
  fi
  if ! printf '%s' "$link" | qrencode -l "$selected" -t ANSIUTF8; then
    ylw '二维码显示失败，请复制上面的链接。'
  fi
  return 0
}

node_show() {
  local link
  link=$(node_python link "$NODE_ID") || return 1
  echo "$link"
  [[ ${1:-auto} == plain ]] || show_qr "$link"
  [[ $(node_get front) != nginx ]] || node_hint
}

node_test() {
  local DOMAIN UUID WS_PATH E2E_IMAGE snapshot field
  local fields=()
  snapshot=$(node_python fields "$NODE_ID") || return 1
  while IFS= read -r field; do fields+=("$field"); done <<< "$snapshot"
  DOMAIN=${fields[1]}; WS_PATH=${fields[5]}; UUID=${fields[6]}; E2E_IMAGE=${fields[7]}
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
  if [[ ! -s $backup/ingress.image && -f $STACK_DIR/ingress.yaml ]]; then
    node_owner v2ray-ingress v2ray-ingress || return 1
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
  if [[ $edit == no ]]; then
    ensure_node_environment || return 1
  else
    need_docker
    local tool
    for tool in python3 curl openssl ss; do
      command -v "$tool" >/dev/null || { red "缺少 ${tool}，请先运行初始化环境。"; return 1; }
    done
  fi
  if [[ $edit == yes ]]; then
    existed=yes; previousimage=$(node_get image) || return 1
    out=$(node_get outbound) || return 1
  else NODE_ID=''; out=direct; fi
  printf '%s\n' '1) 本机节点（本机直出）' '2) 中转节点（通过远端节点出网）' '0) 返回'
  mode=$(node_choice '节点类型' "$(if [[ $out == relay ]]; then echo 2; else echo 1; fi)" '012')
  case $mode in
    1) out=direct ;;
    2) out=relay ;;
    0) return 0 ;;
  esac
  while true; do
    label=$(node_ask '节点名称，例如 韩国直出 / 韩国转日本（0 返回）' "$(if [[ $edit == yes ]]; then node_get label 2>/dev/null || node_get id; fi)") || return 0
    [[ $label != 0 ]] || return 0
    if label=$(node_python validate-label "$label"); then break; fi
  done
  node_ingress_select || return 0
  if confirm '是否修改高级设置（端口、UUID、路径、镜像）？' n; then advanced=yes; fi
  p=$(node_option '本地端口' "$(if [[ $edit == yes ]]; then node_get port; else python3 - "$STACK_DIR" <<'PY'
import sys,json,pathlib,socket
used=set()
for p in (pathlib.Path(sys.argv[1])/'nodes').glob('*/metadata.json'):used.add(json.loads(p.read_text())['port'])
for port in range(2333,65536):
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
  local remote_args=()
  if [[ $out == relay ]]; then
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
      else return 1; fi
  fi
  echo "节点 ${label} (${NODE_ID:-自动编号})；入口 ${d}${ws} (${front})；本地端口 ${p}；出口 ${out}"
  [[ $front != nginx ]] || ylw '创建后仍需手动添加 Nginx 路径配置。'
  confirm '确认应用此节点？' n || return 0
  open_firewall "$front" || return 1
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
    6) node_delete_selected ;;
    7) cmd_node_update ;;
  esac
}

node_delete_selected() {
  ylw '只删除所选节点的容器与配置。'
  ylw '保留其他节点、Docker、系统依赖和证书卷。'
  ylw '最后一个独立 Caddy 节点删除时会停止共享入口。'
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
  ylw '节点已删除；已有 Nginx 的对应 location 需要手动移除。'
}

cmd_node_delete() {
  need_docker
  node_select || return 0
  node_delete_selected
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

ingress_compose() { docker compose --project-directory "$STACK_DIR" -f "$STACK_DIR/ingress.yaml" "$@"; }

ingress_ready() {
  local checks DOMAIN WS_PATH
  checks=$(node_python ingress-checks) || return 1
  [[ -n $checks ]] || return 1
  while IFS=$'\t' read -r DOMAIN WS_PATH; do
    wait_for ws_ok 6 || return 1
  done <<< "$checks"
}

ingress_recover() {
  INGRESS_TX_ACTIVE=no
  node_owner v2ray-ingress v2ray-ingress || return 1
  [[ -n $INGRESS_TX_IMAGE ]] || return 1
  cp -p "$INGRESS_TX_BACKUP/Caddyfile" "$STACK_DIR/ingress/Caddyfile" || return 1
  cp -p "$INGRESS_TX_BACKUP/compose.yaml" "$STACK_DIR/ingress.yaml" || return 1
  node_python ingress-image "$INGRESS_TX_IMAGE" || return 1
  node_python ingress || return 1
  if [[ $INGRESS_TX_RESTART == yes ]]; then
    ingress_compose up -d --no-deps --force-recreate --pull never caddy || return 1
    ingress_ready || return 1
  fi
  ylw "已恢复共享入口原镜像；变更备份保留在 $INGRESS_TX_BACKUP"
}

ingress_validate_image() {
  local checkdir
  mktmp checkdir || return 1
  chmod 700 "$checkdir" || return 1
  cp -p "$STACK_DIR/ingress/Caddyfile" "$checkdir/Caddyfile" || return 1
  E2E_CID_FILES+=("$checkdir/caddy-check.cid")
  docker run --rm --network none --cidfile "$checkdir/caddy-check.cid" \
    -v "$checkdir:/managed:ro,Z" caddy:2 caddy validate --config /managed/Caddyfile --adapter caddyfile
}

cmd_ingress_update() {
  need_docker
  local checks
  checks=$(node_python ingress-checks) || return 1
  if [[ -z $checks || ! -f $STACK_DIR/ingress.yaml ]]; then
    ylw '暂无共享 Caddy 入口；已有 Nginx 由用户自行更新。'; return 0
  fi
  node_owner v2ray-ingress v2ray-ingress || return 1
  ylw '更新共享 Caddy 会短暂中断全部 Caddy 节点的连接，客户端需要重连。'
  confirm '确认更新共享 Caddy 到 caddy:2？' n || return 0
  INGRESS_TX_IMAGE=$(docker inspect -f '{{.Image}}' v2ray-ingress 2>/dev/null) || { red '无法读取现有 Caddy 镜像，停止更新。'; return 1; }
  [[ $INGRESS_TX_IMAGE =~ ^sha256:[a-f0-9]{64}$ ]] || { red '无法确认原镜像 ID，停止更新。'; return 1; }
  INGRESS_TX_BACKUP=$(mktemp -d "$STACK_DIR/.ingress-recovery.XXXXXX") || return 1
  chmod 700 "$INGRESS_TX_BACKUP" || return 1
  cp -p "$STACK_DIR/ingress.yaml" "$INGRESS_TX_BACKUP/compose.yaml" || return 1
  cp -p "$STACK_DIR/ingress/Caddyfile" "$INGRESS_TX_BACKUP/Caddyfile" || return 1
  [[ ! -f $STACK_DIR/ingress/metadata.json ]] || cp -p "$STACK_DIR/ingress/metadata.json" "$INGRESS_TX_BACKUP/metadata.json" || return 1
  printf '%s\n' "$INGRESS_TX_IMAGE" > "$INGRESS_TX_BACKUP/image"
  chmod 600 "$INGRESS_TX_BACKUP/"* || return 1
  INGRESS_TX_RESTART=no INGRESS_TX_ACTIVE=yes
  if node_python ingress-image caddy:2 && node_python ingress && ingress_compose pull -q caddy && ingress_compose config -q && ingress_validate_image; then
    INGRESS_TX_RESTART=yes
    if ingress_compose up -d --no-deps --force-recreate --pull never caddy && ingress_ready; then
      INGRESS_TX_ACTIVE=no
      rm -rf "$INGRESS_TX_BACKUP"
      grn '共享 Caddy 已更新；其他节点容器保持运行。'
      return 0
    fi
  fi
  red '共享 Caddy 更新失败，正在恢复。'
  ingress_recover || red "共享入口恢复失败，备份：$INGRESS_TX_BACKUP"
  return 1
}

container_details() {
  local name=$1 executable=$2 status image version
  status=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null) || { ylw "${name}：容器不存在或无法读取"; return 0; }
  image=$(docker inspect -f '{{.Image}}' "$name" 2>/dev/null || true)
  version=$(docker exec "$name" "$executable" version 2>/dev/null | head -1) || true
  printf '%s：%s\n  实际镜像：%s\n  程序版本：%s\n' "$name" "${status:-未知}" "${image:-无法读取}" "${version:-容器未运行或无法读取}"
}

certificate_details() {
  local domain=$1 certificate
  printf '证书 %s：\n' "$domain"
  if ! command -v timeout >/dev/null; then
    ylw '缺少 timeout，跳过证书读取；请先初始化环境。'; return 0
  fi
  if certificate=$(printf '\n' | timeout 8 openssl s_client -connect 127.0.0.1:443 -servername "$domain" 2>/dev/null | openssl x509 -noout -issuer -enddate 2>/dev/null) && [[ -n $certificate ]]; then
    printf '%s\n' "$certificate"
  else ylw '证书读取失败，请检查 HTTPS 服务和域名配置。'; fi
}

cmd_nodes_status() {
  need_docker; node_python list || return 1
  local id entries domain front
  local ids
  ids=$(node_python ids) || return 1
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    node_owner "v2ray-node-$id" "v2ray-node-$id" || return 1
    container_details "v2ray-node-$id" v2ray
  done <<< "$ids"
  if [[ -f $STACK_DIR/ingress.yaml ]]; then
    node_owner v2ray-ingress v2ray-ingress || return 1
    container_details v2ray-ingress caddy
  fi
  entries=$(node_python entries) || return 1
  while IFS=$'\t' read -r domain front; do
    [[ -n $domain ]] || continue
    certificate_details "$domain"
  done <<< "$entries"
}

node_menu() {
  echo '======== V2Fly 多节点管理 ========'
  if command -v python3 >/dev/null; then node_python list || return 1;
  else ylw '尚未准备 Python，请选择初始化环境。'; fi
  printf '%s\n' '1) 新增节点' '2) 管理节点' '3) 所有节点状态' '4) 更新指定节点' '5) 删除节点' '6) 初始化环境' '7) 更新共享 Caddy' '0) 退出'
  case "$(node_choice '请选择' '0' '01234567')" in
    1) cmd_node_add ;;
    2) cmd_node_manage ;;
    5) cmd_node_delete ;;
    3) cmd_nodes_status ;;
    4) node_select && cmd_node_update ;;
    6) cmd_init ;;
    7) cmd_ingress_update ;;
  esac
}

main() {
  case "${1:-}" in
    init) need_root init; cmd_init ;;
    node-add) need_root node-add; cmd_node_add ;;
    node-manage) need_root node-manage; cmd_node_manage ;;
    nodes) need_root nodes; cmd_nodes_status ;;
    node-update) need_root node-update; need_docker; node_select && cmd_node_update ;;
    node-delete) need_root node-delete; cmd_node_delete ;;
    ingress-update) need_root ingress-update; cmd_ingress_update ;;
    "") need_root; node_menu ;;
    *) die "未知命令: $1（可用: init node-add node-manage nodes node-update node-delete ingress-update）" ;;
  esac
}

# 直接运行时执行 main；被 source 时不执行。
# 这一行同时兼容 bash <(curl ...) 和 curl | bash 两种写法。
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
