# Turbofish 执行计划输入：现状、约束与开放问题

> 读者：Astra（负责设计完整执行计划）。
> 目的：把当前代码、实测数据、已做决策、未决问题和硬约束集中到一处；不预设最终架构，尤其不预设“LSM/MergeTree 一定是 S3 最优”。
> 仓库：`/Users/huyan00/mycode/turbofish`
> 当前 HEAD：`0d59af1`（工作区干净）
> 相关文档：`docs/ARCHITECTURE.md`、`docs/STATE_MACHINES.md`、`docs/TURBOPUFFER.md`、`perf/RESULTS.md`

---

## 1. 目标与非目标

### 1.1 目标

做一个对象存储原生的检索系统，支持：

- 向量检索（IVF/PQ 可演进）
- BM25/全文检索
- 标量过滤
- 多租户 namespace
- 写入、更新、删除、compact
- 单机起步，可扩展到多查询节点
- 冷 namespace 接近零计算成本，数据主要放 S3

### 1.2 非目标（当前阶段）

- 不追求和 Turbopuffer 在 ≤1M docs 的价格战
- 不把 SSD 当数据缓存（用户明确否掉：公有云 SSD 写寿命撑不住）
- 不引入 Python 运行时到服务端
- 不以 Tokio/OpenDAL/Rust sidecar 作为默认方案
- 不先做跨区域复制、强一致多写者、完整 SQL

---

## 2. 用户部署模型（硬约束）

### 2.1 入门形态

一台机器同时跑：

- 元数据/管理节点
- 查询节点

数据放 S3。本地 RAM + SSD 只做很小的缓存，不做权威存储。S3 数据量 ≥ 本地缓存容量的 10 倍。

### 2.2 进阶形态

- 元数据/管理节点按 quota/load 动态拉起查询进程/VM
- 负载下降时回收
- 查询节点无状态：崩溃/被抢占不丢数据，冷启动只依赖 metad + S3

### 2.3 性能要求

- 尽量打满 I/O 和 CPU
- 不允许同步/阻塞代码卡住整个查询进程
- 允许 io_uring / 多路复用 / 异步 I/O
- 跨查询并发是必须的，不是“以后再说”
- compact 必须在后台，不阻塞查询

### 2.4 写路径要求

- LSM/merge-tree 风格：增量只写 delta
- 本地 batch buffer，按大小/时间阈值 flush 成一个 S3 object
- compaction 把多个 delta 重写成完整、紧凑的 segment
- 不允许长期保留“raw + 很多 delta”这种读放大结构
- 写入 buffer 必须和下层 merge tree 配合，不是独立组件

### 2.5 模拟器要求

- 能注入延迟、抖动、错误、价格
- 容量/成本决策主要靠模拟器，不靠反复起 MinIO
- 需要建模 CPU 服务时间、排队、并发上限、compact 抢占

---

## 3. 当前代码状态

### 3.1 目录与职责

| 路径 | 当前职责 | 状态 |
|---|---|---|
| `build/` | segment/global IVF/FTS 构建、`ingest`、`delete_docs`、`compact` | 单写路径的主实现 |
| `query/` | 向量/BM25/filter 查询、批预读 | 已接批量读 |
| `store/` | `ObjectStore` 同步 trait、`get_many`/`get_range_many` | 仍是同步接口 |
| `s3store/` | S3 请求构造、SigV4、`S3Store`、`MockS3Transport` | 同步，依赖 `HttpTransport` |
| `s3http/` | C/libcurl multi 的 `HttpTransport` | 仍在生产路径 |
| `s3client/` | 新：纯 MoonBit 异步 S3 client | 已通过测试，未接入 |
| `threadpool/` | 新：C pthread worker pool | 已通过测试，未接入 |
| `cmd/serve/` | HTTP API、查询/写入、后台 compact 调度 | 单进程、单 async event loop |
| `cmd/metad/` | 独立元数据 HTTP 服务，FsStore 本地 SSD | 已接入 serve |
| `fsstore/` | 本地文件系统 ObjectStore | 测试/本地模式 |
| `simstore/` | 确定性延迟/错误/价格模拟 | 无 CPU/队列模型 |
| `perf/` | Python 对比 harness、结果 | 仅开发用，不是服务端依赖 |

### 3.2 `cmd/serve` 当前实际行为

- 一个 OS 线程，一个 `moonbitlang/async` event loop。
- 查询、写入、后台 compact 共用这个 loop。
- `active_ns`、`seg_cache`、`doc_cache`、`doc_full_cache` 都是进程内内存 LRU。
- 写入只走 `@build.ingest` / `@build.ingest_delta_opts` / `@build.delete_docs`。
- `mtree` 双写已从 `cmd/serve` 删除；`_parts` 不再生成。
- 后台 compact 是脏 namespace FIFO 队列 + 每 tick 限额，调用 `@build.compact`；仍然同步执行，会阻塞查询。
- `AnyStore.get_many` 已批量：metad 批量 + S3 批量；S3 批量目前仍是 libcurl multi。
- 没有跨查询并发；所有请求共享一个 loop。

### 3.3 `cmd/metad`

- 独立 HTTP 服务，单线程 async。
- 元数据 key → 本地 `FsStore`。
- S3 是 durable truth；metad 只做元数据加速。
- 查询冷启动从 metad 读 manifest/segment meta，数据 shard 仍走 S3 range GET。

### 3.4 `s3client`（新）

- 纯 MoonBit，`@http.Client` 持久连接。
- 复用 `s3store.sigv4_sign_request`，不重写 SigV4。
- API：`get`、`get_range`、`put`、`put_if_match`、`delete`、`head_version`、`list`。
- 支持 Range、404/416、409/412、分页、429/5xx 重试。
- 端到端测试用本地 `@http.Server` 假 S3，真实 TCP。
- 限制：对象全量进内存；无 multipart；无流式；无 HTTP/2；TLS 仍走 OpenSSL。
- 未接入 `S3Store`，因为 `ObjectStore` 是同步 trait。

### 3.5 `threadpool`（新）

- 纯 C pthread + MoonBit FFI。
- 固定 N worker、有界环形队列、mutex + cond、pipe 完成通知。
- **不是 lock-free MPMC**；就是一把大锁。当前测试是 4 worker/1000 nop job。
- 设计边界：worker 只执行 C job，不执行 MoonBit 闭包，不持有 MoonBit 对象。
- 未接入任何生产路径。

---

## 4. 已做决策

1. **单一写路径**：`build` 是唯一写入/查询路径；`mtree` 不再在 `cmd/serve` 双写。
2. **compact 目标必须是查询实际读的 build segment**，不是 mtree 的 `_parts`。
3. **元数据与数据分离**：`metad` 独立；S3 是 durable truth。
4. **本地缓存只用内存 LRU**：不把 SSD 当数据缓存；默认面向“很多小 tenant”。
5. **批量读优先**：一个查询先收集 key，再 `get_many`，而不是逐 key `store.get`。
6. **进程隔离优先于线程共享**：MoonBit native 是 refcount/cycle GC，MoonBit 堆对象不能跨线程；多核用多进程，C threadpool 只跑 C job。
7. **不引入 Tokio/OpenDAL/Python/libcurl 作为目标依赖**：S3 访问层用 MoonBit async client；libcurl 是过渡。
8. **性能声明必须带条件**：数据集、recall、cache 状态、并发、durability 必须一起报。

---

## 5. 当前瓶颈（按优先级）

### P0-1 跨查询并发缺失

`cmd/serve` 只有一个 event loop。一个慢查询、一次大 batch、一次 compact 会卡住同进程所有请求。当前“批量并发”只解决单查询内部多个 GET，不解决多查询。

候选：

- 每核一个 `serve` 进程 + `SO_REUSEPORT`
- 或一个 manager 按负载拉起/回收 `serve`
- 或 C/Rust I/O sidecar；但用户不接受 Tokio 重量

### P0-2 compact 阻塞查询

`@build.compact` 是 MoonBit 代码，重写 live 段 + global IVF，执行期间占满 event loop。

候选：

- `cmd/compactd` 独立进程 + namespace lease
- 或者把 compact 拆成可中断的阶段，但仍然是 MoonBit 单线程，收益有限
- 不能直接丢进 C threadpool（MoonBit 堆不能跨线程）

### P0-3 写入还是请求级 ingest

`handle_write` 每次请求直接 `@build.ingest`，没有本地 batch buffer。小写入会产生大量 S3 PUT，写放大和成本都高。

需要设计：

- buffer 放内存还是本地 WAL？
- ack 语义：先 ack 后 flush 会丢；先 flush 后 ack 就没有批处理收益
- buffer 和 merge tree 的 delta 层如何对应
- flush 对象大小/时间阈值
- 崩溃恢复

### P0-4 `s3client` 未接入

`S3Store` 是同步 trait；`s3client` 是 async。需要决定：

- 把 `ObjectStore` 改成 async trait，查询/构建全链路 async 化
- 或者保留同步接口，用 C threadpool 跑阻塞 S3
- 或者做双接口，读路径 async、写路径批量同步

### P1 S3 数据结构是否最优未验证

当前是“不可变 segment + manifest + global IVF”。它接近 ClickHouse MergeTree 的不可变 part 思路，但不能假设这是 S3 最优：

- 对象数量 vs 单对象大小
- range GET 次数 vs 全量 GET
- 小 tenant 的固定开销
- manifest 增长
- compaction 写放大
- FTS/向量/列存是否应该分对象
- header/catalog 是否能一次 4–16 KB range GET 决定跳过

### P1 模拟器不建模 CPU/队列

`simstore` 目前主要是延迟/错误/价格；`concurrency` 只是 latency makespan，不是真实 worker/queue。无法回答：

- 4 核够不够
- compact 抢多少 CPU
- 多少 in-flight 最划算
- 读放大和 CPU 哪个先到瓶颈

### P1 线程池是否必要

当前 `threadpool` 不是 lock-free MPMC，就是一把大锁 + cond。对粗粒度 C job 够用；但 S3 已经 async，查询/compact 又不能跨线程，因此它现在没有主路径用途。

需要 Astra 明确：

- 保留为 C 阻塞 I/O/校验/压缩工具？
- 还是直接删掉，避免 dead code？
- 如果保留，是否改成每 worker 独立队列/工作窃取？不要为了“MPMC”而写高风险 lock-free。

---

## 6. 线程/进程模型（供 Astra 决策）

### 6.1 事实

- `moonbitlang/async` 是单线程协作式；用户代码只能用一个 CPU 核。
- MoonBit native runtime 是 refcount + cycle collector，未提供跨线程共享堆的同步。
- 现有 `runtime/thread_pool.c` 只跑 C job，不跑 MoonBit 闭包。
- 因此：
  - **MoonBit 查询/compact 多核 → 多进程**
  - **C I/O 工作线程 → 可以有，但只跑 C job**

### 6.2 候选形态 A：进程池（推荐起点）

```text
LB / SO_REUSEPORT
  ├─ serve #0  (MoonBit async, 1 loop)
  ├─ serve #1
  ├─ serve #2
  ├─ serve #3
  ├─ compactd  (MoonBit async, 独立进程)
  └─ metad     (元数据)
        └─ S3 durable truth
```

- 4 vCPU → 4 个 serve；32 核 → 32 个。
- 查询进程无状态，缓存只是每进程小 LRU。
- 写入按 namespace 路由到唯一 writer，或用 `_head_ptr` CAS + retry。
- compactd 通过 lease 拿 namespace，不阻塞查询。

### 6.3 候选形态 B：单进程多线程

- 需要给每个线程独立 MoonBit runtime/GC，或改 runtime 支持共享堆。
- 这是 runtime 级工程，不是业务代码。
- 除非 Astra 认为必须，否则不作为第一版。

### 6.4 候选形态 C：I/O sidecar

- C/Rust 进程做 S3 读写，MoonBit 只做计算。
- 用户否掉 Tokio；C sidecar 可行但增加进程间协议。
- 如果 `s3client` 的 async 性能不够，再考虑。

---

## 7. 写入 buffer 与 merge tree：需要 Astra 设计的部分

### 7.1 当前事实

- `build` 有 segment/global IVF/manifest；`compact` 能重写 live 段。
- 没有 L0/L1 分层，也没有本地 batch buffer。
- `ingest` 是请求级调用。
- `mtree` 包还有 write-back buffer 代码，但 `cmd/serve` 已不再使用。

### 7.2 需要回答

1. buffer 的数据结构：按 namespace 的 doc 队列？按 shard？
2. flush 触发：大小、时间、手动、查询前强制？
3. flush 产物：一个 delta segment object？还是 L0 文件 + manifest？
4. 读路径如何合并：manifest 里 L0 delta 列表 + base segment；查询时 merge？
5. 何时 compact：L0 数量、删除比例、读放大阈值、空闲窗口？
6. 崩溃一致性：
   - 写 buffer 未 flush 就 crash，已 ack 的写是否允许丢？
   - 如果不允许，buffer 必须先落 WAL；WAL 放哪？本地 SSD 写寿命是否可接受？
   - 或者 ack 必须等 S3 flush，牺牲批处理延迟。
7. 多 writer：namespace lease 还是单 writer 进程？
8. 读己之写：查询进程如何看到尚未 compact 的 buffer？
9. 写放大 vs 读放大：delta 层数上限、单对象目标大小（64 MB? 256 MB?）
10. 小 tenant：共享 segment + tenant_id + zone map，还是每 tenant 独立 segment？

### 7.3 不要预设

- ClickHouse 用 MergeTree，不代表 S3 上最优；ClickHouse 的 part 合并假设本地磁盘和后台线程模型。
- LSM 的“多 level + 后台 compaction”在 S3 上可能被 PUT 成本和 manifest 读放大反噬。
- 需要比较：
  - 不可变 packed segment + 少量 delta
  - 纯 LSM level
  - 单文件 copy-on-write
  - 列/向量/FTS 分对象 vs 合对象
  - 小对象合并（pack many small tenants into one object）

---

## 8. S3 访问层现状与待决

### 8.1 当前两条路

- `s3http`：C/libcurl multi。批量并发、连接复用；但同步 FFI 会卡 event loop，依赖重。
- `s3client`：纯 MoonBit async。无 libcurl；连接池/重试/Range/CAS 已有；未接 `S3Store`。

### 8.2 需要决定

- `ObjectStore` 是否 async 化？影响 build/query/compact 全链路。
- 如果 async 化，是否保留同步 `ObjectStore` 给 CLI/测试？
- 大对象流式读写：当前 `s3client` 全量进内存，segment 可能几百 MB。
- multipart upload、checksum、region redirect、HTTP/2 是否第一版需要？
- TLS：`@async/tls` 仍用 OpenSSL；用户接受“去 libcurl”，但不等于“零 native 依赖”。

---

## 9. 模拟器需要补的模型

当前 `simstore` 有：

- S3 GET/PUT 首字节延迟、对数正态抖动、带宽
- NVMe 读延迟、内存访问
- WAN jitter、spike、retry、错误概率
- 价格计费

缺：

- CPU 服务时间（向量距离、BM25、decode）
- worker/queue 模型（并发请求排队）
- compact 与查询争抢 CPU/IO
- 每进程 event loop 的阻塞
- 多进程/多租户调度
- S3 请求的 connection pool 上限

Astra 需要给出：

- 模拟器输入/输出契约
- 用哪些参数做容量决策
- 如何用真实小规模实验校准
- 何时必须上真实 MinIO/S3 验证

---

## 10. 已有实测数据（仅作基线，不作承诺）

来自 `perf/RESULTS.md` / `docs/TURBOPUFFER.md`：

- 数据集：50k docs，128d，recall≈0.945
- 冷查询 S3 GET：422 → 31（加入 metad + 批量预读后）
- 冷首查询直连：558 ms → 38.3 ms
- 冷首查询 toxiproxy（50 ms ±20 ms）：23.1 s → 180 ms
- warm p50：Turbofish 0.660 ms / Qdrant 2.009 ms
- warm QPS：Turbofish 1205 / Qdrant 473
- ingest：Qdrant 4.0 s / Turbofish 53.1 s
- 存储：Turbofish 282 MB/3828 objects / Qdrant 72 MB
- RSS：Turbofish ~48 MB / Qdrant 207 MB

限制：

- 50k 不是大规模；recall 不是 1.0；cache 状态/并发已固定但和 turbopuffer 官方口径不完全可比。
- Turbopuffer 没有 API key，未做同规模真实对比。
- 这些数字不能支持“全面优于 Qdrant/Turbopuffer”的结论。

---

## 11. 建议 Astra 输出的执行计划内容

1. 最终进程/线程模型（含每核绑核、SO_REUSEPORT、manager/lease）
2. `ObjectStore` 是否 async 化；`s3client` 接入路径
3. `compactd` 进程边界、lease、调度、失败恢复
4. 写 buffer + merge tree 的数据结构与不变量
5. S3 对象布局（segment/列/FTS/向量/manifest/catalog）与对象大小策略
6. 小 tenant 经济学：共享 segment / zone map / 固定开销
7. 模拟器模型与校准方法
8. 里程碑（每步可验收）与回滚点
9. benchmark 矩阵：数据集、recall、cache、并发、durability、价格
10. 明确“不做什么”

---

## 12. 需要 Astra 明确回答的问题

1. 查询并发用“每核一个进程”还是“单进程多 runtime”？为什么？
2. `threadpool` 保留还是删除？如果保留，是否值得从一把大锁升级？
3. `ObjectStore` async 化，还是保留同步 + C I/O 线程池？哪条迁移成本更低？
4. 写 buffer 的 ack 语义：允许丢未 flush 的写吗？不允许的话 WAL 放哪？
5. L0/delta 层数上限、flush 大小/时间、compact 触发条件？
6. S3 上单个 segment 的目标大小？小 tenant 是否合并？
7. 读路径如何合并 base + delta，如何保证 read-your-writes？
8. compactd 如何拿 lease、如何避免和 writer 冲突、失败后如何恢复？
9. manifest/catalog 是否需要独立的小对象/range GET 快路径？
10. 模拟器先建模哪些量，哪些必须真实集群校准？
11. 第一阶段先做哪条端到端链路，能在一周内得到可验收结果？
12. 哪些当前代码要删除/重写，哪些可以保留？

---

## 13. 关键文件索引

- `cmd/serve/main.mbt`：HTTP API、AnyStore、查询/写入、dirty queue、LRU
- `cmd/serve/branch.mbt`：branch 逻辑
- `build/compact.mbt`：`@build.compact`
- `build/segment.mbt`：segment 写读
- `build/build.mbt`：`ingest`
- `query/query.mbt`、`query/vecq.mbt`、`query/bm25.mbt`
- `store/store.mbt`：同步 `ObjectStore`
- `s3store/s3store.mbt`：S3 请求与 `S3Store`
- `s3client/client.mbt`：新 async S3 client
- `threadpool/tp.c`：C pthread pool
- `cmd/metad/main.mbt`：元数据服务
- `simstore/simstore.mbt`：模拟器
- `perf/RESULTS.md`：实测结果与 caveat
- `docs/ARCHITECTURE.md`：现有架构白皮书
- `docs/STATE_MACHINES.md`：状态机与不变量
