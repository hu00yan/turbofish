// query 包：seekpond/v1 读路径。
//
// 职责：打开 namespace（绑定 manifest 快照）→ BM25 / IVF 向量 / 混合（RRF）检索，
// 全程遵守查询成本模型：
// - namespace.json / manifest.json / seg meta.json / fts/dir.bin / centroids：整对象 GET（小）
// - postings.bin：只用 store.get_range 拉 term 局部区间（外层 16B = SPNDPOS1 头）
// - vec/part-*.bin、rows/*.bin（id / 过滤列）：整对象 GET
// - 一次查询绑定 open 时的 manifest 快照（强一致读）
//
// Q1 增强（全部自动启用，旧数据无新字段时逐字节兼容）：
// - per-segment 解码缓存（dir/doc_len/id/过滤列/blockmax，跨查询复用）
// - seg meta.json stats：filter 与段统计不相交时整段跳过
// - id_encoding=dense_u64：row→id 用 min_id+行号，不读 id.bin
// - 字典列按 code 比对、bool 位图直接查位、PQ16 分区 ADC
// - fts/blockmax.bin 存在时 BM25 走 block-max WAND（正确性与暴力路径一致）

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
/// seg meta.json 的过滤统计（write_stats=true 时存在）。
pub(all) struct SegStats {
  has_ts : Bool
  ts_min : Int64
  ts_max : Int64
  has_cat : Bool
  cat_values : Array[String]
  has_pub : Bool
  pub_values : Array[Bool]
} derive(Debug)

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
pub fn[S : @store.ObjectStore] MetadataCache::new() -> MetadataCache[S] {
  { entries: Map([]), hits: 0, misses: 0, head_ttl_ms: 1000UL }
}

///|
pub fn[S : @store.ObjectStore] MetadataCache::invalidate(
  self : MetadataCache[S],
  ns : String,
) -> Unit {
  self.entries.remove(ns)
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
      if now - old.head_checked_ms < cache.head_ttl_ms {
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
        let n : Namespace[S] = {
          store,
          ns,
          meta,
          manifest,
          centroids: cent,
          cache: old.cache,
          tombstones: None,
          vec_global_cids: None,
          global_gen_cids: Map([]),
          global_gen_packs: Map([]),
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
      let all : Array[String] = Array::new(capacity=g.deltas.length() + 1)
      all.push(g.base)
      for d in g.deltas {
        all.push(d)
      }
      let seen : Set[String] = Set([])
      let out : Array[String] = Array::new(capacity=all.length())
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
      let m = match parse_json_bytes(bs, "global vec meta") {
        Object(mm) => mm
        _ => raise @core.Corrupt("global vec meta is not an object")
      }
      let cids : Array[Int] = Array::new()
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
  let cids : Array[Int] = Array::new()
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
  @utf8.decode(bs.view()) catch {
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
  let cat_values : Array[String] = Array::new()
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
  let pub_values : Array[Bool] = Array::new()
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
      let cs : CachedSeg = {
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
      }
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
fn seg_may_match(cs : CachedSeg, filter : Filter?) -> Bool {
  match filter {
    None => true
    Some(FI64(field, v)) =>
      if field == "ts" {
        match cs.stats {
          Some(s) =>
            if s.has_ts {
              v >= s.ts_min && v <= s.ts_max
            } else {
              true
            }
          None => true
        }
      } else {
        true
      }
    Some(FStr(field, v)) =>
      if field == "category" {
        match cs.stats {
          Some(s) =>
            if s.has_cat {
              let mut found = false
              for x in s.cat_values {
                if x == v {
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
    Some(FBool(field, v)) =>
      if field == "public" {
        match cs.stats {
          Some(s) =>
            if s.has_pub {
              let mut found = false
              for x in s.pub_values {
                if x == v {
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
/// 候选合并收尾：row→id（dense 用 min_id+行号，否则缓存 id 列）→ tombstone
/// 过滤 → score 降序 → top-k。
/// cands 元素 = (segment 下标, segment 内行号, 分数)。
fn[S : @store.ObjectStore] results_from_candidates(
  n : Namespace[S],
  cands : Array[(Int, Int, Double)],
  tomb : Set[UInt64],
  k : Int,
) -> Array[QueryResult] raise @core.SpndError {
  let out : Array[QueryResult] = Array::new()
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
