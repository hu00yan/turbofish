// Roaring bitmap 白盒测试：空 / 稀疏 array container / 稠密 bitmap container /
// 跨高 32 位容器 / 边界值。

///|
fn assert_ids_eq(a : Array[UInt64], b : Array[UInt64]) -> Unit raise {
  assert_eq(a.length(), b.length())
  for i in 0..<a.length() {
    assert_eq(a[i], b[i])
  }
}

///|
test "roaring empty and sparse roundtrip" {
  assert_eq(decode_roaring(encode_roaring([])).length(), 0)
  let ids : Array[UInt64] = [1UL, 2UL, 100UL, 65535UL, 65536UL, 0x1_0000_0000UL]
  assert_ids_eq(decode_roaring(encode_roaring(ids)), ids)
}

///|
test "roaring dense container uses bitmap and roundtrips" {
  // 一个高 32 位容器里放 5000 个 low 值（触发 bitmap container）
  let n = 5000
  let ids : Array[UInt64] = Array::new(capacity=n)
  for i in 0..<n {
    ids.push((i * 3).to_uint64())
  }
  let bs = encode_roaring(ids)
  let back = decode_roaring(bs)
  assert_ids_eq(back, ids)
  // 头之后第一个 container 的 type 应为 1（bitmap）
  assert_eq(bs.get(20), Some(b'\x01'))
}

///|
test "roaring multiple high containers" {
  let ids : Array[UInt64] = [
    1UL, 5UL, 0x1_0000_0000UL, 0x1_0000_0001UL, 0x2_FFFF_FFFFUL,
  ]
  assert_ids_eq(decode_roaring(encode_roaring(ids)), ids)
}

///|
test "roaring_contains membership checks" {
  let empty_bs = encode_roaring([])
  assert_eq(roaring_contains(empty_bs, 1UL), false)
  assert_eq(roaring_contains(empty_bs, 0UL), false)

  let sparse_ids : Array[UInt64] = [1UL, 2UL, 100UL, 65535UL, 65536UL, 0x1_0000_0000UL]
  let sparse_bs = encode_roaring(sparse_ids)
  for id in sparse_ids {
    assert_eq(roaring_contains(sparse_bs, id), true)
  }
  assert_eq(roaring_contains(sparse_bs, 0UL), false)
  assert_eq(roaring_contains(sparse_bs, 3UL), false)
  assert_eq(roaring_contains(sparse_bs, 99UL), false)
  assert_eq(roaring_contains(sparse_bs, 101UL), false)
  assert_eq(roaring_contains(sparse_bs, 65534UL), false)
  assert_eq(roaring_contains(sparse_bs, 0x2_0000_0000UL), false)

  // Dense container (bitmap)
  let n = 5000
  let dense_ids : Array[UInt64] = Array::new(capacity=n)
  for i in 0..<n {
    dense_ids.push((i * 3).to_uint64())
  }
  let dense_bs = encode_roaring(dense_ids)
  assert_eq(roaring_contains(dense_bs, 0UL), true)
  assert_eq(roaring_contains(dense_bs, 3UL), true)
  assert_eq(roaring_contains(dense_bs, 6UL), true)
  assert_eq(roaring_contains(dense_bs, 14997UL), true)
  assert_eq(roaring_contains(dense_bs, 1UL), false)
  assert_eq(roaring_contains(dense_bs, 2UL), false)
  assert_eq(roaring_contains(dense_bs, 4UL), false)
  assert_eq(roaring_contains(dense_bs, 5UL), false)
  assert_eq(roaring_contains(dense_bs, 15000UL), false)
}

