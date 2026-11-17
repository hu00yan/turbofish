# CONTROL_PLANE.md：单机内存 + NVMe 的元数据控制面设计

> 目标：在“S3 是唯一 durable source of truth”的前提下，把 namespace/segment
> 元数据、FTS dir、doc_len、centroids、tombstone、向量分区索引放在**同一台机器的
> 内存 + NVMe** 上，避免每查询回 S3 读元数据。先做单机，跨机共享留作后续。

## 0. 现状与差距

- 已有 `query.MetadataCache` + `open_cached`：进程内缓存 `Namespace`，每次只
  GET 一次 `namespace.json` 检查 head；head 未变则零 manifest/segment 读。
  一次 10 查询的测试中，请求数从 272 降到 83（-69%）。
- 已实现单机 `cmd/metad`：`cmd/serve` 在写路径把 namespace / manifest /
  segment meta / 行属性列 / centroids / tombstone / global IVF meta 镜像到
  本机 SSD（`fsstore`），查询冷启动从 `metad` 读，不再走 S3。可用
  `SPND_META_PREFIX` 让多个 bucket 共享一个 metad 进程。
- 但还缺：
  - head 变化仍靠 `open_cached` 的 `namespace.json` TTL 探测；需要轮询/推送。
  - 大 metadata（dir/doc_len）没有按字节的独立 LRU；metad 依赖文件系统。
  - 多节点没有共享；`metad` 是单机进程，跨机需每机部署或加复制。
  - metad 进程重启后的冷启动会回源 S3；尚未做启动时预热/快照。
  - `SPND_META_DIR` 是整个 metad 的唯一副本，**不是权威数据**：S3 仍是唯一
    真相（写路径先条件写 S3，再镜像 metad）。删掉这个目录不会丢数据，但会让
    冷查询退回到对象存储路径——实测 `cmd/bench1m` 无 metad 时 bm25 冷查询
    **303 GET/q、306 KB/q、$121/1M 查询**，有 metad 时 1.55 GET/q。
    目前没有 `metad --rebuild` 之类的重建入口，只能靠后续写入重新镜像，
    这条要补，否则运维不敢删这个目录、也不敢把它当缓存看。

## 1. 状态分层

| 层 | 内容 | 生命周期 | 失败影响 |
|---|---|---|---|
| S3 | manifest、segment objects、postings、vectors、tombstones | 永久（唯一真相） | 不可用则只读旧快照 |
| 内存 | namespace head、manifest、seg meta、centroids、fts dir、doc_len、tombstone set、global cids | 进程生命周期 | 重启后从 NVMe/S3 恢复 |
| NVMe | 上述 metadata 的快照 + 大对象块缓存（postings/vector/column blocks） | 跨重启（LRU） | 丢失只影响冷启动 |
| 远端查询节点 | 只持有当前 manifest 快照和必要的 S3 range | 查询生命周期 | 回退到 S3 |

原则：**S3 不存“服务状态”**；head 指针是唯一的可变对象，用 CAS 发布；其余对象
不可变、按 manifest id 分代。

## 2. 单机进程模型

```
            ┌─────────────────────────────┐
 query ───▶ │  metad (single process)     │
            │  memory cache + NVMe cache  │
            │  head watcher / publisher   │
            └─────────────┬───────────────┘
                          │ GET/HEAD (revalidate)
                          ▼
                        S3 / MinIO
```

- 一台机器一个 `metad`（或库形态嵌在查询进程里）；同机所有查询共享。
- `metad` 只做 metadata + 小对象；大 postings/vector 仍由查询节点按 manifest
  快照直接 S3 range GET（可命中本机 NVMe block cache）。
- 单机部署简单；跨机时每台机器各自跑 `metad`，靠 head 轮询/推送保持最终一致。

## 3. 内存数据结构

```moonbit
struct NsEntry {
  ns : String
  head_manifest : String          // 最近一次确认的 S3 head
  manifest : ManifestData
  segments : Map[String, CachedSeg] // 现有 query.CachedSeg
  centroids : Centroids?
  tombstones : Set[UInt64]?
  global_cids : Array[Int]?
  last_checked_ms : Int64
  refcount : Int                  // 正在使用的查询快照
}
```

- 以 `manifest.id` 为不可变快照 key；同一 namespace 可同时保留新旧两个快照
  （旧查询 pin 住，新查询用新 head）。
- `CachedSeg` 复用现有 query 实现（dir/doc_len/id/matcher/blockmax/PQ codebook）。
- 大 metadata 用独立 LRU（按字节 budget），小 metadata 常驻。

## 4. NVMe 布局

```
{root}/{store_id}/{ns}/
  head.json                     # {"head":"manifest-...","checked_at":...}
  manifest/{manifest_id}.json
  seg/{seg_id}/meta.json
  seg/{seg_id}/fts_dir.bin
  seg/{seg_id}/doc_len.bin
  centroids/{version}.bin
  tombstones/{manifest_id}.roar
  global/{manifest_id}/meta.json
  global/{manifest_id}/part-{cid}.bin
  blocks/{key_hash}/{offset}-{len}   # postings/column/vector 块缓存
  lru.json                       # 或 sidecar 索引
```

- metadata 用明文对象直接落盘（key 路径化）；大块用 `key_hash` 避免路径过长。
- 写 NVMe 用“临时文件 + rename”保证原子；`head.json` 最后写。
- 启动恢复：读 `head.json`/manifest 快照，向 S3 `HEAD namespace.json` 或
  `GET If-None-Match` 校验；不一致则重新拉取。S3 不可用时可服务旧快照（标记 stale）。
- NVMe 缓存是 **cache**，不是 WAL；丢失不影响正确性，只影响冷启动。

## 5. 读路径

```
get(ns):
  e = memory.get(ns)
  if e and now - e.last_checked < TTL: return e
  head = S3 GET/HEAD namespace.json
  if head == e.head_manifest:
     e.last_checked = now; return e
  else:
     m = S3 GET manifest;  // 只拉 manifest
     e2 = build entry from NVMe/S3 (seg meta/dir/doc_len/centroids)
     memory.put(ns, e2); nvme.write(...)
     return e2
```

- `TTL` 可配（例如 1s~5s）；写路径可通过 RPC 主动 `invalidate(ns)`，把 TTL 降到 0。
- 首次打开：从 S3 拉 manifest + 段元数据；小对象并行拉取（单机可用线程池）。
- 查询只拿 `manifest_id` 快照；大对象由查询节点按快照读 S3，不经过 `metad`。

## 6. 写路径与失效

```
writer: 写新 segment objects → CAS publish head (S3 If-Match)
        → 成功后 RPC notify(metad, ns, new_head)
metad:  若 RPC 到，立即 reload；否则 TTL 轮询发现
```

- 写者仍是“S3 CAS 发布”，不依赖 `metad` 做一致性；`metad` 只是加速读。
- CAS 冲突：写者重读 head 仲裁（现有 `publish_head_expect`）。
- 旧 manifest 快照：查询 pin 住；refcount 归零后按 TTL/GC 删除 NVMe 旧代。
- health：`metad` 不可用时查询回退到 `query.open`（直接 S3），功能降级不中断。

## 7. 指标

- `metadata_hit_rate`、`s3_metadata_gets_saved`、`head_check_latency`、
  `cache_bytes`、`evictions`、`stale_age`、`reload_count`。
- 目标：稳态下每查询 0 次 metadata S3 GET；head 变化后 ≤1 次 manifest GET。

## 8. 与现有代码的映射

| 设计 | 现有实现 |
|---|---|
| 内存 NsEntry | `query.Namespace` + `MetadataCache` |
| per-segment 解码缓存 | `query.CachedSeg` |
| head 检查 | `open_cached` 内 `GET namespace.json` |
| tombstone | `tombstones_of` + roaring |
| 全局 IVF 索引 | `ensure_global_cids` + `vec_global_search` |
| NVMe 落盘 | `cmd/metad` + `fsstore`（native），写路径镜像、查询路径读取 |
| 写通知 | 待实现：RPC / 文件 watch；先 TTL 轮询 |

## 9. 单机落地顺序

1. ~~`DiskCache`（native，基于 fsstore）：metadata 快照~~ → 已由 `cmd/metad`
   覆盖；下一步是加按字节的 LRU 和启动预热。
2. 加 head watcher（TTL + 可选 inotify/RPC），减少每查询的 head 探测。
3. bench：`open` vs `open_cached` vs `open_cached+metad` 的请求/延迟/命中率。
4. 再考虑跨机共享（lease/fencing、head 推送、快照 GC）。

## 10. 非目标

- 不做传统数据库/事务；不把索引放进本地 DB。
- 不改变“S3 是唯一 durable source of truth”。
- 单机方案不承诺跨机强一致；跨机只保证最终一致 + 有界 stale。
