// IVF 向量读路径 + 混合（RRF）。
//
// 向量：query 向量 vs centroids（cosine，@core.cosine_dist_f32）选 nprobe 个最近中心 →
// 每 segment GET seg meta.json（partitions 列表，避免读不存在的 part）→
// GET {seg}/vec/part-{cid}.bin → @format.decode_part → 段内暴力 cosine 精排 →
// per-segment top-k → 合并 → row→id → tombstone → top-k。score = 1 - cosine_dist。
// nprobe >= 中心数时等价于全量暴力扫描。
//
// 混合：BM25 排名列表 + 向量排名列表做 RRF：score(d) = Σ 1/(60 + rank_i(d))，
// rank 从 1 计，两个列表各取 top-k。

///|
/// 选出距查询向量最近的 nprobe 个中心（按距离升序返回 cid）。
fn select_probes(cent : @format.Centroids, qv : Array[Float], nprobe : Int) -> Array[Int] {
  let kk = cent.k()
  if kk <= 0 || nprobe <= 0 {
    return []
  }
  let np = if nprobe < kk { nprobe } else { kk }
  let dists : Array[(Int, Double)] = Array::new(capacity=kk)
  for cid in 0..<kk {
    dists.push((cid, @core.cosine_dist_f32(qv, 0, cent.data, cid * cent.dim, cent.dim)))
  }
  dists.sort_by(fn(a, b) { a.1.compare(b.1) })
  let out : Array[Int] = Array::new(capacity=np)
  for i in 0..<np {
    out.push(dists[i].0)
  }
  out
}

///|
/// 单 segment 的向量候选：只读 partitions 里实际存在的 probed part；
/// 返回 (seg_idx, row, score) 降序 top-k。
fn vec_segment[S : @store.ObjectStore](
  n : Namespace[S],
  seg_idx : Int,
  qv : Array[Float],
  probes : Array[Int],
  k : Int,
  filter : Filter?,
) -> Array[(Int, Int, Double)] raise @core.SpndError {
  let seg = n.manifest.segments[seg_idx]
  let base = "\{n.ns}/_segments/\{seg.id}"
  let meta_bs = get_object(n.store, "\{base}/meta.json")
  let (_, partitions) = parse_seg_meta(meta_bs)
  let part_set : Set[Int] = Set::new()
  for cid in partitions {
    part_set.add(cid)
  }
  let matcher : RowMatcher? = match filter {
    Some(f) => Some(load_matcher(n, seg.id, f))
    None => None
  }
  let cands : Array[(Int, Double)] = Array::new()
  for cid in probes {
    if !part_set.contains(cid) {
      continue
    }
    let bs = match n.store.get("\{base}/vec/part-\{cid}.bin") {
      Some(x) => x
      None => raise @core.NotFound("\{base}/vec/part-\{cid}.bin")
    }
    let part = @format.decode_part(bs)
    if part.dim != qv.length() {
      raise @core.Corrupt("part dim mismatch: \{part.dim} vs qv \{qv.length()}")
    }
    for i in 0..<part.rows.length() {
      let row = part.rows[i]
      let ok = match matcher {
        Some(m) => matcher_at(m, row)
        None => true
      }
      if !ok {
        continue
      }
      let d = @core.cosine_dist_f32(qv, 0, part.data, i * part.dim, part.dim)
      cands.push((row, 1.0 - d))
    }
  }
  cands.sort_by(fn(a, b) { b.1.compare(a.1) })
  if cands.length() > k {
    cands.truncate(k)
  }
  let out : Array[(Int, Int, Double)] = Array::new()
  for c in cands {
    out.push((seg_idx, c.0, c.1))
  }
  out
}

///|
/// 向量检索。nprobe >= 中心数时 = 全量暴力。
pub fn vec_search[S : @store.ObjectStore](
  n : Namespace[S],
  qv : Array[Float],
  k : Int,
  nprobe : Int,
  filter : Filter?,
) -> Array[QueryResult] raise @core.SpndError {
  if k <= 0 || qv.is_empty() {
    return []
  }
  let cent = ensure_centroids(n)
  if qv.length() != cent.dim {
    raise @core.Corrupt("query vector dim \{qv.length()} != centroids dim \{cent.dim}")
  }
  let probes = select_probes(cent, qv, nprobe)
  if probes.is_empty() {
    return []
  }
  let tomb = tombstone_set(n.manifest)
  let cands : Array[(Int, Int, Double)] = Array::new()
  for si in 0..<n.manifest.segments.length() {
    for c in vec_segment(n, si, qv, probes, k, filter) {
      cands.push(c)
    }
  }
  results_from_candidates(n, cands, tomb, k)
}

///|
/// RRF 常量（spec：k=60）。
const RRF_K : Double = 60.0

///|
/// 混合检索：BM25 排名 + 向量排名 → RRF 合并 → top-k。
pub fn hybrid_search[S : @store.ObjectStore](
  n : Namespace[S],
  query : String,
  qv : Array[Float],
  k : Int,
  nprobe : Int,
  filter : Filter?,
) -> Array[QueryResult] raise @core.SpndError {
  if k <= 0 {
    return []
  }
  let bm = bm25_search(n, query, k, filter)
  let vs = vec_search(n, qv, k, nprobe, filter)
  let scores : Map[UInt64, Double] = Map::new()
  let mut rank = 1
  for r in bm {
    let cur = match scores.get(r.id) {
      Some(v) => v
      None => 0.0
    }
    scores.set(r.id, cur + 1.0 / (RRF_K + rank.to_double()))
    rank += 1
  }
  rank = 1
  for r in vs {
    let cur = match scores.get(r.id) {
      Some(v) => v
      None => 0.0
    }
    scores.set(r.id, cur + 1.0 / (RRF_K + rank.to_double()))
    rank += 1
  }
  let out : Array[QueryResult] = Array::new()
  for kv in scores.iter() {
    out.push({ id: kv.0, score: kv.1 })
  }
  out.sort_by(fn(a, b) { b.score.compare(a.score) })
  if out.length() > k {
    out.truncate(k)
  }
  out
}
