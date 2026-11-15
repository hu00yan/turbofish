///|
using @test {assert_eq}

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
fn[S : @store.ObjectStore] tput(s : S, key : String, val : Bytes) -> Unit {
  s.put(key, val)
}

///|
fn[S : @store.ObjectStore] tget_range(
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
  let m : Map[String, Json] = Map([])
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
    ns_name: "test",
    head_manifest: "manifest-01",
    vec_global_version: None,
    distance_metric: "cosine",
    vector_dim: 2,
    vector_dtype: "f32",
    k1: 1.2,
    b: 0.75,
    fts_tokenizer: None,
  }
  tput(
    s,
    "\{ns}/_meta/namespace.json",
    @utf8.encode(meta.to_json().stringify()),
  )
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
    deleted_roar: None,
    vec_global_version: None,
    global_gen: None,
    centroid_version: "centroids-1",
    num_docs: 6,
    avg_doc_len: 20.0 / 6.0,
  }
  tput(
    s,
    "\{ns}/_manifest/manifest-01.json",
    @utf8.encode(man.to_json().stringify()),
  )
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
  tput(
    s,
    "\{ns}/_segments/seg-01A/fts/doc_len.bin",
    @format.encode_col(@format.ColU32([4, 4, 4, 3])),
  )
  // seg-01A：rows
  let ra = "\{ns}/_segments/seg-01A/rows"
  tput(
    s,
    "\{ra}/id.bin",
    @format.encode_col(@format.ColU64([1UL, 2UL, 3UL, 4UL])),
  )
  tput(
    s,
    "\{ra}/text.bin",
    @format.encode_col(
      @format.ColStr([
        "the quick brown fox", "the lazy dog sleeps", "fox and fox run", "猫追狗",
      ]),
    ),
  )
  tput(
    s,
    "\{ra}/category.bin",
    @format.encode_col(@format.ColStr(["a", "b", "a", "c"])),
  )
  tput(
    s,
    "\{ra}/ts.bin",
    @format.encode_col(@format.ColI64([100L, 200L, 300L, 400L])),
  )
  tput(
    s,
    "\{ra}/public.bin",
    @format.encode_col(@format.ColBool([true, false, true, false])),
  )
  tput(
    s,
    "\{ra}/vector.bin",
    @format.encode_vec_col(
      2,
      [10.1, 0.2, 9.8, -0.3, 0.4, 9.5, 0.1, 10.2],
      false,
    ),
  )
  tput(
    s,
    "\{ns}/_segments/seg-01A/meta.json",
    seg_meta_json_bytes("seg-01A", 4, 1UL, 4UL, [0, 1]),
  )
  // seg-01A：vec parts（c0: rows 0,1；c1: rows 2,3）
  tput(
    s,
    "\{ns}/_segments/seg-01A/vec/part-0.bin",
    @format.encode_part(
      { cid: 0, rows: [0, 1], dim: 2, data: [10.1, 0.2, 9.8, -0.3] },
      false,
    ),
  )
  tput(
    s,
    "\{ns}/_segments/seg-01A/vec/part-1.bin",
    @format.encode_part(
      { cid: 1, rows: [2, 3], dim: 2, data: [0.4, 9.5, 0.1, 10.2] },
      false,
    ),
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
  tput(
    s,
    "\{ns}/_segments/seg-01B/fts/doc_len.bin",
    @format.encode_col(@format.ColU32([2, 3])),
  )
  // seg-01B：rows
  let rb = "\{ns}/_segments/seg-01B/rows"
  tput(s, "\{rb}/id.bin", @format.encode_col(@format.ColU64([5UL, 6UL])))
  tput(
    s,
    "\{rb}/text.bin",
    @format.encode_col(@format.ColStr(["the fox", "狗 追 猫"])),
  )
  tput(s, "\{rb}/category.bin", @format.encode_col(@format.ColStr(["a", "c"])))
  tput(s, "\{rb}/ts.bin", @format.encode_col(@format.ColI64([500L, 600L])))
  tput(
    s,
    "\{rb}/public.bin",
    @format.encode_col(@format.ColBool([true, false])),
  )
  tput(
    s,
    "\{rb}/vector.bin",
    @format.encode_vec_col(2, [9.5, 0.5, -0.2, 9.9], false),
  )
  tput(
    s,
    "\{ns}/_segments/seg-01B/meta.json",
    seg_meta_json_bytes("seg-01B", 2, 5UL, 6UL, [0, 1]),
  )
  // seg-01B：vec parts
  tput(
    s,
    "\{ns}/_segments/seg-01B/vec/part-0.bin",
    @format.encode_part({ cid: 0, rows: [0], dim: 2, data: [9.5, 0.5] }, false),
  )
  tput(
    s,
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
  assert_eq(n.centroids is None, true)
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
  let expected3 = @math.ln(2.0) *
    (2.0 * (1.2 + 1.0)) /
    (2.0 + 1.2 * (1.0 - 0.75 + 0.75 * (4.0 / (20.0 / 6.0))))
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
    brute.push(
      (doc_ids[i], 1.0 - @core.cosine_dist_f32(qv, 0, doc_vecs[i], 0, 2)),
    )
  }
  brute.sort_by(fn(a, b) { b.1.compare(a.1) })
  assert_eq(sorted_ids(r), [1UL, 2UL, 3UL, 5UL])
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
  // vec qv=[0,10] nprobe=1（只探最近中心 c1）：id4(1.0) > id6(0.9998) > id3(已删) → [4,6]
  assert_eq(ids_of(vec_search(n, [0.0, 10.0], 10, 1, None)), [4UL, 6UL])
}

///|
test "filter fstr fbool fi64" {
  let s = make_test_store([])
  let n = open(s, "test")
  // "the" 命中 id1(a) id2(b) id5(a)；category=a → [5,1]（id5 dl=2 分更高）
  let r1 = bm25_search(n, "the", 10, Some(f_str("category", "a")))
  assert_eq(ids_of(r1), [5UL, 1UL])
  // public=false 且命中 "the" → 只有 id2
  assert_eq(ids_of(bm25_search(n, "the", 10, Some(f_bool("public", false)))), [
    2UL,
  ])
  // ts=500 且命中 "fox" → 只有 id5（id3 的 ts=300 被滤掉）
  assert_eq(ids_of(bm25_search(n, "fox", 10, Some(f_i64("ts", 500L)))), [5UL])
  // dtype 不匹配的过滤列 → 报错
  try {
    let _ = bm25_search(n, "the", 10, Some(f_i64("category", 3L)))
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

// ============================================================================
// WAND / stats 跳过 / dense id / 字典与位图过滤 / PQ ADC
// ============================================================================

///|
/// 构造 WAND 测试 store：单段 400 行，"hot" 覆盖全部行（4 个 block），
/// "mid" 覆盖 100..299（2 个 block），"rare" 覆盖 0..9（1 个 block）。
fn make_wand_store() -> @store.MemStore {
  let s = @store.MemStore::new()
  let ns = "wand"
  let nrows = 400
  let meta : @format.NamespaceMeta = {
    format: "seekpond/v1",
    ns_name: ns,
    head_manifest: "manifest-w",
    vec_global_version: None,
    distance_metric: "cosine",
    vector_dim: 2,
    vector_dtype: "f32",
    k1: 1.2,
    b: 0.75,
    fts_tokenizer: None,
  }
  tput(
    s,
    "\{ns}/_meta/namespace.json",
    @utf8.encode(meta.to_json().stringify()),
  )
  let man : @format.ManifestData = {
    id: "manifest-w",
    parent: None,
    segments: [
      {
        id: "seg-w",
        row_count: nrows,
        min_id: 1UL,
        max_id: 400UL,
        doc_len_sum: 800,
        size_bytes: 0,
      },
    ],
    deleted: [],
    deleted_roar: None,
    vec_global_version: None,
    global_gen: None,
    centroid_version: "centroids-w",
    num_docs: nrows,
    avg_doc_len: 201.5,
  }
  tput(
    s,
    "\{ns}/_manifest/manifest-w.json",
    @utf8.encode(man.to_json().stringify()),
  )
  let cent : @format.Centroids = { dim: 2, data: [1.0, 0.0] }
  tput(s, "\{ns}/_centroids/centroids-w.bin", @format.encode_centroids(cent))
  // fts：hot 全部行，mid 100..299，rare 0..9
  let hot : Array[@format.Posting] = Array::new(capacity=nrows)
  let mid : Array[@format.Posting] = Array::new()
  let rare : Array[@format.Posting] = Array::new()
  for r in 0..<nrows {
    hot.push({ row: r, tf: 1 + r % 3 })
    if r >= 100 && r < 300 {
      mid.push({ row: r, tf: 2 })
    }
    if r < 10 {
      rare.push({ row: r, tf: 5 })
    }
  }
  let lists : Array[(String, Array[@format.Posting])] = [
    ("hot", hot),
    ("mid", mid),
    ("rare", rare),
  ]
  let built = @format.encode_fts(lists)
  tput(s, "\{ns}/_segments/seg-w/fts/dir.bin", built.dir)
  tput(s, "\{ns}/_segments/seg-w/fts/postings.bin", built.postings)
  let dls : Array[Int] = Array::new(capacity=nrows)
  for r in 0..<nrows {
    dls.push(2 + r)
  }
  tput(
    s,
    "\{ns}/_segments/seg-w/fts/doc_len.bin",
    @format.encode_col(@format.ColU32(dls)),
  )
  // blockmax（dir 排序 hot < mid < rare）
  let hot_blocks : Array[(Int, Int)] = [(3, 2), (3, 130), (3, 258), (3, 386)]
  let mid_blocks : Array[(Int, Int)] = [(2, 102), (2, 130)]
  let rare_blocks : Array[(Int, Int)] = [(5, 2)]
  tput(
    s,
    "\{ns}/_segments/seg-w/fts/blockmax.bin",
    @format.encode_blockmax([hot_blocks, mid_blocks, rare_blocks], 128),
  )
  // rows
  let ra = "\{ns}/_segments/seg-w/rows"
  let ids : Array[UInt64] = Array::new(capacity=nrows)
  let texts : Array[String] = Array::new(capacity=nrows)
  let cats : Array[String] = Array::new(capacity=nrows)
  let tss : Array[Int64] = Array::new(capacity=nrows)
  let pubs : Array[Bool] = Array::new(capacity=nrows)
  let vecs : Array[Float] = Array::new(capacity=nrows * 2)
  for r in 0..<nrows {
    ids.push((r + 1).to_uint64())
    texts.push("hot hot mid rare")
    cats.push(if r % 2 == 0 { "a" } else { "b" })
    tss.push((1000 + r).to_int64())
    pubs.push(r % 2 == 0)
    vecs.push(1.0)
    vecs.push(0.0)
  }
  tput(s, "\{ra}/id.bin", @format.encode_col(@format.ColU64(ids)))
  tput(s, "\{ra}/text.bin", @format.encode_col_str_plain(texts))
  tput(s, "\{ra}/category.bin", @format.encode_col(@format.ColStr(cats)))
  tput(s, "\{ra}/ts.bin", @format.encode_col(@format.ColI64(tss)))
  tput(s, "\{ra}/public.bin", @format.encode_col(@format.ColBool(pubs)))
  tput(s, "\{ra}/vector.bin", @format.encode_vec_col(2, vecs, false))
  tput(
    s,
    "\{ns}/_segments/seg-w/meta.json",
    seg_meta_json_bytes("seg-w", nrows, 1UL, 400UL, [0]),
  )
  s
}

///|
test "WAND matches non-WAND and uses 4 blocks for hot" {
  let s = make_wand_store()
  let n = open(s, "wand")
  let cs = ensure_seg(n, 0)
  match seg_blockmax(n, cs, "seg-w") {
    Some(blk) => {
      assert_eq(blk.length(), 3)
      assert_eq(blk[0].length(), 4) // hot: 400 postings / 128 = 4 blocks
      assert_eq(blk[1].length(), 2) // mid: 200 / 128 = 2 blocks
      assert_eq(blk[2].length(), 1) // rare: 10 / 128 = 1 block
    }
    None => fail("blockmax missing")
  }
  let queries = [
    "hot", "hot mid", "hot rare", "mid rare", "hot mid rare", "rare", "mid", "hot hot",
    "rare hot", "hot mid rare mid",
  ]
  for q in queries {
    let wand = bm25_search_impl(n, q, 10, None, true)
    let base = bm25_search_impl(n, q, 10, None, false)
    assert_eq(wand.length(), base.length())
    // 硬门：top-k 集合一致（并列分数不要求顺序一致），逐 id 分数一致
    let wm : Map[UInt64, Double] = Map([])
    for r in wand {
      wm.set(r.id, r.score)
    }
    for r in base {
      match wm.get(r.id) {
        Some(s) => assert_eq(approx(s, r.score, 1.0e-9), true)
        None => fail("WAND top-k set mismatch on query \{q}")
      }
    }
  }
  // 带过滤时同样一致
  for q in queries {
    let f = Some(f_str("category", "a"))
    let wand = bm25_search_impl(n, q, 10, f, true)
    let base = bm25_search_impl(n, q, 10, f, false)
    assert_eq(wand.length(), base.length())
    let ws : Set[UInt64] = Set([])
    for r in wand {
      ws.add(r.id)
    }
    for r in base {
      assert_eq(ws.contains(r.id), true)
    }
  }
}

///|
test "parse stats and seg_may_match" {
  let j = @utf8.encode(
    (
      #|{"id":"s","row_count":10,"min_id":1,"max_id":10,"partitions":[0],
      #| "id_encoding":"dense_u64","vec_storage":"sq8",
      #| "stats":{"ts":{"min":100,"max":200},
      #|          "category":{"values":["a","b"]},
      #|          "public":{"values":[false,true]}}}
    ),
  )
  let info = parse_seg_meta(j)
  assert_eq(info.row_count, 10)
  assert_eq(info.id_dense, true)
  assert_eq(info.vec_storage, "sq8")
  let stats = match info.stats {
    Some(s) => s
    None => fail("stats missing")
  }
  assert_eq(stats.ts_min, 100L)
  assert_eq(stats.ts_max, 200L)
  assert_eq(stats.cat_values.length(), 2)
  let cs : CachedSeg = {
    row_count: 10,
    partitions: [0],
    min_id: 1UL,
    id_dense: true,
    vec_storage: "sq8",
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
    matchers: Map([]),
    vec_parts: Map([]),
  }
  assert_eq(seg_may_match(cs, Some(f_i64("ts", 150L))), true)
  assert_eq(seg_may_match(cs, Some(f_i64("ts", 50L))), false)
  assert_eq(seg_may_match(cs, Some(f_i64("ts", 250L))), false)
  assert_eq(seg_may_match(cs, Some(f_str("category", "a"))), true)
  assert_eq(seg_may_match(cs, Some(f_str("category", "z"))), false)
  assert_eq(seg_may_match(cs, Some(f_bool("public", true))), true)
  assert_eq(seg_may_match(cs, None), true)
  // dense id：row→id = min_id + row，不读 id.bin
  let s = @store.MemStore::new()
  let meta : @format.NamespaceMeta = {
    format: "",
    ns_name: "q",
    head_manifest: "",
    vec_global_version: None,
    distance_metric: "",
    vector_dim: 0,
    vector_dtype: "",
    k1: 0.0,
    b: 0.0,
    fts_tokenizer: None,
  }
  let man : @format.ManifestData = {
    id: "",
    parent: None,
    segments: [],
    deleted: [],
    deleted_roar: None,
    centroid_version: "",
    vec_global_version: None,
    global_gen: None,
    num_docs: 0,
    avg_doc_len: 0.0,
  }
  let nn : Namespace[@store.MemStore] = {
    store: s,
    ns: "q",
    meta,
    manifest: man,
    centroids: None,
    cache: Map([]),
    tombstones: None,
    vec_global_cids: None,
    global_gen_cids: Map([]),
    global_gen_packs: Map([]),
    global_parts: Map([]),
    head_checked_ms: 0UL,
  }
  assert_eq(row_id(nn, cs, "s", 3), 4UL)
}

///|
test "dict/bitmap filter matchers avoid expansion" {
  let s = @store.MemStore::new()
  let cats : Array[String] = ["a", "b", "a", "c", "b"]
  let pubs : Array[Bool] = [true, false, true, false, true]
  tput(
    s,
    "q/_segments/seg/rows/category.bin",
    @format.encode_col(@format.ColStr(cats)),
  )
  tput(
    s,
    "q/_segments/seg/rows/public.bin",
    @format.encode_col(@format.ColBool(pubs)),
  )
  let meta : @format.NamespaceMeta = {
    format: "",
    ns_name: "q",
    head_manifest: "",
    vec_global_version: None,
    distance_metric: "",
    vector_dim: 0,
    vector_dtype: "",
    k1: 0.0,
    b: 0.0,
    fts_tokenizer: None,
  }
  let man : @format.ManifestData = {
    id: "",
    parent: None,
    segments: [],
    deleted: [],
    deleted_roar: None,
    centroid_version: "",
    vec_global_version: None,
    global_gen: None,
    num_docs: 0,
    avg_doc_len: 0.0,
  }
  let n : Namespace[@store.MemStore] = {
    store: s,
    ns: "q",
    meta,
    manifest: man,
    centroids: None,
    cache: Map([]),
    tombstones: None,
    vec_global_cids: None,
    global_gen_cids: Map([]),
    global_gen_packs: Map([]),
    global_parts: Map([]),
    head_checked_ms: 0UL,
  }
  let cs : CachedSeg = {
    row_count: 5,
    partitions: [],
    min_id: 0UL,
    id_dense: false,
    vec_storage: "",
    vec_normalized: false,
    stats: None,
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
    matchers: Map([]),
    vec_parts: Map([]),
  }
  let md = load_matcher(n, cs, "seg", f_str("category", "b"))
  match md {
    MDict(_, target) => assert_eq(target.to_int() < 65535, true)
    _ => fail("dict matcher expected")
  }
  assert_eq(matcher_at(md, 0), false)
  assert_eq(matcher_at(md, 1), true)
  assert_eq(matcher_at(md, 4), true)
  let mb = load_matcher(n, cs, "seg", f_bool("public", true))
  match mb {
    MBitmap(_, _) => ()
    _ => fail("bitmap matcher expected")
  }
  assert_eq(matcher_at(mb, 0), true)
  assert_eq(matcher_at(mb, 1), false)
  assert_eq(matcher_at(mb, 4), true)
  // 不在字典里的值 → 永不匹配
  let miss = load_matcher(n, cs, "seg", f_str("category", "zzz"))
  assert_eq(matcher_at(miss, 0), false)
  assert_eq(matcher_at(miss, 1), false)
}

///|
test "PQ ADC ranks nearest code first" {
  let codebooks : Array[Float] = Array::new(capacity=256)
  for j in 0..<256 {
    codebooks.push(Float::from_int(j))
  }
  let pq : @format.PQPart = {
    rows: [0, 1, 2],
    dim: 1,
    m: 1,
    dsub: 1,
    codebooks,
    codes: [1U, 200U, 0U],
  }
  let q = normalize_query([1.0])
  // v1 契约：pq_adc_candidates 返回原始累计 l2sq 距离（升序 = 最近优先）；
  // cosine 口径分数换算 1 - dist/2 由 adc_score 在调用方执行。
  let cands = pq_adc_candidates(q, pq, pq.codebooks)
  cands.sort_by(fn(a, b) { a.1.compare(b.1) })
  assert_eq(cands.length(), 3)
  assert_eq(cands[0].0, 0) // code 1 = 最近
  assert_eq(approx(cands[0].1, 0.0, 1.0e-9), true)
  assert_eq(cands[1].0, 2) // code 0 次之（dist=1）
  assert_eq(cands[2].0, 1)
}

///|
test "roaring tombstone object filters results" {
  let s = make_test_store([])
  // 重写 manifest-01：deleted 留空，deleted_roar 指向 roaring 对象
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
    deleted: [],
    deleted_roar: Some("m1"),
    vec_global_version: None,
    global_gen: None,
    centroid_version: "centroids-1",
    num_docs: 6,
    avg_doc_len: 20.0 / 6.0,
  }
  tput(
    s,
    "test/_manifest/manifest-01.json",
    @utf8.encode(man.to_json().stringify()),
  )
  tput(s, "test/_tombstones/m1.roar", @format.encode_roaring([1UL, 4UL]))
  let n = open(s, "test")
  let tomb = tombstones_of(n)
  assert_eq(tomb.contains(1UL), true)
  assert_eq(tomb.contains(4UL), true)
  assert_eq(tomb.contains(2UL), false)
  let r = bm25_search(n, "fox", 10, None)
  for x in r {
    assert_eq(x.id == 1UL || x.id == 4UL, false)
  }
}

///|
test "blockstats ts filter only reads matching blocks" {
  let s = make_test_store([])
  tput(
    s,
    "test/_segments/seg-01A/rows/blockstats.bin",
    @format.encode_blockstats([(100L, 400L)], 256, 4),
  )
  let n = open(s, "test")
  let cs = ensure_seg(n, 0)
  let m = load_matcher(n, cs, "seg-01A", f_i64("ts", 200L))
  assert_eq(matcher_at(m, 0), false)
  assert_eq(matcher_at(m, 1), true)
  assert_eq(matcher_at(m, 2), false)
  assert_eq(matcher_at(m, 3), false)
  // 范围外的值：块统计直接判定不命中
  let m2 = load_matcher(n, cs, "seg-01A", f_i64("ts", 999L))
  assert_eq(matcher_at(m2, 0), false)
  assert_eq(matcher_at(m2, 1), false)
}

///|
test "metadata cache hits and reloads on head change" {
  let s = make_test_store([])
  let cache : MetadataCache[@store.MemStore] = MetadataCache::new()
  let n1 = open_cached(cache, s, "test")
  let n2 = open_cached(cache, s, "test")
  assert_eq(cache.misses, 1)
  assert_eq(cache.hits, 1)
  assert_eq(n2.manifest.id, n1.manifest.id)
  let _ = bm25_search(n1, "fox", 10, None) // 填充 seg 解码缓存
  // 发布 manifest-02：同 segments，parent = manifest-01
  let m2 : @format.ManifestData = {
    id: "manifest-02",
    parent: Some(n1.manifest.id),
    segments: n1.manifest.segments,
    deleted: [],
    deleted_roar: None,
    vec_global_version: None,
    global_gen: None,
    centroid_version: n1.manifest.centroid_version,
    num_docs: n1.manifest.num_docs,
    avg_doc_len: n1.manifest.avg_doc_len,
  }
  tput(
    s,
    "test/_manifest/manifest-02.json",
    @utf8.encode(m2.to_json().stringify()),
  )
  let meta2 : @format.NamespaceMeta = {
    format: n1.meta.format,
    ns_name: n1.meta.ns_name,
    head_manifest: "manifest-02",
    vec_global_version: n1.meta.vec_global_version,
    distance_metric: n1.meta.distance_metric,
    vector_dim: n1.meta.vector_dim,
    vector_dtype: n1.meta.vector_dtype,
    k1: n1.meta.k1,
    b: n1.meta.b,
    fts_tokenizer: n1.meta.fts_tokenizer,
  }
  tput(
    s,
    "test/_meta/namespace.json",
    @utf8.encode(meta2.to_json().stringify()),
  )
  cache.head_ttl_ms = 0UL // 强制立即检查 head
  let n3 = open_cached(cache, s, "test")
  assert_eq(cache.misses, 2)
  assert_eq(n3.manifest.id, "manifest-02")
  // 旧 segment 缓存被继承（同一 Map 引用）
  assert_eq(n3.cache.get("seg-01A") is Some(_), true)
}

///|
fn[S : @store.ObjectStore] tget(s : S, key : String) -> Bytes? {
  s.get(key)
}

///|
test "global IVF partition path matches per-segment" {
  let s = make_test_store([])
  let n0 = open(s, "test")
  // 从 mini store 的 per-segment part 合成两个全局 part（cid 0/1）
  let a0 = match tget(s, "test/_segments/seg-01A/vec/part-0.bin") {
    Some(b) => @format.decode_part(b)
    None => fail("seg-01A part0 missing")
  }
  let a1 = match tget(s, "test/_segments/seg-01A/vec/part-1.bin") {
    Some(b) => @format.decode_part(b)
    None => fail("seg-01A part1 missing")
  }
  let b0 = match tget(s, "test/_segments/seg-01B/vec/part-0.bin") {
    Some(b) => @format.decode_part(b)
    None => fail("seg-01B part0 missing")
  }
  let b1 = match tget(s, "test/_segments/seg-01B/vec/part-1.bin") {
    Some(b) => @format.decode_part(b)
    None => fail("seg-01B part1 missing")
  }
  let d0 : Array[Float] = []
  for v in a0.data {
    d0.push(v)
  }
  for v in b0.data {
    d0.push(v)
  }
  tput(
    s,
    "test/vec/global/g1/part-0.bin",
    @format.encode_global_part(0, [(0, 0), (0, 1), (1, 0)], 2, d0, false),
  )
  let d1 : Array[Float] = []
  for v in a1.data {
    d1.push(v)
  }
  for v in b1.data {
    d1.push(v)
  }
  tput(
    s,
    "test/vec/global/g1/part-1.bin",
    @format.encode_global_part(1, [(0, 2), (0, 3), (1, 1)], 2, d1, false),
  )
  tput(s, "test/vec/global/g1/meta.json", @utf8.encode("{\"cids\":[0,1]}"))
  let meta2 : @format.NamespaceMeta = {
    format: n0.meta.format,
    ns_name: n0.meta.ns_name,
    head_manifest: n0.meta.head_manifest,
    vec_global_version: Some("g1"),
    distance_metric: n0.meta.distance_metric,
    vector_dim: n0.meta.vector_dim,
    vector_dtype: n0.meta.vector_dtype,
    k1: n0.meta.k1,
    b: n0.meta.b,
    fts_tokenizer: n0.meta.fts_tokenizer,
  }
  tput(
    s,
    "test/_meta/namespace.json",
    @utf8.encode(meta2.to_json().stringify()),
  )
  let ng = open(s, "test")
  let qs : Array[Array[Float]] = [[10.0, 0.0], [0.0, 10.0], [9.0, 1.0]]
  for q in qs {
    let g = sorted_ids(vec_search(ng, q, 10, 2, None))
    let p = sorted_ids(vec_search(n0, q, 10, 2, None))
    assert_eq(g, p)
    let gf = sorted_ids(vec_search(ng, q, 10, 2, Some(f_i64("ts", 300L))))
    let pf = sorted_ids(vec_search(n0, q, 10, 2, Some(f_i64("ts", 300L))))
    assert_eq(gf, pf)
  }
}

///|
test "missing global meta raises instead of silent empty" {
  let s = make_test_store([])
  let n0 = open(s, "test")
  let meta2 : @format.NamespaceMeta = {
    ..n0.meta,
    vec_global_version: Some("missing-generation"),
  }
  tput(
    s,
    "test/_meta/namespace.json",
    @utf8.encode(meta2.to_json().stringify()),
  )
  let ng = open(s, "test")
  try {
    let _ = vec_search(ng, [10.0, 0.0], 10, 2, None)
    fail("expected NotFound")
  } catch {
    @core.NotFound(_) => ()
    _ => fail("expected NotFound")
  }
}

///|
test "global meta missing cids raises instead of silent empty" {
  let s = make_test_store([])
  let n0 = open(s, "test")
  let meta2 : @format.NamespaceMeta = {
    ..n0.meta,
    vec_global_version: Some("g-no-cids"),
  }
  tput(
    s,
    "test/_meta/namespace.json",
    @utf8.encode(meta2.to_json().stringify()),
  )
  tput(s, "test/vec/global/g-no-cids/meta.json", @utf8.encode("{\"dim\":2}"))
  let ng = open(s, "test")
  try {
    let _ = vec_search(ng, [10.0, 0.0], 10, 2, None)
    fail("expected Corrupt")
  } catch {
    @core.Corrupt(_) => ()
    _ => fail("expected Corrupt")
  }
}

// ---------------------------------------------------------------------------
// S2a：query 读 global base + deltas（`manifest.global_gen` 代际链）。
// 手工构造：base 代 g-base 覆盖 seg-01A/01B，delta 代 g-delta 只覆盖新段
// seg-01C。rows 仍是 (seg_idx, row)，读路径不重排全局行号。
// ---------------------------------------------------------------------------

///|
fn[S : @store.ObjectStore] tdel(s : S, key : String) -> Unit {
  s.delete(key)
}

///|
/// 在 mini namespace 上叠加第三段 + `global_gen` delta 链：
///   - seg-01C：id [7,8]，向量 [10.2, 0.0] / [0.0, 10.1]，ts [700,800]；
///   - `g-base`：从 seg-01A/01B 的 per-segment part 合成（rows = (seg_idx, row)）；
///   - `g-delta`：只含 seg-01C 的两行（rows = (2,0)/(2,1)），meta 带
///     `kind=delta` / `base=g-base` / `seg_ids`；
///   - manifest-02：`global_gen = Some({base:"g-base", deltas:["g-delta"]})`，
///     `vec_global_version = Some("g-base")`，segments += seg-01C；
///   - namespace.json 也带 `vec_global_version = Some("g-base")`。
fn make_delta_chain_store(deleted : Array[UInt64]) -> @store.MemStore raise {
  let s = make_test_store(deleted)
  let ns = "test"
  // seg-01C：新段（id 7,8）
  let rc = "\{ns}/_segments/seg-01C/rows"
  tput(s, "\{rc}/id.bin", @format.encode_col(@format.ColU64([7UL, 8UL])))
  tput(s, "\{rc}/ts.bin", @format.encode_col(@format.ColI64([700L, 800L])))
  tput(
    s,
    "\{ns}/_segments/seg-01C/meta.json",
    seg_meta_json_bytes("seg-01C", 2, 7UL, 8UL, [0, 1]),
  )
  // base 代：从 seg-01A/01B 的 per-segment part 合成（与全局测试同布局）
  let a0 = match tget(s, "\{ns}/_segments/seg-01A/vec/part-0.bin") {
    Some(b) => @format.decode_part(b)
    None => fail("seg-01A part0 missing")
  }
  let a1 = match tget(s, "\{ns}/_segments/seg-01A/vec/part-1.bin") {
    Some(b) => @format.decode_part(b)
    None => fail("seg-01A part1 missing")
  }
  let b0 = match tget(s, "\{ns}/_segments/seg-01B/vec/part-0.bin") {
    Some(b) => @format.decode_part(b)
    None => fail("seg-01B part0 missing")
  }
  let b1 = match tget(s, "\{ns}/_segments/seg-01B/vec/part-1.bin") {
    Some(b) => @format.decode_part(b)
    None => fail("seg-01B part1 missing")
  }
  let d0 : Array[Float] = []
  for v in a0.data {
    d0.push(v)
  }
  for v in b0.data {
    d0.push(v)
  }
  let d1 : Array[Float] = []
  for v in a1.data {
    d1.push(v)
  }
  for v in b1.data {
    d1.push(v)
  }
  tput(
    s,
    "\{ns}/vec/global/g-base/part-0.bin",
    @format.encode_global_part(0, [(0, 0), (0, 1), (1, 0)], 2, d0, false),
  )
  tput(
    s,
    "\{ns}/vec/global/g-base/part-1.bin",
    @format.encode_global_part(1, [(0, 2), (0, 3), (1, 1)], 2, d1, false),
  )
  tput(
    s,
    "\{ns}/vec/global/g-base/meta.json",
    @utf8.encode(
      "{\"cids\":[0,1],\"dim\":2,\"normalized\":false,\"kind\":\"base\"}",
    ),
  )
  // delta 代：只含新段 seg-01C 的两行
  tput(
    s,
    "\{ns}/vec/global/g-delta/part-0.bin",
    @format.encode_global_part(0, [(2, 0)], 2, [10.2, 0.0], false),
  )
  tput(
    s,
    "\{ns}/vec/global/g-delta/part-1.bin",
    @format.encode_global_part(1, [(2, 1)], 2, [0.0, 10.1], false),
  )
  tput(
    s,
    "\{ns}/vec/global/g-delta/meta.json",
    @utf8.encode(
      "{\"cids\":[0,1],\"dim\":2,\"normalized\":false,\"kind\":\"delta\",\"base\":\"g-base\",\"seg_ids\":[\"seg-01C\"]}",
    ),
  )
  let n0 = open(s, ns)
  let segs : Array[@format.SegmentMeta] = Array::new()
  for sm in n0.manifest.segments {
    segs.push(sm)
  }
  segs.push({
    id: "seg-01C",
    row_count: 2,
    min_id: 7UL,
    max_id: 8UL,
    doc_len_sum: 4,
    size_bytes: 0,
  })
  let man2 : @format.ManifestData = {
    id: "manifest-02",
    parent: Some(n0.manifest.id),
    segments: segs,
    deleted,
    deleted_roar: None,
    vec_global_version: Some("g-base"),
    global_gen: Some({ base: "g-base", deltas: ["g-delta"] }),
    centroid_version: n0.manifest.centroid_version,
    num_docs: 8,
    avg_doc_len: 24.0 / 8.0,
  }
  tput(
    s,
    "\{ns}/_manifest/manifest-02.json",
    @utf8.encode(man2.to_json().stringify()),
  )
  let meta2 : @format.NamespaceMeta = {
    ..n0.meta,
    head_manifest: "manifest-02",
    vec_global_version: Some("g-base"),
  }
  tput(
    s,
    "\{ns}/_meta/namespace.json",
    @utf8.encode(meta2.to_json().stringify()),
  )
  s
}

///|
test "S2a global delta chain merges base and delta rows" {
  let s = make_delta_chain_store([])
  let n = open(s, "test")
  assert_eq(n.manifest.global_gen is Some(_), true)
  assert_eq(n.manifest.segments.length(), 3)
  // 手工 cosine（q=[1,0]，seg meta 未标 vec_normalized ⇒ score = 1 - dist = cos）
  //   id7 [10.2,0.0] = 1.000000（delta / seg-01C）
  //   id1 [10.1,0.2] ≈ 0.999804
  //   id2 [9.8,-0.3] ≈ 0.999532
  //   id5 [9.5,0.5]  ≈ 0.998617
  //   id3 [0.4,9.5]  ≈ 0.042066
  //   id4 [0.1,10.2] ≈ 0.009803
  //   id8 [0.0,10.1] = 0.000000（delta / seg-01C）
  //   id6 [-0.2,9.9] ≈ -0.020198
  let r = vec_search(n, [1.0, 0.0], 10, 2, None)
  assert_eq(ids_of(r), [7UL, 1UL, 2UL, 5UL, 3UL, 4UL, 8UL, 6UL])
  assert_eq(approx(r[0].score, 1.0, 1.0e-6), true)
  assert_eq(approx(r[1].score, 0.999804, 1.0e-4), true)
  assert_eq(approx(r[6].score, 0.0, 1.0e-6), true)
  // 两个 cid 都存在：base 的 part-0/1 与 delta 的 part-0/1 都读到（候选合并）
  assert_eq(r.length(), 8)
  // 同一 query，k=1 只留 delta 行（证明 delta 行参与了打分而不是被跳过）
  let top = vec_search(n, [1.0, 0.0], 1, 2, None)
  assert_eq(ids_of(top), [7UL])
  // filter 仍按 (seg_idx, row) 应用：ts=700 只命中 seg-01C 的 row 0
  let f = vec_search(n, [1.0, 0.0], 10, 2, Some(f_i64("ts", 700L)))
  assert_eq(ids_of(f), [7UL])
}

///|
test "S2a global delta chain skips cid absent from delta meta" {
  let s = make_delta_chain_store([])
  // delta 代只声明 cid 0，且真的没有 part-1：probe cid 1 时该代是合法空分区，
  // 不能报错，也不能让整次查询变空。
  tdel(s, "test/vec/global/g-delta/part-1.bin")
  tput(
    s,
    "test/vec/global/g-delta/meta.json",
    @utf8.encode(
      "{\"cids\":[0],\"dim\":2,\"normalized\":false,\"kind\":\"delta\",\"base\":\"g-base\"}",
    ),
  )
  let n = open(s, "test")
  // q=[0,1]：id4≈0.999952 > id6≈0.999796 > id3≈0.999115 > id5≈0.052559
  //   > id1≈0.019798 > id7(delta,cid0)≈0.0 > id2≈-0.030598
  // id8 本在 delta 的 part-1 里（已删且 delta meta 不再声明 cid1），所以它不出现；
  // 关键是不能报错、也不能把 base 的 cid1 行一起丢掉。
  let r = vec_search(n, [0.0, 1.0], 10, 2, None)
  assert_eq(ids_of(r), [4UL, 6UL, 3UL, 5UL, 1UL, 7UL, 2UL])
  // base 的 cid1 行（id3/4/6）与 delta 的 cid0 行（id7）都在，没有整体丢失
  assert_eq(r.length(), 7)
  assert_eq(r[0].id, 4UL)
  // probe 只剩 cid 0 时 delta 代仍然被读到（id7 来自 delta）
  let only0 = vec_search(n, [10.0, 0.0], 10, 1, None)
  assert_eq(ids_of(only0), [7UL, 1UL, 2UL, 5UL])
}

///|
test "S2a global delta chain missing delta meta raises NotFound" {
  let s = make_delta_chain_store([])
  let n0 = open(s, "test")
  let bad : @format.ManifestData = {
    ..n0.manifest,
    global_gen: Some({ base: "g-base", deltas: ["g-absent"] }),
  }
  tput(
    s,
    "test/_manifest/manifest-02.json",
    @utf8.encode(bad.to_json().stringify()),
  )
  let n = open(s, "test")
  try {
    let _ = vec_search(n, [1.0, 0.0], 10, 2, None)
    fail("expected NotFound")
  } catch {
    @core.NotFound(_) => ()
    _ => fail("expected NotFound")
  }
}

///|
test "S2a global delta chain delta meta missing cids raises" {
  let s = make_delta_chain_store([])
  // delta 代 meta 在但缺 cids：不能当成空代静默跳过
  tput(s, "test/vec/global/g-delta/meta.json", @utf8.encode("{\"dim\":2}"))
  let n = open(s, "test")
  try {
    let _ = vec_search(n, [1.0, 0.0], 10, 2, None)
    fail("expected Corrupt")
  } catch {
    @core.Corrupt(_) => ()
    _ => fail("expected Corrupt")
  }
}

///|
test "S2a global delta chain applies tombstones across generations" {
  let s = make_delta_chain_store([7UL])
  let n = open(s, "test")
  let ids = sorted_ids(vec_search(n, [10.0, 0.0], 10, 2, None))
  // delta 行 id=7 被 tombstone 过滤；base 行与 delta 的 id=8 仍可见。
  assert_eq(ids.contains(7UL), false)
  assert_eq(ids.contains(8UL), true)
  assert_eq(ids.contains(1UL), true)
}

///|
test "warm query path has ZERO S3 calls and serves directly from memory" {
  let s = make_delta_chain_store([7UL])
  let cache : MetadataCache[@store.MemStore] = MetadataCache::new()
  let n = open_cached(cache, s, "test")
  // First query (cold): loads centroids, global parts, segment metadata, tombstones
  let r1 = vec_search(n, [10.0, 0.0], 10, 2, None)
  assert_eq(r1.length() > 0, true)
  // Reset store metrics
  s.reset_cost()
  // Warm query 1: same probe
  let r2 = vec_search(n, [10.0, 0.0], 10, 2, None)
  assert_eq(ids_of(r2), ids_of(r1))
  assert_eq(s.cost().gets, 0)
  assert_eq(s.cost().ranged_gets, 0)
  // Warm query 2: different probe / vector (e.g. probes cid 1)
  let r3 = vec_search(n, [0.0, 10.0], 10, 2, None)
  assert_eq(r3.length() > 0, true)
  assert_eq(s.cost().gets, 0)
  assert_eq(s.cost().ranged_gets, 0)
  // Warm query 3: via open_cached (verifying MetadataCache hit)
  let n_warm = open_cached(cache, s, "test")
  let r4 = vec_search(n_warm, [1.0, 0.0], 10, 2, None)
  assert_eq(r4.length() > 0, true)
  assert_eq(s.cost().gets, 0)
  assert_eq(s.cost().ranged_gets, 0)
}

///|
test "warm_namespace preloads all components resulting in zero S3 calls on first query" {
  let s = make_delta_chain_store([7UL])
  let n = open(s, "test")
  warm_namespace(n)
  s.reset_cost()
  let r = vec_search(n, [10.0, 0.0], 10, 2, None)
  assert_eq(r.length() > 0, true)
  assert_eq(s.cost().gets, 0)
  assert_eq(s.cost().ranged_gets, 0)
}
