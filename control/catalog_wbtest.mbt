// control/catalog_wbtest.mbt: 白盒测试验证 Pluggable Metadata Catalog & Relational State Machine
//
// 覆盖验证内容：
// 1. MemRdbCatalog ACID 事务与 MVCC 快照隔离、写失败自动回滚
// 2. 分布式 Fencing 与租约管理（Lease expiration, fencing epoch 递增与过期令牌拦截）
// 3. Lineage DAG 分支血缘追溯与 Snapshot 注册解析
// 4. GC 安全活跃引用追踪（Head Manifest、快照、血缘祖先、宽限期未引用段检测）
// 5. S3CasCatalog 纯 S3 CAS 头指针原子换代、_heads/ 日志与双写防悬挂检查 (Safety 2)

fn make_manifest(mid : String, seg_ids : Array[String]) -> @format.ManifestData {
  let segs : Array[@format.SegmentMeta] = []
  for sid in seg_ids {
    segs.push({
      id: sid,
      row_count: 10,
      min_id: 1UL,
      max_id: 10UL,
      doc_len_sum: 50,
      size_bytes: 1024,
    })
  }
  {
    id: mid,
    parent: None,
    segments: segs,
    deleted: [],
    deleted_roar: None,
    vec_global_version: None,
    global_gen: None,
    centroid_version: "c0",
    num_docs: seg_ids.length() * 10,
    avg_doc_len: 5.0,
  }
}

// ======================================================================
// 1. MemRdbCatalog ACID 事务、回滚与 MVCC 快照隔离测试
// ======================================================================

test "MemRdbCatalog: ACID rollback on write failure" {
  let cat = MemRdbCatalog::new()
  cat.create_namespace(default_namespace_meta("test_ns", head_manifest="mid-01"))

  // 验证初始状态
  let ns0 = cat.get_namespace("test_ns").unwrap()
  assert_eq(ns0.head_manifest, "mid-01")

  // 在事务中修改元数据并中途失败，验证自动回滚（原子性）
  let res : Result[Unit, CatalogError] = try {
    cat.with_transaction(() => {
      cat.update_head_manifest("test_ns", "mid-02")
      // 故意抛出错误模拟中途失败
      raise CatalogError::TxAborted("simulated write failure mid-transaction")
    })
    Ok(())
  } catch {
    err => Err(err)
  }
  assert_eq(res is Err(_), true)

  // 回滚后，head_manifest 依然是 mid-01，未发生任何脏写或部分更新
  let ns1 = cat.get_namespace("test_ns").unwrap()
  assert_eq(ns1.head_manifest, "mid-01")
}

test "MemRdbCatalog: MVCC snapshot isolation across transaction versions" {
  let cat = MemRdbCatalog::new()
  cat.create_namespace(default_namespace_meta("mvcc_ns", head_manifest="v1"))

  // 版本 1 时的快照视图
  let snap_v1 = cat.get_namespace_at("mvcc_ns", 1UL).unwrap()
  assert_eq(snap_v1.head_manifest, "v1")

  // 更新为 v2
  cat.update_head_manifest("mvcc_ns", "v2")

  // 当前视图已看到 v2
  let cur = cat.get_namespace("mvcc_ns").unwrap()
  assert_eq(cur.head_manifest, "v2")

  // 但指定历史事务编号 1 时，读到的依然是不可变的 v1 视图（快照隔离）
  let hist = cat.get_namespace_at("mvcc_ns", 1UL).unwrap()
  assert_eq(hist.head_manifest, "v1")
}

// ======================================================================
// 2. 分布式 Fencing 与租约管理测试（MemRdbCatalog & S3CasCatalog）
// ======================================================================

test "MemRdbCatalog: Distributed Fencing lease expiration and token mismatch" {
  let cat = MemRdbCatalog::new()
  cat.create_namespace(default_namespace_meta("fenced_ns", head_manifest="mid-01"))
  cat.set_mock_time(Some(1000UL))

  // 1. Worker 1 在 t=1000 申请租约，TTL 5000ms（有效至 6000ms）
  let tok1 = cat.acquire_lease("fenced_ns", "worker-1", 5000UL).unwrap()
  assert_eq(tok1.worker_id, "worker-1")
  assert_eq(tok1.epoch, 1UL)
  assert_eq(tok1.expires_at_ms, 6000UL)

  // 2. Worker 2 在租约有效期内（t=2000）尝试抢占租约，应当被拒绝 (None)
  cat.set_mock_time(Some(2000UL))
  let tok2_denied = cat.acquire_lease("fenced_ns", "worker-2", 5000UL)
  assert_eq(tok2_denied is None, true)

  // 3. Worker 1 正常续约 4000ms
  let tok1_renewed = cat.renew_lease(tok1, 4000UL).unwrap()
  assert_eq(tok1_renewed.epoch, 1UL)
  assert_eq(tok1_renewed.expires_at_ms, 6000UL) // 2000 + 4000 = 6000

  // 4. 时间流逝至 t=7000（租约已过期）
  cat.set_mock_time(Some(7000UL))

  // 5. Worker 2 成功获取过期后的新租约，fencing epoch 递增至 2
  let tok2 = cat.acquire_lease("fenced_ns", "worker-2", 5000UL).unwrap()
  assert_eq(tok2.worker_id, "worker-2")
  assert_eq(tok2.epoch, 2UL)

  // 6. Worker 1（拿着过期的旧 epoch 1 令牌）尝试提交 head manifest，被 FencingTokenMismatch 拒绝
  let stale_commit : Result[Unit, CatalogError] = try {
    cat.update_head_manifest("fenced_ns", "mid-stale", lease_token=tok1)
    Ok(())
  } catch {
    err => Err(err)
  }
  assert_eq(stale_commit is Err(_), true)

  // 7. Worker 2（持有合法 epoch 2 令牌）正常提交 head manifest，成功
  cat.update_head_manifest("fenced_ns", "mid-valid", lease_token=tok2)
  let ns = cat.get_namespace("fenced_ns").unwrap()
  assert_eq(ns.head_manifest, "mid-valid")

  // 8. 释放租约后其他 worker 可立即获取
  assert_eq(cat.release_lease(tok2), true)
  let tok3 = cat.acquire_lease("fenced_ns", "worker-3", 3000UL)
  assert_eq(tok3 is Some(_), true)
}

test "S3CasCatalog: Distributed Fencing lease expiration and fencing on S3 CAS" {
  let store = @store.MemStore::new()
  let cat = S3CasCatalog::new(store)
  cat.create_namespace(default_namespace_meta("s3_fenced", head_manifest="mid-init"))
  cat.set_mock_time(Some(1000UL))

  // 写入合法的 Manifest 对象以供更新
  cat.register_manifest("s3_fenced", make_manifest("mid-init", []))
  cat.register_manifest("s3_fenced", make_manifest("mid-02", []))

  // Worker 1 抢得租约
  let tok1 = cat.acquire_lease("s3_fenced", "w1", 5000UL).unwrap()
  assert_eq(tok1.epoch, 1UL)

  // Worker 2 在有效期内被排斥
  cat.set_mock_time(Some(2000UL))
  assert_eq(cat.acquire_lease("s3_fenced", "w2", 5000UL) is None, true)

  // 模拟过期
  cat.set_mock_time(Some(7000UL))
  let tok2 = cat.acquire_lease("s3_fenced", "w2", 5000UL).unwrap()
  assert_eq(tok2.epoch, 2UL)

  // 旧 Worker 1 提交被拦截
  let res_stale : Result[Unit, CatalogError] = try {
    cat.update_head_manifest("s3_fenced", "mid-02", lease_token=tok1)
    Ok(())
  } catch {
    err => Err(err)
  }
  assert_eq(res_stale is Err(_), true)

  // 新 Worker 2 提交成功
  cat.update_head_manifest("s3_fenced", "mid-02", lease_token=tok2)
  let ns = cat.get_namespace("s3_fenced").unwrap()
  assert_eq(ns.head_manifest, "mid-02")
}

// ======================================================================
// 3. Lineage & Snapshot DAG 测试
// ======================================================================

test "MetadataCatalog: Lineage and Snapshot DAG traversal" {
  let cat = MemRdbCatalog::new()
  cat.create_namespace(default_namespace_meta("main", head_manifest="m-main-1"))
  cat.create_namespace(default_namespace_meta("feature_branch", head_manifest="m-feat-1"))
  cat.create_namespace(default_namespace_meta("sub_experiment", head_manifest="m-sub-1"))

  // 建立分支血缘树：main <- feature_branch <- sub_experiment
  cat.record_branch_origin("feature_branch", "main")
  cat.record_branch_origin("sub_experiment", "feature_branch")

  let lin = cat.get_lineage("sub_experiment")
  assert_eq(lin, ["sub_experiment", "feature_branch", "main"])

  // 注册快照并解析
  cat.register_snapshot("main", "v1.0.0", "m-main-snap1")
  cat.register_snapshot("feature_branch", "checkpoint-a", "m-feat-snapA")

  assert_eq(cat.resolve_snapshot("main", "v1.0.0"), Some("m-main-snap1"))
  assert_eq(cat.resolve_snapshot("feature_branch", "checkpoint-a"), Some("m-feat-snapA"))
  assert_eq(cat.resolve_snapshot("main", "non_existent"), None)
}

test "S3CasCatalog: Lineage and Snapshot DAG in pure S3" {
  let store = @store.MemStore::new()
  let cat = S3CasCatalog::new(store)
  cat.create_namespace(default_namespace_meta("s3_root", head_manifest="m-root"))
  cat.create_namespace(default_namespace_meta("s3_fork", head_manifest="m-fork"))

  cat.record_branch_origin("s3_fork", "s3_root")
  let lin = cat.get_lineage("s3_fork")
  assert_eq(lin, ["s3_fork", "s3_root"])

  cat.register_snapshot("s3_root", "release-2026", "m-snap-2026")
  assert_eq(cat.resolve_snapshot("s3_root", "release-2026"), Some("m-snap-2026"))
}

// ======================================================================
// 4. GC Safety Active Reference Tracking 测试
// ======================================================================

test "MemRdbCatalog: GC Reference Safety across head, snapshots, lineage and grace period" {
  let cat = MemRdbCatalog::new()
  cat.set_mock_time(Some(1000UL))

  cat.create_namespace(default_namespace_meta("root_ns", head_manifest="m-root"))
  cat.create_namespace(default_namespace_meta("child_ns", head_manifest="m-child"))
  cat.record_branch_origin("child_ns", "root_ns")

  // 1. root_ns head 引用 seg-root-head
  cat.register_manifest_segments("root_ns", "m-root", ["seg-root-head"])
  // 2. root_ns 快照引用 seg-root-snap
  cat.register_manifest_segments("root_ns", "m-root-snap", ["seg-root-snap"])
  cat.register_snapshot("root_ns", "snap1", "m-root-snap")
  // 3. child_ns head 引用 seg-child-head
  cat.register_manifest_segments("child_ns", "m-child", ["seg-child-head"])

  // child_ns 的活跃段应当包括自身的段、祖先的 head 段、以及祖先快照保护的段
  let active = cat.list_active_segment_ids("child_ns")
  assert_eq(active.contains("seg-child-head"), true)
  assert_eq(active.contains("seg-root-head"), true)
  assert_eq(active.contains("seg-root-snap"), true)

  // 4. 模拟一个正在上传但尚未被 manifest 引用的孤儿段 seg-staging
  cat.mark_segment_referenced("child_ns", "seg-staging")

  // 在宽限期（5000ms）之内 (t=2000, 间隔 1000ms)，seg-staging 不会被清理
  cat.set_mock_time(Some(2000UL))
  let unref_early = cat.get_unreferenced_segments("child_ns", 5000UL)
  assert_eq(unref_early.contains("seg-staging"), false)

  // 超过宽限期 (t=7000, 间隔 6000ms >= 5000ms)，未被引用的 seg-staging 应当被返回以供 GC
  cat.set_mock_time(Some(7000UL))
  let unref_late = cat.get_unreferenced_segments("child_ns", 5000UL)
  assert_eq(unref_late.contains("seg-staging"), true)

  // 但是所有处于活跃状态的段永远不会被标记为 unreferenced
  assert_eq(unref_late.contains("seg-child-head"), false)
  assert_eq(unref_late.contains("seg-root-head"), false)
  assert_eq(unref_late.contains("seg-root-snap"), false)
}

test "S3CasCatalog: GC Reference Safety and grace period on ObjectStore" {
  let store = @store.MemStore::new()
  let cat = S3CasCatalog::new(store)
  cat.set_mock_time(Some(1000UL))

  cat.create_namespace(default_namespace_meta("ns_s3_gc", head_manifest="m-head"))

  // 在 S3 中准备好数据对象
  cat.seed_segment("ns_s3_gc", "seg-live")
  cat.seed_segment("ns_s3_gc", "seg-orphan")
  cat.register_manifest("ns_s3_gc", make_manifest("m-head", ["seg-live"]))

  // seg-orphan 在 t=1000 标记引用
  cat.mark_segment_referenced("ns_s3_gc", "seg-orphan")

  let active = cat.list_active_segment_ids("ns_s3_gc")
  assert_eq(active.contains("seg-live"), true)
  assert_eq(active.contains("seg-orphan"), false)

  // t=2000：宽限期内
  cat.set_mock_time(Some(2000UL))
  let unref_1 = cat.get_unreferenced_segments("ns_s3_gc", 5000UL)
  assert_eq(unref_1.contains("seg-orphan"), false)
  assert_eq(unref_1.contains("seg-live"), false)

  // t=7000：超过宽限期
  cat.set_mock_time(Some(7000UL))
  let unref_2 = cat.get_unreferenced_segments("ns_s3_gc", 5000UL)
  assert_eq(unref_2.contains("seg-orphan"), true)
  assert_eq(unref_2.contains("seg-live"), false)
}

// ======================================================================
// 5. S3 CAS 原子更新与双写防悬挂指针一致性测试 (Safety 2 & 3)
// ======================================================================

test "S3CasCatalog: Dual-Write Crash Consistency (Safety 2 - No Dangling Pointer)" {
  let store = @store.MemStore::new()
  let cat = S3CasCatalog::new(store)
  cat.create_namespace(default_namespace_meta("crash_ns", head_manifest="m0"))
  cat.register_manifest("crash_ns", make_manifest("m0", []))

  // 构造一个引用了段 "seg-missing" 的 manifest "m-broken"
  // 但我们故意不在 store 中上传该段的任何数据（模拟上传崩溃）
  cat.register_manifest("crash_ns", make_manifest("m-broken", ["seg-missing"]))

  // 尝试提交 m-broken：目录必须拦截并报错 NotFound（防止悬挂指针破坏一致性）
  let res : Result[Unit, CatalogError] = try {
    cat.update_head_manifest("crash_ns", "m-broken")
    Ok(())
  } catch {
    err => Err(err)
  }
  assert_eq(res is Err(_), true)

  // 修复崩溃：上传 seg-missing 之后再次提交
  cat.seed_segment("crash_ns", "seg-missing")
  cat.update_head_manifest("crash_ns", "m-broken")

  let ns = cat.get_namespace("crash_ns").unwrap()
  assert_eq(ns.head_manifest, "m-broken")
}

test "S3CasCatalog: CAS conflict detection on expected_head" {
  let store = @store.MemStore::new()
  let cat = S3CasCatalog::new(store)
  cat.create_namespace(default_namespace_meta("cas_ns", head_manifest="m1"))
  cat.register_manifest("cas_ns", make_manifest("m1", []))
  cat.register_manifest("cas_ns", make_manifest("m2", []))

  // 预期版本与当前版本不匹配 -> CommitConflict
  let conflict : Result[Unit, CatalogError] = try {
    cat.update_head_manifest("cas_ns", "m2", expected_head="m_wrong")
    Ok(())
  } catch {
    err => Err(err)
  }
  assert_eq(conflict is Err(_), true)

  // 预期版本匹配 -> 成功换代
  cat.update_head_manifest("cas_ns", "m2", expected_head="m1")
  let ns = cat.get_namespace("cas_ns").unwrap()
  assert_eq(ns.head_manifest, "m2")
}
