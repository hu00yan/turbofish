// build/cutover.mbt: IVF 自适应重分区（cutover）——`nlist` 随 N 增长，
// 每查询读取字节不随 N 线性膨胀。
//
// 问题：`nlist` 在首次建 namespace 时训练一次即冻结（build_ingest_base /
// ingest_l0_slab 之后恒复用头 manifest 钉住的 centroid_version），数据涨
// 10 倍时每查询读的字节涨 ~10 倍（50k→500k 冷 vec 实测 1717→20,226 KB/q）。
//
// 本文件实现「重分区事件」（cutover）：
// 1. `target_rows_for(n_docs, dim, nprobe)`：目标簇行数 TARGET_ROWS 的纯函数
//    初值，`clamp(round(sqrt(N × net_Bps / (nprobe × bytes_per_row × flops))),
//    256, 1024)`，其中 bytes_per_row = dim × bytes_per_dim（f16 = 2 B/维）；
// 2. `maybe_cutover`：当 `num_docs / cent.k() > 2 × TARGET_ROWS` 时触发一次
//    全量重分区——以 `nlist' = ceil(num_docs / TARGET_ROWS)` 重训中心（落成
//    新 centroid_version），把全部 live 段按新中心重写成新 slab 段，乐观
//    rebase 发布新 manifest（CAS 冲突整体重试 ≤ 5 次，重试期间复用已上传
//    的段、绝不重传大段），旧段进入 superseded 段 GC 的 grace 回收；
// 3. cutover 期间落地的尾巴批（按旧中心分区）在发布前一并按新中心重写，
//    保证任何已发布 manifest 的 `centroid_version` 与全部段分区一致——
//    不存在「一半段旧中心、一半段新中心」的 manifest。
//
// 读路径（query/）不感知 cutover：段内 `vec/part-{c}` 分区的语义不变，
// 只是 cid 空间随 centroid_version 增大。

///|
/// TARGET_ROWS 公式常量：网络带宽 1.25e8 B/s（1Gbps）。
pub const TARGET_NET_BPS : Double = 1.25e8

///|
/// TARGET_ROWS 公式常量：f16 每维 2 字节（bytes_per_dim）。
pub const TARGET_BYTES_PER_DIM : Double = 2.0

///|
/// TARGET_ROWS 公式常量：计算速率 1e10 flop/s。
pub const TARGET_FLOPS : Double = 1.0e10

///|
/// TARGET_ROWS 夹紧下界（同时是 rows/blockstats 的块行数量级）。
pub const TARGET_ROWS_MIN : Int = 256

///|
/// TARGET_ROWS 夹紧上界。
pub const TARGET_ROWS_MAX : Int = 1024

///|
/// cutover 触发/取值公式的 nprobe 口径（判据口径 nprobe=3）。
pub const CUTOVER_NPROBE : Int = 3

///|
/// cutover 触发阈值倍数：`num_docs / cent.k() > CUTOVER_TRIGGER_FACTOR × TARGET_ROWS`。
pub const CUTOVER_TRIGGER_FACTOR : Int = 2

///|
/// 乐观 rebase 最大尝试次数（与 `compact_optimistic` 的 CAS 重试上限一致）。
pub const CUTOVER_MAX_TRIES : Int = 5

///|
/// 目标簇行数 TARGET_ROWS（纯函数）：
/// `clamp(round(sqrt(N × net_Bps / (nprobe × bytes_per_row × flops))), 256, 1024)`，
/// 其中 `bytes_per_row = dim × bytes_per_dim`（f16 = 2 B/维，即公式里的
/// bytes_per_dim 按行折算）。n_docs / dim / nprobe 非正时回落下界。
///
/// 量纲直觉：把「全库一次顺序读的秒数」与「probe 面上的每行计算秒数」放进
/// 同一开销模型后对簇行数求极值；夹紧保证簇行数落在块 IO 友好的
/// [256, 1024] 区间。50k/500k × 128 维、nprobe=3 都落在下界 256。
pub fn target_rows_for(n_docs : Int, dim : Int, nprobe : Int) -> Int {
  if n_docs <= 0 || dim <= 0 || nprobe <= 0 {
    return TARGET_ROWS_MIN
  }
  let bytes_per_row = dim.to_double() * TARGET_BYTES_PER_DIM
  let x = n_docs.to_double() * TARGET_NET_BPS /
    (nprobe.to_double() * bytes_per_row * TARGET_FLOPS)
  let r = if x <= 0.0 {
    0.0
  } else {
    // round half up：floor(x + 0.5)（x ≥ 0）
    (x.sqrt() + 0.5).floor()
  }
  if r < TARGET_ROWS_MIN.to_double() {
    TARGET_ROWS_MIN
  } else if r > TARGET_ROWS_MAX.to_double() {
    TARGET_ROWS_MAX
  } else {
    r.to_int()
  }
}

///|
/// cutover 的目标簇行数：`cfg.target_rows > 0` 用 BuildConfig 覆盖值（测试 /
/// 调优），否则按公式 `target_rows_for(num_docs, dim, nprobe)` 取初值。
pub fn cutover_target_rows(
  cfg : BuildConfig,
  num_docs : Int,
  dim : Int,
  nprobe? : Int = CUTOVER_NPROBE,
) -> Int {
  if cfg.target_rows > 0 {
    cfg.target_rows
  } else {
    target_rows_for(
      num_docs, dim, if nprobe > 0 { nprobe } else { CUTOVER_NPROBE },
    )
  }
}

///|
/// 一次 cutover（IVF 全量重分区）的观测明细：批计量（PUT/行数/耗时由调用方
/// 在 maybe_cutover 外围取快照）之外的口径都在这里。
#derive(Debug)
pub(all) struct CutoverOutcome {
  head : String // 发布后的 head manifest id
  centroid_version : String // 新中心版本（新 manifest 的唯一 centroid_version）
  nlist_old : Int
  nlist_new : Int
  target_rows : Int // 本次使用的 TARGET_ROWS
  rows : Int // 重写行数（剔除墓碑后的 live 行）
  segs_in : Int // 快照段数（被本次重分区替换掉的段）
  segs_out : Int // 重写后的段数（= 新 manifest 的段数）
  centroid_bytes : Int // 新中心表对象字节数
  uploads : Int // 新上传 slab 段数（重试期间不重复上传，缓存命中不计）
  attempts : Int // 乐观 rebase 尝试次数（≤ CUTOVER_MAX_TRIES）
  superseded : Array[String] // 被替换掉的旧段 id（GC 判定前的候选）
  gc_deleted : Int // 本轮 superseded 段 GC 回收的段目录数
  gc_kept_in_grace : Int // grace 窗口内保留的旧段数
}

///|
/// 读一个段的全部行并剔除墓碑行（cutover 物理化 tombstone：被删行不进入
/// 重写后的段；manifest 的 deleted 原样继承，未物理化的删除仍被过滤）。
async fn[S : @store.ObjectStore] load_live_rows(
  store : S,
  ns : String,
  seg : @format.SegmentMeta,
  tomb : Set[UInt64],
) -> Array[@core.Doc] {
  let all = load_segment_docs(store, ns, seg, None, 0)
  if tomb.is_empty() {
    return all
  }
  let out : Array[@core.Doc] = Array()
  for d in all {
    if !tomb.contains(d.id) {
      out.push(d)
    }
  }
  out
}

///|
/// 把一批行按新中心重写成 slab 段（每段 cfg.segment_rows 行，与
/// `build_ingest_base` 的切段口径一致），逐段上传 slab + meta.json。
/// 返回新段元数据（顺序 = docs 顺序）。
async fn[S : @store.ObjectStore] cutover_rewrite(
  store : S,
  cfg : BuildConfig,
  cent : @format.Centroids,
  docs : Array[@core.Doc],
) -> Array[@format.SegmentMeta] {
  let out : Array[@format.SegmentMeta] = Array()
  let n = docs.length()
  if n == 0 {
    return out
  }
  // 按 id 升序：块在 id 连续时稠密（dense_u64，读侧免 id 列）。
  sort_docs_by_id(docs)
  let step = if cfg.segment_rows > 0 && cfg.segment_rows < n {
    cfg.segment_rows
  } else {
    n
  }
  let mut start = 0
  while start < n {
    let end = if start + step < n { start + step } else { n }
    let seg_id = new_slab_segment_id()
    let (slab_bytes, meta_bytes, meta) = build_segment_slab(
      cfg, cent, docs, start, end, seg_id~,
    )
    store.put_many([
      (segment_slab_key(cfg.ns, seg_id), slab_bytes),
      (segment_meta_key(cfg.ns, seg_id), meta_bytes),
    ])
    out.push(meta)
    start = end
  }
  out
}

///|
/// 重分区事件（cutover）：`num_docs / cent.k() > 2 × TARGET_ROWS` 时把全部
/// live 段按 `nlist' = ceil(num_docs / TARGET_ROWS)` 的新中心重写并乐观
/// rebase 发布。不满足触发条件（或无可重写数据）返回 None。
///
/// 并发安全（与 `compact_optimistic` 同一套乐观 rebase 语义）：
/// - 新中心对象只上传一次；重写段按「源段 id → 新段元数据」缓存，CAS 冲突
///   整体重试（≤ CUTOVER_MAX_TRIES 次）期间**不重复上传**任何已上传大段；
/// - 每次尝试重读当前 head，把快照之后落地的尾巴批（按旧中心分区）现场按
///   新中心重写后再发布 ⇒ 发布的 manifest 里所有段都由同一个
///   centroid_version（新中心）分区，不存在新旧中心混用；
/// - 发布成功后跑一次 superseded 段 GC（grace 窗口内旧段保留，在途读者
///   安全），旧段进入 grace 回收。
///
/// 墓碑：重写时物理化（被删行不落进新段）；manifest 的 deleted / deleted_roar
/// 原样继承当前 head（并发新删除落在缓存段行域内时仍被过滤，语义不丢）。
pub async fn[S : @store.ObjectStore] maybe_cutover(
  store : S,
  cfg : BuildConfig,
  nprobe? : Int = CUTOVER_NPROBE,
) -> CutoverOutcome? {
  let ns = cfg.ns
  let meta0 = match read_namespace(store, ns) {
    Some(m) => m
    None => return None
  }
  if meta0.head_manifest == "" {
    return None
  }
  let m0 = load_manifest(store, ns, meta0.head_manifest)
  let cent0 = load_centroids(store, ns, m0.centroid_version)
  if cent0.dim <= 0 {
    return None
  }
  let k0 = cent0.k()
  if k0 <= 0 || m0.num_docs <= 0 {
    return None
  }
  let dim = if cent0.dim > 0 { cent0.dim } else { cfg.vector_dim }
  let target = cutover_target_rows(cfg, m0.num_docs, dim, nprobe=nprobe)
  // 触发条件：num_docs / cent.k() > 2 × TARGET_ROWS
  if m0.num_docs.to_double() / k0.to_double() <=
    (CUTOVER_TRIGGER_FACTOR * target).to_double() {
    return None
  }
  let nlist_new = (m0.num_docs + target - 1) / target
  if nlist_new <= 0 {
    return None
  }
  // 1) 读出快照内全部 live 行（按源段分组）：既用于重训中心，也用于重写。
  let tomb0 : Set[UInt64] = Set([])
  for d in m0.deleted {
    tomb0.add(d)
  }
  let src_docs : Map[String, Array[@core.Doc]] = Map([])
  let all : Array[@core.Doc] = Array()
  for s in m0.segments {
    let live = load_live_rows(store, ns, s, tomb0)
    src_docs.set(s.id, live)
    for d in live {
      all.push(d)
    }
  }
  if all.is_empty() {
    return None
  }
  // 2) 重训中心（新 centroid_version，只上传一次）。
  let cent_new = train_centroids(all, nlist_new, 8, cfg.distance_metric == "euclidean")
  if cent_new.dim <= 0 || cent_new.k() <= 0 {
    return None
  }
  let cv = new_centroid_version()
  let cb = @format.encode_centroids(cent_new)
  store.put(centroids_key(ns, cv), cb)
  // 3) 乐观 rebase：重读 head → 重写未处理源（含尾巴批）→ CAS 发布；
  //    冲突整体重试（≤ 5 次），已重写源走缓存、绝不重传。
  let cache : Map[String, Array[@format.SegmentMeta]] = Map([])
  let mut uploads = 0
  let mut attempts = 0
  let mut result : String? = None
  let mut out_rows = 0
  let mut out_segs = 0
  while attempts < CUTOVER_MAX_TRIES && result is None {
    attempts += 1
    let meta_curr = match read_namespace(store, ns) {
      Some(m) => m
      None => return None
    }
    if meta_curr.head_manifest == "" {
      return None
    }
    let m_curr = load_manifest(store, ns, meta_curr.head_manifest)
    let tomb : Set[UInt64] = Set([])
    for d in m_curr.deleted {
      tomb.add(d)
    }
    let next_segs : Array[@format.SegmentMeta] = Array()
    for s in m_curr.segments {
      match cache.get(s.id) {
        Some(metas) =>
          for m in metas {
            next_segs.push(m)
          }
        None => {
          // 快照源用拍快照时滤过墓碑的行；快照之后落地的尾巴批在这里现场
          // 按新中心重写（发布前完成 ⇒ 不会留下旧中心分区的段）。
          let docs = match src_docs.get(s.id) {
            Some(ds) => ds
            None => load_live_rows(store, ns, s, tomb)
          }
          let metas = cutover_rewrite(store, cfg, cent_new, docs)
          uploads += metas.length()
          cache.set(s.id, metas)
          for m in metas {
            next_segs.push(m)
          }
        }
      }
    }
    let mut total_rows = 0
    let mut total_doclen = 0
    for s in next_segs {
      total_rows += s.row_count
      total_doclen += s.doc_len_sum
    }
    let avg_doc_len = if total_rows > 0 {
      total_doclen.to_double() / total_rows.to_double()
    } else {
      0.0
    }
    let new_id = new_manifest_id()
    let manifest : @format.ManifestData = {
      id: new_id,
      parent: Some(m_curr.id),
      segments: next_segs,
      // 墓碑原样继承：重写已物理化快照内被删行，但并发新删除（可能落在
      // 缓存段的行域内）必须继续被过滤，删除语义不丢。
      deleted: m_curr.deleted,
      deleted_roar: m_curr.deleted_roar,
      // 全局代际链已停写（Step 1）：与 ingest_l0_slab / compact_optimistic 一致。
      vec_global_version: None,
      global_gen: None,
      centroid_version: cv,
      num_docs: total_rows,
      avg_doc_len,
    }
    store.put(manifest_key(ns, new_id), json_bytes(manifest.to_json()))
    let published = try {
      publish_head(store, ns, m_curr.id, new_id)
      true
    } catch {
      _ => false
    }
    if published {
      result = Some(new_id)
      out_rows = total_rows
      out_segs = next_segs.length()
    }
  }
  let head = match result {
    Some(h) => h
    None => return None
  }
  // 4) 旧段进入 grace 回收（被替换掉的段在 grace 窗口后物理删除）。
  let superseded : Array[String] = Array()
  for s in m0.segments {
    superseded.push(s.id)
  }
  let stat = gc_superseded_segments(store, ns)
  Some({
    head,
    centroid_version: cv,
    nlist_old: k0,
    nlist_new: cent_new.k(),
    target_rows: target,
    rows: out_rows,
    segs_in: m0.segments.length(),
    segs_out: out_segs,
    centroid_bytes: cb.length(),
    uploads,
    attempts,
    superseded,
    gc_deleted: stat.deleted,
    gc_kept_in_grace: stat.kept_in_grace,
  })
}

///|
/// 中心表对象字节数（观测用：报告 nlist/中心表大小）；对象缺失返回 0。
pub async fn[S : @store.ObjectStore] centroid_table_bytes(
  store : S,
  ns : String,
  centroid_version : String,
) -> Int {
  match store.get(centroids_key(ns, centroid_version)) {
    Some(bs) => bs.length()
    None => 0
  }
}

///|
pub extend CutoverOutcome with Debug::{to_repr}
