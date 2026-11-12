// cmd/serve 单元与集成白盒测试：
// 1) 存储可插拔：fs:PATH、sim (SimStore) 与 AnyStore 委托验证；
// 2) 后台 Compactor：条件唤醒策略 (L0 >= 4, tombstone >= 20%) 与 idle fallback；
// 3) 查询富化：返回 payload contract 中的 text, category, ts, public。

///|
test "cmd/serve: AnyStore with SimStore pluggability" {
  let sim_cfg = @simstore.SimConfig::aws_default(42U)
  let sim = @simstore.SimStore::new(sim_cfg)
  let store : AnyStore = Sim(sim)

  // 验证 ObjectStore 基本操作
  @store.ObjectStore::put(store, "test/key1", @utf8.encode("value1"))
  let read_val = @store.ObjectStore::get(store, "test/key1")
  assert_eq(read_val is Some(_), true)
  assert_eq(@utf8.decode(read_val.unwrap().view()) catch { _ => "" }, "value1")

  // 验证 CAS put_if_match
  let cas_ok = @store.ObjectStore::put_if_match(
    store,
    "test/cas",
    None,
    @utf8.encode("init"),
  )
  assert_eq(cas_ok, true)
}

///|
test "cmd/serve: In-process Compactor conditional wake-up & idle fallback" {
  let sim_cfg = @simstore.SimConfig::aws_default(100U)
  let sim = @simstore.SimStore::new(sim_cfg)
  let store : AnyStore = Sim(sim)
  let ns = "test_serve_compactor"
  let dim = 4

  let state = get_or_create_ns_state(store, ns, dim)

  // 1. 写入基线
  let base_docs : Array[@core.Doc] = [
    {
      id: 1UL,
      text: "base doc 1",
      vector: [0.1, 0.2, 0.3, 0.4],
      category: "tech",
      ts: 1000L,
      public: true,
    },
    {
      id: 2UL,
      text: "base doc 2",
      vector: [0.2, 0.3, 0.4, 0.5],
      category: "news",
      ts: 2000L,
      public: false,
    },
  ]
  let _ = state.engine.append_base_part(base_docs)
  state.engine.publish_manifest()
  state.compactor.notify_mutation(1000L)

  // L0 数量为 0，不应触发合并
  let res0 = state.compactor.tick(1000L)
  assert_eq(res0 is None, true)

  // 2. 连续追加 4 个 L0 delta batch，达到 l0_threshold (4)
  for b in 1..<=4 {
    let delta_docs : Array[@core.Doc] = [
      {
        id: (10 + b).to_uint64(),
        text: "delta doc \{b}",
        vector: [0.1, 0.1, 0.1, 0.1],
        category: "delta",
        ts: (1000 + b).to_int64(),
        public: true,
      },
    ]
    let _ = state.engine.append_l0_delta_part(delta_docs)
    state.engine.publish_manifest()
  }

  assert_eq(state.engine.get_manifest().l0_count(), 4)

  // 3. 唤醒并驱动 tick：由于 L0 count == 4 >= 4，触发条件合并！
  state.compactor.notify_mutation(2000L)
  let res_comp = state.compactor.tick(2000L)
  assert_eq(res_comp is Some(_), true)
  assert_eq(state.engine.get_manifest().l0_count(), 0)
  assert_eq(state.engine.get_manifest().parts.length(), 1)
  assert_eq(state.engine.get_manifest().parts[0].level, 1)

  // 4. 测试墓碑比例 >= 20% 唤醒
  // 当前基线段有 6 行 (2 base + 4 delta)。软删除 2 行 (2/6 = 33.3% >= 20%)
  state.engine.soft_delete([1UL, 2UL])
  state.engine.publish_manifest()
  state.compactor.notify_mutation(3000L)
  let res_tomb = state.compactor.tick(3000L)
  assert_eq(res_tomb is Some(_), true)
  assert_eq(res_tomb.unwrap().tombstones_purged, 2)
  assert_eq(state.engine.get_manifest().tombstones.length(), 0)

  // 5. 测试 idle fallback 超时回退
  // 追加 1 个小 delta (1 < 4)
  let idle_delta : Array[@core.Doc] = [
    {
      id: 99UL,
      text: "idle delta",
      vector: [0.5, 0.5, 0.5, 0.5],
      category: "idle",
      ts: 5000L,
      public: true,
    },
  ]
  let _ = state.engine.append_l0_delta_part(idle_delta)
  state.engine.publish_manifest()
  state.compactor.notify_mutation(10000L)

  // 未到 idle_fallback_ms (5000ms)，例如只过 1000ms：不触发
  let res_early = state.compactor.tick(11000L)
  assert_eq(res_early is None, true)

  // 超过 idle_fallback_ms (过 6000ms)：触发 idle fallback 合并！
  let res_idle = state.compactor.tick(17000L)
  assert_eq(res_idle is Some(_), true)
  assert_eq(state.engine.get_manifest().l0_count(), 0)
}

///|
test "cmd/serve: Enriched query results payload contract" {
  let sim_cfg = @simstore.SimConfig::aws_default(200U)
  let sim = @simstore.SimStore::new(sim_cfg)
  let store : AnyStore = Sim(sim)
  let ns = "test_serve_query_enrich"
  let dim = 4

  let cfg = @build.BuildConfig::single_copy(ns)
  let docs : Array[@core.Doc] = [
    {
      id: 101UL,
      text: "turbofish cloud storage engine",
      vector: [1.0, 0.0, 0.0, 0.0],
      category: "database",
      ts: 1700000101L,
      public: true,
    },
    {
      id: 102UL,
      text: "turbofish vector search fast",
      vector: [0.0, 1.0, 0.0, 0.0],
      category: "ai",
      ts: 1700000102L,
      public: false,
    },
  ]
  @build.ingest(store, { ..cfg, vector_dim: dim }, docs)

  let n = @query.open(store, ns)
  let qres = @query.bm25_search(n, "storage", 5, None)
  assert_eq(qres.length() >= 1, true)
  let hit = qres[0]
  assert_eq(hit.id, 101UL)

  let attrs = lookup_doc_attrs(store, ns, n, hit.id)
  assert_eq(attrs.text, "turbofish cloud storage engine")
  assert_eq(attrs.category, "database")
  assert_eq(attrs.ts, 1700000101L)
  assert_eq(attrs.public, true)
}
