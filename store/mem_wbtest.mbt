// MemStore 行为测试：CAS、成本记账、缓存模型、范围读。

///|
test "put_get_list_delete" {
  let s = MemStore::new()
  s.put("ns/_meta/namespace.json", b"hello")
  s.put("ns/_manifest/manifest-01.json", b"world")
  let v =  s.get("ns/_meta/namespace.json")
  match v {
    Some(bytes) => assert_eq(bytes, b"hello")
    _ => fail("expected Some")
  }
  let keys = s.list("ns/_manifest/")
  assert_eq(keys.length(), 1)
  assert_eq(keys[0], "ns/_manifest/manifest-01.json")
  s.delete("ns/_meta/namespace.json")
  assert_eq(s.get("ns/_meta/namespace.json"), None)
}

///|
test "put_if_match CAS" {
  let s = MemStore::new()
  // 期望不存在时才能写入
  assert_eq(s.put_if_match("head", None, b"v1"), true)
  // 已存在，期望 None → 冲突
  assert_eq(s.put_if_match("head", None, b"v2"), false)
  // 错误版本 → 冲突
  assert_eq(s.put_if_match("head", Some("v9"), b"v3"), false)
  assert_eq(s.get("head"), Some(b"v1"))
  // 正确版本 → 成功
  let cur = s.head_version("head")
  match cur {
    Some(v) => assert_eq(s.put_if_match("head", Some(v), b"v4"), true)
    None => fail("expected version")
  }
  assert_eq(s.get("head"), Some(b"v4"))
  assert_eq(s.cost().cas_ok, 2)
  assert_eq(s.cost().cas_fail, 2)
}

///|
test "cost accounting cold vs warm" {
  let s = MemStore::new()
  s.put("ns/_segments/seg-01/rows/id.bin", Bytes::make(1000, b'\x00'))
  // 写入预热了缓存；冷查询前先清缓存
  s.cold()
  s.reset_cost()
  let _ = s.get("ns/_segments/seg-01/rows/id.bin")
  let c1 = s.cost()
  assert_eq(c1.gets, 1)
  assert_eq(c1.get_bytes, 1000)
  assert_eq(c1.classes[0].0, "rows")
  // 第二次读命中缓存，字节成本为 0
  let _ = s.get("ns/_segments/seg-01/rows/id.bin")
  let c2 = s.cost()
  assert_eq(c2.gets, 2)
  assert_eq(c2.get_bytes, 1000)
  // 冷启动清缓存
  s.cold()
  s.reset_cost()
  let _ = s.get("ns/_segments/seg-01/rows/id.bin")
  let c3 = s.cost()
  assert_eq(c3.get_bytes, 1000)
}

///|
test "get_range counts partial bytes" {
  let s = MemStore::new()
  s.put("ns/_segments/seg-01/fts/postings.bin", Bytes::make(500, b'\x07'))
  s.cold()
  s.reset_cost()
  let part =  s.get_range("ns/_segments/seg-01/fts/postings.bin", 100, 50)
  match part {
    Some(bytes) => {
      assert_eq(bytes.length(), 50)
      assert_eq(bytes[0], b'\x07')
    }
    _ => fail("expected Some")
  }
  let c = s.cost()
  assert_eq(c.ranged_gets, 1)
  assert_eq(c.ranged_bytes, 50)
  // 同一区间再读 → 已预热，0 字节
  let _ =  s.get_range("ns/_segments/seg-01/fts/postings.bin", 100, 50)
  let c2 = s.cost()
  assert_eq(c2.ranged_gets, 2)
  assert_eq(c2.ranged_bytes, 50)
}

///|
test "classify" {
  assert_eq(classify_key("ns/_meta/namespace.json"), "meta")
  assert_eq(classify_key("ns/_manifest/manifest-01.json"), "manifest")
  assert_eq(classify_key("ns/_centroids/centroids-01.bin"), "centroids")
  assert_eq(classify_key("ns/_segments/seg-01/rows/id.bin"), "rows")
  assert_eq(classify_key("ns/_segments/seg-01/fts/dir.bin"), "fts")
  assert_eq(classify_key("ns/_segments/seg-01/vec/part-3.bin"), "vec")
}
