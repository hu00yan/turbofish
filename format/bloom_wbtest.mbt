// 段级 FTS Bloom filter 测试。

///|
test "bloom membership and hex roundtrip" {
  let terms : Array[String] = ["alpha", "beta", "gamma", "向量", "检索"]
  let b = build_bloom(terms, 10)
  for t in terms {
    assert_eq(bloom_may_contain(b, t), true)
  }
  assert_eq(bloom_may_contain(b, "definitely-not-in-the-set-xyz"), false)
  let b2 = bloom_from_hex(b.m, b.k, bloom_to_hex(b))
  assert_eq(b2.m, b.m)
  assert_eq(b2.k, b.k)
  for t in terms {
    assert_eq(bloom_may_contain(b2, t), true)
  }
}

///|
test "bloom empty and bad hex" {
  let b = build_bloom([], 10)
  assert_eq(b.m, 64)
  assert_eq(bloom_may_contain(b, "x"), false)
  try {
    let _ = bloom_from_hex(64, 7, "zz")
    panic()
  } catch {
    _ => ()
  }
}
