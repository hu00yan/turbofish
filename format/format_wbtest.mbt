// format 包 roundtrip 测试。

///|
test "col u64/u32/i64/f32/bool roundtrip" {
  let u : UInt64 = 18446744073709551615UL
  let a = [1UL, 2UL, u]
  match  decode_col(encode_col(ColU64(a))) {
    ColU64(arr) => assert_eq(arr, a)
    _ => fail("wrong type")
  }
  let b32 = [0, 7, 2147483647]
  match  decode_col(encode_col(ColU32(b32))) {
    ColU32(arr) => assert_eq(arr, b32)
    _ => fail("wrong type")
  }
  let neg = -9223372036854775807L - 1L
  let i64s = [1L, -2L, neg]
  match  decode_col(encode_col(ColI64(i64s))) {
    ColI64(arr) => assert_eq(arr, i64s)
    _ => fail("wrong type")
  }
  let fs : Array[Float] = [1.5, -2.25, 3.14159]
  match  decode_col(encode_col(ColF32(fs))) {
    ColF32(arr) => {
      for i in 0..<fs.length() {
        assert_eq(arr[i], fs[i])
      }
    }
    _ => fail("wrong type")
  }
  let bs = [true, false, true]
  match  decode_col(encode_col(ColBool(bs))) {
    ColBool(arr) => assert_eq(arr, bs)
    _ => fail("wrong type")
  }
}

///|
test "col string roundtrip with utf8" {
  let strs = ["alpha", "beta", "中文测试", "mixed中en文", "", "🉑emoji"]
  match  decode_col(encode_col(ColStr(strs))) {
    ColStr(arr) => assert_eq(arr, strs)
    _ => fail("wrong type")
  }
}

///|
test "vec col f32 and f16 roundtrip" {
  let dim = 4
  let data : Array[Float] = [0.5, -1.25, 100.0, 0.001, 2.5, 3.5, 4.5, 5.5]
  let (d1, out1) =  decode_vec_col(encode_vec_col(dim, data, false))
  assert_eq(d1, dim)
  for i in 0..<data.length() {
    assert_eq(out1[i], data[i])
  }
  let (_, out2) =  decode_vec_col(encode_vec_col(dim, data, true))
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
  let entries =  decode_fts_dir(built.dir)
  assert_eq(entries.length(), 3)
  // 目录按 String::compare 有序（内部自洽即可，不假设 UTF-8 字节序）
  for i in 1..<entries.length() {
    assert_eq(entries[i - 1].term.compare(entries[i].term) <= 0, true)
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
      let p =  read_postings(built.postings, e)
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
      let p =  read_postings(built.postings, e)
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
  let c2 =  decode_centroids(encode_centroids(c))
  assert_eq(c2.k(), 2)
  assert_eq(c2.data[4], 5.0)
  let p : VecPart = { cid: 7, rows: [3, 9, 11], dim: 2, data: [1.0, 2.0, 3.0, 4.0, 5.0, 6.0] }
  let p2 =  decode_part(encode_part(p, false))
  assert_eq(p2.cid, 7)
  assert_eq(p2.rows, [3, 9, 11])
  assert_eq(p2.data[5], 6.0)
  let p3 =  decode_part(encode_part(p, true))
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
    centroid_version: "centroids-01C",
    num_docs: 100,
    avg_doc_len: 18.0,
  }
  let parsed =  manifest_from_json(m.to_json())
  assert_eq(parsed.id, m.id)
  assert_eq(parsed.parent, m.parent)
  assert_eq(parsed.segments.length(), 1)
  assert_eq(parsed.segments[0].id, "seg-01A")
  assert_eq(parsed.segments[0].min_id, 1UL)
  assert_eq(parsed.deleted, m.deleted)
  assert_eq(parsed.centroid_version, m.centroid_version)
}

///|
test "namespace json roundtrip" {
  let ns : NamespaceMeta = {
    format: "seekpond/v1",
    namespace: "my-ns",
    head_manifest: "manifest-01TEST",
    distance_metric: "cosine",
    vector_dim: 768,
    vector_dtype: "f16",
    k1: 1.2,
    b: 0.75,
  }
  let parsed =  namespace_from_json(ns.to_json())
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
