// build/l0_delta_wbtest.mbt: L0 单文件 Delta Slab + 乐观 Rebase Compaction 白盒测试。
//
// 覆盖：
// 1. 写放大预算：已初始化 namespace 下 200 条带向量文档 ≤ 5 次 PUT
// 2. 乐观 rebase：compaction 期间并发插入的新段不丢，老文档也不丢
// 3. 增删语义：仅 deletes 的批次只更新 roaring tombstone，被删 id 不再可见

///|
/// 包装 store：第一次写 manifest 时触发一次「并发写」（模拟 compaction 快照之后、
/// CAS 发布之前前台 `ingest_l0_slab` 插入新段），之后透传。并发写直接打到
/// inner，避免递归。`slab_puts` 记录合并段上传次数（用于断言「绝不重传大段」）。
priv struct RebaseStore[S] {
  inner : S
  cfg : BuildConfig
  pending : Array[@core.Doc]
  mut armed : Bool
  mut slab_puts : Int
}

///|
fn[S] RebaseStore::new(
  inner : S,
  cfg : BuildConfig,
  pending : Array[@core.Doc],
) -> RebaseStore[S] {
  { inner, cfg, pending, armed: true, slab_puts: 0 }
}

///|
impl[S : @store.ObjectStore] @store.ObjectStore for RebaseStore[S] with fn get(
  self : RebaseStore[S],
  key : String,
) -> Bytes? {
  self.inner.get(key)
}

///|
impl[S : @store.ObjectStore] @store.ObjectStore for RebaseStore[S] with fn put(
  self : RebaseStore[S],
  key : String,
  value : Bytes,
) -> Unit {
  if key.has_suffix("segment.slab") {
    self.slab_puts += 1
  }
  self.inner.put(key, value)
  // 并发写发生在 compaction 已拍快照、尚未 CAS 发布的窗口里：制造一次 head 前移
  if self.armed && key.contains("/_manifest/") {
    self.armed = false
    let _ = ingest_l0_slab(self.inner, self.cfg, self.pending, [])
  }
}

///|
impl[S : @store.ObjectStore] @store.ObjectStore for RebaseStore[S] with fn put_if_match(
  self : RebaseStore[S],
  key : String,
  e : @store.Expected,
  value : Bytes,
) -> Bool {
  let @store.Expected(expected) = e
  self.inner.put_if_match(key, @store.Expected(expected), value)
}

///|
impl[S : @store.ObjectStore] @store.ObjectStore for RebaseStore[S] with fn get_range(
  self : RebaseStore[S],
  key : String,
  br : @store.ByteRange,
) -> Bytes? {
  let offset = br.off
  let len = br.len
  self.inner.get_range(key, @store.ByteRange::{ off: offset, len: len })
}

///|
impl[S : @store.ObjectStore] @store.ObjectStore for RebaseStore[S] with fn list(
  self : RebaseStore[S],
  prefix : String,
) -> Array[String] {
  self.inner.list(prefix)
}

///|
impl[S : @store.ObjectStore] @store.ObjectStore for RebaseStore[S] with fn delete(
  self : RebaseStore[S],
  key : String,
) -> Unit {
  self.inner.delete(key)
}

///|
impl[S : @store.ObjectStore] @store.ObjectStore for RebaseStore[S] with fn head_version(
  self : RebaseStore[S],
  key : String,
) -> String? {
  self.inner.head_version(key)
}

///|
/// 单条 doc（用于模拟并发插入的晚到文档）。
fn one_doc(
  id : UInt64,
  dim : Int,
  text : String,
  seed : UInt,
) -> @core.Doc {
  let rng = @core.Rng::new(seed)
  let vec : Array[Float] = Array(capacity=dim)
  for _ in 0..<dim {
    vec.push(Float::from_double(rng.next_range(-1.0, 1.0)))
  }
  { id, text, vector: vec, category: "cat0", ts: 1700000000L, public: true }
}

///|
/// 段内没有扁平 `vector` 组件（Step 1 起向量只存 `vec/part-*` 分区）。
async fn store_has_no_vector_component(
  store : @store.MemStore,
  ns : String,
  seg : @format.SegmentMeta,
) -> Bool {
  let index = read_slab_index(store, ns, seg.id, seg.size_bytes)
  index.get("vector") is None
}

///|
/// manifest 视角下可见的 id（读每段六列并过滤 tombstone）。
async fn[S : @store.ObjectStore] visible_ids(
  store : S,
  ns : String,
  m : @format.ManifestData,
) -> Array[UInt64] {
  let tomb : Set[UInt64] = Set([])
  for d in m.deleted {
    tomb.add(d)
  }
  let out : Array[UInt64] = Array()
  for seg in m.segments {
    for d in load_segment_docs(store, ns, seg, None, 0) {
      if !tomb.contains(d.id) {
        out.push(d.id)
      }
    }
  }
  out
}

///|
fn has_id(ids : Array[UInt64], id : UInt64) -> Bool {
  for x in ids {
    if x == id {
      return true
    }
  }
  false
}

///|
async test "l0 slab: 200 docs within 5 puts" {
  let mem = @store.MemStore::new()
  let bs = @store.BudgetStore::new(mem, @store.IoBudget::unlimited())
  let cfg = {
    ..BuildConfig::default("l0budget"),
    segment_rows: 2000,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
  }
  // 第一批负责初始化（namespace + schema + centroids），不计入预算
  let _ = ingest_l0_slab(bs, cfg, mkdocs(1, 8, 1UL, 3U), [])
  bs.reset()
  let m1 = head_manifest_of(bs, "l0budget")
  // 第二批：已初始化 namespace，500 条带向量文档（这里取 200 条以减少测试时间）
  let mid = ingest_l0_slab(bs, cfg, mkdocs(200, 8, 2UL, 5U), [])
  let puts = bs.tracker().puts
  assert_eq(puts <= 5, true) // 实测 4 次（slab + manifest + head log + head 指针）
  // 新段是单文件 slab：只有 slab 本体 + 兼容元对象，没有 per-cid 碎片
  let m2 = head_manifest_of(bs, "l0budget")
  assert_eq(m2.id, mid)
  assert_eq(m2.segments.length(), 2)
  assert_eq(m2.segments[1].row_count, 200)
  assert_eq(is_l0_slab_segment(m2.segments[1].id), true)
  let segp = "l0budget/_segments/\{m2.segments[1].id}"
  assert_eq(mem.list("\{segp}/").length(), 2)
  assert_eq(mem.head_version("\{segp}/segment.slab") is Some(_), true)
  assert_eq(mem.head_version("\{segp}/meta.json") is Some(_), true)
  // 列回读一致
  let docs = load_segment_docs(bs, "l0budget", m2.segments[1], None, 8)
  assert_eq(docs.length(), 200)
  assert_eq(docs[0].id, 2UL)
  assert_eq(docs[199].id, 201UL)
  assert_eq(docs[0].text, mkdocs(200, 8, 2UL, 5U)[0].text)
  // 老段（m1）仍然在
  assert_eq(m2.segments[0].id, m1.segments[0].id)
}

///|
async test "l0 slab: optimistic rebase keeps concurrent segment" {
  let mem = @store.MemStore::new()
  let cfg = {
    ..BuildConfig::default("l0rebase"),
    segment_rows: 4,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
  }
  // 3 个 L0 slab 段（12 行）
  let _ = ingest_l0_slab(mem, cfg, mkdocs(4, 8, 1UL, 11U), [])
  let _ = ingest_l0_slab(mem, cfg, mkdocs(4, 8, 100UL, 12U), [])
  let _ = ingest_l0_slab(mem, cfg, mkdocs(4, 8, 200UL, 13U), [])
  let m3 = head_manifest_of(mem, "l0rebase")
  assert_eq(m3.segments.length(), 3)
  let old_ids = visible_ids(mem, "l0rebase", m3)
  assert_eq(old_ids.length(), 12)
  // compaction 期间并发插入第 4 段（doc_id = 99999）
  let late = one_doc(99999UL, 8, "late arrival", 99U)
  let hook = RebaseStore::new(mem, cfg, [late])
  let new_id = compact_optimistic(hook, cfg)
  assert_eq(new_id is Some(_), true)
  let m_next = head_manifest_of(mem, "l0rebase")
  // 合并段在前，并发新段原样保留在后
  assert_eq(m_next.segments.length(), 2)
  assert_eq(is_l0_slab_segment(m_next.segments[0].id), true)
  assert_eq(m_next.segments[0].row_count, 12)
  assert_eq(m_next.segments[1].min_id, 99999UL)
  assert_eq(m_next.segments[1].max_id, 99999UL)
  // 查询视角：老文档与并发写入的 99999 同时可见
  let ids = visible_ids(mem, "l0rebase", m_next)
  assert_eq(ids.length(), 13)
  assert_eq(has_id(ids, 99999UL), true)
  assert_eq(has_id(ids, 1UL), true)
  assert_eq(has_id(ids, 203UL), true)
  // 没有墓碑残留
  assert_eq(m_next.deleted.length(), 0)
  // 乐观 rebase：大段只上传一次（CAS 冲突后只重写 manifest，不重传段）
  assert_eq(hook.slab_puts, 1)
}

///|
async test "l0 slab: delete-only batch updates roaring tombstone" {
  let mem = @store.MemStore::new()
  let cfg = {
    ..BuildConfig::default("l0del"),
    segment_rows: 8,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
  }
  let _ = ingest_l0_slab(mem, cfg, mkdocs(6, 8, 1UL, 21U), [])
  let m1 = head_manifest_of(mem, "l0del")
  assert_eq(m1.deleted.length(), 0)
  assert_eq(m1.deleted_roar, None)
  assert_eq(m1.segments.length(), 1)
  // 仅含 deletes 的批次：不新增段，只更新 tombstone 对象
  let mid = ingest_l0_slab(mem, cfg, [], [2UL, 4UL])
  let m2 = head_manifest_of(mem, "l0del")
  assert_eq(m2.id, mid)
  assert_eq(m2.segments.length(), 1)
  assert_eq(m2.deleted.length(), 2)
  assert_eq(m2.deleted[0], 2UL)
  assert_eq(m2.deleted[1], 4UL)
  let roar_id = match m2.deleted_roar {
    Some(v) => v
    None => fail("expected deleted_roar")
  }
  let reraw = must_get(mem, "l0del/_tombstones/\{roar_id}.roar")
  let roar_ids = @format.decode_roaring(reraw)
  assert_eq(roar_ids.length(), 2)
  assert_eq(roar_ids[0], 2UL)
  assert_eq(roar_ids[1], 4UL)
  // 被删 id 不再可见，其余原样
  let ids = visible_ids(mem, "l0del", m2)
  assert_eq(ids.length(), 4)
  assert_eq(has_id(ids, 2UL), false)
  assert_eq(has_id(ids, 4UL), false)
  assert_eq(has_id(ids, 1UL), true)
  assert_eq(has_id(ids, 6UL), true)
  // 再删一次：tombstone 合并去重升序
  let _ = ingest_l0_slab(mem, cfg, [], [4UL, 5UL])
  let m3 = head_manifest_of(mem, "l0del")
  assert_eq(m3.deleted.length(), 3)
  assert_eq(m3.deleted[0], 2UL)
  assert_eq(m3.deleted[1], 4UL)
  assert_eq(m3.deleted[2], 5UL)
  let roar3 = match m3.deleted_roar {
    Some(v) => v
    None => fail("expected deleted_roar")
  }
  assert_eq(@format.decode_roaring(must_get(mem, "l0del/_tombstones/\{roar3}.roar")).length(), 3)
}

///|
/// 段内向量不变式（Step 1）：扁平 `vector` 组件不存在；`vec/part-*` 每行恰
/// 出现一次（Σ|part rows| == seg.row_count）；slab 的 meta.partitions 与写出
/// 的 `vec/part-*` cid 集合一致。
async fn assert_seg_vec_parts(
  store : @store.MemStore,
  ns : String,
  seg : @format.SegmentMeta,
) -> Unit {
  assert_eq(store_has_no_vector_component(store, ns, seg), true)
  let index = read_slab_index(store, ns, seg.id, seg.size_bytes)
  let seen : Array[Bool] = Array(capacity=seg.row_count)
  for _ in 0..<seg.row_count {
    seen.push(false)
  }
  let part_names : Array[String] = Array()
  for e in index.entries {
    if !e.name.has_prefix("vec/part-") {
      continue
    }
    part_names.push(e.name)
    let bs = read_slab_component_by_name(store, ns, seg.id, index, e.name)
    let rows = if @format.is_pq_shared_part(bs) {
      @format.decode_pq_part_shared(bs).rows
    } else if @format.is_pq_part(bs) {
      @format.decode_pq_part(bs).rows
    } else {
      @format.decode_part(bs).rows
    }
    for r in rows {
      assert_eq(r >= 0 && r < seg.row_count, true)
      assert_eq(seen[r], false) // 每行恰在一个 part 里
      seen[r] = true
    }
  }
  let mut total = 0
  for b in seen {
    if b {
      total += 1
    }
  }
  assert_eq(total, seg.row_count) // Σ|part rows| == seg.row_count
  part_names.sort()
  let meta_names : Array[String] = Array()
  for c in seg_partitions(store, "\{ns}/_segments/\{seg.id}") {
    meta_names.push("vec/part-\{c}")
  }
  meta_names.sort()
  assert_eq(part_names, meta_names) // meta.partitions 与写出的 vec/part-* 一致
}

///|
/// Step 1 行为（全局代际链停写、向量回段内分区）：manifest 恒为
/// vec_global_version=None / global_gen=None；每段向量恒在 `vec/part-*` 里，
/// 每行恰出现一次（Σ|part rows| == seg.row_count），meta.partitions 与写出的
/// part 一致；compact_optimistic 合并段同语义，列回读一致。
async test "l0 slab: 向量随段内 vec/part-* 写入，manifest 无全局代际链" {
  let mem = @store.MemStore::new()
  let cfg = {
    ..BuildConfig::single_copy("l0g"),
    segment_rows: 4,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
  }
  let _ = ingest_l0_slab(mem, cfg, mkdocs(4, 8, 1UL, 31U), [])
  let _ = ingest_l0_slab(mem, cfg, mkdocs(4, 8, 100UL, 32U), [])
  let m2 = head_manifest_of(mem, "l0g")
  assert_eq(m2.segments.length(), 2)
  // 全局代际链已停写：恒为 None（Step 1 语义）
  assert_eq(m2.vec_global_version is None, true)
  assert_eq(m2.global_gen is None, true)
  for seg in m2.segments {
    assert_eq(is_l0_slab_segment(seg.id), true)
    assert_seg_vec_parts(mem, "l0g", seg)
  }
  // 乐观 compaction：合并段同样只写段内分区
  let cid = compact_optimistic(mem, cfg)
  assert_eq(cid is Some(_), true)
  let m3 = head_manifest_of(mem, "l0g")
  assert_eq(m3.segments.length(), 1)
  assert_eq(m3.segments[0].row_count, 8)
  assert_eq(m3.global_gen is None, true)
  assert_eq(m3.vec_global_version is None, true)
  assert_seg_vec_parts(mem, "l0g", m3.segments[0])
  // 合并段列回读一致（向量从 vec/part-* 重组）
  let docs = load_segment_docs(mem, "l0g", m3.segments[0], None, 8)
  assert_eq(docs.length(), 8)
  assert_eq(docs[0].id, 1UL)
  assert_eq(docs[7].id, 103UL)
}

///|
/// 不变量：manifest 里的每个段都必须在 `_segments/{id}/meta.json` 有可读元对象。
/// 回归：`ingest_l0_slab` 曾经只写 slab、丢掉 meta.json，导致 query / compact /
/// compact_global 在线上写路径产生的段上全部 NotFound。
async test "l0 slab: 每个 manifest 段都有可读 meta.json（含 compact_optimistic 合并段）" {
  let mem = @store.MemStore::new()
  let cfg = {
    ..BuildConfig::default("l0metainv"),
    segment_rows: 2000,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
  }
  let _ = ingest_l0_slab(mem, cfg, mkdocs(5, 8, 1UL, 3U), [])
  let m1 = head_manifest_of(mem, "l0metainv")
  for s in m1.segments {
    let key = segment_meta_key("l0metainv", s.id)
    assert_eq(mem.get(key) is Some(_), true)
  }
  // compact_optimistic 合并出的段同样必须有
  let _ = compact_optimistic(mem, cfg)
  let m2 = head_manifest_of(mem, "l0metainv")
  for s in m2.segments {
    let key = segment_meta_key("l0metainv", s.id)
    assert_eq(mem.get(key) is Some(_), true)
  }
}

///|
/// 段数压力触发的前缀合并：段数压到 ≤ max_segments，行无丢失，superseded
/// 段在 grace 窗口内保留（gc_deleted 恒 0），合并批信息记录在 outcome 里。
async test "maybe_compact_segments caps segments at max_segments" {
  let mem = @store.MemStore::new()
  let cfg = {
    ..BuildConfig::default("l0cap"),
    segment_rows: 2000,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
  }
  // 10 个小段（每批 3 行）
  for b in 0..<10 {
    let _ = ingest_l0_slab(
      mem,
      cfg,
      mkdocs(3, 8, (b * 100 + 1).to_uint64(), (20 + b).reinterpret_as_uint()),
      [],
    )
  }
  let m0 = head_manifest_of(mem, "l0cap")
  assert_eq(m0.segments.length(), 10)
  let outcome = maybe_compact_segments(mem, cfg, max_segments=3)
  assert_eq(outcome.merges > 0, true)
  assert_eq(outcome.segs_before, 10)
  assert_eq(outcome.segs_after <= 3, true)
  assert_eq(outcome.head != "", true)
  let m1 = head_manifest_of(mem, "l0cap")
  assert_eq(m1.segments.length() <= 3, true)
  // 30 行一个不少（合并只物理化 tombstone，本例无删除）
  let ids = visible_ids(mem, "l0cap", m1)
  assert_eq(ids.length(), 30)
  // 被合并掉的段 id 记录在 outcome；grace 默认 300s ⇒ 刚合并不回收
  assert_eq(outcome.superseded.length() > 0, true)
  assert_eq(outcome.gc_deleted, 0)
  assert_eq(outcome.gc_kept_in_grace, outcome.superseded.length())
  for id in outcome.superseded {
    assert_eq(mem.list("l0cap/_segments/\{id}/").length() > 0, true)
  }
}

///|
/// superseded 段 GC：只删不在任何 live manifest 里的段；grace 窗口内保留；
/// 超窗后连 slab + meta.json + 该段 vec/part-* 组件一并回收；live 段不受影响。
async test "gc_superseded_segments reclaims only out-of-grace segments" {
  let mem = @store.MemStore::new()
  let cfg = {
    ..BuildConfig::default("l0gc"),
    segment_rows: 2000,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
  }
  let _ = ingest_l0_slab(mem, cfg, mkdocs(3, 8, 1UL, 31U), [])
  let _ = ingest_l0_slab(mem, cfg, mkdocs(3, 8, 100UL, 32U), [])
  let _ = ingest_l0_slab(mem, cfg, mkdocs(3, 8, 200UL, 33U), [])
  let m_before = head_manifest_of(mem, "l0gc")
  assert_eq(m_before.segments.length(), 3)
  let seg0 = m_before.segments[0].id
  let seg1 = m_before.segments[1].id
  // 旧布局兼容对象：GC 必须把段目录下的 vec/part-* 组件一并回收
  mem.put("l0gc/_segments/\{seg0}/vec/part-0.bin", b"stub")
  // 合并前 2 段 → 1 段（第 3 段是 tail 保留）
  let merged = compact_optimistic(mem, cfg, max_prefix_segments=2)
  assert_eq(merged is Some(_), true)
  let m = head_manifest_of(mem, "l0gc")
  assert_eq(m.segments.length(), 2)
  // ① 刚合并（grace 默认 300s）⇒ superseded 段仍在 grace 窗口，保留
  let stat1 = gc_superseded_segments(mem, "l0gc")
  assert_eq(stat1.deleted, 0)
  assert_eq(stat1.kept_live, 2)
  assert_eq(stat1.kept_in_grace, 2)
  assert_eq(mem.list("l0gc/_segments/\{seg0}/").length() > 0, true)
  // ② now 超窗（+400s）⇒ 不在任何 live manifest 里的段被回收
  let later = @env.now() + 400000UL
  let stat2 = gc_superseded_segments(mem, "l0gc", now_ms=later)
  assert_eq(stat2.deleted, 2)
  assert_eq(stat2.kept_live, 2)
  assert_eq(stat2.kept_in_grace, 0)
  assert_eq(mem.list("l0gc/_segments/\{seg0}/").length(), 0)
  assert_eq(mem.list("l0gc/_segments/\{seg1}/").length(), 0)
  // live 段的 slab + meta.json 完好，行无丢失
  let m2 = head_manifest_of(mem, "l0gc")
  assert_eq(m2.segments.length(), 2)
  for s in m2.segments {
    assert_eq(mem.get(segment_slab_key("l0gc", s.id)) is Some(_), true)
    assert_eq(mem.get(segment_meta_key("l0gc", s.id)) is Some(_), true)
  }
  let ids = visible_ids(mem, "l0gc", m2)
  assert_eq(ids.length(), 9)
}

///|
/// 回归：slab index 表超过 1024B（组件数随 nlist 增长）的段在合并读取时
/// 不再被固定 tail 窗口截断（旧 read_slab_index 在这里 Truncated）。
async test "compact_optimistic merges segments with large slab index" {
  let mem = @store.MemStore::new()
  let cfg = {
    ..BuildConfig::default("l0bigidx"),
    segment_rows: 2000,
    nlist: 64,
    use_f16: false,
    vector_dim: 8,
  }
  let _ = ingest_l0_slab(mem, cfg, mkdocs(300, 8, 1UL, 41U), [])
  let _ = ingest_l0_slab(mem, cfg, mkdocs(300, 8, 1000UL, 42U), [])
  let m0 = head_manifest_of(mem, "l0bigidx")
  assert_eq(m0.segments.length(), 2)
  // 段 index 表含 64 个 vec/part-* 条目，> 1024B（旧固定 tail 窗口会截断）
  let idx0 = read_slab_index(
    mem,
    "l0bigidx",
    m0.segments[0].id,
    m0.segments[0].size_bytes,
  )
  assert_eq(idx0.entries.length() > 30, true)
  let merged = compact_optimistic(mem, cfg, max_prefix_segments=2)
  assert_eq(merged is Some(_), true)
  let m1 = head_manifest_of(mem, "l0bigidx")
  assert_eq(m1.segments.length(), 1)
  let ids = visible_ids(mem, "l0bigidx", m1)
  assert_eq(ids.length(), 600)
}

///|
/// tier 公式 = floor(log2(row_count / base_rows))：整数边界精确（4000 行
/// 恰为 tier 1、3999 行仍是 tier 0），小段落负档。
test "segment_tier = floor(log2(row_count / segment_rows))" {
  assert_eq(segment_tier(2000, 2000), 0)
  assert_eq(segment_tier(3999, 2000), 0)
  assert_eq(segment_tier(4000, 2000), 1)
  assert_eq(segment_tier(1000, 2000), -1)
  assert_eq(segment_tier(3, 2000), -10) // floor(log2(3/2000)) = floor(-9.38)
  assert_eq(segment_tier(9, 2000), -8) // floor(log2(9/2000)) = floor(-7.80)
  assert_eq(segment_tier(300, 2000), -3) // floor(log2(300/2000)) = floor(-2.74)
  assert_eq(segment_tier(50000, 2000), 4) // floor(log2(25)) = 4
  assert_eq(segment_tier(0, 2000), segment_tier(1, 2000)) // 空段按 1 行
}

///|
/// size-tiered：只合并同 tier 内最旧的 fanout 个段，不跨 tier；合并明细
/// 记录 tier / 输入段数 / 输入输出行数。
async test "maybe_compact_segments merges oldest same-tier segments only" {
  let mem = @store.MemStore::new()
  let cfg = {
    ..BuildConfig::default("l0tier"),
    segment_rows: 2000,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
  }
  // 3 个 100 行段（tier -5）+ 1 个 1200 行段（tier -1）
  let _ = ingest_l0_slab(mem, cfg, mkdocs(100, 8, 1UL, 61U), [])
  let _ = ingest_l0_slab(mem, cfg, mkdocs(100, 8, 1000UL, 62U), [])
  let _ = ingest_l0_slab(mem, cfg, mkdocs(100, 8, 2000UL, 63U), [])
  let _ = ingest_l0_slab(mem, cfg, mkdocs(1200, 8, 3000UL, 64U), [])
  let m0 = head_manifest_of(mem, "l0tier")
  assert_eq(m0.segments.length(), 4)
  let big_id = m0.segments[3].id
  let outcome = maybe_compact_segments(mem, cfg)
  // 3 个 tier -5 段合并成 1 个 300 行段（tier -3）；1200 行段（tier -1）不动
  assert_eq(outcome.merges, 1)
  assert_eq(outcome.segs_before, 4)
  assert_eq(outcome.segs_after, 2)
  let m1 = head_manifest_of(mem, "l0tier")
  assert_eq(m1.segments.length(), 2)
  let mut big_kept = false
  for s in m1.segments {
    if s.id == big_id {
      big_kept = true
    }
  }
  assert_eq(big_kept, true)
  // 行无丢失
  let ids = visible_ids(mem, "l0tier", m1)
  assert_eq(ids.length(), 1500)
  // 合并明细：tier / 输入段数 / 输入输出行数
  assert_eq(outcome.merge_log.length(), 1)
  let info = outcome.merge_log[0]
  assert_eq(info.prefix_fallback, false)
  assert_eq(info.tier, -5)
  assert_eq(info.segs_in, 3)
  assert_eq(info.rows_in, 300)
  assert_eq(info.rows_out, 300)
  assert_eq(outcome.gc_kept_in_grace, outcome.superseded.length())
}

///|
/// merge_ids 指定子集合并：可只合并不相邻的段；跳过段原样保留，墓碑只
/// 保留 tail 段范围内的（被合并段范围的已物理化）。
async test "compact_optimistic merge_ids merges a non-contiguous subset" {
  let mem = @store.MemStore::new()
  let cfg = {
    ..BuildConfig::default("l0sub"),
    segment_rows: 2000,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
  }
  let _ = ingest_l0_slab(mem, cfg, mkdocs(50, 8, 1UL, 71U), []) // A: id 1..50
  let _ = ingest_l0_slab(mem, cfg, mkdocs(50, 8, 1000UL, 72U), []) // B: id 1000..1049
  let _ = ingest_l0_slab(mem, cfg, mkdocs(50, 8, 2000UL, 73U), []) // C: id 2000..2049
  // 删除 A 范围的 7UL 与 B 范围的 1007UL（纯删除批，不新增段）
  let _ = ingest_l0_slab(mem, cfg, [], [7UL, 1007UL])
  let m0 = head_manifest_of(mem, "l0sub")
  assert_eq(m0.segments.length(), 3)
  let a_id = m0.segments[0].id
  let b_id = m0.segments[1].id
  let c_id = m0.segments[2].id
  // 只合并 A 与 C（不相邻），B 原样保留
  let merged = compact_optimistic(mem, cfg, merge_ids=[a_id, c_id])
  assert_eq(merged is Some(_), true)
  let m1 = head_manifest_of(mem, "l0sub")
  assert_eq(m1.segments.length(), 2)
  let mut b_kept = false
  let mut merged_rows = -1
  let mut merged_id = ""
  for s in m1.segments {
    if s.id == b_id {
      b_kept = true
    } else {
      merged_rows = s.row_count
      merged_id = s.id
    }
  }
  assert_eq(b_kept, true)
  assert_eq(merged_id == a_id, false)
  assert_eq(merged_id == c_id, false)
  // 合并段 = A 50 - 1 墓碑 + C 50
  assert_eq(merged_rows, 99)
  // 墓碑：A 范围的 7UL 已物理化，B 范围的 1007UL 保留
  assert_eq(m1.deleted.length(), 1)
  assert_eq(m1.deleted[0], 1007UL)
  let ids = visible_ids(mem, "l0sub", m1)
  assert_eq(ids.length(), 148)
}

///|
/// 安全阀：段数真超过 tiers × fanout × 2 时退回一次前缀合并并记录在
/// merge_log（prefix_fallback），随后仍由 tiered 循环收尾。
async test "maybe_compact_segments safety valve falls back once to prefix merge" {
  let mem = @store.MemStore::new()
  let cfg = {
    ..BuildConfig::default("l0valve"),
    segment_rows: 2000,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
  }
  // 10 个小段（每批 3 行，全落 tier -10）：10 > 1 × 3 × 2 ⇒ 安全阀触发
  for b in 0..<10 {
    let _ = ingest_l0_slab(
      mem,
      cfg,
      mkdocs(3, 8, (b * 100 + 1).to_uint64(), (90 + b).reinterpret_as_uint()),
      [],
    )
  }
  let outcome = maybe_compact_segments(mem, cfg)
  let mut fallbacks = 0
  for info in outcome.merge_log {
    if info.prefix_fallback {
      fallbacks += 1
    }
  }
  assert_eq(fallbacks, 1)
  assert_eq(outcome.merge_log.length(), outcome.merges)
  assert_eq(outcome.merges > 0, true)
  let m1 = head_manifest_of(mem, "l0valve")
  assert_eq(m1.segments.length() <= 3, true)
  let ids = visible_ids(mem, "l0valve", m1)
  assert_eq(ids.length(), 30)
}

///|
/// 合并输出按 doc id 升序（`sort_docs_by_id`）：来源段在 manifest 里逆 id
/// 序时，合并行排序后 id 连续 ⇒ 段标 `dense_u64`（读侧 row_id 走
/// min_id+row、免读 id 列，冷 vec KB/q 不随 N 膨胀的关键）；id 有空洞时
/// 排序后仍不稠密、不标 dense_u64（负向对照，防检查被放宽）。
async test "compact 输出按 id 排序：连续 id 合并段标 dense_u64，空洞不标" {
  let store = WbStore::new()
  let cfg = {
    ..BuildConfig::default("mrgsort"),
    segment_rows: 2000,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
    id_dense: true,
  }
  // 先写高 id 段（1300..1599）再写低 id 段（1000..1299）：manifest 顺序
  // = [高, 低]，按 manifest 顺序直接拼接是乱序的，必须排序才稠密。
  let _ = ingest_l0_slab(store, cfg, mkdocs(300, 8, 1300UL, 41U), [])
  let _ = ingest_l0_slab(store, cfg, mkdocs(300, 8, 1000UL, 42U), [])
  let merged = compact_optimistic(store, cfg, max_prefix_segments=2)
  assert_eq(merged is Some(_), true)
  let m = head_manifest_of(store, "mrgsort")
  assert_eq(m.segments.length(), 1)
  let seg = m.segments[0]
  let index = read_slab_index(store, "mrgsort", seg.id, seg.size_bytes)
  let meta_bs = read_slab_component_by_name(store, "mrgsort", seg.id, index, "meta")
  assert_eq(meta_id_encoding(meta_bs), "dense_u64")
  let ids = seg_ids(store, "mrgsort", seg)
  assert_eq(ids.length(), 600)
  // 排序 + 连续：ids[i] == 1000 + i
  for i in 0..<ids.length() {
    assert_eq(ids[i], 1000UL + i.to_uint64())
  }
  // 负向对照：id 有空洞（1000..1299 + 1600..1899）⇒ 排序后仍不稠密。
  let store2 = WbStore::new()
  let cfg2 = {
    ..BuildConfig::default("mrgsortgap"),
    segment_rows: 2000,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
    id_dense: true,
  }
  let _ = ingest_l0_slab(store2, cfg2, mkdocs(300, 8, 1000UL, 43U), [])
  let _ = ingest_l0_slab(store2, cfg2, mkdocs(300, 8, 1600UL, 44U), [])
  let merged2 = compact_optimistic(store2, cfg2, max_prefix_segments=2)
  assert_eq(merged2 is Some(_), true)
  let m2 = head_manifest_of(store2, "mrgsortgap")
  assert_eq(m2.segments.length(), 1)
  let seg2 = m2.segments[0]
  let index2 = read_slab_index(store2, "mrgsortgap", seg2.id, seg2.size_bytes)
  let meta2 = read_slab_component_by_name(store2, "mrgsortgap", seg2.id, index2, "meta")
  assert_eq(meta_id_encoding(meta2), "")
}

///|
/// 读 seg meta.json 的 id_encoding（无该字段时返回空串）。
fn meta_id_encoding(bs : Bytes) -> String raise @core.SpndError {
  let j = bytes_to_json(bs, "seg meta")
  match j {
    Object(m) =>
      match m.get("id_encoding") {
        Some(String(s)) => s
        _ => ""
      }
    _ => raise @core.Corrupt("seg meta not object")
  }
}

///|
/// 空洞合并段 id 组件 runs_u64：合并两个非相邻 id 段（排序后 2 runs / 600 行）
/// 时 id 组件写 run 表（id_encoding_of = "runs_u64"，20B+2×16B），meta.json
/// 的 id_encoding 仍为空（空洞段不稠密；runs 标记在列头自描述），逐行 id
/// 解码值不变；非连续 id（run ≈ 行数）的段保持逐行 u64（行为不变）。
async test "空洞合并段 id 组件 runs_u64，非连续 id 段保持逐行" {
  let store = WbStore::new()
  let cfg = {
    ..BuildConfig::default("l0runs"),
    segment_rows: 2000,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
    id_dense: true,
  }
  let _ = ingest_l0_slab(store, cfg, mkdocs(300, 8, 1000UL, 61U), [])
  let _ = ingest_l0_slab(store, cfg, mkdocs(300, 8, 1600UL, 62U), [])
  let merged = compact_optimistic(store, cfg, max_prefix_segments=2)
  assert_eq(merged is Some(_), true)
  let m = head_manifest_of(store, "l0runs")
  assert_eq(m.segments.length(), 1)
  let seg = m.segments[0]
  let index = read_slab_index(store, "l0runs", seg.id, seg.size_bytes)
  let meta_bs = read_slab_component_by_name(store, "l0runs", seg.id, index, "meta")
  assert_eq(meta_id_encoding(meta_bs), "")
  let id_bs = read_slab_component_by_name(store, "l0runs", seg.id, index, "id")
  assert_eq(@format.id_encoding_of(id_bs), @format.ID_ENCODING_RUNS)
  assert_eq(id_bs.length() < 600 * 8, true)
  let ids = seg_ids(store, "l0runs", seg)
  assert_eq(ids.length(), 600)
  for i in 0..<300 {
    assert_eq(ids[i], 1000UL + i.to_uint64())
  }
  for i in 300..<600 {
    assert_eq(ids[i], 1600UL + (i - 300).to_uint64())
  }
  // 非连续 id（隔行 id，run ≈ 行数）：id 组件保持逐行 u64
  let store2 = WbStore::new()
  let cfg2 = {
    ..BuildConfig::default("l0runs2"),
    segment_rows: 2000,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
  }
  let docs : Array[@core.Doc] = Array()
  for i in 0..<50 {
    let vec : Array[Float] = Array(capacity=8)
    for _ in 0..<8 {
      vec.push(0.5)
    }
    docs.push({
      id: (i * 2).to_uint64(),
      text: "t\{i}",
      vector: vec,
      category: "c",
      ts: i.to_int64(),
      public: true,
    })
  }
  let _ = ingest_l0_slab(store2, cfg2, docs, [])
  let m2 = head_manifest_of(store2, "l0runs2")
  let seg2 = m2.segments[0]
  let index2 = read_slab_index(store2, "l0runs2", seg2.id, seg2.size_bytes)
  let id_bs2 = read_slab_component_by_name(store2, "l0runs2", seg2.id, index2, "id")
  assert_eq(@format.id_encoding_of(id_bs2), "row_u64")
  let ids2 = seg_ids(store2, "l0runs2", seg2)
  assert_eq(ids2.length(), 50)
  for i in 0..<50 {
    assert_eq(ids2[i], (i * 2).to_uint64())
  }
}

///|
/// Defect A 回归（全链路）：id 取 2^53+1 / 2^63 / u64::MAX 走
/// 「写入 → 删除若干 → 合并 → 读回」：manifest 的 min_id/max_id/deleted 与
/// seg meta 的 min_id 全部精确（u64 主键不许过 JSON Double），被删行不复活、
/// 行不重复。
async test "u64 ids > 2^53 survive write→delete→merge→readback" {
  let mem = @store.MemStore::new()
  let cfg = {
    ..BuildConfig::default("u64edge"),
    segment_rows: 8,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
    id_dense: true,
  }
  let p1 = 9007199254740993UL // 2^53+1（过 JSON Double 即损）
  let p3 = 9223372036854775808UL // 2^63
  let umax = 18446744073709551615UL // u64::MAX
  let _ = ingest_l0_slab(mem, cfg, [
    one_doc(7UL, 8, "small", 34U),
    one_doc(p1, 8, "p53p1", 31U),
    one_doc(p3, 8, "p63", 32U),
    one_doc(umax, 8, "umax", 33U),
  ], [])
  // 删除 2^53+1 与 2^63
  let _ = ingest_l0_slab(mem, cfg, [], [p1, p3])
  let _ = ingest_l0_slab(mem, cfg, [
    one_doc(10UL, 8, "small2", 35U),
    one_doc(9007199254740995UL, 8, "p53p3", 36U),
  ], [])
  // 合并前：墓碑与段边界必须精确（否则 prune/裁剪会永久丢 id）
  let m0 = head_manifest_of(mem, "u64edge")
  assert_eq(m0.deleted.length(), 2)
  assert_eq(m0.deleted[0], p1)
  assert_eq(m0.deleted[1], p3)
  let mut has_umax_bound = false
  for s in m0.segments {
    if s.min_id == 7UL && s.max_id == umax {
      has_umax_bound = true
    }
  }
  assert_eq(has_umax_bound, true)
  // 合并（墓碑物理化）
  let res = compact_optimistic(mem, cfg)
  assert_eq(res is Some(_), true)
  let m = head_manifest_of(mem, "u64edge")
  assert_eq(m.segments.length(), 1)
  assert_eq(m.segments[0].min_id, 7UL)
  assert_eq(m.segments[0].max_id, umax)
  assert_eq(m.deleted.length(), 0) // 已物理化
  // 读回：id 精确、被删行不复活、无重复（length 精确即无重复）
  let ids = visible_ids(mem, "u64edge", m)
  assert_eq(ids.length(), 4)
  assert_eq(has_id(ids, 7UL), true)
  assert_eq(has_id(ids, 10UL), true)
  assert_eq(has_id(ids, 9007199254740995UL), true)
  assert_eq(has_id(ids, umax), true)
  assert_eq(has_id(ids, p1), false)
  assert_eq(has_id(ids, p3), false)
  // 合并段 meta.json 的 min_id/max_id 是精确字符串（dense 段 row→id 前提）
  let meta = seg_meta_map(mem, "u64edge/_segments/\{m.segments[0].id}")
  let min_s = match meta.get("min_id") {
    Some(String(s)) => s
    _ => fail("min_id must be a precise string")
  }
  assert_eq(min_s, "7")
  let max_s = match meta.get("max_id") {
    Some(String(s)) => s
    _ => fail("max_id must be a precise string")
  }
  assert_eq(max_s, "18446744073709551615")
}
