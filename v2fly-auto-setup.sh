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
NETWORK_TX_ACTIVE=no NETWORK_TX_BACKUP=""
NODE_NETWORK_RETAIN_NOTICE=no
SWAP_SOURCE="" SWAP_TARGET="" SWAP_CREATED_ID="" SWAP_ACTIVE=no SWAP_PERSISTED=no
SWAP_STATUS_FILE=/proc/swaps
SWAP_FSTAB_CANDIDATE="" SWAP_FSTAB_BACKUP=""

cleanup() {
  # 清理中的单步失败不能阻止其他临时资源被释放。
  set +e
  cleanup_swap
  if [[ $NODE_NETWORK_RETAIN_NOTICE == yes ]]; then ylw '节点创建未完成；此前成功启用的 BBR + fq 会保留。'; fi
  if [[ $NETWORK_TX_ACTIVE == yes ]]; then network_recover || red "网络优化恢复失败，保留备份：$NETWORK_TX_BACKUP"; fi
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

workflow_step() { printf '\n------------------------------\n%s\n\n' "$*" >&2; }

collect_environment_plan() {
  PLAN_CORE=no PLAN_SWAP=no PLAN_QR=skip
  local status
  if check_node_environment; then :; else
    status=$?
    [[ $status != 2 ]] || return 1
    PLAN_CORE=yes
  fi
}

plan_low_memory() {
  local status
  if needs_swap; then
    ylw '物理内存不足 1 GiB 且无活动 Swap，需要计划创建 1 GiB Swap。' >&2
    confirm '是否计划创建 Swap 并写入 fstab？' n || { red '未安排必需的 Swap，已返回。' >&2; return 1; }
    PLAN_SWAP=yes
  else
    status=$?
    [[ $status == 1 ]] || return 1
  fi
}

plan_qrencode() {
  if command -v qrencode >/dev/null; then PLAN_QR=installed; return 0; fi
  printf '%s\n' '二维码工具尚未安装：' '1) 安装；必要时允许添加 EPEL 9（仅 EL9）' '2) 仅使用现有软件源，失败跳过二维码' '3) 不安装，使用客户端链接' '0) 返回' >&2
  local choice
  choice=$(node_choice '二维码策略' 1 0123)
  case $choice in 1) PLAN_QR=allow ;; 2) PLAN_QR=native ;; 3) PLAN_QR=skip ;; *) return 1 ;; esac
}

environment_summary() {
  if [[ $PLAN_CORE == yes ]]; then printf '环境准备：\n'; printf '  - %s\n' "${ENV_MISSING[@]}";
  else echo '核心依赖与 Docker 已就绪，无需安装或启动。'; fi
  echo "Swap：$(if [[ $PLAN_SWAP == yes ]]; then echo '创建 1 GiB，启用并写入 fstab'; else echo '无需创建'; fi)"
  case $PLAN_QR in
    allow) echo '二维码：安装；必要时允许添加 EPEL 9（仅 EL9）' ;;
    native) echo '二维码：仅现有软件源；失败跳过，不添加 EPEL' ;;
    skip) echo '二维码：不安装' ;;
    installed) echo '二维码：已安装，无需处理' ;;
  esac
}

execute_low_memory() {
  [[ $PLAN_SWAP == yes ]] || return 0
  if ! create_swap; then
    red "Swap 创建或持久化未完成，停止执行；已启用的 Swap 会保留。${SWAP_FSTAB_BACKUP:+ 备份：$SWAP_FSTAB_BACKUP}"
    cleanup_swap
    return 1
  fi
}

execute_environment_plan() {
  execute_low_memory || return 1
  if [[ $PLAN_CORE == yes ]]; then
    install_deps || return 1
  fi
  install_optional_qr "$PLAN_QR"
  if [[ $PLAN_CORE == yes ]]; then install_docker || return 1; fi
  if ! check_node_environment; then
    red '环境复检未通过，停止执行。'
    if (( ${#ENV_MISSING[@]} )); then printf '  - %s\n' "${ENV_MISSING[@]}"; fi
    return 1
  fi
  return 0
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
    command -v "$tool" >/dev/null || { red "缺少 ${tool}，无法安全创建 Swap；请自行准备，不会自动安装工具"; return 1; }
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
  swap_is_active "$SWAP_TARGET" "$SWAP_STATUS_FILE" || { red "无法确认 Swap 状态，请检查 ${SWAP_TARGET}；文件保留"; return 1; }
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

needs_swap() {
  local mem_file=${1:-/proc/meminfo} swaps_file=${2:-/proc/swaps} key value rest total='' entry
  [[ -r $mem_file && -r $swaps_file ]] || { red '无法读取内存 / Swap 状态。' >&2; return 2; }
  while read -r key value rest; do
    if [[ $key == MemTotal: ]]; then total=$value; break; fi
  done < "$mem_file"
  [[ $total =~ ^[0-9]+$ ]] && (( total > 0 )) || { red '无法确定物理内存大小。' >&2; return 2; }
  (( total < 1048576 )) || return 1
  while read -r entry rest; do
    [[ -z $entry || $entry == Filename ]] || return 1
  done < "$swaps_file"
}

install_qrencode_el9() {
  local policy=${1:-native}
  [[ $policy != skip ]] || return 0
  command -v qrencode >/dev/null && return 0
  dnf install -y qrencode && return 0
  if [[ $policy != allow ]]; then
    ylw '现有软件源没有 qrencode；按计划跳过，不添加 EPEL。'
    return 0
  fi
  if ! rpm -q epel-release >/dev/null 2>&1; then
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
  else
    for p in curl ca-certificates openssl python3 iproute2; do
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

# 预检与失败诊断均只读取本机入口及受管资源。
caddy_rate_limit_hint() {
  local domain=$1 trusted=${2:-no} owner
  [[ $trusted != yes ]] || return 0
  command -v docker >/dev/null && command -v timeout >/dev/null && command -v python3 >/dev/null || return 0
  owner=$(timeout 5 docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' v2fly-ingress 2>/dev/null) || return 0
  [[ $owner == v2fly-ingress ]] || return 0
  timeout 5 docker logs --since 24h --tail 200 v2fly-ingress 2>&1 | node_python certificate-limit "$domain" 3<&0 || true
}

node_certificate_preflight() {
  local domain=$1 front=$2 code status=0 owner mount volume
  workflow_step '入口证书与存储预检（只读）'
  if [[ $front == nginx ]]; then
    echo '证书由现有 Nginx / 宝塔管理；不检查 Caddy 数据卷。'
  elif command -v docker >/dev/null && command -v timeout >/dev/null; then
    if owner=$(timeout 5 docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' v2fly-ingress 2>/dev/null); then
      if [[ $owner == v2fly-ingress ]]; then
        mount=$(timeout 5 docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Type}} {{.Name}} {{.Source}}{{end}}{{end}}' v2fly-ingress 2>/dev/null) || mount=''
        if [[ -n $mount ]]; then printf '共享 Caddy 当前 /data 挂载：%s\n' "$mount";
        else ylw '未读取到共享 Caddy 的 /data 挂载，证书存储状态未知。'; fi
      else ylw '同名 Caddy 容器不是本项目资源，不读取其证书存储或日志。'; fi
    else
      volume=v2fly-ingress_node_caddy_data
      if timeout 5 docker volume inspect "$volume" >/dev/null 2>&1; then
        echo "共享 Caddy 当前没有可读取的容器；预期证书卷 $volume 已存在。"
      else echo "共享 Caddy 当前没有可读取的容器；预期证书卷 $volume 未确认存在，启动时可能需要申请证书。"; fi
    fi
    echo '数据卷存在不代表选中域名的证书可用；不导入旧部署的数据卷。'
  else echo '缺少 Docker 或 timeout，跳过证书数据卷检查。'; fi
  if ! command -v curl >/dev/null; then
    echo '缺少 curl，本机 HTTPS 证书状态未知；环境准备后再检查。'
    return 0
  fi
  code=$(curl -q --noproxy '*' -s -I -o /dev/null -w '%{http_code}' --max-time 8 \
    --resolve "$domain:443:127.0.0.1" "https://$domain/" 2>/dev/null) || status=$?
  if [[ $status == 0 ]]; then
    grn "✓ 本机 HTTPS 证书通过主机名与信任链验证（HTTP ${code:-000}）；此证书可用于该域名。"
    if command -v openssl >/dev/null && command -v timeout >/dev/null; then certificate_details "$domain"; fi
  else
    case $status in
      60) ylw '本机 HTTPS 证书验证失败：证书可能过期、域名不匹配或信任链不完整。' ;;
      35) ylw '本机 TLS 握手失败：当前无法确认域名证书可用。' ;;
      7|28) ylw '本机 HTTPS 未连接或超时：服务可能未启动，无法判断磁盘是否已有证书。' ;;
      *) ylw "本机 HTTPS 检查未完成（curl 状态 $status），证书状态未知。" ;;
    esac
    [[ $front != caddy ]] || caddy_rate_limit_hint "$domain"
    [[ $front != caddy ]] || echo '若需要重新签发，请检查域名解析和 80/443 可达性；限流时需等到允许重试。'
  fi
  return 0
}

# 仅输出状态码，不输出响应正文、凭据或任意服务日志。
ws_diagnose() {
  local code status=0 detail
  code=$(curl -s -o /dev/null -w '%{http_code}' --http1.1 --max-time 5 \
    --resolve "$DOMAIN:443:127.0.0.1" \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    "https://$DOMAIN$WS_PATH" 2>/dev/null) || status=$?
  if [[ $code == 101 ]]; then
    ylw '等待期间 HTTPS / WebSocket 未就绪；追加诊断已返回 101，可能刚刚恢复。'
    return 0
  fi
  case $status in
    0) detail="HTTPS 已连通，WebSocket 返回 HTTP ${code:-000}（预期 101）" ;;
    7) detail='无法连接本机 443，请检查共享 Caddy 是否启动' ;;
    28) detail='本机 HTTPS 请求超时' ;;
    35|60) detail='TLS 握手或证书验证失败，请检查证书签发与域名解析' ;;
    *) detail="HTTPS 请求失败，curl 状态 $status，HTTP ${code:-000}" ;;
  esac
  red "HTTPS / WebSocket 自检失败：$detail"
  caddy_rate_limit_hint "$DOMAIN" "$(if [[ $status == 0 ]]; then echo yes; else echo no; fi)"
  ylw '可在服务器查看入口日志：docker logs --tail 80 v2fly-ingress（恢复后日志可能已变化）。'
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
    -v "$dir/config.json:/etc/v2fly/config.json:ro,Z" \
    "$E2E_IMAGE" run -c /etc/v2fly/config.json >/dev/null 2>&1 || return 1
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
  local PLAN_CORE PLAN_SWAP PLAN_QR
  preflight
  workflow_step '1 / 3 环境检查与计划'
  collect_environment_plan || return 1
  plan_low_memory || return 0
  plan_qrencode || return 0
  workflow_step '2 / 3 确认初始化计划'
  environment_summary
  confirm '确认执行以上环境计划？' n || return 0
  workflow_step '3 / 3 执行初始化'
  execute_environment_plan || return 1
  grn '环境已就绪，请使用新增节点。'
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
    bbr = '    sysctls:\n      net.ipv4.tcp_congestion_control: bbr\n' if (root / 'network-bbr-enabled').is_file() else ''
    compose = f'''name: v2fly-node-{node['id']}
services:
  v2fly:
    image: {json.dumps(node['image'])}
    container_name: v2fly-node-{node['id']}
    restart: unless-stopped
    command: run -c /etc/v2fly/config.json
{bbr}    ports:
      - "127.0.0.1:{node['port']}:2333"
    configs:
      - source: node_config
        target: /etc/v2fly/config.json
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
            domains.setdefault(node['domain'], []).append((node['path'], f"v2fly-node-{node['id']}:2333"))
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
    bbr = '    sysctls:\n      net.ipv4.tcp_congestion_control: bbr\n' if (root / 'network-bbr-enabled').is_file() else ''
    write(root / 'ingress.yaml', f'''name: v2fly-ingress
services:
  caddy:
    image: {json.dumps(ingress_image())}
    container_name: v2fly-ingress
    restart: unless-stopped
    command: caddy run --config /managed/Caddyfile --adapter caddyfile
{bbr}    ports:
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


def build_node(node_id, address, front, outbound, port, path, user_id, image, remote_mode='', *remote_values):
    port, path, user_id = resolve_defaults(port, path, user_id)
    node_id = ident(node_id) if node_id != 'new' else node_id
    address, port, path = domain(address), local_port(port), ws_path(path)
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
    return node


def create_node(*args):
    node = build_node(*args)
    ident(node['id'])
    save_node(node)
    render_node(node)


def print_remote_summary(remote):
    print('远端节点配置：')
    print(f"  地址：{remote['domain']}")
    print(f"  端口：{remote['port']}")
    print(f"  UUID：{remote['uuid']}")
    print('  协议：VMess；传输：WebSocket；TLS：开启（严格验证）')
    print(f"  WebSocket 路径：{remote['path']}")
    print(f"  Host：{remote['host']}")
    print(f"  SNI：{remote['sni']}")


def validate_create(*args):
    node = build_node(*args)
    if node['outbound'] == 'relay':
        print_remote_summary(node['remote'])


def resolve_defaults(port, path, user_id):
    if port == 'auto':
        import socket
        used = {node['port'] for node in allnodes()}
        for candidate in range(2333, 65536):
            if candidate in used:
                continue
            with socket.socket() as sock:
                try:
                    sock.bind(('127.0.0.1', candidate))
                except OSError:
                    continue
            port = str(candidate)
            break
        else:
            fail('没有可用本地端口')
    return port, '/' + uuid.uuid4().hex[:12] if path == 'auto' else path, str(uuid.uuid4()) if user_id == 'auto' else user_id


def print_defaults(*args):
    for value in resolve_defaults(*args):
        print(value)


def validate_link(link):
    parse_remote_link(link)


def validate_path(node_id, address, path):
    address, path = domain(address), ws_path(path)
    if any(node['id'] != node_id and node['domain'] == address and node['path'] == path for node in allnodes()):
        fail('入口路径已被其他节点使用')


def validate_port(node_id, port):
    port = local_port(port)
    if any(node['id'] != node_id and node['port'] == port for node in allnodes()):
        fail('本地端口已被其他节点使用')


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


def certificate_limit(selected_domain):
    import datetime
    now = datetime.datetime.now(datetime.timezone.utc)
    latest = None
    selected_domain = selected_domain.lower()
    for line in os.fdopen(3):
        try:
            item = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(item, dict):
            continue
        names = item.get('identifiers', [])
        if not isinstance(names, list):
            names = []
        names = names + [item.get('identifier'), item.get('domain')]
        if selected_domain not in [name.lower() for name in names if isinstance(name, str)]:
            continue
        message = str(item.get('msg', '')).lower()
        if 'certificate obtained successfully' in message or 'certificate renewed successfully' in message:
            latest = None
            continue
        error = str(item.get('error', ''))
        if 'ratelimited' not in error.lower() and 'rate limit' not in error.lower() and 'ratelimited' not in message:
            continue
        retry = re.search(r'retry after\s+(\d{4}-\d\d-\d\d[ T]\d\d:\d\d:\d\d(?:Z|[+-]\d\d:\d\d)?)', error, re.I)
        if retry:
            stamp = retry.group(1).replace(' ', 'T')
            try:
                moment = datetime.datetime.fromisoformat(stamp.replace('Z', '+00:00'))
                if moment.tzinfo is None:
                    moment = moment.replace(tzinfo=datetime.timezone.utc)
                latest = ('past' if moment <= now else 'active', moment.isoformat())
            except ValueError:
                latest = ('unknown', '')
        else:
            latest = ('unknown', '')
    if latest:
        state, stamp = latest
        if state == 'active':
            print('选中域名最近有证书签发限流；日志允许重试时间：' + stamp + '（尚未到达）。')
        elif state == 'past':
            print('选中域名有历史限流记录；允许重试时间已过去：' + stamp + '；不能据此判断仍在限流。')
        else:
            print('选中域名最近有证书签发限流记录；日志未提供可确认的允许重试时间，当前状态需核实。')


HANDLERS = {
    'certificate-limit': certificate_limit,
    'allocate': allocate_node,
    'validate-label': lambda value: print(label_name(value)),
    'validate-domain': lambda value: print(domain(value.strip())),
    'create': create_node,
    'validate-create': validate_create,
    'defaults': print_defaults,
    'validate-link': validate_link,
    'preview-link': lambda link: print_remote_summary(parse_remote_link(link)),
    'validate-port': validate_port,
    'validate-path': validate_path,
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
  local force=${1:-no} name=v2fly-ingress network=v2fly-ingress_default ids previous='' changed=yes
  ids=$(node_python ids) || return 1
  if [[ -z $ids && -f $STACK_DIR/ingress.yaml ]]; then
    node_owner v2fly-ingress v2fly-ingress || return 1
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
  node_owner "$name" v2fly-ingress || return 1
  if ! container_running "$name"; then
    docker compose --project-directory "$STACK_DIR" -f "$STACK_DIR/ingress.yaml" up -d caddy || return 1
  fi
  local id
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    if [[ $(node_python get "$id" front) == caddy ]]; then
      if ! docker inspect -f '{{json .NetworkSettings.Networks}}' "v2fly-node-$id" | grep -q "\"$network\""; then
        docker network connect "$network" "v2fly-node-$id" || return 1
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
  workflow_step 'Nginx：待手工配置'
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
  printf '\n' >&2
  read -r -u "$IN" -p "$1${2:+ [$2]}: " reply || return 1
  printf '%s' "${reply:-$2}"
}

node_option() {
  if [[ $advanced == yes ]]; then node_input "$3" "$1" "$2"; else printf '%s' "$2"; fi
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
  node_owner "v2fly-node-$NODE_ID" "v2fly-node-$NODE_ID" || return 1
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
  if command -v python3 >/dev/null; then listing=$(node_python entries) || return 1;
  else listing=''; ylw '尚无 Python，无法列出已登记入口；环境就绪后会再次检查冲突。' >&2; fi
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
    if (( i > 0 )) && [[ $front != ${fronts[0]} ]]; then
      ylw '已有节点使用另一种 HTTPS 管理方式，请重新选择兼容的入口。' >&2
      continue
    fi
    if [[ $front == caddy && $busy == yes ]] && ! container_running v2fly-ingress; then
      ylw '80/443 已被占用，请选择已有 Nginx 或复用已登记入口。'; continue
    fi
    workflow_step '入口域名'
    while true; do
      d=$(node_input domain '入口域名' "$current_domain") || return 1
      return
    done
  done
}

install_optional_qr() {
  local policy=$1
  if command -v qrencode >/dev/null; then grn '✓ qrencode（二维码）已就绪'; return 0; fi
  case $policy in
    skip) ylw '按计划不安装二维码工具；客户端链接仍可使用。'; return 0 ;;
    allow|native) step '按计划安装二维码工具' ;;
    *) ylw '二维码工具当前不可用；客户端链接仍可使用。'; return 0 ;;
  esac
  if [[ $OS_FAMILY == el9 ]]; then
    install_qrencode_el9 "$policy" || ylw '二维码工具安装失败，继续使用链接。'
  elif ! apt-get update -qq || ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qrencode; then
    ylw '二维码工具安装失败，继续使用链接。'
  fi
  if command -v qrencode >/dev/null; then grn '✓ qrencode（二维码）已就绪';
  else ylw '二维码工具未就绪，本次仅提供客户端链接。'; fi
  return 0
}

show_qr() {
  local link=$1 cols width level selected='' output
  if ! command -v qrencode >/dev/null; then
    ylw '未安装 qrencode，已保留客户端链接；可在初始化环境中选择安装。'; return 0
  fi
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
  workflow_step '客户端链接'
  echo "$link"
  workflow_step '二维码'
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
    if ! wait_for ws_ok 36; then ws_diagnose; return 1; fi
    node_test || return 1
  else
    ylw 'V2Fly 本地入口已就绪；Nginx 反代配置完成后请在管理菜单测试连接。'
  fi
}

node_apply() {
  local backup=$1 oldimage=$2 existed=$3
  if node_compose config -q && node_compose run --rm --no-deps --pull never v2fly test -c /etc/v2fly/config.json && node_compose up -d --no-deps --force-recreate --pull never v2fly; then
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
  docker inspect -f '{{.Image}}' v2fly-ingress > "$backup/ingress.image" 2>/dev/null || true
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
    node_compose up -d --no-deps --force-recreate --pull never v2fly || return 1
  else
    if [[ -f $STACK_DIR/nodes/$NODE_ID/compose.yaml ]]; then node_compose down || return 1; fi
    rm -rf "$STACK_DIR/nodes/$NODE_ID"
  fi
  if [[ ! -s $backup/ingress.image && -f $STACK_DIR/ingress.yaml ]]; then
    node_owner v2fly-ingress v2fly-ingress || return 1
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

node_input() {
  local kind=$1 prompt=$2 default=${3:-} value valid
  while true; do
    value=$(node_ask "${prompt}（0 返回）" "$default") || return 1
    [[ $value != 0 ]] || return 1
    valid=no
    case $kind in
      label)
        value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -n $value && ${#value} -le 80 && ! $value =~ [[:cntrl:]] ]] && valid=yes ;;
      domain)
        [[ $value =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ && $value == *.* && $value != *..* ]] && valid=yes ;;
      port|remote-port)
        if [[ $value == auto && $kind == port ]]; then valid=yes
        elif [[ $value =~ ^[0-9]{1,5}$ ]]; then
          local minimum=1024 number=$((10#$value))
          [[ $kind != remote-port ]] || minimum=1
          (( number >= minimum && number <= 65535 )) && valid=yes
          [[ $valid != yes ]] || value=$number
        fi ;;
      path|remote-path) [[ ( $kind == path && $value == auto ) || $value =~ ^/[A-Za-z0-9._~-]+$ ]] && valid=yes ;;
      uuid|remote-uuid) [[ ( $kind == uuid && $value == auto ) || $value =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]] && valid=yes ;;
      image) [[ $value =~ ^[A-Za-z0-9_.-]+$ || $value =~ ^sha256:[a-f0-9]{64}$ ]] && valid=yes ;;
      vmess)
        if [[ $value == vmess://* && ${#value} -gt 8 ]]; then
          if ! command -v python3 >/dev/null || node_python validate-link "$value"; then valid=yes; fi
        fi ;;
    esac
    if [[ $valid == yes ]]; then printf '%s' "$value"; return 0; fi
    ylw '输入无效，请重新填写当前字段。' >&2
  done
}

# 预览默认值只读取系统状态；确认后沿用同一组值。
node_preview_defaults() {
  local p=${1:-auto} ws=${2:-auto} u=${3:-auto} random
  if command -v python3 >/dev/null; then node_python defaults "$p" "$ws" "$u"; return; fi
  if [[ $p == auto ]]; then
    for ((p=2333; p<=65535; p++)); do
      if ! port_in_use "$p"; then break; fi
    done
    ((p<=65535)) || { red '没有可用本地端口' >&2; return 1; }
  fi
  if [[ $ws == auto || $u == auto ]]; then
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
      IFS= read -r random < /proc/sys/kernel/random/uuid || return 1
    else
      random=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n') || return 1
      [[ ${#random} == 32 ]] || return 1
      random="${random:0:8}-${random:8:4}-4${random:13:3}-8${random:17:3}-${random:20:12}"
    fi
    [[ $random =~ ^[a-fA-F0-9-]{36}$ ]] || return 1
    [[ $u != auto ]] || u=$random
    if [[ $ws == auto ]]; then
      random=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n') || return 1
      [[ ${#random} == 12 ]] || return 1
      ws=/$random
    fi
  fi
  printf '%s\n' "$p" "$ws" "$u"
}

# 只读收集缺失命令对应的软件包；在基础依赖安装后会再次核对实际缺项。
network_missing_packages() {
  local tool package
  NETWORK_MISSING_PACKAGES=()
  for tool in ip tc modprobe sysctl; do
    command -v "$tool" >/dev/null && continue
    case "$OS_FAMILY:$tool" in
      el9:ip) package=iproute ;;
      el9:tc) package=iproute-tc ;;
      el9:modprobe|debian:modprobe) package=kmod ;;
      el9:sysctl) package=procps-ng ;;
      debian:ip|debian:tc) package=iproute2 ;;
      debian:sysctl) package=procps ;;
      *) red '无法确定网络工具的软件包，停止。'; return 1 ;;
    esac
    [[ " ${NETWORK_MISSING_PACKAGES[*]} " == *" $package "* ]] || NETWORK_MISSING_PACKAGES+=("$package")
  done
}

plan_node_network() {
  local choice
  local NETWORK_MISSING_PACKAGES=()
  PLAN_NETWORK_PACKAGES=()
  if [[ -f $STACK_DIR/network-bbr-enabled ]]; then PLAN_NETWORK=enabled; return 0; fi
  while true; do
    choice=$(node_ask '是否启用 BBR + fq（Y/n，0 返回）' y) || return 1
    case "$choice" in
      y|Y) PLAN_NETWORK=yes; break ;;
      n|N) PLAN_NETWORK=no; return 0 ;;
      0) return 1 ;;
      *) ylw '请输入 y、n 或 0。' >&2 ;;
    esac
  done
  network_missing_packages || return 1
  PLAN_NETWORK_PACKAGES=("${NETWORK_MISSING_PACKAGES[@]}")
}

node_network_summary() {
  case "$PLAN_NETWORK" in
    yes)
      echo '网络优化：启用 BBR + fq，作用于宿主机及所有受管节点、共享 Caddy；已有容器将重建并需重连。'
      echo '首次切换出口 fq 会影响该网卡承载的全机流量；环境准备后核验内核、队列与配置，不支持则停止创建。'
      if ((${#PLAN_NETWORK_PACKAGES[@]})); then printf '网络工具：按缺项安装 %s\n' "${PLAN_NETWORK_PACKAGES[*]}"; fi
      ;;
    enabled) echo '网络优化：已有受管 BBR + fq，新节点继承；不重复配置系统或重建既有容器。' ;;
    no) echo '网络优化：本次不启用 BBR + fq。' ;;
  esac
}

install_node_network_dependencies() {
  local package
  local NETWORK_MISSING_PACKAGES=()
  network_missing_packages || return 1
  # 只安装最终确认中列出的包；环境变化导致的新缺项须重新规划。
  for package in "${NETWORK_MISSING_PACKAGES[@]}"; do
    [[ " ${PLAN_NETWORK_PACKAGES[*]} " == *" $package "* ]] || { red "网络工具缺项已变化，请重新规划：$package"; return 1; }
  done
  if ((${#NETWORK_MISSING_PACKAGES[@]})); then
    if [[ $OS_FAMILY == el9 ]]; then
      dnf install -y "${NETWORK_MISSING_PACKAGES[@]}" || { red '网络工具安装失败，停止创建。'; return 1; }
    else
      apt-get update -qq || { red '网络工具的软件源更新失败，停止创建。'; return 1; }
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${NETWORK_MISSING_PACKAGES[@]}" || { red '网络工具安装失败，停止创建。'; return 1; }
    fi
  fi
  network_missing_packages || return 1
  ((${#NETWORK_MISSING_PACKAGES[@]} == 0)) || { red '网络工具复检未通过，停止创建。'; return 1; }
}

cmd_node_add() {
  local edit=${1:-no} d front out p ws u image mode link rd rp ru rw oldimage='' backup existed=no label advanced=no previousimage='' rh rs remote_info='' defaults field
  local PLAN_CORE PLAN_SWAP PLAN_QR PLAN_NETWORK=unchanged
  local PLAN_NETWORK_PACKAGES=()
  local remote_args=() values=()
  workflow_step '1 / 10 只读环境检查'
  preflight
  collect_environment_plan || return 1
  if [[ $edit == yes ]]; then
    command -v python3 >/dev/null || { red '编辑已有节点需要 Python，请先初始化环境。'; return 1; }
    existed=yes; previousimage=$(node_get image) || return 1
    out=$(node_get outbound) || return 1
  else NODE_ID=''; out=direct; fi
  workflow_step '2 / 10 节点类型'
  printf '%s\n' '1) 本机节点（本机直出）' '2) 中转节点（通过远端节点出网）' '0) 返回'
  mode=$(node_choice '节点类型' "$(if [[ $out == relay ]]; then echo 2; else echo 1; fi)" '012')
  case $mode in 1) out=direct ;; 2) out=relay ;; *) return 0 ;; esac
  workflow_step '3 / 10 节点名称'
  label=$(node_input label '节点名称，例如 韩国直出 / 韩国转日本' "$(if [[ $edit == yes ]]; then node_get label 2>/dev/null || node_get id; fi)") || return 0
  workflow_step '4 / 10 HTTPS 入口'
  node_ingress_select || return 0
  node_certificate_preflight "$d" "$front"
  defaults=$(node_preview_defaults "$(if [[ $edit == yes ]]; then node_get port; else echo auto; fi)" "$(if [[ $edit == yes ]]; then node_get path; else echo auto; fi)" "$(if [[ $edit == yes ]]; then node_get uuid; else echo auto; fi)") || return 1
  while IFS= read -r field; do values+=("$field"); done <<< "$defaults"
  workflow_step '5 / 10 高级设置'
  while true; do
    mode=$(node_ask '是否修改高级设置（y/N，0 返回）' n) || return 0
    case $mode in y|Y) advanced=yes; break ;; n|N) break ;; 0) return 0 ;; *) ylw '请输入 y、n 或 0。' >&2 ;; esac
  done
  local port_default
  port_default=$(if [[ $edit == yes ]]; then node_get port; else echo "${values[0]}"; fi)
  while true; do
    p=$(node_option '本地端口' "$port_default" port) || return 0
    if [[ $p != auto ]] && command -v ss >/dev/null && { [[ $edit == no ]] || [[ $p != $(node_get port) ]]; } && port_in_use "$p"; then
      ylw '本地端口已被占用，请重新填写当前字段。' >&2
    elif [[ $p != auto ]] && command -v python3 >/dev/null && ! node_python validate-port "${NODE_ID:-new}" "$p"; then
      ylw '此端口已登记到其他节点，请重新填写。' >&2
    else break; fi
    advanced=yes; port_default=$p
  done
  local path_default
  path_default=$(if [[ $edit == yes ]]; then node_get path; else echo "${values[1]}"; fi)
  while true; do
    ws=$(node_option 'WebSocket 路径' "$path_default" path) || return 0
    if [[ $ws != auto ]] && command -v python3 >/dev/null && ! node_python validate-path "${NODE_ID:-new}" "$d" "$ws"; then
      ylw '入口路径冲突，请重新填写当前字段。' >&2
      advanced=yes; path_default=$ws
    else break; fi
  done
  u=$(node_option 'UUID' "$(if [[ $edit == yes ]]; then node_get uuid; else echo "${values[2]}"; fi)" uuid) || return 0
  image=$(node_option 'V2Fly 镜像标签' "$(if [[ $edit == yes ]]; then node_get image | sed 's|v2fly/v2fly-core:||'; else echo latest; fi)" image) || return 0
  [[ $image == sha256:* ]] || image="v2fly/v2fly-core:$image"
  workflow_step '6 / 10 远端出口'
  if [[ $out == relay ]]; then
    printf '%s\n' '1) 导入 vmess:// 链接' '2) 手动填写'
    local remote_choices=012 remote_default=1
    if [[ $edit == yes && $(node_get outbound) == relay ]]; then echo '3) 保留现有远端'; remote_choices=0123; remote_default=3; fi
    echo '0) 返回'
    mode=$(node_choice '远端配置' "$remote_default" "$remote_choices")
    case $mode in
      1)
        link=$(node_input vmess '远端 vmess:// 链接' '') || return 0
        remote_args=(link "$link")
        if command -v python3 >/dev/null; then
          remote_info=$(node_python preview-link "$link") || return 1
          printf '\n%s\n' "$remote_info"
        else
          remote_info='尚无 Python，暂时无法解析远端链接；环境准备后将校验并显示配置。'
          ylw "$remote_info"
        fi
        ;;
      2)
        rd=$(node_input domain '远端域名' '') || return 0
        rp=$(node_input remote-port '远端端口' 443) || return 0
        ru=$(node_input remote-uuid '远端 UUID' '') || return 0
        rw=$(node_input remote-path '远端 WS 路径' '') || return 0
        rh=$(node_input domain '远端 WebSocket Host' "$rd") || return 0
        rs=$(node_input domain '远端 TLS SNI' "$rd") || return 0
        remote_args=(manual "$rd" "$rp" "$ru" "$rw" "$rh" "$rs")
        remote_info="远端：${rd}:${rp}${rw}；Host=${rh}；SNI=$rs" ;;
      3) remote_args=(preserve); remote_info='保留现有远端配置' ;;
      *) return 0 ;;
    esac
  else echo '本机直出，无需填写远端。'; fi
  if command -v python3 >/dev/null; then
    remote_info=$(node_python validate-create "${NODE_ID:-new}" "$d" "$front" "$out" "$p" "$ws" "$u" "$image" ${remote_args[@]+"${remote_args[@]}"}) || return 1
  fi
  defaults=$(node_preview_defaults "$p" "$ws" "$u") || return 1
  values=()
  while IFS= read -r field; do values+=("$field"); done <<< "$defaults"
  p=${values[0]}; ws=${values[1]}; u=${values[2]}
  workflow_step '7 / 10 环境准备计划'
  plan_low_memory || return 0
  plan_qrencode || return 0
  if [[ $edit == no ]]; then plan_node_network || return 0; fi
  workflow_step '8 / 10 最终确认'
  printf '节点名称：%s\n类型：%s\n入口：%s（%s）\n路径：%s\n本地端口：%s\nUUID：%s\n镜像：%s\n' "$label" "$(if [[ $out == direct ]]; then echo 本机直出; else echo 远端中转; fi)" "$d" "$(if [[ $front == nginx ]]; then echo 已有Nginx; else echo Caddy; fi)" "$(if [[ $ws == auto ]]; then echo 自动生成; else echo "$ws"; fi)" "$(if [[ $p == auto ]]; then echo 自动分配; else echo "$p"; fi)" "$(if [[ $u == auto ]]; then echo 自动生成; else echo "$u"; fi)" "$image"
  [[ -z $remote_info ]] || echo "$remote_info"
  environment_summary
  node_network_summary
  if [[ $front == nginx ]]; then ylw 'Nginx 状态：创建后待手工配置 HTTPS 转发。';
  else echo '防火墙：为 Caddy 放行 80/443（仅修改已启用的防火墙）。'; fi
  printf '\n'
  confirm '确认执行以上全部计划？' n || return 0
  workflow_step '9 / 10 执行准备与创建'
  execute_environment_plan || return 1
  if [[ $PLAN_NETWORK == yes && ! -f $STACK_DIR/network-bbr-enabled ]]; then
    install_node_network_dependencies || return 1
    network_enable_execute || return 1
    NODE_NETWORK_RETAIN_NOTICE=yes
  fi
  remote_info=$(node_python validate-create "${NODE_ID:-new}" "$d" "$front" "$out" "$p" "$ws" "$u" "$image" ${remote_args[@]+"${remote_args[@]}"}) || return 1
  [[ -z $remote_info ]] || echo "$remote_info"
  if { [[ $edit == no ]] || [[ $p != $(node_get port) ]]; } && port_in_use "$p"; then
    red '本地端口在确认后已被占用，停止创建；请重新选择端口。'
    return 1
  fi
  if [[ $edit == no ]]; then NODE_ID=$(node_python allocate) || return 1; fi
  node_owner "v2fly-node-$NODE_ID" "v2fly-node-$NODE_ID" || return 1
  open_firewall "$front" || return 1
  mkdir -p "$STACK_DIR/nodes"; chmod 700 "$STACK_DIR/nodes"
  backup=$(mktemp -d "$STACK_DIR/.node-recovery.XXXXXX"); chmod 700 "$backup"
  if [[ $existed == yes ]]; then
    cp -p "$STACK_DIR/nodes/$NODE_ID/"* "$backup/" || return 1
    oldimage=$(docker inspect -f '{{.Image}}' "v2fly-node-$NODE_ID" 2>/dev/null || true)
  fi
  node_snapshot "$backup" "$oldimage" "$existed" || return 1
  if [[ $existed == yes && $image == "$previousimage" ]]; then
    [[ -n $oldimage ]] || { NODE_TX_ACTIVE=no; red "无法读取旧镜像 ID，停止修改；备份：$backup"; return 1; }
    image=$oldimage
  fi
  if ! node_python create "$NODE_ID" "$d" "$front" "$out" "$p" "$ws" "$u" "$image" ${remote_args[@]+"${remote_args[@]}"}; then
    if [[ $existed == yes ]]; then node_restore_files "$backup" || return 1; else rm -rf "$STACK_DIR/nodes/$NODE_ID"; fi
    NODE_TX_ACTIVE=no
    return 1
  fi
  if [[ $image != sha256:* ]] && ! node_compose pull -q v2fly; then
    NODE_TX_ACTIVE=no
    if [[ $existed == yes ]]; then node_restore_files "$backup"; else rm -rf "$STACK_DIR/nodes/$NODE_ID"; fi
    red "拉取失败，原节点未改变；备份：$backup"; return 1
  fi
  if ! node_python label "$NODE_ID" "$label"; then node_recover "$backup" "$oldimage" "$existed"; return 1; fi
  node_apply "$backup" "$oldimage" "$existed" || return 1
  NODE_TX_ACTIVE=no
  rm -rf "$backup"
  NODE_NETWORK_RETAIN_NOTICE=no
  workflow_step '10 / 10 创建结果'
  if [[ $front == nginx ]]; then grn '节点本地服务已就绪；Nginx HTTPS 转发待手工配置。'; else grn '节点配置与链路自检已通过。'; fi
  node_show
}
cmd_node_manage() {
  need_docker; node_select || return 1
  printf '%s\n' '1) 链接/二维码' '2) 修改' '3) 测试连接' '4) 日志' '5) 重启' '6) 删除' '7) 更新镜像' '0) 返回'
  case "$(node_choice '操作' '1' '01234567')" in
    1) node_show ;;
    2) cmd_node_add yes ;;
    3) node_test ;;
    4) docker logs --tail 100 "v2fly-node-$NODE_ID" ;;
    5) node_compose restart v2fly ;;
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
  oldimage=$(docker inspect -f '{{.Image}}' "v2fly-node-$NODE_ID" 2>/dev/null || true)
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
  oldimage=$(docker inspect -f '{{.Image}}' "v2fly-node-$NODE_ID" 2>/dev/null || true)
  node_snapshot "$backup" "$oldimage" yes || return 1
  node_python image "$NODE_ID" "v2fly/v2fly-core:$image" || return 1
  if ! node_compose pull -q v2fly; then NODE_TX_ACTIVE=no; node_restore_files "$backup"; red "拉取失败；备份：$backup"; return 1; fi
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
  node_owner v2fly-ingress v2fly-ingress || return 1
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
  node_owner v2fly-ingress v2fly-ingress || return 1
  ylw '更新共享 Caddy 会短暂中断全部 Caddy 节点的连接，客户端需要重连。'
  confirm '确认更新共享 Caddy 到 caddy:2？' n || return 0
  INGRESS_TX_IMAGE=$(docker inspect -f '{{.Image}}' v2fly-ingress 2>/dev/null) || { red '无法读取现有 Caddy 镜像，停止更新。'; return 1; }
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

# tc JSON 保留整数精度：rate 是字节/秒，普通时间是微秒，timer_slack 是纳秒。
network_qdisc_plan() {
  python3 - "$1" <<'PY'
import json, re, sys

def integer(value, maximum=0xffffffff):
    if type(value) is not int or not 0 <= value <= maximum:
        raise ValueError('无效整数队列参数')
    return value

def plan(raw):
    data = json.loads(raw)
    if not isinstance(data, list) or not data:
        raise ValueError('队列 JSON 缺失')
    result = []
    for q in data:
        if not isinstance(q, dict) or set(q) - {'kind', 'handle', 'root', 'parent', 'refcnt', 'options'}:
            raise ValueError('未知队列属性')
        kind, handle, parent = q.get('kind'), q.get('handle'), q.get('parent')
        if kind not in ('mq', 'fq', 'fq_codel') or not re.fullmatch(r'[0-9a-f]+:', handle or ''):
            raise ValueError('未知队列类型或句柄')
        if q.get('root') is True:
            if parent is not None:
                raise ValueError('队列根与父级冲突')
        elif not isinstance(parent, str) or not re.fullmatch(r'[0-9a-f]*:[0-9a-f]+', parent):
            raise ValueError('无效父级')
        options = q.get('options', {})
        if not isinstance(options, dict):
            raise ValueError('未知队列选项')
        options = dict(options)
        # iproute2 的 PRINT_ANY 数组标签在 JSON 中保留尾空格，仅接纳这两个已知别名。
        if kind == 'fq':
            for alias, canonical in (('priomap ', 'priomap'), ('weights ', 'weights')):
                if alias in options:
                    if canonical in options:
                        raise ValueError('队列数组字段别名冲突')
                    options[canonical] = options.pop(alias)
        plain = {'limit', 'flow_limit', 'buckets', 'orphan_mask', 'quantum', 'initial_quantum'} if kind == 'fq' else {'limit', 'flows', 'quantum', 'drop_batch', 'memory_limit'}
        times = {'refill_delay', 'horizon', 'ce_threshold', 'offload_horizon'} if kind == 'fq' else {'target', 'interval', 'ce_threshold'}
        rates = {'maxrate', 'low_rate_threshold'} if kind == 'fq' else set()
        allowed = plain | times | rates
        allowed |= {'pacing', 'timer_slack', 'bands', 'priomap', 'weights', 'horizon_drop', 'horizon_cap'} if kind == 'fq' else {'ecn'}
        if (kind == 'mq' and options) or (kind != 'mq' and set(options) - allowed):
            raise ValueError('未知队列选项')
        if kind == 'fq':
            options.setdefault('low_rate_threshold', 0)
        if kind == 'mq' and parent is not None:
            raise ValueError('mq 只能作为根队列')
        args = []
        for key, value in sorted(options.items()):
            if key in ('pacing', 'ecn', 'bands', 'priomap', 'weights'):
                continue
            if key in plain:
                args += [key, str(integer(value))]
            elif key in times:
                args += [key, str(integer(value)) + 'us']
            elif key in rates:
                args += [key, str(integer(value) * 8) + 'bit']
            elif key == 'timer_slack':
                args += [key, str(integer(value)) + 'ns']
            elif key in ('horizon_drop', 'horizon_cap'):
                if value is not None or {'horizon_drop', 'horizon_cap'} <= options.keys():
                    raise ValueError('无效 horizon 选项')
                args += [key]
        if kind == 'fq':
            pacing = options.get('pacing', True)
            if type(pacing) is not bool:
                raise ValueError('无效 pacing 状态')
            args += ['pacing' if pacing else 'nopacing']
            if 'bands' in options or 'priomap' in options:
                priomap = options.get('priomap')
                if options.get('bands') != 3 or not isinstance(priomap, list) or len(priomap) != 16:
                    raise ValueError('无效 bands / priomap')
                args += ['bands', '3', 'priomap'] + [str(integer(v, 2)) for v in priomap]
            if 'weights' in options:
                weights = options['weights']
                if not isinstance(weights, list) or len(weights) != 3 or any(integer(v, 0x7fffffff) == 0 for v in weights):
                    raise ValueError('无效 weights')
                args += ['weights'] + [str(v) for v in weights]
        elif kind == 'fq_codel':
            ecn = options.get('ecn', False)
            if type(ecn) is not bool:
                raise ValueError('无效 ECN 状态')
            args += ['ecn' if ecn else 'noecn']
        result.append({'kind': kind, 'handle': handle, 'parent': parent, 'args': args})
    roots = [q for q in result if q['parent'] is None]
    if len(roots) != 1:
        raise ValueError('队列根不唯一')
    root = roots[0]
    if root['kind'] == 'mq':
        major = ':' if root['handle'] == '0:' else root['handle']
        parents = [q['parent'] for q in result if q['parent'] is not None]
        if len(parents) != len(result) - 1 or not parents or len(set(parents)) != len(parents) or any(not p.startswith(major) for p in parents):
            raise ValueError('mq 子队列归属不明确')
    elif len(result) != 1:
        raise ValueError('未知队列结构')
    return result
try:
    print(json.dumps(plan(sys.argv[1]), separators=(',', ':'), sort_keys=True))
except (ValueError, TypeError, KeyError) as error:
    print('无法安全恢复队列：' + str(error), file=sys.stderr)
    sys.exit(1)
PY
}

# 匿名 mq 可保留具名根；比较调度类型、父级序号及全部规范化选项。
network_qdisc_equal() {
  python3 - "$1" "$2" <<'PY'
import json, sys

def signature(raw):
    return sorted((q['parent'].split(':', 1)[1] if q['parent'] is not None else '', q['kind'], q['args']) for q in json.loads(raw))
sys.exit(0 if signature(sys.argv[1]) == signature(sys.argv[2]) else 1)
PY
}

# 只读检查：拒绝不明确的默认出口及未知队列，避免覆盖用户整形配置。
network_inspect() {
  local routes line output roots children kind parent handle root_kind='' count=0
  command -v ip >/dev/null && command -v tc >/dev/null && command -v sysctl >/dev/null || {
    red '缺少 ip、tc 或 sysctl，无法检查网络优化。'; return 1;
  }
  routes=$(ip -o route show default 2>/dev/null) || return 1
  [[ $(printf '%s\n' "$routes" | sed '/^$/d' | wc -l) -eq 1 ]] || {
    red '默认路由不唯一，无法确定要优化的出口网卡。'; return 1;
  }
  NETWORK_IFACE=$(printf '%s\n' "$routes" | awk '{for(i=1;i<NF;i++) if($i=="dev") {print $(i+1); exit}}')
  [[ $NETWORK_IFACE =~ ^[a-zA-Z0-9_.-]+$ ]] || { red '无法识别有效的出口网卡。'; return 1; }
  output=$(tc qdisc show dev "$NETWORK_IFACE") || return 1
  NETWORK_QDISC_OUTPUT=$output
  NETWORK_QDISC_JSON=$(tc -j qdisc show dev "$NETWORK_IFACE") || return 1
  NETWORK_QDISC_PLAN=$(network_qdisc_plan "$NETWORK_QDISC_JSON") || return 1
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    read -r _ kind _ _ <<< "$line"
    if [[ $line == *' root'* ]]; then
      [[ -z $root_kind ]] || { red '存在多个根队列，停止网络优化。'; return 1; }
      root_kind=$kind
    elif [[ $line == *' parent '* ]]; then
      case "$kind" in fq|fq_codel) ;; *) red '检测到未知子队列，停止网络优化。'; return 1 ;; esac
      count=$((count + 1))
    else
      red '检测到未知队列结构，停止网络优化。'; return 1
    fi
  done <<< "$output"
  case "$root_kind:$count" in
    fq:0|fq_codel:0) NETWORK_QDISC_KIND=single ;;
    mq:*) (( count > 0 )) || { red '多队列缺少可见子队列。'; return 1; }; NETWORK_QDISC_KIND=mq ;;
    *) red '检测到不支持的出口队列结构，停止网络优化。'; return 1 ;;
  esac
  if [[ $NETWORK_QDISC_KIND == mq ]]; then
    handle=$(printf '%s\n' "$NETWORK_QDISC_OUTPUT" | awk '$2=="mq" && $0 ~ / root/ {print $3; exit}')
    [[ $handle != 0: ]] || handle=:
    children=' '
    while IFS= read -r line; do
      [[ $line == *' parent '* ]] || continue
      parent=$(printf '%s\n' "$line" | awk '{for(i=1;i<NF;i++) if($i=="parent") {print $(i+1);exit}}')
      [[ $parent == "$handle"* && $children != *" $parent "* ]] || { red 'mq 子队列归属不明确或重复，停止。'; return 1; }
      children+="$parent "
    done <<< "$NETWORK_QDISC_OUTPUT"
  fi
  output=$(tc filter show dev "$NETWORK_IFACE" 2>/dev/null) || return 1
  [[ -z $output ]] || { red '检测到网卡流量过滤规则，停止网络优化。'; return 1; }
}

# 使用 network_inspect 的只读结果；调用方须保存原始队列并处理失败。
network_set_fq() {
  local line handle parent kind
  if [[ $NETWORK_QDISC_KIND == single ]]; then
    if [[ $NETWORK_QDISC_OUTPUT != 'qdisc fq '* ]]; then
      touch "$NETWORK_TX_BACKUP/queue-started" || return 1
      tc qdisc replace dev "$NETWORK_IFACE" root fq || return 1
    fi
  else
    handle=$(printf '%s\n' "$NETWORK_QDISC_OUTPUT" | awk '$2=="mq" && $0 ~ / root/ {print $3; exit}')
    if [[ $handle == 0: ]]; then
      touch "$NETWORK_TX_BACKUP/queue-started" || return 1
      tc qdisc replace dev "$NETWORK_IFACE" root handle 1: mq || return 1
      NETWORK_QDISC_OUTPUT=$(tc qdisc show dev "$NETWORK_IFACE") || return 1
    fi
    while IFS= read -r line; do
      [[ $line == *' parent '* ]] || continue
      kind=$(printf '%s\n' "$line" | awk '{print $2}')
      [[ $kind != fq ]] || continue
      parent=$(printf '%s\n' "$line" | awk '{for(i=1;i<NF;i++) if($i=="parent") {print $(i+1);exit}}')
      [[ $parent =~ ^[0-9a-f]*:[0-9a-f]+$ ]] || return 1
      touch "$NETWORK_TX_BACKUP/queue-started" || return 1
      tc qdisc replace dev "$NETWORK_IFACE" parent "$parent" fq || return 1
    done <<< "$NETWORK_QDISC_OUTPUT"
  fi
}

# 此函数只负责生成受管文件；调用者须先验证目标文件不存在并建立恢复记录。
network_write_persistence() {
  local modules_file=$1 sysctl_file=$2
  mkdir -p "$(dirname "$modules_file")" "$(dirname "$sysctl_file")" || return 1
  printf 'tcp_bbr\nsch_fq\n' > "$modules_file" || return 1
  printf 'net.ipv4.tcp_congestion_control = bbr\nnet.core.default_qdisc = fq\n' > "$sysctl_file" || return 1
}

# 仅用于明确启用网络优化的集中操作，不改变其他项目的容器。
network_recreate_node() {
  local id=$1 image=$2 override=$3
  NODE_ID=$id
  printf 'services:\n  v2fly:\n    image: %s\n' "$image" > "$override" || return 1
  node_compose -f "$STACK_DIR/nodes/$id/compose.yaml" -f "$override" config -q || return 1
  node_compose -f "$STACK_DIR/nodes/$id/compose.yaml" -f "$override" up -d --no-deps --force-recreate --pull never v2fly || return 1
  [[ $(docker exec "v2fly-node-$id" cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null) == bbr ]] || return 1
  if [[ $(node_get front) == caddy ]]; then
    docker network connect v2fly-ingress_default "v2fly-node-$id" || return 1
  fi
  wait_for node_local_ok 6
}

# 网络优化变更先记录各容器真实镜像，避免标签指向新镜像导致误升级。
network_snapshot_containers() {
  local backup=$1 id image ids congestion
  ids=$(node_python ids) || return 1
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    node_owner "v2fly-node-$id" "v2fly-node-$id" || return 1
    [[ $(docker inspect -f '{{.State.Running}}' "v2fly-node-$id") == true ]] || { red "节点 $id 未运行，请先处理后重试。"; return 1; }
    [[ ! -e $STACK_DIR/nodes/$id/compose.override.yaml && ! -e $STACK_DIR/nodes/$id/compose.override.yml ]] || {
      red "节点 $id 存在 Compose override，请先手工处理后重试。"; return 1;
    }
    image=$(docker inspect -f '{{.Image}}' "v2fly-node-$id" 2>/dev/null) || return 1
    [[ $image =~ ^sha256:[a-f0-9]{64}$ ]] || return 1
    mkdir -p "$backup/nodes/$id" || return 1
    cp -p "$STACK_DIR/nodes/$id/compose.yaml" "$backup/nodes/$id/compose.yaml" || return 1
    printf '%s\n' "$image" > "$backup/nodes/$id/image" || return 1
    congestion=$(docker exec "v2fly-node-$id" cat /proc/sys/net/ipv4/tcp_congestion_control) || return 1
    [[ $congestion =~ ^[a-zA-Z0-9_]+$ ]] || return 1
    printf '%s\n' "$congestion" > "$backup/nodes/$id/congestion" || return 1
  done <<< "$ids"
  if [[ -f $STACK_DIR/ingress.yaml ]]; then
    node_owner v2fly-ingress v2fly-ingress || return 1
    [[ ! -e $STACK_DIR/compose.override.yaml && ! -e $STACK_DIR/compose.override.yml ]] || { red '共享入口存在 Compose override，停止。'; return 1; }
    [[ $(docker inspect -f '{{.State.Running}}' v2fly-ingress) == true ]] || return 1
    image=$(docker inspect -f '{{.Image}}' v2fly-ingress 2>/dev/null) || return 1
    [[ $image =~ ^sha256:[a-f0-9]{64}$ ]] || return 1
    cp -p "$STACK_DIR/ingress.yaml" "$backup/ingress.yaml" || return 1
    printf '%s\n' "$image" > "$backup/ingress.image" || return 1
    congestion=$(docker exec v2fly-ingress cat /proc/sys/net/ipv4/tcp_congestion_control) || return 1
    [[ $congestion =~ ^[a-zA-Z0-9_]+$ ]] || return 1
    printf '%s\n' "$congestion" > "$backup/ingress.congestion" || return 1
  fi
}

# 结构化快照生成合法参数；首条 tc 失败且状态未变化时直接跳过恢复。
network_restore_qdisc() {
  local original current raw root_handle row commands weights_index rc=0
  local -a args
  original=$(cat "$NETWORK_TX_BACKUP/qdisc-plan.json") || return 1
  raw=$(tc -j qdisc show dev "$NETWORK_IFACE") || return 1
  current=$(network_qdisc_plan "$raw") || return 1
  network_qdisc_equal "$original" "$current" && return 0
  root_handle=$(python3 -c 'import json,sys; print(next(q["handle"] for q in json.loads(sys.argv[1]) if q["parent"] is None))' "$current") || return 1
  commands=$(python3 - "$original" "$root_handle" <<'PY'
import json, sys
for q in json.loads(sys.argv[1]):
    if q['kind'] == 'mq':
        continue
    parent = q['parent']
    args = ['root'] if parent is None else ['parent', sys.argv[2] + parent.split(':', 1)[1]]
    if q['handle'] != '0:':
        args += ['handle', q['handle']]
    print(' '.join(args + [q['kind']] + q['args']))
PY
  ) || return 1
  while IFS= read -r row; do
    read -r -a args <<< "$row"
    if tc qdisc replace dev "$NETWORK_IFACE" "${args[@]}"; then continue; fi
    # 部分 iproute2 的 weights 解析器多前进一次；仅在标准三值失败时补一个占位 0。
    # 正常解析器会拒绝 0，不会误应用；两条路径都必须通过下方实际 JSON 核验。
    weights_index=$((${#args[@]} - 4))
    if (( weights_index >= 0 )) && [[ ${args[$weights_index]} == weights ]]; then
      args=("${args[@]:0:$((weights_index + 1))}" 0 "${args[@]:$((weights_index + 1))}")
      tc qdisc replace dev "$NETWORK_IFACE" "${args[@]}" || rc=1
    else rc=1; fi
  done <<< "$commands"
  raw=$(tc -j qdisc show dev "$NETWORK_IFACE") || return 1
  current=$(network_qdisc_plan "$raw") || return 1
  network_qdisc_equal "$original" "$current" || rc=1
  return "$rc"
}

network_recover() {
  NETWORK_TX_ACTIVE=no
  local backup=$NETWORK_TX_BACKUP id image congestion rc=0 override
  # 恢复所有文件后再重建已开始变更的容器；镜像固定为操作前的 ID。
  if [[ -f $backup/host-started ]]; then
    rm -f /etc/modules-load.d/90-v2fly-bbr.conf /etc/sysctl.d/90-v2fly-bbr.conf || rc=1
    sysctl -w "net.core.default_qdisc=$(cat "$backup/default-qdisc")" >/dev/null || rc=1
    sysctl -w "net.ipv4.tcp_congestion_control=$(cat "$backup/congestion")" >/dev/null || rc=1
    NETWORK_IFACE=$(cat "$backup/iface")
    if [[ -f $backup/queue-started ]]; then network_restore_qdisc || rc=1; fi
  fi
  rm -f "$STACK_DIR/network-bbr-enabled" || rc=1
  for id in "$backup"/nodes/*; do
    [[ -d $id ]] || continue
    cp -p "$id/compose.yaml" "$STACK_DIR/nodes/${id##*/}/compose.yaml" || rc=1
  done
  [[ ! -f $backup/ingress.yaml ]] || cp -p "$backup/ingress.yaml" "$STACK_DIR/ingress.yaml" || rc=1
  for id in "$backup"/nodes/*; do
    [[ -f $id/started ]] || continue
    NODE_ID=${id##*/}; image=$(cat "$id/image"); override=$id/image-override.yaml
    congestion=$(cat "$id/congestion") || { rc=1; continue; }
    [[ $congestion =~ ^[a-zA-Z0-9_]+$ ]] || { rc=1; continue; }
    printf 'services:\n  v2fly:\n    image: %s\n    sysctls:\n      net.ipv4.tcp_congestion_control: %s\n' "$image" "$congestion" > "$override" || { rc=1; continue; }
    if node_compose -f "$STACK_DIR/nodes/$NODE_ID/compose.yaml" -f "$override" up -d --no-deps --force-recreate --pull never v2fly; then
      if [[ $(node_get front) == caddy ]]; then
        docker network connect v2fly-ingress_default "v2fly-node-$NODE_ID" || rc=1
      fi
      wait_for node_local_ok 6 || rc=1
      [[ $(docker exec "v2fly-node-$NODE_ID" cat /proc/sys/net/ipv4/tcp_congestion_control) == "$congestion" ]] || rc=1
    else rc=1; fi
  done
  if [[ -f $backup/ingress-started ]]; then
    image=$(cat "$backup/ingress.image"); override=$backup/ingress-image-override.yaml
    congestion=$(cat "$backup/ingress.congestion") || return 1
    [[ $congestion =~ ^[a-zA-Z0-9_]+$ ]] || return 1
    printf 'services:\n  caddy:\n    image: %s\n    sysctls:\n      net.ipv4.tcp_congestion_control: %s\n' "$image" "$congestion" > "$override" || rc=1
    ingress_compose -f "$override" up -d --no-deps --force-recreate --pull never caddy || rc=1
    ingress_ready || rc=1
    [[ $(docker exec v2fly-ingress cat /proc/sys/net/ipv4/tcp_congestion_control) == "$congestion" ]] || rc=1
  fi
  if (( rc == 0 )); then ylw "已恢复原配置、拥塞算法、叶子队列参数和容器（匿名 mq 根保留具名句柄）。备份保留：$backup"
  else red "恢复不完整；请根据备份人工恢复：$backup"; fi
  return "$rc"
}

# 模拟加入受管配置后的 sysctl.d 文件选择；不修改发行版或管理员文件。
network_check_sysctl_priority() {
  python3 - "${1:-/}" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
managed = '90-v2fly-bbr.conf'
targets = {'net.ipv4.tcp_congestion_control': 'bbr', 'net.core.default_qdisc': 'fq'}
selected, seen_dirs = {}, set()

def values(path):
    if path.is_symlink() and path.resolve() == pathlib.Path('/dev/null'):
        return []
    result = []
    for line in path.read_text(errors='replace').splitlines():
        line = re.split(r'[#;]', line, maxsplit=1)[0]
        match = re.match(r'\s*-?([^\s=]+)\s*=\s*(\S+)', line)
        if match:
            key = match[1].replace('/', '.')
            if key in targets:
                result.append((key, match[2]))
    return result

try:
    # 同名文件目录优先级；/lib 可能是 /usr/lib 的别名，只枚举一次。
    for folder in ('etc/sysctl.d', 'run/sysctl.d', 'usr/local/lib/sysctl.d', 'usr/lib/sysctl.d', 'lib/sysctl.d'):
        directory = root / folder
        resolved = directory.resolve()
        if resolved in seen_dirs:
            continue
        seen_dirs.add(resolved)
        if directory.exists():
            for path in directory.glob('*.conf'):
                selected.setdefault(path.name, (path, folder == 'etc/sysctl.d'))
    parsed = {name: values(path) for name, (path, _) in selected.items()}
    # 管理员的 /etc 配置即便排序较早，也不静默压过；独立 sysctl.conf 同样保护。
    for name, (path, admin) in selected.items():
        if admin:
            for key, value in dict(parsed[name]).items():
                if value != targets[key]:
                    raise ValueError('管理员 sysctl 配置冲突，请先人工处理：' + str(path))
    admin_conf = root / 'etc/sysctl.conf'
    if admin_conf.exists() or admin_conf.is_symlink():
        for key, value in dict(values(admin_conf)).items():
            if value != targets[key]:
                raise ValueError('管理员 sysctl 配置冲突，请先人工处理：' + str(admin_conf))
    # 受管 /etc 文件覆盖其他目录的同名文件，再按跨目录文件名顺序计算最终值。
    parsed[managed] = list(targets.items())
    effective = {}
    origins = {}
    for name in sorted(parsed):
        for key, value in parsed[name]:
            effective[key] = value
            origins[key] = name
    for key, desired in targets.items():
        if effective.get(key) != desired:
            path = selected[origins[key]][0]
            raise ValueError('后置 sysctl 配置会覆盖网络优化，请先人工处理：' + str(path))
except (OSError, ValueError) as error:
    print(str(error), file=sys.stderr)
    sys.exit(1)
PY
}

network_preflight() {
  local file value
  for value in python3 modprobe; do
    command -v "$value" >/dev/null || { red "缺少 ${value}；请先初始化环境。"; return 1; }
  done
  [[ -d /run/systemd/system ]] || { red '当前系统未使用 systemd，无法持久化网络配置。'; return 1; }
  [[ ! -e $STACK_DIR/network-bbr-enabled ]] || { red '已有网络优化配置；请查看网络状态，不重复覆盖。'; return 1; }
  for file in /etc/modules-load.d/90-v2fly-bbr.conf /etc/sysctl.d/90-v2fly-bbr.conf; do
    [[ ! -e $file && ! -L $file ]] || { red "文件已存在，不覆盖：$file"; return 1; }
  done
  network_check_sysctl_priority || return 1
  network_inspect || return 1
  # dry-run 只检查模块是否可用；真正加载发生在确认后。
  modprobe -n tcp_bbr && modprobe -n sch_fq || { red '内核缺少 BBR 或 fq 模块。'; return 1; }
  sysctl -n net.ipv4.tcp_congestion_control >/dev/null || return 1
  sysctl -n net.core.default_qdisc >/dev/null || return 1
}

network_add_sysctl() {
  python3 - "$1" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
if '    sysctls:' in s:
    raise SystemExit('已有容器 sysctls，停止以免覆盖用户配置')
needle = '    restart: unless-stopped\n'
if s.count(needle) != 1:
    raise SystemExit('无法识别受管 Compose 文件')
p.write_text(s.replace(needle, needle + '    sysctls:\n      net.ipv4.tcp_congestion_control: bbr\n'))
PY
}

network_apply() {
  local backup=$NETWORK_TX_BACKUP id image override
  # 操作前先检查所有 Compose 文件均可修改，避免变更中途才发现配置冲突。
  for id in "$backup"/nodes/*; do
    [[ -d $id ]] || continue
    cp -p "$id/compose.yaml" "$id/planned.yaml" || return 1
    network_add_sysctl "$id/planned.yaml" || return 1
    NODE_ID=${id##*/}
    node_compose -f "$id/planned.yaml" config -q || return 1
  done
  if [[ -f $backup/ingress.yaml ]]; then
    cp -p "$backup/ingress.yaml" "$backup/ingress-planned.yaml" || return 1
    network_add_sysctl "$backup/ingress-planned.yaml" || return 1
    ingress_compose -f "$backup/ingress-planned.yaml" config -q || return 1
  fi
  # 从此标记起，任何失败或信号都会进入恢复；模块保留加载，不卸载共享内核模块。
  touch "$backup/host-started" || return 1
  modprobe tcp_bbr && modprobe sch_fq || return 1
  [[ " $(sysctl -n net.ipv4.tcp_available_congestion_control) " == *' bbr '* ]] || return 1
  network_write_persistence /etc/modules-load.d/90-v2fly-bbr.conf /etc/sysctl.d/90-v2fly-bbr.conf || return 1
  sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null || return 1
  sysctl -w net.core.default_qdisc=fq >/dev/null || return 1
  network_set_fq || return 1
  touch "$STACK_DIR/network-bbr-enabled" || return 1
  for id in "$backup"/nodes/*; do
    [[ -d $id ]] || continue
    cp -p "$id/planned.yaml" "$STACK_DIR/nodes/${id##*/}/compose.yaml" || return 1
    image=$(cat "$id/image"); touch "$id/started" || return 1
    network_recreate_node "${id##*/}" "$image" "$id/image-override.yaml" || return 1
  done
  if [[ -f $backup/ingress.yaml ]]; then
    cp -p "$backup/ingress-planned.yaml" "$STACK_DIR/ingress.yaml" || return 1
    image=$(cat "$backup/ingress.image"); override=$backup/ingress-image-override.yaml
    printf 'services:\n  caddy:\n    image: %s\n' "$image" > "$override" || return 1
    touch "$backup/ingress-started" || return 1
    ingress_compose -f "$override" up -d --no-deps --force-recreate --pull never caddy || return 1
    [[ $(docker exec v2fly-ingress cat /proc/sys/net/ipv4/tcp_congestion_control) == bbr ]] || return 1
    ingress_ready || return 1
  fi
  [[ $(sysctl -n net.ipv4.tcp_congestion_control) == bbr ]] || return 1
  [[ $(sysctl -n net.core.default_qdisc) == fq ]] || return 1
  network_inspect || return 1
  [[ $NETWORK_QDISC_OUTPUT != *fq_codel* ]] || return 1
}

cmd_network_enable() {
  need_docker
  network_preflight || return 1
  printf '计划：宿主机和本项目所有节点、共享 Caddy 使用 BBR；%s 使用 fq（保留 mq 根队列）。\n' "$NETWORK_IFACE"
  printf '匿名 mq 根需重建为具名 mq（1:），短暂重置叶子；恢复时恢复叶子参数，保留具名 mq 根。\n'
  printf '将重建现有容器并导致连接重连；新增节点继承配置。写入 modules-load/sysctl 配置并保存恢复备份。\n'
  printf '将系统默认队列设为 fq，立即切换当前出口队列；后续新建网卡队列继承默认值，无需重启。\n'
  confirm '确认启用 BBR + fq 并重建本项目所有容器？' n || return 0
  network_enable_execute
}

# 无交互执行核心：菜单确认或新增节点的最终总确认之后调用。
network_enable_execute() {
  local NODE_ID=${NODE_ID:-}
  need_docker
  # 执行之前重查路由、队列和配置，不沿用输入阶段的过期结果。
  network_preflight || return 1
  mkdir -p "$STACK_DIR" || return 1
  NETWORK_TX_BACKUP=$(mktemp -d "$STACK_DIR/network-backup.XXXXXXXX") || return 1
  chmod 700 "$NETWORK_TX_BACKUP" || return 1
  printf '%s\n' "$NETWORK_IFACE" > "$NETWORK_TX_BACKUP/iface" || return 1
  printf '%s\n' "$NETWORK_QDISC_OUTPUT" > "$NETWORK_TX_BACKUP/qdisc" || return 1
  printf '%s\n' "$NETWORK_QDISC_JSON" > "$NETWORK_TX_BACKUP/qdisc.json" || return 1
  printf '%s\n' "$NETWORK_QDISC_PLAN" > "$NETWORK_TX_BACKUP/qdisc-plan.json" || return 1
  sysctl -n net.ipv4.tcp_congestion_control > "$NETWORK_TX_BACKUP/congestion" || return 1
  sysctl -n net.core.default_qdisc > "$NETWORK_TX_BACKUP/default-qdisc" || return 1
  network_snapshot_containers "$NETWORK_TX_BACKUP" || { red "预检失败，系统未修改。备份：$NETWORK_TX_BACKUP"; return 1; }
  NETWORK_TX_ACTIVE=yes
  if network_apply; then
    NETWORK_TX_ACTIVE=no
    grn "BBR + fq 已启用；备份：$NETWORK_TX_BACKUP"
    network_status
  else
    red '网络优化失败，开始恢复。'
    network_recover || return 1
    return 1
  fi
}

network_status() {
  local value route iface id ids
  printf '\n网络优化：\n'
  if [[ -f $STACK_DIR/network-bbr-enabled ]]; then echo '  管理配置：已启用'; else echo '  管理配置：未启用'; fi
  if command -v docker >/dev/null && command -v python3 >/dev/null; then
    ids=$(node_python ids 2>/dev/null || true)
    while IFS= read -r id; do
      [[ -n $id ]] || continue
      value=$(docker exec "v2fly-node-$id" cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true)
      printf '  节点 %s 拥塞算法：%s\n' "$id" "${value:-无法读取}"
    done <<< "$ids"
    if [[ -f $STACK_DIR/ingress.yaml ]]; then
      value=$(docker exec v2fly-ingress cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true)
      printf '  共享 Caddy 拥塞算法：%s\n' "${value:-无法读取}"
    fi
  fi
  value=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
  printf '  宿主机拥塞算法：%s\n' "${value:-无法读取}"
  value=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
  printf '  系统默认队列：%s\n' "${value:-无法读取}"
  route=$(ip -o route show default 2>/dev/null || true)
  if [[ $(printf '%s\n' "$route" | sed '/^$/d' | wc -l) -eq 1 ]]; then
    iface=$(printf '%s\n' "$route" | awk '{for(i=1;i<NF;i++) if($i=="dev") {print $(i+1); exit}}')
    if [[ -n $iface ]]; then
      printf '  默认出口网卡：%s\n' "$iface"
      if command -v tc >/dev/null; then tc qdisc show dev "$iface" || ylw '  无法读取出口队列';
      else ylw '  未安装 tc，无法读取出口队列'; fi
      return 0
    fi
  fi
  ylw '  默认出口不唯一或无法读取，请手工检查路由与队列。'
}

cmd_nodes_status() {
  need_docker; node_python list || return 1
  local id entries domain front value
  local ids
  ids=$(node_python ids) || return 1
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    node_owner "v2fly-node-$id" "v2fly-node-$id" || return 1
    container_details "v2fly-node-$id" v2ray
    value=$(docker exec "v2fly-node-$id" cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true)
    printf '  容器拥塞算法：%s\n' "${value:-无法读取}"
  done <<< "$ids"
  if [[ -f $STACK_DIR/ingress.yaml ]]; then
    node_owner v2fly-ingress v2fly-ingress || return 1
    container_details v2fly-ingress caddy
    value=$(docker exec v2fly-ingress cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true)
    printf '  容器拥塞算法：%s\n' "${value:-无法读取}"
  fi
  network_status
  entries=$(node_python entries) || return 1
  while IFS=$'\t' read -r domain front; do
    [[ -n $domain ]] || continue
    certificate_details "$domain"
  done <<< "$entries"
}

# 与 main 一样直接调用动作，保留原有 errexit 和信号恢复语义。
node_menu() {
  local choice
  while true; do
    echo '======== V2Fly 多节点管理 ========'
    if command -v python3 >/dev/null; then node_python list || return 1;
    else ylw '尚无 Python；可以先填写新增节点，最终确认后统一准备环境。'; fi
    printf '\n------------------------------\n\n'
    printf '%s\n' '1) 新增节点' '2) 管理节点' '3) 所有节点状态' '4) 更新指定节点' '5) 删除节点' '6) 初始化环境' '7) 更新共享 Caddy' '8) 启用 BBR + fq' '9) 网络优化状态' '0) 退出'
    choice=$(node_choice '请选择' '0' '0123456789')
    [[ $choice != 0 ]] || return 0
    case "$choice" in
      1) cmd_node_add ;;
      2) cmd_node_manage ;;
      3) cmd_nodes_status ;;
      4) node_select && cmd_node_update ;;
      5) cmd_node_delete ;;
      6) cmd_init ;;
      7) cmd_ingress_update ;;
      8) cmd_network_enable ;;
      9) network_status ;;
    esac
    # 长期菜单在动作成功后释放临时测试资源；成功事务已经清除各自 ACTIVE 标记。
    cleanup
    TMP_DIRS=() E2E_CID_FILES=() E2E_CID_FILE=''
    set -e
  done
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
    network-enable) need_root network-enable; cmd_network_enable ;;
    network-status) need_root network-status; network_status ;;
    "") need_root; node_menu ;;
    *) die "未知命令: $1（可用: init node-add node-manage nodes node-update node-delete ingress-update network-enable network-status）" ;;
  esac
}

# 直接运行时执行 main；被 source 时不执行。
# 这一行同时兼容 bash <(curl ...) 和 curl | bash 两种写法。
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
