#!/usr/bin/env bash
# 所有 Swap/磁盘/系统管理操作均为 mock；仅写临时 fixture，不写 /etc 或真实 Swap。
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
CASE=$1; DIR="$ROOT/$CASE"; mkdir -p "$DIR"
LOG="$DIR/log"; : > "$LOG"
MEM="$DIR/meminfo"; SWAPS="$DIR/swaps"; FSTAB="$DIR/fstab"; TARGET="$DIR/swapfile"
SWAP_STATUS_FILE=$SWAPS
printf 'MemTotal: 749568 kB\n' > "$MEM"
printf 'Filename Type Size Used Priority\n' > "$SWAPS"
printf '# user configuration\nUUID=original / xfs defaults 0 0\n' > "$FSTAB"
chmod 640 "$FSTAB"
cp "$FSTAB" "$DIR/expected"
step(){ :; }; grn(){ :; }; red(){ printf 'error %s\n' "$*" >> "$LOG"; }; ylw(){ printf 'warning %s\n' "$*" >> "$LOG"; }
assert(){ "$@" || { printf 'assert failed: %s\n' "$*" >&2; exit 1; }; }
contains(){ [[ $(cat "$LOG") == *"$1"* ]]; }
not_contains(){ [[ $(cat "$LOG") != *"$1"* ]]; }
findmnt(){ printf 'findmnt %s\n' "$*" >> "$LOG"; if [[ $CASE == unsupported ]]; then echo btrfs; else echo xfs; fi; }
df(){ printf 'df %s\n' "$*" >> "$LOG"; echo 'Filesystem 1024-blocks Used Available Capacity Mounted'; if [[ $CASE == disk ]]; then echo '/dev/mock 3000000 2000000 1000000 66% /'; else echo '/dev/mock 5000000 1000000 4000000 20% /'; fi; }
dd(){
  printf 'dd %s\n' "$*" >> "$LOG"
  local argument output=''
  for argument in "$@"; do [[ $argument != of=* ]] || output=${argument#of=}; done
  [[ $output == "$DIR"/swapfile.tmp.* ]] || exit 99
  # 第一笔写入前已经是600。
  assert test "$(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$output")" = 600
  printf 'mock non-sparse data\n' > "$output"
  [[ $CASE != dd_fail ]] || return 1
  [[ $CASE != signal_pending ]] || kill -TERM $$
  [[ $CASE != signal_pending_int ]] || kill -INT $$
}
stat(){
  [[ $1 == -c && $2 == '%d:%i' && $3 == -- && $4 == "$DIR"/* ]] || exit 99
  python3 - "$4" <<'PY'
import os,sys
try:
    info=os.lstat(sys.argv[1]); print(f'{info.st_dev}:{info.st_ino}')
except FileNotFoundError: sys.exit(1)
PY
}
rm(){
  printf 'rm %s\n' "$*" >> "$LOG"
  [[ $CASE != unlink_fail || $* != *swapfile.tmp.* ]] || return 1
  python3 - "$DIR" "$TARGET" "$SWAPS" "$@" <<'PY'
import os,pathlib,sys
root,target,swaps,*args=sys.argv[1:]
active=any(line.split()[0]==target for line in pathlib.Path(swaps).read_text().splitlines() if line.split())
for path in [a for a in args if not a.startswith('-')]:
    if os.path.commonpath([os.path.abspath(path),root]) != root: sys.exit(99)
    if not os.path.lexists(path): continue
    # 模拟 Linux：活动 Swap inode 的任何硬链接都不能 unlink。
    if active and os.path.exists(target) and os.path.samestat(os.stat(path),os.stat(target)):
        print('FORBIDDEN active unlink',file=sys.stderr); sys.exit(1)
    os.unlink(path)
PY
  local result=$?
  [[ $result == 0 ]] || return "$result"
  if [[ $CASE == unlink_signal && $* == *swapfile.tmp.* ]]; then kill -TERM $$; fi
}
selinuxenabled(){ return 0; }
chcon(){ printf 'chcon %s\n' "$*" >> "$LOG"; [[ $CASE != context_fail ]]; }
ln(){
  if [[ $1 == -T ]]; then
    [[ $3 == "$DIR"/swapfile.tmp.* && $4 == "$TARGET" ]] || exit 99
    python3 - "$3" "$4" <<'PY'
import os,sys
try: os.link(sys.argv[1],sys.argv[2])
except FileExistsError: sys.exit(1)
PY
  else /bin/ln "$@"; fi
}
restorecon(){ printf 'restorecon %s\n' "$*" >> "$LOG"; }
mkswap(){ printf 'mkswap %s\n' "$*" >> "$LOG"; [[ $1 == "$TARGET" ]] || exit 99; [[ $CASE != init_fail ]]; }
swapon(){
  printf 'swapon %s\n' "$*" >> "$LOG"
  [[ $1 == "$TARGET" ]] || exit 99
  [[ $CASE != enable_fail ]] || return 1
  if [[ $CASE == target_replaced ]]; then
    printf 'replacement user content' > "$DIR/replacement"
    python3 - "$DIR/replacement" "$TARGET" <<'PY'
import os,sys
os.replace(sys.argv[1],sys.argv[2])
PY
    kill -TERM $$
  fi
  assert test "$(python3 -c 'import os,sys;print(os.stat(sys.argv[1]).st_nlink)' "$TARGET")" = 1
  printf '%s file 1048576 0 -2\n' "$TARGET" >> "$SWAPS"
  [[ $CASE != signal_active ]] || kill -TERM $$
}
swapoff(){ printf 'FORBIDDEN swapoff\n' >> "$LOG"; exit 99; }
cp(){
  printf 'cp %s\n' "$*" >> "$LOG"
  [[ $CASE != backup_fail || $* != *v2fly-backup* ]] || return 1
  [[ $CASE != candidate_fail || $* != *v2fly-new* ]] || return 1
  python3 - "$@" <<'PY'
import pathlib,sys,shutil
args=[a for a in sys.argv[1:] if not a.startswith('--')]
source,target=args[-2:]
if '--preserve=all' in sys.argv: shutil.copy2(source,target)
else: pathlib.Path(target).write_bytes(pathlib.Path(source).read_bytes())
PY
}
mv(){
  printf 'mv %s\n' "$*" >> "$LOG"
  [[ $CASE != persist_fail ]] || return 1
  [[ $4 == "$FSTAB" ]] || exit 99
  python3 - "$3" "$4" <<'PY'
import os,sys
os.replace(sys.argv[1],sys.argv[2])
PY
}
systemctl(){ printf 'systemctl %s\n' "$*" >> "$LOG"; [[ $CASE != reload_fail ]]; }
# 让真实安装入口只会调用 fixture 文件。
eval "$(declare -f create_swap | sed '1s/create_swap/create_swap_fixture/')"
create_swap(){ create_swap_fixture "$TARGET" "$FSTAB"; }
# Fixture bridge: planning may ask, actual execute_low_memory never reads input.
fixture_prepare_swap(){
  local status PLAN_SWAP=no
  if needs_swap "$1" "$2"; then
    confirm '计划创建 Swap？' n || return 1
    PLAN_SWAP=yes
    execute_low_memory
  else status=$?; [[ $status == 1 ]]; fi
}
case "$CASE" in
  enough)
    printf 'MemTotal: 2097152 kB\n' > "$MEM"
    fixture_prepare_swap "$MEM" "$SWAPS" || exit 1
    assert test ! -s "$LOG"
    ;;
  existing_swap)
    printf '/existing-swap file 1048576 0 -2\n' >> "$SWAPS"
    fixture_prepare_swap "$MEM" "$SWAPS" || exit 1
    assert test ! -s "$LOG"
    ;;
  decline)
    IN=0
    if fixture_prepare_swap "$MEM" "$SWAPS" </dev/null; then exit 1; fi
    assert not_contains dd
    assert not_contains findmnt
    ;;
  existing_file|symlink|directory|fstab_conflict|disk|unsupported|dd_fail|init_fail|enable_fail|unlink_fail|unlink_signal|target_replaced|backup_fail|candidate_fail|context_fail|persist_fail|reload_fail|signal_pending|signal_pending_int|signal_active|success)
    confirm(){ printf 'confirm %s\n' "$*" >> "$LOG"; [[ $2 == n ]]; }
    case "$CASE" in
      existing_file) printf 'user content' > "$TARGET" ;;
      symlink) ln -s "$DIR/missing-original" "$TARGET" ;;
      directory) mkdir "$TARGET" ;;
      fstab_conflict) printf '%s none swap defaults 0 0\n' "$TARGET" >> "$FSTAB"; /bin/cp "$FSTAB" "$DIR/expected" ;;
    esac
    if [[ $CASE == success ]]; then
      fixture_prepare_swap "$MEM" "$SWAPS" || exit 1
      assert test "$SWAP_ACTIVE" = yes
      assert contains 'bs=1M count=1024 conv=fsync'
      assert contains 'restorecon '
      assert contains 'cp --preserve=all'
      assert contains 'systemctl daemon-reload'
      assert test "$(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$FSTAB")" = 640
      assert test "$(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$SWAP_FSTAB_BACKUP")" = 600
      assert test "$(grep -Fc "$TARGET none swap defaults,nofail 0 0" "$FSTAB")" = 1
      python3 - "$LOG" <<'PY' || exit 1
import pathlib,sys
lines=pathlib.Path(sys.argv[1]).read_text().splitlines()
positions=[next(i for i,s in enumerate(lines) if s.startswith(prefix)) for prefix in ['dd ','restorecon ','mkswap ','rm ','swapon ','mv ','systemctl ']]
assert positions==sorted(positions)
PY
    else
      if fixture_prepare_swap "$MEM" "$SWAPS"; then exit 1; fi
      case "$CASE" in
        candidate_fail|context_fail|persist_fail|reload_fail)
          assert test "$SWAP_ACTIVE" = yes
          assert test -f "$TARGET"
          assert test -f "$SWAP_FSTAB_BACKUP"
          ;;
        existing_file) assert test "$(cat "$TARGET")" = 'user content' ;;
        symlink) assert test -L "$TARGET" ;;
        directory) assert test -d "$TARGET" ;;
        unlink_fail) assert not_contains 'swapon '; assert test ! -e "$TARGET" ;;
        *) assert test ! -e "$TARGET" ;;
      esac
      if [[ $CASE != reload_fail ]]; then assert cmp -s "$FSTAB" "$DIR/expected"; fi
    fi
    assert not_contains FORBIDDEN
    ;;
  legacy_active)
    SWAP_SOURCE="$DIR/swapfile.tmp.legacy"; SWAP_TARGET=$TARGET
    printf 'legacy swap data' > "$SWAP_SOURCE"
    ln -T -- "$SWAP_SOURCE" "$SWAP_TARGET" || exit 1
    SWAP_CREATED_ID=$(stat -c '%d:%i' -- "$SWAP_SOURCE") || exit 1
    printf '%s file 1048576 0 -2\n' "$TARGET" >> "$SWAPS"
    cleanup_swap
    assert test -f "$SWAP_SOURCE"
    assert test -f "$TARGET"
    assert not_contains 'rm '
    ;;
  *) exit 98 ;;
esac
cleanup
assert not_contains FORBIDDEN
BASH
  case "$1" in
    signal_pending|signal_pending_int|unlink_signal)
      expected_status=143; [[ $1 != signal_pending_int ]] || expected_status=130
      [[ $status == "$expected_status" && ! -e "$ROOT/$1/swapfile" ]] || return 1
      [[ $(find "$ROOT/$1" -name 'swapfile.tmp.*' -print) == '' ]] || return 1
      ;;
    target_replaced)
      [[ $status == 143 && $(cat "$ROOT/$1/swapfile") == 'replacement user content' ]] || return 1
      ;;
    signal_active)
      [[ $status == 143 && -f "$ROOT/$1/swapfile" && $(cat "$ROOT/$1/log") != *swapoff* ]] || return 1
      ;;
    *) [[ $status == 0 ]] || return 1 ;;
  esac
  printf 'PASS %s\n' "$1"
}
for test in enough existing_swap decline success existing_file symlink directory fstab_conflict disk unsupported dd_fail init_fail enable_fail unlink_fail unlink_signal target_replaced legacy_active backup_fail candidate_fail context_fail persist_fail reload_fail signal_pending signal_pending_int signal_active; do
  run_case "$test" || { printf 'FAIL %s\n' "$test" >&2; exit 1; }
done
