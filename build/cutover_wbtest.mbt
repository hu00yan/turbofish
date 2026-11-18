// build/cutover_wbtest.mbt: IVF 自适应重分区（cutover）白盒测试。
//
// 覆盖：
// 1) `target_rows_for`：公式的带内取值（dim/nprobe 敏感性）+ 上下界夹紧 +
//    非法输入回落；
// 2) `maybe_cutover`：触发边界（严格 > 2×TARGET_ROWS）、不触发时零副作用；
// 3) cutover 后不变量：Σ|vec/part-{c} rows| == seg.row_count、meta.partitions
//    与写出组件一致、逐行「分区 = 新中心最近中心」；
// 4) manifest.centroid_version 全局一致：新 manifest 的每个段都按同一个
//    （新）中心分区，旧中心分区的段通不过同一检查（负向对照，防检查被放宽）；
// 5) 墓碑物理化 + deleted 语义继承。

///|
/// cutover 测试用配置：8 维小向量、50 行/段、nlist=1（首训 k=1）、
/// f32 精确（不经 f16 往返）、target_rows 显式覆盖。
fn tc_cfg(ns : String, target_rows : Int) -> BuildConfig {
  {
    ns,
    segment_rows: 50,
    nlist: 1,
    use_f16: false,
    vector_dim: 8,
    write_stats: false,
    id_dense: false,
    use_dict_cols: false,
    use_bool_bitmap: false,
    vec_storage: VF16,
    write_blockmax: false,
    normalize_vecs: false,
    write_block_stats: false,
    global_vec_parts: false,
    write_fts_bloom: true,
    global_pack_size: 1,
    fts_tokenizer: @core.Word,
    distance_metric: "cosine",
    target_rows,
  }
}

///|
/// 段分区一致性检查：
/// - Σ|vec/part-{c} rows| == seg.row_count（返回值①）；
/// - meta.json 的 partitions 与 slab 实际写出的 `vec/part-*` 组件一致；
/// - 逐行：所在分区的中心在 `cent` 下是最优（距离 ≤ 全局最优 + eps），
///   不一致行数在返回值②（eps 覆盖 f16 往返的近平局翻转）。
async fn part_check(
  store : WbStore,
  ns : String,
  seg : @format.SegmentMeta,
  cent : @format.Centroids,
  eps : Double,
) -> (Int, Int) {
  let index = read_slab_index(store, ns, seg.id, seg.size_bytes)
  let parts_meta = seg_partitions(store, "\{ns}/_segments/\{seg.id}")
  // meta.partitions 与写出组件一致：个数相等且每个 cid 都有组件。
  let mut comp_count = 0
  for e in index.entries {
    if e.name.has_prefix("vec/part-") {
      comp_count += 1
    }
  }
  assert_eq(comp_count, parts_meta.length())
  let dim = cent.dim
  let k = cent.k()
  let mut sum_rows = 0
  let mut bad = 0
  for c in parts_meta {
    let bs = read_slab_component_by_name(
      store, ns, seg.id, index, "vec/part-\{c}",
    )
    let part = @format.decode_part(bs)
    assert_eq(part.cid, c)
    sum_rows += part.rows.length()
    for i in 0..<part.rows.length() {
      let v : Array[Float] = Array(capacity=dim)
      for d in 0..<dim {
        v.push(part.data[i * dim + d])
      }
      let mut best = @core.cosine_dist_f32(v, 0, cent.data, 0, dim)
      for j in 1..<k {
        let dj = @core.cosine_dist_f32(v, 0, cent.data, j * dim, dim)
        if dj < best {
          best = dj
        }
      }
      let dc = @core.cosine_dist_f32(v, 0, cent.data, c * dim, dim)
      if dc > best + eps {
        bad += 1
      }
    }
  }
  (sum_rows, bad)
}

///|
/// 段的 id 列回读（验证物理化/重写后的行集合）。
async fn seg_ids(store : WbStore, ns : String, seg : @format.SegmentMeta) -> Array[UInt64] {
  let index = read_slab_index(store, ns, seg.id, seg.size_bytes)
  let bs = read_slab_component_by_name(store, ns, seg.id, index, "id")
  match @format.decode_col(bs) {
    @format.ColU64(a) => a
    _ => fail("id column dtype is not u64")
  }
}

///|
test "target_rows_for: 公式带内取值、dim/nprobe 敏感性与上下界夹紧" {
  // 50k / 500k × 128 维、nprobe=3：公式值远低于下界 ⇒ 256
  assert_eq(target_rows_for(50000, 128, 3), 256)
  assert_eq(target_rows_for(500000, 128, 3), 256)
  // 带内值：1e9 docs × 8 维 × nprobe=3 ⇒ round(sqrt(260416.7)) = 510
  assert_eq(target_rows_for(1000000000, 8, 3), 510)
  // dim 翻倍（行字节翻倍）⇒ 目标行数 ÷ √2：361
  assert_eq(target_rows_for(1000000000, 16, 3), 361)
  // nprobe 4 倍 ⇒ 目标行数 ÷ 2：722（对照 8 维 nprobe=3 的 510 × √2 ≈ 722）
  assert_eq(target_rows_for(1000000000, 4, 3), 722)
  // 上界夹紧：1 ⇒ 公式值 1768 ⇒ 1024
  assert_eq(target_rows_for(500000000, 1, 1), 1024)
  // 非法输入回落下界
  assert_eq(target_rows_for(0, 8, 3), 256)
  assert_eq(target_rows_for(100, 0, 3), 256)
  assert_eq(target_rows_for(100, 8, 0), 256)
}

///|
async test "maybe_cutover: 未达阈值零副作用，边界是严格大于" {
  let store = WbStore::new()
  let cfg = tc_cfg("tc-noop", 25)
  // 50 行 / k=1 = 50 == 2×25：不触发（严格 >）
  let _ = ingest_l0_slab(store, cfg, mkdocs(50, 8, 1000UL, 7U), [])
  let m0 = head_manifest_of(store, "tc-noop")
  let r = maybe_cutover(store, cfg)
  assert_eq(r is None, true)
  let m1 = head_manifest_of(store, "tc-noop")
  assert_eq(m1.id, m0.id)
  assert_eq(m1.centroid_version, m0.centroid_version)
  assert_eq(m1.segments.length(), 1)
  // 空 namespace：也返回 None
  let store2 = WbStore::new()
  assert_eq(maybe_cutover(store2, tc_cfg("tc-empty", 25)) is None, true)
}

///|
async test "cutover 重分区：part 行数/partitions/最近中心不变量 + centroid_version 一致" {
  let store = WbStore::new()
  let cfg = tc_cfg("tc-rep", 25)
  // 第 1 批 50 行：50/1 = 50 ≤ 50，不触发
  let _ = ingest_l0_slab(store, cfg, mkdocs(50, 8, 1000UL, 7U), [])
  let m_before = head_manifest_of(store, "tc-rep")
  let cv_old = m_before.centroid_version
  // 第 2 批 50 行：100/1 = 100 > 50 ⇒ cutover，nlist' = ceil(100/25) = 4
  let _ = ingest_l0_slab(store, cfg, mkdocs(50, 8, 1050UL, 7U), [])
  let out = match maybe_cutover(store, cfg) {
    Some(o) => o
    None => fail("cutover should fire at 100/1 > 2×25")
  }
  assert_eq(out.nlist_old, 1)
  assert_eq(out.nlist_new, 4)
  assert_eq(out.target_rows, 25)
  assert_eq(out.rows, 100)
  assert_eq(out.segs_in, 2)
  assert_eq(out.segs_out, 2) // 100 行 / 50 行每段
  assert_eq(out.uploads, 2) // 每源段恰好上传一次
  assert_eq(out.attempts, 1)
  assert_eq(out.centroid_bytes > 0, true)
  // 新中心对象：k = 4
  let cent_new = load_centroids(store, "tc-rep", out.centroid_version)
  assert_eq(cent_new.k(), 4)
  // manifest：centroid_version 唯一指向新中心，段全部被替换
  let m = head_manifest_of(store, "tc-rep")
  assert_eq(m.id, out.head)
  assert_eq(m.centroid_version, out.centroid_version)
  assert_eq(m.centroid_version == cv_old, false)
  assert_eq(m.num_docs, 100)
  for s in m.segments {
    for old in m_before.segments {
      assert_eq(s.id == old.id, false)
    }
  }
  // 不变量：Σ|vec/part-{c} rows| == seg.row_count；partitions 与组件一致；
  // 逐行分区 = 新中心最近中心（f32 精确 ⇒ eps 极小）
  for s in m.segments {
    let (sum_rows, bad) = part_check(store, "tc-rep", s, cent_new, 1.0e-6)
    assert_eq(sum_rows, s.row_count)
    assert_eq(bad, 0)
  }
  // 负向对照：旧（k=1 中心）分区的段在新中心下通不过同一检查——证明该检查
  // 能抓住「一半段旧中心、一半段新中心」的混用 manifest。
  let mut old_bad = 0
  for s in m_before.segments {
    let (_sum, bad) = part_check(store, "tc-rep", s, cent_new, 1.0e-6)
    old_bad += bad
  }
  assert_eq(old_bad > 0, true)
  // cutover 之后的写入批次沿用新中心：manifest 不变版本、段仍逐行一致。
  let _ = ingest_l0_slab(store, cfg, mkdocs(50, 8, 1100UL, 7U), [])
  let m3 = head_manifest_of(store, "tc-rep")
  assert_eq(m3.centroid_version, out.centroid_version)
  assert_eq(m3.segments.length(), 3)
  for s in m3.segments {
    let (sum_rows, bad) = part_check(store, "tc-rep", s, cent_new, 1.0e-6)
    assert_eq(sum_rows, s.row_count)
    assert_eq(bad, 0)
  }
}

///|
async test "cutover 物理化 tombstone 并继承 deleted 语义" {
  let store = WbStore::new()
  let cfg = tc_cfg("tc-del", 25)
  let b1 = mkdocs(50, 8, 2000UL, 7U)
  let _ = ingest_l0_slab(store, cfg, b1, [])
  // 删除 2 行后追加第 2 批：100 行 / k=1 > 50 ⇒ cutover
  let dels = [b1[3].id, b1[7].id]
  let _ = ingest_l0_slab(store, cfg, [], dels)
  let _ = ingest_l0_slab(store, cfg, mkdocs(50, 8, 2050UL, 7U), [])
  let out = match maybe_cutover(store, cfg) {
    Some(o) => o
    None => fail("cutover should fire")
  }
  // 被删行物理化：重写行数 = 98，manifest.num_docs 同步
  assert_eq(out.rows, 98)
  let m = head_manifest_of(store, "tc-del")
  assert_eq(m.num_docs, 98)
  // deleted 原样继承（未物理化的并发删除仍被过滤的语义前提）
  assert_eq(m.deleted.length(), 2)
  assert_eq(m.deleted[0], dels[0])
  assert_eq(m.deleted[1], dels[1])
  // 新段的行集合不含被删 id；每段分区不变量仍然成立
  let cent_new = load_centroids(store, "tc-del", m.centroid_version)
  let mut total = 0
  for s in m.segments {
    for id in seg_ids(store, "tc-del", s) {
      assert_eq(id == dels[0] || id == dels[1], false)
    }
    let (sum_rows, bad) = part_check(store, "tc-del", s, cent_new, 1.0e-6)
    assert_eq(sum_rows, s.row_count)
    assert_eq(bad, 0)
    total += s.row_count
  }
  assert_eq(total, 98)
}

// ---------- Defect B：cutover × 合并并发的确定性交错测试 ----------

///|
/// 可控 store 包装器：在「读 M_start → 完成合并上传 → 发布」窗口内强制插入
/// 一次完整的并发 cutover——触发点 = 本次合并第一次写 manifest 对象（合并段
/// 已上传、发布未发生）。cutover 直接打 inner，避免递归；cutover 自己的段
/// 上传不过包装器（merge_slab_puts 只计合并段）。
priv struct CutoverRaceStore[S] {
  inner : S
  cfg : BuildConfig
  mut armed : Bool
  mut cutover_ran : Int
  mut merge_slab_puts : Int
  mut cv_after : String?
}

///|
fn[S] CutoverRaceStore::new(
  inner : S,
  cfg : BuildConfig,
) -> CutoverRaceStore[S] {
  {
    inner,
    cfg,
    armed: true,
    cutover_ran: 0,
    merge_slab_puts: 0,
    cv_after: None,
  }
}

///|
impl[S : @store.ObjectStore] @store.ObjectStore for CutoverRaceStore[S] with fn get(
  self : CutoverRaceStore[S],
  key : String,
) -> Bytes? {
  self.inner.get(key)
}

///|
impl[S : @store.ObjectStore] @store.ObjectStore for CutoverRaceStore[S] with fn put(
  self : CutoverRaceStore[S],
  key : String,
  value : Bytes,
) -> Unit {
  if key.has_suffix("segment.slab") {
    self.merge_slab_puts += 1
  }
  self.inner.put(key, value)
  if self.armed && key.contains("/_manifest/") {
    self.armed = false
    match maybe_cutover(self.inner, self.cfg) {
      Some(o) => {
        self.cutover_ran += 1
        self.cv_after = Some(o.centroid_version)
      }
      None => ()
    }
  }
}

///|
impl[S : @store.ObjectStore] @store.ObjectStore for CutoverRaceStore[S] with fn put_if_match(
  self : CutoverRaceStore[S],
  key : String,
  e : @store.Expected,
  value : Bytes,
) -> Bool {
  let @store.Expected(expected) = e
  self.inner.put_if_match(key, @store.Expected(expected), value)
}

///|
impl[S : @store.ObjectStore] @store.ObjectStore for CutoverRaceStore[S] with fn get_range(
  self : CutoverRaceStore[S],
  key : String,
  br : @store.ByteRange,
) -> Bytes? {
  let offset = br.off
  let len = br.len
  self.inner.get_range(key, @store.ByteRange::{ off: offset, len: len })
}

///|
impl[S : @store.ObjectStore] @store.ObjectStore for CutoverRaceStore[S] with fn list(
  self : CutoverRaceStore[S],
  prefix : String,
) -> Array[String] {
  self.inner.list(prefix)
}

///|
impl[S : @store.ObjectStore] @store.ObjectStore for CutoverRaceStore[S] with fn delete(
  self : CutoverRaceStore[S],
  key : String,
) -> Unit {
  self.inner.delete(key)
}

///|
impl[S : @store.ObjectStore] @store.ObjectStore for CutoverRaceStore[S] with fn head_version(
  self : CutoverRaceStore[S],
  key : String,
) -> String? {
  self.inner.head_version(key)
}

///|
/// 并发「重写 head 第一个段」并发布（模拟 cutover/合并把前缀段换成新段 id）：
/// 旧行全量搬进新段（不丢行），manifest 其余字段原样继承。
async fn[S : @store.ObjectStore] rewrite_first_seg_and_publish(
  store : S,
  cfg : BuildConfig,
) -> Unit {
  let meta = match read_namespace(store, cfg.ns) {
    Some(m) => m
    None => return
  }
  let m = load_manifest(store, cfg.ns, meta.head_manifest)
  let s0 = m.segments[0]
  let docs = load_segment_docs(store, cfg.ns, s0, None, 0)
  let cent = load_centroids(store, cfg.ns, m.centroid_version)
  let seg_id = new_slab_segment_id()
  let (slab_bytes, meta_bytes, meta_seg) = build_segment_slab(
    cfg, cent, docs, 0, docs.length(), seg_id~,
  )
  store.put_many([
    (segment_slab_key(cfg.ns, seg_id), slab_bytes),
    (segment_meta_key(cfg.ns, seg_id), meta_bytes),
  ])
  let segs : Array[@format.SegmentMeta] = Array()
  segs.push(meta_seg)
  for s in m.segments[1:] {
    segs.push(s)
  }
  let new_id = new_manifest_id()
  let manifest : @format.ManifestData = {
    id: new_id,
    parent: Some(m.id),
    segments: segs,
    deleted: m.deleted,
    deleted_roar: m.deleted_roar,
    vec_global_version: m.vec_global_version,
    global_gen: m.global_gen,
    centroid_version: m.centroid_version,
    num_docs: m.num_docs,
    avg_doc_len: m.avg_doc_len,
  }
  store.put(manifest_key(cfg.ns, new_id), json_bytes(manifest.to_json()))
  publish_head(store, cfg.ns, m.id, new_id)
}

///|
/// 可控 store 包装器：在「读 M_start → 完成合并上传 → 发布」窗口内强制插入
/// 一次并发「前缀段被重写成新段 id」并发布（同上触发点）。
priv struct SegRewriteRaceStore[S] {
  inner : S
  cfg : BuildConfig
  mut armed : Bool
  mut rewrites : Int
  mut merge_slab_puts : Int
}

///|
fn[S] SegRewriteRaceStore::new(
  inner : S,
  cfg : BuildConfig,
) -> SegRewriteRaceStore[S] {
  { inner, cfg, armed: true, rewrites: 0, merge_slab_puts: 0 }
}

///|
impl[S : @store.ObjectStore] @store.ObjectStore for SegRewriteRaceStore[S] with fn get(
  self : SegRewriteRaceStore[S],
  key : String,
) -> Bytes? {
  self.inner.get(key)
}

///|
impl[S : @store.ObjectStore] @store.ObjectStore for SegRewriteRaceStore[S] with fn put(
  self : SegRewriteRaceStore[S],
  key : String,
  value : Bytes,
) -> Unit {
  if key.has_suffix("segment.slab") {
    self.merge_slab_puts += 1
  }
  self.inner.put(key, value)
  if self.armed && key.contains("/_manifest/") {
    self.armed = false
    rewrite_first_seg_and_publish(self.inner, self.cfg)
    self.rewrites += 1
  }
}

///|
impl[S : @store.ObjectStore] @store.ObjectStore for SegRewriteRaceStore[S] with fn put_if_match(
  self : SegRewriteRaceStore[S],
  key : String,
  e : @store.Expected,
  value : Bytes,
) -> Bool {
  let @store.Expected(expected) = e
  self.inner.put_if_match(key, @store.Expected(expected), value)
}

///|
impl[S : @store.ObjectStore] @store.ObjectStore for SegRewriteRaceStore[S] with fn get_range(
  self : SegRewriteRaceStore[S],
  key : String,
  br : @store.ByteRange,
) -> Bytes? {
  let offset = br.off
  let len = br.len
  self.inner.get_range(key, @store.ByteRange::{ off: offset, len: len })
}

///|
impl[S : @store.ObjectStore] @store.ObjectStore for SegRewriteRaceStore[S] with fn list(
  self : SegRewriteRaceStore[S],
  prefix : String,
) -> Array[String] {
  self.inner.list(prefix)
}

///|
impl[S : @store.ObjectStore] @store.ObjectStore for SegRewriteRaceStore[S] with fn delete(
  self : SegRewriteRaceStore[S],
  key : String,
) -> Unit {
  self.inner.delete(key)
}

///|
impl[S : @store.ObjectStore] @store.ObjectStore for SegRewriteRaceStore[S] with fn head_version(
  self : SegRewriteRaceStore[S],
  key : String,
) -> String? {
  self.inner.head_version(key)
}

///|
/// id 集合的重复检测：返回 (总数, 是否有重复)。
fn dup_check(ids : Array[UInt64]) -> (Int, Bool) {
  let seen : Map[UInt64, Int] = Map([])
  for id in ids {
    match seen.get(id) {
      Some(n) => seen.set(id, n + 1)
      None => seen.set(id, 1)
    }
  }
  let mut dup = false
  for id in ids {
    match seen.get(id) {
      Some(n) =>
        if n > 1 {
          dup = true
        }
      None => ()
    }
  }
  (ids.length(), dup)
}

///|
/// Defect B 回归（确定性交错，不靠 sleep）：可控 store 包装器在「读 M_start →
/// 完成合并上传 → 发布」之间插入一次完整的并发 cutover。断言：stale 发布被拒、
/// 整次合并放弃并重试（合并段重建 = slab 上传 2 次）；最终 manifest 唯一
/// centroid_version 是 cutover 之后的（无混合中心，逐行分区检查通过）；行不
/// 重复、被删行不复活。
async test "cutover×merge 交错：stale 发布被拒整体重试，无混合中心/行重复/删行复活" {
  let store = WbStore::new()
  let cfg = tc_cfg("tc-race", 8)
  let b1 = mkdocs(10, 8, 1000UL, 41U)
  let b2 = mkdocs(10, 8, 2000UL, 42U)
  let b3 = mkdocs(10, 8, 3000UL, 43U)
  let _ = ingest_l0_slab(store, cfg, b1, [])
  let del = [b1[3].id]
  let _ = ingest_l0_slab(store, cfg, [], del)
  let _ = ingest_l0_slab(store, cfg, b2, [])
  let _ = ingest_l0_slab(store, cfg, b3, [])
  let m_before = head_manifest_of(store, "tc-race")
  let cv_before = m_before.centroid_version
  assert_eq(m_before.segments.length(), 3)
  // 触发条件已满足：30 行 / k=1 = 30 > 2×8（cutover 必然执行）
  let hook = CutoverRaceStore::new(store, cfg)
  let res = compact_optimistic(hook, cfg)
  assert_eq(res is Some(_), true)
  // 并发 cutover 确实被强制插入过，且换了中心
  assert_eq(hook.cutover_ran, 1)
  let cv_after = match hook.cv_after {
    Some(v) => v
    None => fail("cutover should produce a new centroid_version")
  }
  assert_eq(cv_after == cv_before, false)
  // stale 发布被拒 ⇒ 整次合并放弃并重试：第 1 个合并段被弃、重建上传第 2 个
  assert_eq(hook.merge_slab_puts, 2)
  let m = head_manifest_of(store, "tc-race")
  // 无混合中心：唯一 centroid_version = cutover 之后的新中心
  assert_eq(m.centroid_version, cv_after)
  // 无行重复、无删行复活：29 行恰好各一次
  let ids = visible_ids(store, "tc-race", m)
  assert_eq(ids.length(), 29)
  let (total, dup) = dup_check(ids)
  assert_eq(total, 29)
  assert_eq(dup, false)
  assert_eq(has_id(ids, b1[3].id), false) // 被删行不复活
  // 分区语义一致：合并段逐行按最终中心最近邻分区（旧代码挂旧中心分区 ⇒ bad>0）
  let cent_new = load_centroids(store, "tc-race", m.centroid_version)
  let mut sum_all = 0
  for s in m.segments {
    let (sum_rows, bad) = part_check(store, "tc-race", s, cent_new, 1.0e-6)
    assert_eq(sum_rows, s.row_count)
    assert_eq(bad, 0)
    sum_all += s.row_count
  }
  assert_eq(sum_all, 29)
}

///|
/// Defect B 回归（前缀段替换）：合并窗口内前缀段被并发进程「重写成新段 id」
/// （cutover/合并的典型动作，旧行全量搬进新段）。rebase 必须发现前缀段缺失并
/// 整体放弃重试，否则旧行同时出现在合并段与 tail 新段（行重复）。断言：整体
/// 重试（slab 上传 2 次）、行恰好各一次、被删行不复活。
async test "前缀段被并发替换：合并整体重试，无行重复/丢失/删行复活" {
  let store = WbStore::new()
  let cfg = tc_cfg("tc-segrace", 8)
  let b1 = mkdocs(10, 8, 5000UL, 51U)
  let _ = ingest_l0_slab(store, cfg, b1, [])
  let del = [b1[2].id, b1[5].id]
  let _ = ingest_l0_slab(store, cfg, [], del)
  let b2 = mkdocs(10, 8, 6000UL, 52U)
  let _ = ingest_l0_slab(store, cfg, b2, [])
  let m_before = head_manifest_of(store, "tc-segrace")
  assert_eq(m_before.segments.length(), 2)
  let hook = SegRewriteRaceStore::new(store, cfg)
  let res = compact_optimistic(hook, cfg)
  assert_eq(res is Some(_), true)
  assert_eq(hook.rewrites, 1)
  // 前缀段缺失 ⇒ 整体放弃并重试：合并段重建（上传 2 次）
  assert_eq(hook.merge_slab_puts, 2)
  let m = head_manifest_of(store, "tc-segrace")
  // 18 行恰好各一次：旧行不重复（合并段 + 重写新段不双重承载）、不丢失
  let ids = visible_ids(store, "tc-segrace", m)
  assert_eq(ids.length(), 18)
  let (total, dup) = dup_check(ids)
  assert_eq(total, 18)
  assert_eq(dup, false)
  assert_eq(has_id(ids, b1[2].id), false) // 被删行不复活
  assert_eq(has_id(ids, b1[5].id), false)
}
