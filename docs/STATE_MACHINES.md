# STATE_MACHINES.md：应用中的隐式状态机清单与决定

> 目标：把散落在 build/query/simstore 的隐式状态显式化；每个状态机给出
> **状态、迁移、不变量、失败处理、UX/DX/AX 决定、对应测试**。
> 原则：不破坏旧行为；新状态/新索引默认向后兼容；S3 是唯一 durable truth。

## 0. 总原则

- **不可变对象 + manifest 快照**：segment / manifest / global part / bloom 一次写定，
  只追加；head 指针是唯一可变对象。
- **单副本**：向量只存 global part 一份；per-segment `rows/vector.bin` / `vec/part-*`
  只在旧布局或 global 关闭时存在。Bloom/索引是派生数据，可重建。
- **显式降级**：缺 Bloom / 缺 global / 缺索引时回退到旧路径，不 raise。
- **确定性**：SimStore 的随机延迟由 seed 决定；默认额外延迟为 0，旧测试字节级不变。
- **AX/DX**：状态迁移都有测试；错误用 `SpndError` 明确分类；缓存/索引有 stats/命中率。

## 1. Namespace head / manifest 生命周期

| 状态 | 判定 | 迁移 |
|---|---|---|
| `Uninitialized` | 无 `namespace.json` | `init_namespace` → `Empty` |
| `Empty` | `head_manifest == ""` | 首次 `ingest` → `Live` |
| `Live` | head 指向 manifest | `ingest` append / `delete_docs` / `compact` |
| `Tombstoned` | manifest.deleted 非空 | `compact` → `Live`（物理化） |
| `Compacted` | 1 段、deleted=[] | `ingest` append → `Live` |

不变量：
- manifest 不可变；`parent` 指向上一个 manifest；head 只前进。
- 先写 segment/global/bloom 对象，再写 manifest，再 CAS 发布 head。
- `deleted` 升序去重；roaring 对象与数组一致（新读优先 roaring）。

失败：
- 段写完但 manifest 未写 → 孤儿对象（GC 用 prefix/age）。
- manifest 写完但 head 未发布 → 孤儿 manifest（GC）。
- CAS 冲突 → 重读 head；已变则 `CommitConflict`，调用方重试。

UX/DX/AX：`CommitConflict`/`NotFound` 明确；`delete_docs` 不物理删；
`compact` 幂等（基于当前 head）。

## 2. Segment 生命周期

`Writing → Committed → Live → TombstonedRows → Compacted/Unreferenced → GC`

- `Writing`：列/fts/meta 正在写；不可见。
- `Committed`：manifest 引用；列长度、row_count、partitions 必须自洽。
- `Live`：manifest live；可被查询。
- `TombstonedRows`：`manifest.deleted` 含其 id；查询过滤。
- `Compacted`：新 manifest 不再引用；旧对象可 GC。
- 全局 IVF 模式下 segment 没有 `rows/vector.bin` / `vec/part-*`，向量由
  `vec/global/{manifest}/part-{cid}.bin` 承载（单副本）。

不变量：segment id 全局唯一；`row_count` = 各列长度；`min_id/max_id` 覆盖；
`partitions` 与 part 文件一致（旧布局）或为空（global 布局）。

## 3. Query snapshot / metadata cache

| 状态 | 判定 | 迁移 |
|---|---|---|
| `Cold` | 无 `Namespace` | `open` / `open_cached` → `Bound` |
| `Bound` | 绑定 manifest id | 查询；`open_cached` 可复用 |
| `Fresh` | cache.head == S3 head | 继续复用 |
| `Stale` | S3 head 变 | `open_cached` → reload → `Fresh` |
| `Pinned` | 有查询在用 | refcount → 0 → 可 GC |
| `Missing` | S3 不可用 | 回退旧快照（标记 stale） |

不变量：一个 `Namespace` 内的 `manifest` 不变；`CachedSeg` 以 seg id 为 key
（seg id 不可变，跨 manifest 可继承）；centroid 版本变了才清 centroids；
tombstone/global cids 在 head 变时重置。

UX/DX/AX：`MetadataCache` 暴露 `hits/misses/invalidate`；`open_cached` 文档写明
“只 GET 一次 namespace.json”；旧 segment 缓存自动继承。

## 4. Manifest CAS 发布

`ReadHead → Expected → CAS → Success | Conflict → ReRead → Retry/Raise`

- `expected = Some(old_head)`（S3 If-Match / MemStore 版本）。
- 失败：重读 head；已变 → `CommitConflict`；未变（store 版本语义差异）→ 直接 put。
- 测试：CAS 冲突用例（`simstore/chaos_wbtest.mbt`、`control/catalog_wbtest.mbt`）。

## 5. Compaction

`Idle → LoadingHead → MergingLiveDocs → WritingNewSegment → RebuildingIndexes
→ PublishingManifest → GC(OldSegments/Global/Bloom) → Idle`

- 输入：当前 head、live docs（跳过 tombstones）。
- 输出：1 个新段；centroids 复用；global IVF/bloom 重建；旧代 GC。
- 失败：任一步失败，旧 head 仍有效；新对象成为孤儿（GC）。
- 全局模式：`compact` 从 global parts 预加载旧段向量；新段不写 per-segment
  vector；发布后 GC 旧 global 代。
- 测试：`format/compact_wbtest.mbt`、`format/globalpack_wbtest.mbt`。

## 6. Tombstone

`None → Array → RoaringObject → CompactedEmpty`

- `delete_docs`：合并去重升序 → 写 `_tombstones/{manifest}.roar` → manifest
  `deleted` + `deleted_roar` → CAS。
- 查询：`tombstones_of` 优先 roaring，回退数组；惰性缓存。
- compact：物理化，`deleted=[]`、`deleted_roar=None`。
- 不变量：数组与 roaring 一致；tombstone 只增（直到 compact）。

## 7. Global IVF 分代

`LegacyPerSegment → GlobalGeneration(v1) → GlobalGeneration(v2) → GC(v1)`

- 每 manifest id 一个 generation：`vec/global/{manifest_id}/...`。
- 单副本：global 模式下 segment 不写 vector 列/parts。
- 查询优先按 `manifest.vec_global_version` 读；旧 manifest 快照读旧代（GC 前）。
- GC：publish 后按**被替代时刻**保留 grace（后继代 `created_ms + 60s`，覆盖
  MetadataCache TTL）；只删超龄旧代。显式 `gc_global_versions` 仍可立即清理。
- 回退：无 global → per-segment；PQ 不支持 global → per-segment。
- 测试：`query/query_wbtest.mbt` 中的 global IVF 用例。

## 8. FTS Bloom

`Absent → EmbeddedInSegMeta → MayContainTrue/False`

- build：段内 term 集合 → Bloom（m=next64(terms*10), k=7），hex 嵌入
  `seg meta.json`（不增加对象 GET）。
- query：`may_contain` 全 false → 跳过 dir/postings/doc_len。
- 不变量：Bloom 只可能 false positive，不允许 false negative；参数 m/k 随
  meta 存储，旧数据无 Bloom 走原路径。
- 测试：`format/bloom_wbtest.mbt` 与 segment meta 解析用例。

## 9. Filter matcher 路径

`WholeColumn → DictCodes → BoolBitmap → BlockMask`

- 按列编码自动选择：字典列 code 比对、bool 位图查位、ts 块统计 `MMask`。
- 回退：未知编码/缺块统计 → 整列 decode。
- 不变量：所有路径结果与整列扫描一致（测试断言）。
- 状态：`matchers` 缓存按 `field=value` 缓存，manifest 快照内复用。

## 10. SimStore 三档 + 延迟注入

`Resident → NVMe → S3Cold`；LRU 逐出；`cold()`/`prime_nvme()` 重置。

- 延迟：TTFB 对数正态 + 带宽 + **额外注入**：
  `wan_jitter_p50_us`（WAN 抖动）、`spike_probability/spike_p50_us`（尾部尖刺）、
  `retry_probability/retry_p50_us`（重试/backoff）。
- 默认 0，旧确定性不变；开启后按固定 rng 顺序采样，同 seed 可复现。
- 计费：仅 S3 请求计费；内存/NVMe 命中免费；CAS 失败也计 PUT。
- 测试：三档、LRU、计费、`latency injection deterministic`、并发 makespan。

## 11. 写路径孤儿 / GC

`WriteSegment → WriteIndexes → WriteManifest → PublishHead`

- 失败点：段/索引写完 → 孤儿对象；manifest 写完 → 孤儿 manifest。
- GC：按 `{ns}/_segments/{seg}`、`_manifest/`、`vec/global/`、`_tombstones/`
  前缀 + 引用集合/age 清理；GC 不删当前 head 引用的对象。
- 当前实现：global 代 GC 已有（publish 后按时间 grace）；段/manifest GC 留作运维任务。
- head log 发布：写后 LIST 做 max 仲裁；若发现同基线的并发 sibling（不是
  new_head 的 ancestor），后写者回滚自己的 head 并抛 `CommitConflict`，避免
  较小 id 的写者先返回成功后被静默覆盖。

## 12. 后端 / FFI 状态

`WasmStub ↔ NativeFFI`：`kernel_native.mbt` / `kernel_stub.mbt` 同签名；
`fsstore`/`benchx` 的 native-only 文件用 targets 门控。查询/构建路径不依赖 FFI，
只有 bench 的 C 内核和 FsStore 用。缺 native 时走桩，不破坏 wasm 测试。

## 13. Bench / 场景状态

`GenDocs → Ingest → Gates → Cost → Perf → Extended scenarios`

- 每个场景独立 store；扩展场景追加输出，不改默认参数。
- 失败：gate 失败即 raise；场景失败打印并继续（bench 不中断）。

## 14. S3 transport

`Idle → Signing → Connecting → Sent → Response → Retry/Error`

- `s3http` 通过 libcurl FFI 实现传输层；`s3store` 负责 SigV4 签名与请求构造。
- 不变量：SigV4 签名确定性；条件写 412 → 上层 CAS 仲裁；不记录凭据。
- 当前未实现自动重试/backoff；调用方需要区分网络错误与 4xx/5xx。

## 15. 设计取舍

1. **单副本 global IVF**：删除 per-segment vector 重复，代价是写入时需要维护全局分区代际。
2. **Bloom 嵌入 seg meta**：不增加对象 GET；缺失 term 直接跳过 dir/postings。
3. **进程级 metadata cache**：head 未变时零 manifest/segment 读。
4. **显式降级**：无 Bloom / 无 global / 无块统计 → 旧路径；PQ 不 global。
5. **延迟注入**：默认 0，保持旧确定性；可配 WAN jitter/spike/retry。
6. **形式化 spec**：状态迁移有运行时断言与随机模型检查；不是完整实现证明。

## 16. 测试映射

| 状态机 | 测试 |
|---|---|
| Namespace/CAS | `CAS conflict` |
| Segment/compact | `compact...`、`compact global single-copy...` |
| Query cache | `metadata cache hits/reloads` |
| Global IVF | `global vec parts`、`global IVF matches per-segment` |
| Bloom | `bloom membership/hex`、`seg meta embeds FTS bloom` |
| Tombstone | `delete_docs writes roaring`、`roaring tombstone filters` |
| SimStore | `latency injection deterministic`、三档/LRU/计费 |
| Latency units | bench 表 ms、`[perf]` µs |

## 17. global IVF delta 链

| 状态 | 判定 | 迁移 |
|---|---|---|
| `BaseOnly` | `global_gen=None` / `deltas=[]` | `ingest_delta` → `DeltaChain`；`ingest/compact` → 新 `BaseOnly` |
| `DeltaChain` | `global_gen.deltas` 非空 | `ingest_delta` 追加 delta；`compact_global` 或阈值 → 新 base `BaseOnly` |
| `Compacting` | `compact_global` 写新 base | 发布成功 → `BaseOnly`；失败 → 旧 head 不变，孤儿 base 待维护 GC |

不变量：查询必须读 `base + deltas` 全部代；`(seg_idx,row)` 直接按 manifest.segments 解析；缺 meta/part raise，不补 0；`ingest_delta` 自动 compact 失败不能向调用方报“未提交”。
