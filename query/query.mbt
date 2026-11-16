// query 包：seekpond/v1 读路径。
//
// 职责：打开 namespace（绑定 manifest 快照）→ BM25 / IVF 向量 / 混合（RRF）检索，
// 全程遵守查询成本模型：
// - namespace.json / manifest.json / seg meta.json / fts/dir.bin / centroids：整对象 GET（小）
// - postings.bin：只用 store.get_range 拉 term 局部区间（外层 16B = SPNDPOS1 头）
// - vec/part-*.bin、rows/*.bin（id / 过滤列）：整对象 GET
// - 一次查询绑定 open 时的 manifest 快照（强一致读）
//
// 读路径增强（自动启用；旧数据无新字段时保持兼容）：
// - per-segment 解码缓存（dir/doc_len/id/过滤列/blockmax，跨查询复用）
// - seg meta.json stats：filter 与段统计不相交时整段跳过
// - id_encoding=dense_u64：row→id 用 min_id+行号，不读 id.bin
// - 字典列按 code 比对、bool 位图直接查位、PQ16 分区 ADC
// - fts/blockmax.bin 存在时 BM25 走 block-max WAND（正确性与暴力路径一致）

///|
/// 过滤值。数值列统一 i64（JSON 数值解析为 i64）；string 按 UTF-8 字节序比较。
pub(all) enum FVal {
  S(String)
  B(Bool)
  I(Int64)
}

///|
/// 通用过滤 AST（对齐 turbopuffer v2 过滤面）：
/// - 等值/集合：Eq / Neq / In / NotIn
/// - 范围：Lt / Lte / Gt / Gte（i64 数值比较；string 为 UTF-8 字节序字典序；
///   bool 列不支持范围，加载列时报 Corrupt）
/// - 通配符：Glob(field, pattern)（`*` 匹配 0 个或多个任意字符，`?` 匹配恰好 1 个字符）
/// - 组合：And / Or / Not 任意嵌套
/// 字段列文件位于 {ns}/_segments/{seg}/rows/{field}.bin。
pub(all) enum Filter {
  Eq(String, FVal)
  Neq(String, FVal)
  In(String, Array[FVal])
  NotIn(String, Array[FVal])
  Lt(String, FVal)
  Lte(String, FVal)
  Gt(String, FVal)
  Gte(String, FVal)
  Glob(String, String)
  And(Array[Filter])
  Or(Array[Filter])
  Not(Filter)
}

///|
/// 旧接口兼容构造器（等值语义，等价 Eq(field, S/B/I(v))）。
pub fn f_str(field : String, v : String) -> Filter {
  Eq(field, S(v))
}

///|
pub fn f_bool(field : String, v : Bool) -> Filter {
  Eq(field, B(v))
}

///|
pub fn f_i64(field : String, v : Int64) -> Filter {
  Eq(field, I(v))
}

///|
/// FVal 的调试描述（错误信息用）。
pub fn FVal::describe(self : FVal) -> String {
  match self {
    S(s) => "\"\{s}\""
    B(b) => "\{b}"
    I(v) => "\{v}"
  }
}

///|
/// 单条检索结果。BM25：相关度分；向量：cosine 相似度（1 - 距离）；混合：RRF 分。
#derive(Debug)
pub(all) struct QueryResult {
  id : UInt64
  score : Double
}

///|
/// seg meta.json 的过滤统计（write_stats=true 时存在）。
#derive(Debug)
pub(all) struct SegStats {
  has_ts : Bool
  ts_min : Int64
  ts_max : Int64
  has_cat : Bool
  cat_values : Array[String]
  has_pub : Bool
  pub_values : Array[Bool]
}

///|
/// per-segment 解码缓存。同一 manifest 快照内跨查询复用。
pub(all) struct CachedSeg {
  row_count : Int
  partitions : Array[Int]
  min_id : UInt64
  id_dense : Bool
  vec_storage : String
  vec_normalized : Bool
  stats : SegStats?
  bloom : @format.Bloom?
  mut dir : Array[@format.FtsDirEntry]?
  mut doc_len : Array[Int]?
  mut ids : Array[UInt64]?
  mut blockmax : Array[Array[(Int, Int)]]?
  mut blockmax_size : Int
  mut blockmax_tried : Bool
  mut pq_m : Int
  mut pq_dsub : Int
  mut pq_codebook : Array[Float]?
  mut vec_info : (Int, Int, Int)? // rows/vector.bin 的 (dim, dtype, count)
  mut block_stats : (Int, Int, Array[(Int64, Int64)])? // (block_size, row_count, blocks)
  mut block_stats_tried : Bool
  matchers : Map[String, RowMatcher]
  vec_parts : Map[Int, Bytes]
}

///|
/// 已打开的 namespace：缓存 store 引用、namespace 元数据、manifest 快照、
/// 惰性加载的 centroids 与 per-segment 解码缓存。
pub(all) struct Namespace[S] {
  store : S
  ns : String
  meta : @format.NamespaceMeta
  manifest : @format.ManifestData
  mut centroids : @format.Centroids? // 惰性：首次 vec/hybrid 查询时加载并缓存
  mut cache : Map[String, CachedSeg] // seg_id → 解码缓存
  mut tombstones : Set[UInt64]? // 惰性：roaring/数组 tombstone 集合
  mut vec_global_cids : Array[Int]? // 惰性：全局 IVF 分区 cid 并集（单代或 delta 链）
  // 惰性：各代（global_gen.base + deltas）meta.json 的 cids，按代缓存。
  // delta 链里「某代没有某 cid」是合法空分区，必须按代判断，不能用并集代替。
  mut global_gen_cids : Map[String, Array[Int]]
  // 惰性：各代 meta.json 的 pack_size（>1 = 分包；同 global_gen_cids 一次 GET 进缓存）。
  mut global_gen_packs : Map[String, Int]
  global_parts : Map[String, @format.GlobalVecPart]
  mut head_checked_ms : UInt64 // metadata cache 最近一次 head 检查时间
}

///|
/// 进程级 metadata 缓存：以 namespace 名为 key，缓存已打开的 Namespace
/// （含 per-segment 解码缓存、centroids、tombstone set）。`open_cached` 每次
/// 只 GET 一次 namespace.json 检查 head；head 未变则零 manifest/segment 读。
pub(all) struct MetadataCache[S] {
  entries : Map[String, Namespace[S]]
  mut hits : Int
  mut misses : Int
  mut head_ttl_ms : UInt64
}

///|
pub fn[S] MetadataCache::new() -> MetadataCache[S] {
  { entries: Map([]), hits: 0, misses: 0, head_ttl_ms: 60000UL }
}

///|
pub fn[S] MetadataCache::invalidate(
  self : MetadataCache[S],
  ns : String,
) -> Unit {
  self.entries.remove(ns)
}

///|
pub fn[S] MetadataCache::put(
  self : MetadataCache[S],
  ns : String,
  n : Namespace[S],
) -> Unit {
  self.entries.set(ns, n)
}

///|
pub fn[S] MetadataCache::get(
  self : MetadataCache[S],
  ns : String,
) -> Namespace[S]? {
  self.entries.get(ns)
}

///|
pub fn[S] MetadataCache::set_head_ttl(
  self : MetadataCache[S],
  ttl_ms : UInt64,
) -> Unit {
  self.head_ttl_ms = ttl_ms
}

///|
pub fn[S] MetadataCache::touch(
  self : MetadataCache[S],
  ns : String,
) -> Unit {
  match self.entries.get(ns) {
    Some(n) => n.head_checked_ms = @env.now()
    None => ()
  }
}

///|
pub fn[S] MetadataCache::update_in_memory(
  self : MetadataCache[S],
  store : S,
  ns : String,
  meta : @format.NamespaceMeta,
  manifest : @format.ManifestData,
) -> Namespace[S] {
  open_cached_or_create(self, store, ns, meta, manifest)
}

///|
/// 直接从内存元数据构造 Namespace，零 S3 请求。
pub fn[S] open_from_meta(
  store : S,
  ns : String,
  meta : @format.NamespaceMeta,
  manifest : @format.ManifestData,
) -> Namespace[S] {
  {
    store,
    ns,
    meta,
    manifest,
    centroids: None,
    cache: Map([]),
    tombstones: None,
    vec_global_cids: None,
    global_gen_cids: Map([]),
    global_gen_packs: Map([]),
    global_parts: Map([]),
    head_checked_ms: @env.now(),
  }
}

fn global_gen_equal(
  a : @format.GlobalGen?,
  b : @format.GlobalGen?,
) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(ga), Some(gb)) =>
      if ga.base != gb.base || ga.deltas.length() != gb.deltas.length() {
        false
      } else {
        let mut eq = true
        for i in 0..<ga.deltas.length() {
          if ga.deltas[i] != gb.deltas[i] {
            eq = false
            break
          }
        }
        eq
      }
    _ => false
  }
}

///|
/// 带缓存的从内存元数据打开/复用 Namespace，零 S3 请求。
pub fn[S] open_cached_or_create(
  cache : MetadataCache[S],
  store : S,
  ns : String,
  meta : @format.NamespaceMeta,
  manifest : @format.ManifestData,
) -> Namespace[S] {
  let now = @env.now()
  match cache.entries.get(ns) {
    Some(old) =>
      if old.manifest.id == manifest.id {
        old.head_checked_ms = now
        cache.hits += 1
        old
      } else {
        cache.misses += 1
        let cent = if old.manifest.centroid_version == manifest.centroid_version {
          old.centroids
        } else {
          None
        }
        let tombstones = if old.manifest.deleted_roar == manifest.deleted_roar &&
          old.manifest.deleted == manifest.deleted {
          old.tombstones
        } else {
          None
        }
        let vec_global_cids = if old.manifest.vec_global_version ==
          manifest.vec_global_version &&
          global_gen_equal(old.manifest.global_gen, manifest.global_gen) {
          old.vec_global_cids
        } else {
          None
        }
        let n : Namespace[S] = {
          store,
          ns,
          meta,
          manifest,
          centroids: cent,
          cache: old.cache,
          tombstones,
          vec_global_cids,
          global_gen_cids: old.global_gen_cids,
          global_gen_packs: old.global_gen_packs,
          global_parts: old.global_parts,
          head_checked_ms: now,
        }
        cache.entries.set(ns, n)
        n
      }
    None => {
      cache.misses += 1
      let n : Namespace[S] = {
        store,
        ns,
        meta,
        manifest,
        centroids: None,
        cache: Map([]),
        tombstones: None,
        vec_global_cids: None,
        global_gen_cids: Map([]),
        global_gen_packs: Map([]),
        global_parts: Map([]),
        head_checked_ms: now,
      }
      cache.entries.set(ns, n)
      n
    }
  }
}

///|
/// 预热 Namespace：将 centroids、所有段 meta 与 id 列、tombstone、全局 IVF parts 全部预加载进内存。
/// 段 meta 与 id 列按“缓存 miss 集合”一次性批量读取；已缓存的段不重复请求。
pub fn[S : @store.ObjectStore] warm_namespace(
  n : Namespace[S],
) -> Unit raise @core.SpndError {
  let _ = ensure_centroids(n)
  let seg_count = n.manifest.segments.length()
  // 1) 批量加载所有缺失的 meta.json。
  prewarm_seg_metas(n)
  // 2) 非 dense 段批量加载 id 列（已缓存的跳过）。
  let need_ids : Array[String] = Array(capacity=seg_count)
  let need_cs : Array[CachedSeg] = Array(capacity=seg_count)
  for si in 0..<seg_count {
    let seg = n.manifest.segments[si]
    let cs = match n.cache.get(seg.id) {
      Some(c) => c
      None => raise @core.Corrupt("warm_namespace: missing seg cache")
    }
    if !cs.id_dense && cs.ids is None {
      need_ids.push(seg.id)
      need_cs.push(cs)
    }
  }
  if !need_ids.is_empty() {
    let keys : Array[String] = Array(capacity=need_ids.length())
    for id in need_ids {
      keys.push("\{n.ns}/_segments/\{id}/rows/id.bin")
    }
    let results = @store.ObjectStore::get_many(n.store, keys)
    for i in 0..<need_ids.length() {
      let key = keys[i]
      let bs = match results[i] {
        Some(b) => b
        None => raise @core.NotFound(key)
      }
      let arr = match @format.decode_col(bs) {
        @format.ColU64(x) => x
        _ => raise @core.Corrupt("id column dtype is not u64")
      }
      need_cs[i].ids = Some(arr)
    }
  }
  let _ = tombstones_of(n)
}

///|
/// 带进程级 metadata 缓存的 open：GET namespace.json 检查 head_manifest；
/// 若 head 未变，直接复用旧 Namespace（保留 seg 解码缓存/centroids/tombstone）。
/// 若 head 已变，加载新 manifest，并**继承旧 segment 缓存**（seg id 不可变）。
pub fn[S : @store.ObjectStore] open_cached(
  cache : MetadataCache[S],
  store : S,
  ns : String,
) -> Namespace[S] raise @core.SpndError {
  let now = @env.now()
  match cache.entries.get(ns) {
    Some(old) =>
      if cache.head_ttl_ms > 0UL && now - old.head_checked_ms < cache.head_ttl_ms {
        cache.hits += 1
        return old
      }
    None => ()
  }
  let meta_bs = get_object(store, "\{ns}/_meta/namespace.json")
  let meta0 = @format.namespace_from_json(
    parse_json_bytes(meta_bs, "namespace.json"),
  )
  let head = if meta0.head_manifest != "" {
    meta0.head_manifest
  } else {
    @store.read_head(store, ns, "")
  }
  let meta = { ..meta0, head_manifest: head }
  match cache.entries.get(ns) {
    Some(old) =>
      if old.manifest.id == head {
        old.head_checked_ms = now
        cache.hits += 1
        old
      } else {
        cache.misses += 1
        let man_bs = get_object(store, "\{ns}/_manifest/\{head}.json")
        let manifest = @format.manifest_from_json(
          parse_json_bytes(man_bs, "manifest"),
        )
        let cent = if old.manifest.centroid_version == manifest.centroid_version {
          old.centroids
        } else {
          None
        }
        let tombstones = if old.manifest.deleted_roar == manifest.deleted_roar &&
          old.manifest.deleted == manifest.deleted {
          old.tombstones
        } else {
          None
        }
        let vec_global_cids = if old.manifest.vec_global_version ==
          manifest.vec_global_version &&
          global_gen_equal(old.manifest.global_gen, manifest.global_gen) {
          old.vec_global_cids
        } else {
          None
        }
        let n : Namespace[S] = {
          store,
          ns,
          meta,
          manifest,
          centroids: cent,
          cache: old.cache,
          tombstones,
          vec_global_cids,
          global_gen_cids: old.global_gen_cids,
          global_gen_packs: old.global_gen_packs,
          global_parts: old.global_parts,
          head_checked_ms: now,
        }
        cache.entries.set(ns, n)
        n
      }
    None => {
      cache.misses += 1
      let man_bs = get_object(store, "\{ns}/_manifest/\{head}.json")
      let manifest = @format.manifest_from_json(
        parse_json_bytes(man_bs, "manifest"),
      )
      let n : Namespace[S] = {
        store,
        ns,
        meta,
        manifest,
        centroids: None,
        cache: Map([]),
        tombstones: None,
        vec_global_cids: None,
        global_gen_cids: Map([]),
        global_gen_packs: Map([]),
        global_parts: Map([]),
        head_checked_ms: now,
      }
      cache.entries.set(ns, n)
      n
    }
  }
}

///|
/// 打开 namespace：GET namespace.json + head manifest（一次查询绑定此快照）。
pub fn[S : @store.ObjectStore] open(
  store : S,
  ns : String,
) -> Namespace[S] raise @core.SpndError {
  let meta_key = "\{ns}/_meta/namespace.json"
  let meta_bs = get_object(store, meta_key)
  let meta0 = @format.namespace_from_json(
    parse_json_bytes(meta_bs, "namespace.json"),
  )
  let head = if meta0.head_manifest != "" {
    meta0.head_manifest
  } else {
    @store.read_head(store, ns, "")
  }
  let meta = { ..meta0, head_manifest: head }
  let man_key = "\{ns}/_manifest/\{head}.json"
  let man_bs = get_object(store, man_key)
  let manifest = @format.manifest_from_json(
    parse_json_bytes(man_bs, "manifest"),
  )
  {
    store,
    ns,
    meta,
    manifest,
    centroids: None,
    cache: Map([]),
    tombstones: None,
    vec_global_cids: None,
    global_gen_cids: Map([]),
    global_gen_packs: Map([]),
    global_parts: Map([]),
    head_checked_ms: 0UL,
  }
}

///|
/// 块级 ts 统计（rows/blockstats.bin，266 行块）。不存在时返回 None。
fn[S : @store.ObjectStore] seg_block_stats(
  n : Namespace[S],
  cs : CachedSeg,
  seg_id : String,
) -> (Int, Int, Array[(Int64, Int64)])? raise @core.SpndError {
  if cs.block_stats_tried {
    return cs.block_stats
  }
  cs.block_stats_tried = true
  match n.store.get("\{n.ns}/_segments/\{seg_id}/rows/blockstats.bin") {
    Some(bs) => {
      let (block_size, row_count, blocks) = @format.decode_blockstats(bs)
      let v = (block_size, row_count, blocks)
      cs.block_stats = Some(v)
      Some(v)
    }
    None => None
  }
}

///|
/// rows/vector.bin 头（dim, dtype, count），PQ 精排按块 get_range 前先读一次。
fn[S : @store.ObjectStore] seg_vec_info(
  n : Namespace[S],
  cs : CachedSeg,
  seg_id : String,
) -> (Int, Int, Int)? raise @core.SpndError {
  match cs.vec_info {
    Some(x) => Some(x)
    None => {
      let key = "\{n.ns}/_segments/\{seg_id}/rows/vector.bin"
      match n.store.get_range(key, 0, 16) {
        Some(hdr) =>
          match @format.vec_col_info(hdr) {
            (dim, dtype, count) => {
              cs.vec_info = Some((dim, dtype, count))
              Some((dim, dtype, count))
            }
          }
        None => None
      }
    }
  }
}

///|
/// manifest.global_gen → 需要读的 global 代列表 `[base] + deltas`（去重保序）。
/// None = 旧布局（单代全量，只有 `vec_global_version`）。
fn[T] global_gen_versions(
  n : Namespace[T],
) -> Array[String]? {
  match n.manifest.global_gen {
    // 空 base 的 `global_gen` 是损坏值：与 build 的 ingest_delta 同语义，按旧布局
    // （单代 `vec_global_version`）处理，而不是静默只读 deltas。
    Some(g) if g.base == "" => None
    Some(g) => {
      let all : Array[String] = Array(capacity=g.deltas.length() + 1)
      all.push(g.base)
      for d in g.deltas {
        all.push(d)
      }
      let seen : Set[String] = Set([])
      let out : Array[String] = Array(capacity=all.length())
      for ver in all {
        if ver != "" && !seen.contains(ver) {
          seen.add(ver)
          out.push(ver)
        }
      }
      Some(out)
    }
    None => None
  }
}

///|
/// 单代 global meta 的 cids（按代缓存）。同一次 meta.json 读取顺带缓存
/// `"pack_size"`（>1 = 该代分区分包，见 build/globalvec 的 pack 布局）。
/// - meta 缺失 → NotFound（声明了代就必须能读到）；
/// - `cids` 字段缺失 → Corrupt（`"cids":[]` 是合法空代，不能与字段缺失混淆）。
fn[S : @store.ObjectStore] global_gen_cids(
  n : Namespace[S],
  ver : String,
) -> Array[Int] raise @core.SpndError {
  match n.global_gen_cids.get(ver) {
    Some(c) => c
    None => {
      let key = "\{n.ns}/vec/global/\{ver}/meta.json"
      let bs = match n.store.get(key) {
        Some(b) => b
        None => raise @core.NotFound(key)
      }
      cache_global_gen_meta(n, ver, key, bs)
    }
  }
}

///|
/// 解析并缓存单代 global meta（cids + pack_size）。
fn[S] cache_global_gen_meta(
  n : Namespace[S],
  ver : String,
  key : String,
  bs : Bytes,
) -> Array[Int] raise @core.SpndError {
  let m = match parse_json_bytes(bs, "global vec meta") {
    Object(mm) => mm
    _ => raise @core.Corrupt("global vec meta is not an object")
  }
  let cids : Array[Int] = Array()
  match m.get("cids") {
    Some(Array(arr)) =>
      for x in arr {
        match x {
          Number(d, ..) => cids.push(d.to_int())
          _ => ()
        }
      }
    _ =>
      raise @core.Corrupt(
        "global vec meta missing cids (\{key})",
      )
  }
  // pack_size 缺省 1（未打包，旧数据兼容）。
  let ps = match m.get("pack_size") {
    Some(Number(d, ..)) => d.to_int()
    _ => 1
  }
  n.global_gen_cids.set(ver, cids)
  n.global_gen_packs.set(ver, if ps < 1 { 1 } else { ps })
  cids
}

///|
/// 批量预加载多代 global meta.json（只读缓存 miss 的代）。
fn[S : @store.ObjectStore] prewarm_global_gen_cids(
  n : Namespace[S],
  vers : Array[String],
) -> Unit raise @core.SpndError {
  let missing : Array[String] = Array(capacity=vers.length())
  for ver in vers {
    if n.global_gen_cids.get(ver) is None {
      missing.push(ver)
    }
  }
  if missing.is_empty() {
    return
  }
  let keys : Array[String] = Array(capacity=missing.length())
  for ver in missing {
    keys.push("\{n.ns}/vec/global/\{ver}/meta.json")
  }
  let results = @store.ObjectStore::get_many(n.store, keys)
  for i in 0..<missing.length() {
    let key = keys[i]
    let bs = match results[i] {
      Some(b) => b
      None => raise @core.NotFound(key)
    }
    let _ = cache_global_gen_meta(n, missing[i], key, bs)
  }
}

///|
/// 单代分区 pack 大小（未加载过该代 meta 时返回 1；不影响已有 cids 缓存语义）。
fn[S : @store.ObjectStore] global_gen_pack_size(
  n : Namespace[S],
  ver : String,
) -> Int raise @core.SpndError {
  match n.global_gen_packs.get(ver) {
    Some(p) => p
    None => {
      // 触发一次加载（cids + pack_size 一次 GET 同时进缓存）。
      let _ = global_gen_cids(n, ver)
      match n.global_gen_packs.get(ver) {
        Some(p) => p
        None => 1
      }
    }
  }
}

///|
/// 全局 IVF 分区的 cid 并集（惰性缓存）。
/// - `global_gen` 有值：`base` + 全部 `deltas` 的 `vec/global/{gen}/meta.json`
///   的 cids 并集；任何一代缺 meta / 缺 cids 都显式报错（静默跳过会让该代行
///   永久不可见，表现为「查不到但也不报错」）。
/// - `global_gen` 为 None：保持旧单代逻辑（`vec_global_version`）。
fn[S : @store.ObjectStore] ensure_global_cids(
  n : Namespace[S],
) -> Array[Int]? raise @core.SpndError {
  match n.vec_global_cids {
    Some(c) => return Some(c)
    None => ()
  }
  let cids : Array[Int] = Array()
  match global_gen_versions(n) {
    Some(gens) => {
      let seen : Set[Int] = Set([])
      for ver in gens {
        for c in global_gen_cids(n, ver) {
          if !seen.contains(c) {
            seen.add(c)
            cids.push(c)
          }
        }
      }
    }
    None => {
      let ver = match n.manifest.vec_global_version {
        Some(v) => v
        None =>
          match n.meta.vec_global_version {
            Some(v) => v
            None => return None
          }
      }
      let key = "\{n.ns}/vec/global/\{ver}/meta.json"
      let bs = match n.store.get(key) {
        Some(b) => b
        // manifest 已声明 global 代：meta 缺失不是「回退到 per-segment」的理由，
        // 单副本段没有 per-segment part，静默回退只会返回空结果（review P1-3）。
        None => raise @core.NotFound(key)
      }
      let m = match parse_json_bytes(bs, "global vec meta") {
        Object(mm) => mm
        _ => raise @core.Corrupt("global vec meta is not an object")
      }
      match m.get("cids") {
        Some(Array(arr)) =>
          for x in arr {
            match x {
              Number(d, ..) => cids.push(d.to_int())
              _ => ()
            }
          }
        _ =>
          // cids 字段缺失不是「空 namespace」：manifest 有段时必须显式报错，
          // 否则会静默返回空结果。
          if n.manifest.segments.length() > 0 {
            raise @core.Corrupt("global vec meta missing cids")
          }
      }
    }
  }
  n.vec_global_cids = Some(cids)
  Some(cids)
}

///|
/// manifest.deleted → tombstone 集合（惰性缓存）。有 deleted_roar 时优先读
/// roaring 对象；否则回退 manifest JSON 数组（旧数据兼容）。
fn[S : @store.ObjectStore] tombstones_of(
  n : Namespace[S],
) -> Set[UInt64] raise @core.SpndError {
  match n.tombstones {
    Some(s) => s
    None => {
      let s : Set[UInt64] = Set([])
      let ids : Array[UInt64] = match n.manifest.deleted_roar {
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
        s.add(d)
      }
      n.tombstones = Some(s)
      s
    }
  }
}

///|
/// GET 整对象；缺失按 NotFound 报错。
fn[S : @store.ObjectStore] get_object(
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
  @utf8.decode(bs.exact_view()) catch {
    _ => raise @core.Corrupt("invalid utf8 bytes")
  }
}

///|
/// Bytes → Json（解析失败统一转 Corrupt）。
fn parse_json_bytes(bs : Bytes, what : String) -> Json raise @core.SpndError {
  let s = bytes_to_string(bs)
  @json.parse(s) catch {
    _ => raise @core.Corrupt("invalid json in \{what}")
  }
}

///|
/// seg meta.json 解析结果。
priv struct SegMetaInfo {
  row_count : Int
  partitions : Array[Int]
  min_id : UInt64
  id_dense : Bool
  vec_storage : String
  vec_normalized : Bool
  stats : SegStats?
  bloom : @format.Bloom?
}

///|
/// 解析 stats 对象；缺字段返回 None。
fn parse_stats(j : Json) -> SegStats? {
  let m = match j {
    Object(mm) => mm
    _ => return None
  }
  let mut has_ts = false
  let mut ts_min = 0L
  let mut ts_max = 0L
  match m.get("ts") {
    Some(Object(t)) =>
      match (t.get("min"), t.get("max")) {
        (Some(Number(lo, ..)), Some(Number(hi, ..))) => {
          has_ts = true
          ts_min = lo.to_int64()
          ts_max = hi.to_int64()
        }
        _ => ()
      }
    _ => ()
  }
  let mut has_cat = false
  let cat_values : Array[String] = Array()
  match m.get("category") {
    Some(Object(c)) =>
      match c.get("values") {
        Some(Array(vals)) => {
          has_cat = true
          for v in vals {
            match v {
              String(s) => cat_values.push(s)
              _ => ()
            }
          }
        }
        _ => ()
      }
    _ => ()
  }
  let mut has_pub = false
  let pub_values : Array[Bool] = Array()
  match m.get("public") {
    Some(Object(p)) =>
      match p.get("values") {
        Some(Array(vals)) => {
          has_pub = true
          for v in vals {
            match v {
              True => pub_values.push(true)
              False => pub_values.push(false)
              _ => ()
            }
          }
        }
        _ => ()
      }
    _ => ()
  }
  Some({ has_ts, ts_min, ts_max, has_cat, cat_values, has_pub, pub_values })
}

///|
/// seg meta.json → 行数 / 分区 / dense id / 统计。
fn parse_seg_meta(bs : Bytes) -> SegMetaInfo raise @core.SpndError {
  let m = match parse_json_bytes(bs, "seg meta.json") {
    Object(mm) => mm
    _ => raise @core.Corrupt("seg meta.json is not an object")
  }
  let row_count = match m.get("row_count") {
    Some(Number(d, ..)) => d.to_int()
    _ => raise @core.Corrupt("seg meta.json missing row_count")
  }
  let parts : Array[Int] = Array()
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
  let min_id = match m.get("min_id") {
    Some(Number(d, ..)) => d.to_uint64()
    _ => 0UL
  }
  let id_dense = match m.get("id_encoding") {
    Some(String(s)) => s == "dense_u64"
    _ => false
  }
  let vec_storage = match m.get("vec_storage") {
    Some(String(s)) => s
    _ => ""
  }
  let vec_normalized = match m.get("vec_normalized") {
    Some(True) => true
    _ => false
  }
  let stats = match m.get("stats") {
    Some(j) => parse_stats(j)
    None => None
  }
  let bloom : @format.Bloom? = match
    (m.get("bloom"), m.get("bloom_m"), m.get("bloom_k")) {
    (Some(String(h)), Some(Number(mm, ..)), Some(Number(kk, ..))) =>
      Some(@format.bloom_from_hex(mm.to_int(), kk.to_int(), h)) catch {
        _ => None
      }
    _ => None
  }
  {
    row_count,
    partitions: parts,
    min_id,
    id_dense,
    vec_storage,
    vec_normalized,
    stats,
    bloom,
  }
}

///|
/// 由 seg meta.json 构造空的 CachedSeg（所有列/索引尚未加载）。
fn make_cached_seg(info : SegMetaInfo) -> CachedSeg {
  {
    row_count: info.row_count,
    partitions: info.partitions,
    min_id: info.min_id,
    id_dense: info.id_dense,
    vec_storage: info.vec_storage,
    vec_normalized: info.vec_normalized,
    stats: info.stats,
    bloom: info.bloom,
    dir: None,
    doc_len: None,
    ids: None,
    blockmax: None,
    blockmax_size: 128,
    blockmax_tried: false,
    pq_m: 0,
    pq_dsub: 0,
    pq_codebook: None,
    vec_info: None,
    block_stats: None,
    block_stats_tried: false,
    matchers: Map([]),
    vec_parts: Map([]),
  }
}

///|
/// 批量加载 manifest 里所有缓存 miss 的 seg meta.json（已缓存的段不重复请求）。
fn[S : @store.ObjectStore] prewarm_seg_metas(
  n : Namespace[S],
) -> Unit raise @core.SpndError {
  let seg_count = n.manifest.segments.length()
  let missing_ids : Array[String] = Array(capacity=seg_count)
  for si in 0..<seg_count {
    let seg = n.manifest.segments[si]
    if n.cache.get(seg.id) is None {
      missing_ids.push(seg.id)
    }
  }
  if missing_ids.is_empty() {
    return
  }
  let keys : Array[String] = Array(capacity=missing_ids.length())
  for id in missing_ids {
    keys.push("\{n.ns}/_segments/\{id}/meta.json")
  }
  let results = @store.ObjectStore::get_many(n.store, keys)
  for i in 0..<missing_ids.length() {
    let key = keys[i]
    let bs = match results[i] {
      Some(b) => b
      None => raise @core.NotFound(key)
    }
    let info = parse_seg_meta(bs)
    n.cache.set(missing_ids[i], make_cached_seg(info))
  }
}

///|
/// 取得（必要时加载）某 segment 的缓存。
fn[S : @store.ObjectStore] ensure_seg(
  n : Namespace[S],
  seg_idx : Int,
) -> CachedSeg raise @core.SpndError {
  let seg = n.manifest.segments[seg_idx]
  match n.cache.get(seg.id) {
    Some(cs) => cs
    None => {
      let info = parse_seg_meta(
        get_object(n.store, "\{n.ns}/_segments/\{seg.id}/meta.json"),
      )
      let cs = make_cached_seg(info)
      n.cache.set(seg.id, cs)
      cs
    }
  }
}

///|
/// fts dir（缓存）。
fn[S : @store.ObjectStore] seg_dir(
  n : Namespace[S],
  cs : CachedSeg,
  seg_id : String,
) -> Array[@format.FtsDirEntry] raise @core.SpndError {
  match cs.dir {
    Some(d) => d
    None => {
      let d = @format.decode_fts_dir(
        get_object(n.store, "\{n.ns}/_segments/\{seg_id}/fts/dir.bin"),
      )
      cs.dir = Some(d)
      d
    }
  }
}

///|
/// doc_len 列（缓存）。
fn[S : @store.ObjectStore] seg_doc_len(
  n : Namespace[S],
  cs : CachedSeg,
  seg_id : String,
) -> Array[Int] raise @core.SpndError {
  match cs.doc_len {
    Some(a) => a
    None => {
      let a = match
        @format.decode_col(
          get_object(n.store, "\{n.ns}/_segments/\{seg_id}/fts/doc_len.bin"),
        ) {
        @format.ColU32(x) => x
        _ => raise @core.Corrupt("doc_len column dtype is not u32")
      }
      cs.doc_len = Some(a)
      a
    }
  }
}

///|
/// id 列（缓存；dense 段不加载）。
fn[S : @store.ObjectStore] seg_ids(
  n : Namespace[S],
  cs : CachedSeg,
  seg_id : String,
) -> Array[UInt64] raise @core.SpndError {
  match cs.ids {
    Some(a) => a
    None => {
      let a = match
        @format.decode_col(
          get_object(n.store, "\{n.ns}/_segments/\{seg_id}/rows/id.bin"),
        ) {
        @format.ColU64(x) => x
        _ => raise @core.Corrupt("id column dtype is not u64")
      }
      cs.ids = Some(a)
      a
    }
  }
}

///|
/// block-max 索引（缓存；文件不存在时记 tried 避免重复 GET）。
fn[S : @store.ObjectStore] seg_blockmax(
  n : Namespace[S],
  cs : CachedSeg,
  seg_id : String,
) -> Array[Array[(Int, Int)]]? raise @core.SpndError {
  if cs.blockmax_tried {
    return cs.blockmax
  }
  cs.blockmax_tried = true
  let key = "\{n.ns}/_segments/\{seg_id}/fts/blockmax.bin"
  match n.store.get(key) {
    Some(bs) => {
      cs.blockmax_size = @core.read_u32_le(bs, 12).reinterpret_as_int()
      let blk = @format.decode_blockmax(bs)
      cs.blockmax = Some(blk)
      Some(blk)
    }
    None => None
  }
}

///|
/// PQ16 共享码本（每 segment 一个对象，缓存）。
fn[S : @store.ObjectStore] seg_pq_codebook(
  n : Namespace[S],
  cs : CachedSeg,
  seg_id : String,
) -> (Int, Int, Array[Float])? raise @core.SpndError {
  match cs.pq_codebook {
    Some(cbs) => Some((cs.pq_m, cs.pq_dsub, cbs))
    None => {
      let key = "\{n.ns}/_segments/\{seg_id}/vec/pq-codebook.bin"
      match n.store.get(key) {
        Some(bs) => {
          let (m, dsub, _, cbs) = @format.decode_pq_codebook(bs)
          cs.pq_m = m
          cs.pq_dsub = dsub
          cs.pq_codebook = Some(cbs)
          Some((m, dsub, cbs))
        }
        None => None
      }
    }
  }
}

///|
/// row→id：dense 段用 min_id+行号，否则读 id 列（缓存）。
fn[S : @store.ObjectStore] row_id(
  n : Namespace[S],
  cs : CachedSeg,
  seg_id : String,
  row : Int,
) -> UInt64 raise @core.SpndError {
  if cs.id_dense {
    return cs.min_id + row.to_uint64()
  }
  let ids = seg_ids(n, cs, seg_id)
  match ids.get(row) {
    Some(x) => x
    None => raise @core.Corrupt("row \{row} out of range in id column")
  }
}

///|
/// stats 预判：filter 与段统计不相交时整段跳过（不读任何列/fts）。
/// 组合节点保守求值：And 全部可能、Or 任一可能、Not 恒 true（不可跳过）。
fn seg_may_match(cs : CachedSeg, filter : Filter?) -> Bool {
  match filter {
    None => true
    Some(f) => seg_may_match_f(cs, f)
  }
}

///|
/// ts 块级 min/max 与单值/范围谓词是否可能相交（无 stats 时恒 true）。
fn stats_may_ts(cs : CachedSeg, _v : Int64, cmp : (Int64, Int64) -> Bool) -> Bool {
  match cs.stats {
    Some(s) => if s.has_ts { cmp(s.ts_min, s.ts_max) } else { true }
    None => true
  }
}

///|
/// 字典列 value set 与单值/范围谓词是否可能相交（无 stats 时恒 true）。
/// cmp 输入为 term_compare(x, v) 的结果。
fn stats_may_str(cs : CachedSeg, v : String, cmp : (Int) -> Bool) -> Bool {
  match cs.stats {
    Some(s) =>
      if s.has_cat {
        let mut found = false
        for x in s.cat_values {
          if cmp(@format.term_compare(x, v)) {
            found = true
            break
          }
        }
        found
      } else {
        true
      }
    None => true
  }
}

///|
fn seg_may_match_f(cs : CachedSeg, f : Filter) -> Bool {
  match f {
    Eq(field, v) =>
      match v {
        S(s) =>
          if field == "category" {
            stats_may_str(cs, s, fn(c) { c == 0 })
          } else {
            true
          }
        B(b) =>
          if field == "public" {
            match cs.stats {
              Some(s) =>
                if s.has_pub {
                  let mut found = false
                  for x in s.pub_values {
                    if x == b {
                      found = true
                      break
                    }
                  }
                  found
                } else {
                  true
                }
              None => true
            }
          } else {
            true
          }
        I(i) =>
          if field == "ts" {
            stats_may_ts(cs, i, fn(lo, hi) { i >= lo && i <= hi })
          } else {
            true
          }
      }
    Neq(_, _) => true // 反等值无整段跳过语义
    In(field, vals) => {
      // 任一值可能与段统计相交即不可跳过
      let mut any = false
      for v in vals {
        if seg_may_match_f(cs, Eq(field, v)) {
          any = true
          break
        }
      }
      any
    }
    NotIn(_, _) => true
    Lt(field, v) =>
      match v {
        I(i) =>
          if field == "ts" {
            stats_may_ts(cs, i, fn(lo, _) { lo < i })
          } else {
            true
          }
        S(s) =>
          if field == "category" {
            stats_may_str(cs, s, fn(c) { c < 0 })
          } else {
            true
          }
        B(_) => true
      }
    Lte(field, v) =>
      match v {
        I(i) =>
          if field == "ts" {
            stats_may_ts(cs, i, fn(lo, _) { lo <= i })
          } else {
            true
          }
        S(s) =>
          if field == "category" {
            stats_may_str(cs, s, fn(c) { c <= 0 })
          } else {
            true
          }
        B(_) => true
      }
    Gt(field, v) =>
      match v {
        I(i) =>
          if field == "ts" {
            stats_may_ts(cs, i, fn(_, hi) { hi > i })
          } else {
            true
          }
        S(s) =>
          if field == "category" {
            stats_may_str(cs, s, fn(c) { c > 0 })
          } else {
            true
          }
        B(_) => true
      }
    Gte(field, v) =>
      match v {
        I(i) =>
          if field == "ts" {
            stats_may_ts(cs, i, fn(_, hi) { hi >= i })
          } else {
            true
          }
        S(s) =>
          if field == "category" {
            stats_may_str(cs, s, fn(c) { c >= 0 })
          } else {
            true
          }
        B(_) => true
      }
    And(children) => {
      let mut all = true
      for c in children {
        if !seg_may_match_f(cs, c) {
          all = false
          break
        }
      }
      all
    }
    Or(children) => {
      let mut any = false
      for c in children {
        if seg_may_match_f(cs, c) {
          any = true
          break
        }
      }
      any
    }
    Not(_) => true
    Glob(_, _) => true // 通配符不能整段剪枝，恒 true
  }
}

///|
/// 惰性加载 centroids（首次调用后缓存进 Namespace）。
fn[S : @store.ObjectStore] ensure_centroids(
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
  let seen : Set[String] = Set([])
  let out : Array[String] = Array()
  for t in terms {
    if !seen.contains(t) {
      seen.add(t)
      out.push(t)
    }
  }
  out
}

///|
/// 候选合并收尾：row→id（dense 用 min_id+行号，否则缓存 id 列）→ tombstone
/// 过滤 → score 降序 → top-k。
/// cands 元素 = (segment 下标, segment 内行号, 分数)。
fn[S : @store.ObjectStore] results_from_candidates(
  n : Namespace[S],
  cands : Array[(Int, Int, Double)],
  tomb : Set[UInt64],
  k : Int,
) -> Array[QueryResult] raise @core.SpndError {
  let out : Array[QueryResult] = Array()
  for c in cands {
    let (si, row, score) = c
    let seg = n.manifest.segments[si]
    let cs = ensure_seg(n, si)
    let id = row_id(n, cs, seg.id, row)
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

pub extend QueryResult with Debug::{to_repr}
pub extend SegStats with Debug::{to_repr}
