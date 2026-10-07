#!/usr/bin/env bash
# 仅模拟 OS、包管理、Docker、防火墙；所有外部写操作均由 mock 拦截。
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
SCRIPT="$PWD/v2fly-auto-setup.sh"
ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$ROOT"' EXIT
export SCRIPT ROOT
run_case() {
  local status=0
  bash -s -- "$1" <<'BASH' || status=$?
set -euo pipefail
source "$SCRIPT"
CASE=$1
LOG="$ROOT/$CASE.log"; : > "$LOG"
OS_FAMILY=el9; FRONT=caddy
HAVE_DOCKER=yes; HAVE_QR=yes; HAVE_UFW=no; HAVE_FIREWALL=yes
HAVE_COMPOSE=yes
QR_ATTEMPTS=0
PODMAN=no; MISSING=''; FIREWALL_RUNNING=yes; INTERFACE_ZONE=external
step(){ :; }; grn(){ :; }; ylw(){ printf 'warning %s\n' "$*" >> "$LOG"; }
assert(){ "$@" || { printf 'assert failed: %s\n' "$*" >&2; exit 1; }; }
contains(){ [[ $(cat "$LOG") == *"$1"* ]]; }
not_contains(){ [[ $(cat "$LOG") != *"$1"* ]]; }
command(){
  if [[ ${1:-} == -v ]]; then
    case "$2" in
      docker) [[ $HAVE_DOCKER == yes ]] ;;
      qrencode) [[ $HAVE_QR == yes ]] ;;
      ufw) [[ $HAVE_UFW == yes ]] ;;
      firewall-cmd) [[ $HAVE_FIREWALL == yes ]] ;;
      curl|openssl|python3|ss|ip)
        [[ $CASE != deps_missing_command || $2 != ss ]] ;;
      systemctl|dnf|rpm|apt-get) return 0 ;;
      *) builtin command "$@" ;;
    esac
  else builtin command "$@"; fi
}
rpm(){
  printf 'rpm %s\n' "$*" >> "$LOG"
  if [[ $2 == epel-release ]]; then [[ $CASE == epel_existing ]];
  elif [[ $2 == podman-docker ]]; then [[ $PODMAN == yes ]]; else [[ " $MISSING " != *" $2 "* ]]; fi
}
dnf(){
  printf 'dnf %s\n' "$*" >> "$LOG"
  if [[ $CASE == deps_failure && $* == 'install -y curl '* ]]; then return 1; fi
  if [[ $* == 'install -y qrencode' ]]; then
    QR_ATTEMPTS=$((QR_ATTEMPTS+1))
    if [[ $CASE == deps_optional || $CASE == epel_tool_fail ]]; then return 1; fi
    if [[ $CASE == epel_* && $QR_ATTEMPTS == 1 ]]; then return 1; fi
  fi
  if [[ $CASE == epel_repo_fail && $* == *epel-release-latest-9.noarch.rpm* ]]; then return 1; fi
  if [[ $* == 'install -y docker-ce '* && $CASE == docker_conflict ]]; then return 1; fi
  if [[ $* == *docker-ce* ]]; then HAVE_DOCKER=yes; fi
  if [[ $* == 'install -y curl '* && $CASE != deps_missing_package ]]; then MISSING=''; fi
  return 0
}
apt-get(){ printf 'FORBIDDEN apt-get\n' >> "$LOG"; exit 99; }
curl(){
  [[ $CASE == docker_plugin && $2 == https://github.com/docker/compose/releases/download/v2.24.7/* ]] || exit 99
  printf 'curl %s\n' "$*" >> "$LOG"
  local previous='' argument target=''
  for argument in "$@"; do [[ $previous != -o ]] || target=$argument; previous=$argument; done
  [[ -n $target && $target == "${TMP_DIRS[0]}"/* ]] || exit 99
  printf 'mock artifact\n' > "$target"
}
sh(){ printf 'FORBIDDEN sh\n' >> "$LOG"; exit 99; }
install(){
  [[ $CASE == docker_plugin ]] || exit 99
  printf 'install %s\n' "$*" >> "$LOG"
  [[ $1 != -m ]] || HAVE_COMPOSE=yes
}
uname(){ echo x86_64; }
sha256sum(){ printf 'sha256sum %s\n' "$*" >> "$LOG"; }
systemctl(){ printf 'systemctl %s\n' "$*" >> "$LOG"; }
docker(){
  printf 'docker %s\n' "$*" >> "$LOG"
  case "$*" in
    --version) if [[ $PODMAN == yes ]]; then echo 'podman version 4.9.4'; else echo 'Docker version 20.10.24'; fi ;;
    'compose version --short') echo 2.24.7 ;;
    info) [[ $CASE != docker_unready ]] ;;
    'compose version') [[ $HAVE_COMPOSE == yes ]]  ;;
    run*)
      local previous='' argument
      for argument in "$@"; do
        if [[ $previous == --cidfile ]]; then echo own-el9-client > "$argument"; fi
        previous=$argument
      done
      ;;
    'port own-el9-client 10808/tcp') echo 127.0.0.1:12345 ;;
    rm*) return 0 ;;
    *) printf 'FORBIDDEN unexpected docker\n' >&2; exit 99 ;;
  esac
}
firewall-cmd(){
  printf 'firewall-cmd %s\n' "$*" >> "$LOG"
  case "$1" in
    --state) [[ $FIREWALL_RUNNING == yes ]] ;;
    --get-zone-of-interface=ens192) echo "$INTERFACE_ZONE" ;;
    --get-default-zone) echo public ;;
    --zone=*|--permanent) return 0 ;;
    *) exit 99 ;;
  esac
}
ip(){ printf 'ip %s\n' "$*" >> "$LOG"; echo '1.1.1.1 via 10.0.0.1 dev ens192 src 10.0.0.2 uid 0'; }
ufw(){
  printf 'ufw %s\n' "$*" >> "$LOG"
  [[ $1 != status ]] || echo 'Status: active'
  [[ $CASE != firewall_ufw_failure || $* != 'allow 80/tcp' ]]
}
sleep(){ :; }
setenforce(){ exit 99; }
confirm(){
  printf 'confirm %s\n' "$*" >> "$LOG"
  [[ $2 == n && ( $CASE == epel_agree || $CASE == epel_repo_fail || $CASE == epel_tool_fail ) ]]
}
case "$CASE" in
  os_*)
    os_file="$ROOT/$CASE.os"
    case "$CASE" in
      os_debian) id=debian; version=12; name=Debian ;;
      os_ubuntu) id=ubuntu; version=24.04; name=Ubuntu ;;
      os_rocky9) id=rocky; version=9.6; name='Rocky Linux' ;;
      os_alma9) id=almalinux; version=9.6; name=AlmaLinux ;;
      os_stream9) id=centos; version=9; name='CentOS Stream' ;;
      os_reject_rocky8) id=rocky; version=8.10; name='Rocky Linux' ;;
      os_reject_alma8) id=almalinux; version=8.10; name=AlmaLinux ;;
      os_reject_stream8) id=centos; version=8; name='CentOS Stream' ;;
      os_reject_centoslinux9) id=centos; version=9; name='CentOS Linux' ;;
      os_reject_centoslinux8) id=centos; version=8; name='CentOS Linux' ;;
      os_reject_rhel9) id=rhel; version=9.6; name='Red Hat Enterprise Linux' ;;
      os_reject_fedora) id=fedora; version=42; name=Fedora ;;
    esac
    printf 'ID=%s\nVERSION_ID=%s\nNAME="%s"\n' "$id" "$version" "$name" > "$os_file"
    detect_os "$os_file"
    case "$CASE" in
      os_debian|os_ubuntu) assert test "$OS_FAMILY" = debian ;;
      *) assert test "$OS_FAMILY" = el9 ;;
    esac
    ;;
  deps_missing|deps_optional|deps_minimal|deps_failure|deps_missing_command|deps_missing_package|deps_qr_missing)
    if [[ $CASE == deps_minimal ]]; then MISSING=curl;
    else MISSING='curl curl-minimal ca-certificates openssl python3 iproute'; fi
    [[ $CASE != deps_optional && $CASE != deps_qr_missing ]] || HAVE_QR=no
    install_deps || exit 1
    if [[ $CASE == deps_minimal ]]; then assert not_contains 'dnf install -y curl';
    else assert contains 'dnf install -y curl ca-certificates openssl python3 iproute'; fi
    if [[ $CASE == deps_optional ]]; then
      assert not_contains 'dnf install -y qrencode'
      assert not_contains 'confirm '
      assert not_contains epel-release-latest-9.noarch.rpm
    fi
    if [[ $CASE == deps_qr_missing ]]; then assert contains 'qrencode 不可用'; assert not_contains 'confirm '; fi
    assert not_contains EPEL-release
    assert not_contains FORBIDDEN
    ;;
  epel_agree|epel_existing|epel_repo_fail|epel_tool_fail|epel_installed)
    HAVE_QR=no
    [[ $CASE != epel_installed ]] || HAVE_QR=yes
    install_qrencode_el9 allow || exit 1
    case "$CASE" in
      epel_installed) assert test ! -s "$LOG" ;;
      epel_existing) assert not_contains 'confirm '; assert not_contains epel-release-latest-9.noarch.rpm; assert test "$QR_ATTEMPTS" = 2 ;;
      *)
        assert not_contains 'confirm '
        assert contains 'dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm'
        if [[ $CASE == epel_repo_fail ]]; then assert test "$QR_ATTEMPTS" = 1; assert contains 'EPEL 软件源安装失败';
        elif [[ $CASE == epel_tool_fail ]]; then assert contains 'qrencode 仍无法安装';
        else assert test "$QR_ATTEMPTS" = 2; fi
        ;;
    esac
    assert not_contains nogpgcheck
    assert not_contains crb
    assert not_contains epel-next
    ;;
  docker_existing|docker_new|docker_podman|docker_conflict|docker_plugin|docker_unready)
    [[ $CASE != docker_new && $CASE != docker_conflict ]] || HAVE_DOCKER=no
    [[ $CASE != docker_podman ]] || PODMAN=yes
    [[ $CASE != docker_plugin ]] || HAVE_COMPOSE=no
    install_docker || exit 1
    if [[ $CASE == docker_existing || $CASE == docker_plugin ]]; then assert not_contains 'dnf ';
    else
      assert contains 'dnf install -y dnf-plugins-core'
      assert contains 'dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo'
      assert contains 'dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin'
    fi
    if [[ $CASE == docker_plugin ]]; then
      assert contains 'sha256sum -c checksum'
      assert contains 'install -m 755'
      assert contains '/usr/local/lib/docker/cli-plugins/docker-compose'
    fi
    assert contains 'systemctl enable --now docker'
    assert not_contains allowerasing
    assert not_contains 'dnf remove'
    assert not_contains FORBIDDEN
    ;;
  firewall_zone|firewall_default|firewall_inactive|firewall_nginx|firewall_ufw|firewall_ufw_failure|firewall_absent)
    [[ $CASE != firewall_absent ]] || HAVE_FIREWALL=no
    [[ $CASE != firewall_ufw_failure ]] || HAVE_UFW=yes
    [[ $CASE != firewall_default ]] || INTERFACE_ZONE='no zone'
    [[ $CASE != firewall_inactive ]] || FIREWALL_RUNNING=no
    [[ $CASE != firewall_nginx ]] || { FRONT=nginx; HAVE_UFW=yes; }
    [[ $CASE != firewall_ufw ]] || HAVE_UFW=yes
    open_firewall || exit 1
    if [[ $CASE == firewall_nginx || $CASE == firewall_absent ]]; then assert test ! -s "$LOG";
    elif [[ $CASE == firewall_inactive ]]; then assert not_contains --add-port;
    else
      zone=external; [[ $CASE != firewall_default ]] || zone=public
      assert contains 'ip -4 route get 1.1.1.1'
      assert contains 'firewall-cmd --get-zone-of-interface=ens192'
      for port in 80 443; do
        assert contains "firewall-cmd --zone=$zone --add-port=$port/tcp"
        assert contains "firewall-cmd --permanent --zone=$zone --add-port=$port/tcp"
      done
      [[ $CASE != firewall_ufw ]] || assert contains 'ufw allow 443/tcp'
    fi
    assert not_contains reload
    assert not_contains 'systemctl start firewalld'
    ;;
  selinux)
    FRONT=nginx; DOMAIN=test.invalid; UUID=test-only; WS_PATH=/test; E2E_IMAGE=v2fly/v2fly-core:latest
    curl(){ echo 204; }
    e2e_ok || exit 1
    assert contains '/etc/v2ray/config.json:ro,Z'
    assert not_contains label=disable
    ;;
  *) exit 98 ;;
esac
BASH
  case "$1" in
    os_reject_*|docker_podman|docker_conflict|docker_unready|deps_failure|deps_missing_command|deps_missing_package|firewall_ufw_failure) [[ $status == 1 ]] || return 1 ;;
    *) [[ $status == 0 ]] || return 1 ;;
  esac
  if [[ $1 == docker_podman ]]; then
    [[ $(cat "$ROOT/$1.log") != *'dnf '* && $(cat "$ROOT/$1.log") != *systemctl* ]] || return 1
  fi
  if [[ $1 == docker_conflict ]]; then
    [[ $(cat "$ROOT/$1.log") != *systemctl* && $(cat "$ROOT/$1.log") != *'dnf remove'* && $(cat "$ROOT/$1.log") != *allowerasing* ]] || return 1
  fi
  if [[ $1 == firewall_ufw_failure ]]; then
    [[ $(cat "$ROOT/$1.log") != *'ufw allow 443/tcp'* && $(cat "$ROOT/$1.log") != *firewall-cmd* ]] || return 1
  fi
  printf 'PASS %s\n' "$1"
}
for test in os_debian os_ubuntu os_rocky9 os_alma9 os_stream9 os_reject_rocky8 os_reject_alma8 os_reject_stream8 os_reject_centoslinux9 os_reject_centoslinux8 os_reject_rhel9 os_reject_fedora deps_missing deps_optional deps_minimal deps_failure deps_missing_command deps_missing_package deps_qr_missing epel_agree epel_existing epel_repo_fail epel_tool_fail epel_installed docker_existing docker_new docker_podman docker_conflict docker_plugin docker_unready firewall_zone firewall_default firewall_inactive firewall_nginx firewall_ufw firewall_ufw_failure firewall_absent selinux; do
  run_case "$test" || { printf 'FAIL %s\n' "$test" >&2; exit 1; }
done
