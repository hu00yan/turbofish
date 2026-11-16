// SlabV2 单文件段（L0 Delta Slab）透明读取白盒测试。
//
// 手写两个 namespace，覆盖：
//   A. "slabq"（per-segment IVF + euclidean）：传统碎片段 seg-la + SlabV2 单文件段
//      seg-sa 共存于同一 manifest。slab 段的组件（id/text/category/ts/public/
//      vector/fts dir/postings/doc_len/vec part）全部打包在 segment.slab 内，
//      Index 位于文件尾部（走"补拉尾部"分支）。
//   B. "slabg"（Global IVF）：Base 段读 packs；L0 SlabV2 增量段只有
//      `rows/vector.bin` 组件（未合入 global），验证精确扫描 + Top-K 归并、
//      tombstone 过滤与"同 id 以更晚段为准"的去重语义。
//
// 覆盖点：bm25 从 slab 命中、vec 精确命中（+ filter）、hybrid 融合、
// slab/碎片共存合并与去重、i64/bool/字典列从 slab 读取。

///|
/// SlabV2 段的 meta.json（可带 seg_seq 标注）。
fn slab_seg_meta_json(
  seg_id : String,
  row_count : Int,
  min_id : UInt64,
  max_id : UInt64,
  partitions : Array[Int],
  seg_seq : Int,
) -> Bytes {
  let m : Map[String, Json] = Map([])
  m.set("id", Json::string(seg_id))
  m.set("row_count", Json::number(row_count.to_double()))
  m.set("min_id", Json::number(min_id.to_double()))
  m.set("max_id", Json::number(max_id.to_double()))
  m.set("format", Json::string("slab_v2"))
  let pj : Array[Json] = Array()
  for c in partitions {
    pj.push(Json::number(c.to_double()))
  }
  m.set("partitions", Json::array(pj))
  if seg_seq >= 0 {
    m.set("seg_seq", Json::number(seg_seq.to_double()))
  }
  @utf8.encode(Json::object(m).stringify())
}

///|
/// 把一个段的全部组件打包成单个 `segment.slab`（index_at_end 覆盖两种布局）。
async fn slab_seed(
  s : @store.MemStore,
  ns : String,
  seg_id : String,
  ids : Array[UInt64],
  texts : Array[String],
  cats : Array[String],
  tss : Array[Int64],
  pubs : Array[Bool],
  flat : Array[Float],
  dim : Int,
  doc_len : Array[Int],
  lists : Array[(String, Array[@format.Posting])],
  with_vector : Bool,
  parts : Array[(Int, Array[Int], Array[Float])],
  partitions : Array[Int],
  seg_seq : Int,
  index_at_end : Bool,
) -> Int {
  let n = ids.length()
  let comps : Array[@format.SlabComponentPayload] = Array()
  comps.push(
    @format.SlabComponentPayload::new(
      "id", @format.encode_col(@format.ColU64(ids)), n,
    ),
  )
  comps.push(
    @format.SlabComponentPayload::new(
      "text", @format.encode_col_str_plain(texts), n,
    ),
  )
  comps.push(
    @format.SlabComponentPayload::new(
      "category", @format.encode_col(@format.ColStr(cats)), n,
    ),
  )
  comps.push(
    @format.SlabComponentPayload::new(
      "ts", @format.encode_col(@format.ColI64(tss)), n,
    ),
  )
  comps.push(
    @format.SlabComponentPayload::new(
      "public", @format.encode_col(@format.ColBool(pubs)), n,
    ),
  )
  if with_vector {
    comps.push(
      @format.SlabComponentPayload::new(
        "vector", @format.encode_vec_col(dim, flat, false), n,
      ),
    )
  }
  let built = @format.encode_fts(lists)
  comps.push(
    @format.SlabComponentPayload::new("fts/dir", built.dir, lists.length()),
  )
  comps.push(
    @format.SlabComponentPayload::new(
      "fts/postings", built.postings, built.entries.length(),
    ),
  )
  comps.push(
    @format.SlabComponentPayload::new(
      "fts/doc_len", @format.encode_col(@format.ColU32(doc_len)), n,
    ),
  )
  for p in parts {
    let (cid, rows, data) = p
    comps.push(
      @format.SlabComponentPayload::new(
        "vec/part-\{cid}",
        @format.encode_part({ cid, rows, dim, data }, false),
        rows.length(),
      ),
    )
  }
  let (slab, _index) = @format.encode_slab(comps, index_at_end~)
  tput(s, "\{ns}/_segments/\{seg_id}/segment.slab", slab)
  tput(
    s,
    "\{ns}/_segments/\{seg_id}/meta.json",
    slab_seg_meta_json(
      seg_id,
      n,
      ids[0],
      ids[n - 1],
      partitions,
      seg_seq,
    ),
  )
  slab.length()
}

///|
/// 传统碎片文件布局的段（rows/*.bin + fts/*.bin + vec/part-*.bin）。
async fn legacy_seed(
  s : @store.MemStore,
  ns : String,
  seg_id : String,
  ids : Array[UInt64],
  texts : Array[String],
  cats : Array[String],
  tss : Array[Int64],
  pubs : Array[Bool],
  flat : Array[Float],
  dim : Int,
  doc_len : Array[Int],
  lists : Array[(String, Array[@format.Posting])],
  parts : Array[(Int, Array[Int], Array[Float])],
  partitions : Array[Int],
) -> Unit {
  let n = ids.length()
  let base = "\{ns}/_segments/\{seg_id}"
  let built = @format.encode_fts(lists)
  tput(s, "\{base}/fts/dir.bin", built.dir)
  tput(s, "\{base}/fts/postings.bin", built.postings)
  tput(s, "\{base}/fts/doc_len.bin", @format.encode_col(@format.ColU32(doc_len)))
  tput(s, "\{base}/rows/id.bin", @format.encode_col(@format.ColU64(ids)))
  tput(s, "\{base}/rows/text.bin", @format.encode_col_str_plain(texts))
  tput(s, "\{base}/rows/category.bin", @format.encode_col(@format.ColStr(cats)))
  tput(s, "\{base}/rows/ts.bin", @format.encode_col(@format.ColI64(tss)))
  tput(s, "\{base}/rows/public.bin", @format.encode_col(@format.ColBool(pubs)))
  tput(s, "\{base}/rows/vector.bin", @format.encode_vec_col(dim, flat, false))
  for p in parts {
    let (cid, rows, data) = p
    tput(
      s,
      "\{base}/vec/part-\{cid}.bin",
      @format.encode_part({ cid, rows, dim, data }, false),
    )
  }
  tput(
    s,
    "\{base}/meta.json",
    slab_seg_meta_json(seg_id, n, ids[0], ids[n - 1], partitions, -1),
  )
}

///|
/// 写入 namespace.json + manifest.json + centroids。
async fn seed_namespace(
  s : @store.MemStore,
  ns : String,
  meta : @format.NamespaceMeta,
  man : @format.ManifestData,
  cent : @format.Centroids,
) -> Unit {
  tput(s, "\{ns}/_meta/namespace.json", @utf8.encode(meta.to_json().stringify()))
  tput(
    s,
    "\{ns}/_manifest/\{man.id}.json",
    @utf8.encode(man.to_json().stringify()),
  )
  tput(
    s,
    "\{ns}/_centroids/\{man.centroid_version}.bin",
    @format.encode_centroids(cent),
  )
}

///|
/// 构造两个 namespace：A = 碎片段 + SlabV2 段共存（per-segment IVF）；
/// B = Global IVF Base + 未合入 global 的 L0 SlabV2 增量段。
async fn make_slab_store() -> @store.MemStore {
  let s = @store.MemStore::new()
  let cent : @format.Centroids = { dim: 2, data: [10.0, 0.0, 0.0, 10.0] }

  // ---------------- namespace A: "slabq"（euclidean，per-segment IVF）--------
  let nsa = "slabq"
  let lists_la : Array[(String, Array[@format.Posting])] = [
    ("fox", [{ row: 0, tf: 1 }, { row: 1, tf: 1 }]),
    ("jumps", [{ row: 0, tf: 1 }]),
    ("legacy", [{ row: 1, tf: 1 }]),
  ]
  legacy_seed(
    s,
    nsa,
    "seg-la",
    [1UL, 2UL],
    ["fox jumps", "legacy fox"],
    ["a", "b"],
    [100L, 200L],
    [true, false],
    [10.0, 0.0, 1.0, 0.0],
    2,
    [2, 2],
    lists_la,
    [(0, [0, 1], [10.0, 0.0, 1.0, 0.0])],
    [0],
  )
  // slab 段：id 2 与 seg-la 重复（更晚 → 覆盖），id 3 全新。
  let lists_sa : Array[(String, Array[@format.Posting])] = [
    ("slab", [{ row: 0, tf: 1 }, { row: 1, tf: 1 }]),
    ("fox", [{ row: 0, tf: 1 }]),
    ("only", [{ row: 1, tf: 1 }]),
  ]
  let size_a = slab_seed(
    s,
    nsa,
    "seg-sa",
    [2UL, 3UL],
    ["slab fox", "slab only"],
    ["c", "c"],
    [300L, 400L],
    [true, false],
    [10.0, 0.0, 0.0, 10.0],
    2,
    [2, 2],
    lists_sa,
    true,
    [(0, [0], [10.0, 0.0]), (1, [1], [0.0, 10.0])],
    [0, 1],
    -1,
    true, // Index 位于文件尾部（走补拉尾部路径）
  )
  let meta_a : @format.NamespaceMeta = {
    format: "seekpond/v1",
    ns_name: nsa,
    head_manifest: "manifest-a-01",
    vec_global_version: None,
    distance_metric: "euclidean",
    vector_dim: 2,
    vector_dtype: "f32",
    k1: 1.2,
    b: 0.75,
    fts_tokenizer: None,
  }
  let man_a : @format.ManifestData = {
    id: "manifest-a-01",
    parent: None,
    segments: [
      {
        id: "seg-la",
        row_count: 2,
        min_id: 1UL,
        max_id: 2UL,
        doc_len_sum: 4,
        size_bytes: 0,
      },
      {
        id: "seg-sa",
        row_count: 2,
        min_id: 2UL,
        max_id: 3UL,
        doc_len_sum: 4,
        size_bytes: size_a,
      },
    ],
    deleted: [],
    deleted_roar: None,
    vec_global_version: None,
    global_gen: None,
    centroid_version: "centroids-1",
    num_docs: 4,
    avg_doc_len: 2.0,
  }
  seed_namespace(s, nsa, meta_a, man_a, cent)

  // ---------------- namespace B: "slabg"（cosine，Global IVF）----------------
  let nsb = "slabg"
  legacy_seed(
    s,
    nsb,
    "seg-lb",
    [1UL, 2UL],
    ["base one", "base two"],
    ["a", "b"],
    [10L, 20L],
    [true, false],
    [10.0, 0.0, 0.0, 10.0],
    2,
    [2, 2],
    [("base", [{ row: 0, tf: 1 }, { row: 1, tf: 1 }])],
    [
      (0, [0], [10.0, 0.0]),
      (1, [1], [0.0, 10.0]),
    ],
    [0, 1],
  )
  // L0 增量段：只带 rows/vector.bin（未合入 Global IVF），无 vec/part。
  let _ = slab_seed(
    s,
    nsb,
    "seg-sb",
    [2UL, 3UL],
    ["delta two", "delta three"],
    ["z", "z"],
    [30L, 40L],
    [true, false],
    [10.0, 0.0, 0.0, 10.0],
    2,
    [2, 2],
    [("delta", [{ row: 0, tf: 1 }, { row: 1, tf: 1 }])],
    true,
    [],
    [],
    7, // seg_seq 标注：唯一的 slab 增量段
    false, // Index 位于固定偏移（1 次 Range GET 解码）
  )
  // Global IVF Base 段（只含 legacy seg 的行）：
  //   cid 0 → seg 0 row 0（id 1），cid 1 → seg 0 row 1（id 2）。
  tput(
    s,
    "\{nsb}/vec/global/g1/part-0.bin",
    @format.encode_global_part(0, [(0, 0)], 2, [10.0, 0.0], false),
  )
  tput(
    s,
    "\{nsb}/vec/global/g1/part-1.bin",
    @format.encode_global_part(1, [(0, 1)], 2, [0.0, 10.0], false),
  )
  let gm : Map[String, Json] = Map([])
  let cids : Array[Json] = [Json::number(0.0), Json::number(1.0)]
  gm.set("cids", Json::array(cids))
  tput(s, "\{nsb}/vec/global/g1/meta.json", @utf8.encode(Json::object(gm).stringify()))
  let meta_b : @format.NamespaceMeta = {
    format: "seekpond/v1",
    ns_name: nsb,
    head_manifest: "manifest-b-01",
    vec_global_version: Some("g1"),
    distance_metric: "cosine",
    vector_dim: 2,
    vector_dtype: "f32",
    k1: 1.2,
    b: 0.75,
    fts_tokenizer: None,
  }
  let man_b : @format.ManifestData = {
    id: "manifest-b-01",
    parent: None,
    segments: [
      {
        id: "seg-lb",
        row_count: 2,
        min_id: 1UL,
        max_id: 2UL,
        doc_len_sum: 4,
        size_bytes: 0,
      },
      {
        id: "seg-sb",
        row_count: 2,
        min_id: 2UL,
        max_id: 3UL,
        doc_len_sum: 4,
        size_bytes: 0,
      },
    ],
    deleted: [3UL], // slab 增量段的 id 3 已软删除
    deleted_roar: None,
    vec_global_version: Some("g1"),
    global_gen: None,
    centroid_version: "centroids-1",
    num_docs: 4,
    avg_doc_len: 2.0,
  }
  seed_namespace(s, nsb, meta_b, man_b, cent)
  s
}

///|
async test "slab v2: bm25 从单文件段命中并经统一入口合并去重" {
  let s = make_slab_store()
  let n = open(s, "slabq")
  // 只有 slab 段含 "slab" 词：id 2 / id 3 必须命中。
  let r = bm25_search(n, "slab", 10, None)
  assert_eq(sorted_ids(r), [2UL, 3UL])
  for x in r {
    assert_eq(x.score > 0.0, true)
  }
  // "only" 只出现在 slab 段第二行。
  let r2 = bm25_search(n, "only", 10, None)
  assert_eq(sorted_ids(r2), [3UL])
  // "fox" 同时命中碎片段（id 1、id 2）与 slab 段（id 2）：合并后按 id 去重，
  // 同一 doc.id 以 manifest 更靠后的段（slab，seg-sa）为准。
  let r3 = bm25_search(n, "fox", 10, None)
  assert_eq(sorted_ids(r3), [1UL, 2UL])
  assert_eq(r3.length(), 2)
  // ts 列（i64）与 public 列（位图 bool）都从 segment.slab 组件读取。
  assert_eq(sum_field(n, "ts", None), 1000.0)
  assert_eq(sum_field(n, "ts", Some(f_i64("ts", 300L))), 300.0)
  assert_eq(count_docs(n, Some(f_bool("public", true))), 2)
}

///|
async test "slab v2: vec_search 从单文件段精确命中（含 filter 下推）" {
  let s = make_slab_store()
  let n = open(s, "slabq")
  // filter 只命中 slab 段的 category="c" 两行：向量来自 slab 的 vec/part 组件。
  let r = vec_search(n, [10.0, 0.0], 10, 2, Some(f_str("category", "c")))
  assert_eq(sorted_ids(r), [2UL, 3UL])
  // euclidean：score = -l2sq。id 2 = [10,0] → 0；id 3 = [0,10] → -200。
  let by_id : Map[UInt64, Double] = Map([])
  for x in r {
    by_id.set(x.id, x.score)
  }
  assert_eq(approx(by_id.get(2UL).unwrap(), 0.0, 1.0e-6), true)
  assert_eq(approx(by_id.get(3UL).unwrap(), -200.0, 1.0e-6), true)
  // 无 filter：碎片段与 slab 段合并，id 2 只出现一次且用更晚段（slab）的分数。
  let r2 = vec_search(n, [10.0, 0.0], 10, 2, None)
  assert_eq(sorted_ids(r2), [1UL, 2UL, 3UL])
  let seen : Set[UInt64] = Set([])
  for x in r2 {
    assert_eq(seen.contains(x.id), false)
    seen.add(x.id)
  }
  let best2 : Map[UInt64, Double] = Map([])
  for x in r2 {
    best2.set(x.id, x.score)
  }
  assert_eq(approx(best2.get(2UL).unwrap(), 0.0, 1.0e-6), true)
  // 列式下推引擎同样从 slab 组件读列。
  let m = matching_ids(n, f_str("category", "c"))
  m.sort()
  assert_eq(m, [2UL, 3UL])
}

///|
async test "slab v2: hybrid_search 融合 slab 与碎片段两路结果" {
  let s = make_slab_store()
  let n = open(s, "slabq")
  let bm = bm25_search(n, "fox", 10, None)
  let vs = vec_search(n, [10.0, 0.0], 10, 2, None)
  let hy = hybrid_search(n, "fox", [10.0, 0.0], 10, 2, None)
  // 三路 id 集合一致（bm/vec 各自去重后都是 {1,2,3}）。
  assert_eq(sorted_ids(hy), [1UL, 2UL, 3UL])
  // id 2 同时出现在两路：RRF 分 = 1/(60+rank_bm) + 1/(60+rank_vec)。
  let mut rank_bm = 0
  for i, x in bm {
    if x.id == 2UL {
      rank_bm = i + 1
    }
  }
  let mut rank_vs = 0
  for i, x in vs {
    if x.id == 2UL {
      rank_vs = i + 1
    }
  }
  assert_eq(rank_bm > 0, true)
  assert_eq(rank_vs > 0, true)
  let expected = 1.0 / (60.0 + rank_bm.to_double()) +
    1.0 / (60.0 + rank_vs.to_double())
  let mut got = 0.0
  for x in hy {
    if x.id == 2UL {
      got = x.score
    }
  }
  assert_eq(approx(got, expected, 1.0e-9), true)
  // 混合结果里没有任何 slab 段独有的 id 缺失。
  assert_eq(hy.length(), 3)
}

///|
async test "slab v2: global IVF base 与未合入的 L0 slab 增量段归并" {
  let s = make_slab_store()
  let n = open(s, "slabg")
  // nprobe=1 只探到 base 的 cid 0：base 只给 id 1；id 2 只能来自 L0 slab 增量段
  // （其 rows/vector.bin 组件与 base 的旧 id 2 冲突 → 新段覆盖；id 3 被 tombstone）。
  let r = vec_search(n, [10.0, 0.0], 10, 1, None)
  assert_eq(sorted_ids(r), [1UL, 2UL])
  let by_id : Map[UInt64, Double] = Map([])
  for x in r {
    by_id.set(x.id, x.score)
  }
  // cosine：slab 段的 id 2 = [10,0] → 1.0（base 里旧 id 2 = [0,10] → 0.0，
  // 若没有"新段覆盖"语义会返回 0.0）。
  assert_eq(approx(by_id.get(2UL).unwrap(), 1.0, 1.0e-6), true)
  assert_eq(approx(by_id.get(1UL).unwrap(), 1.0, 1.0e-6), true)
  // nprobe=2：两代结果合并后仍然每个 id 只出现一次，tombstone 的 id 3 不出现。
  let r2 = vec_search(n, [10.0, 0.0], 10, 2, None)
  assert_eq(sorted_ids(r2), [1UL, 2UL])
  let seen : Set[UInt64] = Set([])
  for x in r2 {
    assert_eq(seen.contains(x.id), false)
    seen.add(x.id)
  }
  // 带 filter 的路径同样先走 pushdown，再融合 slab 增量段候选。
  let r3 = vec_search(n, [10.0, 0.0], 10, 2, Some(f_str("category", "z")))
  assert_eq(sorted_ids(r3), [2UL])
}

///|
async test "slab v2: SlabIndex 惰性解码常驻 CachedSeg，warm 查询零 I/O" {
  let s = make_slab_store()
  let n = open(s, "slabq")
  // 冷查询：1 次 Range GET 解 Header(+Index)，再按组件精读。
  let _ = bm25_search(n, "slab", 10, None)
  let _ = vec_search(n, [10.0, 0.0], 10, 2, None)
  let cs = n.cache.get("seg-sa").unwrap()
  assert_eq(cs.slab_tried, true)
  let idx = cs.slab_index.unwrap()
  assert_eq(idx.get("id") is Some(_), true)
  assert_eq(idx.get("vector") is Some(_), true)
  assert_eq(idx.get("fts/dir") is Some(_), true)
  assert_eq(idx.get("fts/postings") is Some(_), true)
  assert_eq(idx.get("fts/doc_len") is Some(_), true)
  assert_eq(idx.get("vec/part-1") is Some(_), true)
  // 碎片段没有 segment.slab：slab_index 为 None 且只探测一次。
  let legacy = n.cache.get("seg-la").unwrap()
  assert_eq(legacy.slab_tried, true)
  assert_eq(legacy.slab_index is None, true)
  // warm 向量查询：Index、vec part 全在内存 → 零 GET / 零 Ranged GET。
  s.reset_cost()
  let _ = vec_search(n, [10.0, 0.0], 10, 2, None)
  assert_eq(s.cost().gets, 0)
  assert_eq(s.cost().ranged_gets, 0)
  // warm BM25：与碎片布局一致，只重读 term 的 posting 局部区间（1 次 Range GET），
  // SlabIndex 不再重新探测/解码。
  s.reset_cost()
  let _ = bm25_search(n, "slab", 10, None)
  assert_eq(s.cost().gets, 0)
  assert_eq(s.cost().ranged_gets, 1)
  // 瓦片化：索引对每个 term 各发 1 次（"slab" 只有 1 个 term）。
  s.reset_cost()
  let _ = bm25_search(n, "slab only", 10, None)
  assert_eq(s.cost().gets, 0)
  assert_eq(s.cost().ranged_gets, 2)
}
