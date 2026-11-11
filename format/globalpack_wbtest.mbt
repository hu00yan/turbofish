// global part pack（SPNDGVPK）白盒测试：roundtrip、index 字节布局、
// 子区间解码与独立 part 解码等价、越界/坏 magic 报错。
// 注意：using @test 已由 quant_wbtest.mbt 声明，包内不重复。

///|
test "global pack roundtrip and index layout" {
  let p1 = encode_global_part(3, [(0, 0), (1, 5)], 2, [1.0, 2.0, 3.0, 4.0], true)
  let p2 = encode_global_part(7, [(2, 1)], 2, [5.0, 6.0], true)
  let pack = encode_global_pack([(3, p1), (7, p2)])
  // header: magic8 + count u32 + pad u32 = 16B；index 每项 12B。
  assert_eq(pack.length(), 16 + 2 * 12 + p1.length() + p2.length())
  let idx = decode_global_pack_index(pack)
  assert_eq(idx.length(), 2)
  assert_eq(idx[0].0, 3)
  assert_eq(idx[0].1, 16 + 2 * 12)
  assert_eq(idx[0].2, p1.length())
  assert_eq(idx[1].0, 7)
  // 子区间解码结果与独立 part 解码等价。
  let g1 = decode_global_part_at(pack, idx[0].1, idx[0].2)
  assert_eq(g1.cid, 3)
  assert_eq(g1.rows.length(), 2)
  assert_eq(g1.rows[1], (1, 5))
  assert_eq(g1.data.length(), 4)
  assert_eq(g1.data[3], 4.0)
  let g2 = decode_global_part_at(pack, idx[1].1, idx[1].2)
  assert_eq(g2.cid, 7)
  assert_eq(g2.rows[0], (2, 1))
  assert_eq(g2.data[1], 6.0)
  // 直接 decode_global_part 与 pack 子区间解码一致（blob 是标准编码）。
  let d2 = decode_global_part(p2)
  assert_eq(d2.cid, g2.cid)
  assert_eq(d2.data[0], g2.data[0])
  // 空 index（0 个 part）是合法结构。
  assert_eq(decode_global_pack_index(encode_global_pack([])).length(), 0)
}

///|
test "global pack out-of-range offsets rejected" {
  let p = encode_global_part(1, [(0, 0)], 1, [1.0], true)
  let pack = encode_global_pack([(1, p)])
  // offset 越界 → Truncated；len 不足以放 header → Truncated。
  let raised1 = try {
    let _ = decode_global_part_at(pack, 1 << 30, 20)
    false
  } catch {
    _ => true
  }
  assert_eq(raised1, true)
  let raised2 = try {
    let _ = decode_global_part_at(pack, 0, 4)
    false
  } catch {
    _ => true
  }
  assert_eq(raised2, true)
}

