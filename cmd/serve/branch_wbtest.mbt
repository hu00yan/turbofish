// cmd/serve/branch_wbtest.mbt: Zero-Copy Instant Branching & Snapshots Test Suite

///|
fn make_test_docs(start_id : UInt64, count : Int, tag : String) -> Array[@core.Doc] {
  let docs : Array[@core.Doc] = Array(capacity=count)
  for i in 0..<count {
    let id = start_id + i.to_uint64()
    docs.push({
      id,
      text: "docid\{id} token\{tag}",
      vector: [0.1, 0.2, 0.3, 0.4],
      category: tag,
      ts: 1000L + i.to_int64(),
      public: true,
    })
  }
  docs
}

///|
test "cmd/serve: zero-copy instant branching" {
  reset_coordinator_for_test()
  reset_branch_origins_for_test()
  let sim = @simstore.SimStore::new(@simstore.SimConfig::aws_default(100U))
  let store : AnyStore = Sim(sim)
  let src_ns = "test_zc_src"
  let branch_ns = "test_zc_branch"
  let dim = 4

  let cfg = @build.BuildConfig::single_copy(src_ns)
  let initial_docs = make_test_docs(1UL, 10, "initial")
  @build.ingest(store, { ..cfg, vector_dim: dim }, initial_docs)

  // 源空间段文件列表
  let src_segs = store.list("\{src_ns}/_segments/")
  assert_eq(src_segs.length() > 0, true)

  // 执行 zero-copy branching
  let head = create_branch(store, src_ns, branch_ns, true)
  assert_eq(head != "", true)

  // 关键验证 1：Zero-Copy，底层无任何段数据文件复制 ($0 data duplication)
  let branch_raw_segs = raw_list(store, "\{branch_ns}/_segments/")
  assert_eq(branch_raw_segs.length(), 0)

  // 关键验证 2：通过 AnyStore 继承机制可无缝读取数据
  let n_branch = @query.open(store, branch_ns)
  assert_eq(@query.count_docs(n_branch, None), 10)

  // BM25 文本检索成功
  let bm25_res = @query.bm25_search(n_branch, "tokeninitial", 5, None)
  assert_eq(bm25_res.length() > 0, true)

  // 向量检索成功
  let qvec : Array[Float] = [0.1, 0.2, 0.3, 0.4]
  let vec_res = @query.vec_search(n_branch, qvec, 5, 2, None)
  assert_eq(vec_res.length() > 0, true)
}

///|
test "cmd/serve: write isolation between branches and source" {
  reset_coordinator_for_test()
  reset_branch_origins_for_test()
  let sim = @simstore.SimStore::new(@simstore.SimConfig::aws_default(200U))
  let store : AnyStore = Sim(sim)
  let src_ns = "test_iso_src"
  let branch_a = "test_iso_a"
  let branch_b = "test_iso_b"
  let dim = 4

  let cfg_src = @build.BuildConfig::single_copy(src_ns)
  @build.ingest(store, { ..cfg_src, vector_dim: dim }, make_test_docs(1UL, 5, "base"))

  // 分支 A 与 B
  let _ = create_branch(store, src_ns, branch_a, true)
  let _ = create_branch(store, src_ns, branch_b, true)

  // 向 branch_A 写入 2 条 (id 101, 102)
  let cfg_a = @build.BuildConfig::single_copy(branch_a)
  @build.ingest(store, { ..cfg_a, vector_dim: dim }, make_test_docs(101UL, 2, "brancha"))

  // 向 branch_B 写入 2 条 (id 201, 202)
  let cfg_b = @build.BuildConfig::single_copy(branch_b)
  @build.ingest(store, { ..cfg_b, vector_dim: dim }, make_test_docs(201UL, 2, "branchb"))

  // 向 src_ns 写入 1 条 (id 301)
  @build.ingest(store, { ..cfg_src, vector_dim: dim }, make_test_docs(301UL, 1, "srcextra"))

  // 验证源空间：只有 base 5 条 + srcextra 1 条 = 6 条
  let n_src = @query.open(store, src_ns)
  assert_eq(@query.count_docs(n_src, None), 6)
  assert_eq(@query.bm25_search(n_src, "tokenbrancha", 5, None).length(), 0)
  assert_eq(@query.bm25_search(n_src, "tokenbranchb", 5, None).length(), 0)
  assert_eq(@query.bm25_search(n_src, "tokensrcextra", 5, None).length(), 1)

  // 验证 branch_A：有 base 5 条 + brancha 2 条 = 7 条；不包含 branch_B 或 srcextra 的写入
  let n_a = @query.open(store, branch_a)
  assert_eq(@query.count_docs(n_a, None), 7)
  assert_eq(@query.bm25_search(n_a, "tokenbrancha", 5, None).length(), 2)
  assert_eq(@query.bm25_search(n_a, "tokenbranchb", 5, None).length(), 0)
  assert_eq(@query.bm25_search(n_a, "tokensrcextra", 5, None).length(), 0)

  // 验证 branch_B：有 base 5 条 + branchb 2 条 = 7 条；不包含 branch_A 或 srcextra 的写入
  let n_b = @query.open(store, branch_b)
  assert_eq(@query.count_docs(n_b, None), 7)
  assert_eq(@query.bm25_search(n_b, "tokenbranchb", 5, None).length(), 2)
  assert_eq(@query.bm25_search(n_b, "tokenbrancha", 5, None).length(), 0)
  assert_eq(@query.bm25_search(n_b, "tokensrcextra", 5, None).length(), 0)
}

///|
test "cmd/serve: delete isolation on branch" {
  reset_coordinator_for_test()
  reset_branch_origins_for_test()
  let sim = @simstore.SimStore::new(@simstore.SimConfig::aws_default(300U))
  let store : AnyStore = Sim(sim)
  let src_ns = "test_del_src"
  let branch_ns = "test_del_branch"
  let dim = 4

  let cfg = @build.BuildConfig::single_copy(src_ns)
  @build.ingest(store, { ..cfg, vector_dim: dim }, make_test_docs(1UL, 4, "deltest"))

  let _ = create_branch(store, src_ns, branch_ns, true)

  // 在分支上软删除 doc 1 和 doc 2
  let cfg_branch = @build.BuildConfig::single_copy(branch_ns)
  @build.delete_docs(store, { ..cfg_branch, vector_dim: dim }, [1UL, 2UL])

  // 分支上只剩 2 条
  let n_branch = @query.open(store, branch_ns)
  assert_eq(@query.count_docs(n_branch, None), 2)

  // 源空间完全不受影响，仍有 4 条
  let n_src = @query.open(store, src_ns)
  assert_eq(@query.count_docs(n_src, None), 4)
}

///|
test "cmd/serve: compaction on branch without affecting source" {
  reset_coordinator_for_test()
  reset_branch_origins_for_test()
  let sim = @simstore.SimStore::new(@simstore.SimConfig::aws_default(400U))
  let store : AnyStore = Sim(sim)
  let src_ns = "test_cpt_src"
  let branch_ns = "test_cpt_branch"
  let dim = 4

  let cfg_src = @build.BuildConfig::single_copy(src_ns)
  @build.ingest(store, { ..cfg_src, vector_dim: dim }, make_test_docs(1UL, 3, "cptone"))

  let _ = create_branch(store, src_ns, branch_ns, true)

  // 向 branch 追加更多段
  let cfg_branch = @build.BuildConfig::single_copy(branch_ns)
  @build.ingest(store, { ..cfg_branch, vector_dim: dim }, make_test_docs(10UL, 3, "cpttwo"))

  let n_branch_before = @query.open(store, branch_ns)
  assert_eq(n_branch_before.manifest.segments.length(), 2)

  // 在 branch_ns 上执行段合并 compaction
  @build.compact(store, { ..cfg_branch, vector_dim: dim }, branch_ns)

  // 验证 branch_ns 合并为一个段
  let n_branch_after = @query.open(store, branch_ns)
  assert_eq(n_branch_after.manifest.segments.length(), 1)
  assert_eq(@query.count_docs(n_branch_after, None), 6)

  // 验证源空间 segments 数量与数据完全不变
  let n_src = @query.open(store, src_ns)
  assert_eq(n_src.manifest.segments.length(), 1)
  assert_eq(@query.count_docs(n_src, None), 3)
}

///|
test "cmd/serve: snapshot creation and instant restore" {
  reset_coordinator_for_test()
  reset_branch_origins_for_test()
  let sim = @simstore.SimStore::new(@simstore.SimConfig::aws_default(500U))
  let store : AnyStore = Sim(sim)
  let ns = "test_snap_restore"
  let dim = 4

  let cfg = @build.BuildConfig::single_copy(ns)
  @build.ingest(store, { ..cfg, vector_dim: dim }, make_test_docs(1UL, 3, "verone"))

  // 1. 创建不可变快照 v1
  let head_v1 = create_snapshot(store, ns, "snapshot-v1")
  assert_eq(head_v1 != "", true)

  // 验证快照列表
  let snaps = list_snapshots(store, ns)
  assert_eq(snaps.length(), 1)
  assert_eq(snaps[0], "snapshot-v1")

  // 2. 模拟新写入数据，进入 v2 状态
  @build.ingest(store, { ..cfg, vector_dim: dim }, make_test_docs(10UL, 5, "vertwo"))

  let n_v2 = @query.open(store, ns)
  assert_eq(@query.count_docs(n_v2, None), 8)
  assert_eq(@query.bm25_search(n_v2, "tokenvertwo", 5, None).length(), 5)

  // 3. 瞬间恢复至 snapshot-v1
  let restored_head = restore_snapshot(store, ns, "snapshot-v1")
  assert_eq(restored_head, head_v1)

  // 4. 验证数据已瞬间回滚至 v1
  let n_restored = @query.open(store, ns)
  assert_eq(@query.count_docs(n_restored, None), 3)
  assert_eq(@query.bm25_search(n_restored, "tokenvertwo", 5, None).length(), 0)
  assert_eq(@query.bm25_search(n_restored, "tokenverone", 5, None).length(), 3)
}

///|
test "cmd/serve: multi-tier branch inheritance (A -> B -> C)" {
  reset_coordinator_for_test()
  reset_branch_origins_for_test()
  let sim = @simstore.SimStore::new(@simstore.SimConfig::aws_default(600U))
  let store : AnyStore = Sim(sim)
  let dim = 4

  // Tier 1: Main
  let main_ns = "tier_main"
  let cfg_main = @build.BuildConfig::single_copy(main_ns)
  @build.ingest(store, { ..cfg_main, vector_dim: dim }, make_test_docs(1UL, 2, "root"))

  // Tier 2: Dev (branched from Main)
  let dev_ns = "tier_dev"
  let _ = create_branch(store, main_ns, dev_ns, true)
  let cfg_dev = @build.BuildConfig::single_copy(dev_ns)
  @build.ingest(store, { ..cfg_dev, vector_dim: dim }, make_test_docs(10UL, 2, "devfeat"))

  // Tier 3: Feature (branched from Dev)
  let feat_ns = "tier_feat"
  let _ = create_branch(store, dev_ns, feat_ns, true)
  let cfg_feat = @build.BuildConfig::single_copy(feat_ns)
  @build.ingest(store, { ..cfg_feat, vector_dim: dim }, make_test_docs(20UL, 2, "featonly"))

  // 验证 Feature 可以层层穿透访问全部数据 (root 2 + dev 2 + feat 2 = 6)
  let n_feat = @query.open(store, feat_ns)
  assert_eq(@query.count_docs(n_feat, None), 6)
  assert_eq(@query.bm25_search(n_feat, "tokenroot", 5, None).length(), 2)
  assert_eq(@query.bm25_search(n_feat, "tokendevfeat", 5, None).length(), 2)
  assert_eq(@query.bm25_search(n_feat, "tokenfeatonly", 5, None).length(), 2)

  // 验证 Dev 只有 root 2 + dev 2 = 4
  let n_dev = @query.open(store, dev_ns)
  assert_eq(@query.count_docs(n_dev, None), 4)
  assert_eq(@query.bm25_search(n_dev, "tokenfeatonly", 5, None).length(), 0)

  // 验证 Main 只有 root 2
  let n_main = @query.open(store, main_ns)
  assert_eq(@query.count_docs(n_main, None), 2)
}

///|
test "cmd/serve: branch error cases" {
  reset_coordinator_for_test()
  reset_branch_origins_for_test()
  let sim = @simstore.SimStore::new(@simstore.SimConfig::aws_default(700U))
  let store : AnyStore = Sim(sim)

  // 源不存在
  let mut src_not_found = false
  try {
    let _ = create_branch(store, "non_existent_ns", "b1", true)
    ()
  } catch {
    @core.NotFound(_) => src_not_found = true
    _ => ()
  }
  assert_eq(src_not_found, true)

  // 建立真实命名空间
  let cfg = @build.BuildConfig::single_copy("real_src")
  @build.ingest(store, { ..cfg, vector_dim: 4 }, make_test_docs(1UL, 2, "ok"))

  // 空 branch_name
  let mut empty_name = false
  try {
    let _ = create_branch(store, "real_src", "", true)
    ()
  } catch {
    @core.Corrupt(_) => empty_name = true
    _ => ()
  }
  assert_eq(empty_name, true)

  // 同名
  let mut same_name = false
  try {
    let _ = create_branch(store, "real_src", "real_src", true)
    ()
  } catch {
    @core.Corrupt(_) => same_name = true
    _ => ()
  }
  assert_eq(same_name, true)

  // 正常创建分支
  let _ = create_branch(store, "real_src", "branch_dup", true)

  // 重复创建冲突
  let mut dup_branch = false
  try {
    let _ = create_branch(store, "real_src", "branch_dup", true)
    ()
  } catch {
    @core.CommitConflict(_) => dup_branch = true
    _ => ()
  }
  assert_eq(dup_branch, true)
}

///|
test "cmd/serve: snapshot error cases" {
  reset_coordinator_for_test()
  reset_branch_origins_for_test()
  let sim = @simstore.SimStore::new(@simstore.SimConfig::aws_default(800U))
  let store : AnyStore = Sim(sim)

  // 对不存在的命名空间打快照
  let mut snap_not_found = false
  try {
    let _ = create_snapshot(store, "ghost_ns", "snap1")
    ()
  } catch {
    @core.NotFound(_) => snap_not_found = true
    _ => ()
  }
  assert_eq(snap_not_found, true)

  // 建立真实命名空间
  let cfg = @build.BuildConfig::single_copy("snap_real_src")
  @build.ingest(store, { ..cfg, vector_dim: 4 }, make_test_docs(1UL, 2, "ok"))

  // 空 snapshot_name
  let mut empty_snap_name = false
  try {
    let _ = create_snapshot(store, "snap_real_src", "")
    ()
  } catch {
    @core.Corrupt(_) => empty_snap_name = true
    _ => ()
  }
  assert_eq(empty_snap_name, true)

  // 恢复不存在的快照
  let mut restore_not_found = false
  try {
    let _ = restore_snapshot(store, "snap_real_src", "non_existent_snap")
    ()
  } catch {
    @core.NotFound(_) => restore_not_found = true
    _ => ()
  }
  assert_eq(restore_not_found, true)
}

///|
test "cmd/serve: zero-copy speed and object count guarantee" {
  reset_coordinator_for_test()
  reset_branch_origins_for_test()
  let sim = @simstore.SimStore::new(@simstore.SimConfig::aws_default(900U))
  let store : AnyStore = Sim(sim)
  let src_ns = "bulk_src"
  let branch_ns = "bulk_branch"
  let dim = 4

  let cfg = @build.BuildConfig::single_copy(src_ns)
  let docs = make_test_docs(1UL, 50, "bulk")
  @build.ingest(store, { ..cfg, vector_dim: dim }, docs)

  let src_objs = store.list("\{src_ns}/")
  assert_eq(src_objs.length() > 0, true)

  // 克隆分支
  let _ = create_branch(store, src_ns, branch_ns, true)

  // 验证 branch 的物理段文件数量为 0
  let branch_raw_segs = raw_list(store, "\{branch_ns}/_segments/")
  assert_eq(branch_raw_segs.length(), 0)

  // 验证 branch 的全部 50 条记录立即可读
  let n = @query.open(store, branch_ns)
  assert_eq(@query.count_docs(n, None), 50)
}

///|
test "cmd/serve: multiple snapshots and branching from restored state" {
  reset_coordinator_for_test()
  reset_branch_origins_for_test()
  let sim = @simstore.SimStore::new(@simstore.SimConfig::aws_default(1000U))
  let store : AnyStore = Sim(sim)
  let ns = "multi_snap_ns"
  let branch_from_restored = "branch_from_restored_ns"
  let dim = 4

  let cfg = @build.BuildConfig::single_copy(ns)
  // Stage 1: 5 docs -> snap1
  @build.ingest(store, { ..cfg, vector_dim: dim }, make_test_docs(1UL, 5, "stage1"))
  let snap1 = create_snapshot(store, ns, "snap1")

  // Stage 2: +5 docs -> snap2
  @build.ingest(store, { ..cfg, vector_dim: dim }, make_test_docs(10UL, 5, "stage2"))
  let snap2 = create_snapshot(store, ns, "snap2")

  let snaps = list_snapshots(store, ns)
  assert_eq(snaps.length(), 2)
  assert_eq(snaps[0], "snap1")
  assert_eq(snaps[1], "snap2")

  // 当前应该有 10 docs
  let n_now = @query.open(store, ns)
  assert_eq(@query.count_docs(n_now, None), 10)

  // 恢复回 snap1 (5 docs)
  let _ = restore_snapshot(store, ns, "snap1")
  let n_after_restore = @query.open(store, ns)
  assert_eq(@query.count_docs(n_after_restore, None), 5)

  // 基于恢复后的状态建立新分支
  let _ = create_branch(store, ns, branch_from_restored, true)
  let n_branch = @query.open(store, branch_from_restored)
  assert_eq(@query.count_docs(n_branch, None), 5)
  assert_eq(n_branch.manifest.id, snap1)
}
