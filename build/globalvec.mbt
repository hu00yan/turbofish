// namespace 级全局 IVF 分区构建（可选，S3 请求数优化）。
//
// 对每个 cid，把 manifest 中所有 live segment 的向量合并成
// `vec/global/{manifest_id}/part-{cid}.bin`：rows 为 (seg_idx, row)，seg_idx 是
// manifest.segments 的下标。查询只读 nprobe 个对象，而不是 nprobe×段数。
//
// **单副本**：global 模式下 segment 不写 `rows/vector.bin` / `vec/part-*`，
// 向量只存在 global part 一份。`ingest` / `compact` 重写整代全量 base；
// `ingest_delta` 只追加一个 delta 代（meta.json 的 `"kind":"delta"` + `"base"`），
// manifest 用 `global_gen` 记录 base + deltas 链，消除逐批全量重写的 O(n²) 写放大。
// 默认关闭；大 namespace 可开启并配合 GC。
// 仅 VF16 支持全局化；SQ8/PQ16 保留 per-segment part（避免压缩静默失效）。
//
// 归一化不变式：seg meta.vec_normalized=true ⇒ 该段行在任一 global 代中都已
// L2 归一化；global meta.normalized=true 表示整代归一化。读者按 per-segment
// 标志选 dot/cosine，cosine 对未归一化行仍然正确。

///|
/// 全局 IVF 代际 GC 的默认 grace：覆盖 MetadataCache TTL + 一次查询的最长
/// 生命周期。旧代在 grace 内保留，避免 in-flight 查询读到被删对象。
pub const GLOBAL_GC_GRACE_MS : UInt64 = 60000UL

///|
/// 读 global meta.json（不存在 raise NotFound）。
async fn[S : @store.ObjectStore] read_global_meta(
  store : S,
  ns : String,
  ver : String,
) -> Map[String, Json] {
  let key = "\{ns}/vec/global/\{ver}/meta.json"
  let bs = match store.get(key) {
    Some(b) => b
    None => raise @core.NotFound(key)
  }
  match bytes_to_json(bs, "global meta") {
    Object(m) => m
    _ => raise @core.Corrupt("global meta is not an object")
  }
}

///|
/// global meta 的 cids（缺省 []）。
fn global_meta_cids(m : Map[String, Json]) -> Array[Int] {
  let out : Array[Int] = Array()
  match m.get("cids") {
    Some(Array(arr)) =>
      for x in arr {
        match x {
          Number(d, ..) => out.push(d.to_int())
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
/// global meta 的 normalized 标志（旧数据缺省 false）。
fn global_meta_normalized(m : Map[String, Json]) -> Bool {
  match m.get("normalized") {
    Some(j) => j == Json::boolean(true)
    None => false
  }
}

///|
/// global meta 的 (kind, base)：（base 代缺省 ""，delta 代 kind="delta"）。
fn global_meta_kind_base(m : Map[String, Json]) -> (String, String) {
  let kind = match m.get("kind") {
    Some(String(s)) => s
    _ => ""
  }
  let base = match m.get("base") {
    Some(String(s)) => s
    _ => ""
  }
  (kind, base)
}

///|
/// global 代际链的版本列表（base 在前，deltas 按写入顺序；重复版本去重）：
/// - `global_gen` 有值且 base 非空：`[base, deltas...]`；
/// - `global_gen` 缺省 / base 为空（旧布局或损坏值）：退回 `vec_global_version` 单代；
/// - 两者皆无：空数组（manifest 没有 global 向量）。
///
/// 读路径（`rebuild_global_vec_parts` / `compact`）必须遍历全部代，否则 delta
/// 之后写出的新段向量会丢（S2b）。
fn global_gen_versions(m : @format.ManifestData) -> Array[String] {
  let out : Array[String] = Array()
  let push_one = fn(v : String) -> Unit {
    if v == "" {
      return
    }
    for x in out {
      if x == v {
        return
      }
    }
    out.push(v)
  }
  match m.global_gen {
    Some(g) =>
      if g.base != "" {
        push_one(g.base)
        for d in g.deltas {
          push_one(d)
        }
        return out
      }
    None => ()
  }
  match m.vec_global_version {
    Some(v) => push_one(v)
    None => ()
  }
  out
}

///|
/// 读一个 global 代（base 或 delta）的**全部** part 并做完整性校验：
/// - meta.json 必须存在，cids 可解析；
/// - part 必须存在；dim 必须 > 0 且代内一致；`expected_dim > 0` 时必须相等；
/// - 每行 (seg_idx,row) 必须落在 `manifest` 的段范围内（manifest=None 时跳过，
///   用于没有旧 manifest 的兜底路径）；
/// - delta 代（meta `kind="delta"`）的 `base` 必须等于 `expect_base`（非空时）。
///
/// 返回 (meta, dim, parts)；代内没有 part 时 dim 回落为 `expected_dim`。
/// 单副本语义下任何缺失都不允许静默跳过（跳过 = 丢行）。
async fn[S : @store.ObjectStore] read_global_gen_parts(
  store : S,
  ns : String,
  ver : String,
  manifest : @format.ManifestData?,
  expected_dim : Int,
  expect_base : String,
) -> (Map[String, Json], Int, Array[@format.GlobalVecPart]) {
  let gm = read_global_meta(store, ns, ver)
  let (kind, mbase) = global_meta_kind_base(gm)
  if kind == "delta" && expect_base != "" && mbase != expect_base {
    raise @core.Corrupt(
      "global delta \{ver} base \{mbase} != chain base \{expect_base}",
    )
  }
  let mut gdim = 0
  let parts : Array[@format.GlobalVecPart] = Array()
  // 解码（pack 代按 pack 读 + index 二分；未打包代每 cid 一 GET），再统一校验。
  let ps = match gm.get("pack_size") {
    Some(Number(d, ..)) => if d.to_int() < 1 { 1 } else { d.to_int() }
    _ => 1
  }
  let decoded : Array[@format.GlobalVecPart] = Array()
  let keys : Array[String] = Array()
  if ps > 1 {
    let by_pack : Map[Int, Array[Int]] = Map([])
    for cid in global_meta_cids(gm) {
      let pk = cid / ps
      match by_pack.get(pk) {
        Some(l) => l.push(cid)
        None => by_pack.set(pk, [cid])
      }
    }
    for kv in by_pack.iter() {
      let (pk, want_cids) = kv
      let pkey = "\{ns}/vec/global/\{ver}/pack-\{pk}.bin"
      let bs = match store.get(pkey) {
        Some(b) => b
        None => raise @core.NotFound(pkey)
      }
      let idx = @format.decode_global_pack_index(bs)
      for cid in want_cids {
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
              raise @core.Corrupt("global pack cid mismatch in \{pkey}")
            }
            decoded.push(gp)
            keys.push(pkey)
            found = true
            break
          } else if c < cid {
            lo = mid + 1
          } else {
            hi = mid - 1
          }
        }
        if !found {
          raise @core.NotFound("\{pkey} missing cid \{cid}")
        }
      }
    }
  } else {
    for cid in global_meta_cids(gm) {
      let key = "\{ns}/vec/global/\{ver}/part-\{cid}.bin"
      let bs = match store.get(key) {
        Some(b) => b
        None => raise @core.NotFound(key)
      }
      decoded.push(@format.decode_global_part(bs))
      keys.push(key)
    }
  }
  for i in 0..<decoded.length() {
    let gp = decoded[i]
    let key = keys[i]
    if gp.dim <= 0 {
      raise @core.Corrupt("global part dim must be positive: \{key}")
    }
    if gdim == 0 {
      gdim = gp.dim
    } else if gdim != gp.dim {
      raise @core.Corrupt(
        "global part dim mismatch: \{gdim} vs \{gp.dim} (\{key})",
      )
    }
    match manifest {
      Some(om) =>
        for r in gp.rows {
          if r.0 < 0 ||
            r.0 >= om.segments.length() ||
            r.1 < 0 ||
            r.1 >= om.segments[r.0].row_count {
            raise @core.Corrupt(
              "global part row out of range: (\{r.0},\{r.1}) in \{key}",
            )
          }
        }
      None => ()
    }
    parts.push(gp)
  }
  if expected_dim > 0 && gdim != 0 && gdim != expected_dim {
    raise @core.Corrupt(
      "global gen \{ver} dim \{gdim} != expected \{expected_dim}",
    )
  }
  (gm, if gdim == 0 { expected_dim } else { gdim }, parts)
}

///|
/// 读 segment meta.json 的 vec_normalized 标志（旧数据缺省 false）。
async fn[S : @store.ObjectStore] segment_vec_normalized(
  store : S,
  ns : String,
  seg_id : String,
) -> Bool {
  let key = "\{ns}/_segments/\{seg_id}/meta.json"
  let bs = match store.get(key) {
    Some(b) => b
    None => raise @core.NotFound(key)
  }
  let m = match bytes_to_json(bs, "seg meta.json") {
    Object(mm) => mm
    _ => raise @core.Corrupt("seg meta.json is not an object")
  }
  match m.get("vec_normalized") {
    Some(j) => j == Json::boolean(true)
    None => false
  }
}

///|
/// 把一行向量归一化（零向量原样）。
fn normalize_one(v : Array[Float], dim : Int) -> Array[Float] {
  pq_normalize(v, dim)
}

///|
/// 读 segment meta.json 的 partitions（cid 升序）。
async fn[S : @store.ObjectStore] segment_partitions(
  store : S,
  ns : String,
  seg_id : String,
) -> Array[Int] {
  let key = "\{ns}/_segments/\{seg_id}/meta.json"
  let bs = match store.get(key) {
    Some(b) => b
    None => raise @core.NotFound(key)
  }
  let j = bytes_to_json(bs, "seg meta.json")
  let m = match j {
    Object(mm) => mm
    _ => raise @core.Corrupt("seg meta.json is not an object")
  }
  let out : Array[Int] = Array()
  match m.get("partitions") {
    Some(Array(arr)) =>
      for p in arr {
        match p {
          Number(d, ..) => out.push(d.to_int())
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
/// 把向量分配到最近中心（与 write_segment 同语义）。
fn assign_cid(v : Array[Float], cent : @format.Centroids, dim : Int) -> Int {
  let k = cent.k()
  if k <= 0 {
    return 0
  }
  let adim = if cent.dim > 0 { cent.dim } else { dim }
  let mut best = 0
  let mut best_d = @core.cosine_dist_f32(v, 0, cent.data, 0, adim)
  for c in 1..<k {
    let d = @core.cosine_dist_f32(v, 0, cent.data, c * adim, adim)
    if d < best_d {
      best_d = d
      best = c
    }
  }
  best
}

///|
/// 构建 manifest 对应的全局 IVF 分区 **单副本**：向量只存在 global part 里，
/// 不再写 per-segment `rows/vector.bin` / `vec/part-*`。
///
/// - `old_global_version` 有值时，从旧 global 代拷旧段向量：manifest 有
///   `global_gen` 则遍历 base + 全部 deltas（否则只有该单代）；
/// - 否则从旧段的 per-segment part 拷贝（兼容旧数据）；
/// - 新段向量直接从 `docs[new_ranges[j]]` 计算，不读盘；
/// - `new_ranges[j]` 是第 j 个新段在 docs 中的 [start, end)；
/// - `old_seg_count` 是旧段数量（新段 seg_idx = old_seg_count + j）。
async fn[S : @store.ObjectStore] rebuild_global_vec_parts(
  store : S,
  cfg : BuildConfig,
  ns : String,
  cent : @format.Centroids,
  manifest : @format.ManifestData,
  old_manifest : @format.ManifestData?,
  old_global_version : String?,
  docs : Array[@core.Doc],
  new_ranges : Array[(Int, Int)],
  old_seg_count : Int,
) -> Array[Int] {
  let base = "\{ns}/vec/global/\{manifest.id}"
  let k = if cent.k() > 0 { cent.k() } else { 1 }
  let dim = if cent.dim > 0 { cent.dim } else { cfg.vector_dim }
  let rows : Array[Array[(Int, Int)]] = Array(capacity=k)
  let data : Array[Array[Float]] = Array(capacity=k)
  let mut part_bytes = 0
  for _ in 0..<k {
    rows.push(Array())
    data.push(Array())
  }
  if dim <= 0 {
    let m : Map[String, Json] = Map([])
    m.set("cids", Json::array([]))
    store.put("\{base}/meta.json", json_bytes(Json::object(m)))
    return []
  }
  // 旧段向量：优先 global 代际链（`global_gen` 的 base + deltas；旧布局只有
  // `old_global_version` 单代），回退 per-segment part。
  // 每代可能用不同 normalize 设置构建：只有「该代未归一化且新配置要归一化」时
  // 才逐行归一化；已归一化的数据在 cosine 下仍然正确。
  // S2b：只读 base 会丢掉 delta 之后写入的新段向量，所以链必须逐代读完。
  let chain_base = match old_manifest {
    Some(om) =>
      match om.global_gen {
        Some(g) => if g.base != "" { g.base } else { "" }
        None => ""
      }
    None => ""
  }
  let old_gens : Array[String] = match old_manifest {
    Some(om) =>
      match om.global_gen {
        // 新布局：整条链（base + 全部 deltas）都要拷进新 base。
        Some(g) =>
          if g.base != "" {
            global_gen_versions(om)
          } else {
            match old_global_version {
              Some(v) => [v]
              None => []
            }
          }
        // 旧布局：单代全量 base。
        None =>
          match old_global_version {
            Some(v) => [v]
            None => []
          }
      }
    None =>
      match old_global_version {
        Some(v) => [v]
        None => []
      }
  }
  if old_gens.length() > 0 {
    for gen_ver in old_gens {
      let (gm, _gdim, parts) = read_global_gen_parts(
        store, ns, gen_ver, old_manifest, dim, chain_base,
      )
      let need_norm = cfg.normalize_vecs && !global_meta_normalized(gm)
      for gp in parts {
        let cid = gp.cid
        if cid < 0 || cid >= k {
          continue
        }
        for i in 0..<gp.rows.length() {
          let (si, row) = gp.rows[i]
          rows[cid].push((si, row))
          if need_norm {
            let v : Array[Float] = Array(capacity=dim)
            for d in 0..<dim {
              v.push(gp.data[i * dim + d])
            }
            for x in normalize_one(v, dim) {
              data[cid].push(x)
            }
          } else {
            for d in 0..<dim {
              data[cid].push(gp.data[i * dim + d])
            }
          }
        }
      }
    }
  } else {
    match old_manifest {
      Some(om) =>
        for si in 0..<om.segments.length() {
          let seg = om.segments[si]
          let old_norm = segment_vec_normalized(store, ns, seg.id)
          let need_norm = cfg.normalize_vecs && !old_norm
          for cid in segment_partitions(store, ns, seg.id) {
            if cid >= k {
              continue
            }
            let key = "\{ns}/_segments/\{seg.id}/vec/part-\{cid}.bin"
            let bs = match store.get(key) {
              Some(b) => b
              None => raise @core.NotFound(key)
            }
            let part = @format.decode_part(bs)
            if part.dim != dim {
              raise @core.Corrupt(
                "segment part dim \{part.dim} != \{dim} (\{key})",
              )
            }
            for j in 0..<part.rows.length() {
              rows[cid].push((si, part.rows[j]))
              if need_norm {
                let v : Array[Float] = Array(capacity=dim)
                for d in 0..<dim {
                  v.push(part.data[j * dim + d])
                }
                for x in normalize_one(v, dim) {
                  data[cid].push(x)
                }
              } else {
                for d in 0..<dim {
                  data[cid].push(part.data[j * dim + d])
                }
              }
            }
          }
        }
      None => ()
    }
  }
  // 新段向量：直接来自 docs（不读盘）。写 global part 的必须是最终向量：
  // normalize_vecs=true 时先归一化，否则 seg meta 的 vec_normalized 会与实际
  // 数据不一致，查询按 dot 打分导致排序被模长污染（review P0-2）。
  for j in 0..<new_ranges.length() {
    let (start, end) = new_ranges[j]
    let si = old_seg_count + j
    for r in start..<end {
      let raw = docs[r].vector
      let v = if cfg.normalize_vecs { normalize_one(raw, dim) } else { raw }
      let cid = assign_cid(v, cent, dim)
      rows[cid].push((si, r - start))
      for d in 0..<dim {
        data[cid].push(v[d])
      }
    }
  }
  // 写新代 global part（每 cid 一个对象，或按 cfg.global_pack_size 打包）
  let built : Array[(Int, Bytes)] = Array()
  for cid in 0..<k {
    if rows[cid].length() == 0 {
      continue
    }
    let bs = @format.encode_global_part(
      cid,
      rows[cid],
      dim,
      data[cid],
      cfg.use_f16,
    )
    built.push((cid, bs))
  }
  let (cids, wrote_bytes) = put_global_parts(store, base, built, cfg.global_pack_size)
  part_bytes += wrote_bytes
  let m : Map[String, Json] = Map([])
  let arr : Array[Json] = Array(capacity=cids.length())
  for c in cids {
    arr.push(Json::number(c.to_double()))
  }
  m.set("cids", Json::array(arr))
  m.set("dim", Json::number(dim.to_double()))
  m.set("normalized", Json::boolean(cfg.normalize_vecs))
  m.set("created_ms", Json::number(@env.now().to_double()))
  m.set("bytes", Json::number(part_bytes.to_double()))
  if cfg.global_pack_size > 1 {
    m.set("pack_size", Json::number(cfg.global_pack_size.to_double()))
  }
  let seg_ids : Array[Json] = Array(capacity=manifest.segments.length())
  for s in manifest.segments {
    seg_ids.push(Json::string(s.id))
  }
  m.set("seg_ids", Json::array(seg_ids))
  store.put("\{base}/meta.json", json_bytes(Json::object(m)))
  cids
}

///|
/// 把 (cid, part blob) 列表（cid 升序）落盘：
/// - pack_size=1（默认）：每 cid 一个 `part-{cid}.bin`（旧行为，字节不变）；
/// - pack_size=P>1：按 cid/P 分相邻组，每组一个 `pack-{i}.bin`（SPNDGVPK，
///   见 @format.encode_global_pack；调用方在 meta.json 记 `"pack_size"`）。
/// 返回 (cids 升序, 落盘总字节)。
async fn[S : @store.ObjectStore] put_global_parts(
  store : S,
  dir : String,
  parts : Array[(Int, Bytes)],
  pack_size : Int,
) -> (Array[Int], Int) {
  let cids : Array[Int] = Array(capacity=parts.length())
  let mut bytes = 0
  if pack_size <= 1 {
    let items : Array[(String, Bytes)] = Array(capacity=parts.length())
    for p in parts {
      items.push(("\{dir}/part-\{p.0}.bin", p.1))
      cids.push(p.0)
      bytes += p.1.length()
    }
    store.put_many(items)
    return (cids, bytes)
  }
  // 打包：parts 升序 ⇒ 按 cid/P 分组后组内 cid 连续。
  let group : Array[(Int, Bytes)] = Array()
  let items : Array[(String, Bytes)] = Array()
  let mut cur_pack = -1
  for p in parts {
    let pk = p.0 / pack_size
    if pk != cur_pack && group.length() > 0 {
      let bs = @format.encode_global_pack(group)
      items.push(("\{dir}/pack-\{cur_pack}.bin", bs))
      bytes += bs.length()
      group.clear()
    }
    cur_pack = pk
    group.push(p)
    cids.push(p.0)
  }
  if group.length() > 0 {
    let bs = @format.encode_global_pack(group)
    items.push(("\{dir}/pack-\{cur_pack}.bin", bs))
    bytes += bs.length()
  }
  store.put_many(items)
  (cids, bytes)
}

///|
/// 写一个 **delta 代**：只把本批新段的向量写进新代目录
/// `vec/global/{manifest.id}/part-{cid}.bin`，**不读** 旧 base / 旧 delta。
///
/// - rows = (seg_idx, row)，seg_idx = old_seg_count + j（manifest.segments 下标），
///   与新 base 路径完全同语义，读者可用同一套解码逻辑；
/// - 归一化语义与 `rebuild_global_vec_parts` 一致（`cfg.normalize_vecs` ⇒ 落盘前
///   L2 归一化），保证 delta 行与 base 行的打分口径相同；
/// - meta.json 复用 base 代字段（cids/dim/normalized/created_ms/seg_ids），另加
///   `"kind":"delta"` 与 `"base": <旧 base 版本>`；`seg_ids` 只列本代覆盖的新段。
///
/// 返回实际写出的 cid 列表。
async fn[S : @store.ObjectStore] write_global_delta_parts(
  store : S,
  cfg : BuildConfig,
  ns : String,
  cent : @format.Centroids,
  manifest : @format.ManifestData,
  base_version : String,
  docs : Array[@core.Doc],
  new_ranges : Array[(Int, Int)],
  old_seg_count : Int,
) -> Array[Int] {
  let dir = "\{ns}/vec/global/\{manifest.id}"
  let k = if cent.k() > 0 { cent.k() } else { 1 }
  let dim = if cent.dim > 0 { cent.dim } else { cfg.vector_dim }
  let rows : Array[Array[(Int, Int)]] = Array(capacity=k)
  let data : Array[Array[Float]] = Array(capacity=k)
  let mut part_bytes = 0
  for _ in 0..<k {
    rows.push(Array())
    data.push(Array())
  }
  let built : Array[(Int, Bytes)] = Array()
  if dim > 0 {
    // 新段向量：直接来自 docs（不读盘），分配与归一化同 base 路径。
    for j in 0..<new_ranges.length() {
      let (start, end) = new_ranges[j]
      let si = old_seg_count + j
      for r in start..<end {
        let raw = docs[r].vector
        let v = if cfg.normalize_vecs { normalize_one(raw, dim) } else { raw }
        let cid = assign_cid(v, cent, dim)
        rows[cid].push((si, r - start))
        for d in 0..<dim {
          data[cid].push(v[d])
        }
      }
    }
    for cid in 0..<k {
      if rows[cid].length() == 0 {
        continue
      }
      let bs = @format.encode_global_part(
        cid,
        rows[cid],
        dim,
        data[cid],
        cfg.use_f16,
      )
      built.push((cid, bs))
    }
  }
  let (cids, wrote_bytes) = put_global_parts(store, dir, built, cfg.global_pack_size)
  part_bytes += wrote_bytes
  let m : Map[String, Json] = Map([])
  let arr : Array[Json] = Array(capacity=cids.length())
  for c in cids {
    arr.push(Json::number(c.to_double()))
  }
  m.set("cids", Json::array(arr))
  m.set("dim", Json::number(dim.to_double()))
  m.set("normalized", Json::boolean(cfg.normalize_vecs))
  m.set("created_ms", Json::number(@env.now().to_double()))
  m.set("bytes", Json::number(part_bytes.to_double()))
  if cfg.global_pack_size > 1 {
    m.set("pack_size", Json::number(cfg.global_pack_size.to_double()))
  }
  let seg_ids : Array[Json] = Array(capacity=new_ranges.length())
  for j in 0..<new_ranges.length() {
    let si = old_seg_count + j
    if si >= 0 && si < manifest.segments.length() {
      seg_ids.push(Json::string(manifest.segments[si].id))
    }
  }
  m.set("seg_ids", Json::array(seg_ids))
  m.set("kind", Json::string("delta"))
  m.set("base", Json::string(base_version))
  store.put("\{dir}/meta.json", json_bytes(Json::object(m)))
  cids
}

///|
/// 立即 GC 旧代全局 IVF 分区：只保留 `keep_version`。这是显式维护入口；
/// 正常写入路径用 `gc_global_versions_grace`，避免删掉 in-flight 查询的旧代。
pub async fn[S : @store.ObjectStore] gc_global_versions(
  store : S,
  ns : String,
  keep_version : String,
) -> Unit {
  gc_global_versions_grace(store, ns, keep_version, 0UL)
}

///|
/// 从 key 中提取 global 版本号：`{ns}/vec/global/{ver}/...`。
fn global_version_of_key(prefix : String, key : String) -> String? {
  if !key.has_prefix(prefix) {
    return None
  }
  let rest = key[prefix.length():]
  match rest.find("/") {
    Some(i) => Some(rest[:i].to_owned())
    None => None
  }
}

///|
/// 按时间 grace GC 旧代，保留 `keep_versions` 集合。单版本入口见
/// `gc_global_versions_grace`（签名/语义不变）。
///
/// keep 集合内的代永不删除。任何非 keep 代的替代时刻取「后继代 created_ms」
/// 与「created_ms 不早于它的最早 keep 代 created_ms」中的较大者：
/// compact_global 把整条旧链折成一个新 base 时，旧 base + 全部 deltas 是
/// 被**同一个**新 base 同时替代的，不能只看链内相邻代的创建时间，否则旧 base
/// 可能在 in-flight 查询仍引用它时就被回收。
pub async fn[S : @store.ObjectStore] gc_global_versions_grace_keep(
  store : S,
  ns : String,
  keep_versions : Array[String],
  grace_ms : UInt64,
) -> Unit {
  let keep : Set[String] = Set([])
  for v in keep_versions {
    keep.add(v)
  }
  let prefix = "\{ns}/vec/global/"
  let now = @env.now()
  let keys = store.list(prefix)
  // 收集 unique version + (meta 是否存在, created_ms)。
  let vers : Array[(String, Bool, UInt64)] = Array()
  let seen : Set[String] = Set([])
  for key in keys {
    let ver = match global_version_of_key(prefix, key) {
      Some(v) => v
      None => continue
    }
    if seen.contains(ver) {
      continue
    }
    seen.add(ver)
    let mkey = "\{prefix}\{ver}/meta.json"
    let (has_meta, created) = match store.get(mkey) {
      Some(bs) =>
        match bytes_to_json(bs, "global meta") {
          Object(m) =>
            match m.get("created_ms") {
              Some(Number(x, ..)) => (true, x.to_uint64())
              _ => (true, 0UL)
            }
          _ => (true, 0UL)
        }
      None => (false, 0UL)
    }
    vers.push((ver, has_meta, created))
  }
  // 显式 GC：不做 grace 判断，直接删非 keep 代。
  if grace_ms == 0UL {
    for key in keys {
      let ver = match global_version_of_key(prefix, key) {
        Some(v) => v
        None => ""
      }
      if !keep.contains(ver) {
        store.delete(key)
      }
    }
    return
  }
  // keep 代可能没有 global meta（例如 compact 成全 tombstone 空 manifest）：
  // 把它当成 now 时刻的替代者，旧代从 now 起算 grace。
  let order = vers.copy()
  for kv in keep_versions {
    if !seen.contains(kv) {
      order.push((kv, false, now))
    }
  }
  order.sort_by(fn(a, b) {
    if a.2 == b.2 {
      a.0.compare(b.0)
    } else {
      a.2.compare(b.2)
    }
  })
  // keep 代的实际创建时间（缺失 meta 的 keep 用 now）。
  let keep_times : Array[(String, UInt64)] = Array(
    capacity=keep_versions.length(),
  )
  for kv in keep_versions {
    let mut created = now
    for v in vers {
      let (ver, has_meta, c) = v
      if ver == kv && has_meta {
        created = c
      }
    }
    keep_times.push((kv, created))
  }
  let to_delete : Set[String] = Set([])
  for i in 0..<order.length() {
    let (ver, has_meta, created) = order[i]
    if keep.contains(ver) || !has_meta {
      continue
    }
    let mut replaced_ms = 0UL
    if i + 1 < order.length() {
      let (sver, shas, screated) = order[i + 1]
      if !shas {
        if keep.contains(sver) {
          replaced_ms = now
        } else {
          // 后继代 meta 缺失且不是当前 keep：替代时刻未知，安全起见不删。
          continue
        }
      } else {
        replaced_ms = screated
      }
    }
    // 整条旧链被 keep 代（compact 后的新 base）统一替代：取不早于本代的最早
    // keep 创建时间，和相邻后继取较大者，保证旧链在 grace 内都可读。
    let mut keep_replaced = 0UL
    for kt in keep_times {
      let (kv, kc) = kt
      if kv == ver || kc < created {
        continue
      }
      if keep_replaced == 0UL || kc < keep_replaced {
        keep_replaced = kc
      }
    }
    if keep_replaced > replaced_ms {
      replaced_ms = keep_replaced
    }
    if replaced_ms != 0UL && now >= replaced_ms + grace_ms {
      to_delete.add(ver)
    }
  }
  if to_delete.is_empty() {
    return
  }
  for key in keys {
    match global_version_of_key(prefix, key) {
      Some(ver) => if to_delete.contains(ver) { store.delete(key) }
      None => ()
    }
  }
}

///|
/// 按时间 grace GC 旧代，只保留 `keep_version`。语义见
/// `gc_global_versions_grace_keep`；本入口保持旧签名不变。
pub async fn[S : @store.ObjectStore] gc_global_versions_grace(
  store : S,
  ns : String,
  keep_version : String,
  grace_ms : UInt64,
) -> Unit {
  gc_global_versions_grace_keep(store, ns, [keep_version], grace_ms)
}

///|
/// 一个 global 代的全部对象字节数（meta + parts）。用于 delta 链的合并阈值。
async fn[S : @store.ObjectStore] global_gen_bytes(
  store : S,
  ns : String,
  ver : String,
) -> Int {
  // 新格式把 part 字节数写进 meta，阈值检查不再读整个 base。
  let gm = read_global_meta(store, ns, ver)
  match gm.get("bytes") {
    Some(Number(d, ..)) => d.to_int()
    _ => {
      // 旧格式兜底：只有维护期/首次 compact 会走到这里。
      let mut total = 0
      for key in store.list("\{ns}/vec/global/\{ver}/") {
        match store.get(key) {
          Some(bs) => total += bs.length()
          None => ()
        }
      }
      total
    }
  }
}

///|
/// 把当前 head 的 global delta 链（base + deltas）合并成一个新的全量 base：
/// - 无 `global_gen` 或 deltas 为空 ⇒ no-op（不生成 manifest）；
/// - 新 manifest 复制旧 segments/deleted/centroid_version 等，只改
///   `vec_global_version = Some(new_id)`、`global_gen = None`、`parent = old.id`；
/// - 复用 `rebuild_global_vec_parts` 读完整条旧链写 `vec/global/{new_id}`；
/// - CAS 发布后用 grace GC 回收旧 base + deltas（新 base 保留），失败不破坏旧 head。
pub async fn[S : @store.ObjectStore] compact_global(
  store : S,
  cfg : BuildConfig,
  ns : String,
) -> Unit {
  let meta = match read_namespace(store, ns) {
    Some(m) => m
    None => raise @core.NotFound("namespace not found: \{ns}")
  }
  if meta.head_manifest == "" {
    raise @core.NotFound("no manifest published yet: \{ns}")
  }
  let old = load_manifest(store, ns, meta.head_manifest)
  match old.global_gen {
    Some(g) => if g.base == "" || g.deltas.length() == 0 { return }
    None => return
  }
  let cent = load_centroids(store, ns, old.centroid_version)
  let new_id = new_manifest_id()
  let manifest : @format.ManifestData = {
    id: new_id,
    parent: Some(old.id),
    segments: old.segments,
    deleted: old.deleted,
    deleted_roar: old.deleted_roar,
    vec_global_version: Some(new_id),
    global_gen: None,
    centroid_version: old.centroid_version,
    num_docs: old.num_docs,
    avg_doc_len: old.avg_doc_len,
  }
  // old_manifest = 当前 head（带 global_gen）⇒ 读 base + 全部 deltas；
  // old_global_version = None、docs 空、new_ranges 空 ⇒ 只做旧链拷贝。
  let _ = rebuild_global_vec_parts(
    store,
    cfg,
    ns,
    cent,
    manifest,
    Some(old),
    None,
    [],
    [],
    0,
  )
  store.put(manifest_key(ns, manifest.id), json_bytes(manifest.to_json()))
  publish_head(store, ns, old.id, manifest.id)
  // 旧链在 grace 内保留；只把新 base 列进 keep 集合。
  gc_global_versions_grace_keep(store, ns, [manifest.id], GLOBAL_GC_GRACE_MS)
}

///|
/// 阈值触发 `compact_global`：delta 数 >= `max_deltas`，或 delta 总字节 /
/// base 字节 >= 0.3（base 为空时只要 delta 非空就触发）。无链 / 空链 no-op。
/// 自动合并失败直接向上抛错（不静默吞掉）。
pub async fn[S : @store.ObjectStore] maybe_compact_global(
  store : S,
  cfg : BuildConfig,
  ns : String,
  max_deltas : Int,
) -> Unit {
  let meta = match read_namespace(store, ns) {
    Some(m) => m
    None => return
  }
  if meta.head_manifest == "" {
    return
  }
  let old = load_manifest(store, ns, meta.head_manifest)
  let gen = match old.global_gen {
    Some(g) => g
    None => return
  }
  if gen.base == "" || gen.deltas.length() == 0 {
    return
  }
  let mut trigger = gen.deltas.length() >= max_deltas
  if !trigger {
    let base_bytes = global_gen_bytes(store, ns, gen.base)
    let mut delta_bytes = 0
    for d in gen.deltas {
      delta_bytes += global_gen_bytes(store, ns, d)
    }
    let ratio = if base_bytes > 0 {
      delta_bytes.to_double() / base_bytes.to_double()
    } else if delta_bytes > 0 {
      1.0
    } else {
      0.0
    }
    // 数量是主触发（读放大上界 = max_deltas + 1 代）；比例只在链已经
    // 明显偏大时提前合并，避免小 base 的 2~3 批就全量重写。
    trigger = gen.deltas.length() >= max_deltas ||
      (gen.deltas.length() >= 4 && ratio >= 0.5)
  }
  if trigger {
    compact_global(store, cfg, ns)
  }
}
