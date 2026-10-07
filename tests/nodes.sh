#!/usr/bin/env bash
# 独立临时目录与模拟 Docker；不安装软件、不访问网络、不启动容器。
set -euo pipefail
cd "$(dirname "$0")/.."
SCRIPT="$PWD/v2fly-auto-setup.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export SCRIPT ROOT
bash <<'TEST'
set -euo pipefail
source "$SCRIPT"
ORIGINAL_INGRESS=$(declare -f node_ingress_apply)
STACK_DIR="$ROOT/stack"; ENV_FILE="$STACK_DIR/.env"; COMPOSE_FILE="$STACK_DIR/compose.yaml"
mkdir -p "$STACK_DIR"
U=11111111-2222-4333-8444-555555555555
node_python create kr kr.example.com nginx direct 2334 /kr "$U" v2fly/v2fly-core:latest
node_python create jp kr.example.com nginx relay 2335 /jp "$U" v2fly/v2fly-core:latest manual jp.example.com 443 "$U" /remote
python3 - "$STACK_DIR" <<'PY'
import json,pathlib,sys,os
r=pathlib.Path(sys.argv[1]);a=json.loads((r/'nodes/kr/config.json').read_text());b=json.loads((r/'nodes/jp/config.json').read_text())
assert a['outbounds']==[{'protocol':'freedom','settings':{}}]
assert len(b['outbounds'])==1 and b['outbounds'][0]['protocol']=='vmess'
assert b['outbounds'][0]['streamSettings']['tlsSettings']['allowInsecure'] is False
for p in (r/'nodes').glob('*/*'):assert p.stat().st_mode&0o777==0o600
assert '127.0.0.1:2334:2333' in (r/'nodes/kr/compose.yaml').read_text()
PY
echo 'PASS independent-direct-relay-and-permissions'
if node_python create bad kr.example.com nginx direct 2334 /new "$U" v2fly/v2fly-core:latest; then exit 1; fi
if node_python create bad kr.example.com nginx direct 2336 /kr "$U" v2fly/v2fly-core:latest; then exit 1; fi
if node_python create bad KR.EXAMPLE.COM nginx direct 2336 /kr "$U" v2fly/v2fly-core:latest; then exit 1; fi
if node_python create bad other.example.com caddy direct 2336 /new "$U" v2fly/v2fly-core:latest; then exit 1; fi
if node_python create ../bad other.example.com nginx direct 2336 /new "$U" v2fly/v2fly-core:latest; then exit 1; fi
if node_python create bad other.example.com nginx direct 2336 '/new"' "$U" v2fly/v2fly-core:latest; then exit 1; fi
echo 'PASS conflicts-and-untrusted-input'
LINK=$(python3 - "$U" <<'PY'
import sys,json,base64
print('vmess://'+base64.b64encode(json.dumps(dict(add='jp.example.com',port=443,id=sys.argv[1],net='ws',tls='tls',path='/remote',host='host.example.com',sni='sni.example.com')).encode()).decode())
PY
)
node_python create imported kr.example.com nginx relay 2336 /imported "$U" v2fly/v2fly-core:latest link "$LINK"
node_python create imported kr.example.com nginx relay 2336 /imported "$U" v2fly/v2fly-core:latest preserve
python3 - "$STACK_DIR" <<'PY'
import json,sys,pathlib
r=json.loads((pathlib.Path(sys.argv[1])/'nodes/imported/metadata.json').read_text())['remote'];assert r['host']=='host.example.com' and r['sni']=='sni.example.com'
PY
if node_python create bad kr.example.com nginx relay 2337 /bad "$U" v2fly/v2fly-core:latest link vmess://bad; then exit 1; fi
echo 'PASS import-and-preserve-host-sni'
NODE_ID=jp
node_hint > "$ROOT/nginx"
[[ $(cat "$ROOT/nginx") == *'127.0.0.1:2335'* ]] || exit 1
[[ $(cat "$ROOT/nginx") == *'location = /jp'* ]] || exit 1
node_python link jp > "$ROOT/link"
python3 - "$ROOT/link" <<'PY'
import json,base64,sys
v=json.loads(base64.b64decode(open(sys.argv[1]).read().strip()[8:]));assert v['add']=='kr.example.com' and v['path']=='/jp'
PY
echo 'PASS nginx-and-client-link'
node_python ingress
[[ ! -f $STACK_DIR/ingress.yaml ]] || exit 1
# 全新 Caddy 入口。
STACK_DIR="$ROOT/caddy"; ENV_FILE="$STACK_DIR/.env"; COMPOSE_FILE="$STACK_DIR/compose.yaml"
node_python create kr kr.example.com caddy direct 2334 /kr "$U" v2fly/v2fly-core:latest
node_python create jp kr.example.com caddy relay 2335 /jp "$U" v2fly/v2fly-core:latest manual jp.example.com 443 "$U" /remote
node_python ingress
[[ $(cat "$STACK_DIR/ingress/Caddyfile") == *'reverse_proxy v2ray-node-jp:2333'* ]] || exit 1
[[ $(cat "$STACK_DIR/ingress.yaml") == *'./ingress:/managed:ro,Z'* ]] || exit 1
# 标准旧入口只保留读取，不改原配置。
printf 'DOMAIN=old.example.com\nUUID=%s\nWS_PATH=/old\nFRONT=caddy\n' "$U" > "$ENV_FILE"
printf 'original compose\n' > "$COMPOSE_FILE"
node_python ingress
[[ $(cat "$STACK_DIR/ingress/Caddyfile") == *'reverse_proxy v2ray:2333'* ]] || exit 1
[[ $(cat "$COMPOSE_FILE") == 'original compose' ]] || exit 1
echo 'PASS persistent-caddy-and-standard-legacy-ingress'
# 效果模拟：只能重建选中节点并连接共享网络，Caddy 改动仅 reload。
LOG="$ROOT/docker.log"
docker(){
  printf '%s\n' "$*" >> "$LOG"
  case "$*" in
    *com.docker.compose.project*) echo v2ray ;;
    *Config.Cmd*) echo '/managed/Caddyfile' ;;
    *NetworkSettings.Networks*) echo '{}' ;;
  esac
}
NODE_ID=jp
node_ingress_apply
[[ $(cat "$LOG") == *'network connect v2ray_default v2ray-node-jp'* ]] || exit 1
[[ $(cat "$LOG") != *'caddy reload --config /managed/Caddyfile'* ]] || exit 1
node_ingress_apply yes
[[ $(cat "$LOG") == *'caddy reload --config /managed/Caddyfile'* ]] || exit 1
[[ $(cat "$LOG") != *'force-recreate'* ]] || exit 1
echo 'PASS shared-caddy-reload-no-other-node-restart'
# 回滚使用不可变旧镜像 ID；只选中的节点执行 up。
backup=$(mktemp -d "$STACK_DIR/.test-backup.XXXXXX")
cp -p "$STACK_DIR/nodes/jp/"* "$backup/"
node_python create jp kr.example.com caddy direct 2335 /changed "$U" v2fly/v2fly-core:new
node_compose(){ printf 'node=%s %s\n' "$NODE_ID" "$*" >> "$LOG"; [[ $1 != config ]]; }
node_ingress_apply(){ :; }
OLD=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
if node_apply "$backup" "$OLD" yes; then exit 1; fi
[[ $(node_get image) == "$OLD" ]] || exit 1
[[ $(node_get outbound) == relay ]] || exit 1
[[ $(cat "$STACK_DIR/nodes/jp/compose.yaml") == *"$OLD"* ]] || exit 1
[[ $(cat "$LOG") == *'node=jp up -d --no-deps --force-recreate --pull never v2ray'* ]] || exit 1
echo 'PASS rollback-original-image-and-target-scope'
if node_legacy_guard install; then exit 1; fi
echo 'PASS guarded-legacy-overwrite'
# 交互默认值：修改中转节点回车必须保留出口/远端/镜像；不执行真实 effects。
(
  STACK_DIR="$ROOT/interactive"; ENV_FILE="$STACK_DIR/.env"; COMPOSE_FILE="$STACK_DIR/compose.yaml"
  NODE_ID=jp
  node_python create jp kr.example.com nginx relay 2335 /jp "$U" v2fly/v2fly-core:5.41.0 manual jp.example.com 443 "$U" /remote
  preflight(){ :; }; need_docker(){ :; }; ss(){ :; }; port_in_use(){ return 1; }
  docker(){ if [[ $* == *'{{.Image}}'* ]]; then echo sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; elif [[ $1 == inspect ]]; then return 1; fi; }
  ask(){ printf '%s' "$2"; }
  confirm(){ [[ $1 != *'高级设置'* ]]; }
  node_apply(){ echo "$NODE_ID" >> "$ROOT/applied"; }
  node_show(){ :; }
  cmd_node_add yes
  [[ $(node_get outbound) == relay ]] || exit 1
  [[ $(node_get image) == sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]] || exit 1
  [[ $(node_get path) == /jp ]] || exit 1
  [[ $(cat "$ROOT/applied") == jp ]] || exit 1
  echo 'PASS edit-interactive-defaults-preserve-relay'
)
# 最后独立 Caddy 节点删除：只关闭自有入口，保留证书卷。
(
  eval "$ORIGINAL_INGRESS"
  STACK_DIR="$ROOT/last"; ENV_FILE="$STACK_DIR/.env"; COMPOSE_FILE="$STACK_DIR/compose.yaml"
  node_python create last last.example.com caddy direct 2334 /last "$U" v2fly/v2fly-core:latest
  node_python ingress
  rm "$STACK_DIR/nodes/last/metadata.json"
  docker(){ printf '%s\n' "$*" >> "$ROOT/last.log"; if [[ $* == *com.docker.compose.project* ]]; then echo v2ray-ingress; fi; }
  node_ingress_apply
  [[ ! -f $STACK_DIR/ingress.yaml ]] || exit 1
  [[ $(cat "$ROOT/last.log") == *'down'* ]] || exit 1
  [[ $(cat "$ROOT/last.log") != *'volume rm'* ]] || exit 1
  echo 'PASS last-caddy-removal-retains-certificates'
)
# 无标签同名容器不能当成不存在。
(
 docker(){ return 0; }
 if node_owner v2ray-node-test v2ray-node-test; then exit 1; fi
 echo 'PASS unlabeled-container-ownership'
)

TEST

# TERM 在删除节点的元数据移走后到达，EXIT 恢复原节点配置和原镜像。
signal_status=0
bash <<'SIGNAL' || signal_status=$?
set -euo pipefail
source "$SCRIPT"
STACK_DIR="$ROOT/signal"; ENV_FILE="$STACK_DIR/.env"; COMPOSE_FILE="$STACK_DIR/compose.yaml"
NODE_ID=test
U=11111111-2222-4333-8444-555555555555
node_python create test kr.example.com nginx direct 2334 /test "$U" v2fly/v2fly-core:latest
backup=$(mktemp -d "$STACK_DIR/.node-recovery.XXXXXX")
cp -p "$STACK_DIR/nodes/test/"* "$backup/"
docker(){ return 1; }
node_compose(){ echo "$*" >> "$ROOT/signal.log"; }
node_snapshot "$backup" sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa yes
mv "$STACK_DIR/nodes/test/metadata.json" "$backup/removed-metadata.json"
kill -TERM "$$"
SIGNAL
[[ $signal_status == 143 ]] || exit 1
[[ -f $ROOT/signal/nodes/test/metadata.json ]] || exit 1
[[ $(cat "$ROOT/signal.log") == *'up -d --no-deps --force-recreate --pull never v2ray'* ]] || exit 1
printf 'PASS signal-recovers-selected-node\n'
