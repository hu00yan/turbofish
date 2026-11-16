# VERIFICATION_PIPELINE.md：七层验证流水线

> 目标：把错误**挡在流水线和架构层**，而非依赖 review 和事后补救。
> 原则：①错误左移——能被编译器/静态层拦的绝不留给测试；②成本递增分层——
> 秒级层先跑、昂贵层后跑，每层失败立即熔断；③**Turbopuffer 是唯一参照物**——
> 每个性能/成本声明必须在可比轴上不输 Turbopuffer 公开数据，否则不许发布。
> 参照数据：`docs/TURBOPUFFER.md`（2026-11-15 快照）。

## 0. 流水线拓扑（按执行顺序，失败即停）

```
T0 静态(30s) ─► T1 单测+覆盖(3min) ─► T2 协议conformance(3min) ─► T3 差分对拍(5min)
   ─► T4 形式化/模型(5min) ─► T5 混沌e2e(10min) ─► [合并主干] ─► T6 性能/成本契约(30min, 发布前)
   ─► T7 变异测试(每周, 离线)
```

每层硬超时看门狗（超时=FAIL，防止死锁伪装绿灯）。触发时机：
T0+T1 每次编辑；T2+T3+T4 每个任务交付（`verify_task.sh`）；T5 每次合入主干；
T6 发布前或动到查询/写路径/格式时；T7 每周一次。

## T0 静态层（让编译器当裁判，秒级）

| 检查 | 手段 | 拦截的错误类 |
|---|---|---|
| 全仓类型检查 | `moon check -d --target native`（warnings 即错） | async 泄漏、签名不匹配 |
| **类型化契约（newtype）** | `Expected(String?)` / `ByteRange{off,len}` / `KeyRange` | **参数顺序颠倒**（本轮 put_if_match 陷阱） |
| pub 签名快照 | `.contract/*.mbti` 快照 diff，变更必须显式提交快照 | trait 悄悄演进破坏下游 |
| 发布原语唯一性 | lint：`put_if_match` 发布 head 只允许出现在 `store/txn.mbt` | 手写 CAS 状态机（本轮真 bug 根因） |
| 依赖禁令 | lint：全仓 `moon.pkg` 禁 `lcurl`/`s3http`/`moon.pkg.json` | 废依赖回流 |
| 文档-测试绑定 | `docs/*.md` 不变量必须带 `verified-by: <test>` 标注，脚本校验测试存在 | 文档与实现脱节 |
| 测试形态 | 新测试必须含断言；禁 `assert_true(true)`；禁改 golden | 测试作弊 |

## T1 单元 + 覆盖率门槛（分钟级）

- 全量 `moon test --target native`（现有 382+ 测试基线，只增不减）。
- **覆盖率门槛**：核心包（store/build/query/groupcommit/meta）行覆盖 ≥ 85%，
  跌破即红——"没测到"从沉默变成显式失败。

## T2 协议 Conformance（契约套件，一次建处处生效）

对每个公开 trait/协议建**黑盒性质套件**，所有实现必须跑同一套：

- `store/conformance/`（`ObjectStore`）：批量≡单键逐项等价（get_many/get_range_many/put_many
  与循环调用结果逐下标相等）、CAS 四象限（create/match/mismatch/concurrent）、
  range 越界与截断、delete 幂等、list 排序稳定、404 语义一致。
  实现矩阵：MemStore / FsStore / SimStore / S3Client(+内置 FakeS3) / Faulty[S] 包装器。
- `groupcommit` 协议：strict 不丢已确认写、flush 合并上界、双缓冲不互阻、反压 429、失败扇出。
- `metad` 租约协议：互斥、fencing epoch、过期抢占、脏队列去重与 claim。

**新增后端实现 trait = 自动被整套拷问**，错误在实现当下拦截。

## T3 差分对拍（本轮逃逸 bug 的直接解药）

同一数据集 × 随机操作序列（`@core.Rng` 固定 seed），成对结果**逐字节相等**：

1. SlabV2 单文件段 ≡ 传统多文件段（BM25/vec/hybrid/filter 全路径）
2. compact 前 ≡ compact 后（含墓碑边界、同 id 多版本 later-wins）
3. global IVF 融合读 ≡ 逐段暴力读
4. 组提交合并写 ≡ 逐条直写（写后读结果一致）

对拍 harness 是独立包（`difftest/`），产物是差异报告，不是断言堆。

## T4 轻量形式化（spec 模型 + 随机模型检验）

以 `spec/` 既有模型（cas/gc/mergetree/roaring）为基座升级为**模型检验**：

- 状态机模型：`ingest_l0_slab` / `compact_optimistic` / `delete` 的抽象状态
  （head 链、段集合、墓碑、L0 计数）。
- **随机模型检验（model-based testing）**：500 条随机操作序列 × 20 操作/条，
  每步执行后断言不变量：head 单调前进、墓碑单调、manifest 自洽、
  **无已确认写丢失（strict 持久性）**、compact 输入⊆输出∪墓碑。
- 同 seed 100% 复现；失败自动收缩（shrink）到最小复现序列。
- 不变量清单维护在本文件 §9，新增状态机必须同步新增不变量条目（T0 文档绑定校验）。

## T5 混沌端到端（合入主干门禁）

`testkit/fakes3` 独立故障注入假 S3（真 TCP）+ `cmd/fakes3` 可执行体（`/_stats` 暴露
gets/puts/max_concurrent_inflight）。固定 seed 剧本：

- 并发写 + 慢 S3（150ms TTFB）+ CAS 竞争（多写者同 head）+ 5xx 重试 +
  `kill -9` serve/compactd + 自动重启 + compactd 并行合并。
- 断言：0 丢已确认写、读己之写 100%、compact 前后查询一致、
  `max_concurrent_inflight ≥ 4`（并发真实性）、组提交 `puts ≤ 5/批`（写放大上界）。
- 多进程 `SO_REUSEPORT` + 写亲和转发纳入同一剧本。

## T6 性能/成本契约（Turbopuffer 锚点，发布硬门禁）

**声明纪律**：每个数字必须带六维条件（数据集、recall、缓存状态、并发、durability、
价格口径），缺一不收。iso-recall 对齐（recall@10 = 0.95 主锚点，0.90/0.99 双侧）。

| 契约 | 轴（对齐 TP 公开口径） | TP 参照 | Turbofish 目标 |
|---|---|---|---|
| TP-1 | 10M×768d 向量查询 warm p50/p90/p99 | 14/17/27 ms | **≤ 12/15/24 ms**（快 ≥15%）|
| TP-2 | 同上 cold p50（未缓存 namespace 首查） | 874 ms | **≤ 700 ms** |
| TP-3 | 1M BM25 warm p50 / cold p50 | 13 / 316 ms | **≤ 11 / 280 ms** |
| TP-4 | Upsert 512KB p50 | 165 ms | **≤ 150 ms** |
| TP-5 | 10M docs + 10M 查询/月账单 | ~$164 | **≤ $120**（simcluster 出预算，真实账单校验）|
| TP-6 | 小租户：100×500 docs + 1M 查询/月 | $16（Launch 地板） | **< $8**（NanoTenant 单 Slab）|
| TP-7 | 稳态存储放大（GC 后 bytes/doc ÷ f16 向量字节） | ~1.5–2× | **≤ 2.5×**（现 5.6KB/doc=14×，GC 前不许发布）|

配套纪律：
- **simcluster 校准契约**：预测 vs 真实 MinIO/toxiproxy 实测误差 ≤ 20%，
  超出即校准失效、T6 结论作废。
- **性能回归门禁**：同机同 seed 重跑，任一主指标劣化 > 10% 即红。
- 对比实验沿用 `perf/run_compare.py`（50k 快速矩阵）+ 10M 规模在发布前跑
  真实 S3；Turbopuffer 侧数字取官网快照并在报告中注明抓取日期。

## T7 变异测试（测试自身的质量，每周离线）

`scripts/gates/mutation_check.sh` 自动注入 10 个代表性变异（删 CAS 重试、
`<=`→`<`、去 tombstone 过滤、批处理退化为循环、range off-by-one 等），
要求 ≥ 9 个被现有测试杀死；未杀死的变异对应的测试缺口当周补上。

## 9. 不变量清单（T4 逐步断言，新增状态机必须补充此表）

| ID | 不变量 | verified-by |
|---|---|---|
| INV-1 | head 指针只前进（manifest id 全序） | `spec/cas_spec.mbt` |
| INV-2 | tombstone 集合单调（仅 compact 物理化收缩） | `spec/mergetree_spec.mbt` |
| INV-3 | strict 持久性：HTTP 200 后的写崩溃可恢复 | `groupcommit/buffer_wbtest.mbt` + T5 |
| INV-4 | compact 输入段 ⊆ 输出段 ∪ 墓碑（不丢活文档） | `build/l0_delta_wbtest.mbt` + T3 |
| INV-5 | 并发追加段在乐观 Rebase 后保留在 manifest | `build/l0_delta_wbtest.mbt` |
| INV-6 | 批量读与单键读语义等价 | `store/conformance/` |
| INV-7 | 租约互斥：同资源同时至多一个 holder | `meta/client_wbtest.mbt` |
| INV-8 | 查询结果 later-wins（同 id 多版本） | `query/slab_wbtest.mbt` + T3 |
| INV-9 | Bloom 无假阴性 | `format/bloom_wbtest.mbt` |
| INV-10 | read-your-writes：strong 查询见最新已确认写 | `cmd/serve/serve_wbtest.mbt` + T5 |

## 10. 与开发流程的关系

- 每个开发任务照旧走「**先锁验收测试（RED）→ 派 DeepSeek 零歧义实现 →
  `verify_task.sh` 闭环（自动重试≤3 → 熔断交回主控）→ 主控合入**」。
- 任务卡必须声明：适用层级（T0–T5）、新增不变量、对应 conformance 套件。
- 本文件由主控维护；层级/门槛变更需在 PR 描述中给出逃逸错误证据。
