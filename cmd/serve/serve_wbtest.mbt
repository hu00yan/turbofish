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

///|
test "cmd/serve: parse_filter_json tpf array syntax" {
  // ["attr", "Eq", v]
  let f1 = parse_filter_json(
    (@json.parse("[\"category\",\"Eq\",\"books\"]") catch { _ => fail("bad json") }),
  )
  assert_eq(f1 is @query.Eq(_, _), true)
  // 两元糖 ["attr", v] = Eq
  let f2 = parse_filter_json(
    (@json.parse("[\"category\",\"books\"]") catch { _ => fail("bad json") }),
  )
  assert_eq(f2 is @query.Eq(_, _), true)
  // op 全集
  for spec in [
    ("[\"ts\",\"NotEq\",5]", "Neq"),
    ("[\"ts\",\"Lt\",5]", "Lt"),
    ("[\"ts\",\"Lte\",5]", "Lte"),
    ("[\"ts\",\"Gt\",5]", "Gt"),
    ("[\"ts\",\"Gte\",5]", "Gte"),
    ("[\"ts\",\"In\",[1,2,3]]", "In"),
    ("[\"ts\",\"NotIn\",[1,2,3]]", "NotIn"),
  ] {
    let f = parse_filter_json(
      (@json.parse(spec.0) catch { _ => fail("bad json") }),
    )
    assert_eq(filter_shape(f), spec.1)
  }
  // 组合
  let f3 = parse_filter_json(
    (@json.parse(
        "[\"And\",[[\"ts\",\"Gte\",100],[\"Or\",[[\"category\",\"a\"],[\"Not\",[\"public\",true]]]]]]"
      ) catch {
        _ => fail("bad json")
      }),
  )
  assert_eq(f3 is @query.And(_), true)
  // 非法：未知 op / 非同质 In / bool 范围 / 空 filter / 非法形状
  for bad in [
    "[\"ts\",\"Bogus\",5]",
    "[\"ts\",\"In\",[1,\"a\"]]",
    "[\"public\",\"Lt\",true]",
    "[]",
    "[\"And\",[]]",
    "\"category\"",
  ] {
    let ok = (try {
      let _ = parse_filter_json((@json.parse(bad) catch { _ => fail("bad json") }))
      true
    } catch {
      _ => false
    })
    assert_eq(ok, false)
  }
}

///|
/// 过滤树顶层形状标签（测试辅助）。
fn filter_shape(f : @query.Filter) -> String {
  match f {
    @query.Eq(_, _) => "Eq"
    @query.Neq(_, _) => "Neq"
    @query.In(_, _) => "In"
    @query.NotIn(_, _) => "NotIn"
    @query.Lt(_, _) => "Lt"
    @query.Lte(_, _) => "Lte"
    @query.Gt(_, _) => "Gt"
    @query.Gte(_, _) => "Gte"
    @query.Glob(_, _) => "Glob"
    @query.And(_) => "And"
    @query.Or(_) => "Or"
    @query.Not(_) => "Not"
  }
}

///|
test "cmd/serve: distance metric aliases" {
  assert_eq(parse_metric(Json::string("cosine")), Some("cosine"))
  assert_eq(parse_metric(Json::string("cosine_distance")), Some("cosine"))
  assert_eq(parse_metric(Json::string("euclidean")), Some("euclidean"))
  assert_eq(parse_metric(Json::string("euclidean_squared")), Some("euclidean"))
  assert_eq(parse_metric(Json::string("manhattan")), None)
  assert_eq(parse_metric(Json::number(1.0)), None)
}

///|
test "cmd/serve: Glob filter parsing" {
  let f1 = parse_filter_json(
    @json.parse("[\"category\", \"Glob\", \"tech*\"]") catch {
      _ => fail("bad json")
    },
  )
  assert_eq(f1 is @query.Glob("category", "tech*"), true)
  assert_eq(filter_shape(f1), "Glob")

  // 非法 Glob（值不是字符串）
  let bad_ok = try {
    let _ = parse_filter_json(
      @json.parse("[\"category\", \"Glob\", 123]") catch { _ => fail("bad json") },
    )
    true
  } catch {
    _ => false
  }
  assert_eq(bad_ok, false)
}

///|
test "cmd/serve: API key authentication check_auth" {
  // 1. 未配置 SPND_API_KEY 时全部放行
  @env.unset_env_var("SPND_API_KEY")
  let no_hdr_req : @http.Request = {
    meth: Get,
    path: "/v1/namespaces/test/health",
    headers: Map([]),
  }
  assert_eq(check_auth(no_hdr_req), true)

  // 2. 配置 SPND_API_KEY 时校验 Bearer token
  @env.set_env_var("SPND_API_KEY", "super-secret-key-123")
  assert_eq(check_auth(no_hdr_req), false)

  let bad_prefix_hdr : @http.Headers = Map([])
  bad_prefix_hdr.set(@http.CaseInsensitiveString("authorization"), "Basic dXNlcjpwYXNz")
  let bad_prefix_req : @http.Request = {
    meth: Post,
    path: "/v1/namespaces/test/query",
    headers: bad_prefix_hdr,
  }
  assert_eq(check_auth(bad_prefix_req), false)

  let wrong_token_hdr : @http.Headers = Map([])
  wrong_token_hdr.set(@http.CaseInsensitiveString("authorization"), "Bearer wrong-key")
  let wrong_token_req : @http.Request = {
    meth: Post,
    path: "/v1/namespaces/test/query",
    headers: wrong_token_hdr,
  }
  assert_eq(check_auth(wrong_token_req), false)

  let good_token_hdr : @http.Headers = Map([])
  good_token_hdr.set(@http.CaseInsensitiveString("authorization"), "Bearer super-secret-key-123")
  let good_token_req : @http.Request = {
    meth: Post,
    path: "/v1/namespaces/test/query",
    headers: good_token_hdr,
  }
  assert_eq(check_auth(good_token_req), true)

  // 清理环境变量
  @env.unset_env_var("SPND_API_KEY")
}

///|
test "cmd/serve: Prometheus metrics counters" {
  let init_reqs = prom_requests_total.val
  let init_queries = prom_queries_total.val
  let init_writes = prom_writes_total.val

  prom_requests_total.val += 1
  prom_queries_total.val += 1
  prom_writes_total.val += 1

  assert_eq(prom_requests_total.val, init_reqs + 1)
  assert_eq(prom_queries_total.val, init_queries + 1)
  assert_eq(prom_writes_total.val, init_writes + 1)
}

///|
test "cmd/serve: delete_by_filter write path" {
  let sim_cfg = @simstore.SimConfig::aws_default(300U)
  let sim = @simstore.SimStore::new(sim_cfg)
  let store : AnyStore = Sim(sim)
  let ns = "test_serve_del_filter"
  let dim = 4

  let cfg = @build.BuildConfig::single_copy(ns)
  let docs : Array[@core.Doc] = [
    {
      id: 1UL,
      text: "doc one",
      vector: [1.0, 0.0, 0.0, 0.0],
      category: "db_mysql",
      ts: 100L,
      public: true,
    },
    {
      id: 2UL,
      text: "doc two",
      vector: [0.0, 1.0, 0.0, 0.0],
      category: "db_postgres",
      ts: 200L,
      public: true,
    },
    {
      id: 3UL,
      text: "doc three",
      vector: [0.0, 0.0, 1.0, 0.0],
      category: "web_frontend",
      ts: 300L,
      public: false,
    },
  ]
  @build.ingest(store, { ..cfg, vector_dim: dim }, docs)

  let n_before = @query.open(store, ns)
  assert_eq(@query.count_docs(n_before, None), 3)

  // 按 Glob 过滤删除 category 以 "db_*" 开头的行 (应该删掉 1UL, 2UL)
  let filter = @query.Glob("category", "db_*")
  let deleted_count = delete_by_filter_core(store, ns, filter)
  assert_eq(deleted_count, 2)

  // 验证存活文档只剩 3UL
  let n_after = @query.open(store, ns)
  assert_eq(@query.count_docs(n_after, None), 1)
  let qres = @query.bm25_search(n_after, "doc", 10, None)
  assert_eq(qres.length(), 1)
  assert_eq(qres[0].id, 3UL)
}

///|
test "cmd/serve: namespace copy and branch" {
  let sim_cfg = @simstore.SimConfig::aws_default(400U)
  let sim = @simstore.SimStore::new(sim_cfg)
  let store : AnyStore = Sim(sim)
  let src_ns = "test_serve_src_ns"
  let dest_ns = "test_serve_dest_ns"
  let dim = 4

  let cfg = @build.BuildConfig::single_copy(src_ns)
  let docs : Array[@core.Doc] = [
    {
      id: 10UL,
      text: "original doc in source",
      vector: [0.5, 0.5, 0.5, 0.5],
      category: "test",
      ts: 500L,
      public: true,
    },
  ]
  @build.ingest(store, { ..cfg, vector_dim: dim }, docs)

  // 执行 copy
  copy_namespace_data(store, src_ns, dest_ns)

  // 验证 dest_ns 独立且具备相同数据
  let n_dest = @query.open(store, dest_ns)
  assert_eq(@query.count_docs(n_dest, None), 1)
  let qres = @query.bm25_search(n_dest, "original", 5, None)
  assert_eq(qres.length(), 1)
  assert_eq(qres[0].id, 10UL)
}

///|
test "cmd/serve: sum_field aggregation" {
  let sim_cfg = @simstore.SimConfig::aws_default(500U)
  let sim = @simstore.SimStore::new(sim_cfg)
  let store : AnyStore = Sim(sim)
  let ns = "test_serve_sum_field"
  let dim = 4

  let cfg = @build.BuildConfig::single_copy(ns)
  let docs : Array[@core.Doc] = [
    {
      id: 1UL,
      text: "apple",
      vector: [1.0, 0.0, 0.0, 0.0],
      category: "fruit",
      ts: 10L,
      public: true,
    },
    {
      id: 2UL,
      text: "banana",
      vector: [0.0, 1.0, 0.0, 0.0],
      category: "fruit",
      ts: 25L,
      public: true,
    },
    {
      id: 3UL,
      text: "carrot",
      vector: [0.0, 0.0, 1.0, 0.0],
      category: "vegetable",
      ts: 40L,
      public: true,
    },
  ]
  @build.ingest(store, { ..cfg, vector_dim: dim }, docs)

  let n = @query.open(store, ns)
  // 无 filter：全部 ts 求和 (10 + 25 + 40 = 75)
  let sum_all = @query.sum_field(n, "ts", None)
  assert_eq(sum_all, 75.0)

  // 带 filter：仅 fruit (10 + 25 = 35)
  let filter = @query.Eq("category", @query.S("fruit"))
  let sum_fruit = @query.sum_field(n, "ts", Some(filter))
  assert_eq(sum_fruit, 35.0)
}

///|
test "cmd/serve: partial update patch_rows without resending vector" {
  let sim_cfg = @simstore.SimConfig::aws_default(600U)
  let sim = @simstore.SimStore::new(sim_cfg)
  let store : AnyStore = Sim(sim)
  let ns = "test_serve_patch"
  let dim = 4

  let cfg = @build.BuildConfig::single_copy(ns)
  let docs : Array[@core.Doc] = [
    {
      id: 101UL,
      text: "original text about databases",
      vector: [1.0, 0.0, 0.0, 0.0],
      category: "old_category",
      ts: 1000L,
      public: true,
    },
    {
      id: 102UL,
      text: "another document about networking",
      vector: [0.0, 1.0, 0.0, 0.0],
      category: "infra",
      ts: 1500L,
      public: false,
    },
  ]
  @build.ingest(store, { ..cfg, vector_dim: dim }, docs)

  // 1. Partial update: patch category, ts, public without resending vector
  let patches : Array[RowPatch] = [
    {
      id: 101UL,
      text: None,
      category: Some("new_category"),
      ts: Some(2000L),
      public: Some(false),
    },
  ]
  let (patched_count, head) = patch_rows_core(store, ns, patches)
  assert_eq(patched_count, 1)
  assert_eq(head != "", true)

  // 2. Subsequent BM25 query on "databases" reflects updated attributes
  let n1 = @query.open(store, ns)
  let qres_bm25 = @query.bm25_search(n1, "databases", 5, None)
  assert_eq(qres_bm25.length() >= 1, true)
  assert_eq(qres_bm25[0].id, 101UL)

  let attrs = lookup_doc_attrs(store, ns, n1, 101UL)
  assert_eq(attrs.text, "original text about databases")
  assert_eq(attrs.category, "new_category")
  assert_eq(attrs.ts, 2000L)
  assert_eq(attrs.public, false)

  // 3. Subsequent vector query on [1.0, 0.0, 0.0, 0.0] finds 101UL with preserved vector
  let qv : Array[Float] = [1.0, 0.0, 0.0, 0.0]
  let qres_vec = @query.vec_search(n1, qv, 5, 2, None)
  assert_eq(qres_vec.length() >= 1, true)
  assert_eq(qres_vec[0].id, 101UL)
  assert_eq(qres_vec[0].score > 0.9, true)

  // 4. Partial update of text while preserving existing vector
  let text_patch : Array[RowPatch] = [
    {
      id: 101UL,
      text: Some("updated text about search"),
      category: None,
      ts: None,
      public: None,
    },
  ]
  let (p2_count, _) = patch_rows_core(store, ns, text_patch)
  assert_eq(p2_count, 1)

  let n2 = @query.open(store, ns)
  let qres_updated = @query.bm25_search(n2, "search", 5, None)
  assert_eq(qres_updated.length() >= 1, true)
  assert_eq(qres_updated[0].id, 101UL)

  let attrs2 = lookup_doc_attrs(store, ns, n2, 101UL)
  assert_eq(attrs2.text, "updated text about search")
  assert_eq(attrs2.category, "new_category") // category preserved from previous patch
  assert_eq(attrs2.ts, 2000L)

  // 5. Patching non-existent doc ID raises NotFound
  let missing_patch : Array[RowPatch] = [
    {
      id: 999UL,
      text: Some("ghost"),
      category: None,
      ts: None,
      public: None,
    },
  ]
  let not_found_ok = try {
    let _ = patch_rows_core(store, ns, missing_patch)
    false
  } catch {
    @core.NotFound(_) => true
    _ => false
  }
  assert_eq(not_found_ok, true)
}

///|
test "cmd/serve: coordinator authoritative in-memory metadata with zero S3 calls on warm query" {
  let sim_cfg = @simstore.SimConfig::aws_default(700U)
  let sim = @simstore.SimStore::new(sim_cfg)
  let store : AnyStore = Sim(sim)
  let ns = "test_serve_authoritative"
  let dim = 4

  let state = get_or_create_ns_state(store, ns, dim)
  let cfg = @build.BuildConfig::single_copy(ns)
  let docs1 : Array[@core.Doc] = [
    {
      id: 1UL,
      text: "cloud distributed vector database",
      vector: [1.0, 0.0, 0.0, 0.0],
      category: "database",
      ts: 100L,
      public: true,
    },
    {
      id: 2UL,
      text: "fast in-memory coordinator metadata",
      vector: [0.0, 1.0, 0.0, 0.0],
      category: "coordinator",
      ts: 200L,
      public: true,
    },
  ]
  @build.ingest(store, { ..cfg, vector_dim: dim }, docs1)
  let head1 = match @store.read_head_pointer(store, ns) {
    Some(h) => h
    None => @store.read_head(store, ns, "")
  }
  // Coordinator updates in-memory state on write
  state.update_after_write(store, ns, head1)
  for d in docs1 {
    state.doc_cache.set(d.id, { text: d.text, category: d.category, ts: d.ts, public: d.public })
    state.doc_full_cache.set(d.id, d)
  }

  // 1. First query: uses state.get_query_ns() directly without reading namespace.json or manifest.json
  let qn1 = state.get_query_ns(store, ns)
  assert_eq(qn1.manifest.id, head1)

  let hits1 = @query.bm25_search(qn1, "coordinator", 5, None)
  assert_eq(hits1.length(), 1)
  assert_eq(hits1[0].id, 2UL)

  let attrs1 = lookup_doc_attrs(store, ns, qn1, 2UL)
  assert_eq(attrs1.text, "fast in-memory coordinator metadata")
  assert_eq(attrs1.category, "coordinator")

  // Verify consecutive queries do not make ANY metadata requests to S3
  let gets_after_first = sim.cost().s3_gets
  for _ in 0..<10 {
    let qn_loop = state.get_query_ns(store, ns)
    let res = @query.bm25_search(qn_loop, "coordinator", 5, None)
    assert_eq(res.length(), 1)
    let a = lookup_doc_attrs(store, ns, qn_loop, res[0].id)
    assert_eq(a.category, "coordinator")
  }
  let gets_after_ten = sim.cost().s3_gets
  // Zero additional S3 GETs!
  assert_eq(gets_after_ten, gets_after_first)

  // 2. Partial patch: patch category of doc 2, state updates immediately
  let patches : Array[RowPatch] = [
    {
      id: 2UL,
      text: None,
      category: Some("ultra_coordinator"),
      ts: Some(300L),
      public: None,
    },
  ]
  let (patched_count, head2) = patch_rows_core(store, ns, patches)
  assert_eq(patched_count, 1)
  assert_eq(head2 != head1, true)

  // Query immediately sees updated state without S3 metadata reload
  let qn2 = state.get_query_ns(store, ns)
  assert_eq(qn2.manifest.id, head2)
  let hits2 = @query.bm25_search(qn2, "coordinator", 5, None)
  assert_eq(hits2.length() >= 1, true)
  assert_eq(hits2[0].id, 2UL)
  let attrs2 = lookup_doc_attrs(store, ns, qn2, hits2[0].id)
  assert_eq(attrs2.category, "ultra_coordinator")
  assert_eq(attrs2.ts, 300L)

  // 3. Delete by filter: delete database category
  let dels = delete_by_filter_core(store, ns, @query.Eq("category", @query.S("database")))
  assert_eq(dels, 1)

  let qn3 = state.get_query_ns(store, ns)
  let cnt = @query.count_docs(qn3, None)
  assert_eq(cnt, 2)
  let db_hits = @query.bm25_search(qn3, "database", 5, None)
  assert_eq(db_hits.length(), 0)
}

///|
test "cmd/serve: cold-start warms all segments and subsequent queries across all segments make zero S3 calls" {
  let sim_cfg = @simstore.SimConfig::aws_default(701U)
  let sim = @simstore.SimStore::new(sim_cfg)
  let store : AnyStore = Sim(sim)
  let ns = "test_serve_cold_warm"
  let dim = 4

  let cfg = @build.BuildConfig::single_copy(ns)
  let docs : Array[@core.Doc] = [
    {
      id: 10UL,
      text: "first segment alpha doc",
      vector: [1.0, 0.0, 0.0, 0.0],
      category: "alpha",
      ts: 100L,
      public: true,
    },
    {
      id: 20UL,
      text: "second segment beta doc",
      vector: [0.0, 1.0, 0.0, 0.0],
      category: "beta",
      ts: 200L,
      public: true,
    },
  ]
  @build.ingest(store, { ..cfg, vector_dim: dim }, docs)

  // Cold start: get_or_load_ns_state opens snapshot, pre-warms centroids, global IVF parts and all segment caches
  let state = get_or_load_ns_state(store, ns)
  let qn = state.get_query_ns(store, ns)

  // Query doc 10 from segment 0
  let res1 = @query.bm25_search(qn, "alpha", 5, None)
  let a1 = lookup_doc_attrs(store, ns, qn, res1[0].id)

  // Query doc 20 from segment 1
  let res2 = @query.bm25_search(qn, "beta", 5, None)
  let a2 = lookup_doc_attrs(store, ns, qn, res2[0].id)
  assert_eq(res1.length(), 1)
  assert_eq(res1[0].id, 10UL)
  assert_eq(a1.category, "alpha")
  assert_eq(res2.length(), 1)
  assert_eq(res2[0].id, 20UL)
  assert_eq(a2.category, "beta")

  // Warm queries across 20 iterations: zero S3 GETs
  let gets_after_first_query = sim.cost().s3_gets
  for _ in 0..<20 {
    let r1 = @query.bm25_search(qn, "alpha", 5, None)
    let r2 = @query.bm25_search(qn, "beta", 5, None)
    let _ = lookup_doc_attrs(store, ns, qn, r1[0].id)
    let _ = lookup_doc_attrs(store, ns, qn, r2[0].id)
  }
  assert_eq(sim.cost().s3_gets, gets_after_first_query)
}

///|
test "cmd/serve: 3-tier coordinator and worker pool cache dispatching" {
  reset_coordinator_for_test()
  let sim_cfg = @simstore.SimConfig::aws_default(999U)
  let sim = @simstore.SimStore::new(sim_cfg)
  let store : AnyStore = Sim(sim)
  let ns = "test_serve_3tier"
  let dim = 4

  let cfg = @build.BuildConfig::single_copy(ns)
  let docs : Array[@core.Doc] = [
    {
      id: 100UL,
      text: "distributed query worker tier",
      vector: [1.0, 0.0, 0.0, 0.0],
      category: "worker",
      ts: 1000L,
      public: true,
    },
    {
      id: 200UL,
      text: "authoritative coordinator metadata",
      vector: [0.0, 1.0, 0.0, 0.0],
      category: "coordinator",
      ts: 2000L,
      public: true,
    },
  ]
  @build.ingest(store, { ..cfg, vector_dim: dim }, docs)

  let coord = get_coordinator(store)
  let state = get_or_load_ns_state(store, ns)
  let qn = state.get_query_ns(store, ns)

  // Verify coordinator registered tenant
  let tenant = coord.get_tenant(ns)
  assert_eq(tenant is Some(_), true)

  let qv : Array[Float] = [1.0, 0.0, 0.0, 0.0]
  let res1 = coord.dispatch_vector_query(ns, qn, qv, 5, 8, None)
  let worker = coord.select_worker(ns)
  let (hits1, _, _, _, bytes1) = worker.cache.stats()
  assert_eq(res1.length() >= 1, true)
  assert_eq(res1[0].id, 100UL)
  assert_eq(bytes1 > 0, true)

  // Warm vector query through coordinator: hits worker 5-min cache
  let res2 = coord.dispatch_vector_query(ns, qn, qv, 5, 8, None)
  assert_eq(res2.length() >= 1, true)
  assert_eq(res2[0].id, 100UL)
  let (hits2, _, _, _, _) = worker.cache.stats()
  assert_eq(hits2 > hits1, true)

  // Dispatch BM25 and Hybrid queries through coordinator
  let res_bm25 = coord.dispatch_bm25_query(ns, qn, "distributed", 5, None)
  assert_eq(res_bm25.length() >= 1, true)
  assert_eq(res_bm25[0].id, 100UL)

  let res_hybrid = coord.dispatch_hybrid_query(ns, qn, "distributed", qv, 5, 8, None, None)
  assert_eq(res_hybrid.length() >= 1, true)
  assert_eq(res_hybrid[0].id, 100UL)
}
