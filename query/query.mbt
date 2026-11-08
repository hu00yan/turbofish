// query 包：seekpond/v1 读路径。
//
// 职责：打开 namespace（绑定 manifest 快照）→ BM25 / IVF 向量 / 混合（RRF）检索，
// 全程遵守查询成本模型：
// - namespace.json / manifest.json / seg meta.json / fts/dir.bin / centroids：整对象 GET（小）
// - postings.bin：只用 store.get_range 拉 term 局部区间（外层 16B = SPNDPOS1 头）
// - vec/part-*.bin、rows/*.bin（id / 过滤列）：整对象 GET
// - 一次查询绑定 open 时的 manifest 快照（强一致读）
//
// 本文件：公开契约（Filter / QueryResult / Namespace / open）+ 各搜索共用的
// 底层读取与候选合并（tombstone / row→id / top-k）。

///|
/// 过滤条件：(字段名, 期望值)。字段列文件位于 {ns}/_segments/{seg}/rows/{field}.bin。
pub(all) enum Filter {
  FStr(String, String)
  FBool(String, Bool)
  FI64(String, Int64)
}

///|
/// 单条检索结果。BM25：相关度分；向量：cosine 相似度（1 - 距离）；混合：RRF 分。
pub(all) struct QueryResult {
  id : UInt64
  score : Double
} derive(Debug)

///|
/// 已打开的 namespace：缓存 store 引用、namespace 元数据、manifest 快照与
/// 惰性加载的 centroids。查询全程使用该快照，不重读 manifest。
pub(all) struct Namespace[S] {
  store : S
  ns : String
  meta : @format.NamespaceMeta
  manifest : @format.ManifestData
  mut centroids : @format.Centroids? // 惰性：首次 vec/hybrid 查询时加载并缓存
}

///|
/// 打开 namespace：GET namespace.json + head manifest（一次查询绑定此快照）。
pub fn open[S : @store.ObjectStore](
  store : S,
  ns : String,
) -> Namespace[S] raise @core.SpndError {
  let meta_key = "\{ns}/_meta/namespace.json"
  let meta_bs = get_object(store, meta_key)
  let meta = @format.namespace_from_json(parse_json_bytes(meta_bs, "namespace.json"))
  let man_key = "\{ns}/_manifest/\{meta.head_manifest}.json"
  let man_bs = get_object(store, man_key)
  let manifest = @format.manifest_from_json(parse_json_bytes(man_bs, "manifest"))
  { store, ns, meta, manifest, centroids: None }
}

///|
/// manifest.deleted → tombstone 集合。
fn tombstone_set(man : @format.ManifestData) -> Set[UInt64] {
  let s : Set[UInt64] = Set::new()
  for d in man.deleted {
    s.add(d)
  }
  s
}

///|
/// GET 整对象；缺失按 NotFound 报错。
fn get_object[S : @store.ObjectStore](
  store : S,
  key : String,
) -> Bytes raise @core.SpndError {
  match store.get(key) {
    Some(bs) => bs
    None => raise @core.NotFound(key)
  }
}

///|
/// Bytes → String（UTF-8）。
fn bytes_to_string(bs : Bytes) -> String raise @core.SpndError {
  @utf8.decode(bs.view()) catch { _ => raise @core.Corrupt("invalid utf8 bytes") }
}

///|
/// Bytes → Json（解析失败统一转 Corrupt）。
fn parse_json_bytes(bs : Bytes, what : String) -> Json raise @core.SpndError {
  let s = bytes_to_string(bs)
  @json.parse(s) catch { _ => raise @core.Corrupt("invalid json in \{what}") }
}

///|
/// seg meta.json → (row_count, partitions)。
fn parse_seg_meta(bs : Bytes) -> (Int, Array[Int]) raise @core.SpndError {
  let m = match parse_json_bytes(bs, "seg meta.json") {
    Object(mm) => mm
    _ => raise @core.Corrupt("seg meta.json is not an object")
  }
  let row_count = match m.get("row_count") {
    Some(Number(d, ..)) => d.to_int()
    _ => raise @core.Corrupt("seg meta.json missing row_count")
  }
  let parts : Array[Int] = Array::new()
  match m.get("partitions") {
    Some(Array(arr)) =>
      for pj in arr {
        match pj {
          Number(d, ..) => parts.push(d.to_int())
          _ => ()
        }
      }
    _ => ()
  }
  (row_count, parts)
}

///|
/// GET + decode 列文件。
fn read_col[S : @store.ObjectStore](
  n : Namespace[S],
  key : String,
) -> @format.ColData raise @core.SpndError {
  @format.decode_col(get_object(n.store, key))
}

///|
/// 惰性加载 centroids（首次调用后缓存进 Namespace）。
fn ensure_centroids[S : @store.ObjectStore](
  n : Namespace[S],
) -> @format.Centroids raise @core.SpndError {
  match n.centroids {
    Some(c) => c
    None => {
      let key = "\{n.ns}/_centroids/\{n.manifest.centroid_version}.bin"
      let c = @format.decode_centroids(get_object(n.store, key))
      n.centroids = Some(c)
      c
    }
  }
}

///|
/// 查询词去重（保序）。
fn dedupe_terms(terms : Array[String]) -> Array[String] {
  let seen : Set[String] = Set::new()
  let out : Array[String] = Array::new()
  for t in terms {
    if !seen.contains(t) {
      seen.add(t)
      out.push(t)
    }
  }
  out
}

///|
/// 候选合并收尾：row→id（按 segment 惰性读 id 列一次）→ tombstone 过滤 →
/// score 降序 → top-k。
/// cands 元素 = (segment 下标, segment 内行号, 分数)。
fn results_from_candidates[S : @store.ObjectStore](
  n : Namespace[S],
  cands : Array[(Int, Int, Double)],
  tomb : Set[UInt64],
  k : Int,
) -> Array[QueryResult] raise @core.SpndError {
  let id_cols : Map[Int, Array[UInt64]] = Map::new()
  let out : Array[QueryResult] = Array::new()
  for c in cands {
    let (si, row, score) = c
    let ids = match id_cols.get(si) {
      Some(a) => a
      None => {
        let seg = n.manifest.segments[si]
        let arr = match read_col(n, "\{n.ns}/_segments/\{seg.id}/rows/id.bin") {
          @format.ColU64(a) => a
          _ => raise @core.Corrupt("id column dtype is not u64")
        }
        id_cols.set(si, arr)
        arr
      }
    }
    let id = match ids.get(row) {
      Some(x) => x
      None => raise @core.Corrupt("row \{row} out of range in id column")
    }
    if tomb.contains(id) {
      continue
    }
    out.push({ id, score })
  }
  out.sort_by(fn(a, b) { b.score.compare(a.score) })
  if out.length() > k {
    out.truncate(k)
  }
  out
}
