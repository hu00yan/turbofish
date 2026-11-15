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
/// euclidean=true 时按 l2sq 选择（中心未归一化）；否则 cosine。
fn select_probes(
  cent : @format.Centroids,
  qv : Array[Float],
  nprobe : Int,
  euclidean : Bool,
) -> Array[Int] {
  let kk = cent.k()
  if kk <= 0 || nprobe <= 0 {
    return []
  }
  let np = if nprobe < kk { nprobe } else { kk }
  let dists : Array[(Int, Double)] = Array(capacity=kk)
  for cid in 0..<kk {
    // euclidean namespace：l2sq 最小 = 欧氏最近；
    // cosine：手工构造的旧 namespace 中心未必归一化，保持通用 cosine
    let d = if euclidean {
      @core.l2sq_f32(qv, 0, cent.data, cid * cent.dim, cent.dim)
    } else {
      @core.cosine_dist_f32(qv, 0, cent.data, cid * cent.dim, cent.dim)
    }
    dists.push((cid, d))
  }
  dists.sort_by(fn(a, b) { a.1.compare(b.1) })
  let out : Array[Int] = Array(capacity=np)
  for i in 0..<np {
    out.push(dists[i].0)
  }
  out
}

///|
/// 统一打分口径：
/// - euclidean：score = -l2sq(qv, row)（值越大越近；l2sq 已是 Double）
/// - cosine 且已归一化：score = dot(qv_norm, row)（cosine 退化为 dot）
/// - cosine 未归一化：score = 1 - cosine_dist(qv, row)
fn vec_score_of(
  metric_euclidean : Bool,
  vec_normalized : Bool,
  qv : Array[Float],
  qv_norm : Array[Float],
  data : Array[Float],
  off : Int,
  dim : Int,
) -> Double {
  if metric_euclidean {
    -@core.l2sq_f32(qv, 0, data, off, dim)
  } else if vec_normalized {
    @core.dot_f32(qv_norm, 0, data, off, dim)
  } else {
    1.0 - @core.cosine_dist_f32(qv, 0, data, off, dim)
  }
}

///|
/// 查询向量 L2 归一化（PQ ADC 用；零向量原样）。
fn normalize_query(qv : Array[Float]) -> Array[Float] {
  let n = @core.norm_f32(qv, 0, qv.length())
  let out : Array[Float] = Array(capacity=qv.length())
  for v in qv {
    out.push(if n > 0.0 { Float::from_double(v.to_double() / n) } else { v })
  }
  out
}

///|
/// PQ16 ADC：查询子空间 vs 256 个码字建 LUT，再按每行 codes 求和。
/// 返回 (row, 累计 l2sq 距离)。cosine 口径的分数换算（1 - dist/2，要求码本
/// 在归一化向量上训练）由调用方按 namespace 度量执行：euclidean 直接取 -dist。
pub fn pq_adc_candidates(
  qv_adc : Array[Float],
  pq : @format.PQPart,
  codebooks : Array[Float],
) -> Array[(Int, Double)] {
  pq_adc_candidates_filtered(qv_adc, pq, codebooks, None)
}

///|
/// 带谓词下推 BitSet 过滤的 PQ16 ADC：仅对 surviving 候选行计算码本查表距离，
/// 在重度过滤（如 5% 选择率）场景下跳过 95% 查表开销。
fn pq_adc_candidates_filtered(
  qv_adc : Array[Float],
  pq : @format.PQPart,
  codebooks : Array[Float],
  bitset : BitSet?,
) -> Array[(Int, Double)] {
  let m = pq.m
  let dsub = pq.dsub
  let lut : Array[Double] = Array(capacity=m * 256)
  for c in 0..<m {
    let qb = c * dsub
    for j in 0..<256 {
      let cb = (c * 256 + j) * dsub
      let mut dist = 0.0
      for d in 0..<dsub {
        let diff = qv_adc[qb + d].to_double() - codebooks[cb + d].to_double()
        dist += diff * diff
      }
      lut.push(dist)
    }
  }
  let out : Array[(Int, Double)] = Array(capacity=pq.rows.length())
  for i in 0..<pq.rows.length() {
    let row = pq.rows[i]
    match bitset {
      Some(bs) => if !(bs.get(row)) { continue }
      None => ()
    }
    let mut dist = 0.0
    for c in 0..<m {
      let code = pq.codes[i * m + c].reinterpret_as_int()
      dist += lut[c * 256 + code]
    }
    out.push((row, dist))
  }
  out
}

///|
/// ADC 距离 → 排序分：cosine（码本归一化）1 - dist/2；euclidean -dist。
fn adc_score(dist : Double, euclidean : Bool) -> Double {
  if euclidean {
    -dist
  } else {
    1.0 - dist / 2.0
  }
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
  pushdown : MatchedDocSet?,
  rerank : Bool,
) -> Array[(Int, Int, Double)] raise @core.SpndError {
  let seg = n.manifest.segments[seg_idx]
  let cs = ensure_seg(n, seg_idx)
  let (should_skip, seg_bs) = match pushdown {
    Some(p) =>
      match p.seg_bitsets.get(seg.id) {
        Some(bs) => (bs.is_empty(), Some(bs))
        None => (true, None)
      }
    None =>
      match filter {
        Some(f) => (!seg_may_match(cs, Some(f)), None)
        None => (false, None)
      }
  }
  if should_skip {
    return []
  }
  let euclidean = n.meta.distance_metric == "euclidean"
  let qadc = if euclidean { qv } else { qv_norm }
  let base = "\{n.ns}/_segments/\{seg.id}"
  let part_set : Set[Int] = Set([])
  for cid in cs.partitions {
    part_set.add(cid)
  }
  let matcher : RowMatcher? = if seg_bs is Some(_) {
    None
  } else {
    match filter {
      Some(f) => Some(load_matcher(n, cs, seg.id, f))
      None => None
    }
  }
  let cands : Array[(Int, Double)] = Array()
  let pq_cands : Array[(Int, Double)] = Array()
  let mut has_pq = false
  for cid in probes {
    if !part_set.contains(cid) {
      continue
    }
    let bs = match cs.vec_parts.get(cid) {
      Some(x) => x
      None => {
        let key = "\{base}/vec/part-\{cid}.bin"
        let x = match n.store.get(key) {
          Some(v) => v
          None => raise @core.NotFound(key)
        }
        cs.vec_parts.set(cid, x)
        x
      }
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
      for c in pq_adc_candidates_filtered(qadc, pq, cbs, seg_bs) {
        let (row, dist) = c
        let ok = match seg_bs {
          Some(_) => true
          None =>
            match matcher {
              Some(m) => matcher_at(m, row)
              None => true
            }
        }
        if ok {
          pq_cands.push((row, adc_score(dist, euclidean)))
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
      for c in pq_adc_candidates_filtered(qadc, pq, pq.codebooks, seg_bs) {
        let (row, dist) = c
        let ok = match seg_bs {
          Some(_) => true
          None =>
            match matcher {
              Some(m) => matcher_at(m, row)
              None => true
            }
        }
        if ok {
          pq_cands.push((row, adc_score(dist, euclidean)))
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
        let ok = match seg_bs {
          Some(b) => b.get(row)
          None =>
            match matcher {
              Some(m) => matcher_at(m, row)
              None => true
            }
        }
        if !ok {
          continue
        }
        let score = vec_score_of(
          euclidean, cs.vec_normalized, qv, qv_norm, part.data,
          i * part.dim, part.dim,
        )
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
    let top : Array[(Int, Double)] = Array(capacity=ef)
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
                    let score = vec_score_of(
                      euclidean, cs.vec_normalized, qv, qv_norm, data,
                      local_row * vdim, vdim,
                    )
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
  let out : Array[(Int, Int, Double)] = Array()
  for c in cands {
    out.push((seg_idx, c.0, c.1))
  }
  out
}

///|
///|
/// 专用于 Top-K 向量打分的定长 Min-Heap。
/// 零堆对象分配：预分配容量 k 的扁平数组，热循环内只做就地置换和 sift。
priv struct TopKHeap {
  capacity : Int
  mut size : Int
  ids : Array[UInt64]
  scores : Array[Double]
}

fn TopKHeap::new(k : Int) -> TopKHeap {
  let cap = if k > 0 { k } else { 1 }
  {
    capacity: cap,
    size: 0,
    ids: Array(capacity=cap),
    scores: Array(capacity=cap),
  }
}

fn TopKHeap::push(self : TopKHeap, id : UInt64, score : Double) -> Unit {
  if self.size < self.capacity {
    let mut idx = self.size
    self.ids.push(id)
    self.scores.push(score)
    self.size += 1
    while idx > 0 {
      let parent = (idx - 1) / 2
      if self.scores[idx] < self.scores[parent] {
        let ts = self.scores[idx]
        self.scores[idx] = self.scores[parent]
        self.scores[parent] = ts
        let ti = self.ids[idx]
        self.ids[idx] = self.ids[parent]
        self.ids[parent] = ti
        idx = parent
      } else {
        break
      }
    }
  } else if score > self.scores[0] {
    self.scores[0] = score
    self.ids[0] = id
    let mut idx = 0
    let n = self.size
    while true {
      let left = idx * 2 + 1
      let right = idx * 2 + 2
      if left >= n {
        break
      }
      let mut smallest = left
      if right < n && self.scores[right] < self.scores[left] {
        smallest = right
      }
      if self.scores[smallest] < self.scores[idx] {
        let ts = self.scores[idx]
        self.scores[idx] = self.scores[smallest]
        self.scores[smallest] = ts
        let ti = self.ids[idx]
        self.ids[idx] = self.ids[smallest]
        self.ids[smallest] = ti
        idx = smallest
      } else {
        break
      }
    }
  }
}

fn TopKHeap::to_results(self : TopKHeap) -> Array[QueryResult] {
  let out : Array[QueryResult] = Array(capacity=self.size)
  for i in 0..<self.size {
    out.push({ id: self.ids[i], score: self.scores[i] })
  }
  out.sort_by(fn(a, b) { b.score.compare(a.score) })
  out
}

///|
/// 读一代全局分区并重分候选进 TopKHeap。
/// 零堆对象分配：预解段元数据，候选打分就地 Min-Heap 置换。
fn[S : @store.ObjectStore] collect_global_candidates(
  n : Namespace[S],
  qv : Array[Float],
  qv_norm : Array[Float],
  probes : Array[Int],
  ver : String,
  cid_set : Set[Int],
  seg_skip : Array[Bool],
  seg_matchers : Array[RowMatcher?],
  seg_bitsets : Array[BitSet?],
  seg_norm : Array[Bool],
  seg_dense : Array[Bool],
  seg_min_id : Array[UInt64],
  seg_ids_arr : Array[Array[UInt64]?],
  tomb : Set[UInt64],
  allowed_ids : Set[UInt64]?,
  heap : TopKHeap,
) -> Unit raise @core.SpndError {
  let nseg = n.manifest.segments.length()
  let ps = global_gen_pack_size(n, ver)
  if ps > 1 {
    let by_pack : Map[Int, Array[Int]] = Map([])
    for cid in probes {
      if !cid_set.contains(cid) {
        continue
      }
      let part_key = "\{ver}/\{cid}"
      match n.global_parts.get(part_key) {
        Some(gp) =>
          score_global_part(
            n, gp, qv, qv_norm, part_key, nseg, seg_skip, seg_matchers,
            seg_bitsets, seg_norm, seg_dense, seg_min_id, seg_ids_arr, tomb,
            allowed_ids, heap,
          )
        None => {
          let pk = cid / ps
          match by_pack.get(pk) {
            Some(l) => l.push(cid)
            None => by_pack.set(pk, [cid])
          }
        }
      }
    }
    for kv in by_pack.iter() {
      let (pk, want_cids) = kv
      let key = "\{n.ns}/vec/global/\{ver}/pack-\{pk}.bin"
      let bs = match n.store.get(key) {
        Some(b) => b
        None => raise @core.NotFound(key)
      }
      let idx = @format.decode_global_pack_index(bs)
      for item in idx {
        let (c, off, len) = item
        let gp = @format.decode_global_part_at(bs, off, len)
        if gp.cid != c {
          raise @core.Corrupt("global pack cid mismatch in \{key}")
        }
        n.global_parts.set("\{ver}/\{c}", gp)
      }
      for cid in want_cids {
        let part_key = "\{ver}/\{cid}"
        match n.global_parts.get(part_key) {
          Some(gp) =>
            score_global_part(
              n, gp, qv, qv_norm, key, nseg, seg_skip, seg_matchers,
              seg_bitsets, seg_norm, seg_dense, seg_min_id, seg_ids_arr, tomb,
              allowed_ids, heap,
            )
          None => raise @core.NotFound("\{key} missing cid \{cid}")
        }
      }
    }
    return
  }
  for cid in probes {
    if !cid_set.contains(cid) {
      continue
    }
    let part_key = "\{ver}/\{cid}"
    let gp = match n.global_parts.get(part_key) {
      Some(p) => p
      None => {
        let key = "\{n.ns}/vec/global/\{ver}/part-\{cid}.bin"
        let bs = match n.store.get(key) {
          Some(b) => b
          None => raise @core.NotFound(key)
        }
        let p = @format.decode_global_part(bs)
        if p.dim != qv.length() {
          raise @core.Corrupt(
            "global part dim mismatch: \{p.dim} vs qv \{qv.length()}",
          )
        }
        n.global_parts.set(part_key, p)
        p
      }
    }
    score_global_part(
      n, gp, qv, qv_norm, part_key, nseg, seg_skip, seg_matchers, seg_bitsets,
      seg_norm, seg_dense, seg_min_id, seg_ids_arr, tomb, allowed_ids, heap,
    )
  }
}

///|
/// 单个 global part 的行级打分与 Top-K 堆置换。
/// 热循环优化：
/// - 消除任何堆对象分配（无 tuple、无 intermediate 结构体）
/// - 谓词下推 BitSet 位测试 O(1)，未命中行直接跳过，无 ID 查表与向量点积
/// - 字段引用前置绑定，段级别元数据直接扁平下标索引 O(1)
/// - tombstone 与 filter 先行短路，跳过无用向量乘法
/// - 点积采用 8-way 并行累加器 auto-vec 级计算
fn[S] score_global_part(
  n : Namespace[S],
  gp : @format.GlobalVecPart,
  qv : Array[Float],
  qv_norm : Array[Float],
  key : String,
  nseg : Int,
  seg_skip : Array[Bool],
  seg_matchers : Array[RowMatcher?],
  seg_bitsets : Array[BitSet?],
  seg_norm : Array[Bool],
  seg_dense : Array[Bool],
  seg_min_id : Array[UInt64],
  seg_ids_arr : Array[Array[UInt64]?],
  tomb : Set[UInt64],
  allowed_ids : Set[UInt64]?,
  heap : TopKHeap,
) -> Unit raise @core.SpndError {
  let dim = gp.dim
  if dim != qv.length() {
    raise @core.Corrupt(
      "global part dim mismatch: \{dim} vs qv \{qv.length()}",
    )
  }
  let euclidean = n.meta.distance_metric == "euclidean"
  let gp_data = gp.data
  let gp_rows = gp.rows
  let num_rows = gp_rows.length()
  let has_tomb = !(tomb.is_empty())

  for i in 0..<num_rows {
    let (si, row) = gp_rows[i]
    if si < 0 || si >= nseg {
      raise @core.Corrupt(
        "global part seg_idx \{si} out of range (\{nseg}) in \{key}",
      )
    }
    if seg_skip[si] {
      continue
    }
    match seg_bitsets[si] {
      Some(bs) => if !(bs.get(row)) { continue }
      None =>
        match seg_matchers[si] {
          Some(m) => if !(matcher_at(m, row)) { continue }
          None => ()
        }
    }
    let id = if seg_dense[si] {
      seg_min_id[si] + row.to_uint64()
    } else {
      match seg_ids_arr[si] {
        Some(arr) =>
          if row >= 0 && row < arr.length() {
            arr[row]
          } else {
            raise @core.Corrupt("row \{row} out of range in id column")
          }
        None => raise @core.Corrupt("missing id column for non-dense segment")
      }
    }
    match allowed_ids {
      Some(aids) => if !(aids.contains(id)) { continue }
      None => ()
    }
    if has_tomb && tomb.contains(id) {
      continue
    }

    let off = i * dim
    let score = if euclidean {
      -@core.l2sq_f32(qv, 0, gp_data, off, dim)
    } else if seg_norm[si] {
      @core.dot_f32(qv_norm, 0, gp_data, off, dim)
    } else {
      1.0 - @core.cosine_dist_f32(qv, 0, gp_data, off, dim)
    }
    heap.push(id, score)
  }
}

///|
/// namespace 级全局 IVF 分区检索：rows 为 (seg_idx, row)。
/// - `global_gen` 有值（delta 链）：按 `[base] + deltas` 逐代读 part。同一 cid
///   在 base 与 delta 都有 part 时两侧候选合并；某代没有该 cid 时跳过该代。
/// - `global_gen` 为 None：保持旧单代路径（只读 `vec_global_version` 一代）。
/// filter 在行级 matcher / pushdown bitset 应用；seg stats 仍用于跳过整段。
fn[S : @store.ObjectStore] vec_global_search(
  n : Namespace[S],
  qv : Array[Float],
  qv_norm : Array[Float],
  probes : Array[Int],
  k : Int,
  filter : Filter?,
  pushdown : MatchedDocSet?,
  allowed_ids : Set[UInt64]?,
) -> Array[QueryResult] raise @core.SpndError {
  if k <= 0 {
    return []
  }
  // 只加载本次 probe 命中的全局分区；不要再全量预加载，否则冷查询会
  // 把所有 generation 的向量分片从对象存储拉一遍。
  // 代 → 该代存在的 cid 集合。旧布局只有一代（来自 ensure_global_cids 的并集）。
  let gens : Array[String] = Array()
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
  let nseg = n.manifest.segments.length()
  let seg_skip : Array[Bool] = Array(capacity=nseg)
  let seg_norm : Array[Bool] = Array(capacity=nseg)
  let seg_dense : Array[Bool] = Array(capacity=nseg)
  let seg_min_id : Array[UInt64] = Array(capacity=nseg)
  let seg_ids_arr : Array[Array[UInt64]?] = Array(capacity=nseg)
  let seg_matchers : Array[RowMatcher?] = Array(capacity=nseg)
  let seg_bitsets : Array[BitSet?] = Array(capacity=nseg)

  for si in 0..<nseg {
    let cs = ensure_seg(n, si)
    let seg_id = n.manifest.segments[si].id
    let (should_skip, bs) = match pushdown {
      Some(p) =>
        match p.seg_bitsets.get(seg_id) {
          Some(bitset) => (bitset.is_empty(), Some(bitset))
          None => (true, None)
        }
      None =>
        match filter {
          Some(f) => (!seg_may_match(cs, Some(f)), None)
          None => (false, None)
        }
    }
    seg_skip.push(should_skip)
    seg_bitsets.push(bs)
    seg_norm.push(cs.vec_normalized)
    seg_dense.push(cs.id_dense)
    seg_min_id.push(cs.min_id)
    let ids = if cs.id_dense {
      None
    } else {
      Some(seg_ids(n, cs, seg_id))
    }
    seg_ids_arr.push(ids)
    let m = match filter {
      Some(f) =>
        if should_skip || bs is Some(_) {
          None
        } else {
          Some(load_matcher(n, cs, seg_id, f))
        }
      None => None
    }
    seg_matchers.push(m)
  }

  let heap = TopKHeap::new(k)
  for ver in gens {
    let cid_set = match gen_cid_sets.get(ver) {
      Some(s) => s
      None => continue
    }
    collect_global_candidates(
      n, qv, qv_norm, probes, ver, cid_set, seg_skip, seg_matchers, seg_bitsets,
      seg_norm, seg_dense, seg_min_id, seg_ids_arr, tomb, allowed_ids, heap,
    )
  }
  heap.to_results()
}

///|
/// 向量检索。集成了 Predicate Pushdown Filtering Engine：
/// 1. 若携带 filter，先进行向量化列式下推预过滤，生成存活行 BitSet；
/// 2. 若下推过滤命中数为 0，零开销直接短路返回空列表（跳过全部 probe 与点积）；
/// 3. 在探针扫描中，仅对 surviving 候选行执行点积运算，获得 10x-20x 剪枝加速。
pub fn[S : @store.ObjectStore] vec_search(
  n : Namespace[S],
  qv : Array[Float],
  k : Int,
  nprobe : Int,
  filter : Filter?,
) -> Array[QueryResult] raise @core.SpndError {
  vec_search_with_pushdown(n, qv, k, nprobe, filter, None)
}

///|
/// 向量检索扩展入口：支持外部传入 allowed_ids 显式剪枝。
pub fn[S : @store.ObjectStore] vec_search_with_pushdown(
  n : Namespace[S],
  qv : Array[Float],
  k : Int,
  nprobe : Int,
  filter : Filter?,
  allowed_ids : Set[UInt64]?,
) -> Array[QueryResult] raise @core.SpndError {
  if k <= 0 || qv.is_empty() {
    return []
  }
  match allowed_ids {
    Some(aids) => if aids.is_empty() { return [] }
    None => ()
  }
  let pushdown : MatchedDocSet? = match filter {
    Some(f) => {
      let p = eval_pushdown_filter(n, f)
      if p.total_matched == 0 {
        return []
      }
      Some(p)
    }
    None => None
  }
  let cent = ensure_centroids(n)
  if qv.length() != cent.dim {
    raise @core.Corrupt(
      "query vector dim \{qv.length()} != centroids dim \{cent.dim}",
    )
  }
  let qv_norm = normalize_query(qv)
  let probes = select_probes(
    cent,
    qv,
    nprobe,
    n.meta.distance_metric == "euclidean",
  )
  if probes.is_empty() {
    return []
  }
  if n.manifest.global_gen is Some(_) ||
    n.manifest.vec_global_version is Some(_) ||
    n.meta.vec_global_version is Some(_) {
    return vec_global_search(
      n, qv, qv_norm, probes, k, filter, pushdown, allowed_ids,
    )
  }
  let tomb = tombstones_of(n)
  let cands : Array[(Int, Int, Double)] = Array()
  for si in 0..<n.manifest.segments.length() {
    for
      c in vec_segment(
        n, si, qv, qv_norm, probes, k, filter, pushdown, false,
      ) {
      cands.push(c)
    }
  }
  let results = results_from_candidates(n, cands, tomb, k)
  match allowed_ids {
    Some(aids) => {
      let filtered : Array[QueryResult] = Array(capacity=results.length())
      for r in results {
        if aids.contains(r.id) {
          filtered.push(r)
        }
      }
      filtered
    }
    None => results
  }
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
  vec_search_rerank_with_pushdown(n, qv, k, nprobe, filter, None)
}

///|
/// 精排检索扩展入口：支持外部传入 allowed_ids 显式剪枝。
pub fn[S : @store.ObjectStore] vec_search_rerank_with_pushdown(
  n : Namespace[S],
  qv : Array[Float],
  k : Int,
  nprobe : Int,
  filter : Filter?,
  allowed_ids : Set[UInt64]?,
) -> Array[QueryResult] raise @core.SpndError {
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
  match allowed_ids {
    Some(aids) => if aids.is_empty() { return [] }
    None => ()
  }
  let pushdown : MatchedDocSet? = match filter {
    Some(f) => {
      let p = eval_pushdown_filter(n, f)
      if p.total_matched == 0 {
        return []
      }
      Some(p)
    }
    None => None
  }
  let cent = ensure_centroids(n)
  if qv.length() != cent.dim {
    raise @core.Corrupt(
      "query vector dim \{qv.length()} != centroids dim \{cent.dim}",
    )
  }
  let qv_norm = normalize_query(qv)
  let probes = select_probes(
    cent,
    qv,
    nprobe,
    n.meta.distance_metric == "euclidean",
  )
  if probes.is_empty() {
    return []
  }
  let tomb = tombstones_of(n)
  let cands : Array[(Int, Int, Double)] = Array()
  for si in 0..<n.manifest.segments.length() {
    for
      c in vec_segment(
        n, si, qv, qv_norm, probes, k, filter, pushdown, true,
      ) {
      cands.push(c)
    }
  }
  let results = results_from_candidates(n, cands, tomb, k)
  match allowed_ids {
    Some(aids) => {
      let filtered : Array[QueryResult] = Array(capacity=results.length())
      for r in results {
        if aids.contains(r.id) {
          filtered.push(r)
        }
      }
      filtered
    }
    None => results
  }
}

///|
/// RRF 默认常量（spec：k=60；可被 HybridOpts.rank_constant 覆盖）。
const RRF_K : Double = 60.0

///|
/// 混合检索参数（对齐 turbopuffer rerank_by=["RRF", rank_constant, weights]）：
/// - fusion="rrf"：score(d) = Σ w_i / (rank_constant + rank_i(d))，rank 从 1 计
/// - fusion="linear"：两路列表各自 min-max 归一化后线性加权
pub(all) struct HybridOpts {
  rank_constant : Double
  fusion : String // "rrf" | "linear"
  weight_bm25 : Double
  weight_vec : Double
}

///|
pub fn HybridOpts::default() -> HybridOpts {
  { rank_constant: RRF_K, fusion: "rrf", weight_bm25: 1.0, weight_vec: 1.0 }
}

///|
/// 混合检索（默认 RRF k=60、等权）。兼容旧签名。
pub fn[S : @store.ObjectStore] hybrid_search(
  n : Namespace[S],
  query : String,
  qv : Array[Float],
  k : Int,
  nprobe : Int,
  filter : Filter?,
) -> Array[QueryResult] raise @core.SpndError {
  hybrid_search_opts(n, query, qv, k, nprobe, filter, HybridOpts::default())
}

///|
/// min-max 归一化（退化分布：全部同分时统一 1.0）。
fn minmax_norm(scores : Array[(UInt64, Double)]) -> Array[(UInt64, Double)] {
  let out : Array[(UInt64, Double)] = Array(
    capacity=scores.length(),
  )
  if scores.is_empty() {
    return out
  }
  let mut lo = scores[0].1
  let mut hi = scores[0].1
  for kv in scores {
    if kv.1 < lo {
      lo = kv.1
    }
    if kv.1 > hi {
      hi = kv.1
    }
  }
  let span = hi - lo
  for kv in scores {
    let v = if span <= 0.0 {
      1.0
    } else {
      (kv.1 - lo) / span
    }
    out.push((kv.0, v))
  }
  out
}

///|
/// 混合检索：BM25 排名 + 向量排名 → RRF 或线性加权融合 → top-k。
pub fn[S : @store.ObjectStore] hybrid_search_opts(
  n : Namespace[S],
  query : String,
  qv : Array[Float],
  k : Int,
  nprobe : Int,
  filter : Filter?,
  opts : HybridOpts,
) -> Array[QueryResult] raise @core.SpndError {
  if k <= 0 {
    return []
  }
  let bm = bm25_search(n, query, k, filter)
  let vs = vec_search(n, qv, k, nprobe, filter)
  let out : Array[QueryResult] = Array()
  if opts.fusion == "linear" {
    let nb = minmax_norm(
      (fn() {
        let a : Array[(UInt64, Double)] = Array(capacity=bm.length())
        for r in bm {
          a.push((r.id, r.score))
        }
        a
      })(),
    )
    let nv = minmax_norm(
      (fn() {
        let a : Array[(UInt64, Double)] = Array(capacity=vs.length())
        for r in vs {
          a.push((r.id, r.score))
        }
        a
      })(),
    )
    let scores : Map[UInt64, Double] = Map([])
    for kv in nb {
      let cur = match scores.get(kv.0) {
        Some(v) => v
        None => 0.0
      }
      scores.set(kv.0, cur + opts.weight_bm25 * kv.1)
    }
    for kv in nv {
      let cur = match scores.get(kv.0) {
        Some(v) => v
        None => 0.0
      }
      scores.set(kv.0, cur + opts.weight_vec * kv.1)
    }
    for kv in scores.iter() {
      out.push({ id: kv.0, score: kv.1 })
    }
  } else {
    let rrf_k = if opts.rank_constant > 0.0 {
      opts.rank_constant
    } else {
      RRF_K
    }
    let scores : Map[UInt64, Double] = Map([])
    let mut rank = 1
    for r in bm {
      let cur = match scores.get(r.id) {
        Some(v) => v
        None => 0.0
      }
      scores.set(r.id, cur + opts.weight_bm25 / (rrf_k + rank.to_double()))
      rank += 1
    }
    rank = 1
    for r in vs {
      let cur = match scores.get(r.id) {
        Some(v) => v
        None => 0.0
      }
      scores.set(r.id, cur + opts.weight_vec / (rrf_k + rank.to_double()))
      rank += 1
    }
    for kv in scores.iter() {
      out.push({ id: kv.0, score: kv.1 })
    }
  }
  out.sort_by(fn(a, b) { b.score.compare(a.score) })
  if out.length() > k {
    out.truncate(k)
  }
  out
}
