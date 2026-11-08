// build 包：写路径 —— segment 构建、kmeans 训练、ingest、tombstone。
// 公开 API（BuildConfig / ingest / delete_docs / train_centroids）是
// build/query/bench 三方契约，签名不得更改（NOTES.md 第 3 节）。
// 对象 key 构造、JSON IO、CAS 发布在 segment.mbt；kmeans 在 kmeans.mbt。

///|
pub(all) struct BuildConfig {
  ns : String
  segment_rows : Int // 每 N 行一个 segment
  nlist : Int // IVF 中心数
  use_f16 : Bool
  vector_dim : Int
}

///|
/// 默认：segment_rows=2000, nlist=64, use_f16=true, vector_dim=768
pub fn BuildConfig::default(ns : String) -> BuildConfig {
  { ns, segment_rows: 2000, nlist: 64, use_f16: true, vector_dim: 768 }
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
pub fn ingest[S : @store.ObjectStore](
  store : S,
  cfg : BuildConfig,
  docs : Array[@core.Doc],
) -> Unit raise @core.SpndError {
  // 头 manifest：head_manifest 为 ""（首次创建占位 / 上次发布中断）视为无 live manifest
  let old_manifest : @format.ManifestData? = match read_namespace(store, cfg.ns) {
    Some(meta) => if meta.head_manifest == "" {
      None
    } else {
      Some(load_manifest(store, cfg.ns, meta.head_manifest))
    }
    None => {
      init_namespace(store, cfg)
      None
    }
  }
  // centroids：首次训练写入；之后复用 manifest 钉住的版本
  let (centroid_version, cent) = match old_manifest {
    Some(m) => {
      let c = load_centroids(store, cfg.ns, m.centroid_version)
      (m.centroid_version, c)
    }
    None => {
      let v = @core.next_centroid_version()
      let c : @format.Centroids = if docs.length() > 0 {
        train_centroids(docs, cfg.nlist, 8)
      } else {
        { dim: cfg.vector_dim, data: [] }
      }
      store.put(centroids_key(cfg.ns, v), @format.encode_centroids(c))
      (v, c)
    }
  }
  // 切段写入（segment_rows<=0 时兜底为单段）
  let new_segs : Array[@format.SegmentMeta] = Array::new()
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
    start = end
  }
  // 新 manifest：旧 live segments + 新 segments，deleted 沿用
  let segs : Array[@format.SegmentMeta] = Array::new()
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
    None => Array::new()
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
  let manifest : @format.ManifestData = {
    id: @core.next_manifest_id(),
    parent: parent_id,
    segments: segs,
    deleted: deleted_arr,
    centroid_version,
    num_docs: total_rows,
    avg_doc_len,
  }
  store.put(manifest_key(cfg.ns, manifest.id), json_bytes(manifest.to_json()))
  publish_head(store, cfg.ns, manifest.id)
}

///|
/// 逻辑删除（tombstone）：读头 manifest → deleted 合并 ids（去重、升序）→
/// 写新 manifest（segments 与 centroid_version 不变，parent = 旧 manifest id）→
/// CAS 发布头指针。不物理删除对象；namespace.json 的字段不更新。
pub fn delete_docs[S : @store.ObjectStore](
  store : S,
  cfg : BuildConfig,
  ids : Array[UInt64],
) -> Unit raise @core.SpndError {
  let meta = match read_namespace(store, cfg.ns) {
    Some(m) => m
    None => raise @core.NotFound("namespace not found: \{cfg.ns}")
  }
  if meta.head_manifest == "" {
    raise @core.NotFound("no manifest published yet: \{cfg.ns}")
  }
  let old = load_manifest(store, cfg.ns, meta.head_manifest)
  // 合并去重：排序后跳过相邻重复（不依赖 Set/Hash）
  let all : Array[UInt64] = Array::new()
  for d in old.deleted {
    all.push(d)
  }
  for d in ids {
    all.push(d)
  }
  all.sort_by(fn(a, b) { a.compare(b) })
  let dels : Array[UInt64] = Array::new()
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
  let manifest : @format.ManifestData = {
    id: @core.next_manifest_id(),
    parent: Some(old.id),
    segments: old.segments,
    deleted: dels,
    centroid_version: old.centroid_version,
    num_docs: total_rows,
    avg_doc_len,
  }
  store.put(manifest_key(cfg.ns, manifest.id), json_bytes(manifest.to_json()))
  publish_head(store, cfg.ns, manifest.id)
}
