// IVF 向量读路径 + 混合（RRF）。
//
// 向量：query 向量 vs centroids（cosine，@core.cosine_dist_f32）选 nprobe 个最近中心 →
// 每 segment 用缓存的 seg meta.json（partitions 列表，避免读不存在的 part）→
// GET {seg}/vec/part-{cid}.bin → 按 magic 分派：
//   SPNDPRT1 → @format.decode_part（f32/f16/sq8 一律展开 f32）后暴力 cosine 精排；
//   SPNDPQP1 → ADC：查询向量按子空间建 m×256 LUT，候选分 = 1 - Σ LUT[c][code]/2
//   （码本在归一化向量上训练，故 ADC 分数近似 cosine 相似度）。
// → 段内 top-k → 合并 → row→id → tombstone → top-k。score = 1 - cosine_dist。
// nprobe >= 中心数时等价于全量暴力扫描（PQ 为近似）。
//
// 混合：BM25 排名列表 + 向量排名列表做 RRF：score(d) = Σ 1/(60 + rank_i(d))，
// rank 从 1 计，两个列表各取 top-k。

///|
/// 选出距查询向量最近的 nprobe 个中心（按距离升序返回 cid）。
fn select_probes(
  cent : @format.Centroids,
  qv : Array[Float],
  nprobe : Int,
) -> Array[Int] {
  let kk = cent.k()
  if kk <= 0 || nprobe <= 0 {
    return []
  }
  let np = if nprobe < kk { nprobe } else { kk }
  let dists : Array[(Int, Double)] = Array::new(capacity=kk)
  for cid in 0..<kk {
    // 手工构造的旧 namespace 中心未必归一化，这里保持通用 cosine
    dists.push(
      (cid, @core.cosine_dist_f32(qv, 0, cent.data, cid * cent.dim, cent.dim)),
    )
  }
  dists.sort_by(fn(a, b) { a.1.compare(b.1) })
  let out : Array[Int] = Array::new(capacity=np)
  for i in 0..<np {
    out.push(dists[i].0)
  }
  out
}

///|
/// 查询向量 L2 归一化（PQ ADC 用；零向量原样）。
fn normalize_query(qv : Array[Float]) -> Array[Float] {
  let n = @core.norm_f32(qv, 0, qv.length())
  let out : Array[Float] = Array::new(capacity=qv.length())
  for v in qv {
    out.push(if n > 0.0 { Float::from_double(v.to_double() / n) } else { v })
  }
  out
}

///|
/// PQ16 ADC：查询子空间 vs 256 个码字建 LUT，再按每行 codes 求和。
/// 返回 (row, 1 - dist²/2)（归一化向量上 dist² = 2 - 2cos）。
fn pq_adc_candidates(
  qv_norm : Array[Float],
  pq : @format.PQPart,
  codebooks : Array[Float],
) -> Array[(Int, Double)] {
  let m = pq.m
  let dsub = pq.dsub
  let lut : Array[Double] = Array::new(capacity=m * 256)
  for c in 0..<m {
    let qb = c * dsub
    for j in 0..<256 {
      let cb = (c * 256 + j) * dsub
      let mut dist = 0.0
      for d in 0..<dsub {
        let diff = qv_norm[qb + d].to_double() - codebooks[cb + d].to_double()
        dist += diff * diff
      }
      lut.push(dist)
    }
  }
  let out : Array[(Int, Double)] = Array::new(capacity=pq.rows.length())
  for i in 0..<pq.rows.length() {
    let mut dist = 0.0
    for c in 0..<m {
      let code = pq.codes[i * m + c].reinterpret_as_int()
      dist += lut[c * 256 + code]
    }
    out.push((pq.rows[i], 1.0 - dist / 2.0))
  }
  out
}

///|
/// 单 segment 的向量候选：只读 partitions 里实际存在的 probed part；
/// 返回 (seg_idx, row, score) 降序 top-k。
fn[S : @store.ObjectStore] vec_segment(
  n : Namespace[S],
  seg_idx : Int,
  qv : Array[Float],
  qv_norm : Array[Float],
  probes : Array[Int],
  k : Int,
  filter : Filter?,
  rerank : Bool,
) -> Array[(Int, Int, Double)] raise @core.SpndError {
  let seg = n.manifest.segments[seg_idx]
  let cs = ensure_seg(n, seg_idx)
  if !seg_may_match(cs, filter) {
    return []
  }
  let base = "\{n.ns}/_segments/\{seg.id}"
  let part_set : Set[Int] = Set([])
  for cid in cs.partitions {
    part_set.add(cid)
  }
  let matcher : RowMatcher? = match filter {
    Some(f) => Some(load_matcher(n, cs, seg.id, f))
    None => None
  }
  let cands : Array[(Int, Double)] = Array::new()
  let pq_cands : Array[(Int, Double)] = Array::new()
  let mut has_pq = false
  for cid in probes {
    if !part_set.contains(cid) {
      continue
    }
    let key = "\{base}/vec/part-\{cid}.bin"
    let bs = match n.store.get(key) {
      Some(x) => x
      None => raise @core.NotFound(key)
    }
    if @format.is_pq_shared_part(bs) {
      let pq = @format.decode_pq_part_shared(bs)
      if pq.dim != qv.length() {
        raise @core.Corrupt(
          "pq shared part dim mismatch: \{pq.dim} vs qv \{qv.length()}",
        )
      }
      let (m, _, cbs) = match seg_pq_codebook(n, cs, seg.id) {
        Some(x) => x
        None => raise @core.NotFound("\{base}/vec/pq-codebook.bin")
      }
      if m != pq.m {
        raise @core.Corrupt("pq m mismatch: part \{pq.m} vs codebook \{m}")
      }
      has_pq = true
      for c in pq_adc_candidates(qv_norm, pq, cbs) {
        let (row, score) = c
        let ok = match matcher {
          Some(m) => matcher_at(m, row)
          None => true
        }
        if ok {
          pq_cands.push((row, score))
        }
      }
    } else if @format.is_pq_part(bs) {
      let pq = @format.decode_pq_part(bs)
      if pq.dim != qv.length() {
        raise @core.Corrupt(
          "pq part dim mismatch: \{pq.dim} vs qv \{qv.length()}",
        )
      }
      has_pq = true
      for c in pq_adc_candidates(qv_norm, pq, pq.codebooks) {
        let (row, score) = c
        let ok = match matcher {
          Some(m) => matcher_at(m, row)
          None => true
        }
        if ok {
          pq_cands.push((row, score))
        }
      }
    } else {
      let part = @format.decode_part(bs)
      if part.dim != qv.length() {
        raise @core.Corrupt(
          "part dim mismatch: \{part.dim} vs qv \{qv.length()}",
        )
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
        let score = if cs.vec_normalized {
          @core.dot_f32(qv_norm, 0, part.data, i * part.dim, part.dim)
        } else {
          1.0 - @core.cosine_dist_f32(qv, 0, part.data, i * part.dim, part.dim)
        }
        cands.push((row, score))
      }
    }
  }
  // PQ：ADC 取 top-ef，再用 rows/vector.bin 的 f16/f32 块精排（按 256 行块
  // get_range，避免整列读）。向量列不可读/非 f16-f32 时回退 ADC 分数。
  if has_pq && !rerank {
    for c in pq_cands {
      cands.push(c)
    }
  } else if has_pq {
    pq_cands.sort_by(fn(a, b) { b.1.compare(a.1) })
    let ef = if pq_cands.length() < 50 { pq_cands.length() } else { 50 }
    let top : Array[(Int, Double)] = Array::new(capacity=ef)
    for i in 0..<ef {
      top.push(pq_cands[i])
    }
    match seg_vec_info(n, cs, seg.id) {
      Some((vdim, dtype, count)) =>
        if vdim == qv.length() &&
          (dtype == @format.DT_F16 || dtype == @format.DT_F32) {
          let item = if dtype == @format.DT_F16 { 2 } else { 4 }
          let block_size = 256
          top.sort_by(fn(a, b) { a.0.compare(b.0) })
          let mut i = 0
          while i < top.length() {
            let block = top[i].0 / block_size
            let start_row = block * block_size
            let nrows = if start_row + block_size < count {
              block_size
            } else {
              count - start_row
            }
            let off = 16 + start_row * vdim * item
            let len = nrows * vdim * item
            match n.store.get_range("\{base}/rows/vector.bin", off, len) {
              Some(payload) => {
                let data = @format.decode_vec_payload(
                  payload, dtype, vdim, nrows,
                ) catch {
                  _ => []
                }
                if data.length() == nrows * vdim {
                  let mut j = i
                  while j < top.length() && top[j].0 / block_size == block {
                    let row = top[j].0
                    let local_row = row - start_row
                    let score = if cs.vec_normalized {
                      @core.dot_f32(qv_norm, 0, data, local_row * vdim, vdim)
                    } else {
                      1.0 -
                      @core.cosine_dist_f32(qv, 0, data, local_row * vdim, vdim)
                    }
                    top[j] = (row, score)
                    j += 1
                  }
                }
              }
              None => ()
            }
            while i < top.length() && top[i].0 / block_size == block {
              i += 1
            }
          }
        }
      None => ()
    }
    for c in top {
      cands.push(c)
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
/// 读一代全局分区并重分候选到 `cands`（元素 (seg_idx, row, score)）。
/// - 该代 meta.cids 不含 probe cid ⇒ 合法空分区，跳过（delta 代只覆盖新段，
///   旧 cid 在 delta 里可能根本不存在；这不是错误）；
/// - 含该 cid 但 part 对象缺失 ⇒ NotFound（不能静默返回部分结果）；
/// - rows 仍是 (seg_idx, row)：直接用 `n.manifest.segments` / `ensure_seg`，
///   不重排成全局行号；打分口径按 per-segment 的 `cs.vec_normalized`，
///   tombstone / filter 逻辑与单代路径完全一致。
fn[S : @store.ObjectStore] collect_global_candidates(
  n : Namespace[S],
  qv : Array[Float],
  qv_norm : Array[Float],
  probes : Array[Int],
  ver : String,
  cid_set : Set[Int],
  skip : Set[Int],
  matchers : Map[Int, RowMatcher],
  filter : Filter?,
  cands : Array[(Int, Int, Double)],
) -> Unit raise @core.SpndError {
  let nseg = n.manifest.segments.length()
  // 打包代（meta.json pack_size > 1）：probes 按 cid/P 分组，每个 distinct
  // pack 只 GET 一次，再从 pack index 解出所需 cid 的 part。
  let ps = global_gen_pack_size(n, ver)
  if ps > 1 {
    // 需要 pack → 组内 cid 列表。
    let by_pack : Map[Int, Array[Int]] = Map([])
    for cid in probes {
      if !cid_set.contains(cid) {
        continue
      }
      let pk = cid / ps
      match by_pack.get(pk) {
        Some(l) => l.push(cid)
        None => by_pack.set(pk, [cid])
      }
    }
    for kv in by_pack.iter() {
      let (pk, want_cids) = kv
      let key = "\{n.ns}/vec/global/\{ver}/pack-\{pk}.bin"
      let bs = match n.store.get(key) {
        Some(b) => b
        // pack 内声明过的 cid 才会进组；pack 对象缺失说明数据损坏。
        None => raise @core.NotFound(key)
      }
      let idx = @format.decode_global_pack_index(bs)
      for cid in want_cids {
        // pack index 内二分（cid 升序）。
        let mut lo = 0
        let mut hi = idx.length() - 1
        let mut found = false
        while lo <= hi {
          let mid = (lo + hi) / 2
          let c = idx[mid].0
          if c == cid {
            let (c, off, len) = idx[mid]
            let gp = @format.decode_global_part_at(bs, off, len)
            if gp.cid != c {
              raise @core.Corrupt("global pack cid mismatch in \{key}")
            }
            score_global_part(
              n, gp, qv, qv_norm, key, nseg, skip, matchers, filter, cands,
            )
            found = true
            break
          } else if c < cid {
            lo = mid + 1
          } else {
            hi = mid - 1
          }
        }
        if !found {
          // cids 列表声明此分区存在（cid_set 含之）但 pack 里没有 → 损坏。
          raise @core.NotFound("\{key} missing cid \{cid}")
        }
      }
    }
    return
  }
  for cid in probes {
    if !cid_set.contains(cid) {
      continue
    }
    let key = "\{n.ns}/vec/global/\{ver}/part-\{cid}.bin"
    let bs = match n.store.get(key) {
      Some(b) => b
      // cids 列表声明此分区存在；缺失必须报错，不能静默返回部分结果。
      None => raise @core.NotFound(key)
    }
    let gp = @format.decode_global_part(bs)
    if gp.dim != qv.length() {
      raise @core.Corrupt(
        "global part dim mismatch: \{gp.dim} vs qv \{qv.length()}",
      )
    }
    score_global_part(n, gp, qv, qv_norm, key, nseg, skip, matchers, filter, cands)
  }
}

///|
/// 单个 global part 的行级打分（tombstone/filter/归一化口径与原内联逻辑一致）。
fn[S : @store.ObjectStore] score_global_part(
  n : Namespace[S],
  gp : @format.GlobalVecPart,
  qv : Array[Float],
  qv_norm : Array[Float],
  key : String,
  nseg : Int,
  skip : Set[Int],
  matchers : Map[Int, RowMatcher],
  filter : Filter?,
  cands : Array[(Int, Int, Double)],
) -> Unit raise @core.SpndError {
  if gp.dim != qv.length() {
    raise @core.Corrupt(
      "global part dim mismatch: \{gp.dim} vs qv \{qv.length()}",
    )
  }
  for i in 0..<gp.rows.length() {
    let (si, row) = gp.rows[i]
    // 代际链里 seg_idx 指向写该代时的 manifest.segments 下标；段只追加不删，
    // 当前 manifest 仍然可直接用。越界说明数据损坏，不能静默跳过。
    if si < 0 || si >= nseg {
      raise @core.Corrupt(
        "global part seg_idx \{si} out of range (\{nseg}) in \{key}",
      )
    }
    if skip.contains(si) {
      continue
    }
    let cs = ensure_seg(n, si)
    match filter {
      Some(f) => {
        let m = match matchers.get(si) {
          Some(m) => m
          None => {
            let m = load_matcher(n, cs, n.manifest.segments[si].id, f)
            matchers.set(si, m)
            m
          }
        }
        if !matcher_at(m, row) {
          continue
        }
      }
      None => ()
    }
    let score = if cs.vec_normalized {
      @core.dot_f32(qv_norm, 0, gp.data, i * gp.dim, gp.dim)
    } else {
      1.0 - @core.cosine_dist_f32(qv, 0, gp.data, i * gp.dim, gp.dim)
    }
    cands.push((si, row, score))
  }
}

///|
/// namespace 级全局 IVF 分区检索：rows 为 (seg_idx, row)。
/// - `global_gen` 有值（delta 链）：按 `[base] + deltas` 逐代读 part。同一 cid
///   在 base 与 delta 都有 part 时两侧候选合并；某代没有该 cid 时跳过该代。
/// - `global_gen` 为 None：保持旧单代路径（只读 `vec_global_version` 一代）。
/// filter 在行级 matcher 应用；seg stats 仍用于跳过整段。
fn[S : @store.ObjectStore] vec_global_search(
  n : Namespace[S],
  qv : Array[Float],
  qv_norm : Array[Float],
  probes : Array[Int],
  k : Int,
  filter : Filter?,
) -> Array[QueryResult] raise @core.SpndError {
  // 代 → 该代存在的 cid 集合。旧布局只有一代（来自 ensure_global_cids 的并集）。
  let gens : Array[String] = Array::new()
  let gen_cid_sets : Map[String, Set[Int]] = Map([])
  match global_gen_versions(n) {
    Some(vers) =>
      for ver in vers {
        let cs : Set[Int] = Set([])
        for c in global_gen_cids(n, ver) {
          cs.add(c)
        }
        gen_cid_sets.set(ver, cs)
        gens.push(ver)
      }
    None => {
      let ver = match n.manifest.vec_global_version {
        Some(v) => v
        None =>
          match n.meta.vec_global_version {
            Some(v) => v
            None => return []
          }
      }
      let cids = match ensure_global_cids(n) {
        Some(c) => c
        None => return [] // 调用方只在 manifest 声明 global 时进入；防御性保留
      }
      let cs : Set[Int] = Set([])
      for c in cids {
        cs.add(c)
      }
      gen_cid_sets.set(ver, cs)
      gens.push(ver)
    }
  }
  let tomb = tombstones_of(n)
  let skip : Set[Int] = Set([])
  match filter {
    Some(f) =>
      for si in 0..<n.manifest.segments.length() {
        let cs = ensure_seg(n, si)
        if !seg_may_match(cs, Some(f)) {
          skip.add(si)
        }
      }
    None => ()
  }
  let matchers : Map[Int, RowMatcher] = Map([])
  let cands : Array[(Int, Int, Double)] = Array::new()
  for ver in gens {
    let cid_set = match gen_cid_sets.get(ver) {
      Some(s) => s
      None => continue
    }
    collect_global_candidates(
      n, qv, qv_norm, probes, ver, cid_set, skip, matchers, filter, cands,
    )
  }
  results_from_candidates(n, cands, tomb, k)
}

///|
/// 向量检索。nprobe >= 中心数时 = 全量暴力（PQ 存储为近似）。
pub fn[S : @store.ObjectStore] vec_search(
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
    raise @core.Corrupt(
      "query vector dim \{qv.length()} != centroids dim \{cent.dim}",
    )
  }
  let qv_norm = normalize_query(qv)
  let probes = select_probes(cent, qv, nprobe)
  if probes.is_empty() {
    return []
  }
  // 全局 IVF 分区：每个 cid 只读一个对象（不随段数放大）。filter 在行级应用，
  // stats 仍用于跳过整段（只影响 matcher，不影响 global part 读）。
  // manifest 声明 global 时这是**必须**路径：meta/part 缺失必须 raise，禁止静默
  // 回退到 per-segment（单副本段没有 part，会返回空结果）。
  // `global_gen`（delta 链）同样走全局路径：base + deltas 逐代读。
  if n.manifest.global_gen is Some(_) ||
    n.manifest.vec_global_version is Some(_) ||
    n.meta.vec_global_version is Some(_) {
    return vec_global_search(n, qv, qv_norm, probes, k, filter)
  }
  let tomb = tombstones_of(n)
  let cands : Array[(Int, Int, Double)] = Array::new()
  for si in 0..<n.manifest.segments.length() {
    for c in vec_segment(n, si, qv, qv_norm, probes, k, filter, false) {
      cands.push(c)
    }
  }
  results_from_candidates(n, cands, tomb, k)
}

///|
/// 向量检索（PQ + f16 精排实验路径）：ADC 取 top-50，再按 256 行块 get_range
/// 读 rows/vector.bin 精排。仅用于评估；默认 `vec_search` 仍是纯 ADC。
pub fn[S : @store.ObjectStore] vec_search_rerank(
  n : Namespace[S],
  qv : Array[Float],
  k : Int,
  nprobe : Int,
  filter : Filter?,
) -> Array[QueryResult] raise @core.SpndError {
  // 单副本 global namespace 没有 per-segment parts / rows/vector.bin；
  // 评估专用路径不能静默返回空，必须显式拒绝（delta 链同样是单副本）。
  if n.manifest.global_gen is Some(_) ||
    n.manifest.vec_global_version is Some(_) ||
    n.meta.vec_global_version is Some(_) {
    raise @core.Corrupt(
      "vec_search_rerank is per-segment only; global single-copy not supported",
    )
  }
  if k <= 0 || qv.is_empty() {
    return []
  }
  let cent = ensure_centroids(n)
  if qv.length() != cent.dim {
    raise @core.Corrupt(
      "query vector dim \{qv.length()} != centroids dim \{cent.dim}",
    )
  }
  let qv_norm = normalize_query(qv)
  let probes = select_probes(cent, qv, nprobe)
  if probes.is_empty() {
    return []
  }
  let tomb = tombstones_of(n)
  let cands : Array[(Int, Int, Double)] = Array::new()
  for si in 0..<n.manifest.segments.length() {
    for c in vec_segment(n, si, qv, qv_norm, probes, k, filter, true) {
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
pub fn[S : @store.ObjectStore] hybrid_search(
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
  let scores : Map[UInt64, Double] = Map([])
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
