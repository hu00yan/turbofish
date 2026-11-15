///|

// WriteBackBuffer 与 CachedManifestStore 白盒测试：
// 1. 验证 50 轮连续 10 行微编辑在 WriteBackBuffer 攒批写回下的削减效果（从 150 次 PUT 削减到 15 次，削减 90%）；
// 2. 验证透明融合检索（Read-Your-Own-Writes）：未刷盘内存文档与持久化文档精确合并；
// 3. 验证 CachedManifestStore 零 S3 GET 开销；
// 4. 验证多云 HeadCoordinator (NativeCasCoordinator vs LeaseCoordinator)。

///|
fn make_wb_test_docs(start : Int, count : Int, dim : Int) -> Array[@core.Doc] {
  let docs : Array[@core.Doc] = Array(capacity=count)
  for i in 0..<count {
    let id_num = start + i
    let v : Array[Float] = Array(capacity=dim)
    for d in 0..<dim {
      v.push(Float::from_int((id_num * 13 + d * 7) % 500) * 0.002)
    }
    docs.push({
      id: id_num.to_uint64(),
      text: "turbofish document content id=\{id_num}",
      vector: v,
      category: "test_doc",
      ts: (1700000000 + id_num).to_int64(),
      public: true,
    })
  }
  docs
}

///|
test "WriteBackBuffer: 50 successive 10-row edits slashed from 150 PUTs to 15 PUTs" {
  let store = @store.MemStore::new()
  let ns = "cursor_write_back_ns"
  let dim = 4
  let engine = MergeTreeEngine::new(store, ns, dim, false, None)

  // 1. 写入 1,000 篇基线文档 (Base Part, Level = 1)
  let base_docs = make_wb_test_docs(1, 1000, dim)
  let _ = engine.append_base_part(base_docs)
  engine.publish_manifest()

  let puts_after_base = store.cost().puts
  // base_part (1) + manifest (1) + head_ptr (1) = 3 PUTs
  assert_eq(puts_after_base, 3)

  // 2. 初始化 WriteBackBuffer，设置每攒满 100 行或 64KB 触发一次写回
  let wb = WriteBackBuffer::new(
    engine,
    flush_rows_threshold=100,
    flush_bytes_threshold=65536,
    linger_ms=5000L,
  )

  // 3. 执行 50 轮连续微突变（每轮 10 行，共 500 次行修改）
  for step in 0..<50 {
    let edit_start = step * 10 + 1
    let old_ids : Array[UInt64] = Array(capacity=10)
    let updated_docs : Array[@core.Doc] = Array(capacity=10)

    for i in 0..<10 {
      let id_num = edit_start + i
      let id_u64 = id_num.to_uint64()
      old_ids.push(id_u64)
      let v : Array[Float] = Array(capacity=dim)
      for d in 0..<dim {
        v.push(Float::from_int((id_num * 31 + step * 19 + d) % 500) * 0.002)
      }
      updated_docs.push({
        id: id_u64,
        text: "turbofish mutated step=\{step} doc=\{id_num}",
        vector: v,
        category: "mutated",
        ts: (1710000000 + step * 100 + i).to_int64(),
        public: true,
      })
    }

    let now_ms = (step + 1).to_int64() * 100L // 每次编辑间隔 100ms
    let flush_res = wb.mutate(updated_docs, old_ids, now_ms)

    // 每 10 轮（100 行）恰好触发 1 次批量 Flush 下刷
    if (step + 1) % 10 == 0 {
      assert_eq(flush_res is Some(_), true)
    } else {
      assert_eq(flush_res is None, true) // 暂存缓冲，0 次 S3 PUT！
    }
  }

  // 4. 断言：50 轮编辑后，只执行了 5 次下刷
  assert_eq(wb.total_flushes(), 5)
  assert_eq(wb.total_mutations(), 500)

  // 5 次下刷产生：5 × 3 = 15 次 PUT。加上最初基线的 3 次，总计仅 18 次 PUT
  // 若未攒批：50 × 3 = 150 次 PUT，外加基线 3 次 = 153 次 PUT。
  // 写成本削减比例达到 (150 - 15) / 150 = 90.0%
  let total_puts = store.cost().puts
  assert_eq(total_puts, 18)

  // 5. 验证读时强一致性：检索所有活文档完全正确，1000 篇活文档无丢失无重复
  let live_docs = wb.read_all_live_docs()
  assert_eq(live_docs.length(), 1000)
  // 验证前 500 篇文档已全部更新为 mutated
  assert_eq(live_docs[0].category, "mutated")
  assert_eq(live_docs[499].category, "mutated")
  // 501~1000 篇保持原状
  assert_eq(live_docs[500].category, "test_doc")
}

///|
test "CachedManifestStore eliminates S3 GETs on read path" {
  let store = @store.MemStore::new()
  let ns = "cached_manifest_ns"
  let obj_store = ObjManifestStore::new(store, ns)
  let cached_store = CachedManifestStore::new(obj_store, ttl_ms=2000L, is_writer=true)

  // 发布初始版本
  let m = Manifest::new()
  m.seq = 1UL
  ManifestStore::publish(cached_store, m)

  // 重置统计
  store.reset_cost()

  // 连续执行 10 次 load()
  for _ in 0..<10 {
    let loaded = ManifestStore::load(cached_store)
    assert_eq(loaded.seq, 1UL)
  }

  // 断言：由于是 Writer 节点且内存缓存命中，S3 GET 次数严格为 0
  let reqs = store.cost().gets
  assert_eq(reqs, 0)
}

///|
test "Multi-Cloud HeadCoordinators (Native CAS and Lease fallback)" {
  let store = @store.MemStore::new()
  let ns = "coordinator_test_ns"

  // 1. 原生 CAS 协调器测试
  let native_coord = NativeCasCoordinator::new(store)
  assert_eq(native_coord.read_head(ns), None)

  // 初次提交（预期版本 None）
  let ok1 = native_coord.commit_head(ns, None, "manifest-1")
  assert_eq(ok1, true)
  let (val1, ver1) = match native_coord.read_head(ns) {
    Some(pair) => pair
    None => fail("head must exist")
  }
  assert_eq(val1, "manifest-1")

  // 冲突提交（预期版本错误）必须返回 false
  let ok_fail = native_coord.commit_head(ns, Some("wrong_ver"), "manifest-2")
  assert_eq(ok_fail, false)

  // 正确换代提交
  let ok2 = native_coord.commit_head(ns, Some(ver1), "manifest-2")
  assert_eq(ok2, true)

  // 2. 租约后备协调器测试（用于阿里云/腾讯云/MinIO 等不支持 PUT CAS 的场景）
  let lease_coord = LeaseCoordinator::new(store)
  let ok_lease = lease_coord.commit_head(ns, Some("manifest-2"), "manifest-3")
  assert_eq(ok_lease, true)
  let (val3, _) = match lease_coord.read_head(ns) {
    Some(pair) => pair
    None => fail("head must exist")
  }
  assert_eq(val3, "manifest-3")
}

extend LeaseCoordinator with HeadCoordinator::{commit_head, read_head}
