// control/scatter_wbtest.mbt：分布式 Scatter-Gather 执行引擎白盒测试。

///|
async fn[S : @store.ObjectStore] wb_put(s : S, key : String, val : Bytes) -> Unit {
  s.put(key, val)
}

///|
async test "TopKHeap: push, sift-down, capacity bound and ordering" {
  let heap = TopKHeap::new(3)
  assert_eq(heap.size, 0)
  assert_eq(heap.capacity, 3)

  heap.push(10UL, 1.0)
  heap.push(20UL, 5.0)
  heap.push(30UL, 3.0)
  assert_eq(heap.size, 3)

  // 此时堆中元素为 1.0, 5.0, 3.0，最小堆顶为 1.0
  // 插入比堆顶小的值，应该被丢弃
  heap.push(40UL, 0.5)
  assert_eq(heap.size, 3)

  // 插入比堆顶大的值 4.0，应该置换掉 1.0
  heap.push(50UL, 4.0)
  assert_eq(heap.size, 3)

  let results = heap.to_results()
  assert_eq(results.length(), 3)
  // 最终保留的前 3 名降序应为：20 (5.0), 50 (4.0), 30 (3.0)
  assert_eq(results[0].id, 20UL)
  assert_eq(results[0].score, 5.0)
  assert_eq(results[1].id, 50UL)
  assert_eq(results[1].score, 4.0)
  assert_eq(results[2].id, 30UL)
  assert_eq(results[2].score, 3.0)
}

///|
async test "TopKHeap: merge_candidates gathers partial worker results" {
  let heap = TopKHeap::new(4)
  let worker1_res : Array[@query.QueryResult] = [
    { id: 101UL, score: 0.95 },
    { id: 102UL, score: 0.70 },
  ]
  let worker2_res : Array[@query.QueryResult] = [
    { id: 201UL, score: 0.98 },
    { id: 202UL, score: 0.85 },
    { id: 203UL, score: 0.60 },
  ]
  heap.merge_candidates(worker1_res)
  heap.merge_candidates(worker2_res)

  let results = heap.to_results()
  assert_eq(results.length(), 4)
  assert_eq(results[0].id, 201UL)
  assert_eq(results[0].score, 0.98)
  assert_eq(results[1].id, 101UL)
  assert_eq(results[1].score, 0.95)
  assert_eq(results[2].id, 202UL)
  assert_eq(results[2].score, 0.85)
  assert_eq(results[3].id, 102UL)
  assert_eq(results[3].score, 0.70)
}

///|
async test "split_partitions: boundary and fair slice partitioning" {
  // 空列表
  let s0 = split_partitions([], 3)
  assert_eq(s0.length(), 3)
  assert_eq(s0[0].length(), 0)
  assert_eq(s0[1].length(), 0)
  assert_eq(s0[2].length(), 0)

  // 1 worker
  let s1 = split_partitions([0, 1, 2, 3], 1)
  assert_eq(s1.length(), 1)
  assert_eq(s1[0].length(), 4)

  // 4 分区 2 workers：均分
  let s2 = split_partitions([10, 20, 30, 40], 2)
  assert_eq(s2.length(), 2)
  assert_eq(s2[0], [10, 20])
  assert_eq(s2[1], [30, 40])

  // 5 分区 3 workers：2 + 2 + 1
  let s3 = split_partitions([0, 1, 2, 3, 4], 3)
  assert_eq(s3.length(), 3)
  assert_eq(s3[0], [0, 1])
  assert_eq(s3[1], [2, 3])
  assert_eq(s3[2], [4])

  // 1 分区 4 workers：1 + 0 + 0 + 0
  let s4 = split_partitions([99], 4)
  assert_eq(s4.length(), 4)
  assert_eq(s4[0], [99])
  assert_eq(s4[1].length(), 0)
  assert_eq(s4[2].length(), 0)
  assert_eq(s4[3].length(), 0)

  // 7 分区 4 workers：2 + 2 + 2 + 1 = 7
  let s5 = split_partitions([1, 2, 3, 4, 5, 6, 7], 4)
  assert_eq(s5.length(), 4)
  assert_eq(s5[0], [1, 2])
  assert_eq(s5[1], [3, 4])
  assert_eq(s5[2], [5, 6])
  assert_eq(s5[3], [7])
}

///|
/// 构造包含 4 个 Centroid / 分区的多段 Global IVF 测试数据集。
async fn make_scatter_test_store() -> (@store.MemStore, String) {
  let s = @store.MemStore::new()
  let ns = "scatter_test"
  let mid = "manifest-01"
  let ver = "g1"

  // 1. namespace.json
  let nm : Map[String, Json] = Map([])
  nm.set("format", Json::string("seekpond/v1"))
  nm.set("namespace", Json::string(ns))
  nm.set("head_manifest", Json::string(mid))
  nm.set("vec_global_version", Json::string(ver))
  nm.set("distance_metric", Json::string("cosine"))
  nm.set("vector_dim", Json::number(4.0))
  nm.set("vector_dtype", Json::string("f32"))
  nm.set("fts_k1", Json::number(1.2))
  nm.set("fts_b", Json::number(0.75))
  wb_put(s, "\{ns}/_meta/namespace.json", @utf8.encode(Json::object(nm).stringify()))

  // 2. manifest-01.json：包含 2 个 segment，单段 dense
  let seg0_meta : Map[String, Json] = Map([])
  seg0_meta.set("id", Json::string("seg-0"))
  seg0_meta.set("row_count", Json::number(4.0))
  seg0_meta.set("min_id", Json::number(100.0))
  seg0_meta.set("max_id", Json::number(103.0))
  seg0_meta.set("doc_len_sum", Json::number(10.0))
  seg0_meta.set("size_bytes", Json::number(100.0))

  let seg1_meta : Map[String, Json] = Map([])
  seg1_meta.set("id", Json::string("seg-1"))
  seg1_meta.set("row_count", Json::number(4.0))
  seg1_meta.set("min_id", Json::number(200.0))
  seg1_meta.set("max_id", Json::number(203.0))
  seg1_meta.set("doc_len_sum", Json::number(10.0))
  seg1_meta.set("size_bytes", Json::number(100.0))

  let mm : Map[String, Json] = Map([])
  mm.set("id", Json::string(mid))
  mm.set("parent", Json::null())
  mm.set("segments", Json::array([Json::object(seg0_meta), Json::object(seg1_meta)]))
  mm.set("deleted", Json::array([]))
  mm.set("deleted_roar", Json::null())
  mm.set("vec_global_version", Json::string(ver))
  mm.set("centroid_version", Json::string("centroids-1"))
  mm.set("num_docs", Json::number(8.0))
  mm.set("avg_doc_len", Json::number(2.5))
  wb_put(s, "\{ns}/_manifest/\{mid}.json", @utf8.encode(Json::object(mm).stringify()))

  // 3. centroids-1.bin：4 个 4-维中心
  // c0: [1, 0, 0, 0]
  // c1: [0, 1, 0, 0]
  // c2: [0, 0, 1, 0]
  // c3: [0, 0, 0, 1]
  let cent_data : Array[Float] = [
    1.0, 0.0, 0.0, 0.0,
    0.0, 1.0, 0.0, 0.0,
    0.0, 0.0, 1.0, 0.0,
    0.0, 0.0, 0.0, 1.0,
  ]
  let cent : @format.Centroids = { dim: 4, data: cent_data }
  wb_put(s, "\{ns}/_centroids/centroids-1.bin", @format.encode_centroids(cent))

  // 4. segment meta.json
  // seg-0: id_encoding="dense_u64", min_id=100, partitions=[0, 1]
  let s0_json : Map[String, Json] = Map([])
  s0_json.set("row_count", Json::number(4.0))
  s0_json.set("partitions", Json::array([Json::number(0.0), Json::number(1.0)]))
  s0_json.set("min_id", Json::number(100.0))
  s0_json.set("id_encoding", Json::string("dense_u64"))
  s0_json.set("vec_storage", Json::string("f32"))
  s0_json.set("vec_normalized", Json::boolean(true))
  wb_put(s, "\{ns}/_segments/seg-0/meta.json", @utf8.encode(Json::object(s0_json).stringify()))

  // seg-1: id_encoding="dense_u64", min_id=200, partitions=[2, 3]
  let s1_json : Map[String, Json] = Map([])
  s1_json.set("row_count", Json::number(4.0))
  s1_json.set("partitions", Json::array([Json::number(2.0), Json::number(3.0)]))
  s1_json.set("min_id", Json::number(200.0))
  s1_json.set("id_encoding", Json::string("dense_u64"))
  s1_json.set("vec_storage", Json::string("f32"))
  s1_json.set("vec_normalized", Json::boolean(true))
  wb_put(s, "\{ns}/_segments/seg-1/meta.json", @utf8.encode(Json::object(s1_json).stringify()))

  // 5. Global IVF Partitions
  // Part 0 (接近 c0): doc 100 (seg 0 row 0), doc 101 (seg 0 row 1)
  let p0_rows : Array[(Int, Int)] = [(0, 0), (0, 1)]
  let p0_vecs : Array[Float] = [
    0.99, 0.05, 0.0, 0.0,
    0.95, 0.10, 0.0, 0.0,
  ]
  wb_put(
    s,
    "\{ns}/vec/global/\{ver}/part-0.bin",
    @format.encode_global_part(0, p0_rows, 4, p0_vecs, false),
  )

  // Part 1 (接近 c1): doc 102 (seg 0 row 2), doc 103 (seg 0 row 3)
  let p1_rows : Array[(Int, Int)] = [(0, 2), (0, 3)]
  let p1_vecs : Array[Float] = [
    0.05, 0.99, 0.0, 0.0,
    0.10, 0.95, 0.0, 0.0,
  ]
  wb_put(
    s,
    "\{ns}/vec/global/\{ver}/part-1.bin",
    @format.encode_global_part(1, p1_rows, 4, p1_vecs, false),
  )

  // Part 2 (接近 c2): doc 200 (seg 1 row 0), doc 201 (seg 1 row 1)
  let p2_rows : Array[(Int, Int)] = [(1, 0), (1, 1)]
  let p2_vecs : Array[Float] = [
    0.0, 0.0, 0.99, 0.05,
    0.0, 0.0, 0.95, 0.10,
  ]
  wb_put(
    s,
    "\{ns}/vec/global/\{ver}/part-2.bin",
    @format.encode_global_part(2, p2_rows, 4, p2_vecs, false),
  )

  // Part 3 (接近 c3): doc 202 (seg 1 row 2), doc 203 (seg 1 row 3)
  let p3_rows : Array[(Int, Int)] = [(1, 2), (1, 3)]
  let p3_vecs : Array[Float] = [
    0.0, 0.0, 0.05, 0.99,
    0.0, 0.0, 0.10, 0.95,
  ]
  wb_put(
    s,
    "\{ns}/vec/global/\{ver}/part-3.bin",
    @format.encode_global_part(3, p3_rows, 4, p3_vecs, false),
  )

  wb_put(s, "\{ns}/vec/global/\{ver}/meta.json", @utf8.encode("{\"cids\":[0,1,2,3]}"))

  (s, ns)
}

///|
async test "Scatter-Gather: Result equality between single-worker sequential scan and multi-worker scatter-gather" {
  let (store, ns) = make_scatter_test_store()
  let qn = @query.open(store, ns)

  // Coordinator with 1 worker (单 Worker 顺序扫描对照组)
  let coord1 = Coordinator::new(store, worker_count=1)
  coord1.register_tenant(ns, "manifest-01", 4, "cosine", "standard", 8)

  // Coordinator with 2 workers (双 Worker Scatter-Gather)
  let coord2 = Coordinator::new(store, worker_count=2)
  coord2.register_tenant(ns, "manifest-01", 4, "cosine", "standard", 8)

  // Coordinator with 4 workers (四 Worker Scatter-Gather)
  let coord4 = Coordinator::new(store, worker_count=4)
  coord4.register_tenant(ns, "manifest-01", 4, "cosine", "standard", 8)

  // 查询向量 qv：偏向 c0 与 c1
  let qv : Array[Float] = [0.8, 0.6, 0.0, 0.0]
  let top_k = 5
  let nprobe = 4 // 探测全部 4 个中心

  // 单 Worker 顺序查询
  let res_single = coord1.dispatch_vector_query(ns, qn, qv, top_k, nprobe, None)

  // 2-Worker Scatter-Gather 查询
  let res_scatter2 = coord2.scatter_gather_vector_query(ns, qn, qv, top_k, nprobe, None)

  // 4-Worker Scatter-Gather 查询
  let res_scatter4 = coord4.scatter_gather_vector_query(ns, qn, qv, top_k, nprobe, None)

  // 断言：结果集大小严格相等
  assert_eq(res_single.length(), res_scatter2.length())
  assert_eq(res_single.length(), res_scatter4.length())
  assert_eq(res_single.length() > 0, true)

  // 断言：每个返回结果的 doc ID 与打分完全一致（100% 数值与排序相等性）
  for i in 0..<res_single.length() {
    assert_eq(res_scatter2[i].id, res_single[i].id)
    assert_eq(res_scatter4[i].id, res_single[i].id)
    let diff2 = (res_scatter2[i].score - res_single[i].score).abs()
    let diff4 = (res_scatter4[i].score - res_single[i].score).abs()
    assert_eq(diff2 < 1.0e-6, true)
    assert_eq(diff4 < 1.0e-6, true)
  }

  // 顶级召回必须是 doc 100（距离 qv 最近）
  assert_eq(res_scatter2[0].id, 100UL)
  assert_eq(res_scatter4[0].id, 100UL)
}

///|
async test "Scatter-Gather: Warm cache hit verification on multi-worker pool" {
  let (store, ns) = make_scatter_test_store()
  let qn = @query.open(store, ns)

  let coord = Coordinator::new(store, worker_count=2)
  coord.register_tenant(ns, "manifest-01", 4, "cosine", "standard", 8)

  let qv : Array[Float] = [0.0, 0.0, 0.8, 0.6] // 偏向 c2 / c3
  let top_k = 4
  let nprobe = 4

  // 第一轮查询（Cold Start）：Worker 缓存未命中，从 store 载入并填入本地缓存
  let res1 = coord.scatter_gather_vector_query(ns, qn, qv, top_k, nprobe, None)
  assert_eq(res1.length() >= 4, true)

  let w0 = coord.workers[0]
  let w1 = coord.workers[1]
  let (hits0_cold, misses0_cold, _, _, bytes0_cold) = w0.cache.stats()
  let (hits1_cold, misses1_cold, _, _, bytes1_cold) = w1.cache.stats()

  // 验证两台 Worker 分别承担了对应分区的冷启动加载
  assert_eq(bytes0_cold > 0, true)
  assert_eq(bytes1_cold > 0, true)
  assert_eq(misses0_cold > 0, true)
  assert_eq(misses1_cold > 0, true)

  // 第二轮查询（Warm Cache）：相同探针分区命中各 Worker 本地 5 分钟热缓存
  let res2 = coord.scatter_gather_vector_query(ns, qn, qv, top_k, nprobe, None)
  assert_eq(res2.length(), res1.length())

  let (hits0_warm, misses0_warm, _, _, _) = w0.cache.stats()
  let (hits1_warm, misses1_warm, _, _, _) = w1.cache.stats()

  // 验证热缓存命中数显著增长，且未产生新的 miss
  assert_eq(hits0_warm > hits0_cold, true)
  assert_eq(hits1_warm > hits1_cold, true)
  assert_eq(misses0_warm, misses0_cold)
  assert_eq(misses1_warm, misses1_cold)
}

///|
async test "Scatter-Gather: Result equality with deleted documents (tombstones)" {
  let (store, ns) = make_scatter_test_store()
  // 在 manifest 中增加 deleted: [100UL]
  let mid = "manifest-01"
  let man_bytes = match store.get("\{ns}/_manifest/\{mid}.json") {
    Some(b) => b
    None => fail("missing manifest")
  }
  let json_str = @utf8.decode(man_bytes) catch { _ => "" }
  let patched_json = json_str.replace(
    old="\"deleted\":[]",
    new="\"deleted\":[100]",
  )
  wb_put(store, "\{ns}/_manifest/\{mid}.json", @utf8.encode(patched_json))

  let qn = @query.open(store, ns)
  let coord1 = Coordinator::new(store, worker_count=1)
  let coord2 = Coordinator::new(store, worker_count=2)

  let qv : Array[Float] = [1.0, 0.0, 0.0, 0.0]
  let res_single = coord1.dispatch_vector_query(ns, qn, qv, 4, 4, None)
  let res_scatter = coord2.scatter_gather_vector_query(ns, qn, qv, 4, 4, None)

  // 结果大小相等，且均不包含被删除的 100UL
  assert_eq(res_single.length(), res_scatter.length())
  for item in res_scatter {
    assert_eq(item.id != 100UL, true)
  }
  for i in 0..<res_single.length() {
    assert_eq(res_scatter[i].id, res_single[i].id)
  }
}

///|
async test "Scatter-Gather: Various worker counts (3, 5, 8 workers) result equality" {
  let (store, ns) = make_scatter_test_store()
  let qn = @query.open(store, ns)

  let coord1 = Coordinator::new(store, worker_count=1)
  let coord3 = Coordinator::new(store, worker_count=3)
  let coord5 = Coordinator::new(store, worker_count=5)
  let coord8 = Coordinator::new(store, worker_count=8)

  let qv : Array[Float] = [0.75, 0.65, 0.1, 0.05]
  let top_k = 6
  let nprobe = 4

  let res1 = coord1.dispatch_vector_query(ns, qn, qv, top_k, nprobe, None)
  let res3 = coord3.scatter_gather_vector_query(ns, qn, qv, top_k, nprobe, None)
  let res5 = coord5.scatter_gather_vector_query(ns, qn, qv, top_k, nprobe, None)
  let res8 = coord8.scatter_gather_vector_query(ns, qn, qv, top_k, nprobe, None)

  assert_eq(res1.length(), res3.length())
  assert_eq(res1.length(), res5.length())
  assert_eq(res1.length(), res8.length())

  for i in 0..<res1.length() {
    assert_eq(res3[i].id, res1[i].id)
    assert_eq(res5[i].id, res1[i].id)
    assert_eq(res8[i].id, res1[i].id)
    assert_eq((res3[i].score - res1[i].score).abs() < 1.0e-6, true)
    assert_eq((res5[i].score - res1[i].score).abs() < 1.0e-6, true)
    assert_eq((res8[i].score - res1[i].score).abs() < 1.0e-6, true)
  }
}

///|
async test "Scatter-Gather: Edge cases (empty query, zero top_k, zero nprobe)" {
  let (store, ns) = make_scatter_test_store()
  let qn = @query.open(store, ns)
  let coord = Coordinator::new(store, worker_count=2)

  // top_k = 0
  let r0 = coord.scatter_gather_vector_query(ns, qn, [1.0, 0.0, 0.0, 0.0], 0, 4, None)
  assert_eq(r0.length(), 0)

  // nprobe = 0
  let r1 = coord.scatter_gather_vector_query(ns, qn, [1.0, 0.0, 0.0, 0.0], 5, 0, None)
  assert_eq(r1.length(), 0)

  // empty vector
  let r2 = coord.scatter_gather_vector_query(ns, qn, [], 5, 4, None)
  assert_eq(r2.length(), 0)
}

