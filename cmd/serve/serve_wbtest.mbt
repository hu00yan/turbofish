// cmd/serve 单元与集成白盒测试：
// 1) 存储可插拔：fs:PATH、sim (SimStore) 与 AnyStore 委托验证；
// 2) 写路径只有 build 一套；后台按脏 namespace 队列做 build 段合并；
// 3) 查询富化：返回 payload contract 中的 text, category, ts, public；
// 4) 内存 LRU 缓存上限与淘汰。

///|
test "cmd/serve: AnyStore with SimStore pluggability" {
  let sim_cfg = @simstore.SimConfig::aws_default(42U)
  let sim = @simstore.SimStore::new(sim_cfg)
  let store : AnyStore = Sim(sim)

  // 验证 ObjectStore 基本操作
  @store.ObjectStore::put(store, "test/key1", @utf8.encode("value1"))
  let read_val = @store.ObjectStore::get(store, "test/key1")
  assert_eq(read_val is Some(_), true)
  assert_eq(@utf8.decode(read_val.unwrap().exact_view()) catch { _ => "" }, "value1")

  // 验证 CAS put_if_match
  let cas_ok = @store.ObjectStore::put_if_match(
    store,
    "test/cas",
    None,
    @utf8.encode("init"),
  )
  assert_eq(cas_ok, true)

  // 批量读必须与逐个 get 同长同序；缺失 key 保持 None 原下标。
  @store.ObjectStore::put(store, "test/key2", @utf8.encode("value2"))
  let keys : Array[String] = ["test/key2", "test/missing", "test/key1"]
  let got = @store.ObjectStore::get_many(store, keys)
  assert_eq(got.length(), 3)
  assert_eq(@utf8.decode(got[0].unwrap().exact_view()) catch { _ => "" }, "value2")
  assert_eq(got[1] is None, true)
  assert_eq(@utf8.decode(got[2].unwrap().exact_view()) catch { _ => "" }, "value1")
}

///|
test "cmd/serve: LRU caches evict by entry and weight caps" {
  let cache : LruCache[Int] = LruCache::new(2, 0, fn(_v : Int) -> Int { 1 })
  cache.set("a", 1)
  cache.set("b", 2)
  // 触达 a，使 b 成为最久未使用
  assert_eq(cache.get("a"), Some(1))
  cache.set("c", 3)
  assert_eq(cache.length(), 2)
  assert_eq(cache.get("b"), None)
  assert_eq(cache.get("a"), Some(1))
  assert_eq(cache.get("c"), Some(3))

  // 权重上限：x=3 + y=3 超过 max_weight=5，淘汰 x
  let weighted : LruCache[Int] = LruCache::new(
    10,
    5,
    fn(v : Int) -> Int { v },
  )
  weighted.set("x", 3)
  weighted.set("y", 3)
  assert_eq(weighted.get("x"), None)
  assert_eq(weighted.get("y"), Some(3))
  assert_eq(weighted.total_weight, 3)
}

///|
test "cmd/serve: namespace state has no write engine and reads stay on build segments" {
  let sim_cfg = @simstore.SimConfig::aws_default(801U)
  let sim = @simstore.SimStore::new(sim_cfg)
  let store : AnyStore = Sim(sim)
  let ns = "test_serve_build_only"
  let dim = 4

  // 只读入口 / 状态创建不应访问 store，也不应初始化 mtree 写引擎。
  let state = get_or_create_ns_state(store, ns, dim)
  assert_eq(state.query_ns is None, true)
  assert_eq(sim.cost().s3_gets, 0)

  let cfg = @build.BuildConfig::single_copy(ns)
  let docs : Array[@core.Doc] = [
    {
      id: 1UL,
      text: "single build write path",
      vector: [1.0, 0.0, 0.0, 0.0],
      category: "build",
      ts: 100L,
      public: true,
    },
  ]
  @build.ingest(store, { ..cfg, vector_dim: dim }, docs)
  let head = match @store.read_head_pointer(store, ns) {
    Some(h) => h
    None => @store.read_head(store, ns, "")
  }
  state.update_after_write(store, ns, head)

  let qn = state.get_query_ns(store, ns)
  assert_eq(qn.manifest.id, head)
  let hits = @query.bm25_search(qn, "build", 5, None)
  assert_eq(hits.length(), 1)
  assert_eq(hits[0].id, 1UL)
  let attrs = lookup_doc_attrs(store, ns, qn, 1UL)
  assert_eq(attrs.category, "build")
  // 没有 mtree compact part 对象：写入只有 build 一套。
  assert_eq(store.list("\{ns}/_parts/").length(), 0)

  // 冷启动读另一个 namespace：同样不应产生 _parts。
  let ns2 = "test_serve_build_only_read"
  @build.ingest(store, { ..@build.BuildConfig::single_copy(ns2), vector_dim: dim }, [
    {
      id: 2UL,
      text: "read only path",
      vector: [0.0, 1.0, 0.0, 0.0],
      category: "query",
      ts: 200L,
      public: true,
    },
  ])
  let state2 = get_or_load_ns_state(store, ns2)
  let qn2 = state2.get_query_ns(store, ns2)
  assert_eq(@query.count_docs(qn2, None), 1)
  assert_eq(store.list("\{ns2}/_parts/").length(), 0)

  // patch / delete 也都收敛到 build 一套，不再产生 mtree 对象。
  let patches : Array[RowPatch] = [
    {
      id: 1UL,
      text: None,
      category: Some("patched"),
      ts: None,
      public: None,
    },
  ]
  let (patched, _) = patch_rows_core(store, ns, patches)
  assert_eq(patched, 1)
  assert_eq(store.list("\{ns}/_parts/").length(), 0)
  let deleted = delete_by_filter_core(
    store,
    ns,
    @query.Eq("category", @query.S("patched")),
  )
  assert_eq(deleted, 1)
  assert_eq(store.list("\{ns}/_parts/").length(), 0)
}

///|
test "cmd/serve: build segment compaction preserves query results" {
  let sim_cfg = @simstore.SimConfig::aws_default(802U)
  let sim = @simstore.SimStore::new(sim_cfg)
  let store : AnyStore = Sim(sim)
  let ns = "test_serve_compact_segments"
  let dim = 4
  let cfg = { ..@build.BuildConfig::single_copy(ns), vector_dim: dim, segment_rows: 1 }

  let batch1 : Array[@core.Doc] = [
    {
      id: 10UL,
      text: "alpha compact doc",
      vector: [1.0, 0.0, 0.0, 0.0],
      category: "alpha",
      ts: 10L,
      public: true,
    },
    {
      id: 11UL,
      text: "beta compact doc",
      vector: [0.0, 1.0, 0.0, 0.0],
      category: "beta",
      ts: 11L,
      public: false,
    },
  ]
  @build.ingest(store, cfg, batch1)
  let batch2 : Array[@core.Doc] = [
    {
      id: 12UL,
      text: "gamma compact doc",
      vector: [0.0, 0.0, 1.0, 0.0],
      category: "gamma",
      ts: 12L,
      public: true,
    },
  ]
  @build.ingest_delta_opts(store, cfg, batch2, 8, false)

  let before = @query.open(store, ns)
  assert_eq(before.manifest.segments.length() >= 2, true)
  assert_eq(@query.count_docs(before, None), 3)
  let hits_before = @query.bm25_search(before, "compact", 10, None)
  assert_eq(hits_before.length(), 3)
  let attrs_before = lookup_doc_attrs(store, ns, before, 11UL)

  @build.compact(store, cfg, ns)
  let after = @query.open(store, ns)
  assert_eq(after.manifest.segments.length(), 1)
  assert_eq(@query.count_docs(after, None), 3)
  let hits_after = @query.bm25_search(after, "compact", 10, None)
  assert_eq(hits_after.length(), 3)
  let attrs_after = lookup_doc_attrs(store, ns, after, 11UL)
  assert_eq(attrs_after.text, attrs_before.text)
  assert_eq(attrs_after.category, attrs_before.category)
  assert_eq(attrs_after.ts, attrs_before.ts)
  assert_eq(attrs_after.public, attrs_before.public)
}

///|
test "cmd/serve: compact prunes caches for merged-away segments" {
  let sim_cfg = @simstore.SimConfig::aws_default(803U)
  let sim = @simstore.SimStore::new(sim_cfg)
  let store : AnyStore = Sim(sim)
  let ns = "test_serve_compact_cache_prune"
  let dim = 4
  let cfg = { ..@build.BuildConfig::single_copy(ns), vector_dim: dim, segment_rows: 1 }
  let batch1 : Array[@core.Doc] = [
    {
      id: 1UL,
      text: "alpha",
      vector: [1.0, 0.0, 0.0, 0.0],
      category: "a",
      ts: 1L,
      public: true,
    },
  ]
  let batch2 : Array[@core.Doc] = [
    {
      id: 2UL,
      text: "beta",
      vector: [0.0, 1.0, 0.0, 0.0],
      category: "b",
      ts: 2L,
      public: true,
    },
  ]
  @build.ingest(store, cfg, batch1)
  @build.ingest_delta_opts(store, cfg, batch2, 8, false)
  let state = get_or_load_ns_state(store, ns)
  let before = state.get_query_ns(store, ns)
  assert_eq(before.manifest.segments.length(), 2)
  assert_eq(before.cache.length(), 2)
  compact_namespace_state(store, state, ns)
  let after = state.get_query_ns(store, ns)
  assert_eq(after.manifest.segments.length(), 1)
  assert_eq(after.cache.length(), 1)
  assert_eq(after.cache.contains(after.manifest.segments[0].id), true)
}

///|
test "cmd/serve: compact trigger uses segment/deleted/idle thresholds" {
  let sim_cfg = @simstore.SimConfig::aws_default(803U)
  let sim = @simstore.SimStore::new(sim_cfg)
  let store : AnyStore = Sim(sim)
  let state = get_or_create_ns_state(store, "test_serve_trigger", 4)
  let settings : CompactSettings = {
    interval_ms: 1000L,
    max_per_tick: 8,
    seg_threshold: 8,
    delete_ratio: 0.2,
    idle_ms: 30000L,
    max_rows: 5000000,
  }
  state.last_write_ms = 1000L
  state.manifest_num_docs = 100
  state.live_segments = 9
  assert_eq(should_compact(state, settings, 1000L), true)

  state.live_segments = 2
  state.manifest_deleted = 25
  assert_eq(should_compact(state, settings, 1000L), true)

  state.manifest_deleted = 0
  assert_eq(should_compact(state, settings, 2000L), false)
  assert_eq(should_compact(state, settings, 32000L), true)

  // 只有 1 段：永远不需要合并。
  state.live_segments = 1
  assert_eq(should_compact(state, settings, 32000L), false)
}

///|
test "cmd/serve: background compactor only processes dirty namespaces" {
  reset_dirty_for_test()
  let sim_cfg = @simstore.SimConfig::aws_default(804U)
  let sim = @simstore.SimStore::new(sim_cfg)
  let store : AnyStore = Sim(sim)
  let ns = "test_serve_dirty_compact"
  let dim = 4
  let cfg = { ..@build.BuildConfig::single_copy(ns), vector_dim: dim, segment_rows: 1 }
  let docs : Array[@core.Doc] = [
    {
      id: 1UL,
      text: "dirty one",
      vector: [1.0, 0.0, 0.0, 0.0],
      category: "dirty",
      ts: 1L,
      public: true,
    },
    {
      id: 2UL,
      text: "dirty two",
      vector: [0.0, 1.0, 0.0, 0.0],
      category: "dirty",
      ts: 2L,
      public: true,
    },
    {
      id: 3UL,
      text: "dirty three",
      vector: [0.0, 0.0, 1.0, 0.0],
      category: "dirty",
      ts: 3L,
      public: true,
    },
  ]
  @build.ingest(store, cfg, docs)

  let state = get_or_create_ns_state(store, ns, dim)
  let head = match @store.read_head_pointer(store, ns) {
    Some(h) => h
    None => @store.read_head(store, ns, "")
  }
  state.update_after_write(store, ns, head)
  assert_eq(state.live_segments, 3)
  mark_namespace_dirty(ns)

  let settings : CompactSettings = {
    interval_ms: 1000L,
    max_per_tick: 8,
    seg_threshold: 2,
    delete_ratio: 0.2,
    idle_ms: 30000L,
    max_rows: 5000000,
  }
  let processed = compact_dirty_once(store, @async.now(), settings)
  assert_eq(processed, 1)
  assert_eq(state.live_segments, 1)
  let after = @query.open(store, ns)
  assert_eq(@query.count_docs(after, None), 3)
  assert_eq(@query.bm25_search(after, "dirty", 10, None).length(), 3)
  // 队列已空：不再扫描所有 active_ns。
  assert_eq(compact_dirty_once(store, @async.now(), settings), 0)
  reset_dirty_for_test()
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

  // tombstone 行仍在 segment 里，但 lookup 必须返回 None，不能被 patch 复活。
  assert_eq(lookup_doc_full(store, ns, n_after, 1UL) is None, true)
  assert_eq(lookup_doc_attrs(store, ns, n_after, 1UL).text, "")
  let patch_deleted : Array[RowPatch] = [
    {
      id: 1UL,
      text: Some("revived"),
      category: None,
      ts: None,
      public: None,
    },
  ]
  let revived = try {
    let _ = patch_rows_core(store, ns, patch_deleted)
    false
  } catch {
    @core.NotFound(_) => true
    _ => false
  }
  assert_eq(revived, true)
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
    state.doc_cache.set(d.id.to_string(), { text: d.text, category: d.category, ts: d.ts, public: d.public })
    state.doc_full_cache.set(d.id.to_string(), d)
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
  // Zero additional S3 GETs
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
