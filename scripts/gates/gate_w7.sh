#!/usr/bin/env bash
# W7 行为闸门：全仓 native 编译/测试 + 四个可执行文件构建 + 端到端冒烟 +
# 「cmd/serve / cmd/compactd 不再依赖 libcurl」的静态断言。
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/env.sh

echo "== [gate_w7] 1/4 全仓 native 编译 + 全量测试"
moon check --target native
moon test --target native

echo "== [gate_w7] 2/4 构建 serve / compactd / metad / supervise"
moon build --target native --release cmd/serve cmd/compactd cmd/metad cmd/supervise

echo "== [gate_w7] 3/4 端到端冒烟（fs 存储 + metad + serve + compactd）"
bash scripts/gates/smoke_e2e.sh

echo "== [gate_w7] 4/4 serve/compactd 不依赖 libcurl"
if grep -rEn "s3http|CurlTransport|-lcurl" cmd/serve cmd/compactd --include="*.mbt" --include="moon.pkg"; then
  echo "[gate_w7][FAIL] cmd/serve 或 cmd/compactd 仍引用 s3http / libcurl"
  exit 1
fi

# 额外结构断言：写路径必须走组提交 + ingest_l0_slab；compactd 必须领 metad 脏队列。
grep -q "GroupCommitManager" cmd/serve/main.mbt
grep -q "ingest_l0_slab" cmd/serve/main.mbt
grep -q "claim_dirty" cmd/compactd/main.mbt
grep -q "compact_optimistic" cmd/compactd/main.mbt
grep -q "ReusePortServer" cmd/serve/main.mbt
grep -q "UringEngine" cmd/serve/main.mbt

echo "GATE_W7: PASS"
