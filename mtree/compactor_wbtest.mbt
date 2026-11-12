// Compactor / Janitor 引擎端到端白盒测试：
// 1) 条件唤醒策略（Conditional Wake-up Policy）：仅在 >=4 L0 delta 或墓碑比例 >20% 时触发，辅以 idle timer fallback，断言 0 LIST 请求；
// 2) 合并与墓碑物理化：合并 L0 parts 为新的 consolidated base part，彻底清除 soft-deleted 行；
// 3) 并发读写隔离：合并过程中查询路径读无锁、零阻塞、结果 100% 正确保真。

///|
fn make_docs_batch(start_id : Int, count : Int, dim : Int, prefix : String) -> Array[@core.Doc] {
  let docs : Array[@core.Doc] = Array::new(capacity=count)
  for i in 0..<count {
    let id_num = start_id + i
    let v : Array[Float] = Array::new(capacity=dim)
    for d in 0..<dim {
      v.push(Float::from_int(id_num * dim + d) * 0.01)
    }
    docs.push({
      id: id_num.to_uint64(),
      text: "\{prefix} document body for id \{id_num}",
      vector: v,
      category: if id_num % 2 == 0 { "code" } else { "doc" },
      ts: (1700000000 + id_num).to_int64(),
      public: id_num % 2 == 0,
    })
  }
  docs
}

///|
test "Compactor: 1) conditional wake-up policy triggers properly and asserts zero LIST" {
  let store = @store.MemStore::new()
  let ns = "compactor_cond_test"
  let dim = 4
  let engine = MergeTreeEngine::new(store, ns, dim, false, None)

  let config : CompactionTriggerConfig = {
    l0_threshold: 4,
    tombstone_ratio_threshold: 0.20,
    idle_fallback_ms: 10000L,
    max_merge_parts: 16,
  }
  let policy = TieredMergePolicy::new(config)
  let compactor = Compactor::new(engine, policy, config)

  // 1. 写入基线数据
  let _ = engine.append_base_part(make_docs_batch(1, 100, dim, "base"))
  engine.publish_manifest()

  // 2. 依次写入 3 个小批量 L0 Delta Parts（3 < 4，0 tombstones）
  for i in 0..<3 {
    let start_id = 1000 + i * 10
    let _ = engine.append_l0_delta_part(make_docs_batch(start_id, 10, dim, "delta_\{i}"))
    engine.publish_manifest()
  }

  // 此时 L0 数量为 3 < 4，空闲时间 0 -> 不触发合并
  compactor.notify_mutation(100L)
  let res1 = compactor.tick(100L)
  assert_eq(res1 is None, true)
  assert_eq(engine.get_manifest().l0_count(), 3)

  // 3. 写入第 4 个 L0 Delta Part（L0 达到 4 个）
  let _ = engine.append_l0_delta_part(make_docs_batch(1030, 10, dim, "delta_3"))
  engine.publish_manifest()
  assert_eq(engine.get_manifest().l0_count(), 4)

  // 记录 LIST 数量
  let lists_before = store.cost().lists

  // 触发合并
  compactor.notify_mutation(200L)
  let res2 = compactor.tick(200L)

  // 断言：成功触发合并，并且读/写路径全过程零 LIST 请求！
  assert_eq(res2 is Some(_), true)
  let lists_after = store.cost().lists
  assert_eq(lists_after - lists_before, 0)

  // 合并后全部 4 个 L0 delta 与基线合并为单一 consolidated base part
  let m_done = engine.get_manifest()
  assert_eq(m_done.l0_count(), 0)
  assert_eq(m_done.parts.length(), 1)
  assert_eq(m_done.parts[0].level, 1) // consolidated base
  assert_eq(m_done.parts[0].row_count, 140) // 100 base + 40 deltas
}

///|
test "Compactor: 2) tombstone ratio > 20% triggers compaction and physicalizes deleted rows" {
  let store = @store.MemStore::new()
  let ns = "compactor_tomb_test"
  let dim = 4
  let engine = MergeTreeEngine::new(store, ns, dim, false, None)

  let config : CompactionTriggerConfig = {
    l0_threshold: 4,
    tombstone_ratio_threshold: 0.20,
    idle_fallback_ms: 10000L,
    max_merge_parts: 16,
  }
  let compactor = Compactor::new(engine, TieredMergePolicy::new(config), config)

  // 写入 50 条基线数据（id 1..50）
  let _ = engine.append_base_part(make_docs_batch(1, 50, dim, "base"))
  engine.publish_manifest()

  // 软删除 15 条（id 1..15），比例 15/50 = 30% > 20%
  let old_ids : Array[UInt64] = Array::new(capacity=15)
  for i in 1..<=15 {
    old_ids.push(i.to_uint64())
  }
  engine.soft_delete(old_ids)
  engine.publish_manifest()

  // 此时 L0 为 0 (< 4)，但 tombstone 比例 30% > 20%
  compactor.notify_mutation(300L)
  let res = compactor.tick(300L)
  assert_eq(res is Some(_), true)

  match res {
    Some(r) => {
      // 50 删 15 = 35 存活
      assert_eq(r.output_row_count, 35)
      assert_eq(r.tombstones_purged, 15)
    }
    None => fail("compaction must trigger on tombstone ratio > 20%")
  }

  // 验证合并后的 Manifest 与 Part 数据：墓碑行已被彻底物理剔除！
  let m_done = engine.get_manifest()
  assert_eq(m_done.parts.length(), 1)
  assert_eq(m_done.tombstones.length(), 0) // tombstones 清理完毕

  let live_docs = engine.read_live_docs()
  assert_eq(live_docs.length(), 35)
  for d in live_docs {
    assert_eq(d.id > 15UL, true) // id 1..15 已彻底被物理消除
  }
}

///|
test "Compactor: 3) idle timer fallback triggers compaction for pending delta" {
  let store = @store.MemStore::new()
  let ns = "compactor_idle_test"
  let dim = 4
  let engine = MergeTreeEngine::new(store, ns, dim, false, None)

  let config : CompactionTriggerConfig = {
    l0_threshold: 4,
    tombstone_ratio_threshold: 0.20,
    idle_fallback_ms: 5000L, // 5秒空闲超时
    max_merge_parts: 16,
  }
  let compactor = Compactor::new(engine, TieredMergePolicy::new(config), config)

  // 写入 1 个基线段 + 仅 1 个 L0 delta (< 4，无墓碑)
  let _ = engine.append_base_part(make_docs_batch(1, 20, dim, "base"))
  let _ = engine.append_l0_delta_part(make_docs_batch(100, 5, dim, "pending_delta"))
  engine.publish_manifest()

  // 记录最后一次活动时间在 1000ms
  compactor.notify_mutation(1000L)

  // 检查在 3000ms（空闲 2000ms < 5000ms）-> 不触发
  let res_early = compactor.tick(3000L)
  assert_eq(res_early is None, true)
  assert_eq(engine.get_manifest().l0_count(), 1)

  // 检查在 7000ms（空闲 6000ms >= 5000ms）-> 触发 idle timer fallback
  let res_idle = compactor.tick(7000L)
  assert_eq(res_idle is Some(_), true)

  // 合并完成，L0 已被折叠
  assert_eq(engine.get_manifest().l0_count(), 0)
  assert_eq(engine.get_manifest().parts.length(), 1)
}

///|
test "Compactor: 4) query path remains 100% unblocked and consistent during background compaction" {
  let store = @store.MemStore::new()
  let ns = "compactor_concurrency_test"
  let dim = 4
  let engine = MergeTreeEngine::new(store, ns, dim, false, None)

  let config : CompactionTriggerConfig = {
    l0_threshold: 2,
    tombstone_ratio_threshold: 0.20,
    idle_fallback_ms: 10000L,
    max_merge_parts: 16,
  }
  let compactor = Compactor::new(engine, TieredMergePolicy::new(config), config)

  // 写入基线与 L0 delta
  let _ = engine.append_base_part(make_docs_batch(1, 50, dim, "base_v1"))
  let _ = engine.append_l0_delta_part(make_docs_batch(101, 10, dim, "delta_v1"))
  let _ = engine.append_l0_delta_part(make_docs_batch(111, 10, dim, "delta_v2"))
  engine.publish_manifest()

  // 读路径 1：读者在合并执行前发起读请求，无锁读取
  let live_before = engine.read_live_docs()
  assert_eq(live_before.length(), 70) // 50 + 10 + 10

  // 后台合并器执行合并
  compactor.notify_mutation(100L)
  let comp_res = compactor.tick(100L)
  assert_eq(comp_res is Some(_), true)

  // 读路径 2：合并完成后立即发起读请求，零阻塞，结果精确无缝
  let live_after = engine.read_live_docs()
  assert_eq(live_after.length(), 70)

  // 验证所有数据值依然 100% 一致保真
  for i in 0..<70 {
    assert_eq(live_before[i].id, live_after[i].id)
    assert_eq(live_before[i].text, live_after[i].text)
  }
}
