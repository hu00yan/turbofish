// v1 过滤/度量/混合参数 白盒测试。复用 query_wbtest.mbt 的 fixture：
// make_test_store（mini namespace：6 docs、2 段、dim=2、centroids c0=[10,0] c1=[0,10]）。
// 数据备忘：
//   id 1: text "the quick brown fox" category a  ts 100 public T  vec [10.1, 0.2]
//   id 2: text "the lazy dog sleeps" category b  ts 200 public F  vec [9.8, -0.3]
//   id 3: text "fox and fox run"     category a  ts 300 public F  vec [0.4, 9.5]
//   id 4: text "猫追狗"               category c  ts 400 public T  vec [0.1, 10.2]
//   id 5: text "the fox"             category a  ts 500 public T  vec [9.5, 0.5]
//   id 6: text "狗 追 猫"             category c  ts 600 public F  vec [-0.2, 9.9]

///|
/// euclidean 度量的同构 fixture（仅 namespace.json 的 distance_metric 不同）。
async fn make_test_store_euclid() -> @store.MemStore {
  let s = make_test_store([])
  let meta : @format.NamespaceMeta = {
    format: "seekpond/v1",
    ns_name: "test",
    head_manifest: "manifest-01",
    vec_global_version: None,
    distance_metric: "euclidean",
    vector_dim: 2,
    vector_dtype: "f32",
    k1: 1.2,
    b: 0.75,
    fts_tokenizer: None,
  }
  tput(
    s,
    "test/_meta/namespace.json",
    @utf8.encode(meta.to_json().stringify()),
  )
  s
}

///|
async test "v1 filter tree: And/Or/Not/Neq/In/NotIn/range on bm25" {
  let n = open(make_test_store([]), "test")
  // "the" 命中 {1,2,5}
  // And(Eq(category,a), Gte(ts,500)) → 5
  assert_eq(
    ids_of(
      bm25_search(
        n,
        "the",
        10,
        Some(
          And([Eq("category", S("a")), Gte("ts", I(500L))]),
        ),
      ),
    ),
    [5UL],
  )
  // Or(Eq(category,b), Gt(ts,450)) 于 "the" → 2(cat b), 5(ts 500) → {2,5}
  let or_ids = ids_of(
    bm25_search(
      n,
      "the",
      10,
      Some(Or([Eq("category", S("b")), Gt("ts", I(450L))])),
    ),
  )
  assert_eq(or_ids.length(), 2)
  assert_eq(or_ids.contains(2UL), true)
  assert_eq(or_ids.contains(5UL), true)
  // Not(Eq(category,a)) 于 "the" → 去掉 1、5 → {2}
  assert_eq(
    ids_of(bm25_search(n, "the", 10, Some(Not(Eq("category", S("a")))))),
    [2UL],
  )
  // Neq 等价 Not(Eq)
  assert_eq(
    ids_of(bm25_search(n, "the", 10, Some(Neq("category", S("a"))))),
    [2UL],
  )
  // "the" + In(category,[b,c]) → {2}
  assert_eq(
    ids_of(bm25_search(n, "the", 10, Some(In("category", [S("b"), S("c")])))),
    [2UL],
  )
  // NotIn(category,[a]) 于 "the" → {2}
  assert_eq(
    ids_of(bm25_search(n, "the", 10, Some(NotIn("category", [S("a")])))),
    [2UL],
  )
  // Lte(ts,400) 于 "fox" → {3,1}（5 ts=500 被去掉；id3 tf=2 排前）
  assert_eq(
    ids_of(bm25_search(n, "fox", 10, Some(Lte("ts", I(400L))))),
    [3UL, 1UL],
  )
  // string 范围：Gt(category,"a") 于 "fox"（cat 全 a）→ 空
  assert_eq(
    ids_of(bm25_search(n, "fox", 10, Some(Gt("category", S("a"))))),
    [],
  )
  // 空 In 恒 false
  assert_eq(ids_of(bm25_search(n, "the", 10, Some(In("category", [])))), [])
}

///|
async test "v1 count_docs: unfiltered / filtered / tombstoned" {
  let n = open(make_test_store([]), "test")
  assert_eq(count_docs(n, None), 6)
  assert_eq(count_docs(n, Some(Eq("category", S("a")))), 3) // 1, 3, 5
  assert_eq(
    count_docs(n, Some(And([Gte("ts", I(200L)), Lte("ts", I(500L))]))),
    4, // 2, 3, 4, 5
  )
  // 组合：Not + 范围
  assert_eq(
    count_docs(n, Some(Not(Lt("ts", I(300L))))),
    4, // ts >= 300: 3, 4, 5, 6
  )
  // tombstone：id 1 删除后
  let nt = open(make_test_store([1UL]), "test")
  assert_eq(count_docs(nt, None), 5)
  assert_eq(count_docs(nt, Some(Eq("category", S("a")))), 2) // 只剩 3, 5
}

///|
async test "v1 seg_may_match: tree pruning" {
  let j = @utf8.encode(
    (
      #|{"id":"s","row_count":10,"min_id":1,"max_id":10,"partitions":[0],
      #| "stats":{"ts":{"min":100,"max":200},
      #|          "category":{"values":["a","b"]},
      #|          "public":{"values":[false,true]}}}
    ),
  )
  let info = parse_seg_meta(j)
  let stats = match info.stats {
    Some(s) => s
    None => fail("stats missing")
  }
  let cs : CachedSeg = {
    row_count: 10,
    partitions: [0],
    min_id: 1UL,
    id_dense: true,
    vec_storage: "",
    vec_normalized: false,
    stats: Some(stats),
    bloom: None,
    dir: None,
    doc_len: None,
    ids: None,
    blockmax: None,
    blockmax_size: 128,
    blockmax_tried: false,
    pq_m: 0,
    pq_dsub: 0,
    pq_codebook: None,
    vec_info: None,
    block_stats: None,
    block_stats_tried: false,
    slab_index: None,
    slab_tried: false,
    seg_seq: -1,
    matchers: Map([]),
    vec_parts: Map([]),
  }
  // ts 范围
  assert_eq(seg_may_match(cs, Some(Gt("ts", I(150L)))), true)
  assert_eq(seg_may_match(cs, Some(Gt("ts", I(200L)))), false)
  assert_eq(seg_may_match(cs, Some(Lte("ts", I(100L)))), true)
  assert_eq(seg_may_match(cs, Some(Lte("ts", I(99L)))), false)
  // string 范围（term_compare 字节序）
  assert_eq(seg_may_match(cs, Some(Gt("category", S("a")))), true) // b > a
  assert_eq(seg_may_match(cs, Some(Gt("category", S("b")))), false)
  assert_eq(seg_may_match(cs, Some(Lte("category", S("a")))), true)
  // In / NotIn / Neq / Not（保守）
  assert_eq(
    seg_may_match(cs, Some(In("category", [S("z"), S("b")]))),
    true,
  )
  assert_eq(
    seg_may_match(cs, Some(In("category", [S("x"), S("y")]))),
    false,
  )
  assert_eq(seg_may_match(cs, Some(In("ts", [I(50L), I(300L)]))), false)
  assert_eq(seg_may_match(cs, Some(In("ts", [I(150L)]))), true)
  assert_eq(seg_may_match(cs, Some(NotIn("category", [S("a")]))), true)
  assert_eq(seg_may_match(cs, Some(Neq("category", S("a")))), true)
  assert_eq(seg_may_match(cs, Some(Not(f_str("category", "z")))), true)
  // 组合
  assert_eq(
    seg_may_match(cs, Some(And([f_str("category", "a"), Gt("ts", I(300L))]))),
    false,
  )
  assert_eq(
    seg_may_match(cs, Some(Or([f_str("category", "z"), Gt("ts", I(150L))]))),
    true,
  )
  assert_eq(
    seg_may_match(cs, Some(Or([f_str("category", "z"), f_str("category", "q")]))),
    false,
  )
}

///|
async test "v1 matcher: set / cmp / composition semantics" {
  // MDictSet：codes [0,1,0]，目标 {1}
  let md : RowMatcher = MDictSet(
    [(0).to_uint16(), (1).to_uint16(), (0).to_uint16()],
    Set([(1).to_uint16()]),
  )
  assert_eq(matcher_at(md, 0), false)
  assert_eq(matcher_at(md, 1), true)
  assert_eq(matcher_at(md, 2), false)
  // MI64Cmp
  let mc : RowMatcher = MI64Cmp([10L, 20L, 30L], CMP_GT, 15L)
  assert_eq(matcher_at(mc, 0), false)
  assert_eq(matcher_at(mc, 1), true)
  assert_eq(matcher_at(mc, 2), true)
  // MStrCmp：字节序 "ab" < "b"
  let ms : RowMatcher = MStrCmp(["a", "b", "ab"], CMP_GTE, "b")
  assert_eq(matcher_at(ms, 1), true)
  assert_eq(matcher_at(ms, 2), false)
  // 组合：And/Or/Not（MOr 空 = false，MAnd 空 = true）
  let t : RowMatcher = MAnd([])
  let f : RowMatcher = MOr([])
  assert_eq(matcher_at(t, 0), true)
  assert_eq(matcher_at(f, 0), false)
  assert_eq(matcher_at(MNot(mc), 0), true)
  assert_eq(
    matcher_at(MAnd([mc, MNot(MI64Cmp([10L, 20L, 30L], CMP_LT, 25L))]), 1),
    false, // 20 > 15 且 !(20 < 25) → false
  )
  // MStrSet / MI64Set
  let ss : RowMatcher = MStrSet(["x", "y", "z"], Set(["y", "z"]))
  assert_eq(matcher_at(ss, 0), false)
  assert_eq(matcher_at(ss, 1), true)
  let iset : RowMatcher = MI64Set([1L, 2L, 3L], Set([2L]))
  assert_eq(matcher_at(iset, 1), true)
  assert_eq(matcher_at(iset, 2), false)
}

///|
async test "v1 hybrid opts: weights degenerate to single list; rrf compat" {
  let n = open(make_test_store([]), "test")
  let qv : Array[Float] = [10.0, 0.0]
  let bm = bm25_search(n, "the", 3, None) // {1,2,5}
  let vs = vec_search(n, qv, 3, 2, None)
  // 权重退化：只看向量路
  let h_vec = hybrid_search_opts(
    n,
    "the",
    qv,
    3,
    2,
    None,
    { rank_constant: 60.0, fusion: "rrf", weight_bm25: 0.0, weight_vec: 1.0 },
  )
  assert_eq(ids_of(h_vec), ids_of(vs))
  // 只看 BM25 路
  let h_bm = hybrid_search_opts(
    n,
    "the",
    qv,
    3,
    2,
    None,
    { rank_constant: 60.0, fusion: "rrf", weight_bm25: 1.0, weight_vec: 0.0 },
  )
  assert_eq(ids_of(h_bm), ids_of(bm))
  // linear 融合的单路退化 = 该路排序
  let h_lin = hybrid_search_opts(
    n,
    "the",
    qv,
    3,
    2,
    None,
    { rank_constant: 60.0, fusion: "linear", weight_bm25: 0.0, weight_vec: 1.0 },
  )
  assert_eq(ids_of(h_lin), ids_of(vs))
  // 默认 opts 与旧 hybrid_search 行为一致
  let h_old = hybrid_search(n, "the", qv, 3, 2, None)
  let h_def = hybrid_search_opts(n, "the", qv, 3, 2, None, HybridOpts::default())
  assert_eq(ids_of(h_old), ids_of(h_def))
  // rank_constant 变化只改分值不改 RRF 的合并集合（两路并集取 top-3）
  let h_k1 = hybrid_search_opts(
    n,
    "the",
    qv,
    3,
    2,
    None,
    { rank_constant: 1.0, fusion: "rrf", weight_bm25: 1.0, weight_vec: 1.0 },
  )
  let ids1 : Set[UInt64] = Set([])
  for r in h_k1 {
    ids1.add(r.id)
  }
  let union : Set[UInt64] = Set([])
  for r in bm {
    union.add(r.id)
  }
  for r in vs {
    union.add(r.id)
  }
  for r in h_k1 {
    assert_eq(union.contains(r.id), true)
  }
  assert_eq(h_k1.length(), 3)
}

///|
async test "v1 euclidean metric: scoring and brute-force parity" {
  let n = open(make_test_store_euclid(), "test")
  let qv : Array[Float] = [10.0, 0.0]
  let rs = vec_search(n, qv, 10, 2, None)
  // 最近 = id1（[10.1,0.2]，l2sq = 0.05），score = -0.05（cosine 口径会是 ~1.0）
  assert_eq(rs[0].id, 1UL)
  assert_eq(approx(rs[0].score, -0.05, 1.0e-6), true)
  // nprobe=all == 暴力 l2sq 排序：id1(0.05) < id2(0.13) < id5(0.5) < c1 簇
  assert_eq(rs[1].id, 2UL)
  assert_eq(approx(rs[1].score, -0.13, 1.0e-6), true)
  assert_eq(rs[2].id, 5UL)
  assert_eq(approx(rs[2].score, -0.5, 1.0e-6), true)
  // 过滤后：Gte(ts,400) → 只有 id4/id6/id5... 实际命中 {4,5,6}，欧氏最近 5
  let rf = vec_search(n, qv, 10, 2, Some(Gte("ts", I(400L))))
  assert_eq(rf[0].id, 5UL)
}

///|
/// glob_match 单元测试：* / ? / 边界 / 混合。
async test "v1 glob_match unit" {
  // 精确匹配（无通配符）
  assert_eq(glob_match("hello", "hello"), true)
  assert_eq(glob_match("hello", "world"), false)
  assert_eq(glob_match("", ""), true)
  // * 匹配任意长度
  assert_eq(glob_match("hello", "*"), true)
  assert_eq(glob_match("", "*"), true)
  assert_eq(glob_match("abc", "a*"), true)
  assert_eq(glob_match("abc", "a*c"), true)
  assert_eq(glob_match("abXYZc", "a*c"), true)
  assert_eq(glob_match("ac", "a*c"), true)
  assert_eq(glob_match("abc", "*c"), true)
  assert_eq(glob_match("abc", "d*"), false)
  // ? 恰好匹配一个字符
  assert_eq(glob_match("a", "?"), true)
  assert_eq(glob_match("", "?"), false)
  assert_eq(glob_match("ab", "?"), false)
  assert_eq(glob_match("ab", "??"), true)
  assert_eq(glob_match("abc", "a?c"), true)
  assert_eq(glob_match("axc", "a?c"), true)
  assert_eq(glob_match("ac", "a?c"), false)
  // 混合
  assert_eq(glob_match("the quick brown fox", "the*fox"), true)
  assert_eq(glob_match("the fox", "the?fox"), true)
  assert_eq(glob_match("the fox", "the??fox"), false)
  assert_eq(glob_match("fox and fox run", "fox*"), true)
  assert_eq(glob_match("cat", "*at"), true)
  assert_eq(glob_match("cat", "*dog"), false)
  // 多 *
  assert_eq(glob_match("abcdef", "a*c*f"), true)
  assert_eq(glob_match("abcdef", "a*d*g"), false)
  assert_eq(glob_match("", "***"), true)
}

///|
/// Glob 过滤在 bm25_search 和 count_docs 路径均工作。
async test "v1 Glob filter: basic wildcard matching" {
  let n = open(make_test_store([]), "test")
  // category 字段：a a b a c c（id 顺序 1~6）
  // Glob(category, "a") 精确 → ids {1,3,5}
  let r_exact = ids_of(bm25_search(n, "fox", 10, Some(Glob("category", "a"))))
  // "fox" 命中 {1,3,5}，全部 category=a → {3,5,1}（按 BM25 分排序）
  assert_eq(r_exact.length(), 3)
  assert_eq(r_exact.contains(1UL), true)
  assert_eq(r_exact.contains(3UL), true)
  assert_eq(r_exact.contains(5UL), true)

  // Glob(category, "*") 匹配所有 → "fox" 命中 {1,3,5}（全命中）
  let r_star = ids_of(bm25_search(n, "fox", 10, Some(Glob("category", "*"))))
  assert_eq(r_star.length(), 3)

  // Glob(category, "?") 匹配任意单字符 → 所有 category 都是单字符 (a/b/c)
  // 对 "fox" 结果集 {1,3,5}：全部 category=a（单字符）→ 仍 3 个
  let r_q = ids_of(bm25_search(n, "fox", 10, Some(Glob("category", "?"))))
  assert_eq(r_q.length(), 3)

  // Glob(category, "b*") 匹配 "b..." → 只有 id2（category=b）
  // "the" 命中 {1,2,5}，category b 只有 id2
  let r_b = ids_of(bm25_search(n, "the", 10, Some(Glob("category", "b*"))))
  assert_eq(r_b, [2UL])

  // Glob(category, "z*") 无匹配
  let r_z = ids_of(bm25_search(n, "the", 10, Some(Glob("category", "z*"))))
  assert_eq(r_z, [])
}

///|
/// Glob 匹配 text 字段（非 dict 列）。
async test "v1 Glob filter: text field wildcards" {
  let n = open(make_test_store([]), "test")
  // text "the quick brown fox" - Glob 匹配 "the*fox"
  // 通过 count_docs 验证：满足 Glob(text, "the*fox") 的文档
  //   id1: "the quick brown fox" → 匹配
  //   id5: "the fox" → 匹配（the* 然后 fox）
  //   其余不匹配
  let cnt_the_fox = count_docs(n, Some(Glob("text", "the*fox")))
  assert_eq(cnt_the_fox, 2) // id1, id5

  // Glob(text, "*fox*") 包含 fox 的文档：id1("the quick brown fox"), id3("fox and fox run"), id5("the fox")
  let cnt_fox = count_docs(n, Some(Glob("text", "*fox*")))
  assert_eq(cnt_fox, 3) // id1, id3, id5

  // Glob(text, "猫?狗") 匹配 "猫追狗"（? 匹配 追）→ id4
  let cnt_cat = count_docs(n, Some(Glob("text", "猫?狗")))
  assert_eq(cnt_cat, 1) // id4

  // Glob(text, "*猫*") → id4("猫追狗") 和 id6("狗 追 猫")
  let cnt_cat2 = count_docs(n, Some(Glob("text", "*猫*")))
  assert_eq(cnt_cat2, 2) // id4, id6
}

///|
/// Glob 与 tombstone 配合：被删文档不出现在 count/matching_ids 结果中。
async test "v1 Glob filter: tombstone exclusion" {
  // id1 被删除
  let nt = open(make_test_store([1UL]), "test")
  // 未删时 Glob(category, "a") count = 3（id1,3,5）；删 id1 后 = 2
  assert_eq(count_docs(nt, Some(Glob("category", "a"))), 2)
  let ids = matching_ids(nt, Glob("category", "a"))
  assert_eq(ids.contains(1UL), false)
  assert_eq(ids.contains(3UL), true)
  assert_eq(ids.contains(5UL), true)
}

///|
/// Glob 组合：And/Or 嵌套。
async test "v1 Glob filter: composition with And/Or" {
  let n = open(make_test_store([]), "test")
  // And(Glob(category,a*), Gte(ts,300)) → category=a 且 ts>=300 → id3(ts300), id5(ts500)
  let cnt_and = count_docs(
    n,
    Some(And([Glob("category", "a*"), Gte("ts", I(300L))])),
  )
  assert_eq(cnt_and, 2) // id3, id5

  // Or(Glob(category,b*), Glob(category,c*)) → category=b 或 c → id2,id4,id6
  let cnt_or = count_docs(
    n,
    Some(Or([Glob("category", "b*"), Glob("category", "c*")])),
  )
  assert_eq(cnt_or, 3) // id2, id4, id6

  // Not(Glob(category,a)) → category != "a" → id2,id4,id6 (3 docs)
  let cnt_not = count_docs(n, Some(Not(Glob("category", "a"))))
  assert_eq(cnt_not, 3)
}

///|
/// sum_field: ts 字段求和。
async test "v1 sum_field: ts sum without filter" {
  let n = open(make_test_store([]), "test")
  // ts = [100,200,300,400,500,600]，和 = 2100
  let s = sum_field(n, "ts", None)
  assert_eq(approx(s, 2100.0, 1.0e-9), true)
}

///|
/// sum_field: 带 filter 求和。
async test "v1 sum_field: ts sum with filter" {
  let n = open(make_test_store([]), "test")
  // category=a → id1(ts100), id3(ts300), id5(ts500) → 900
  let s_a = sum_field(n, "ts", Some(Eq("category", S("a"))))
  assert_eq(approx(s_a, 900.0, 1.0e-9), true)

  // Gte(ts,400) → id4(400),id5(500),id6(600) → 1500
  let s_gte = sum_field(n, "ts", Some(Gte("ts", I(400L))))
  assert_eq(approx(s_gte, 1500.0, 1.0e-9), true)

  // In(category, [b,c]) → id2(200),id4(400),id6(600) → 1200
  let s_in = sum_field(n, "ts", Some(In("category", [S("b"), S("c")])))
  assert_eq(approx(s_in, 1200.0, 1.0e-9), true)

  // Glob(category, "a") → same as Eq(category,a) → 900
  let s_glob = sum_field(n, "ts", Some(Glob("category", "a")))
  assert_eq(approx(s_glob, 900.0, 1.0e-9), true)

  // And(Gte(ts,200), Lte(ts,400)) → id2(200),id3(300),id4(400) → 900
  let s_range = sum_field(
    n,
    "ts",
    Some(And([Gte("ts", I(200L)), Lte("ts", I(400L))])),
  )
  assert_eq(approx(s_range, 900.0, 1.0e-9), true)
}

///|
/// sum_field: tombstone 被排除。
async test "v1 sum_field: tombstone excluded" {
  // 删除 id1(ts=100) 和 id4(ts=400)
  let nt = open(make_test_store([1UL, 4UL]), "test")
  // 全部存活 sum = 2100 - 100 - 400 = 1600
  let s = sum_field(nt, "ts", None)
  assert_eq(approx(s, 1600.0, 1.0e-9), true)

  // filter category=a + tombstone(id1) → id3(300)+id5(500) = 800
  let s_a = sum_field(nt, "ts", Some(Eq("category", S("a"))))
  assert_eq(approx(s_a, 800.0, 1.0e-9), true)
}

///|
/// sum_field: 空结果集返回 0。
async test "v1 sum_field: empty result" {
  let n = open(make_test_store([]), "test")
  // 不存在的 category → sum = 0
  let s = sum_field(n, "ts", Some(Eq("category", S("zzz"))))
  assert_eq(approx(s, 0.0, 1.0e-9), true)
}

///|
/// matching_ids: 基本行为。
async test "v1 matching_ids: basic" {
  let n = open(make_test_store([]), "test")
  // Eq(category, a) → {1,3,5}
  let ids_a = matching_ids(n, Eq("category", S("a")))
  ids_a.sort()
  assert_eq(ids_a, [1UL, 3UL, 5UL])

  // Eq(category, c) → {4,6}
  let ids_c = matching_ids(n, Eq("category", S("c")))
  ids_c.sort()
  assert_eq(ids_c, [4UL, 6UL])

  // Gte(ts, 500) → {5,6}
  let ids_gte = matching_ids(n, Gte("ts", I(500L)))
  ids_gte.sort()
  assert_eq(ids_gte, [5UL, 6UL])

  // Glob(category, "*") → all 6 ids
  let ids_all = matching_ids(n, Glob("category", "*"))
  ids_all.sort()
  assert_eq(ids_all, [1UL, 2UL, 3UL, 4UL, 5UL, 6UL])
}

///|
/// matching_ids: 组合过滤器。
async test "v1 matching_ids: compound filters" {
  let n = open(make_test_store([]), "test")
  // And(Eq(category,a), Gt(ts,200)) → id3(ts300), id5(ts500)
  let ids_and = matching_ids(
    n,
    And([Eq("category", S("a")), Gt("ts", I(200L))]),
  )
  ids_and.sort()
  assert_eq(ids_and, [3UL, 5UL])

  // Or(Eq(category,b), Eq(category,c)) → {2,4,6}
  let ids_or = matching_ids(
    n,
    Or([Eq("category", S("b")), Eq("category", S("c"))]),
  )
  ids_or.sort()
  assert_eq(ids_or, [2UL, 4UL, 6UL])

  // Not(Eq(public,true)) → public=false → {2,4,6}
  let ids_not = matching_ids(n, Not(Eq("public", B(true))))
  ids_not.sort()
  assert_eq(ids_not, [2UL, 4UL, 6UL])

  // Glob + range: And(Glob(category,"a*"), Lte(ts,300)) → id1(100), id3(300)
  let ids_glob_range = matching_ids(
    n,
    And([Glob("category", "a*"), Lte("ts", I(300L))]),
  )
  ids_glob_range.sort()
  assert_eq(ids_glob_range, [1UL, 3UL])
}

///|
/// matching_ids: tombstone 排除。
async test "v1 matching_ids: tombstone excluded" {
  // 删除 id3
  let nt = open(make_test_store([3UL]), "test")
  let ids = matching_ids(nt, Eq("category", S("a")))
  ids.sort()
  assert_eq(ids, [1UL, 5UL]) // id3 被排除
  assert_eq(ids.contains(3UL), false)
}

///|
/// matching_ids: 空过滤结果。
async test "v1 matching_ids: empty result" {
  let n = open(make_test_store([]), "test")
  // 不存在的值
  let ids = matching_ids(n, Eq("category", S("zzz")))
  assert_eq(ids, [])

  // In 空集恒 false
  let ids_empty = matching_ids(n, In("category", []))
  assert_eq(ids_empty, [])
}

///|
/// seg_may_match 对 Glob 保守返回 true（不跳过段）。
async test "v1 seg_may_match: Glob is conservative (never prunes)" {
  let j = @utf8.encode(
    (
      #|{"id":"s","row_count":10,"min_id":1,"max_id":10,"partitions":[0],
      #| "stats":{"ts":{"min":100,"max":200},
      #|          "category":{"values":["a","b"]},
      #|          "public":{"values":[false,true]}}}
    ),
  )
  let info = parse_seg_meta(j)
  let stats = match info.stats {
    Some(s) => s
    None => fail("stats missing")
  }
  let cs : CachedSeg = {
    row_count: 10,
    partitions: [0],
    min_id: 1UL,
    id_dense: true,
    vec_storage: "",
    vec_normalized: false,
    stats: Some(stats),
    bloom: None,
    dir: None,
    doc_len: None,
    ids: None,
    blockmax: None,
    blockmax_size: 128,
    blockmax_tried: false,
    pq_m: 0,
    pq_dsub: 0,
    pq_codebook: None,
    vec_info: None,
    block_stats: None,
    block_stats_tried: false,
    slab_index: None,
    slab_tried: false,
    seg_seq: -1,
    matchers: Map([]),
    vec_parts: Map([]),
  }
  // Glob は常に true（統計でプルーニング不可）
  assert_eq(seg_may_match(cs, Some(Glob("category", "z*"))), true)
  assert_eq(seg_may_match(cs, Some(Glob("category", "?"))), true)
  assert_eq(seg_may_match(cs, Some(Glob("ts", "*"))), true)
  // Glob in And: Glob side returns true, so And result depends on other child
  assert_eq(
    seg_may_match(cs, Some(And([Glob("category", "z*"), Gt("ts", I(300L))]))),
    false, // Gt(ts,300): ts_max=200 < 300 → false → And = false
  )
  assert_eq(
    seg_may_match(cs, Some(Or([Glob("category", "z*"), Gt("ts", I(150L))]))),
    true, // Gt(ts,150): ts_max=200>150 → true → Or = true
  )
}
