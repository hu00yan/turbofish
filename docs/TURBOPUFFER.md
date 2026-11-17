# Turbopuffer 对比与下一步计划

> 抓取/测量日期：2026-11-15。Turbopuffer 的价格和公开性能来自其官网，可能变化；
> 本文的美元数字是模型估算，不是报价。我们的实测来自
> [`perf/RESULTS.md`](../perf/RESULTS.md) 的 50k × 128 维运行。

## 1. 先给结论

1. **性能不能直接对比。** Turbopuffer 公开数据是 10M × 768 维、强一致；
   我们目前是 50k × 128 维、单进程缓存。两者规模、维度、一致性都不同。
2. **小规模我们很难在价格上赢。** Turbopuffer Launch 最低 $16/月；
   50k～1M 文档、每月 1000 万查询的账单基本就是 $16，而自建一台 4 vCPU
   机器 7×24 运行通常就要 $40 左右。
3. **10M 以上是真正的战场。** Turbopuffer 10M × 768 维、约 15 GB 逻辑数据，
   每月 1000 万查询约 **$164**；自建目标架构大约 **$80～160**（一台/几台
   NVMe 节点 + S3），差距不大，但自建多了运维、复制、故障恢复。
4. **我们的优势不应是“更便宜”，而是“可自托管、可控、可改”。**
   如果要做成产品，定位应是 BYOC/私有化、单租户低延迟、定制分词/排序，
   而不是在公开云上和小规模 Turbopuffer 打价格战。
5. **当前最缺的不是查询 CPU，而是规模化和稳态存储。** 固定 `nlist=64`、
   4×64 MB worker cache、无 GC 的 5.6 KB/doc 物理放大会在 10M 文档时先崩。

## 2. Turbopuffer 公开性能

来自 <https://turbopuffer.com/>（2026-11-15 页面）：

| 场景 | 规模 | warm p50 / p90 / p99 | cold p50 / p90 / p99 |
| --- | --- | ---: | ---: |
| Vector query | 10M docs, 768d, f16, ~15 GB | 14 / 17 / 27 ms | 874 / 1214 / 1686 ms |
| BM25 FTS | 1M docs, ~300 MB | 13 / 18 / 29 ms | 316 / 381 / 559 ms |
| Upsert 512 KB | — | 165 / 248 / 850 ms | — |

其架构文档说明：默认强一致，consistent read 有约 **10 ms** 的元数据检查地板；
首次查询把 namespace 数据缓存到 NVMe，后续查询路由到同一节点；
冷查询直接对对象存储做 **少量、批量、ranged reads**；写入走对象存储 WAL，
按秒 group commit；ANN 使用 SPFresh 风格的 centroid 索引，而不是 HNSW。

## 3. 我们的实测（不可直接对比）

来自 50k × 128 维、f16、exact numpy ground truth、recall≈0.945：

| 指标 | Turbofish direct MinIO | Turbofish + 50ms±20ms toxiproxy | Qdrant 本地盘 |
| --- | ---: | ---: | ---: |
| warm p50 | 0.660 ms | 0.681 ms | 2.009 ms |
| warm p95 | 1.121 ms | 1.128 ms | 2.296 ms |
| warm QPS（串行） | 1205 | 1149 | 473 |
| cold 第一查 | 38.3 ms | 180.0 ms | 12.5 ms |
| cold 20 查 S3 GET | 31 次 | 31 次 | — |
| 写入 50k | 53.1 s / 942 docs/s | 417.7 s / 120 docs/s | 4.0 s + 14.1 s 建索引 |
| 存储 | 282 MB / 5.6 KB/doc | 310 MB / 6.2 KB/doc | 72 MB / 1.44 KB/doc |

**为什么不能拿 0.66 ms 对 14 ms：**

- 我们是 50k × 128，Turbopuffer 是 10M × 768；计算量差三个数量级。
- 我们的 warm 查询命中进程内 `Namespace`/worker cache，没有每次都做跨节点
  strong-consistency head 检查；Turbopuffer 默认强一致，约 10 ms 地板。
- 我们的 cold 是“冷查询进程、热 metad / OS / MinIO”；Turbopuffer 的 cold
  是未缓存 namespace 的对象存储读取。两者冷启动定义也不同。
- 我们的 0.66 ms 说明单机热路径很快，不说明 10M 规模还能保持。

## 4. 成本模型

Turbopuffer 公开单价（Launch/Scale，2026-11-15）：

| 项目 | 价格 |
| --- | ---: |
| 索引存储 | $0.33 / GB-month |
| 非索引存储 | $0.165 / GB-month |
| 写入 | $2 / GB（批量最大 5 折，10 KB 起计） |
| 查询数据量 | $1 / PB（每查询最低 1.28 GB；32–128 GB 部分 2 折，>128 GB 部分 4 折） |
| 返回数据量 | $0.05 / GB |

模型假设：

- f16 向量，属性约 51 B/doc（id 8 + text 30 + category 4 + ts 8 + public 1）。
- 逻辑大小 = `51 + 2 × dim` B/doc。
- 每月 1000 万次查询，静态数据，不计写入和返回。
- 自建按“目标架构”估：S3 $0.023/GB-month，4 vCPU NVMe 节点 $40/月，
  10M 文档约 1 台，100M 文档约 4 台；**不含运维人力**。
- 自建物理大小按当前 128 维实测 5.6 KB/doc；768 维按 6 KB/doc 估。

| 工作负载 | Turbopuffer/月 | 我们的 S3 存储/月 | 自建目标/月（含节点） |
| --- | ---: | ---: | ---: |
| 50k × 128d | **$16（最低消费）** | $0.01 | ~$40 |
| 1M × 128d | **$16（最低消费）** | $0.13 | ~$40 |
| 10M × 128d | **$31.71** | $1.29 | ~$81 |
| 100M × 128d | **$317.13** | $13.00 | ~$333 |
| 1M × 768d | **$16.39** | $0.07 | ~$40 |
| 10M × 768d | **$163.94** | $1.38 | ~$81 |
| 100M × 768d | **$576.65** | $13.80 | ~$327 |

读法：

- **≤1M 文档**：Turbopuffer 的 $16 最低消费低于一台 7×24 自建节点；
  只有“已经有机器/必须私有化”时自建才合理。
- **10M 文档、每月 1000 万查询**：Turbopuffer 约 $164（768d）；
  自建目标约 $81，但前提是我们能把 10M 查询做到单节点 ~20 ms 级，
  目前还做不到。
- **100M 文档**：Turbopuffer 约 $577；自建约 $327，但需要 4 节点、
  分片、GC、故障恢复，工程成本远高于表格里的机器钱。
- 写入成本未计入；Turbopuffer 全量重写 15 GB 约 $30（5 折后），
  自建主要是 S3 PUT 和 compaction 写放大，当前 compaction 残留是更大的问题。

## 5. 真正的差距

| 维度 | Turbopuffer | 我们当前 |
| --- | --- | --- |
| 单 namespace 规模 | 128B docs / 256TB，支持 256 shards | IVF `nlist=64` 固定，未做 10M 级分片 |
| 缓存 | 首次查询后整个 namespace 进 NVMe；多租户共享 | 4×64 MB worker cache + metad 元数据；无全量 NVMe block cache |
| 冷读 | 批量 cluster ranged read，少量 round trip | 每个 probe part 一次 GET；50k 冷窗 31 次 |
| 一致性 | 默认强一致，~10ms 地板 | 进程内快照/元数据缓存；跨节点强一致未验证 |
| 存储效率 | 逻辑计费，物理放大由服务吸收 | 5.6 KB/doc，无 superseded part GC |
| 功能 | BM25、filters、regex、branch、多向量、聚合 | BM25/过滤/RRF 已有，但未做同规模基准；缺 branch/regex/聚合等 |
| 运维 | 全托管、多租户、复制、限流 | 单机 metad，无复制/failover/限流 |
| 写入 | WAL + 秒级 group commit，~10k vectors/s/ns | 直接写 S3 + 同步 compaction；50k 写入 942 docs/s direct |

### 5.1 实测分解（当前 main，50k × 128，`cmd/bench1m`）

同一把尺子分别跑线上写路径（`BENCH_WRITE_SLAB=1`，`ingest_l0_slab`）与 legacy
路径（`ingest` + `ingest_delta_opts`）：

| 指标 | legacy | slab（线上） |
| --- | ---: | ---: |
| PUT / 1000 文档批 | ~75 | ~68 |
| vec 冷查询 GET/q | 114 | 164 |
| vec 冷查询 KB/q | 1717 | 1934 |
| vec 热查询 GET/q | 50 | 0 |
| vec 热查询 p50（虚拟时钟） | 1657 ms | 10.4 ms |

**每批 ~68 个 PUT 的构成**：1 个 segment slab + 64 个全局 IVF delta part
（`write_global_delta_parts` 每个簇一个对象，`global_pack_size` 默认 1）
+ manifest + head 记录。也就是说段格式（W3 的「4 PUT/批」）只占 6%，
成本主项是全局 IVF 的增量派生对象。

**每次查询的读放大**：

```
bytes/query ≈ nprobe × (N / nlist) × dim × 2B
```

50k × 128、nprobe=8、nlist=64 时为 8 × 780 行 × 128 × 2B ≈ 1.6 MB，
实测 1934 KB/q（含列与倒排）吻合。按同一公式外推到 10M × 768 且 nlist 仍为
64 时是 **≈1.9 GB/查询**，比 Turbopuffer 的冷读量高三个数量级。所以 TP-1
（10M warm ≤12 ms）在固定 `nlist` 下不可达，先把 `nlist` 随 N 增长做出来，
才谈得上同规模对比。

**packing 不是成本杠杆**：`BENCH_PACK=8` 把 PUT 降到 22/批、`PACK=16` 降到
18/批，但 vec 冷查询 KB/q 从 1717 涨到 12505（读放大 7 倍）。在「PUT 计费、
字节不计费」的模型里它看起来划算，实际是把成本挪到延迟上。

## 6. 下一步计划

### P0：先把“可比”做出来（1 周）

1. 新增 `perf/run_turbopuffer.py`，需要 `TURBOPUFFER_API_KEY`。同一份
   1M/10M × 768 数据集、同一 exact GT、iso-recall、warm/cold、过滤/FTS。
   - 若没有 API key，只能引用官网数字，不得声称“我们赢了”。
2. 新增 `perf/cost_model.py`，把上面的公式和场景固化成可复算 JSON。
3. 增加 `consistency=strong|eventual` 两档基准，明确我们的 0.66 ms 是哪一档。
4. 验收：一份 JSON 同时包含两引擎的 warm/cold p50/p95/p99、recall、QPS、
   ingest、$ / 10M queries；`errors=[]`。

### P1：补规模化和稳态存储（2–4 周）

5. **自适应 IVF/分片**：`nlist` 随 N 增长（目标是每簇行数 ≤ 2k，10M 时需要
   nlist ≈ 5k，而不是 64），支持 namespace sharding。验收看 §5.1 的公式：
   同 recall 下 `KB/q` 不随 N 增长。当前 `nlist` 在首次建 namespace 时训好就
   冻结，所以要带「compact 时重训中心并重分片」这一半，否则规模一涨就退化。
   目标 1M/10M × 768 在 recall≈0.95 时 warm p50 <20 ms（单节点）。
6. **NVMe block cache**：缓存 probe 命中的 cluster/global part，而不只是
   metadata；目标 10M 文档、64 GB SSD 下 warm 命中率 >90%。
7. **批量/range 冷读**：把多个 cluster 的 offset 合并成少量 ranged GET；
   目标 1M cold p50 <500 ms，10M cold p50 <1.5 s（对齐 Turbopuffer 874 ms
   的量级，而不是现在的 31 次 part GET）。
8. **GC/retention**：清理 superseded merge-tree parts/manifests；
   目标 128d <2 KB/doc，768d <3 KB/doc；否则 100M 文档会被历史 compaction
   拖死。
9. 验收：同规模基准 + `mc du` 稳态存储 + 24 小时写入/查询混合测试。

### P2：产品化与差异化（1–2 个月）

10. **强一致/多节点**：metad head 推送或 TTL 失效、查询节点无状态化、
    read replica；明确 strong read 的 ~10 ms 地板，不和 eventual 混报。
11. **FTS/hybrid 对齐**：BM25 1M warm 目标 ~15 ms；过滤 + 向量 + BM25
    的混合查询纳入固定基准。
12. **运维能力**：鉴权、租户隔离、限流、重试、metrics/tracing、备份、
    metad 复制/failover。
13. **定位**：优先做“可自托管/BYOC、单租户低延迟、可定制”的搜索底座；
    不在 50k～1M 小规模上和 Turbopuffer 打价格战。

## 7. 来源

- Turbopuffer 首页性能：<https://turbopuffer.com/>
- 价格：<https://turbopuffer.com/pricing.md>
- 架构与 tradeoffs：<https://turbopuffer.com/docs/architecture.md>、
  <https://turbopuffer.com/docs/tradeoffs.md>
- 限制：<https://turbopuffer.com/docs/limits.md>
- 我们的实测：`perf/RESULTS.md` 与
  `perf/results/compare-20261115T101916Z-33642.json`
