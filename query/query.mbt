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
// - id 列 runs_u64（列头自描述）：读侧二分定位 run 再线性取行，不展开全列
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
  mut ids : @format.IdCol?
  mut blockmax : Array[Array[(Int, Int)]]?
  mut blockmax_size : Int
  mut blockmax_tried : Bool
  mut pq_m : Int
  mut pq_dsub : Int
  mut pq_codebook : Array[Float]?
  mut vec_info : (Int, Int, Int)? // rows/vector.bin 的 (dim, dtype, count)
  mut block_stats : (Int, Int, Array[(Int64, Int64)])? // (block_size, row_count, blocks)
  mut block_stats_tried : Bool
  // SlabV2 单文件段：惰性探测 + 解码的组件索引（至多 1 次 Range GET）。
  // None 且 slab_tried=true 表示该段没有 segment.slab（沿用碎片文件布局）。
  mut slab_index : @format.SlabIndex?
  mut slab_tried : Bool
  // 可选：段元数据里的写入序（L0 delta 段新旧判定用；缺省按 manifest 顺序）。
  mut seg_seq : Int
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
pub async fn[S : @store.ObjectStore] warm_namespace(
  n : Namespace[S],
) -> Unit {
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
    let reqs : Array[(String, CachedSeg, String)] = Array(
      capacity=need_ids.length(),
    )
    for i in 0..<need_ids.length() {
      reqs.push((need_ids[i], need_cs[i], "rows/id.bin"))
    }
    let results = seg_read_components_many(n, reqs)
    for i in 0..<need_ids.length() {
      let key = seg_legacy_key(n.ns, need_ids[i], "rows/id.bin")
      let bs = match results[i] {
        Some(b) => b
        None => raise @core.NotFound(key)
      }
      let arr = @format.decode_id_col(bs)
      need_cs[i].ids = Some(arr)
    }
  }
  let _ = tombstones_of(n)
}

///|
/// 带进程级 metadata 缓存的 open：GET namespace.json 检查 head_manifest；
/// 若 head 未变，直接复用旧 Namespace（保留 seg 解码缓存/centroids/tombstone）。
/// 若 head 已变，加载新 manifest，并**继承旧 segment 缓存**（seg id 不可变）。
pub async fn[S : @store.ObjectStore] open_cached(
  cache : MetadataCache[S],
  store : S,
  ns : String,
) -> Namespace[S] {
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
pub async fn[S : @store.ObjectStore] open(
  store : S,
  ns : String,
) -> Namespace[S] {
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

// ----------------------------------------------------------------------
// SlabV2 单文件段读路径（L0 Delta Slab 透明融合读取）
//
// 约定：`{ns}/_segments/{seg}/segment.slab` 是 SlabV2 的单文件布局
// （Header + 连续数据块 + Index Table [+ Trailer]，见 format/slab.mbt）。
// 读路径对「碎片文件」与「单文件段」完全透明：
// - 首次访问某段时用 1 次 Range GET 拉 Header(+Index) 解码出 SlabIndex，常驻
//   CachedSeg（`slab_index` / `slab_tried`），后续组件读全部是精准 Range GET；
// - Index 位于文件尾部时按 index_offset 补拉一次尾部切片解码；
// - 段不存在 segment.slab 时沿用原有碎片文件路径（rows/*.bin、fts/*.bin）。
// 所有路径（id/text/category/ts/public/doc_len/fts_dir/postings/vector）都收敛
// 到 `seg_read_component` / `seg_read_component_range` 两个统一入口。
// ----------------------------------------------------------------------

///|
/// Slab Index 预读长度（Header + Index 一次拉完；固定偏移布局足够）。
const SLAB_INDEX_PREFETCH : Int = 4096

///|
/// Index 位于文件尾部时的补充预读长度（Index + Trailer；分区多的段也能一次拉完）。
const SLAB_INDEX_TAIL_PREFETCH : Int = 65536

///|
/// SlabIndex 单条目字节上界估算（2B 名长 + 名 ≤15B + 8 + 8 + 4）：前置 index
/// 超出头预读窗口时按剩余条目数定长续拉（不足再拉），不拉数据区。
const SLAB_INDEX_ENTRY_MAX : Int = 37

///|
/// SlabV2 单文件段的 key。
fn seg_slab_key(ns : String, seg_id : String) -> String {
  "\{ns}/_segments/\{seg_id}/segment.slab"
}

///|
/// 碎片文件布局下的组件 key。
fn seg_legacy_key(ns : String, seg_id : String, rel_path : String) -> String {
  "\{ns}/_segments/\{seg_id}/\{rel_path}"
}

///|
/// 自定义列在 slab 里的别名：`rows/{field}.bin` ↔ `{field}`。
fn slab_alt_name(rel_path : String) -> String {
  if !rel_path.has_prefix("rows/") || !rel_path.has_suffix(".bin") {
    return ""
  }
  let rest = rel_path[5:].to_owned()
  let parts = rest.split(".").collect()
  if parts.is_empty() {
    ""
  } else {
    parts[0].to_owned()
  }
}

///|
/// 去掉 `.bin` 后缀（slab 内组件名不带后缀：`vec/part-0`、`fts/dir`）。
fn slab_strip_bin(name : String) -> String {
  if name.has_suffix(".bin") && name.length() > 4 {
    name[0:name.length() - 4].to_owned()
  } else {
    ""
  }
}

///|
/// 在 SlabIndex 中定位组件：先按原相对路径（format 侧已带常见归一化别名），
/// 再按去 `.bin` 后缀的组件名，最后按 `rows/{field}.bin` → `{field}` 自定义列别名。
fn slab_entry_of(
  index : @format.SlabIndex,
  rel_path : String,
) -> @format.SlabEntry? {
  match index.get(rel_path) {
    Some(e) => Some(e)
    None => {
      let stripped = slab_strip_bin(rel_path)
      let by_strip = if stripped != "" {
        index.get(stripped)
      } else {
        None
      }
      match by_strip {
        Some(e) => Some(e)
        None => {
          let alt = slab_alt_name(rel_path)
          if alt != "" {
            index.get(alt)
          } else {
            None
          }
        }
      }
    }
  }
}

///|
/// 由「从偏移 0 拉到的 header 切片」解码 SlabIndex；index 在尾部时返回 None
/// （调用方补读尾部）。缺 magic / 截断一律 None（该段不是 SlabV2）。
fn slab_index_of_header_bytes(bs : Bytes) -> @format.SlabIndex? {
  let (_ver, io) = @format.decode_slab_header(bs) catch {
    _ => return None
  }
  let off = io.to_int()
  if off < 0 || off >= bs.length() {
    return None
  }
  let idx = @format.decode_slab_index(bs, off) catch {
    _ => return None
  }
  Some(idx)
}

///|
/// 拉取并解码某段的 SlabIndex（index 在尾部时共 2 次 Range GET）。
async fn[S : @store.ObjectStore] load_slab_index(
  n : Namespace[S],
  seg_id : String,
) -> @format.SlabIndex? {
  let key = seg_slab_key(n.ns, seg_id)
  let hdr = match n.store.get_range(key, @store.ByteRange::{ off: 0, len: SLAB_INDEX_PREFETCH }) {
    Some(b) => b
    None => return None
  }
  match slab_index_of_header_bytes(hdr) {
    Some(idx) => Some(idx)
    None => {
      let (_ver, index_offset) = @format.decode_slab_header(hdr) catch {
        _ => return None
      }
      let off = index_offset.to_int()
      if off == @format.SLAB_HEADER_LEN {
        // 前置 index 超出头预读窗口（分区多的段）：从断点续拉剩余 index
        // 字节（定长估算、不足再拉、至多 8 轮），不拉数据区。完整后用
        // 已解条目直接组 SlabIndex，不再二次解码。
        let scan0 = @format.scan_slab_index(hdr, off) catch {
          _ => return None
        }
        let mut idx = scan0.0
        let count = scan0.1
        let mut pos = scan0.2
        let mut done = scan0.3
        let mut acc = hdr
        let mut tries = 0
        while !done && tries < 8 {
          tries += 1
          let remaining = count - idx.entries.length()
          if remaining <= 0 {
            break
          }
          let want = remaining * SLAB_INDEX_ENTRY_MAX + 32
          match n.store.get_range(key, @store.ByteRange::{ off: pos, len: want }) {
            Some(part) => {
              let b = Buffer()
              b.write_bytesview(acc.exact_view(start=0, end=pos))
              b.write_bytes(part.exact_view())
              acc = b.to_bytes()
              let scan = @format.scan_slab_index(acc, off) catch {
                _ => return None
              }
              idx = scan.0
              pos = scan.2
              done = scan.3
            }
            None => return None
          }
        }
        if done {
          Some(idx)
        } else {
          None
        }
      } else if off > 0 {
        // 旧尾部布局（兼容）：按 header 里的 index_offset 补拉尾部切片。
        match n.store.get_range(key, @store.ByteRange::{ off: off, len: SLAB_INDEX_TAIL_PREFETCH }) {
          Some(tail) => {
            let idx = @format.decode_slab_index(tail, 0) catch {
              _ => return None
            }
            Some(idx)
          }
          None => None
        }
      } else {
        None
      }
    }
  }
}

///|
/// 惰性探测 + 解码某段的 SlabIndex（结果常驻 CachedSeg）。
async fn[S : @store.ObjectStore] ensure_slab_index(
  n : Namespace[S],
  cs : CachedSeg,
  seg_id : String,
) -> @format.SlabIndex? {
  if cs.slab_tried {
    return cs.slab_index
  }
  cs.slab_tried = true
  let idx = load_slab_index(n, seg_id)
  cs.slab_index = idx
  idx
}

///|
/// 统一组件读取入口：SlabV2 段按 SlabEntry 映射到 `segment.slab` 内的
/// `(entry.offset, entry.length)` 精准 Range GET；碎片段读 `{rel_path}`。
/// 组件不存在返回 None（调用方保留原有「可选对象」语义）。
pub async fn[S : @store.ObjectStore] seg_read_component(
  n : Namespace[S],
  seg_id : String,
  cseg : CachedSeg,
  rel_path : String,
) -> Bytes? {
  match ensure_slab_index(n, cseg, seg_id) {
    Some(index) =>
      match slab_entry_of(index, rel_path) {
        Some(e) =>
          n.store.get_range(seg_slab_key(n.ns, seg_id), @store.ByteRange::{ off: e.offset.to_int(), len: e.length.to_int() })
        None => n.store.get(seg_legacy_key(n.ns, seg_id, rel_path))
      }
    None => n.store.get(seg_legacy_key(n.ns, seg_id, rel_path))
  }
}

///|
/// 统一组件范围读入口：有 SlabIndex 时映射为
/// `(entry.offset + off, len)`（组件内相对偏移 → 文件内绝对偏移）。
pub async fn[S : @store.ObjectStore] seg_read_component_range(
  n : Namespace[S],
  seg_id : String,
  cseg : CachedSeg,
  rel_path : String,
  off : Int,
  len : Int,
) -> Bytes? {
  match ensure_slab_index(n, cseg, seg_id) {
    Some(index) =>
      match slab_entry_of(index, rel_path) {
        Some(e) =>
          n.store.get_range(seg_slab_key(n.ns, seg_id), @store.ByteRange::{ off: e.offset.to_int() + off, len: len })
        None =>
          n.store.get_range(seg_legacy_key(n.ns, seg_id, rel_path), @store.ByteRange::{ off: off, len: len })
      }
    None => n.store.get_range(seg_legacy_key(n.ns, seg_id, rel_path), @store.ByteRange::{ off: off, len: len })
  }
}

///|
/// 必需组件读：缺失按 NotFound 报错。
pub async fn[S : @store.ObjectStore] seg_read_component_or_fail(
  n : Namespace[S],
  seg_id : String,
  cseg : CachedSeg,
  rel_path : String,
) -> Bytes {
  match seg_read_component(n, seg_id, cseg, rel_path) {
    Some(bs) => bs
    None => raise @core.NotFound(seg_legacy_key(n.ns, seg_id, rel_path))
  }
}

///|
/// 批量预读统一入口（碎片段走 1 次 `get_many`，slab 段走 1 次
/// `get_range_many`；未探测过 slab 的段先合并成 1 次 `get_range_many` 探测）。
/// 入参 = (seg_id, CachedSeg, 相对路径)，返回与入参同长同序，缺失保持 None。
pub async fn[S : @store.ObjectStore] seg_read_components_many(
  n : Namespace[S],
  reqs : Array[(String, CachedSeg, String)],
) -> Array[Bytes?] {
  let out : Array[Bytes?] = Array(capacity=reqs.length())
  for _ in 0..<reqs.length() {
    out.push(None)
  }
  if reqs.is_empty() {
    return out
  }
  // 1) 批量探测尚未判定布局的段（每段 1 次 Range GET，合并为一次调用）。
  let probe_seg : Array[String] = Array()
  let probe_cs : Array[CachedSeg] = Array()
  let seen : Set[String] = Set([])
  for r in reqs {
    let (seg_id, cs, _) = r
    if !cs.slab_tried && !seen.contains(seg_id) {
      seen.add(seg_id)
      probe_seg.push(seg_id)
      probe_cs.push(cs)
    }
  }
  if !probe_seg.is_empty() {
    let ranges : Array[@store.KeyRange] = Array(capacity=probe_seg.length())
    for seg_id in probe_seg {
      ranges.push(@store.KeyRange::{ key: seg_slab_key(n.ns, seg_id), off: 0, len: SLAB_INDEX_PREFETCH })
    }
    let heads = @store.ObjectStore::get_range_many(n.store, ranges)
    let need_tail : Array[Int] = Array()
    for i in 0..<probe_seg.length() {
      probe_cs[i].slab_tried = true
      match heads[i] {
        Some(hdr) =>
          match slab_index_of_header_bytes(hdr) {
            Some(idx) => probe_cs[i].slab_index = Some(idx)
            None =>
              // index 在尾部（或非 SlabV2）：走一次单键补读判定。
              need_tail.push(i)
          }
        None => ()
      }
    }
    for i in need_tail {
      probe_cs[i].slab_index = load_slab_index(n, probe_seg[i])
    }
  }
  // 2) 按布局分派：slab 段合并成一次 get_range_many，碎片段合并成一次 get_many。
  let slab_ranges : Array[@store.KeyRange] = Array()
  let slab_pos : Array[Int] = Array()
  let legacy_keys : Array[String] = Array()
  let legacy_pos : Array[Int] = Array()
  for i in 0..<reqs.length() {
    let (seg_id, cs, rel_path) = reqs[i]
    let entry = match cs.slab_index {
      Some(index) => slab_entry_of(index, rel_path)
      None => None
    }
    match entry {
      Some(e) => {
        slab_pos.push(i)
        slab_ranges.push(@store.KeyRange::{
          key: seg_slab_key(n.ns, seg_id),
          off: e.offset.to_int(),
          len: e.length.to_int(),
        })
      }
      None => {
        legacy_pos.push(i)
        legacy_keys.push(seg_legacy_key(n.ns, seg_id, rel_path))
      }
    }
  }
  if !slab_ranges.is_empty() {
    let rs = @store.ObjectStore::get_range_many(n.store, slab_ranges)
    for j in 0..<slab_pos.length() {
      out[slab_pos[j]] = rs[j]
    }
  }
  if !legacy_keys.is_empty() {
    let rs = @store.ObjectStore::get_many(n.store, legacy_keys)
    for j in 0..<legacy_pos.length() {
      out[legacy_pos[j]] = rs[j]
    }
  }
  out
}

///|
/// 块级 ts 统计（rows/blockstats.bin，266 行块）。不存在时返回 None。
async fn[S : @store.ObjectStore] seg_block_stats(
  n : Namespace[S],
  cs : CachedSeg,
  seg_id : String,
) -> (Int, Int, Array[(Int64, Int64)])? {
  if cs.block_stats_tried {
    return cs.block_stats
  }
  cs.block_stats_tried = true
  match seg_read_component(n, seg_id, cs, "rows/blockstats.bin") {
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
async fn[S : @store.ObjectStore] seg_vec_info(
  n : Namespace[S],
  cs : CachedSeg,
  seg_id : String,
) -> (Int, Int, Int)? {
  match cs.vec_info {
    Some(x) => Some(x)
    None => {
      match seg_read_component_range(n, seg_id, cs, "rows/vector.bin", 0, 16) {
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
async fn[S : @store.ObjectStore] global_gen_cids(
  n : Namespace[S],
  ver : String,
) -> Array[Int] {
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
async fn[S : @store.ObjectStore] prewarm_global_gen_cids(
  n : Namespace[S],
  vers : Array[String],
) -> Unit {
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
async fn[S : @store.ObjectStore] global_gen_pack_size(
  n : Namespace[S],
  ver : String,
) -> Int {
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
async fn[S : @store.ObjectStore] ensure_global_cids(
  n : Namespace[S],
) -> Array[Int]? {
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
async fn[S : @store.ObjectStore] tombstones_of(
  n : Namespace[S],
) -> Set[UInt64] {
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
async fn[S : @store.ObjectStore] get_object(
  store : S,
  key : String,
) -> Bytes {
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
  seg_seq : Int
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
  // 可选 seg_seq：L0 delta 段用来判定「谁更新」；缺省 -1（按 manifest 顺序）。
  let seg_seq = match m.get("seg_seq") {
    Some(Number(d, ..)) => d.to_int()
    _ => -1
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
    seg_seq,
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
    slab_index: None,
    slab_tried: false,
    seg_seq: info.seg_seq,
    matchers: Map([]),
    vec_parts: Map([]),
  }
}

///|
/// 批量加载 manifest 里所有缓存 miss 的 seg meta.json（已缓存的段不重复请求）。
async fn[S : @store.ObjectStore] prewarm_seg_metas(
  n : Namespace[S],
) -> Unit {
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
async fn[S : @store.ObjectStore] ensure_seg(
  n : Namespace[S],
  seg_idx : Int,
) -> CachedSeg {
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
async fn[S : @store.ObjectStore] seg_dir(
  n : Namespace[S],
  cs : CachedSeg,
  seg_id : String,
) -> Array[@format.FtsDirEntry] {
  match cs.dir {
    Some(d) => d
    None => {
      let d = @format.decode_fts_dir(
        seg_read_component_or_fail(n, seg_id, cs, "fts/dir.bin"),
      )
      cs.dir = Some(d)
      d
    }
  }
}

///|
/// doc_len 列（缓存）。
async fn[S : @store.ObjectStore] seg_doc_len(
  n : Namespace[S],
  cs : CachedSeg,
  seg_id : String,
) -> Array[Int] {
  match cs.doc_len {
    Some(a) => a
    None => {
      let a = match
        @format.decode_col(
          seg_read_component_or_fail(n, seg_id, cs, "fts/doc_len.bin"),
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
/// id 列（缓存；dense 段不加载）。runs_u64 段返回 run 表（不展开全列），
/// 逐行列返回 IdPlain。
async fn[S : @store.ObjectStore] seg_ids(
  n : Namespace[S],
  cs : CachedSeg,
  seg_id : String,
) -> @format.IdCol {
  match cs.ids {
    Some(a) => a
    None => {
      let a = @format.decode_id_col(
        seg_read_component_or_fail(n, seg_id, cs, "rows/id.bin"),
      )
      cs.ids = Some(a)
      a
    }
  }
}

///|
/// block-max 索引（缓存；文件不存在时记 tried 避免重复 GET）。
async fn[S : @store.ObjectStore] seg_blockmax(
  n : Namespace[S],
  cs : CachedSeg,
  seg_id : String,
) -> Array[Array[(Int, Int)]]? {
  if cs.blockmax_tried {
    return cs.blockmax
  }
  cs.blockmax_tried = true
  match seg_read_component(n, seg_id, cs, "fts/blockmax.bin") {
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
async fn[S : @store.ObjectStore] seg_pq_codebook(
  n : Namespace[S],
  cs : CachedSeg,
  seg_id : String,
) -> (Int, Int, Array[Float])? {
  match cs.pq_codebook {
    Some(cbs) => Some((cs.pq_m, cs.pq_dsub, cbs))
    None => {
      match seg_read_component(n, seg_id, cs, "vec/pq-codebook.bin") {
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
/// row→id：dense 段用 min_id+行号；否则读 id 列（缓存）——runs_u64 段
/// 二分定位 run 再线性取行，逐行列直接下标。
async fn[S : @store.ObjectStore] row_id(
  n : Namespace[S],
  cs : CachedSeg,
  seg_id : String,
  row : Int,
) -> UInt64 {
  if cs.id_dense {
    return cs.min_id + row.to_uint64()
  }
  let ids = seg_ids(n, cs, seg_id)
  ids.at(row)
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
async fn[S : @store.ObjectStore] ensure_centroids(
  n : Namespace[S],
) -> @format.Centroids {
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
/// 过滤 → 跨段按 id 去重（LSM 语义：manifest 中更靠后的段 / seg_seq 更大的段
/// 视为更新，覆盖旧段的同一 doc id）→ score 降序 → top-k。
/// cands 元素 = (segment 下标, segment 内行号, 分数)。
async fn[S : @store.ObjectStore] results_from_candidates(
  n : Namespace[S],
  cands : Array[(Int, Int, Double)],
  tomb : Set[UInt64],
  k : Int,
) -> Array[QueryResult] {
  let best : Map[UInt64, (Int, Double)] = Map([])
  for c in cands {
    let (si, row, score) = c
    let seg = n.manifest.segments[si]
    let cs = ensure_seg(n, si)
    let id = row_id(n, cs, seg.id, row)
    if tomb.contains(id) {
      continue
    }
    // 段新旧序：seg_seq 标注优先，否则用 manifest 下标（靠后 = 新）。
    let rank = if cs.seg_seq >= 0 { cs.seg_seq } else { si }
    match best.get(id) {
      Some((old_rank, old_score)) =>
        if rank > old_rank || (rank == old_rank && score > old_score) {
          best.set(id, (rank, score))
        }
      None => best.set(id, (rank, score))
    }
  }
  let out : Array[QueryResult] = Array(capacity=best.length())
  for kv in best.iter() {
    out.push({ id: kv.0, score: kv.1.1 })
  }
  out.sort_by(fn(a, b) { b.score.compare(a.score) })
  if out.length() > k {
    out.truncate(k)
  }
  out
}

pub extend QueryResult with Debug::{to_repr}
pub extend SegStats with Debug::{to_repr}
