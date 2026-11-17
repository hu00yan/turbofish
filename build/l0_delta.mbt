// build/l0_delta.mbt: L0 单文件 Delta Slab 写入 + 无阻塞乐观 Rebase Compaction。
//
// 问题：传统 `ingest` 每批 docs 要写 ~84 个对象（六列 + fts + 每个 cid 一个
// part + meta.json + manifest + head log + head 指针），小批量写入被 S3 PUT 次数
// 拖死。
//
// 本文件的两条新路径：
// 1. `ingest_l0_slab`：一批 docs 打成**单个** `{ns}/_segments/{slabseg-...}/
//    segment.slab`（SlabV2 单文件布局，六列 + 倒排 + meta 全在 slab 里），
//    只额外写 manifest + head（+ 可选 tombstone）。已初始化 namespace 下
//    500 条带向量文档 = 4 次 PUT（≤ 5 硬指标）。
// 2. `compact_optimistic`：拍快照合并前缀段，**乐观 rebase** 发布——合并期间
//    并发写的新段（tail）与新增墓碑全部保留；CAS 冲突只重读 head 重组 manifest
//    JSON 重试，绝不重传已上传的大段，也不阻塞前台写入。
//
// 段布局标记：L0 slab 段的 id 前缀为 `slabseg-`（manifest 里即可判定，零额外
// 读）；`segment_is_slab` 额外容忍 `write_segment_slab` 写出的 `seg-*` +
// `segment.slab`（旧 slab 数据）。

///|
/// L0 单文件段 id 前缀。`slabseg-{ts}-{writer}-{seq}`。
pub const SLAB_SEG_PREFIX : String = "slabseg"

///|
/// superseded 段回收（`gc_superseded_segments`）的 grace 窗口：段被合并掉后，
/// 旧 manifest 的在途读者可能仍引用它；只有超窗后仍不被任何 live manifest
/// 引用的段才物理删除。语义对齐 `GLOBAL_GC_GRACE_MS`（时间宽限），默认 300s。
pub const SEGMENT_GC_GRACE_MS : UInt64 = 300000UL

///|
/// 生成 L0 单文件段 id（可排序，前缀即存储布局标记）。
fn new_slab_segment_id() -> String {
  new_scoped_id(SLAB_SEG_PREFIX)
}

///|
/// id 前缀判定：L0 单文件 SlabV2 段。
pub fn is_l0_slab_segment(seg_id : String) -> Bool {
  seg_id.has_prefix(SLAB_SEG_PREFIX + "-")
}

///|
/// 合并两组 id：去重 + 升序（不依赖 Hash，语义同 `delete_docs`）。
fn merge_sorted_ids(a : Array[UInt64], b : Array[UInt64]) -> Array[UInt64] {
  let all : Array[UInt64] = Array(capacity=a.length() + b.length())
  for x in a {
    all.push(x)
  }
  for x in b {
    all.push(x)
  }
  all.sort_by(fn(x, y) { x.compare(y) })
  let out : Array[UInt64] = Array(capacity=all.length())
  for i in 0..<all.length() {
    if i == 0 || out[out.length() - 1] != all[i] {
      out.push(all[i])
    }
  }
  out
}

///|
/// 两个已排序 id 数组是否逐元素相等。
fn same_ids(a : Array[UInt64], b : Array[UInt64]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i in 0..<a.length() {
    if a[i] != b[i] {
      return false
    }
  }
  true
}

///|
/// 段的兼容元对象 key：`{ns}/_segments/{seg_id}/meta.json`。
/// slab 内也内嵌同一份 meta（"meta" 组件），但这个对象是所有读者的公共契约。
pub fn segment_meta_key(ns : String, seg_id : String) -> String {
  "\{ns}/_segments/\{seg_id}/meta.json"
}

///|
/// 段是否为 SlabV2 单文件布局：`slabseg-` 前缀（L0）或 `segment.slab` 存在
/// （旧 `write_segment_slab` 输出）。后者需要 1 次 HEAD_Version 探测。
pub async fn[S : @store.ObjectStore] segment_is_slab(
  store : S,
  ns : String,
  seg_id : String,
) -> Bool {
  if is_l0_slab_segment(seg_id) {
    return true
  }
  match store.head_version(segment_slab_key(ns, seg_id)) {
    Some(_) => true
    None => false
  }
}

///|
/// 从 slab 的 `vec/part-{c}` 分区重组向量列（Step 1 起 slab 不写扁平 `"vector"`）。
/// 每行恰在一个 part 里，按 rows 下标散布回行主序；PQ 共享码本分区用
/// `vec/pq-codebook` 重建（码本中心近似）。返回 (dim, rows×dim)。
async fn[S : @store.ObjectStore] rebuild_vec_from_parts(
  store : S,
  ns : String,
  seg_id : String,
  index : @format.SlabIndex,
  n : Int,
) -> (Int, Array[Float]) {
  let mut vdim = 0
  let flat : Array[Float] = Array(capacity=n)
  for e in index.entries {
    if !e.name.has_prefix("vec/part-") {
      continue
    }
    let bs = read_slab_component_by_name(store, ns, seg_id, index, e.name)
    let (rows, data, d) = if @format.is_pq_shared_part(bs) {
      let pq = @format.decode_pq_part_shared(bs)
      let (m, dsub, _, cbs) = match index.get("vec/pq-codebook") {
        Some(_) =>
          @format.decode_pq_codebook(
            read_slab_component_by_name(
              store, ns, seg_id, index, "vec/pq-codebook",
            ),
          )
        None => raise @core.NotFound("\{segment_slab_key(ns, seg_id)} vec/pq-codebook")
      }
      if m != pq.m || dsub != pq.dsub {
        raise @core.Corrupt("pq codebook mismatch in \{seg_id}")
      }
      let data : Array[Float] = Array(capacity=pq.rows.length() * pq.dim)
      for i in 0..<pq.rows.length() {
        for c in 0..<pq.m {
          let code = pq.codes[i * pq.m + c].reinterpret_as_int()
          for l in 0..<pq.dsub {
            data.push(cbs[(c * 256 + code) * pq.dsub + l])
          }
        }
      }
      (pq.rows, data, pq.dim)
    } else if @format.is_pq_part(bs) {
      let pq = @format.decode_pq_part(bs)
      let data : Array[Float] = Array(capacity=pq.rows.length() * pq.dim)
      for i in 0..<pq.rows.length() {
        for c in 0..<pq.m {
          let code = pq.codes[i * pq.m + c].reinterpret_as_int()
          for l in 0..<pq.dsub {
            data.push(pq.codebooks[(c * 256 + code) * pq.dsub + l])
          }
        }
      }
      (pq.rows, data, pq.dim)
    } else {
      let part = @format.decode_part(bs)
      (part.rows, part.data, part.dim)
    }
    if vdim == 0 {
      vdim = d
      for _ in 0..<(n * vdim) {
        flat.push(0.0)
      }
    }
    if d != vdim {
      raise @core.Corrupt("part dim mismatch in \{seg_id}")
    }
    for i in 0..<rows.length() {
      let r = rows[i]
      if r < 0 || r >= n {
        raise @core.Corrupt("part row \{r} out of range in \{seg_id}")
      }
      for dd in 0..<vdim {
        flat[r * vdim + dd] = data[i * vdim + dd]
      }
    }
  }
  if vdim == 0 {
    raise @core.Corrupt("slab segment has no vector components: \{seg_id}")
  }
  (vdim, flat)
}

///|
/// 读 SlabV2 单文件段的六列并重建 Doc 数组（顺序 = 段内行号）。
/// `preloaded` 非空时（旧全局 IVF 单副本数据）向量来自 global part；否则优先读
/// 扁平 `vector` 组件（旧数据），没有则从 `vec/part-{c}` 分区重组
///（Step 1 起 slab 恒写分区、不写扁平 `vector`）。
async fn[S : @store.ObjectStore] load_slab_docs(
  store : S,
  ns : String,
  seg : @format.SegmentMeta,
  preloaded : Array[Float]?,
  preloaded_dim : Int,
) -> Array[@core.Doc] {
  let index = read_slab_index(store, ns, seg.id, seg.size_bytes)
  let cell = async fn(name : String) -> Bytes {
    read_slab_component_by_name(store, ns, seg.id, index, name)
  }
  let ids = match @format.decode_col(cell("id")) {
    @format.ColU64(a) => a
    _ => raise @core.Corrupt("slab id column dtype is not u64")
  }
  let texts = match @format.decode_col(cell("text")) {
    @format.ColStr(a) => a
    _ => raise @core.Corrupt("slab text column dtype is not str")
  }
  let cats = match @format.decode_col(cell("category")) {
    @format.ColStr(a) => a
    _ => raise @core.Corrupt("slab category column dtype is not str")
  }
  let tss = match @format.decode_col(cell("ts")) {
    @format.ColI64(a) => a
    _ => raise @core.Corrupt("slab ts column dtype is not i64")
  }
  let pubs = match @format.decode_col(cell("public")) {
    @format.ColBool(a) => a
    _ => raise @core.Corrupt("slab public column dtype is not bool")
  }
  let (dim, vec) = match preloaded {
    Some(v) => (preloaded_dim, v)
    None =>
      match index.get("vector") {
        Some(_) => @format.decode_vec_col(cell("vector"))
        None => rebuild_vec_from_parts(store, ns, seg.id, index, ids.length())
      }
  }
  let n = ids.length()
  if texts.length() != n ||
    cats.length() != n ||
    tss.length() != n ||
    pubs.length() != n ||
    vec.length() != n * dim {
    raise @core.Corrupt("slab: column length mismatch in \{seg.id}")
  }
  let docs : Array[@core.Doc] = Array(capacity=n)
  for i in 0..<n {
    let v : Array[Float] = Array(capacity=dim)
    for d in 0..<dim {
      v.push(vec[i * dim + d])
    }
    docs.push({
      id: ids[i],
      text: texts[i],
      vector: v,
      category: cats[i],
      ts: tss[i],
      public: pubs[i],
    })
  }
  docs
}

///|
/// 读一个段的六列并重建 Doc 数组：自动派发 SlabV2 单文件 / Legacy 多文件。
pub async fn[S : @store.ObjectStore] load_segment_docs(
  store : S,
  ns : String,
  seg : @format.SegmentMeta,
  preloaded : Array[Float]?,
  preloaded_dim : Int,
) -> Array[@core.Doc] {
  if segment_is_slab(store, ns, seg.id) {
    load_slab_docs(store, ns, seg, preloaded, preloaded_dim)
  } else {
    compact_load_docs(store, ns, seg.id, preloaded, preloaded_dim)
  }
}

///|
/// 从 `segs`（依次为每段全部行）构建一个**全量**全局 IVF base 代：
/// `vec/global/{manifest_id}/part-{cid}.bin`（或 pack）。`seg_docs[i]` 的行对应
/// manifest.segments[i]，含 tombstone 行（global part 必须覆盖每段的每一行）。
///
/// 与 `rebuild_global_vec_parts` 的区别：不需要旧 manifest 的 global 代际链，
/// 直接由内存中的段文档重建整代（compact 语义），因此可以任意重排段序。
async fn[S : @store.ObjectStore] write_global_base_from_segs(
  store : S,
  cfg : BuildConfig,
  ns : String,
  cent : @format.Centroids,
  manifest_id : String,
  segs : Array[@format.SegmentMeta],
  seg_docs : Array[Array[@core.Doc]],
) -> Array[Int] {
  let dir = "\{ns}/vec/global/\{manifest_id}"
  let k = if cent.k() > 0 { cent.k() } else { 1 }
  let dim = if cent.dim > 0 { cent.dim } else { cfg.vector_dim }
  let rows : Array[Array[(Int, Int)]] = Array(capacity=k)
  let data : Array[Array[Float]] = Array(capacity=k)
  for _ in 0..<k {
    rows.push(Array())
    data.push(Array())
  }
  let mut part_bytes = 0
  if dim > 0 {
    for si in 0..<seg_docs.length() {
      let docs = seg_docs[si]
      for r in 0..<docs.length() {
        let raw = docs[r].vector
        let v = if cfg.normalize_vecs { normalize_one(raw, dim) } else { raw }
        let cid = assign_cid(v, cent, dim)
        rows[cid].push((si, r))
        for d in 0..<dim {
          data[cid].push(v[d])
        }
      }
    }
  }
  let built : Array[(Int, Bytes)] = Array()
  for cid in 0..<k {
    if rows[cid].length() == 0 {
      continue
    }
    built.push((
      cid,
      @format.encode_global_part(cid, rows[cid], dim, data[cid], cfg.use_f16),
    ))
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
  let seg_ids : Array[Json] = Array(capacity=segs.length())
  for s in segs {
    seg_ids.push(Json::string(s.id))
  }
  m.set("seg_ids", Json::array(seg_ids))
  store.put("\{dir}/meta.json", json_bytes(Json::object(m)))
  cids
}

///|
/// L0 单文件 Delta 写入：把一批 `docs`（可为空）+ `deletes` 编码成**一个**
/// `segment.slab` 段，合并 tombstone 后 CAS 发布新 manifest，返回新 manifest id。
///
/// 写入对象（已初始化 namespace、无删除时共 4 次 PUT）：
/// 1. `{ns}/_segments/{slabseg-...}/segment.slab`（六列 + 倒排 + meta 全在这一个
///    对象里；**不写** rows/*、fts/*、vec/part-* 碎片对象，**不重建**全局 IVF）
/// 2. `{ns}/_manifest/{id}.json`
/// 3. `_heads/{id}`（head log）
/// 4. `_head_ptr`（读者 1 次 GET 探测面）
/// 可选：`{ns}/_tombstones/{id}.roar`（仅当本批有 deletes 且集合变化）
///
/// 首次调用会初始化 namespace（namespace.json + schema.json）并训练/写入
/// centroids；之后复用头 manifest 钉住的 centroid_version。
///
/// 全局 IVF：**已停写**（Step 1 行为切换，向量恒随段内 `vec/part-*` 走）。
/// `ingest_l0_slab` 与 `compact_optimistic` 的 manifest 恒为
/// `vec_global_version = None` / `global_gen = None`；下面保留的代际链逻辑与
/// `write_global_delta_parts` / `rebuild_global_vec_parts` / 
/// `write_global_base_from_segs` 调用全部不执行（旧数据读路径仍兼容），
/// 等 Step 2 与 `build/globalvec.mbt` 一起删除。
pub async fn[S : @store.ObjectStore] ingest_l0_slab(
  store : S,
  cfg : BuildConfig,
  docs : Array[@core.Doc],
  deletes : Array[UInt64],
) -> String {
  let ns = cfg.ns
  // 1. 头 manifest（head_manifest 为 "" 视为无 live manifest）
  let old_meta : @format.NamespaceMeta? = read_namespace(store, ns)
  let mut expected_head = ""
  let old : @format.ManifestData? = match old_meta {
    Some(meta) => {
      expected_head = meta.head_manifest
      if meta.head_manifest == "" {
        None
      } else {
        Some(load_manifest(store, ns, meta.head_manifest))
      }
    }
    None => {
      init_namespace(store, cfg)
      None
    }
  }
  let old_global_version : String? = match old {
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
  // 2. centroids（已存在则只读，不新增 PUT）
  let (centroid_version, cent) = match old {
    Some(m) => (m.centroid_version, load_centroids(store, ns, m.centroid_version))
    None => {
      let v = new_centroid_version()
      let c : @format.Centroids = if docs.length() > 0 {
        train_centroids(docs, cfg.nlist, 8, cfg.distance_metric == "euclidean")
      } else {
        { dim: cfg.vector_dim, data: [] }
      }
      store.put(centroids_key(ns, v), @format.encode_centroids(c))
      (v, c)
    }
  }
  let new_id = new_manifest_id()
  // 3. 新 slab 段（单对象）+ 段列表
  let segs : Array[@format.SegmentMeta] = Array()
  let mut old_seg_count = 0
  match old {
    Some(m) => {
      for s in m.segments {
        segs.push(s)
      }
      old_seg_count = m.segments.length()
    }
    None => ()
  }
  let mut slab_write : (String, Bytes)? = None
  // 不变量：manifest 里的每个段都必须有可读的 `_segments/{id}/meta.json`。
  // query / compact / compact_global 都用它；slab 内嵌的 meta 只是读者优化。
  let mut meta_write : (String, Bytes)? = None
  if docs.length() > 0 {
    let seg_id = new_slab_segment_id()
    let (slab_bytes, meta_bytes, meta) = build_segment_slab(
      cfg, cent, docs, 0, docs.length(), seg_id~,
    )
    slab_write = Some((segment_slab_key(ns, seg_id), slab_bytes))
    meta_write = Some((segment_meta_key(ns, seg_id), meta_bytes))
    segs.push(meta)
  }
  // 4. tombstone（roar 对象只在删除集合变化时写）
  let old_deleted : Array[UInt64] = match old {
    Some(m) => m.deleted
    None => []
  }
  let old_roar : String? = match old {
    Some(m) => m.deleted_roar
    None => None
  }
  let deleted = merge_sorted_ids(old_deleted, deletes)
  let mut deleted_roar : String? = old_roar
  let mut tomb_write : (String, Bytes)? = None
  if !same_ids(deleted, old_deleted) {
    if deleted.is_empty() {
      deleted_roar = None
    } else {
      let tk = tombstone_key(ns, new_id)
      tomb_write = Some((tk, @format.encode_roaring(deleted)))
      deleted_roar = Some(new_id)
    }
  }
  // 5. 统计 + 全局 IVF 代际链
  let mut total_rows = 0
  let mut total_doclen = 0
  for s in segs {
    total_rows += s.row_count
    total_doclen += s.doc_len_sum
  }
  let avg_doc_len = if total_rows > 0 {
    total_doclen.to_double() / total_rows.to_double()
  } else {
    0.0
  }
  // 全局代际链已停写（Step 1）：恒 false，manifest 的 vec_global_version /
  // global_gen 恒为 None，写路径不再产生全局代际链。
  let want_global = false
  let mut vec_global_version : String? = None
  let mut global_gen : @format.GlobalGen? = None
  let mut full_base = false
  if want_global {
    if docs.length() == 0 {
      // 纯删除批次：不动 global 代际链（否则 delta 链会被断开）
      vec_global_version = old_global_version
      global_gen = match old {
        Some(m) => m.global_gen
        None => None
      }
    } else {
      let old_gen : @format.GlobalGen? = match old {
        Some(m) => m.global_gen
        None => None
      }
      let mut base = ""
      let deltas : Array[String] = Array()
      match old_gen {
        Some(g) =>
          if g.base != "" {
            base = g.base
            for d in g.deltas {
              deltas.push(d)
            }
            deltas.push(new_id)
          } else {
            match old_global_version {
              Some(v) => {
                base = v
                deltas.push(new_id)
              }
              None => full_base = true
            }
          }
        None =>
          match old_global_version {
            Some(v) => {
              base = v
              deltas.push(new_id)
            }
            None => full_base = true
          }
      }
      if full_base {
        base = new_id
      }
      vec_global_version = Some(base)
      global_gen = Some({ base, deltas })
    }
  }
  let manifest : @format.ManifestData = {
    id: new_id,
    parent: match old {
      Some(m) => Some(m.id)
      None => None
    },
    segments: segs,
    deleted,
    deleted_roar,
    vec_global_version,
    global_gen,
    centroid_version,
    num_docs: total_rows,
    avg_doc_len,
  }
  // 6. 全局向量：delta 代（不重写 base）/ 无旧 global 时写全量 base
  if want_global && docs.length() > 0 {
    if full_base {
      let _ = rebuild_global_vec_parts(
        store,
        cfg,
        ns,
        cent,
        manifest,
        old,
        None,
        docs,
        [(0, docs.length())],
        old_seg_count,
      )
    } else {
      let _ = write_global_delta_parts(
        store,
        cfg,
        ns,
        cent,
        manifest,
        match vec_global_version {
          Some(v) => v
          None => new_id
        },
        docs,
        [(0, docs.length())],
        old_seg_count,
      )
    }
  }
  // 7. 段 + tombstone + manifest 批量落盘后 CAS 发布（先段后 head）。
  let items : Array[(String, Bytes)] = Array()
  match slab_write {
    Some(kv) => items.push(kv)
    None => ()
  }
  match meta_write {
    Some(kv) => items.push(kv)
    None => ()
  }
  match tomb_write {
    Some(kv) => items.push(kv)
    None => ()
  }
  items.push((manifest_key(ns, new_id), json_bytes(manifest.to_json())))
  store.put_many(items)
  publish_head(store, ns, expected_head, new_id)
  new_id
}

///|
/// 前缀合并后仍需要保留的墓碑：只有落在**并发新增 tail 段** id 范围内的 id 才
/// 还需要过滤；被 prefix 段承载的 id 已在前缀合并时物理化（合并段不含它们）。
fn prune_tombstones(
  deleted : Array[UInt64],
  tails : Array[@format.SegmentMeta],
) -> Array[UInt64] {
  let out : Array[UInt64] = Array()
  if tails.is_empty() {
    return out
  }
  for d in deleted {
    let mut keep = false
    for t in tails {
      if d >= t.min_id && d <= t.max_id {
        keep = true
        break
      }
    }
    if keep {
      out.push(d)
    }
  }
  out
}

///|
/// 无阻塞乐观 Rebase Compaction：
/// 1. 拍起始快照 `M_start`，取合并集合：`merge_ids` 非空时只合并这些段
///    （**指定子集合并**，同 tier 段可以不相邻；只认 `M_start` 里实际存在的
///    id，一个都不剩则 `None`）；默认取前缀段集合（manifest 顺序的前 N 段）；
/// 2. 段数 ≤ 1 且 `M_start.deleted` 为空 ⇒ `None`（无可合并）；
/// 3. 把前缀段的存活行合并成 **1 个** SlabV2 单文件段并上传（`global_vec_parts`
///    时同时写新的全量 global IVF packs）；
/// 4. **乐观 rebase 发布**：重读当前 head `M_curr`，把不在 prefix 里的并发新段
///    `tail_new_segs` 拼在合并段之后，墓碑只保留 tail 段范围内的；CAS 发布
///    `M_next`。冲突则重读 `M_curr` 重新拼 manifest JSON 重试（最多 5 次），
///    **绝不重传已上传的合并段**，也不会丢并发新写。
///
/// 返回新 manifest id；无需合并或 5 次 CAS 全部冲突时返回 None。
///
/// 【子集合并的限制】rebase 拼接固定把合并段排在段列表最前（前缀合并时
/// 天然保持段序）；`merge_ids` 非前缀子集时 manifest 段序会被重排。段序
/// 不承载语义（query 全段扫描、GC 集合判定、`prune_tombstones` 按段 id
/// 范围剪裁），故本单不改 rebase 拼接逻辑。
pub async fn[S : @store.ObjectStore] compact_optimistic(
  store : S,
  cfg : BuildConfig,
  max_prefix_segments? : Int = 8,
  merge_ids? : Array[String] = [],
) -> String? {
  let ns = cfg.ns
  let meta0 = match read_namespace(store, ns) {
    Some(m) => m
    None => return None
  }
  if meta0.head_manifest == "" {
    return None
  }
  let m_start = load_manifest(store, ns, meta0.head_manifest)
  if m_start.segments.length() <= 1 && m_start.deleted.is_empty() {
    return None
  }
  // 合并集合：merge_ids 非空 = 指定子集（同 tier 不相邻段也可以）；
  // 默认 = manifest 顺序的前 N 段（前缀合并）。rebase 拼接两种情况共用。
  let in_prefix : Map[String, Bool] = Map([])
  if merge_ids.length() > 0 {
    let wanted : Map[String, Bool] = Map([])
    for id in merge_ids {
      wanted.set(id, true)
    }
    let mut picked = 0
    for s in m_start.segments {
      let hit = match wanted.get(s.id) {
        Some(_) => true
        None => false
      }
      if hit {
        in_prefix.set(s.id, true)
        picked += 1
      }
    }
    if picked == 0 {
      return None
    }
  } else {
    let maxp = if max_prefix_segments > 0 {
      max_prefix_segments
    } else {
      m_start.segments.length()
    }
    let mut taken = 0
    for s in m_start.segments {
      if taken < maxp {
        in_prefix.set(s.id, true)
        taken += 1
      }
    }
  }
  // 读前缀段的存活行（兼容传统多文件段与单文件 slab 段）
  let tomb : Set[UInt64] = Set([])
  for d in m_start.deleted {
    tomb.add(d)
  }
  let has_global = m_start.vec_global_version is Some(_) ||
    m_start.global_gen is Some(_)
  let (gvecs, gdim) : (Map[Int, Array[Float]], Int) = if has_global {
    load_global_vec_rows(store, ns, m_start)
  } else {
    (Map([]), 0)
  }
  let live : Array[@core.Doc] = Array()
  for si in 0..<m_start.segments.length() {
    let seg = m_start.segments[si]
    if !in_prefix.contains(seg.id) {
      continue
    }
    let pre : Array[Float]? = if has_global {
      if seg.row_count == 0 {
        Some(Array())
      } else {
        match gvecs.get(si) {
          Some(a) => Some(a)
          None =>
            raise @core.Corrupt("missing preloaded vectors for segment \{si}")
        }
      }
    } else {
      None
    }
    for d in load_segment_docs(store, ns, seg, pre, gdim) {
      if !tomb.contains(d.id) {
        live.push(d)
      }
    }
  }
  let cent = load_centroids(store, ns, m_start.centroid_version)
  // 合并段：只上传一次；重试期间复用（乐观 rebase 的关键）
  let merged_seg : @format.SegmentMeta? = if live.length() > 0 {
    let seg_id = new_slab_segment_id()
    let (slab_bytes, meta_bytes, meta) = build_segment_slab(
      cfg, cent, live, 0, live.length(), seg_id~,
    )
    store.put_many([
      (segment_slab_key(ns, seg_id), slab_bytes),
      (segment_meta_key(ns, seg_id), meta_bytes),
    ])
    Some(meta)
  } else {
    None
  }
  let merged_id : String = match merged_seg {
    Some(s) => s.id
    None => ""
  }
  let want_global = false // 全局代际链已停写（Step 1）：同 ingest_l0_slab。
  let mut last_tomb : (Array[UInt64], String)? = None
  let mut tries = 0
  let mut result : String? = None
  while tries < 5 && result is None {
    tries += 1
    // 乐观 rebase：读发布时刻的当前 head
    let meta_curr = match read_namespace(store, ns) {
      Some(m) => m
      None => return result
    }
    if meta_curr.head_manifest == "" {
      return result
    }
    let m_curr = load_manifest(store, ns, meta_curr.head_manifest)
    // 并发新增 tail 段：不在合并集合、也不是本次的合并段
    let tails : Array[@format.SegmentMeta] = Array()
    for s in m_curr.segments {
      if in_prefix.contains(s.id) || s.id == merged_id {
        continue
      }
      tails.push(s)
    }
    // 合并段固定排最前（前缀合并时天然保持段序）；merge_ids 非前缀子集时
    // 段序会重排，但段序不承载语义（见函数头「子集合并的限制」）。
    let next_segs : Array[@format.SegmentMeta] = Array()
    match merged_seg {
      Some(s) => next_segs.push(s)
      None => ()
    }
    for t in tails {
      next_segs.push(t)
    }
    // 墓碑：只保留 tail 段范围内的（prefix 的已经被物理化）
    let deleted_next = prune_tombstones(m_curr.deleted, tails)
    let mut deleted_roar : String? = None
    let mut tomb_write : (String, Bytes)? = None
    if !deleted_next.is_empty() {
      if same_ids(deleted_next, m_curr.deleted) {
        deleted_roar = m_curr.deleted_roar
      } else {
        let reused = match last_tomb {
          Some(t) => if same_ids(t.0, deleted_next) { Some(t.1) } else { None }
          None => None
        }
        match reused {
          Some(k) => deleted_roar = Some(k)
          None => {
            let tid = new_manifest_id()
            tomb_write = Some((
              tombstone_key(ns, tid),
              @format.encode_roaring(deleted_next),
            ))
            deleted_roar = Some(tid)
            last_tomb = Some((deleted_next, tid))
          }
        }
      }
    }
    let new_id = new_manifest_id()
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
    let manifest : @format.ManifestData = {
      id: new_id,
      parent: Some(m_curr.id),
      segments: next_segs,
      deleted: deleted_next,
      deleted_roar,
      // 全局代际链已停写（Step 1）：恒为 None。
      vec_global_version: None,
      global_gen: None,
      centroid_version: m_curr.centroid_version,
      num_docs: total_rows,
      avg_doc_len,
    }
    // 全局 IVF：M_next 全量新 base（合并段 + tail 段），段序已重排
    if want_global && next_segs.length() > 0 {
      let curr_has_global = m_curr.vec_global_version is Some(_) ||
        m_curr.global_gen is Some(_)
      let (tvecs, tdim) : (Map[Int, Array[Float]], Int) = if curr_has_global {
        load_global_vec_rows(store, ns, m_curr)
      } else {
        (Map([]), gdim)
      }
      let seg_docs : Array[Array[@core.Doc]] = Array(capacity=next_segs.length())
      match merged_seg {
        Some(_) => seg_docs.push(live)
        None => ()
      }
      for t in tails {
        // tvecs 以 m_curr.segments 的下标为键（tail 在 m_curr 里的真实位置）
        let mut idx = -1
        for si in 0..<m_curr.segments.length() {
          if m_curr.segments[si].id == t.id {
            idx = si
          }
        }
        let pre : Array[Float]? = if curr_has_global && t.row_count > 0 && idx >= 0 {
          tvecs.get(idx)
        } else {
          None
        }
        seg_docs.push(load_segment_docs(store, ns, t, pre, tdim))
      }
      let _ = write_global_base_from_segs(
        store, cfg, ns, cent, new_id, next_segs, seg_docs,
      )
    }
    let items : Array[(String, Bytes)] = Array()
    match tomb_write {
      Some(kv) => items.push(kv)
      None => ()
    }
    items.push((manifest_key(ns, new_id), json_bytes(manifest.to_json())))
    store.put_many(items)
    let published = try {
      publish_head(store, ns, m_curr.id, new_id)
      true
    } catch {
      _ => false
    }
    if published {
      result = Some(new_id)
    }
  }
  result
}

///|
/// 从 manifest id 解析内嵌毫秒时间戳（`manifest-{13 位 ts}-{writer}-{seq}`）。
/// 解析不出（旧数据 / 测试短 id）返回 None，GC 一律按「刚发布」保守处理，
/// 保证不误删时间戳未知的 manifest 所引用的段。
fn manifest_id_ts_ms(id : String) -> UInt64? {
  let prefix = "manifest-"
  if !id.has_prefix(prefix) {
    return None
  }
  let chars = id[prefix.length():].to_array()
  if chars.length() < 14 || chars[13].to_int() != 45 {
    return None
  }
  let mut n = 0UL
  for i in 0..<13 {
    let c = chars[i].to_int()
    if c < 48 || c > 57 {
      return None
    }
    n = n * 10UL + (c - 48).to_uint64()
  }
  Some(n)
}

///|
/// superseded 段回收统计：`deleted` = 物理删除的 `slabseg-*` 段目录数；
/// `kept_live` = 仍被当前 head 引用；`kept_in_grace` = 已被合并掉但仍在
/// grace 窗口内（有 live manifest 仍可能引用）。
#derive(Debug)
pub(all) struct SegGcStat {
  deleted : Int
  kept_live : Int
  kept_in_grace : Int
}

///|
/// 回收被合并掉的旧 slab 段（superseded segment GC）。
///
/// 「live manifest」= 当前 head ∪ head 日志里发布不满 `grace_ms` 的 manifest
/// （含并发 sibling / fork——在途读者可能仍钉在上面）。判定规则：只有**不在
/// 任何 live manifest 里**、且最后一次被引用不晚于 grace 窗口之前的段才删除。
/// 时间锚点取 manifest id 内嵌的毫秒时间戳（`manifest-{ts}-...`）；解析不出
/// 的 id 按「刚发布」保守处理 ⇒ 其段永不误删。
///
/// 删除面 = 该段目录下的**全部**对象：段 slab + `meta.json` + 该段的
/// `vec/part-*` 组件（碎片布局的 rows/fts/* 也一并回收）。
/// 删除前**重新读一次 head** 逐段确认（防「扫描后 head 又引用该段」的 TOCTOU）。
///
/// 语义对齐 `gc_global_versions_grace`：grace 是给在途读者的宽限期，不是立即
/// 删除；`grace_ms = 0` 时只保留 head 引用的段。保护集里的 manifest 读不出来
/// 时整轮放弃（fail-safe，宁可漏回收不误删）。返回各分类计数。
pub async fn[S : @store.ObjectStore] gc_superseded_segments(
  store : S,
  ns : String,
  grace_ms~ : UInt64 = SEGMENT_GC_GRACE_MS,
  now_ms~ : UInt64 = @env.now(),
) -> SegGcStat {
  let hprefix = @store.head_prefix(ns)
  let sprefix = "\{ns}/_segments/"
  // 1) 保护集：grace 窗口内发布的 manifest（含 fork/sibling）的段集合。
  let live_refs : Set[String] = Set([])
  for key in store.list(hprefix) {
    if !key.has_prefix(hprefix) {
      continue
    }
    let id = key[hprefix.length():].to_owned()
    let ts = match manifest_id_ts_ms(id) {
      Some(t) => t
      None => now_ms // 时间戳未知：按刚发布处理 ⇒ 永在 grace 内
    }
    if ts + grace_ms <= now_ms {
      continue // 超窗：该 manifest 的在途读者视为已结束
    }
    let mm : @format.ManifestData? = try {
      Some(load_manifest(store, ns, id))
    } catch {
      _ => None
    }
    match mm {
      Some(m) =>
        for s in m.segments {
          live_refs.add(s.id)
        }
      // 保护集里的 manifest 读不出来：段集合无法确认，整轮 GC 放弃。
      None => return { deleted: 0, kept_live: 0, kept_in_grace: 0 }
    }
  }
  // 2) 桶内全部 slabseg-* 段目录（去重）。
  let dirs : Array[String] = Array()
  let seen : Set[String] = Set([])
  for key in store.list(sprefix) {
    if !key.has_prefix(sprefix) {
      continue
    }
    let rest = key[sprefix.length():]
    let seg_id = match rest.find("/") {
      Some(i) => rest[:i].to_owned()
      None => continue
    }
    if !is_l0_slab_segment(seg_id) || seen.contains(seg_id) {
      continue
    }
    seen.add(seg_id)
    dirs.push(seg_id)
  }
  // 3) 删前重新读一次 head 确认（TOCTOU 防护：扫描后 head 若又引用该段则跳过）。
  let meta = match read_namespace(store, ns) {
    Some(m) => m
    None => return { deleted: 0, kept_live: 0, kept_in_grace: 0 }
  }
  if meta.head_manifest == "" {
    return { deleted: 0, kept_live: 0, kept_in_grace: 0 }
  }
  let head_mm : @format.ManifestData? = try {
    Some(load_manifest(store, ns, meta.head_manifest))
  } catch {
    _ => None
  }
  let head_m = match head_mm {
    Some(m) => m
    None => return { deleted: 0, kept_live: 0, kept_in_grace: 0 }
  }
  let head_segs : Set[String] = Set([])
  for s in head_m.segments {
    head_segs.add(s.id)
    live_refs.add(s.id)
  }
  // 4) 分类 + 删除。
  let mut deleted = 0
  let mut kept_live = 0
  let mut kept_in_grace = 0
  for seg_id in dirs {
    if head_segs.contains(seg_id) {
      kept_live += 1
      continue
    }
    if live_refs.contains(seg_id) {
      kept_in_grace += 1
      continue
    }
    for key in store.list("\{sprefix}\{seg_id}/") {
      store.delete(key)
    }
    deleted += 1
  }
  { deleted, kept_live, kept_in_grace }
}

///|
/// size-tiered 合并 fanout：同 tier（同量级）段攒够 fanout 个才合并，
/// 一次只合并该 tier 内最旧的 fanout 个段（具名常量，默认 3）。
pub const SEGMENT_TIER_FANOUT : Int = 3

///|
/// 安全阀倍数：段数真超过 `tiers × fanout × SEGMENT_TIER_MAX_FACTOR` 时
/// 退回一次前缀合并并打日志（保底，防 tier 判定异常导致段数无界）。
pub const SEGMENT_TIER_MAX_FACTOR : Int = 2

///|
/// floor(log2(n))（n ≥ 1）。
fn floor_log2_i64(n : Int64) -> Int {
  let mut t = 0
  let mut v = 1L
  while v <= n / 2L {
    v = v * 2L
    t = t + 1
  }
  t
}

///|
/// 2^t（t ≥ 0）。
fn pow2_i64(t : Int) -> Int64 {
  let mut v = 1L
  for _ in 0..<t {
    v = v * 2L
  }
  v
}

///|
/// base·2^t ≤ rows（t 可为负）。负指数侧用带进位除法避免溢出/截断。
fn le_pow(base : Int64, rows : Int64, t : Int) -> Bool {
  if t >= 0 {
    base * pow2_i64(t) <= rows
  } else {
    let p = pow2_i64(0 - t)
    (base + p - 1L) / p <= rows
  }
}

///|
/// 段量级档（tier）：`floor(log2(row_count / base_rows))`，base_rows 取
/// `cfg.segment_rows`。同 tier 段行数相差 < 2×，视为同量级，size-tiered
/// 只在同 tier 内合并。全程 Int64 精确比较（`base·2^t ≤ rows <
/// base·2^(t+1)`），无浮点误差；rows / base_rows ≤ 0 时按 1 处理。
pub fn segment_tier(row_count : Int, base_rows : Int) -> Int {
  let base = if base_rows > 0 { base_rows.to_int64() } else { 1L }
  let rows = if row_count > 0 { row_count.to_int64() } else { 1L }
  let mut t = floor_log2_i64(rows) - floor_log2_i64(base)
  while t > -61 && !le_pow(base, rows, t) {
    t = t - 1
  }
  while t < 61 && le_pow(base, rows, t + 1) {
    t = t + 1
  }
  t
}

///|
/// 一次合并的明细：被合并段所在 tier（前缀合并记输出段 tier）、输入段数、
/// 输入/输出行数（输出行数 = 新 head 里本次合并产物的行数，单写者下精确）。
#derive(Debug)
pub(all) struct SegMergeInfo {
  tier : Int
  segs_in : Int
  rows_in : Int
  rows_out : Int
  prefix_fallback : Bool // true = 安全阀退回的前缀合并
}

///|
/// size-tiered 段压力合并的结果：合并后的 head、合并次数、合并前后段数、
/// 被合并掉的段 id（供调用方做 GC 计数观测）、整轮一次 GC 的统计与逐次
/// 合并明细 `merge_log`。
#derive(Debug)
pub(all) struct SegCompactOutcome {
  head : String // 合并后的 head manifest id（未触发 = 调用前 head；无 head = "")
  merges : Int // 成功发布的合并批次数（= merge_log.length()）
  segs_before : Int
  segs_after : Int
  superseded : Array[String] // 被合并掉的段 id（GC 判定前的候选）
  gc_deleted : Int
  gc_kept_in_grace : Int
  merge_log : Array[SegMergeInfo] // 逐次合并明细（tier / 输入段数 / 输入输出行数）
}

///|
/// 合并前后 manifest 差集：被合并掉的段 id + 输出段行数（新 head 里不在
/// 合并前段集合中的段 = 本次合并产物；并发新增 tail 段同理计入，单写者下
/// 精确）。
fn merge_diff(
  old_ids : Array[String],
  rows_of : Map[String, Int],
  new_m : @format.ManifestData,
) -> (Array[String], Int) {
  let keep : Map[String, Bool] = Map([])
  for s in new_m.segments {
    keep.set(s.id, true)
  }
  let superseded : Array[String] = Array()
  for id in old_ids {
    let hit = match keep.get(id) {
      Some(_) => true
      None => false
    }
    if !hit {
      superseded.push(id)
    }
  }
  let mut rows_out = 0
  for s in new_m.segments {
    let known = match rows_of.get(s.id) {
      Some(_) => true
      None => false
    }
    if !known {
      rows_out += s.row_count
    }
  }
  (superseded, rows_out)
}

///|
/// size-tiered 段压力合并（薄封装，`compact_optimistic` 的写路径触发器）：
///
/// - 段按 `segment_tier(row_count, cfg.segment_rows)` 分档（tier），**只合并
///   同 tier 段**、不跨档；某 tier 段数 ≥ `fanout` 时，把该 tier 内**最旧的
///   fanout 个段**（段 id 升序 = 创建序）交给
///   `compact_optimistic(merge_ids=...)` 合并成 1 段，循环到没有任何 tier
///   达到 fanout 为止（合并产物升档后可能在本轮继续触发更高档合并）；
/// - 段数不再硬性 ≤ `max_segments`，实际上界 ≈ tiers × `fanout`；安全阀：
///   段数真超过 `tiers × fanout × SEGMENT_TIER_MAX_FACTOR` 时退回**一次**
///   前缀合并（`compact_optimistic`，前缀段数取 `max_segments`）并打日志，
///   随后仍由 tiered 循环收尾；
/// - 本轮结束时一次 `gc_superseded_segments` 回收被合并掉的旧段（grace 窗口
///   见 `SEGMENT_GC_GRACE_MS`），outcome 的 gc_* 是整轮口径；
/// - 每次合并的 tier / 输入段数 / 输入输出行数记录在 `merge_log`。
///
/// 返回 `SegCompactOutcome`；合并无法推进（无可合并 / CAS 全部冲突 / 段数
/// 不再下降）即停。不改 `ingest_l0_slab` / `compact_optimistic` 的语义。

///|
pub async fn[S : @store.ObjectStore] maybe_compact_segments(
  store : S,
  cfg : BuildConfig,
  max_segments~ : Int = 8,
  fanout~ : Int = SEGMENT_TIER_FANOUT,
) -> SegCompactOutcome {
  let ns = cfg.ns
  let none : SegCompactOutcome = {
    head: "",
    merges: 0,
    segs_before: 0,
    segs_after: 0,
    superseded: [],
    gc_deleted: 0,
    gc_kept_in_grace: 0,
    merge_log: [],
  }
  let meta0 = match read_namespace(store, ns) {
    Some(m) => m
    None => return none
  }
  if meta0.head_manifest == "" {
    return none
  }
  let m0 = load_manifest(store, ns, meta0.head_manifest)
  let segs_before = m0.segments.length()
  let base_rows = if cfg.segment_rows > 0 { cfg.segment_rows } else { 1 }
  let ff = if fanout > 1 { fanout } else { SEGMENT_TIER_FANOUT }
  let mut head = meta0.head_manifest
  let mut segs = segs_before
  let superseded : Array[String] = Array()
  let merge_log : Array[SegMergeInfo] = Array()
  let mut merges = 0
  let mut fallback_used = false
  let mut going = true
  while going {
    going = false
    let m = load_manifest(store, ns, head)
    // tier → 段 id（升序 = 创建序，最旧在前）；rows_of 供行数统计。
    let tier_ids : Map[Int, Array[String]] = Map([])
    let tier_keys : Array[Int] = Array()
    let rows_of : Map[String, Int] = Map([])
    for s in m.segments {
      rows_of.set(s.id, s.row_count)
      let t = segment_tier(s.row_count, base_rows)
      match tier_ids.get(t) {
        Some(a) => a.push(s.id)
        None => {
          let a : Array[String] = Array()
          a.push(s.id)
          tier_ids.set(t, a)
          tier_keys.push(t)
        }
      }
    }
    tier_keys.sort()
    // 合并前的段集合：差集 = 本次被合并掉的段。
    let old_ids : Array[String] = Array()
    for s in m.segments {
      old_ids.push(s.id)
    }
    let mut acted = false
    // 安全阀：段数真超过 tiers × fanout × 倍数时退回一次前缀合并。
    if !fallback_used &&
      segs > tier_keys.length() * ff * SEGMENT_TIER_MAX_FACTOR &&
      segs > max_segments {
      fallback_used = true
      let prefix_n = if max_segments > 1 { max_segments } else { 2 }
      println(
        "maybe_compact_segments: 安全阀触发（segs=\{segs} > tiers=\{tier_keys.length()} × fanout=\{ff} × \{SEGMENT_TIER_MAX_FACTOR}），退回一次前缀合并（前缀 \{prefix_n} 段）",
      )
      let mut rows_in = 0
      let mut segs_in = 0
      for id in old_ids {
        if segs_in < prefix_n {
          match rows_of.get(id) {
            Some(r) => rows_in += r
            None => ()
          }
          segs_in += 1
        }
      }
      match compact_optimistic(store, cfg, max_prefix_segments=prefix_n) {
        Some(new_head) => {
          acted = true
          merges += 1
          head = new_head
          let m_new = load_manifest(store, ns, new_head)
          let (sup, rows_out) = merge_diff(old_ids, rows_of, m_new)
          for id in sup {
            superseded.push(id)
          }
          merge_log.push({
            tier: segment_tier(rows_out, base_rows),
            segs_in,
            rows_in,
            rows_out,
            prefix_fallback: true,
          })
          let old_count = segs
          segs = m_new.segments.length()
          if segs < old_count {
            going = true
          }
        }
        None => ()
      }
    }
    if !acted {
      // tiered：取 tier 值最小（最小段档）且段数 ≥ fanout 的档，
      // 合并该档内最旧的 fanout 个段（段 id 升序 = 创建序）。
      let picked : Array[String] = Array()
      let mut picked_tier = 0
      for t in tier_keys {
        if picked.length() > 0 {
          break
        }
        let arr = match tier_ids.get(t) {
          Some(a) => a
          None => continue
        }
        if arr.length() >= ff {
          arr.sort()
          picked_tier = t
          for i in 0..<ff {
            picked.push(arr[i])
          }
        }
      }
      if picked.length() == ff {
        let mut rows_in = 0
        for id in picked {
          match rows_of.get(id) {
            Some(r) => rows_in += r
            None => ()
          }
        }
        match compact_optimistic(store, cfg, merge_ids=picked) {
          Some(new_head) => {
            merges += 1
            head = new_head
            let m_new = load_manifest(store, ns, new_head)
            let (sup, rows_out) = merge_diff(old_ids, rows_of, m_new)
            for id in sup {
              superseded.push(id)
            }
            merge_log.push({
              tier: picked_tier,
              segs_in: ff,
              rows_in,
              rows_out,
              prefix_fallback: false,
            })
            let old_count = segs
            segs = m_new.segments.length()
            // 段数没降 ⇒ 合并无法推进，退出避免死循环。
            if segs < old_count {
              going = true
            }
          }
          // 合并无法推进（无可合并 / CAS 全部冲突）。
          None => ()
        }
      }
    }
  }
  // 本轮结束时一次 GC（grace 窗口内的一律保留）。
  let mut gc_deleted = 0
  let mut gc_kept_in_grace = 0
  if merges > 0 {
    let stat = gc_superseded_segments(store, ns)
    gc_deleted = stat.deleted
    gc_kept_in_grace = stat.kept_in_grace
  }
  {
    head,
    merges,
    segs_before,
    segs_after: segs,
    superseded,
    gc_deleted,
    gc_kept_in_grace,
    merge_log,
  }
}

///|
pub extend SegGcStat with Debug::{to_repr}
pub extend SegMergeInfo with Debug::{to_repr}
pub extend SegCompactOutcome with Debug::{to_repr}
