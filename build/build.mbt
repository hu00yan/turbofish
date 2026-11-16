// build 包：写路径 —— segment 构建、kmeans 训练、ingest、tombstone。
// 公开 API（BuildConfig / ingest / delete_docs / train_centroids）由 query 与 bench 共用。
// 对象 key 构造、JSON IO、CAS 发布在 segment.mbt；kmeans 在 kmeans.mbt。

///|
/// 向量存储方式：VF16 由 use_f16 决定 f16/f32，
/// VSq8 用 SQ8 量化向量列 + 分区，VPq16 分区用 PQ16（向量列仍存 f16/f32
/// 供精排/暴力对照）。
#derive(Debug, Eq)
pub(all) enum VecStorage {
  VF16
  VSq8
  VPq16
}


///|
/// 构建配置。所有可选编码开关默认关闭，保持与旧数据兼容。
pub(all) struct BuildConfig {
  ns : String
  segment_rows : Int // 每 N 行一个 segment
  nlist : Int // IVF 中心数
  use_f16 : Bool
  vector_dim : Int
  write_stats : Bool // seg meta.json 附 ts/category/public 统计
  id_dense : Bool // id 恰为 min_id+行号时写 id_encoding=dense_u64
  use_dict_cols : Bool // category 列字典编码（text 始终普通列）
  use_bool_bitmap : Bool // public 列位图编码
  vec_storage : VecStorage // 向量存储/量化方式
  write_blockmax : Bool // 写 fts/blockmax.bin（WAND 块跳过）
  normalize_vecs : Bool // 写入前把向量 L2 归一化（IVF 扫描 cosine→dot）
  write_block_stats : Bool // 写 rows/blockstats.bin（256 行 ts min/max）
  global_vec_parts : Bool // 写 namespace 级全局 IVF 分区（跨 segment 合并）
  write_fts_bloom : Bool // seg meta 内嵌 FTS term Bloom（跳过不可能命中的段）
  global_pack_size : Int // 全局分区分包：>1 时相邻 cid 打包成 pack-{i}.bin（1 = 每 cid 一对象）
  fts_tokenizer : @core.Tokenizer // 全文分词器（默认 Word = 旧行为；CJK 命名空间选 smartcn/kuromoji/nori）
  distance_metric : String // "cosine"（默认，写入归一化）| "euclidean"（l2sq，不归一化）
}

///|
/// 默认：segment_rows=2000, nlist=64, use_f16=true, vector_dim=768，
/// 其余新开关 false / VF16。
pub fn BuildConfig::default(ns : String) -> BuildConfig {
  {
    ns,
    segment_rows: 2000,
    nlist: 64,
    use_f16: true,
    vector_dim: 768,
    write_stats: false,
    id_dense: false,
    use_dict_cols: false,
    use_bool_bitmap: false,
    vec_storage: VF16,
    write_blockmax: false,
    normalize_vecs: false,
    write_block_stats: false,
    global_vec_parts: false,
    write_fts_bloom: true,
    global_pack_size: 1,
    fts_tokenizer: @core.Word,
    distance_metric: "cosine",
  }
}

///|
/// 函数式更新：开启/关闭 seg meta 统计。
pub fn BuildConfig::with_stats(self : BuildConfig, v : Bool) -> BuildConfig {
  { ..self, write_stats: v }
}

///|
/// 函数式更新：开启/关闭 dense id 编码标记。
pub fn BuildConfig::with_id_dense(self : BuildConfig, v : Bool) -> BuildConfig {
  { ..self, id_dense: v }
}

///|
/// 函数式更新：category 列是否字典编码。
pub fn BuildConfig::with_dict_cols(self : BuildConfig, v : Bool) -> BuildConfig {
  { ..self, use_dict_cols: v }
}

///|
/// 函数式更新：public 列是否位图编码。
pub fn BuildConfig::with_bool_bitmap(
  self : BuildConfig,
  v : Bool,
) -> BuildConfig {
  { ..self, use_bool_bitmap: v }
}

///|
/// 函数式更新：向量存储方式。
pub fn BuildConfig::with_vec_storage(
  self : BuildConfig,
  v : VecStorage,
) -> BuildConfig {
  { ..self, vec_storage: v }
}

///|
/// 函数式更新：是否写 block-max 索引。
pub fn BuildConfig::with_blockmax(self : BuildConfig, v : Bool) -> BuildConfig {
  { ..self, write_blockmax: v }
}

///|
/// 函数式更新：写入前是否把向量 L2 归一化（IVF 扫描时 cosine = dot，
/// 省掉每个候选的两次 norm 计算）。
pub fn BuildConfig::with_normalize_vecs(
  self : BuildConfig,
  v : Bool,
) -> BuildConfig {
  { ..self, normalize_vecs: v }
}

///|
/// 函数式更新：是否写 256 行块级 ts 统计（filter 时只读命中块）。
pub fn BuildConfig::with_block_stats(
  self : BuildConfig,
  v : Bool,
) -> BuildConfig {
  { ..self, write_block_stats: v }
}

///|
/// 函数式更新：是否写 namespace 级全局 IVF 分区（消除 nprobe×段数放大）。
pub fn BuildConfig::with_global_vec_parts(
  self : BuildConfig,
  v : Bool,
) -> BuildConfig {
  { ..self, global_vec_parts: v }
}

///|
/// 函数式更新：是否在 seg meta 内嵌 FTS term Bloom。
pub fn BuildConfig::with_fts_bloom(self : BuildConfig, v : Bool) -> BuildConfig {
  { ..self, write_fts_bloom: v }
}

///|
/// 函数式更新：全局分区分包大小（>1 = 相邻 cid 每 P 个打包成 pack-{i}.bin，
/// meta.json 记 `"pack_size"`；1 = 每 cid 一个 part 对象，旧行为）。
pub fn BuildConfig::with_global_pack_size(
  self : BuildConfig,
  v : Int,
) -> BuildConfig {
  { ..self, global_pack_size: if v < 1 { 1 } else { v } }
}

///|
/// 函数式更新：全文分词器（CJK 命名空间用 smartcn/kuromoji/nori；
/// 构建与查询必须同一选择，否则索引与查询 term 不一致）。
pub fn BuildConfig::with_fts_tokenizer(
  self : BuildConfig,
  v : @core.Tokenizer,
) -> BuildConfig {
  { ..self, fts_tokenizer: v }
}

///|
/// 函数式更新：距离度量。"euclidean" 时写入不归一化（cosine 退化为 dot 的
/// 前提不成立），kmeans/IVF 按欧氏语义建分区。
pub fn BuildConfig::with_distance_metric(
  self : BuildConfig,
  v : String,
) -> BuildConfig {
  { ..self, distance_metric: v }
}

///|
/// 单副本推荐配置：全局 IVF（向量只存一份）+ 写入归一化（IVF 扫描 dot）+
/// FTS Bloom。适合新 namespace；旧 namespace 可继续用 default 兼容布局。
pub fn BuildConfig::single_copy(ns : String) -> BuildConfig {
  {
    ..BuildConfig::default(ns),
    global_vec_parts: true,
    normalize_vecs: true,
    write_fts_bloom: true,
  }
}

///|
/// ingest / ingest_delta 共用的构建基线：读旧状态、复用/训练 centroids、写新段
/// 对象，并把新 manifest 的分段/统计字段汇总好。**不**写 manifest、不发布 head、
/// 不碰 global part —— 两个入口各自决定 global 的写法与发布收尾。
///
/// `new_id` 在本函数末尾生成，与 `ingest` 原有的 id 生成顺序一致
/// （manifest id 单调递增，顺序影响 head 仲裁，不能提前）。
priv struct IngestBase {
  expected_head : String
  old_manifest : @format.ManifestData?
  old_global_version : String?
  old_seg_count : Int
  new_id : String
  centroid_version : String
  cent : @format.Centroids
  new_ranges : Array[(Int, Int)]
  segs : Array[@format.SegmentMeta]
  deleted : Array[UInt64]
  deleted_roar : String?
  parent : String?
  num_docs : Int
  avg_doc_len : Double
}

///|
/// 写新段 + 拼新 manifest 的公共基线（见 `IngestBase`）。语义与 `ingest` 原实现
/// 完全相同（对象 key、写入顺序、id 生成顺序均不变）。
async fn[S : @store.ObjectStore] build_ingest_base(
  store : S,
  cfg : BuildConfig,
  docs : Array[@core.Doc],
) -> IngestBase {
  // 头 manifest：head_manifest 为 ""（首次创建占位 / 上次发布中断）视为无 live manifest。
  // expected_head 必须保存**构建基线**，发布时用它做 compare-and-set；不能用发布
  // 时刻重新读到的 head（review P0-1）。
  let old_meta : @format.NamespaceMeta? = read_namespace(store, cfg.ns)
  let mut expected_head = ""
  let old_manifest : @format.ManifestData? = match old_meta {
    Some(meta) => {
      expected_head = meta.head_manifest
      if meta.head_manifest == "" {
        None
      } else {
        Some(load_manifest(store, cfg.ns, meta.head_manifest))
      }
    }
    None => {
      init_namespace(store, cfg)
      None
    }
  }
  let old_global_version : String? = match old_manifest {
    Some(m) =>
      match m.vec_global_version {
        Some(v) => Some(v)
        None =>
          match old_meta {
            Some(mm) => mm.vec_global_version
            None => None
          }
      }
    None => None
  }
  let old_seg_count : Int = match old_manifest {
    Some(m) => m.segments.length()
    None => 0
  }
  // centroids：首次训练写入；之后复用 manifest 钉住的版本
  let (centroid_version, cent) = match old_manifest {
    Some(m) => {
      let c = load_centroids(store, cfg.ns, m.centroid_version)
      (m.centroid_version, c)
    }
    None => {
      let v = new_centroid_version()
      let c : @format.Centroids = if docs.length() > 0 {
        train_centroids(docs, cfg.nlist, 8, cfg.distance_metric == "euclidean")
      } else {
        { dim: cfg.vector_dim, data: [] }
      }
      store.put(centroids_key(cfg.ns, v), @format.encode_centroids(c))
      (v, c)
    }
  }
  // 切段写入（segment_rows<=0 时兜底为单段）
  let new_segs : Array[@format.SegmentMeta] = Array()
  let new_ranges : Array[(Int, Int)] = Array()
  let step = if cfg.segment_rows > 0 {
    cfg.segment_rows
  } else if docs.length() > 0 {
    docs.length()
  } else {
    1
  }
  let mut start = 0
  while start < docs.length() {
    let end = if start + step < docs.length() {
      start + step
    } else {
      docs.length()
    }
    new_segs.push(write_segment(store, cfg, cent, docs, start, end))
    new_ranges.push((start, end))
    start = end
  }
  // 新 manifest：旧 live segments + 新 segments，deleted 沿用
  let segs : Array[@format.SegmentMeta] = Array()
  let mut total_rows = 0
  let mut total_doclen = 0
  let deleted_arr : Array[UInt64] = match old_manifest {
    Some(m) => {
      for s in m.segments {
        segs.push(s)
        total_rows += s.row_count
        total_doclen += s.doc_len_sum
      }
      m.deleted
    }
    None => Array()
  }
  for s in new_segs {
    segs.push(s)
    total_rows += s.row_count
    total_doclen += s.doc_len_sum
  }
  let parent_id : String? = match old_manifest {
    Some(m) => Some(m.id)
    None => None
  }
  let avg_doc_len = if total_rows > 0 {
    total_doclen.to_double() / total_rows.to_double()
  } else {
    0.0
  }
  let new_id = new_manifest_id()
  {
    expected_head,
    old_manifest,
    old_global_version,
    old_seg_count,
    new_id,
    centroid_version,
    cent,
    new_ranges,
    segs,
    deleted: deleted_arr,
    deleted_roar: match old_manifest {
      Some(m) => m.deleted_roar
      None => None
    },
    parent: parent_id,
    num_docs: total_rows,
    avg_doc_len,
  }
}

///|
/// 写入一批 docs 并发布新 manifest：
/// - 首次调用：创建 namespace.json（head_manifest 占位 ""）+ schema.json，
///   用本批 docs 训练 centroids（Lloyd iters=8）写 {ns}/_centroids/{ver}.bin
/// - 非首次：复用头 manifest 钉住的 centroid_version（读 centroids 对象做分配），
///   不新建 centroids 对象
/// - docs 按 cfg.segment_rows 切段，每段写 rows/*.bin、fts/*、vec/part-{cid}.bin、
///   meta.json（partitions 为实际写出的 cid 升序列表）
/// - 新 manifest = 旧 live segments + 新 segments，deleted 沿用旧的，
///   parent = 旧 manifest id；num_docs = 全部段行数和，
///   avg_doc_len = doc_len 总和 / 总行数；CAS 发布头指针
///
/// global 模式（`global_vec_parts && VF16`）下重写**整代全量** base
/// `vec/global/{new_id}`（`global_gen = None`）。追加写入请用 `ingest_delta`。
pub async fn[S : @store.ObjectStore] ingest(
  store : S,
  cfg : BuildConfig,
  docs : Array[@core.Doc],
) -> Unit {
  let b = build_ingest_base(store, cfg, docs)
  let want_global = cfg.global_vec_parts && cfg.vec_storage == VF16
  let manifest : @format.ManifestData = {
    id: b.new_id,
    parent: b.parent,
    segments: b.segs,
    deleted: b.deleted,
    deleted_roar: b.deleted_roar,
    vec_global_version: if want_global {
      Some(b.new_id)
    } else {
      None
    },
    global_gen: None,
    centroid_version: b.centroid_version,
    num_docs: b.num_docs,
    avg_doc_len: b.avg_doc_len,
  }
  let vec_global : String? = if want_global {
    let _ = rebuild_global_vec_parts(
      store,
      cfg,
      cfg.ns,
      b.cent,
      manifest,
      b.old_manifest,
      b.old_global_version,
      docs,
      b.new_ranges,
      b.old_seg_count,
    )
    Some(manifest.id)
  } else {
    None
  }
  store.put(manifest_key(cfg.ns, manifest.id), json_bytes(manifest.to_json()))
  publish_head(store, cfg.ns, b.expected_head, manifest.id)
  if vec_global is Some(_) || b.old_global_version is Some(_) {
    // 不立即删除旧代：MetadataCache / in-flight 查询可能仍持有旧快照。
    // 只回收超过 grace 的旧代；显式维护可调用 gc_global_versions。
    gc_global_versions_grace(store, cfg.ns, manifest.id, GLOBAL_GC_GRACE_MS)
  }
}

///|
/// 追加写入（global IVF 的 delta 写路径）：与 `ingest` 的 segment /
/// centroid / manifest 逻辑完全一致，**只有 global 部分不同**：
/// - 只把本批新段的向量写进新代 `vec/global/{new_manifest_id}`（不重写旧 base，
///   不读旧 base/delta），新代 meta.json 带 `"kind":"delta"` 与 `"base"`；
/// - 旧 manifest 已有 `global_gen`：`base` 不变，`deltas` 追加新代，
///   `vec_global_version = Some(base)`；
/// - 旧 manifest 只有 `vec_global_version`（旧版单代）：旧代当 base，新代作为
///   第一个 delta；
/// - 旧 manifest 没有 global（或无 manifest）：写全量 base（含旧段向量的拷贝），
///   `global_gen = Some({base: new_id, deltas: []})`；
/// - 非 global 配置（`!global_vec_parts || VSq8/VPq16`）直接退回 `ingest`；
/// - 发布用 `publish_head`，**不调用 GC**（旧代由后续 ingest/compact 的 grace
///   GC 或显式 `gc_global_versions` 回收）。
pub async fn[S : @store.ObjectStore] ingest_delta(
  store : S,
  cfg : BuildConfig,
  docs : Array[@core.Doc],
) -> Unit {
  ingest_delta_opts(store, cfg, docs, 8, true)
}

///|
/// `ingest_delta` 的可配置版本：`max_deltas` 控制自动合并阈值，`auto_compact=false`
/// 时只追加 delta，由调用方在批次结束后显式 `compact_global`（1M 基准用）。
pub async fn[S : @store.ObjectStore] ingest_delta_opts(
  store : S,
  cfg : BuildConfig,
  docs : Array[@core.Doc],
  max_deltas : Int,
  auto_compact : Bool,
) -> Unit {
  if !(cfg.global_vec_parts && cfg.vec_storage == VF16) {
    // 没有全局分区就没有 delta 可言：与 ingest 行为一致（全量写 + 全量 base）。
    ingest(store, cfg, docs)
    return
  }
  let b = build_ingest_base(store, cfg, docs)
  // 旧代基线：global_gen.base 优先；legacy（只有 vec_global_version）以它为 base；
  // 两者皆无 ⇒ 本批写全量 base。
  let old_gen : @format.GlobalGen? = match b.old_manifest {
    Some(m) => m.global_gen
    None => None
  }
  let mut base = ""
  let deltas : Array[String] = Array()
  let mut full_base = false
  match old_gen {
    Some(g) =>
      if g.base != "" {
        base = g.base
        for d in g.deltas {
          deltas.push(d)
        }
        deltas.push(b.new_id)
      } else {
        // 损坏的 global_gen（空 base）：按 legacy 处理
        match b.old_global_version {
          Some(v) => {
            base = v
            deltas.push(b.new_id)
          }
          None => full_base = true
        }
      }
    None =>
      match b.old_global_version {
        Some(v) => {
          base = v
          deltas.push(b.new_id)
        }
        None => full_base = true
      }
  }
  if full_base {
    base = b.new_id
  }
  let manifest : @format.ManifestData = {
    id: b.new_id,
    parent: b.parent,
    segments: b.segs,
    deleted: b.deleted,
    deleted_roar: b.deleted_roar,
    vec_global_version: Some(base),
    global_gen: Some({ base, deltas }),
    centroid_version: b.centroid_version,
    num_docs: b.num_docs,
    avg_doc_len: b.avg_doc_len,
  }
  if full_base {
    // 无旧 global：全量 base（旧段若只有 per-segment part，由该函数负责拷贝）
    let _ = rebuild_global_vec_parts(
      store,
      cfg,
      cfg.ns,
      b.cent,
      manifest,
      b.old_manifest,
      None,
      docs,
      b.new_ranges,
      b.old_seg_count,
    )
  } else {
    let _ = write_global_delta_parts(
      store,
      cfg,
      cfg.ns,
      b.cent,
      manifest,
      base,
      docs,
      b.new_ranges,
      b.old_seg_count,
    )
  }
  store.put(manifest_key(cfg.ns, manifest.id), json_bytes(manifest.to_json()))
  publish_head(store, cfg.ns, b.expected_head, manifest.id)
  // 自动 compact 是纯优化：delta manifest 已经发布，失败不能让调用方误以为
  // 本批未提交。吞掉失败，链仍然正确，下一次 ingest_delta/维护会再尝试。
  if auto_compact {
    let _ = try {
      maybe_compact_global(store, cfg, cfg.ns, max_deltas)
      true
    } catch {
      _ => false
    }
  }
}

///|
/// 逻辑删除（tombstone）：读头 manifest → deleted 合并 ids（去重、升序）→
/// 写新 manifest（segments 与 centroid_version 不变，parent = 旧 manifest id）→
/// CAS 发布头指针。不物理删除对象；namespace.json 的字段不更新。
pub async fn[S : @store.ObjectStore] delete_docs(
  store : S,
  cfg : BuildConfig,
  ids : Array[UInt64],
) -> Unit {
  let meta = match read_namespace(store, cfg.ns) {
    Some(m) => m
    None => raise @core.NotFound("namespace not found: \{cfg.ns}")
  }
  if meta.head_manifest == "" {
    raise @core.NotFound("no manifest published yet: \{cfg.ns}")
  }
  let old = load_manifest(store, cfg.ns, meta.head_manifest)
  // 合并去重：排序后跳过相邻重复（不依赖 Set/Hash）
  let all : Array[UInt64] = Array()
  for d in old.deleted {
    all.push(d)
  }
  for d in ids {
    all.push(d)
  }
  all.sort_by(fn(a, b) { a.compare(b) })
  let dels : Array[UInt64] = Array()
  for i in 0..<all.length() {
    let d = all[i]
    if i == 0 || dels[dels.length() - 1] != d {
      dels.push(d)
    }
  }
  let mut total_rows = 0
  let mut total_doclen = 0
  for s in old.segments {
    total_rows += s.row_count
    total_doclen += s.doc_len_sum
  }
  let avg_doc_len = if total_rows > 0 {
    total_doclen.to_double() / total_rows.to_double()
  } else {
    0.0
  }
  let new_id = new_manifest_id()
  store.put(tombstone_key(cfg.ns, new_id), @format.encode_roaring(dels))
  let manifest : @format.ManifestData = {
    id: new_id,
    parent: Some(old.id),
    segments: old.segments,
    deleted: dels,
    deleted_roar: Some(new_id),
    vec_global_version: old.vec_global_version,
    // 删除只改 tombstone，不动 segments ⇒ global 代际链必须原样继承，
    // 否则 delta 链会被断开（旧 delta 里的老段向量会“消失”）。
    global_gen: old.global_gen,
    centroid_version: old.centroid_version,
    num_docs: total_rows,
    avg_doc_len,
  }
  store.put(manifest_key(cfg.ns, manifest.id), json_bytes(manifest.to_json()))
  publish_head(store, cfg.ns, old.id, manifest.id)
}

pub extend VecStorage with Debug::{to_repr}
pub extend VecStorage with Eq::{not_equal, equal}
