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
