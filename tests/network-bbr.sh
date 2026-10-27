#!/usr/bin/env bash
# 严格模拟 tc / Docker / sysctl，仅修改临时目录，不操作真实系统。
set -euo pipefail
cd "$(dirname "$0")/.."
source ./v2fly-auto-setup.sh
STACK_DIR=$(mktemp -d)
trap 'builtin command rm -rf "$STACK_DIR"' EXIT
check() { "$@" || { echo "FAIL: $*" >&2; exit 1; }; }
export MOCK_DIR=$STACK_DIR
cat > "$STACK_DIR/tc-mock.py" <<'PYMOCK'
import copy, json, os, pathlib, re, sys
root = pathlib.Path(os.environ['MOCK_DIR'])
args = sys.argv[1:]
state = json.loads((root / 'queue.json').read_text())
if args == ['-j', 'qdisc', 'show', 'dev', 'ens5']:
    print(json.dumps(state)); sys.exit(0)
if args == ['qdisc', 'show', 'dev', 'ens5']:
    for q in state:
        place = 'root' if q.get('root') else 'parent ' + q['parent']
        print('qdisc', q['kind'], q['handle'], place)
    sys.exit(0)
if args == ['filter', 'show', 'dev', 'ens5']:
    sys.exit(0)
if args[:4] != ['qdisc', 'replace', 'dev', 'ens5']:
    raise SystemExit('unexpected tc command')
with (root / 'tc.log').open('a') as log:
    log.write(' '.join(args) + '\n')
words = args[4:]
if words[0] == 'root':
    parent = None; words = words[1:]
elif words[0] == 'parent':
    parent = words[1]; words = words[2:]
    if parent.startswith(':'):
        raise SystemExit('Failed to find specified qdisc')
else:
    raise SystemExit('invalid attachment')
handle = '0:'
if words[0] == 'handle':
    handle = words[1]; words = words[2:]
kind = words[0]; words = words[1:]
if os.environ.get('FAIL_TC') == 'root' and parent is None:
    sys.exit(1)
if os.environ.get('FAIL_TC') == 'second' and parent == '1:2' and kind == 'fq':
    sys.exit(1)
if kind == 'mq':
    if parent is not None or handle != '1:' or words:
        raise SystemExit('invalid mq')
    for q in state:
        if q.get('root'):
            q['handle'] = '1:'
        else:
            q['parent'] = '1:' + q['parent'].split(':')[1]
            q['kind'] = 'fq_codel'
            q['options'] = {'limit': 10240, 'flows': 1024, 'quantum': 1514, 'target': 5000, 'interval': 100000, 'memory_limit': 33554432, 'ecn': True, 'drop_batch': 64}
else:
    if kind not in ('fq', 'fq_codel'):
        raise SystemExit('invalid qdisc')
    options = {}
    if kind == 'fq' and os.environ.get('EMIT_FQ_BANDS'):
        options.update({'bands':3, 'priomap ':[1,2,2,2,1,2,0,0,1,1,1,1,1,1,1,1], 'weights ':[589824,196608,65536]})
    plain = {'limit', 'flow_limit', 'quantum', 'initial_quantum', 'buckets', 'orphan_mask', 'flows', 'drop_batch', 'memory_limit'}
    times = {'target', 'interval', 'refill_delay', 'horizon', 'offload_horizon', 'ce_threshold'}
    while words:
        key, words = words[0], words[1:]
        if key in ('ecn', 'noecn'):
            if key == 'ecn': options['ecn'] = True
            elif os.environ.get('CORRUPT_ECN'): options['ecn'] = True
            continue
        if key in ('pacing', 'nopacing'):
            if key == 'nopacing': options['pacing'] = False
            continue
        if key in ('horizon_drop', 'horizon_cap'):
            options[key] = None; continue
        if key == 'bands':
            if words[:2] != ['3', 'priomap'] or len(words) < 18 or any(v not in ('0', '1', '2') for v in words[2:18]):
                raise SystemExit('invalid bands')
            options.update({'bands':3, 'priomap ':list(map(int, words[2:18]))}); words = words[18:]; continue
        if key == 'weights':
            # 模拟上游旧解析器：循环前 NEXT_ARG 额外跳过首个 token。
            if os.environ.get('LEGACY_WEIGHTS'):
                words = words[1:]
            if len(words) < 3 or any(not v.isdigit() or int(v) <= 0 for v in words[:3]):
                raise SystemExit('invalid weights')
            options['weights '] = list(map(int, words[:3])); words = words[3:]; continue
        if not words:
            raise SystemExit('missing parameter')
        value, words = words[0], words[1:]
        # 与 iproute2 一样，包数/quantum 仅接受整数，不能把显示用 p/b 后缀回放。
        if key in plain:
            if not re.fullmatch(r'[0-9]+', value): raise SystemExit('integer parameter required')
            options[key] = int(value)
        elif key in times or key == 'timer_slack':
            unit = 'ns' if key == 'timer_slack' else 'us'
            if not re.fullmatch(r'[0-9]+' + unit, value): raise SystemExit('precise time required')
            options[key] = int(value[:-2])
        elif key in ('maxrate', 'low_rate_threshold'):
            if not re.fullmatch(r'[0-9]+bit', value) or int(value[:-3]) % 8: raise SystemExit('exact bit rate required')
            number = int(value[:-3]) // 8
            if number or key == 'maxrate': options[key] = number
        else:
            raise SystemExit('unknown option ' + key)
    q = {'kind': kind, 'handle': handle, 'options': options}
    q.update(root=True) if parent is None else q.update(parent=parent)
    if parent is None:
        state = [q]
    else:
        state = [q if old.get('parent') == parent else old for old in state]
(root / 'queue.json').write_text(json.dumps(state))
PYMOCK
reset_queue() {
  python3 - "$STACK_DIR/queue.json" <<'PY'
import json, pathlib, sys
# 第二叶子未打印 ecn，实际为关闭；memory_limit 刻意使用会被文本舍入的整数。
base = {'limit':10240,'flows':1024,'quantum':1514,'target':5001,'interval':100003,'memory_limit':33554439,'drop_batch':64}
first = dict(base, ecn=True)
pathlib.Path(sys.argv[1]).write_text(json.dumps([{'kind':'mq','handle':'0:','root':True,'options':{}}, {'kind':'fq_codel','handle':'0:','parent':':1','options':first}, {'kind':'fq_codel','handle':'0:','parent':':2','options':base}]))
PY
}
tc() { python3 "$STACK_DIR/tc-mock.py" "$@"; }
ip() { printf 'default via 192.0.2.1 dev ens5\n'; }
sysctl() {
  case "$*" in
    '-n net.ipv4.tcp_available_congestion_control') echo 'reno cubic bbr' ;;
    '-n net.ipv4.tcp_congestion_control') cat "$STACK_DIR/host-algo" ;;
    '-n net.core.default_qdisc') cat "$STACK_DIR/host-default" ;;
    '-w '*)
      printf '%s\n' "$*" >> "$STACK_DIR/host.log"
      case "$2" in
        net.ipv4.tcp_congestion_control=*) printf '%s\n' "${2#*=}" > "$STACK_DIR/host-algo" ;;
        net.core.default_qdisc=*) printf '%s\n' "${2#*=}" > "$STACK_DIR/host-default" ;;
        *) return 1 ;;
      esac ;;
    *) return 1 ;;
  esac
}
modprobe() { [[ ${FAIL_MODULE:-no} != yes ]]; }
rm() {
  local arg
  for arg in "$@"; do case "$arg" in /etc/*) return 0 ;; esac; done
  builtin command rm "$@"
}
network_write_real=$(declare -f network_write_persistence)
network_write_persistence() { printf 'persistence\n' >> "$STACK_DIR/host.log"; }
node_owner() { :; }
node_local_ok() { :; }
wait_for() { "$1"; }
ingress_ready() { :; }
compose_mock() {
  local service=$1 name=$2 override='' previous='' arg algorithm
  shift 2
  printf '%s %s\n' "$name" "$*" >> "$STACK_DIR/container.log"
  for arg in "$@"; do [[ $previous != -f ]] || override=$arg; previous=$arg; done
  [[ " $* " == *' up '* ]] || return 0
  [[ ${FAIL_NODE:-} != "$name" ]] || return 1
  algorithm=$(awk '/net.ipv4.tcp_congestion_control:/ {print $2}' "$override")
  [[ -n $algorithm ]] || algorithm=bbr
  [[ ${CORRUPT_CONTAINER:-} != "$name" ]] || algorithm=cubic
  printf '%s\n' "$algorithm" > "$STACK_DIR/$name.algo"
}
node_compose() { compose_mock v2fly "v2fly-node-$NODE_ID" "$@"; }
ingress_compose() { compose_mock caddy v2fly-ingress "$@"; }
docker() {
  case "$*" in
    'inspect -f {{.Image}} '*) printf 'sha256:%064d\n' 1 ;;
    'inspect -f {{.State.Running}} '*) echo true ;;
    'exec '*'/proc/sys/net/ipv4/tcp_congestion_control') cat "$STACK_DIR/$2.algo" ;;
    'network connect '*) : ;;
    *) return 1 ;;
  esac
}
reset_host() { echo cubic > "$STACK_DIR/host-algo"; echo fq_codel > "$STACK_DIR/host-default"; }
reset_host
reset_queue
check network_inspect
NETWORK_TX_BACKUP=$STACK_DIR/recovery
mkdir -p "$NETWORK_TX_BACKUP"
printf '%s\n' "$NETWORK_QDISC_PLAN" > "$NETWORK_TX_BACKUP/qdisc-plan.json"
cp "$STACK_DIR/queue.json" "$STACK_DIR/original.json"
check network_set_fq
check network_restore_qdisc
python3 - "$STACK_DIR/original.json" "$STACK_DIR/queue.json" <<'PY'
import json, sys
old, new = [json.load(open(p)) for p in sys.argv[1:]]
assert new[0]['kind'] == 'mq' and new[0]['handle'] == '1:'
for before, after in zip(old[1:], new[1:]):
    assert before['options'] == after['options'], (before, after)
PY
# 宽松 mock 会接受的非法回放现在必须拒绝。
if tc qdisc replace dev ens5 parent 1:1 fq_codel limit 10240p >/dev/null 2>&1; then exit 1; fi
if tc qdisc replace dev ens5 parent 1:1 fq quantum 18030b >/dev/null 2>&1; then exit 1; fi
# 验证“tc 返回成功但实际 ECN 不匹配”也会被恢复后核验检出。
check network_inspect
check network_set_fq
export CORRUPT_ECN=yes
if network_restore_qdisc >/dev/null; then echo 'expected ECN mismatch failure' >&2; exit 1; fi
unset CORRUPT_ECN
check network_restore_qdisc
# 根替换命令失败但状态不变：不重放匿名 :N，也不假报恢复失败。
reset_queue
check network_inspect
export FAIL_TC=root
if network_set_fq; then exit 1; fi
unset FAIL_TC
check network_restore_qdisc
check cmp "$STACK_DIR/original.json" "$STACK_DIR/queue.json"
# 第一叶子已修改、第二叶子失败：恢复所有原参数，并恢复隐含的 noecn。
check network_inspect
check network_set_fq
check network_restore_qdisc
check network_inspect
export FAIL_TC=second
if network_set_fq; then exit 1; fi
unset FAIL_TC
check network_restore_qdisc
# fq JSON 的精度、默认 pacing、nopacing、band 参数以及合法整数恢复。
cat > "$STACK_DIR/fq.json" <<'JSON'
[{"kind":"mq","handle":"1:","root":true,"options":{}},{"kind":"fq","handle":"8001:","parent":"1:1","options":{"limit":10000,"flow_limit":100,"buckets":1024,"orphan_mask":1023,"bands":3,"priomap ":[1,2,2,2,1,2,0,0,1,1,1,1,1,1,1,1],"weights ":[589824,196608,65536],"quantum":18031,"initial_quantum":90151,"low_rate_threshold":68751,"refill_delay":40001,"timer_slack":10003,"horizon":10000001,"horizon_drop":null}},{"kind":"fq","handle":"8002:","parent":"1:2","options":{"limit":9000,"flow_limit":90,"quantum":18033,"initial_quantum":90153,"pacing":false}}]
JSON
# 上游真实 JSON 尾空格键可前检；同一数组同时出现两个别名必须拒绝。
python3 - "$STACK_DIR/fq.json" "$STACK_DIR/alias-conflict.json" <<'PY'
import json, sys
q = json.load(open(sys.argv[1]))
q[1]['options']['priomap'] = q[1]['options']['priomap ']
json.dump(q, open(sys.argv[2], 'w'))
PY
if network_qdisc_plan "$(cat "$STACK_DIR/alias-conflict.json")" >/dev/null 2>&1; then exit 1; fi
python3 - "$STACK_DIR/fq.json" "$STACK_DIR/alias-conflict.json" <<'PY'
import json, sys
q = json.load(open(sys.argv[1]))
q[1]['options']['weights'] = q[1]['options']['weights ']
json.dump(q, open(sys.argv[2], 'w'))
PY
if network_qdisc_plan "$(cat "$STACK_DIR/alias-conflict.json")" >/dev/null 2>&1; then exit 1; fi
if network_qdisc_plan '[{"kind":"fq","handle":"0:","root":true,"options":{"limit ":1000}}]' >/dev/null 2>&1; then exit 1; fi
cp "$STACK_DIR/fq.json" "$STACK_DIR/queue.json"
check network_inspect
printf '%s\n' "$NETWORK_QDISC_PLAN" > "$NETWORK_TX_BACKUP/qdisc-plan.json"
# 主动改为 fq_codel，随后由生产恢复函数重建 fq。
check tc qdisc replace dev ens5 parent 1:1 fq_codel limit 100
check tc qdisc replace dev ens5 parent 1:2 fq_codel limit 100
check network_restore_qdisc
python3 - "$STACK_DIR/fq.json" "$STACK_DIR/queue.json" <<'PY'
import json, sys
before, after = [json.load(open(p)) for p in sys.argv[1:]]
assert before == after, (before, after)
PY
# 新解析器标准恢复成功后，不得额外尝试旧解析器占位形式。
check test "$(grep -c 'weights 0 589824' "$STACK_DIR/tc.log" || true)" -eq 0
# 旧解析器按上游缺陷额外跳一项：标准三值拒绝，兼容四值成功并精确恢复。
check tc qdisc replace dev ens5 parent 1:1 fq_codel limit 100
export LEGACY_WEIGHTS=yes
if tc qdisc replace dev ens5 parent 1:1 fq weights 589824 196608 65536 >/dev/null 2>&1; then exit 1; fi
check network_restore_qdisc
unset LEGACY_WEIGHTS
check grep -q 'weights 0 589824 196608 65536$' "$STACK_DIR/tc.log"
python3 - "$STACK_DIR/fq.json" "$STACK_DIR/queue.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1])) == json.load(open(sys.argv[2]))
PY
# 新解析器拒绝兼容命令中的零权重，且不改变实际队列。
cp "$STACK_DIR/queue.json" "$STACK_DIR/before-invalid-weights.json"
if tc qdisc replace dev ens5 parent 1:1 fq weights 0 589824 196608 65536 >/dev/null 2>&1; then exit 1; fi
check cmp "$STACK_DIR/before-invalid-weights.json" "$STACK_DIR/queue.json"
# 单根 fq_codel 恢复隐含 noecn，同样检查最终状态。
printf '[{"kind":"fq_codel","handle":"0:","root":true,"options":{"limit":10240,"quantum":1514}}]' > "$STACK_DIR/queue.json"
check network_inspect
printf '%s\n' "$NETWORK_QDISC_PLAN" > "$NETWORK_TX_BACKUP/qdisc-plan.json"
cp "$STACK_DIR/queue.json" "$STACK_DIR/single-original.json"
check network_set_fq
check network_restore_qdisc
python3 - "$STACK_DIR/single-original.json" "$STACK_DIR/queue.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1])) == json.load(open(sys.argv[2]))
PY
if network_qdisc_plan '[{"kind":"fq","handle":"0:","root":true,"options":{"unknown":1}}]' >/dev/null 2>&1; then exit 1; fi
# 配置生成、容器实际算法快照与事务失败恢复。
uuid=11111111-2222-4333-8444-555555555555
node_python create 1 example.com caddy direct 2333 /one "$uuid" v2fly/v2fly-core:latest
node_python create 2 example.com caddy direct 2334 /two "$uuid" v2fly/v2fly-core:latest
node_python ingress
echo reno > "$STACK_DIR/v2fly-node-1.algo"
echo bbr > "$STACK_DIR/v2fly-node-2.algo"
echo reno > "$STACK_DIR/v2fly-ingress.algo"
reset_queue
reset_host
check network_inspect
NETWORK_TX_BACKUP=$STACK_DIR/transaction
mkdir -p "$NETWORK_TX_BACKUP"
printf '%s\n' "$NETWORK_QDISC_PLAN" > "$NETWORK_TX_BACKUP/qdisc-plan.json"
echo ens5 > "$NETWORK_TX_BACKUP/iface"
echo cubic > "$NETWORK_TX_BACKUP/congestion"
echo fq_codel > "$NETWORK_TX_BACKUP/default-qdisc"
check network_snapshot_containers "$NETWORK_TX_BACKUP"
check grep -qx reno "$NETWORK_TX_BACKUP/nodes/1/congestion"
check grep -qx bbr "$NETWORK_TX_BACKUP/nodes/2/congestion"
check grep -qx reno "$NETWORK_TX_BACKUP/ingress.congestion"
NETWORK_TX_ACTIVE=yes
export EMIT_FQ_BANDS=yes
check network_apply
unset EMIT_FQ_BANDS
check grep -q '"priomap "' "$STACK_DIR/queue.json"
check grep -q '"weights "' "$STACK_DIR/queue.json"
for name in v2fly-node-1 v2fly-node-2 v2fly-ingress; do check grep -qx bbr "$STACK_DIR/$name.algo"; done
# 新节点继承 BBR。
node_python create 3 example.com caddy direct 2335 /three "$uuid" v2fly/v2fly-core:latest
check grep -q 'net.ipv4.tcp_congestion_control: bbr' "$STACK_DIR/nodes/3/compose.yaml"
check network_recover
check grep -qx reno "$STACK_DIR/v2fly-node-1.algo"
check grep -qx bbr "$STACK_DIR/v2fly-node-2.algo"
check grep -qx reno "$STACK_DIR/v2fly-ingress.algo"
check grep -qx cubic "$STACK_DIR/host-algo"
check grep -qx fq_codel "$STACK_DIR/host-default"
check cmp "$NETWORK_TX_BACKUP/nodes/1/compose.yaml" "$STACK_DIR/nodes/1/compose.yaml"
# 恢复命令返回成功但容器实际算法错误，仍报告恢复失败。
export CORRUPT_CONTAINER=v2fly-node-1
if network_recover >/dev/null; then echo 'expected container mismatch failure' >&2; exit 1; fi
unset CORRUPT_CONTAINER
check network_recover
# 第二个容器重建失败，已修改的第一个容器必须按实际原算法恢复。
reset_queue
check network_inspect
export FAIL_NODE=v2fly-node-2
if network_apply; then echo 'expected second container failure' >&2; exit 1; fi
unset FAIL_NODE
check network_recover
check grep -qx reno "$STACK_DIR/v2fly-node-1.algo"
check grep -qx bbr "$STACK_DIR/v2fly-node-2.algo"
check grep -qx reno "$STACK_DIR/v2fly-ingress.algo"
# 模块加载失败发生在队列变更之前，不调用 tc 恢复。
NETWORK_TX_BACKUP=$STACK_DIR/module-failure
mkdir -p "$NETWORK_TX_BACKUP"
echo cubic > "$NETWORK_TX_BACKUP/congestion"
echo fq_codel > "$NETWORK_TX_BACKUP/default-qdisc"
echo ens5 > "$NETWORK_TX_BACKUP/iface"
reset_queue
export FAIL_MODULE=yes
if network_apply; then exit 1; fi
unset FAIL_MODULE
check test ! -e "$NETWORK_TX_BACKUP/queue-started"
check network_recover
# 受管文件生成、冲突与状态仍只读模拟。
eval "$network_write_real"
check network_write_persistence "$STACK_DIR/modules.conf" "$STACK_DIR/sysctl.conf"
check grep -q 'net.core.default_qdisc = fq' "$STACK_DIR/sysctl.conf"
# sysctl.d 按 basename 排序、同名目录优先级以及管理员保护。
SYSROOT=$STACK_DIR/sysctl-fixture
reset_sysctl_fixture() {
  builtin command rm -rf "$SYSROOT"
  mkdir -p "$SYSROOT/etc/sysctl.d" "$SYSROOT/run/sysctl.d" "$SYSROOT/usr/local/lib/sysctl.d" "$SYSROOT/usr/lib/sysctl.d"
  ln -s usr/lib "$SYSROOT/lib"
  printf 'net.core.default_qdisc = fq_codel\nnet.ipv4.tcp_congestion_control = cubic\n' > "$SYSROOT/usr/lib/sysctl.d/50-default.conf"
}
reset_sysctl_fixture
check network_check_sysctl_priority "$SYSROOT"
printf 'net.core.default_qdisc = fq_codel\n' > "$SYSROOT/usr/lib/sysctl.d/99-late.conf"
if network_check_sysctl_priority "$SYSROOT" >/dev/null 2>&1; then exit 1; fi
ln -s /dev/null "$SYSROOT/etc/sysctl.d/99-late.conf"
check network_check_sysctl_priority "$SYSROOT"
builtin command rm "$SYSROOT/etc/sysctl.d/99-late.conf"
printf 'net.core.default_qdisc = fq\n' > "$SYSROOT/etc/sysctl.d/99-late.conf"
check network_check_sysctl_priority "$SYSROOT"
reset_sysctl_fixture
printf 'net.core.default_qdisc = fq_codel\n' > "$SYSROOT/etc/sysctl.d/10-admin.conf"
if network_check_sysctl_priority "$SYSROOT" >/dev/null 2>&1; then exit 1; fi
reset_sysctl_fixture
printf 'net.ipv4.tcp_congestion_control = cubic\n' > "$SYSROOT/etc/sysctl.conf"
if network_check_sysctl_priority "$SYSROOT" >/dev/null 2>&1; then exit 1; fi
reset_sysctl_fixture
printf 'net.core.default_qdisc = fq_codel\n' > "$SYSROOT/usr/lib/sysctl.d/99-shared.conf"
printf 'net.core.default_qdisc = fq\n' > "$SYSROOT/run/sysctl.d/99-shared.conf"
check network_check_sysctl_priority "$SYSROOT"
printf 'net.core.default_qdisc = fq_codel\n' > "$SYSROOT/run/sysctl.d/99-shared.conf"
if network_check_sysctl_priority "$SYSROOT" >/dev/null 2>&1; then exit 1; fi
reset_sysctl_fixture
printf 'net.core.default_qdisc = fq_codel\n' > "$SYSROOT/usr/lib/sysctl.d/99-shared.conf"
printf 'net.core.default_qdisc = fq\n' > "$SYSROOT/usr/local/lib/sysctl.d/99-shared.conf"
check network_check_sysctl_priority "$SYSROOT"
state=$(network_status)
[[ $state == *'系统默认队列：fq_codel'* && $state == *'宿主机拥塞算法：cubic'* ]] || exit 1
printf 'PASS strict tc parser, exact JSON rollback, ECN/pacing preservation, container algorithms and phase-aware recovery\n'

# 无交互核心不读取菜单确认；批量处理节点不能污染新增流程的 NODE_ID。
(
 need_docker(){ :; }
 network_preflight(){ network_inspect; }
 network_snapshot_containers(){ :; }
 network_apply(){ NODE_ID=existing-node; touch "$STACK_DIR/network-bbr-enabled"; }
 network_status(){ :; }
 confirm(){ echo FORBIDDEN-confirm > "$STACK_DIR/forbidden-interaction"; return 99; }
 node_ask(){ echo FORBIDDEN-input > "$STACK_DIR/forbidden-interaction"; return 99; }
 NODE_ID=new-node-context
 check network_enable_execute
 [[ $NODE_ID == new-node-context ]] || exit 1
 check test ! -e "$STACK_DIR/forbidden-interaction"
 # 独立菜单取消仍然零执行；保持它自己的预检与确认包装。
 confirm(){ return 1; }
 network_enable_execute(){ touch "$STACK_DIR/forbidden-core"; }
 check cmd_network_enable
 check test ! -e "$STACK_DIR/forbidden-core"
)
echo 'PASS noninteractive network core, node context preservation and menu cancellation'
