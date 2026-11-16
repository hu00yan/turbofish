///|

// MemStore 行为测试：CAS、成本记账、缓存模型、范围读。

///|
async test "put_get_list_delete" {
  let s = MemStore::new()
  s.put("ns/_meta/namespace.json", b"hello")
  s.put("ns/_manifest/manifest-01.json", b"world")
  let v = s.get("ns/_meta/namespace.json")
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
async test "put_if_match CAS" {
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
async test "cost accounting cold vs warm" {
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
async test "get_range counts partial bytes" {
  let s = MemStore::new()
  s.put("ns/_segments/seg-01/fts/postings.bin", Bytes::make(500, b'\x07'))
  s.cold()
  s.reset_cost()
  let part = s.get_range("ns/_segments/seg-01/fts/postings.bin", 100, 50)
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
  let _ = s.get_range("ns/_segments/seg-01/fts/postings.bin", 100, 50)
  let c2 = s.cost()
  assert_eq(c2.ranged_gets, 2)
  assert_eq(c2.ranged_bytes, 50)
}

///|
async test "classify" {
  assert_eq(classify_key("ns/_meta/namespace.json"), "meta")
  assert_eq(classify_key("ns/_manifest/manifest-01.json"), "manifest")
  assert_eq(classify_key("ns/_centroids/centroids-01.bin"), "centroids")
  assert_eq(classify_key("ns/_segments/seg-01/rows/id.bin"), "rows")
  assert_eq(classify_key("ns/_segments/seg-01/fts/dir.bin"), "fts")
  assert_eq(classify_key("ns/_segments/seg-01/vec/part-3.bin"), "vec")
}

///|
async test "head log append-only max and gc" {
  let s = MemStore::new()
  assert_eq(read_head(s, "ns", ""), "")
  write_head(s, "ns", "manifest-a")
  write_head(s, "ns", "manifest-c")
  write_head(s, "ns", "manifest-b")
  assert_eq(read_head(s, "ns", ""), "manifest-c")
  assert_eq(read_head(s, "empty", "legacy"), "legacy")
  gc_heads(s, "ns", "manifest-c")
  let keys = s.list("ns/_heads/")
  assert_eq(keys.length(), 1)
  assert_eq(keys[0], "ns/_heads/manifest-c")
}

///|
async test "get_many 与逐个 get 逐位一致（含缺失 key，顺序不变）" {
  let s1 = MemStore::new()
  let s2 = MemStore::new()
  let keys = ["ns/a.bin", "ns/missing.bin", "ns/b.bin"]
  s1.put(keys[0], b"alpha")
  s2.put(keys[0], b"alpha")
  s1.put(keys[2], b"beta")
  s2.put(keys[2], b"beta")
  // 冷启动，确保计费 / 缓存语义也逐位可比
  s1.cold()
  s2.cold()
  s1.reset_cost()
  s2.reset_cost()
  let batch = s1.get_many(keys)
  // 返回长度与输入一致
  assert_eq(batch.length(), keys.length())
  // 与逐个 get 逐位一致
  for i in 0..<keys.length() {
    assert_eq(batch[i], s2.get(keys[i]))
  }
  // None 保持在缺失下标；顺序不因缺失改变
  assert_eq(batch[0], Some(b"alpha"))
  assert_eq(batch[1], None)
  assert_eq(batch[2], Some(b"beta"))
  // 计费语义不变：批取等价于 n 次单键 get
  let c1 = s1.cost()
  let c2 = s2.cost()
  assert_eq(c1.gets, 3)
  assert_eq(c1.gets, c2.gets)
  assert_eq(c1.get_bytes, c2.get_bytes)
  // 空输入 → 空数组
  assert_eq(s1.get_many([]).length(), 0)
}

///|
async test "get_range_many 与逐个 get_range 逐位一致（含缺失 key）" {
  let s1 = MemStore::new()
  let s2 = MemStore::new()
  let data = Bytes::makei(50, i => i.to_byte())
  s1.put("ns/seg.bin", data)
  s2.put("ns/seg.bin", data)
  s1.cold()
  s2.cold()
  s1.reset_cost()
  s2.reset_cost()
  let ranges = [
    ("ns/seg.bin", 5, 10),
    ("ns/missing.bin", 0, 4),
    ("ns/seg.bin", 45, 100),
  ]
  let batch = s1.get_range_many(ranges)
  assert_eq(batch.length(), ranges.length())
  for i in 0..<ranges.length() {
    let (k, off, len) = ranges[i]
    assert_eq(batch[i], s2.get_range(k, off, len))
  }
  // None 保持在缺失下标；截短 / 缺失语义与单键一致
  assert_eq(batch[0], Some(data[5:15].to_owned()))
  assert_eq(batch[1], None)
  assert_eq(batch[2], Some(data[45:50].to_owned()))
  // 计费语义不变：批取等价于 n 次单键 get_range
  let c1 = s1.cost()
  let c2 = s2.cost()
  assert_eq(c1.ranged_gets, 3)
  assert_eq(c1.ranged_gets, c2.ranged_gets)
  assert_eq(c1.ranged_bytes, c2.ranged_bytes)
  // 空输入 → 空数组
  assert_eq(s1.get_range_many([]).length(), 0)
}
