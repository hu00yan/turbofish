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
/// 读 SlabV2 单文件段的六列并重建 Doc 数组（顺序 = 段内行号）。
/// `preloaded` 非空时（全局 IVF 单副本模式）向量来自 global part，slab 内没有
/// `vector` 组件。
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
        None =>
          raise @core.Corrupt(
            "slab segment has no vector component: \{seg.id}",
          )
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
/// 全局 IVF（`global_vec_parts && VF16`）：段本身不存向量（与 `write_segment`
/// 同语义），本批向量写成一个 **delta 代**（不重写 base，同 `ingest_delta`）；
/// 非 global 配置下 manifest 的 global 字段清空（与 `ingest` 一致），向量随
/// slab 段自带。
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
  let want_global = cfg.global_vec_parts && cfg.vec_storage == VF16
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
/// 1. 拍起始快照 `M_start`，取前缀段集合（默认前 8 段）；
/// 2. 段数 ≤ 1 且 `M_start.deleted` 为空 ⇒ `None`（无可合并）；
/// 3. 把前缀段的存活行合并成 **1 个** SlabV2 单文件段并上传（`global_vec_parts`
///    时同时写新的全量 global IVF packs）；
/// 4. **乐观 rebase 发布**：重读当前 head `M_curr`，把不在 prefix 里的并发新段
///    `tail_new_segs` 拼在合并段之后，墓碑只保留 tail 段范围内的；CAS 发布
///    `M_next`。冲突则重读 `M_curr` 重新拼 manifest JSON 重试（最多 5 次），
///    **绝不重传已上传的合并段**，也不会丢并发新写。
///
/// 返回新 manifest id；无需合并或 5 次 CAS 全部冲突时返回 None。
pub async fn[S : @store.ObjectStore] compact_optimistic(
  store : S,
  cfg : BuildConfig,
  max_prefix_segments? : Int = 8,
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
  // 前缀段集合：manifest 顺序的前 N 段
  let maxp = if max_prefix_segments > 0 {
    max_prefix_segments
  } else {
    m_start.segments.length()
  }
  let in_prefix : Map[String, Bool] = Map([])
  let mut taken = 0
  for s in m_start.segments {
    if taken < maxp {
      in_prefix.set(s.id, true)
      taken += 1
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
  let want_global = cfg.global_vec_parts && cfg.vec_storage == VF16
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
    // 并发新增 tail 段：不在 prefix、也不是本次的合并段
    let tails : Array[@format.SegmentMeta] = Array()
    for s in m_curr.segments {
      if in_prefix.contains(s.id) || s.id == merged_id {
        continue
      }
      tails.push(s)
    }
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
      vec_global_version: if want_global {
        Some(new_id)
      } else {
        None
      },
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
