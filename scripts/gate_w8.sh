#!/usr/bin/env bash
# gate_w8.sh — W8 门禁：类型化 store 契约 + 唯一发布原语 + 跨后端 conformance
# L1 反作弊/契约快照 → L2 编译 → L3 全测试 → L4 行为断言
set -u
. "$(dirname "$0")/env.sh"
cd "$(dirname "$0")/.."
LOG="/tmp/gate_w8.log"
FAIL=0

step() { echo "== $1"; }
die()  { echo "FAIL: $1"; exit 1; }

step "L1a 反作弊：无 moon.pkg.json / TODO / 占位"
find . -name "moon.pkg.json" -not -path "./.mooncakes/*" -not -path "./_build/*" | grep . && die "moon.pkg.json 出现（必须 moon.pkg DSL）"
grep -rn --include='*.mbt' -E 'TODO|FIXME|unimplemented|\(\)\s*//\s*占位' \
  store/ store/conformance/ 2>/dev/null | grep -v '_build' && die "store 层出现占位标记"
grep -rn --include='*.mbt' 'test "' store/ store/conformance/ | grep -iE 'always pass|永远通过|占位' && die "占位测试名"

step "L1b 契约快照：trait 签名必须是类型化形式"
for sig in \
  "put_if_match(Self, String, Expected, Bytes)" \
  "get_range(Self, String, ByteRange)" \
  "get_range_many(Self, Array\[KeyRange\])" ; do
  grep -q "$sig" store/store.mbt || die "trait 签名丢失/回退: $sig"
done
grep -q "pub(all) struct Expected(String?)" store/store.mbt || die "Expected newtype 缺失"
grep -q "commit_with_rebase" store/txn.mbt || die "唯一发布原语 commit_with_rebase 缺失"
grep -q "commit_cas_on" store/txn.mbt || die "commit_cas_on 缺失"

step "L1c 防回潮：裸元组范围 / 裸 String? expected 禁止回流"
grep -rn --include='*.mbt' 'ranges : Array\[(String, Int, Int)\]' store/ store/conformance/ && die "get_range_many 出现裸元组 ranges（必须 Array[KeyRange]）"
grep -rn --include='*.mbt' 'expected : String?' --include='*.mbt' . 2>/dev/null \
  | grep -v '.mooncakes\|_build\|s3client/client.mbt\|simstore/chaos.mbt\|s3store/s3store.mbt' \
  | grep 'fn ' && die "put_if_match 侧出现裸 String? expected（必须 Expected）"

step "L1d 契约完整性：conformance 条款与负向对照都在"
grep -q "Expected(None) 对已存在 key 应失败" store/conformance/conformance.mbt || die "conformance CAS 条款缺失"
grep -q "坏后端被契约抓住" store/conformance/conformance_wbtest.mbt || die "conformance 负向对照缺失（防契约被改宽）"
LINES=$(wc -l < store/conformance/conformance.mbt)
[ "$LINES" -ge 100 ] || die "conformance 契约被删减（$LINES 行 < 100）"
grep -q "conformance_report" fsstore/fsstore_wbtest.mbt || die "FsStore 未接入 conformance"
grep -q "conformance_report" s3store/s3_wbtest.mbt || die "S3Store 未接入 conformance"

step "L2 编译（全仓）"
moon check --target native > "$LOG" 2>&1 || die "moon check 失败（见 $LOG）"

step "L3 全量测试"
moon test --target native > "$LOG" 2>&1
tail -n 2 "$LOG"
grep -q "failed: 0" <(tail -n 1 "$LOG") || die "测试未全绿"

step "L4 行为断言"
grep -q "Total tests" "$LOG" || die "无测试输出"
# 原语与 conformance 必须真的跑过（测试名进入统计）
T=$(tail -n 1 "$LOG" | grep -oE 'Total tests: [0-9]+' | grep -oE '[0-9]+')
[ "${T:-0}" -ge 390 ] || die "测试总数 $T < 390（可能删测试）"

echo "GATE_W8: PASS (${T} tests)"
