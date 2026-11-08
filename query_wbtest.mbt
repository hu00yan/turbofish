// query 包白盒测试：不依赖 build 包，用 MemStore + format.encode_* 手工构造
// 一个 mini namespace（2 个 segment、6 个 doc、dim=2、2 个中心、f32 存储），
// 覆盖：open 快照、bm25 命中/未命中/多词/k 截断/降序、posting range 读解码
// 与整读一致、nprobe=全部时与暴力一致、tombstone、三种 Filter、hybrid RRF 可复算。
//
// 手工数据布局（namespace "test"）：
//   seg-01A：id [1,2,3,4]，text ["the quick brown fox","the lazy dog sleeps",
//             "fox and fox run","猫追狗"]，dl [4,4,4,3]，category [a,b,a,c]，
//             ts [100,200,300,400]，public [T,F,T,F]
//             向量 [10.1,0.2] [9.8,-0.3] [0.4,9.5] [0.1,10.2] → part-0/1/1?：
//             c0=[10,0] 近 → doc0,doc1；c1=[0,10] 近 → doc2,doc3
//   seg-01B：id [5,6]，text ["the fox","狗 追 猫"]，dl [2,3]，category [a,c]，
//             ts [500,600]，public [T,F]，向量 [9.5,0.5]（c0） [-0.2,9.9]（c1）

///|
/// wbtest 辅助：trait 方法跨包不能直接点调用，走泛型分发。
fn tput[S : @store.ObjectStore](s : S, key : String, val : Bytes) -> Unit {
  tput(s, key, val)
}

///|
fn tget_range[S : @store.ObjectStore](
  s : S,
  key : String,
  off : Int,
  len : Int,
) -> Bytes? {
  s.get_range(key, off, len)
}

///|
fn seg_meta_json_bytes(
  seg_id : String,
  row_count : Int,
  min_id : UInt64,
  max_id : UInt64,
  parts : Array[Int],
) -> Bytes {
  let m : Map[String, Json] = Map::new()
  m.set("id", Json::string(seg_id))
  m.set("row_count", Json::number(row_count.to_double()))
  m.set("min_id", Json::number(min_id.to_double()))
  m.set("max_id", Json::number(max_id.to_double()))
  let pj : Array[Json] = Array::new()
  for c in parts {
    pj.push(Json::number(c.to_double()))
  }
  m.set("partitions", Json::array(pj))
  @utf8.encode(Json::object(m).stringify())
}

///|
/// 构造 mini namespace 的全部对象。deleted 直接写进 manifest。
fn make_test_store(deleted : Array[UInt64]) -> @store.MemStore {
  let s = @store.MemStore::new()
  let ns = "test"
  // namespace.json
  let meta : @format.NamespaceMeta = {
    format: "seekpond/v1",
    namespace: "test",
    head_manifest: "manifest-01",
    distance_metric: "cosine",
    vector_dim: 2,
    vector_dtype: "f32",
    k1: 1.2,
    b: 0.75,
  }
  tput(s, "\{ns}/_meta/namespace.json", @utf8.encode(meta.to_json().stringify()))
  // manifest-01
  let man : @format.ManifestData = {
    id: "manifest-01",
    parent: None,
    segments: [
      {
        id: "seg-01A",
        row_count: 4,
        min_id: 1UL,
        max_id: 4UL,
        doc_len_sum: 15,
        size_bytes: 0,
      },
      {
        id: "seg-01B",
        row_count: 2,
        min_id: 5UL,
        max_id: 6UL,
        doc_len_sum: 5,
        size_bytes: 0,
      },
    ],
    deleted,
    centroid_version: "centroids-1",
    num_docs: 6,
    avg_doc_len: 20.0 / 6.0,
  }
  tput(s, "\{ns}/_manifest/manifest-01.json", @utf8.encode(man.to_json().stringify()))
  // centroids（c0=[10,0] c1=[0,10]）
  let cent : @format.Centroids = { dim: 2, data: [10.0, 0.0, 0.0, 10.0] }
  tput(s, "\{ns}/_centroids/centroids-1.bin", @format.encode_centroids(cent))
  // seg-01A：fts
  let lists_a : Array[(String, Array[@format.Posting])] = [
    ("the", [{ row: 0, tf: 1 }, { row: 1, tf: 1 }]),
    ("quick", [{ row: 0, tf: 1 }]),
    ("brown", [{ row: 0, tf: 1 }]),
    ("fox", [{ row: 0, tf: 1 }, { row: 2, tf: 2 }]),
    ("lazy", [{ row: 1, tf: 1 }]),
    ("dog", [{ row: 1, tf: 1 }]),
    ("sleeps", [{ row: 1, tf: 1 }]),
    ("and", [{ row: 2, tf: 1 }]),
    ("run", [{ row: 2, tf: 1 }]),
    ("猫", [{ row: 3, tf: 1 }]),
    ("追", [{ row: 3, tf: 1 }]),
    ("狗", [{ row: 3, tf: 1 }]),
  ]
  let built_a = @format.encode_fts(lists_a)
  tput(s, "\{ns}/_segments/seg-01A/fts/dir.bin", built_a.dir)
  tput(s, "\{ns}/_segments/seg-01A/fts/postings.bin", built_a.postings)
  tput(s, 
    "\{ns}/_segments/seg-01A/fts/doc_len.bin",
    @format.encode_col(@format.ColU32([4, 4, 4, 3])),
  )
  // seg-01A：rows
  let ra = "\{ns}/_segments/seg-01A/rows"
  tput(s, "\{ra}/id.bin", @format.encode_col(@format.ColU64([1UL, 2UL, 3UL, 4UL])))
  tput(s, 
    "\{ra}/text.bin",
    @format.encode_col(
      @format.ColStr(["the quick brown fox", "the lazy dog sleeps", "fox and fox run", "猫追狗"]),
    ),
  )
  tput(s, "\{ra}/category.bin", @format.encode_col(@format.ColStr(["a", "b", "a", "c"])))
  tput(s, "\{ra}/ts.bin", @format.encode_col(@format.ColI64([100L, 200L, 300L, 400L])))
  tput(s, "\{ra}/public.bin", @format.encode_col(@format.ColBool([true, false, true, false])))
  tput(s, 
    "\{ra}/vector.bin",
    @format.encode_vec_col(2, [10.1, 0.2, 9.8, -0.3, 0.4, 9.5, 0.1, 10.2], false),
  )
  tput(s, "\{ns}/_segments/seg-01A/meta.json", seg_meta_json_bytes("seg-01A", 4, 1UL, 4UL, [0, 1]))
  // seg-01A：vec parts（c0: rows 0,1；c1: rows 2,3）
  tput(s, 
    "\{ns}/_segments/seg-01A/vec/part-0.bin",
    @format.encode_part({ cid: 0, rows: [0, 1], dim: 2, data: [10.1, 0.2, 9.8, -0.3] }, false),
  )
  tput(s, 
    "\{ns}/_segments/seg-01A/vec/part-1.bin",
    @format.encode_part({ cid: 1, rows: [2, 3], dim: 2, data: [0.4, 9.5, 0.1, 10.2] }, false),
  )
  // seg-01B：fts
  let lists_b : Array[(String, Array[@format.Posting])] = [
    ("the", [{ row: 0, tf: 1 }]),
    ("fox", [{ row: 0, tf: 1 }]),
    ("狗", [{ row: 1, tf: 1 }]),
    ("追", [{ row: 1, tf: 1 }]),
    ("猫", [{ row: 1, tf: 1 }]),
  ]
  let built_b = @format.encode_fts(lists_b)
  tput(s, "\{ns}/_segments/seg-01B/fts/dir.bin", built_b.dir)
  tput(s, "\{ns}/_segments/seg-01B/fts/postings.bin", built_b.postings)
  tput(s, 
    "\{ns}/_segments/seg-01B/fts/doc_len.bin",
    @format.encode_col(@format.ColU32([2, 3])),
  )
  // seg-01B：rows
  let rb = "\{ns}/_segments/seg-01B/rows"
  tput(s, "\{rb}/id.bin", @format.encode_col(@format.ColU64([5UL, 6UL])))
  tput(s, "\{rb}/text.bin", @format.encode_col(@format.ColStr(["the fox", "狗 追 猫"])))
  tput(s, "\{rb}/category.bin", @format.encode_col(@format.ColStr(["a", "c"])))
  tput(s, "\{rb}/ts.bin", @format.encode_col(@format.ColI64([500L, 600L])))
  tput(s, "\{rb}/public.bin", @format.encode_col(@format.ColBool([true, false])))
  tput(s, "\{rb}/vector.bin", @format.encode_vec_col(2, [9.5, 0.5, -0.2, 9.9], false))
  tput(s, "\{ns}/_segments/seg-01B/meta.json", seg_meta_json_bytes("seg-01B", 2, 5UL, 6UL, [0, 1]))
  // seg-01B：vec parts
  tput(s, 
    "\{ns}/_segments/seg-01B/vec/part-0.bin",
    @format.encode_part({ cid: 0, rows: [0], dim: 2, data: [9.5, 0.5] }, false),
  )
  tput(s, 
    "\{ns}/_segments/seg-01B/vec/part-1.bin",
    @format.encode_part({ cid: 1, rows: [1], dim: 2, data: [-0.2, 9.9] }, false),
  )
  s
}

///|
fn ids_of(results : Array[QueryResult]) -> Array[UInt64] {
  let out : Array[UInt64] = Array::new()
  for r in results {
    out.push(r.id)
  }
  out
}

///|
fn sorted_ids(results : Array[QueryResult]) -> Array[UInt64] {
  let out = ids_of(results)
  out.sort()
  out
}

///|
fn approx(a : Double, b : Double, eps : Double) -> Bool {
  (a - b).abs() < eps
}

///|
test "open binds meta and manifest snapshot" {
  let s = make_test_store([])
  let n = open(s, "test")
  assert_eq(n.meta.k1, 1.2)
  assert_eq(n.meta.vector_dim, 2)
  assert_eq(n.manifest.segments.length(), 2)
  assert_eq(n.manifest.segments[0].id, "seg-01A")
  assert_eq(n.manifest.segments[1].row_count, 2)
  // centroids 惰性：open 后为 None
  assert_eq(n.centroids.is_empty(), true)
  // 首次向量查询触发加载
  let _ = vec_search(n, [10.0, 0.0], 1, 1, None)
  match n.centroids {
    Some(c) => assert_eq(c.k(), 2)
    None => fail("centroids not cached")
  }
}

///|
test "posting range read decodes same as full read_postings" {
  let lists : Array[(String, Array[@format.Posting])] = [
    ("apple", [{ row: 0, tf: 2 }, { row: 3, tf: 1 }, { row: 10, tf: 4 }]),
    ("香蕉", [{ row: 1, tf: 1 }, { row: 7, tf: 3 }]),
    ("zoo", [{ row: 2, tf: 1 }, { row: 9, tf: 9 }]),
  ]
  let built = @format.encode_fts(lists)
  let entries = @format.decode_fts_dir(built.dir)
  let s = @store.MemStore::new()
  tput(s, "p", built.postings)
  for e in entries {
    // query 路径：get_range 只拉局部（offset 外层 +16 SPNDPOS1 头）再自解码
    let slice = match tget_range(s, "p", 16 + e.offset, e.size) {
      Some(x) => x
      None => fail("range read failed")
    }
    let from_slice = decode_posting_slice(slice)
    let from_full = @format.read_postings(built.postings, e)
    // Posting 未实现 Eq/Show，逐元素比对
    assert_eq(from_slice.length(), e.df)
    assert_eq(from_slice.length(), from_full.length())
    for i in 0..<from_slice.length() {
      assert_eq(from_slice[i].row, from_full[i].row)
      assert_eq(from_slice[i].tf, from_full[i].tf)
    }
  }
}

///|
test "bm25 hit, order and scores" {
  let s = make_test_store([])
  let n = open(s, "test")
  // "fox"：segA doc2(tf=2) id3 > segB doc0 id5 > segA doc0 id1
  let r = bm25_search(n, "fox", 10, None)
  assert_eq(ids_of(r), [3UL, 5UL, 1UL])
  assert_eq(r[0].score > r[1].score, true)
  assert_eq(r[1].score > r[2].score, true)
  // 分数可复算（与公式一致）：id3 = idf(ln2) * tf_norm(tf=2, dl=4)
  let expected3 = @math.ln(2.0) * (2.0 * (1.2 + 1.0)) / (2.0 + 1.2 * (1.0 - 0.75 + 0.75 * (4.0 / (20.0 / 6.0))))
  assert_eq(approx(r[0].score, expected3, 1.0e-12), true)
}

///|
test "bm25 miss returns empty" {
  let s = make_test_store([])
  let n = open(s, "test")
  assert_eq(bm25_search(n, "zebra", 10, None).length(), 0)
  // 空查询 / k<=0 也返回空
  assert_eq(bm25_search(n, "", 10, None).length(), 0)
  assert_eq(bm25_search(n, "fox", 0, None).length(), 0)
}

///|
test "bm25 multi-term and k truncation" {
  let s = make_test_store([])
  let n = open(s, "test")
  // "the fox"：命中 id1(id2 的 the), id2, id3(fox), id5(the+fox)
  let r = bm25_search(n, "the fox", 10, None)
  let got = sorted_ids(r)
  assert_eq(got, [1UL, 2UL, 3UL, 5UL])
  // "the" 命中 id1,id2,id5；k=1 截断
  let r1 = bm25_search(n, "the", 1, None)
  assert_eq(r1.length(), 1)
  let r3 = bm25_search(n, "the", 10, None)
  assert_eq(sorted_ids(r3), [1UL, 2UL, 5UL])
  // 分数降序
  for i in 1..<r3.length() {
    assert_eq(r3[i - 1].score >= r3[i].score, true)
  }
}

///|
test "bm25 cjk single-char query" {
  let s = make_test_store([])
  let n = open(s, "test")
  // "猫" 单字：segA id4 (N=4, df=1) > segB id6 (N=2, df=1)
  let r = bm25_search(n, "猫", 10, None)
  assert_eq(ids_of(r), [4UL, 6UL])
}

///|
test "vec nprobe=all matches brute force" {
  let s = make_test_store([])
  let n = open(s, "test")
  let qv : Array[Float] = [10.0, 0.0]
  let r = vec_search(n, qv, 4, 2, None) // nprobe=2=中心数 → 全量
  // 暴力全量对照（用源向量）
  let doc_vecs : Array[Array[Float]] = [
    [10.1, 0.2],
    [9.8, -0.3],
    [0.4, 9.5],
    [0.1, 10.2],
    [9.5, 0.5],
    [-0.2, 9.9],
  ]
  let doc_ids : Array[UInt64] = [1UL, 2UL, 3UL, 4UL, 5UL, 6UL]
  let brute : Array[(UInt64, Double)] = Array::new()
  for i in 0..<6 {
    brute.push((doc_ids[i], 1.0 - @core.cosine_dist_f32(qv, 0, doc_vecs[i], 0, 2)))
  }
  brute.sort_by(fn(a, b) { b.1.compare(a.1) })
  assert_eq(sorted_ids(r), [1UL, 2UL, 5UL, 3UL])
  // 每个 id 的分数与暴力一致
  for i in 0..<4 {
    assert_eq(approx(r[i].score, brute[i].1, 1.0e-9), true)
  }
}

///|
test "vec nprobe=1 restricts to nearest cluster" {
  let s = make_test_store([])
  let n = open(s, "test")
  let r = vec_search(n, [10.0, 0.0], 10, 1, None) // 只探 c0
  for id in ids_of(r) {
    assert_eq(id == 1UL || id == 2UL || id == 5UL, true)
  }
  assert_eq(r.is_empty(), false)
}

///|
test "tombstone filters bm25 and vec results" {
  let s = make_test_store([3UL])
  let n = open(s, "test")
  // bm25 "fox" 原为 [3,5,1] → 3 被删 → [5,1]
  assert_eq(ids_of(bm25_search(n, "fox", 10, None)), [5UL, 1UL])
  // vec qv=[0,10]：c1 候选 id4(1.0) > id6(0.9998) > id3(0.99916) → 删 3 → [4,6]
  assert_eq(ids_of(vec_search(n, [0.0, 10.0], 10, 2, None)), [4UL, 6UL])
}

///|
test "filter fstr fbool fi64" {
  let s = make_test_store([])
  let n = open(s, "test")
  // "the" 命中 id1(a) id2(b) id5(a)；category=a → [5,1]（id5 dl=2 分更高）
  let r1 = bm25_search(n, "the", 10, Some(FStr("category", "a")))
  assert_eq(ids_of(r1), [5UL, 1UL])
  // public=false 且命中 "the" → 只有 id2
  assert_eq(ids_of(bm25_search(n, "the", 10, Some(FBool("public", false)))), [2UL])
  // ts=500 且命中 "fox" → 只有 id5（id3 的 ts=300 被滤掉）
  assert_eq(ids_of(bm25_search(n, "fox", 10, Some(FI64("ts", 500L)))), [5UL])
  // dtype 不匹配的过滤列 → 报错
  try {
    let _ = bm25_search(n, "the", 10, Some(FI64("category", 3L)))
    panic()
  } catch {
    _ => ()
  }
}

///|
test "hybrid rrf recomputable" {
  let s = make_test_store([])
  let n = open(s, "test")
  let qv : Array[Float] = [10.0, 0.0]
  let r = hybrid_search(n, "fox", qv, 4, 2, None)
  // bm25 排名：id3=1, id5=2, id1=3；vec 排名：id1=1, id2=2, id5=3, id3=4
  // RRF: id1=1/63+1/61, id3=1/61+1/64, id5=1/62+1/63, id2=1/62
  let e1 = 1.0 / 63.0 + 1.0 / 61.0
  let e3 = 1.0 / 61.0 + 1.0 / 64.0
  let e5 = 1.0 / 62.0 + 1.0 / 63.0
  let e2 = 1.0 / 62.0
  assert_eq(ids_of(r), [1UL, 3UL, 5UL, 2UL])
  assert_eq(approx(r[0].score, e1, 1.0e-12), true)
  assert_eq(approx(r[1].score, e3, 1.0e-12), true)
  assert_eq(approx(r[2].score, e5, 1.0e-12), true)
  assert_eq(approx(r[3].score, e2, 1.0e-12), true)
}
