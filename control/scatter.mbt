// control/scatter.mbt：分布式 Scatter-Gather 执行引擎。
//
// 3-Tier 云原生架构协调与计算层：
// 1. Multi-worker query fan-out：
//    当向量检索命中多个中心/分区（nprobe）时，Coordinator 将探针分区列表分派切片至 Worker 池中的可用 Worker。
// 2. Parallel partition execution：
//    每个 Worker 针对分配的分区切片，结合本地 5 分钟热缓存（WorkerTieredCache）独立计算局部 Top-K 候选。
// 3. Coordinator streaming merge：
//    Coordinator 收集各 Worker 返回的局部 Top-K 候选列表，使用流式 Min-Heap (TopKHeap) 汇聚并生成全局排序的最终 Top-K 结果。

///|
/// Coordinator 与 Worker 专用的 Top-K 最小堆（Min-Heap）。
/// 堆顶始终维护当前 Top-K 中的最小分数（用于 O(1) 淘汰阈值判定与 O(log K) 置换）。
pub struct TopKHeap {
  capacity : Int
  mut size : Int
  ids : Array[UInt64]
  scores : Array[Double]
}

///|
pub fn TopKHeap::new(k : Int) -> TopKHeap {
  let cap = if k > 0 { k } else { 1 }
  {
    capacity: cap,
    size: 0,
    ids: [],
    scores: [],
  }
}

///|
/// 向堆中压入一个候选条目：
/// - 未满时直接压入并上浮；
/// - 已满且候选分高于堆顶时置换堆顶并下沉；
/// - 分数相同时采用 doc ID 打破平局，保证排序确定性。
pub fn TopKHeap::push(self : TopKHeap, id : UInt64, score : Double) -> Unit {
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

///|
/// 流式合并候选列表进 TopKHeap。
pub fn TopKHeap::merge_candidates(
  self : TopKHeap,
  candidates : Array[@query.QueryResult],
) -> Unit {
  for c in candidates {
    self.push(c.id, c.score)
  }
}

///|
/// 导出全局降序排序的 Top-K 结果。
pub fn TopKHeap::to_results(self : TopKHeap) -> Array[@query.QueryResult] {
  let out : Array[@query.QueryResult] = []
  for i in 0..<self.size {
    out.push({ id: self.ids[i], score: self.scores[i] })
  }
  out.sort_by(fn(a, b) {
    let sc = b.score.compare(a.score)
    if sc != 0 {
      sc
    } else {
      a.id.compare(b.id)
    }
  })
  out
}

///|
/// 将 probe 分区列表均衡切片分派给 worker_count 个 Worker。
pub fn split_partitions(
  probes : Array[Int],
  worker_count : Int,
) -> Array[Array[Int]] {
  let w = if worker_count < 1 { 1 } else { worker_count }
  let n = probes.length()
  if n == 0 {
    let out : Array[Array[Int]] = []
    for _ in 0..<w {
      out.push([])
    }
    return out
  }
  let out : Array[Array[Int]] = []
  let base = n / w
  let rem = n % w
  let mut cur = 0
  for i in 0..<w {
    let count = base + (if i < rem { 1 } else { 0 })
    let slice : Array[Int] = []
    for j in 0..<count {
      slice.push(probes[cur + j])
    }
    cur += count
    out.push(slice)
  }
  out
}

///|
/// 根据中心点距查询向量的距离选出前 nprobe 个分区 cid。
pub fn select_probe_partitions(
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
  let dists : Array[(Int, Double)] = []
  for cid in 0..<kk {
    let d = if euclidean {
      @core.l2sq_f32(qv, 0, cent.data, cid * cent.dim, cent.dim)
    } else {
      @core.cosine_dist_f32(qv, 0, cent.data, cid * cent.dim, cent.dim)
    }
    dists.push((cid, d))
  }
  dists.sort_by(fn(a, b) { a.1.compare(b.1) })
  let out : Array[Int] = []
  for i in 0..<np {
    out.push(dists[i].0)
  }
  out
}

///|
/// 查询向量 L2 归一化。
fn normalize_query_vec(qv : Array[Float]) -> Array[Float] {
  let n = @core.norm_f32(qv, 0, qv.length())
  let out : Array[Float] = []
  for v in qv {
    out.push(if n > 0.0 { Float::from_double(v.to_double() / n) } else { v })
  }
  out
}

///|
/// Worker 执行分配给自身的分区切片（结合本地 5 分钟热缓存）。
pub async fn[S : @store.ObjectStore] QueryWorker::execute_partition_slice(
  self : QueryWorker[S],
  n : @query.Namespace[S],
  qv : Array[Float],
  partitions : Array[Int],
  top_k : Int,
  filter : @query.Filter?,
) -> Array[@query.QueryResult] {
  if top_k <= 0 || qv.is_empty() || partitions.is_empty() {
    return []
  }

  // 1. 过滤条件预计算（如有 filter，通过 matching_ids 转换为可匹配 doc ID 集合）
  let allowed_set : Map[UInt64, Bool]? = match filter {
    Some(f) => {
      let matched = @query.matching_ids(n, f)
      if matched.is_empty() {
        return []
      }
      let m : Map[UInt64, Bool] = Map([])
      for id in matched {
        m.set(id, true)
      }
      Some(m)
    }
    None => None
  }

  // 2. Tombstones 预加载
  let tomb_set : Map[UInt64, Bool] = Map([])
  match n.tombstones {
    Some(s) =>
      for d in s {
        tomb_set.set(d, true)
      }
    None => {
      let ids = match n.manifest.deleted_roar {
        Some(mid) => {
          let key = "\{n.ns}/_tombstones/\{mid}.roar"
          match n.store.get(key) {
            Some(bs) => @format.decode_roaring(bs)
            None => n.manifest.deleted
          }
        }
        None => n.manifest.deleted
      }
      for d in ids {
        tomb_set.set(d, true)
      }
    }
  }

  let euclidean = n.meta.distance_metric == "euclidean"
  let qv_norm = if euclidean { qv } else { normalize_query_vec(qv) }
  let heap = TopKHeap::new(top_k)
  let nseg = n.manifest.segments.length()

  // 3. 确定 Global IVF 版本代际
  let gens : Array[String] = match n.manifest.global_gen {
    Some(g) if g.base != "" => {
      let all : Array[String] = [g.base]
      for d in g.deltas {
        if d != "" && !all.contains(d) {
          all.push(d)
        }
      }
      all
    }
    _ =>
      match n.manifest.vec_global_version {
        Some(v) => [v]
        None =>
          match n.meta.vec_global_version {
            Some(v) => [v]
            None => []
          }
      }
  }

  // 4. 若为 Global IVF 分区
  if !gens.is_empty() {
    for ver in gens {
      for cid in partitions {
        let part_key = "\{ver}/\{cid}"
        // 4.1 检查 Worker 本地 5 分钟热缓存
        let gp : @format.GlobalVecPart = match self.cache.get(part_key) {
          Some(p) => p
          None => {
            // 未命中本地热缓存：从 Namespace 内存快照或底层物理 Store 获取
            let loaded = match n.global_parts.get(part_key) {
              Some(p) => p
              None => {
                let direct_key = "\{n.ns}/vec/global/\{ver}/part-\{cid}.bin"
                match self.store.get(direct_key) {
                  Some(bs) => {
                    let p = @format.decode_global_part(bs)
                    n.global_parts.set(part_key, p)
                    p
                  }
                  None => {
                    // 若存在 pack 分包则尝试从分包提取
                    let ps = match n.global_gen_packs.get(ver) {
                      Some(sz) => sz
                      None => 1
                    }
                    if ps > 1 {
                      let pk = cid / ps
                      let pkey = "\{n.ns}/vec/global/\{ver}/pack-\{pk}.bin"
                      match self.store.get(pkey) {
                        Some(bs) => {
                          let idx = @format.decode_global_pack_index(bs)
                          for item in idx {
                            let (c, off, len) = item
                            let dec = @format.decode_global_part_at(bs, off, len)
                            let k = "\{ver}/\{c}"
                            n.global_parts.set(k, dec)
                          }
                          match n.global_parts.get(part_key) {
                            Some(p) => p
                            None => raise @core.NotFound("missing part \{cid} in pack \{pk}")
                          }
                        }
                        None => raise @core.NotFound(direct_key)
                      }
                    } else {
                      raise @core.NotFound(direct_key)
                    }
                  }
                }
              }
            }
            // 写入 Worker 5 分钟热缓存
            self.cache.put(part_key, loaded)
            loaded
          }
        }

        // 4.2 计算该分区内向量与 qv 的相似度并压入堆
        let dim = gp.dim
        let num_rows = gp.rows.length()
        for i in 0..<num_rows {
          let (si, row) = gp.rows[i]
          if si < 0 || si >= nseg {
            continue
          }
          let seg = n.manifest.segments[si]
          let cs = match n.cache.get(seg.id) {
            Some(c) => c
            None => continue
          }
          let id = if cs.id_dense {
            cs.min_id + row.to_uint64()
          } else {
            match cs.ids {
              Some(col) => col.at(row) catch { _ => continue }
              None => continue
            }
          }
          if tomb_set.get(id) is Some(_) {
            continue
          }
          match allowed_set {
            Some(m) => if m.get(id) is None { continue }
            None => ()
          }
          let off = i * dim
          let score = if euclidean {
            -@core.l2sq_f32(qv, 0, gp.data, off, dim)
          } else if cs.vec_normalized {
            @core.dot_f32(qv_norm, 0, gp.data, off, dim)
          } else {
            1.0 - @core.cosine_dist_f32(qv, 0, gp.data, off, dim)
          }
          heap.push(id, score)
        }
      }
    }
    return heap.to_results()
  }

  // 5. 若为 Legacy Per-segment 分区（单副本段分区）
  for cid in partitions {
    for si in 0..<nseg {
      let seg = n.manifest.segments[si]
      let cs = match n.cache.get(seg.id) {
        Some(c) => c
        None => continue
      }
      if !cs.partitions.contains(cid) {
        continue
      }
      // SlabV2 单文件段从 `segment.slab` 的 `vec/part-{cid}` 组件精准读取，
      // 碎片段走 `vec/part-{cid}.bin`（同一入口，透明兼容）。
      let bs = match cs.vec_parts.get(cid) {
        Some(b) => b
        None => {
          let b = @query.seg_read_component_or_fail(
            n, seg.id, cs, "vec/part-\{cid}.bin",
          )
          cs.vec_parts.set(cid, b)
          b
        }
      }
      if !@format.is_pq_part(bs) && !@format.is_pq_shared_part(bs) {
        let part = @format.decode_part(bs)
        let dim = part.dim
        for i in 0..<part.rows.length() {
          let row = part.rows[i]
          let id = if cs.id_dense {
            cs.min_id + row.to_uint64()
          } else {
            match cs.ids {
              Some(col) => col.at(row) catch { _ => continue }
              None => continue
            }
          }
          if tomb_set.get(id) is Some(_) {
            continue
          }
          match allowed_set {
            Some(m) => if m.get(id) is None { continue }
            None => ()
          }
          let off = i * dim
          let score = if euclidean {
            -@core.l2sq_f32(qv, 0, part.data, off, dim)
          } else if cs.vec_normalized {
            @core.dot_f32(qv_norm, 0, part.data, off, dim)
          } else {
            1.0 - @core.cosine_dist_f32(qv, 0, part.data, off, dim)
          }
          heap.push(id, score)
        }
      }
    }
  }

  heap.to_results()
}

///|
/// 汇聚合并各 Worker partial top-K 结果（流式 Min-Heap 归并）。
pub fn gather_merge_results(
  partial_results : Array[Array[@query.QueryResult]],
  top_k : Int,
) -> Array[@query.QueryResult] {
  if top_k <= 0 {
    return []
  }
  let heap = TopKHeap::new(top_k)
  for worker_res in partial_results {
    heap.merge_candidates(worker_res)
  }
  heap.to_results()
}

///|
/// Coordinator 汇聚合并各 Worker partial top-K 结果。
pub fn[S] Coordinator::gather_merge(
  self : Coordinator[S],
  partial_results : Array[Array[@query.QueryResult]],
  top_k : Int,
) -> Array[@query.QueryResult] {
  let _ = self
  gather_merge_results(partial_results, top_k)
}

///|
/// Coordinator 分布式 Scatter-Gather 向量查询引擎：
/// 1. 多 Worker 查询扇出（Multi-worker query fan-out）：划分探针分区并分配给 Worker 池；
/// 2. 分区并行计算（Parallel partition execution）：每个 Worker 结合 5 分钟热缓存独立计算局部 Top-K；
/// 3. Coordinator 流式汇聚（Streaming merge）：通过 TopKHeap (Min-Heap) 汇聚并返回全局 Top-K 结果。
pub async fn[S : @store.ObjectStore] Coordinator::scatter_gather_vector_query(
  self : Coordinator[S],
  tenant_id : String,
  n : @query.Namespace[S],
  qv : Array[Float],
  top_k : Int,
  nprobe : Int,
  filter : @query.Filter?,
) -> Array[@query.QueryResult] {
  let _ = tenant_id
  if top_k <= 0 || qv.is_empty() || nprobe <= 0 {
    return []
  }

  // 确保 Namespace 元数据及 Centroids 预加载
  if n.centroids is None {
    @query.warm_namespace(n)
  }
  let cent = match n.centroids {
    Some(c) => c
    None => {
      let key = "\{n.ns}/_centroids/\{n.manifest.centroid_version}.bin"
      let bs = match n.store.get(key) {
        Some(b) => b
        None => raise @core.NotFound(key)
      }
      let c = @format.decode_centroids(bs)
      n.centroids = Some(c)
      c
    }
  }

  if qv.length() != cent.dim {
    raise @core.Corrupt(
      "query vector dim \{qv.length()} != centroids dim \{cent.dim}",
    )
  }

  // 计算需探查的分区列表
  let probes = select_probe_partitions(
    cent,
    qv,
    nprobe,
    n.meta.distance_metric == "euclidean",
  )
  if probes.is_empty() {
    return []
  }

  let worker_count = self.workers.length()
  if worker_count <= 1 {
    let worker = if worker_count == 1 {
      self.workers[0]
    } else {
      QueryWorker::new("default", self.store)
    }
    return worker.execute_partition_slice(n, qv, probes, top_k, filter)
  }

  // 1. Multi-worker query fan-out
  let slices = split_partitions(probes, worker_count)

  // 2. Parallel partition execution
  let partial_results : Array[Array[@query.QueryResult]] = []
  for i in 0..<worker_count {
    let slice = slices[i]
    if slice.is_empty() {
      continue
    }
    let res = self.workers[i].execute_partition_slice(
      n, qv, slice, top_k, filter,
    )
    partial_results.push(res)
  }

  // 3. Coordinator streaming merge
  self.gather_merge(partial_results, top_k)
}
