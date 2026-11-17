// format 包 roundtrip 测试。

///|
test "col u64/u32/i64/f32/bool roundtrip" {
  let u : UInt64 = 18446744073709551615UL
  let a = [1UL, 2UL, u]
  match decode_col(encode_col(ColU64(a))) {
    ColU64(arr) => assert_eq(arr, a)
    _ => fail("wrong type")
  }
  let b32 = [0, 7, 2147483647]
  match decode_col(encode_col(ColU32(b32))) {
    ColU32(arr) => assert_eq(arr, b32)
    _ => fail("wrong type")
  }
  let neg = -9223372036854775807L - 1L
  let i64s = [1L, -2L, neg]
  match decode_col(encode_col(ColI64(i64s))) {
    ColI64(arr) => assert_eq(arr, i64s)
    _ => fail("wrong type")
  }
  let fs : Array[Float] = [1.5, -2.25, 3.14159]
  match decode_col(encode_col(ColF32(fs))) {
    ColF32(arr) =>
      for i in 0..<fs.length() {
        assert_eq(arr[i], fs[i])
      }
    _ => fail("wrong type")
  }
  let bs = [true, false, true]
  match decode_col(encode_col(ColBool(bs))) {
    ColBool(arr) => assert_eq(arr, bs)
    _ => fail("wrong type")
  }
}

///|
test "col string roundtrip with utf8" {
  let strs = ["alpha", "beta", "中文测试", "mixed中en文", "", "🉑emoji"]
  match decode_col(encode_col(ColStr(strs))) {
    ColStr(arr) => assert_eq(arr, strs)
    _ => fail("wrong type")
  }
}

///|
test "vec col f32 and f16 roundtrip" {
  let dim = 4
  let data : Array[Float] = [0.5, -1.25, 100.0, 0.001, 2.5, 3.5, 4.5, 5.5]
  let (d1, out1) = decode_vec_col(encode_vec_col(dim, data, false))
  assert_eq(d1, dim)
  for i in 0..<data.length() {
    assert_eq(out1[i], data[i])
  }
  let (_, out2) = decode_vec_col(encode_vec_col(dim, data, true))
  for i in 0..<data.length() {
    let err = (out2[i].to_double() - data[i].to_double()).abs()
    // f16 量化误差应在千分量级
    assert_eq(err < data[i].to_double().abs() * 0.001 + 0.002, true)
  }
}

///|
test "fts encode/read_postings roundtrip" {
  let lists : Array[(String, Array[Posting])] = [
    ("apple", [{ row: 0, tf: 2 }, { row: 3, tf: 1 }, { row: 10, tf: 4 }]),
    ("香蕉", [{ row: 1, tf: 1 }]),
    ("zoo", [{ row: 2, tf: 1 }, { row: 9, tf: 9 }]),
  ]
  let built = encode_fts(lists)
  let entries = decode_fts_dir(built.dir)
  assert_eq(entries.length(), 3)
  // 目录按 term_compare（UTF-8 字节序）有序：与查询二分同一比较器。
  // （历史坑：String::compare 长度优先，"香蕉" 多字节多字 term 位移到尾部，
  //  与字节序二分错位 → CJK 多字查询必失败。本用例的 ASCII+CJK 混排即回归锚点。）
  for i in 1..<entries.length() {
    assert_eq(term_compare(entries[i - 1].term, entries[i].term) <= 0, true)
  }
  // 按 term 查找并验证 posting 内容
  let mut apple_entry : FtsDirEntry? = None
  let mut banana_entry : FtsDirEntry? = None
  let mut zoo_entry : FtsDirEntry? = None
  for e in entries {
    match e.term {
      "apple" => apple_entry = Some(e)
      "香蕉" => banana_entry = Some(e)
      "zoo" => zoo_entry = Some(e)
      _ => fail("unexpected term")
    }
  }
  match apple_entry {
    Some(e) => {
      let p = read_postings(built.postings, e)
      assert_eq(p.length(), 3)
      assert_eq(p[0].row, 0)
      assert_eq(p[0].tf, 2)
      assert_eq(p[2].row, 10)
      assert_eq(p[2].tf, 4)
    }
    None => fail("missing apple")
  }
  match banana_entry {
    Some(e) => {
      let p = read_postings(built.postings, e)
      assert_eq(p[0].row, 1)
      assert_eq(p[0].tf, 1)
    }
    None => fail("missing 香蕉")
  }
  match zoo_entry {
    Some(e) => assert_eq(e.df, 2)
    None => fail("missing zoo")
  }
}

///|
test "centroids and part roundtrip" {
  let c : Centroids = { dim: 3, data: [1.0, 2.0, 3.0, 4.0, 5.0, 6.0] }
  let c2 = decode_centroids(encode_centroids(c))
  assert_eq(c2.k(), 2)
  assert_eq(c2.data[4], 5.0)
  let p : VecPart = {
    cid: 7,
    rows: [3, 9, 11],
    dim: 2,
    data: [1.0, 2.0, 3.0, 4.0, 5.0, 6.0],
  }
  let p2 = decode_part(encode_part(p, false))
  assert_eq(p2.cid, 7)
  assert_eq(p2.rows, [3, 9, 11])
  assert_eq(p2.data[5], 6.0)
  let p3 = decode_part(encode_part(p, true))
  assert_eq(p3.rows, [3, 9, 11])
  assert_eq(p3.data[3] > 3.9 && p3.data[3] < 4.1, true)
}

///|
test "manifest json roundtrip" {
  let m : ManifestData = {
    id: "manifest-01TEST",
    parent: Some("manifest-00PARENT"),
    segments: [
      {
        id: "seg-01A",
        row_count: 100,
        min_id: 1UL,
        max_id: 100UL,
        doc_len_sum: 1800,
        size_bytes: 123456,
      },
    ],
    deleted: [5UL, 77UL],
    deleted_roar: None,
    vec_global_version: None,
    global_gen: None,
    centroid_version: "centroids-01C",
    num_docs: 100,
    avg_doc_len: 18.0,
  }
  let parsed = manifest_from_json(m.to_json())
  assert_eq(parsed.id, m.id)
  assert_eq(parsed.parent, m.parent)
  assert_eq(parsed.segments.length(), 1)
  assert_eq(parsed.segments[0].id, "seg-01A")
  assert_eq(parsed.segments[0].min_id, 1UL)
  assert_eq(parsed.deleted, m.deleted)
  assert_eq(parsed.centroid_version, m.centroid_version)
}

///|
/// `global_gen`（base + deltas 代际链）的 JSON 往返。
/// - Some：写 `"global_gen":{"base":...,"deltas":[...]}`，解析回来一致；
/// - None：**不写** `global_gen` 键（旧 manifest JSON 字节不变），解析回来也是 None。
test "manifest global_gen json roundtrip" {
  let m : ManifestData = {
    id: "manifest-02GEN",
    parent: Some("manifest-01BASE"),
    segments: [],
    deleted: [],
    deleted_roar: None,
    vec_global_version: Some("manifest-01BASE"),
    global_gen: Some({ base: "manifest-01BASE", deltas: ["d1", "d2"] }),
    centroid_version: "centroids-01C",
    num_docs: 0,
    avg_doc_len: 0.0,
  }
  let s = m.to_json().stringify()
  assert_eq(s.contains("\"global_gen\""), true)
  let parsed = manifest_from_json(m.to_json())
  let g = match parsed.global_gen {
    Some(g) => g
    None => fail("global_gen lost in roundtrip")
  }
  assert_eq(g.base, "manifest-01BASE")
  assert_eq(g.deltas, ["d1", "d2"])
  assert_eq(parsed.vec_global_version, Some("manifest-01BASE"))
  // 空 deltas 也要能往返（全量 base 的新布局）
  let g0 : ManifestData = {
    ..m,
    id: "manifest-03BASE",
    global_gen: Some({ base: "manifest-03BASE", deltas: [] }),
  }
  let p0 = manifest_from_json(g0.to_json())
  match p0.global_gen {
    Some(x) => {
      assert_eq(x.base, "manifest-03BASE")
      assert_eq(x.deltas.length(), 0)
    }
    None => fail("empty-delta global_gen lost")
  }
  // None：键不出现（保证旧布局字节兼容）
  let legacy : ManifestData = { ..m, global_gen: None }
  assert_eq(legacy.to_json().stringify().contains("global_gen"), false)
  assert_eq(manifest_from_json(legacy.to_json()).global_gen is None, true)
}

///|
test "namespace json roundtrip" {
  let ns : NamespaceMeta = {
    format: "seekpond/v1",
    ns_name: "my-ns",
    head_manifest: "manifest-01TEST",
    fts_tokenizer: None,
    vec_global_version: None,
    distance_metric: "cosine",
    vector_dim: 768,
    vector_dtype: "f16",
    k1: 1.2,
    b: 0.75,
  }
  let parsed = namespace_from_json(ns.to_json())
  assert_eq(parsed.head_manifest, "manifest-01TEST")
  assert_eq(parsed.vector_dim, 768)
  assert_eq(parsed.k1, 1.2)
}

///|
test "bad magic raises" {
  try {
    let _ = decode_col(b"garbage!!")
    panic()
  } catch {
    _ => ()
  }
}

///|
/// 构造 12 runs / 300 行的 id 列（run 10 行连续、run 间空洞 5）：空洞合并段形态。
fn mk_hole_ids() -> Array[UInt64] {
  let ids : Array[UInt64] = Array()
  let mut base = 1000UL
  for _ in 0..<12 {
    for j in 0..<10 {
      ids.push(base + j.to_uint64())
    }
    base += 15UL
  }
  ids
}

///|
/// runs_u64：连续 run 少的 id 列写 run 表；IdCol::at 二分定位、to_array /
/// decode_col 兼容展开都与原 id 列逐行一致。
test "format: encode_id_col few runs → runs_u64，二分/展开与逐行一致" {
  let ids = mk_hole_ids()
  let bs = encode_id_col(ids)
  assert_eq(id_encoding_of(bs), ID_ENCODING_RUNS)
  assert_eq(is_id_runs_col(bs), true)
  let runs = decode_id_runs(bs)
  assert_eq(runs.length(), 12)
  assert_eq(runs[0].min_id, 1000UL)
  assert_eq(runs[0].start_row, 0)
  assert_eq(runs[0].len, 10)
  assert_eq(runs[11].start_row, 110)
  assert_eq(runs[11].len, 10)
  assert_eq(runs[11].min_id, 1165UL)
  let col = decode_id_col(bs)
  for r in 0..<ids.length() {
    assert_eq(col.at(r), ids[r])
  }
  // run 边界行（首/末）精确
  assert_eq(col.at(0), 1000UL)
  assert_eq(col.at(9), 1009UL)
  assert_eq(col.at(110), 1165UL)
  assert_eq(col.at(119), 1174UL)
  assert_eq(col.to_array(), ids)
  // 老调用方兼容路径：decode_col 展开为 ColU64
  match decode_col(bs) {
    ColU64(a) => assert_eq(a, ids)
    _ => fail("runs_u64 decode_col 应展开为 ColU64")
  }
  // 越界 raise
  let oob = try {
    let _ = col.at(ids.length())
    false
  } catch {
    _ => true
  }
  assert_eq(oob, true)
}

///|
/// 非连续 id（run 近似行数）的段行为不变：run 表不小于逐行时保持 row_u64。
test "format: 非连续 id encode_id_col 保持逐行 u64" {
  // 交替 id：每行一个 run ⇒ 16B/run 不小于 8B/row ⇒ 逐行
  let ids : Array[UInt64] = Array()
  for i in 0..<100 {
    ids.push((i * 2).to_uint64())
  }
  let bs = encode_id_col(ids)
  assert_eq(id_encoding_of(bs), "row_u64")
  assert_eq(is_id_runs_col(bs), false)
  match decode_id_col(bs) {
    IdPlain(a) => assert_eq(a, ids)
    IdRuns(_) => fail("非连续 id 不应走 runs_u64")
  }
  // 阈值边界：2 行 1 run（16B == 16B）保持逐行；3 行 1 run（16B < 24B）走 runs
  assert_eq(id_encoding_of(encode_id_col([7UL, 8UL])), "row_u64")
  assert_eq(id_encoding_of(encode_id_col([7UL, 8UL, 9UL])), ID_ENCODING_RUNS)
  assert_eq(id_encoding_of(encode_id_col([])), "row_u64")
}

///|
/// runs_u64 run 表完整性校验：覆盖不足/错位一律 Corrupt（不静默错 id）。
test "format: decode_id_runs 坏 run 表 Corrupt" {
  // count=5 但 run 只覆盖 3 行
  let bad = encode_col_id_runs(5, [{ min_id: 1UL, start_row: 0, len: 3 }])
  let r1 = try {
    let _ = decode_id_runs(bad)
    false
  } catch {
    _ => true
  }
  assert_eq(r1, true)
  // run 与行数一致但 min_id/行映射可逆：正常解码
  let ok = encode_col_id_runs(3, [{ min_id: 42UL, start_row: 0, len: 3 }])
  let runs = decode_id_runs(ok)
  assert_eq(runs.length(), 1)
  let col = decode_id_col(ok)
  assert_eq(col.at(2), 44UL)
}
