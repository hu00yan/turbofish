// =========================================================================
// CHAOS MONKEY (混沌猴子) 极端对抗性测试套件
// =========================================================================
// 目标：专门构造边界、异常、并发竞争、极值、乱序与软删除生命周期冲突，
// 暴露潜在死锁、状态死循环、内存泄漏、文档复活（Resurrection Anomaly）与数据损坏。

fn make_chaos_docs(ids : Array[UInt64], dim : Int, text_prefix : String) -> Array[@core.Doc] {
  let docs : Array[@core.Doc] = Array::new(capacity=ids.length())
  for id in ids {
    let v : Array[Float] = Array::new(capacity=dim)
    for d in 0..<dim {
      v.push(Float::from_int(((id.to_int() * 17 + d * 3) % 200)) * 0.005)
    }
    docs.push({
      id,
      text: "\{text_prefix}_doc_\{id}",
      vector: v,
      category: "chaos",
      ts: 1700000000L + id.reinterpret_as_int64(),
      public: true,
    })
  }
  docs
}

// -------------------------------------------------------------------------
// 混沌场景 1: 极值 Doc ID (0UL, 极稀疏, 接近 UInt64 最大值)
// -------------------------------------------------------------------------
test "Chaos 1: Extreme Doc IDs (0UL, sparse clusters, RoaringBitmap boundary)" {
  let store = @store.MemStore::new()
  let ns = "chaos_extreme_ids"
  let dim = 4
  let engine = MergeTreeEngine::new(store, ns, dim, false, None)

  // 包含 0UL，普通 ID，以及跨越高 48 位容器边界的稀疏巨型 ID
  let extreme_ids : Array[UInt64] = [
    0UL,
    1UL,
    65535UL,        // low container max
    65536UL,        // high container 1, low 0
    1000000UL,
    0x100000000UL,  // 32-bit boundary
    0x7FFFFFFFFFFFFFFFUL, // i64 max as u64
  ]

  let docs = make_chaos_docs(extreme_ids, dim, "EXTREME")
  let _ = engine.append_base_part(docs)
  engine.publish_manifest()

  // 1. 读取活文档，验证所有极值 ID 准确无误还原
  let live = engine.read_live_docs()
  assert_eq(live.length(), extreme_ids.length())
  assert_eq(live[0].id, 0UL)
  assert_eq(live[live.length() - 1].id, 0x7FFFFFFFFFFFFFFFUL)

  // 2. 软删除极值中的部分 ID (0UL, 65536UL, 0x7FFFFFFFFFFFFFFFUL)
  engine.soft_delete([0UL, 65536UL, 0x7FFFFFFFFFFFFFFFUL])
  engine.publish_manifest()

  let live_after_del = engine.read_live_docs()
  assert_eq(live_after_del.length(), 4)
  assert_eq(live_after_del[0].id, 1UL)
  assert_eq(live_after_del[1].id, 65535UL)
  assert_eq(live_after_del[2].id, 1000000UL)
  assert_eq(live_after_del[3].id, 0x100000000UL)
}

// -------------------------------------------------------------------------
// 混沌场景 2: WriteBackBuffer 初始批次 Linger 停滞探测
// -------------------------------------------------------------------------
test "Chaos 2: WriteBackBuffer linger trigger on initial batch" {
  let store = @store.MemStore::new()
  let ns = "chaos_wb_linger"
  let dim = 4
  let engine = MergeTreeEngine::new(store, ns, dim, false, None)

  let wb = WriteBackBuffer::new(
    engine,
    flush_rows_threshold=100, // 阈值很高，5 行绝不满足条数条件
    flush_bytes_threshold=1000000,
    linger_ms=1000L,          // 1秒超时
  )

  let docs = make_chaos_docs([1UL, 2UL, 3UL, 4UL, 5UL], dim, "LINGER_TEST")
  
  // 在 t = 100ms 写入首批 5 行
  let r1 = wb.mutate(docs, [], 100L)
  assert_eq(r1 is None, true) // 暂存缓冲
  assert_eq(wb.pending_count(), 5)

  // 在 t = 1500ms（过去 1400ms > linger_ms=1000ms）发生无数据心跳/或下一笔小突变
  let r2 = wb.mutate([], [], 1500L)
  
  // 核心断言：超过 linger 窗口后必须自动触发刷盘！若 last_flush_ms 未妥善初始化则会死锁停滞！
  let did_flush = r2 is Some(_) || wb.pending_count() == 0
  assert_eq(did_flush, true)
}

// -------------------------------------------------------------------------
// 混沌场景 3: WriteBackBuffer 纯删除吞吐与内存膨胀探测
// -------------------------------------------------------------------------
test "Chaos 3: Pure deletion bursts should not leak or ignore thresholds" {
  let store = @store.MemStore::new()
  let ns = "chaos_pure_deletes"
  let dim = 4
  let engine = MergeTreeEngine::new(store, ns, dim, false, None)

  let wb = WriteBackBuffer::new(
    engine,
    flush_rows_threshold=50,
    linger_ms=1000L,
  )

  // 连续灌入 150 个纯删除墓碑，不传入任何新文档
  let tombstones : Array[UInt64] = Array::new(capacity=150)
  for i in 1..=150 {
    tombstones.push(i.to_uint64())
  }

  let r = wb.mutate([], tombstones, 500L)

  // 核心断言：纯删除也是突变操作，积累达到阈值后绝不可无限堆积在内存！
  // 若未刷盘，pending_tombstones 会持续泄露
  if r is None {
    // 若未能按 rows 触发，至少在手动 flush 时必须正确持久化到 manifest
    let flushed = wb.flush(600L)
    assert_eq(flushed is None, true) // 只有墓碑无新 part，但 manifest 已换代
  }
  assert_eq(engine.manifest.tombstones.length(), 150)
}

// -------------------------------------------------------------------------
// 混沌场景 4: L0 Delta Part 的真正删除（避免文档复活异常）
// -------------------------------------------------------------------------
test "Chaos 4: True deletion in L0 Delta Part should not resurrect after compaction" {
  let store = @store.MemStore::new()
  let ns = "chaos_l0_resurrect"
  let dim = 4
  let engine = MergeTreeEngine::new(store, ns, dim, false, None)

  // 1. 基线 Part (id: 1..5)
  let base_docs = make_chaos_docs([1UL, 2UL, 3UL, 4UL, 5UL], dim, "BASE")
  let _ = engine.append_base_part(base_docs)
  engine.publish_manifest()

  // 2. L0 Delta Part 追加新文档 (id: 100UL, 101UL)
  let l0_docs = make_chaos_docs([100UL, 101UL], dim, "L0")
  let _ = engine.append_l0_delta_part(l0_docs)
  engine.publish_manifest()

  assert_eq(engine.read_live_docs().length(), 7)

  // 3. 混沌攻击：软删除 L0 中的 100UL！
  engine.soft_delete([100UL])
  engine.publish_manifest()

  // 核心断言 A：read_live_docs 必须立即过滤掉 100UL！不可因为 100UL 在 L0 就豁免墓碑！
  let live_mid = engine.read_live_docs()
  let mut has_100_in_live = false
  for d in live_mid {
    if d.id == 100UL {
      has_100_in_live = true
    }
  }
  assert_eq(has_100_in_live, false)

  // 4. 执行后台 Compactor 物理化合并
  let cfg : CompactionTriggerConfig = {
    l0_threshold: 1,
    tombstone_ratio_threshold: 0.10,
    idle_fallback_ms: 0L,
    max_merge_parts: 16,
  }
  let compactor = Compactor::new(
    engine,
    TieredMergePolicy::new(cfg),
    cfg,
  )
  compactor.notify_mutation(1000L)
  let comp_res = compactor.tick(1001L)
  assert_eq(comp_res is Some(_), true)

  // 核心断言 B：Compaction 物理化后，100UL 绝不可死而复活（Resurrection Anomaly）！
  let live_post_compact = engine.read_live_docs()
  let mut has_100_post = false
  for d in live_post_compact {
    if d.id == 100UL {
      has_100_post = true
    }
  }
  assert_eq(has_100_post, false)
  assert_eq(live_post_compact.length(), 6) // 5 base + 1 l0 (101UL)
}

// -------------------------------------------------------------------------
// 混沌场景 5: 全行被删除时的 Compactor 物理化（清空与空 Part 处理）
// -------------------------------------------------------------------------
test "Chaos 5: Total deletion of a part during compaction" {
  let store = @store.MemStore::new()
  let ns = "chaos_total_del"
  let dim = 4
  let engine = MergeTreeEngine::new(store, ns, dim, false, None)

  let base_docs = make_chaos_docs([10UL, 20UL], dim, "DEL_ALL")
  let _ = engine.append_base_part(base_docs)
  engine.publish_manifest()

  // 将全部两行删除
  engine.soft_delete([10UL, 20UL])
  engine.publish_manifest()

  assert_eq(engine.read_live_docs().length(), 0)

  // 触发合并
  let cfg : CompactionTriggerConfig = {
    l0_threshold: 1,
    tombstone_ratio_threshold: 0.10,
    idle_fallback_ms: 0L,
    max_merge_parts: 16,
  }
  let compactor = Compactor::new(
    engine,
    TieredMergePolicy::new(cfg),
    cfg,
  )
  compactor.notify_mutation(100L)
  let comp_res = compactor.tick(101L)

  // 核心断言：全删情况下合并器不应 panic，活文档依然为 0
  assert_eq(comp_res is Some(_), true)
  assert_eq(engine.read_live_docs().length(), 0)
}

// -------------------------------------------------------------------------
// 混沌场景 6: 多云 CAS 并发竞争冲突与胜负仲裁
// -------------------------------------------------------------------------
test "Chaos 6: Native CAS multi-worker thundering herd race arbitration" {
  let store = @store.MemStore::new()
  let ns = "chaos_cas_race"

  let coord1 = NativeCasCoordinator::new(store)
  let coord2 = NativeCasCoordinator::new(store)

  // 初始提交 v1
  let ok1 = HeadCoordinator::commit_head(coord1, ns, None, "manifest_v1.json")
  assert_eq(ok1, true)

  // Worker 1 与 Worker 2 同时读到期望版本 v1
  let (val1, ver1) = match HeadCoordinator::read_head(coord1, ns) {
    Some(pair) => pair
    None => fail("should read head")
  }
  let (val2, ver2) = match HeadCoordinator::read_head(coord2, ns) {
    Some(pair) => pair
    None => fail("should read head")
  }
  assert_eq(val1, "manifest_v1.json")
  assert_eq(val2, "manifest_v1.json")
  assert_eq(ver1, ver2)

  // Worker 1 抢先提交 v2 成功
  let win = HeadCoordinator::commit_head(coord1, ns, Some(ver1), "manifest_v2.json")
  assert_eq(win, true)

  // Worker 2 滞后提交（携带过期的 ver2），必须被 CAS 坚决拒绝（返回 false，零静默覆盖！）
  let lose = HeadCoordinator::commit_head(coord2, ns, Some(ver2), "manifest_v2_conflicted.json")
  assert_eq(lose, false)

  // 校验当前持久化指针依然是胜利者 Worker 1 的值
  let (final_val, _) = match HeadCoordinator::read_head(coord1, ns) {
    Some(pair) => pair
    None => fail("should read head")
  }
  assert_eq(final_val, "manifest_v2.json")
}
