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
node_python create 1 1.example.com nginx direct 2334 /1 "$U" v2fly/v2fly-core:latest
node_python create 2 1.example.com nginx relay 2335 /2 "$U" v2fly/v2fly-core:latest manual 2.example.com 443 "$U" /remote
python3 - "$STACK_DIR" <<'PY'
import json,pathlib,sys,os
r=pathlib.Path(sys.argv[1]);a=json.loads((r/'nodes/1/config.json').read_text());b=json.loads((r/'nodes/2/config.json').read_text())
assert a['outbounds']==[{'protocol':'freedom','settings':{}}]
assert len(b['outbounds'])==1 and b['outbounds'][0]['protocol']=='vmess'
assert b['outbounds'][0]['streamSettings']['tlsSettings']['allowInsecure'] is False
for p in (r/'nodes').glob('*/*'):assert p.stat().st_mode&0o777==0o600
assert '127.0.0.1:2334:2333' in (r/'nodes/1/compose.yaml').read_text()
PY
echo 'PASS independent-direct-relay-and-permissions'
if node_python create 4 1.example.com nginx direct 2334 /new "$U" v2fly/v2fly-core:latest; then exit 1; fi
if node_python create 4 1.example.com nginx direct 2336 /1 "$U" v2fly/v2fly-core:latest; then exit 1; fi
if node_python create 4 1.EXAMPLE.COM nginx direct 2336 /1 "$U" v2fly/v2fly-core:latest; then exit 1; fi
if node_python create 4 other.example.com caddy direct 2336 /new "$U" v2fly/v2fly-core:latest; then exit 1; fi
if node_python create ../4 other.example.com nginx direct 2336 /new "$U" v2fly/v2fly-core:latest; then exit 1; fi
if node_python create 4 other.example.com nginx direct 2336 '/new"' "$U" v2fly/v2fly-core:latest; then exit 1; fi
echo 'PASS conflicts-and-untrusted-input'
LINK=$(python3 - "$U" <<'PY'
import sys,json,base64
print('vmess://'+base64.b64encode(json.dumps(dict(add='2.example.com',port=443,id=sys.argv[1],net='ws',tls='tls',path='/remote',host='host.example.com',sni='sni.example.com')).encode()).decode())
PY
)
node_python create 3 1.example.com nginx relay 2336 /3 "$U" v2fly/v2fly-core:latest link "$LINK"
node_python create 3 1.example.com nginx relay 2336 /3 "$U" v2fly/v2fly-core:latest preserve
python3 - "$STACK_DIR" <<'PY'
import json,sys,pathlib
r=json.loads((pathlib.Path(sys.argv[1])/'nodes/3/metadata.json').read_text())['remote'];assert r['host']=='host.example.com' and r['sni']=='sni.example.com'
PY
if node_python create 4 1.example.com nginx relay 2337 /4 "$U" v2fly/v2fly-core:latest link vmess://4; then exit 1; fi
echo 'PASS import-and-preserve-host-sni'
NODE_ID=2
node_hint > "$ROOT/nginx"
[[ $(cat "$ROOT/nginx") == *'127.0.0.1:2335'* ]] || exit 1
[[ $(cat "$ROOT/nginx") == *'location = /2'* ]] || exit 1
node_python link 2 > "$ROOT/link"
python3 - "$ROOT/link" <<'PY'
import json,base64,sys
v=json.loads(base64.b64decode(open(sys.argv[1]).read().strip()[8:]));assert v['add']=='1.example.com' and v['path']=='/2'
PY
echo 'PASS nginx-and-client-link'
node_python ingress
[[ ! -f $STACK_DIR/ingress.yaml ]] || exit 1
# 全新 Caddy 入口。
STACK_DIR="$ROOT/caddy"; ENV_FILE="$STACK_DIR/.env"; COMPOSE_FILE="$STACK_DIR/compose.yaml"
node_python create 1 1.example.com caddy direct 2334 /1 "$U" v2fly/v2fly-core:latest
node_python create 2 1.example.com caddy relay 2335 /2 "$U" v2fly/v2fly-core:latest manual 2.example.com 443 "$U" /remote
node_python ingress
[[ $(cat "$STACK_DIR/ingress/Caddyfile") == *'reverse_proxy v2ray-node-2:2333'* ]] || exit 1
[[ $(cat "$STACK_DIR/ingress.yaml") == *'./ingress:/managed:ro,Z'* ]] || exit 1
printf 'DOMAIN=old.example.com\nWS_PATH=/old\nFRONT=caddy\n' > "$ENV_FILE"
printf 'original compose\n' > "$COMPOSE_FILE"
node_python ingress
[[ $(cat "$STACK_DIR/ingress/Caddyfile") != *'reverse_proxy v2ray:2333'* ]]
[[ $(cat "$COMPOSE_FILE") == 'original compose' ]]
echo 'PASS ignores-legacy-env-and-compose'
# 效果模拟：只能重建选中节点并连接共享网络，Caddy 改动仅 reload。
LOG="$ROOT/docker.log"
docker(){
  printf '%s\n' "$*" >> "$LOG"
  case "$*" in
    *com.docker.compose.project*) echo v2ray-ingress ;;
    *Config.Cmd*) echo '/managed/Caddyfile' ;;
    *NetworkSettings.Networks*) echo '{}' ;;
  esac
}
NODE_ID=2
node_ingress_apply
[[ $(cat "$LOG") == *'network connect v2ray-ingress_default v2ray-node-2'* ]] || exit 1
[[ $(cat "$LOG") != *'caddy reload --config /managed/Caddyfile'* ]] || exit 1
node_ingress_apply yes
[[ $(cat "$LOG") == *'caddy reload --config /managed/Caddyfile'* ]] || exit 1
[[ $(cat "$LOG") != *'force-recreate'* ]] || exit 1
echo 'PASS shared-caddy-reload-no-other-node-restart'
# 回滚使用不可变旧镜像 ID；只选中的节点执行 up。
backup=$(mktemp -d "$STACK_DIR/.1-backup.XXXXXX")
cp -p "$STACK_DIR/nodes/2/"* "$backup/"
node_python create 2 1.example.com caddy direct 2335 /changed "$U" v2fly/v2fly-core:new
node_compose(){ printf 'node=%s %s\n' "$NODE_ID" "$*" >> "$LOG"; [[ $1 != config ]]; }
node_ingress_apply(){ :; }
OLD=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
if node_apply "$backup" "$OLD" yes; then exit 1; fi
[[ $(node_get image) == "$OLD" ]] || exit 1
[[ $(node_get outbound) == relay ]] || exit 1
[[ $(cat "$STACK_DIR/nodes/2/compose.yaml") == *"$OLD"* ]] || exit 1
[[ $(cat "$LOG") == *'node=2 up -d --no-deps --force-recreate --pull never v2ray'* ]] || exit 1
echo 'PASS rollback-original-image-and-target-scope'
# 交互默认值：修改中转节点回车必须保留出口/远端/镜像；不执行真实 effects。
(
  STACK_DIR="$ROOT/interactive"; ENV_FILE="$STACK_DIR/.env"; COMPOSE_FILE="$STACK_DIR/compose.yaml"
  NODE_ID=2
  node_python create 2 1.example.com nginx relay 2335 /2 "$U" v2fly/v2fly-core:5.41.0 manual 2.example.com 443 "$U" /remote
  preflight(){ :; }; need_docker(){ :; }; ss(){ :; }; port_in_use(){ return 1; }; open_firewall(){ :; }
  docker(){ if [[ $* == *'{{.Image}}'* ]]; then echo sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; elif [[ $1 == inspect ]]; then return 1; fi; }
  node_ask(){ printf '%s' "$2"; }
  confirm(){ [[ $1 != *'高级设置'* ]]; }
  node_apply(){ echo "$NODE_ID" >> "$ROOT/applied"; }
  node_show(){ :; }
  cmd_node_add yes > "$ROOT/edit-defaults.log"
  [[ $(rg -c '^1\) 本机节点' "$ROOT/edit-defaults.log") == 1 ]]
  [[ $(node_get outbound) == relay ]] || exit 1
  [[ $(node_get image) == sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]] || exit 1
  [[ $(node_get path) == /2 ]] || exit 1
  [[ $(cat "$ROOT/applied") == 2 ]] || exit 1
  # 主动改成本机直出不保留远端元数据；类型整流程只询问一次。
  node_ask(){
    printf '%s\n' "$1" >> "$ROOT/edit-switch-prompts"
    if [[ $1 == 节点类型 ]]; then printf 1; else printf '%s' "$2"; fi
  }
  cmd_node_add yes > "$ROOT/edit-switch.log"
  [[ $(node_get outbound) == direct ]]
  if node_get remote >/dev/null 2>&1; then exit 1; fi
  [[ $(rg -c '^节点类型$' "$ROOT/edit-switch-prompts") == 1 ]]
  echo 'PASS edit-interactive-defaults-preserve-relay'
)
# 最后独立 Caddy 节点删除：只关闭自有入口，保留证书卷。
(
  eval "$ORIGINAL_INGRESS"
  STACK_DIR="$ROOT/1"; ENV_FILE="$STACK_DIR/.env"; COMPOSE_FILE="$STACK_DIR/compose.yaml"
  node_python create 1 1.example.com caddy direct 2334 /1 "$U" v2fly/v2fly-core:latest
  node_python ingress
  rm "$STACK_DIR/nodes/1/metadata.json"
  docker(){ printf '%s\n' "$*" >> "$ROOT/1.log"; if [[ $* == *com.docker.compose.project* ]]; then echo v2ray-ingress; fi; }
  node_ingress_apply
  [[ ! -f $STACK_DIR/ingress.yaml ]] || exit 1
  [[ $(cat "$ROOT/1.log") == *'down'* ]] || exit 1
  [[ $(cat "$ROOT/1.log") != *'volume rm'* ]] || exit 1
  echo 'PASS last-caddy-removal-retains-certificates'
)
# 无标签同名容器不能当成不存在。
(
 docker(){ return 0; }
 if node_owner v2ray-node-1 v2ray-node-1; then exit 1; fi
 echo 'PASS unlabeled-container-ownership'
)

# 名称验证、数字序号与已有目录保护；删除后仍递增。
(
 STACK_DIR="$ROOT/numeric"
 [[ $(node_python validate-label '  韩国直出  ') == 韩国直出 ]]
 if node_python validate-label '   '; then exit 1; fi
 [[ ! -e $STACK_DIR ]]
 [[ $(node_python allocate) == 1 ]]
 node_python create 1 one.example.com nginx direct 2334 /one "$U" v2fly/v2fly-core:latest
 NODE_ID=1; [[ $(node_get id) == 1 ]]
 rm -rf "$STACK_DIR/nodes/1"
 [[ $(node_python allocate) == 2 ]]
 mkdir "$STACK_DIR/nodes/8"
 [[ $(node_python allocate) == 9 ]]
 for i in 1 2 3 4; do node_python allocate > "$ROOT/allocation-$i" & done
 wait
 [[ $(cat "$ROOT"/allocation-* | sort -n | tr '\n' ' ') == '10 11 12 13 ' ]]
 [[ $(cat "$STACK_DIR/nodes/.id-sequence") == 13 ]]
 echo 'PASS numeric-highwater-existing-directory-and-concurrency'
)
# 使用真实 read 模拟输入，避免 ask 的子 shell 丢失队列状态。
(
 STACK_DIR="$ROOT/fresh-menu"; ENV_FILE="$STACK_DIR/.env"; COMPOSE_FILE="$STACK_DIR/compose.yaml"
 preflight(){ :; }; need_docker(){ :; }; ss(){ :; }; port_in_use(){ return 1; }; open_firewall(){ :; }
 docker(){ if [[ $1 == inspect ]]; then return 1; fi; }
 node_apply(){ :; }; node_show(){ :; }
 cmd_node_add > "$ROOT/fresh-menu.log" <<'INPUT'
9
1
韩国直出
99
1
4 domain
fresh.example.com
n
y
INPUT
 NODE_ID=1
 [[ $(node_get label) == 韩国直出 && $(node_get front) == caddy ]]
 [[ $(cat "$STACK_DIR/nodes/.id-sequence") == 1 ]]
 [[ $(cat "$ROOT/fresh-menu.log") == *'暂无已登记的入口'* ]]
 [[ $(cat "$ROOT/fresh-menu.log") != *'节点标识'* ]]
 # 最终取消不分配序号、不增加目录。
 cmd_node_add > "$ROOT/cancel-menu.log" <<'INPUT'
1
取消测试
1
n
n
INPUT
 [[ $(cat "$STACK_DIR/nodes/.id-sequence") == 1 && ! -e $STACK_DIR/nodes/2 ]]
 echo 'PASS fresh-create-invalid-retry-and-final-cancel'
)
(
 STACK_DIR="$ROOT/reuse-menu"; ENV_FILE="$STACK_DIR/.env"; COMPOSE_FILE="$STACK_DIR/compose.yaml"
 node_python create 1 a.example.com nginx direct 2334 /a "$U" v2fly/v2fly-core:latest
 node_python create 2 a.example.com nginx direct 2335 /b "$U" v2fly/v2fly-core:latest
 node_python create 3 b.example.com nginx direct 2336 /c "$U" v2fly/v2fly-core:latest
 edit=no; d=''; front=''; port_in_use(){ return 1; }
 node_ingress_select > "$ROOT/reuse-menu.log" <<'INPUT'
99
2
INPUT
 [[ $d == b.example.com && $front == nginx ]]
 [[ $(node_python entries | wc -l | tr -d ' ') == 2 ]]
 node_owner(){ :; }
 node_select > "$ROOT/select-menu.log" <<'INPUT'
99
2
INPUT
 [[ $NODE_ID == 2 ]]
 if node_select <<<'0'; then exit 1; fi
 echo 'PASS deduplicated-reuse-numbered-selection-and-cancel'
)
(
 STACK_DIR="$ROOT/busy-menu"; edit=no; d=''; front=''; port_in_use(){ return 0; }
 node_ingress_select > "$ROOT/busy-menu.log" <<'INPUT'

existing.example.com
INPUT
 [[ $front == nginx && $d == existing.example.com && ! -e $STACK_DIR ]]
 if node_ingress_select <<<'0'; then exit 1; fi
 if node_ingress_select </dev/null; then exit 1; fi
 node_select </dev/null && exit 1
 preflight(){ :; }; need_docker(){ :; }; ss(){ :; }; docker(){ :; }; open_firewall(){ :; }
 cmd_node_add </dev/null
 [[ ! -e $STACK_DIR ]]
 echo 'PASS fresh-busy-default-and-no-write-on-return'
)

# 新建第一问类型，编辑保留原类型；返回时不创建文件。
(
 STACK_DIR="$ROOT/type-first"; ENV_FILE="$STACK_DIR/.env"; COMPOSE_FILE="$STACK_DIR/compose.yaml"
 preflight(){ :; }; need_docker(){ :; }; ss(){ :; }; port_in_use(){ return 1; }; open_firewall(){ :; }
 docker(){ if [[ $1 == inspect ]]; then return 1; fi; }
 node_apply(){ :; }; node_show(){ :; }
 node_ask(){ printf '%s\n' "$1" >> "$ROOT/type-prompts"; ask "$@"; }
 cmd_node_add <<<'0' > "$ROOT/type-cancel.log"
 [[ $(cat "$ROOT/type-prompts") == 节点类型 && ! -e $STACK_DIR ]]
 : > "$ROOT/type-prompts"
 cmd_node_add > "$ROOT/type-relay.log" <<INPUT
2
中转测试
2
relay.example.com
n
2
2.example.com
443
$U
/remote


y
INPUT
 NODE_ID=1
 [[ $(node_get outbound) == relay ]]
 [[ $(head -n 2 "$ROOT/type-prompts" | tr '\n' '|') == '节点类型|节点名称，例如 韩国直出 / 韩国转日本（0 返回）|' ]]
 [[ $(cat "$ROOT/type-relay.log") == *'2) 中转节点（通过远端节点出网）'* ]]
 echo 'PASS type-first-relay-and-zero-without-mutation'
)
# 主菜单删除直接选择、确认；拒绝不改变文件，只操作目标容器。
(
 STACK_DIR="$ROOT/delete-flow"; ENV_FILE="$STACK_DIR/.env"; COMPOSE_FILE="$STACK_DIR/compose.yaml"
 node_python create 1 one.example.com nginx direct 2334 /one "$U" v2fly/v2fly-core:latest
 node_python create 2 two.example.com nginx direct 2335 /two "$U" v2fly/v2fly-core:latest
 cp "$STACK_DIR/nodes/1/metadata.json" "$ROOT/before-delete"
 need_docker(){ :; }; node_owner(){ :; }
 docker(){ printf '%s\n' "$*" >> "$ROOT/delete-effects"; if [[ $* == *'{{.Image}}'* ]]; then echo sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; fi; }
 node_compose(){ printf 'node=%s %s\n' "$NODE_ID" "$*" >> "$ROOT/delete-effects"; }
 node_ingress_apply(){ printf 'ingress\n' >> "$ROOT/delete-effects"; }
 node_ask(){ printf '%s\n' "$1" >> "$ROOT/delete-prompts"; ask "$@"; }
 node_menu > "$ROOT/delete-refuse.log" <<'INPUT'
5
1
n
INPUT
 cmp "$STACK_DIR/nodes/1/metadata.json" "$ROOT/before-delete"
 [[ ! -e $ROOT/delete-effects ]]
 [[ $(cat "$ROOT/delete-prompts" | tr '\n' '|') == '请选择|选择节点|' ]]
 [[ $(cat "$ROOT/delete-refuse.log") != *'1) 链接/二维码'* ]]
 node_menu > "$ROOT/delete-accept.log" <<'INPUT'
5
1
y
INPUT
 [[ ! -e $STACK_DIR/nodes/1 && -f $STACK_DIR/nodes/2/metadata.json ]]
 [[ $(cat "$ROOT/delete-effects") == *'node=1 down'* ]]
 [[ $(cat "$ROOT/delete-effects") != *'node=2'* && $(cat "$ROOT/delete-effects") != *'volume'* && $(cat "$ROOT/delete-effects") != *'apt'* ]]
 [[ $(cat "$ROOT/delete-accept.log") == *'保留其他节点、Docker、系统依赖和证书卷'* ]]
 # 管理菜单 6 使用同一删除逻辑。
 cmd_node_manage > "$ROOT/delete-manage.log" <<'INPUT'
1
6
y
INPUT
 [[ ! -e $STACK_DIR/nodes/2 && $(cat "$ROOT/delete-effects") == *'node=2 down'* ]]
 echo 'PASS direct-delete-confirm-refusal-and-target-scope'
)

# 未登记目录忽略，已分配编号仍能展示和生成入口。
(
 STACK_DIR="$ROOT/managed-only"
 mkdir -p "$STACK_DIR/nodes/manual"
 printf '{}' > "$STACK_DIR/nodes/manual/metadata.json"
 [[ $(node_python allocate) == 1 ]]
 node_python create 1 one.example.com caddy direct 2333 /one "$U" v2fly/v2fly-core:latest
 [[ $(node_python ids) == 1 ]]
 node_python entries >/dev/null
 node_python ingress
 if node_python create old one.example.com caddy direct 2334 /old "$U" v2fly/v2fly-core:latest; then exit 1; fi
 echo 'PASS managed-numeric-only-with-sequence-and-unmanaged-directory'
)
# 最后入口删除也检查归属，不能关闭无标签或其他项目的同名容器。
(
 eval "$ORIGINAL_INGRESS"
 STACK_DIR="$ROOT/foreign-ingress"
 node_python create 1 one.example.com caddy direct 2333 /one "$U" v2fly/v2fly-core:latest
 node_python ingress
 rm "$STACK_DIR/nodes/1/metadata.json"
 docker(){ printf '%s\n' "$*" >> "$ROOT/foreign-ingress.log"; }
 if node_ingress_apply; then exit 1; fi
 [[ -f $STACK_DIR/ingress.yaml && $(cat "$ROOT/foreign-ingress.log") != *' down'* ]]
 echo 'PASS foreign-ingress-protected-on-last-delete'
)
# 删除后恢复停止的共享入口时，用删除前不可变镜像；不替换其他节点。
(
 eval "$ORIGINAL_INGRESS"
 STACK_DIR="$ROOT/shared-recovery"; NODE_ID=1
 node_python create 1 one.example.com caddy direct 2333 /one "$U" v2fly/v2fly-core:latest
 node_python ingress
 backup=$(mktemp -d "$STACK_DIR/.test-backup.XXXXXX")
 cp -p "$STACK_DIR/nodes/1/"* "$backup/"
 IMMUTABLE=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
 docker(){
  printf '%s\n' "$*" >> "$ROOT/shared-recovery.log"
  case "$*" in
   *'{{.Image}}'*) echo "$IMMUTABLE" ;;
   *com.docker.compose.project*) echo v2ray-ingress ;;
   *NetworkSettings.Networks*) echo '{"v2ray-ingress_default":{}}' ;;
   'ps -q'*) return 0 ;;
  esac
 }
 node_snapshot "$backup" "$IMMUTABLE" yes
 mv "$STACK_DIR/nodes/1/metadata.json" "$backup/removed-metadata.json"
 rm "$STACK_DIR/ingress.yaml" "$STACK_DIR/ingress/Caddyfile"
 node_compose(){ printf 'node=%s %s\n' "$NODE_ID" "$*" >> "$ROOT/shared-recovery.log"; }
 node_recover "$backup" "$IMMUTABLE" yes
 [[ $(node_get image) == "$IMMUTABLE" ]]
 [[ $(cat "$STACK_DIR/ingress.yaml") == *"$IMMUTABLE"* ]]
 [[ $(cat "$ROOT/shared-recovery.log") == *'up -d caddy'* ]]
 echo 'PASS shared-ingress-recovery-original-image'
)

TEST

# TERM 在删除节点的元数据移走后到达，EXIT 恢复原节点配置和原镜像。
signal_status=0
bash <<'SIGNAL' || signal_status=$?
set -euo pipefail
source "$SCRIPT"
STACK_DIR="$ROOT/signal"; ENV_FILE="$STACK_DIR/.env"; COMPOSE_FILE="$STACK_DIR/compose.yaml"
NODE_ID=1
U=11111111-2222-4333-8444-555555555555
node_python create 1 1.example.com nginx direct 2334 /1 "$U" v2fly/v2fly-core:latest
backup=$(mktemp -d "$STACK_DIR/.node-recovery.XXXXXX")
cp -p "$STACK_DIR/nodes/1/"* "$backup/"
docker(){ return 1; }
node_compose(){ echo "$*" >> "$ROOT/signal.log"; }
node_snapshot "$backup" sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa yes
mv "$STACK_DIR/nodes/1/metadata.json" "$backup/removed-metadata.json"
kill -TERM "$$"
SIGNAL
[[ $signal_status == 143 ]] || exit 1
[[ -f $ROOT/signal/nodes/1/metadata.json ]] || exit 1
[[ $(cat "$ROOT/signal.log") == *'up -d --no-deps --force-recreate --pull never v2ray'* ]] || exit 1
printf 'PASS signal-recovers-selected-node\n'
