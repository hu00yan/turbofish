///|

// format 包新编码（字典列/位图 bool/SQ8/PQ16/blockmax）白盒测试。
// 覆盖：roundtrip、字节级布局断言、旧格式（flags=0）向后兼容、阈值回退、
// f16 路径互不干扰。

///|
fn assert_bytes_eq(a : Bytes, b : Bytes) -> Unit raise {
  assert_eq(a.length(), b.length())
  for i in 0..<a.length() {
    match (a.get(i), b.get(i)) {
      (Some(x), Some(y)) => assert_eq(x.to_int(), y.to_int())
      _ => fail("byte missing")
    }
  }
}

///|
test "dict string col roundtrip with cjk/empty/dup" {
  let strs = ["中文", "a", "中文", "", "中文", "中文"]
  match decode_col(encode_col(ColStr(strs))) {
    ColStr(arr) => assert_eq(arr, strs)
    _ => fail("wrong type")
  }
  // decode_col_dict 精确回读 dict + codes
  let (dict, codes) = decode_col_dict(encode_col(ColStr(strs)))
  assert_eq(dict, ["中文", "a", ""])
  assert_eq(codes, [0U, 1U, 0U, 2U, 0U, 0U].map(fn(x) { x.to_uint16() }))
  // 空列
  match decode_col(encode_col(ColStr([]))) {
    ColStr(arr) => assert_eq(arr.length(), 0)
    _ => fail("wrong type")
  }
  let (_, codes0) = decode_col_dict(encode_col(ColStr([])))
  assert_eq(codes0.length(), 0)
  assert_eq(dict.length(), 3) // 上一次调用的 dict 不受影响
}

///|
test "dict string col byte layout" {
  // ["b","a","b",""] → dict=["b","a",""]（首次出现序），codes=[0,1,0,2]
  let strs = ["b", "a", "b", ""]
  let bs = encode_col(ColStr(strs))
  // 20B 头：magic8 + dtype1(=5) + flags1(=1) + count4(=4) + extra4(=2) + pad2
  assert_eq(bs.length(), 50)
  match bs.get(8) {
    Some(x) => assert_eq(x.to_int(), DT_STR)
    None => fail("no dtype")
  }
  match bs.get(9) {
    Some(x) => assert_eq(x.to_int(), COL_FLAG_DICT)
    None => fail("no flags")
  }
  assert_eq(@core.read_u32_le(bs, 10).reinterpret_as_int(), 4)
  assert_eq(@core.read_u32_le(bs, 14).reinterpret_as_int(), 2) // extra = dict_data 字节数
  // payload：dict_count(=3) @20，dict_offsets @24（4×4），dict_data @40，codes @42
  assert_eq(@core.read_u32_le(bs, 20).reinterpret_as_int(), 3)
  assert_eq(@core.read_u32_le(bs, 24).reinterpret_as_int(), 0)
  assert_eq(@core.read_u32_le(bs, 28).reinterpret_as_int(), 1)
  assert_eq(@core.read_u32_le(bs, 32).reinterpret_as_int(), 2)
  assert_eq(@core.read_u32_le(bs, 36).reinterpret_as_int(), 2)
  match bs.get(40) {
    Some(x) => assert_eq(x.to_int(), 98) // 'b'
    None => fail("no dict data")
  }
  match bs.get(41) {
    Some(x) => assert_eq(x.to_int(), 97) // 'a'
    None => fail("no dict data")
  }
  assert_eq(@core.read_u16_le(bs, 42).to_int(), 0)
  assert_eq(@core.read_u16_le(bs, 44).to_int(), 1)
  assert_eq(@core.read_u16_le(bs, 46).to_int(), 0)
  assert_eq(@core.read_u16_le(bs, 48).to_int(), 2)
  match decode_col(bs) {
    ColStr(arr) => assert_eq(arr, strs)
    _ => fail("wrong type")
  }
}

///|
test "dict col falls back to plain when distinct > 65535" {
  // 65536 个唯一词：u16 code 放不下 → flags=0 普通串列
  let arr : Array[String] = Array(capacity=65536)
  for i in 0..<65536 {
    arr.push("w\{i}")
  }
  let bs = encode_col(ColStr(arr))
  match bs.get(9) {
    Some(x) => assert_eq(x.to_int(), 0) // flags=0，未走字典
    None => fail("no flags")
  }
  match decode_col(bs) {
    ColStr(out) => {
      assert_eq(out.length(), 65536)
      assert_eq(out[0], "w0")
      assert_eq(out[12345], "w12345")
      assert_eq(out[65535], "w65535")
    }
    _ => fail("wrong type")
  }
  // 边界内 65535 个唯一词：仍走字典（flags bit0=1）
  let arr2 : Array[String] = Array(capacity=65535)
  for i in 0..<65535 {
    arr2.push("u\{i}")
  }
  let bs2 = encode_col(ColStr(arr2))
  match bs2.get(9) {
    Some(x) => assert_eq(x.to_int(), COL_FLAG_DICT)
    None => fail("no flags")
  }
  match decode_col(bs2) {
    ColStr(out) => {
      assert_eq(out.length(), 65535)
      assert_eq(out[65534], "u65534")
    }
    _ => fail("wrong type")
  }
}

///|
test "bool bitmap col roundtrip and byte layout" {
  // 1 位边界
  match decode_col(encode_col(ColBool([true]))) {
    ColBool(arr) => assert_eq(arr, [true])
    _ => fail("wrong type")
  }
  match decode_col(encode_col(ColBool([false]))) {
    ColBool(arr) => assert_eq(arr, [false])
    _ => fail("wrong type")
  }
  // 8 位边界：单字节，位序小端（行 i = bit i）
  let v8 : Array[Bool] = [true, false, false, true, false, false, true, false]
  let bs8 = encode_col(ColBool(v8))
  assert_eq(bs8.length(), 21) // 20B 头 + 1B 位图
  match bs8.get(9) {
    Some(x) => assert_eq(x.to_int(), COL_FLAG_BITMAP)
    None => fail("no flags")
  }
  match bs8.get(20) {
    Some(x) => assert_eq(x.to_int(), 1 | 8 | 64) // bits 0,3,6
    None => fail("no bitmap")
  }
  match decode_col(bs8) {
    ColBool(arr) => assert_eq(arr, v8)
    _ => fail("wrong type")
  }
  // 9 位边界：跨两个字节，行 8 → 字节 1 的 bit 0
  let v9 : Array[Bool] = [
    true, false, false, false, false, false, false, false, true,
  ]
  let bs9 = encode_col(ColBool(v9))
  assert_eq(bs9.length(), 22) // 20B 头 + 2B 位图
  match bs9.get(20) {
    Some(x) => assert_eq(x.to_int(), 1)
    None => fail("no bitmap")
  }
  match bs9.get(21) {
    Some(x) => assert_eq(x.to_int(), 1)
    None => fail("no bitmap")
  }
  match decode_col(bs9) {
    ColBool(arr) => assert_eq(arr, v9)
    _ => fail("wrong type")
  }
  // 17 位（3 字节，尾字节部分使用）
  let v17 : Array[Bool] = Array(capacity=17)
  for i in 0..<17 {
    v17.push(i % 3 == 0)
  }
  match decode_col(encode_col(ColBool(v17))) {
    ColBool(arr) => assert_eq(arr, v17)
    _ => fail("wrong type")
  }
}

///|
test "decode_col backward compat with flags=0 old format" {
  // 旧格式字符串列：flags=0，(count+1)×u32 offsets + UTF-8 data
  let strs = ["x", "yy", "中文"]
  let b = Buffer()
  let datas = Buffer()
  let offs = Buffer()
  let mut total = 0
  for s in strs {
    offs.write_uint_le(total.reinterpret_as_uint())
    let e = @utf8.encode(s)
    datas.write_bytes(e.exact_view())
    total += e.length()
  }
  offs.write_uint_le(total.reinterpret_as_uint())
  write_col_header(b, DT_STR, 0, strs.length(), total)
  b.write_bytes(offs.to_bytes().exact_view())
  b.write_bytes(datas.to_bytes().exact_view())
  match decode_col(b.to_bytes()) {
    ColStr(arr) => assert_eq(arr, strs)
    _ => fail("wrong type")
  }
  // 旧字符串列不能当字典列解码
  try {
    let _ = decode_col_dict(b.to_bytes())
    panic()
  } catch {
    _ => ()
  }
  // 旧格式 bool 列：flags=0，每值 1B
  let bools = [true, false, true, true]
  let b2 = Buffer()
  write_col_header(b2, DT_BOOL, 0, bools.length(), 0)
  for v in bools {
    b2.write_byte(if v { b'\x01' } else { b'\x00' })
  }
  match decode_col(b2.to_bytes()) {
    ColBool(arr) => assert_eq(arr, bools)
    _ => fail("wrong type")
  }
}

///|
test "sq8 vec col auto roundtrip and quantization error" {
  let dim = 2
  let data : Array[Float] = [0.0, 10.0, 5.0, -5.0, 10.0, 10.0]
  let bs = encode_vec_col_sq8_auto(dim, data)
  // 16B 头 + mins 8B + scales 8B + codes 6B
  assert_eq(bs.length(), 38)
  match bs.get(8) {
    Some(x) => assert_eq(x.to_int(), DT_SQ8)
    None => fail("no dtype")
  }
  // per_dim_min @16：[0.0, -5.0]；per_dim_inv_scale @24：[25.5, 17.0]
  assert_eq(@core.read_f32_le(bs, 16), 0.0)
  assert_eq(@core.read_f32_le(bs, 20), -5.0)
  assert_eq(@core.read_f32_le(bs, 24), 25.5)
  assert_eq(@core.read_f32_le(bs, 28), 17.0)
  // codes @32（手算：round((v-min)×inv_scale) clamp [0,255]）
  let expect : Array[Int] = [0, 255, 128, 0, 255, 255]
  for i in 0..<6 {
    match bs.get(32 + i) {
      Some(x) => assert_eq(x.to_int(), expect[i])
      None => fail("no code")
    }
  }
  // 展开回 f32：误差 < (max-min)/255 + 1e-3
  let (d, out) = decode_vec_col(bs)
  assert_eq(d, dim)
  let bounds : Array[Float] = [10.0 / 255.0 + 0.001, 15.0 / 255.0 + 0.001]
  for i in 0..<6 {
    let err = (out[i].to_double() - data[i].to_double()).abs()
    assert_eq(err < bounds[i % dim].to_double(), true)
  }
  // 显式参数版与 auto 版字节一致
  let bs2 = encode_vec_col_sq8(dim, data, [0.0, -5.0], [25.5, 17.0])
  assert_bytes_eq(bs2, bs)
}

///|
test "sq8 constant column has zero inv_scale and decodes exact" {
  let dim = 2
  let data : Array[Float] = [3.25, 7.5, 3.25, 7.5]
  let bs = encode_vec_col_sq8_auto(dim, data)
  assert_eq(@core.read_f32_le(bs, 24), 0.0)
  assert_eq(@core.read_f32_le(bs, 28), 0.0)
  for i in 0..<4 {
    match bs.get(32 + i) {
      Some(x) => assert_eq(x.to_int(), 0)
      None => fail("no code")
    }
  }
  let (_, out) = decode_vec_col(bs)
  for i in 0..<4 {
    assert_eq(out[i], data[i])
  }
}

///|
test "sq8 part raw and expanded roundtrip" {
  let p : VecPart = {
    cid: 5,
    rows: [2, 9, 4],
    dim: 2,
    data: [0.0, 10.0, 5.0, -5.0, 10.0, 10.0],
  }
  let bs = encode_part_sq8_auto(p)
  // 20B 头 + rows 12B + mins 8B + scales 8B + codes 6B
  assert_eq(bs.length(), 54)
  let (mins, scales, codes) = decode_part_sq8_raw(bs)
  assert_eq(mins, [0.0, -5.0])
  assert_eq(scales, [25.5, 17.0])
  let expect : Array[UInt] = [0U, 255U, 128U, 0U, 255U, 255U]
  assert_eq(codes, expect)
  // decode_part 展开回 f32
  let p2 = decode_part(bs)
  assert_eq(p2.cid, 5)
  assert_eq(p2.rows, [2, 9, 4])
  assert_eq(p2.dim, 2)
  let bounds : Array[Float] = [10.0 / 255.0 + 0.001, 15.0 / 255.0 + 0.001]
  for i in 0..<6 {
    let err = (p2.data[i].to_double() - p.data[i].to_double()).abs()
    assert_eq(err < bounds[i % 2].to_double(), true)
  }
  // 显式参数版与 auto 版字节一致
  assert_bytes_eq(encode_part_sq8(p, [0.0, -5.0], [25.5, 17.0]), bs)
  // 非 sq8 part 拒绝 raw 解码
  try {
    let _ = decode_part_sq8_raw(encode_part(p, false))
    panic()
  } catch {
    _ => ()
  }
}

///|
test "pq16 part exact roundtrip and byte layout" {
  let m = 2
  let dsub = 2
  let dim = m * dsub
  let rows = [7, 42, 9]
  let codebooks : Array[Float] = Array(capacity=m * 256 * dsub)
  for c in 0..<m {
    for j in 0..<256 {
      for l in 0..<dsub {
        codebooks.push(Float::from_int((c * 256 + j) * 2 + l) * 0.25 - 100.0)
      }
    }
  }
  let codes : Array[UInt] = [0U, 255U, 128U, 1U, 254U, 3U]
  let bs = encode_pq_part(rows, dim, m, codebooks, codes)
  // 20B 头 + rows 12B + codebooks 4096B + codes 6B
  assert_eq(bs.length(), 4134)
  assert_eq(@core.read_u16_le(bs, 8).to_int(), m)
  assert_eq(@core.read_u16_le(bs, 10).to_int(), dsub)
  assert_eq(@core.read_u32_le(bs, 12).reinterpret_as_int(), 3)
  assert_eq(@core.read_u16_le(bs, 16).to_int(), dim)
  assert_eq(@core.read_u16_le(bs, 18).to_int(), 0) // pad
  let pq = decode_pq_part(bs)
  assert_eq(pq.rows, rows)
  assert_eq(pq.dim, dim)
  assert_eq(pq.m, m)
  assert_eq(pq.dsub, dsub)
  assert_eq(pq.codes, codes)
  assert_eq(pq.codebooks.length(), m * 256 * dsub)
  for i in 0..<codebooks.length() {
    assert_eq(pq.codebooks[i], codebooks[i])
  }
  // 精确字节抽查：codebook[1][255][1] = (256+255)*2+1 = 1023 → 1023*0.25-100
  assert_eq(@core.read_f32_le(bs, 20 + 12 + 1023 * 4), 155.75)
  // m×dsub != dim → 解码 Corrupt
  let bad = encode_pq_part(rows, 5, m, codebooks, codes)
  try {
    let _ = decode_pq_part(bad)
    panic()
  } catch {
    _ => ()
  }
  // 坏 magic
  try {
    let _ = decode_pq_part(b"garbage!!")
    panic()
  } catch {
    _ => ()
  }
}

///|
test "blockmax roundtrip, empty and multi-block" {
  // 空 term 表
  let empty = encode_blockmax([], 128)
  assert_eq(empty.length(), 20)
  assert_eq(decode_blockmax(empty).length(), 0)
  // 多块 + 空 term + 单块
  let t0 : Array[(Int, Int)] = [(3, 100), (2, 80), (5, 120)]
  let t1 : Array[(Int, Int)] = []
  let t2 : Array[(Int, Int)] = [(1, 10)]
  let bs = encode_blockmax([t0, t1, t2], 128)
  // 20B 头 + term0(4+24) + term1(4) + term2(4+8) = 64
  assert_eq(bs.length(), 64)
  assert_eq(@core.read_u32_le(bs, 8).reinterpret_as_int(), 3)
  assert_eq(@core.read_u32_le(bs, 12).reinterpret_as_int(), 128)
  assert_eq(@core.read_u32_le(bs, 16).reinterpret_as_int(), 0)
  // term0 block_count @20 = 3，第一块 (3,100) @24
  assert_eq(@core.read_u32_le(bs, 20).reinterpret_as_int(), 3)
  assert_eq(@core.read_u32_le(bs, 24).reinterpret_as_int(), 3)
  assert_eq(@core.read_u32_le(bs, 28).reinterpret_as_int(), 100)
  assert_eq(@core.read_u32_le(bs, 32).reinterpret_as_int(), 2)
  assert_eq(@core.read_u32_le(bs, 36).reinterpret_as_int(), 80)
  assert_eq(@core.read_u32_le(bs, 40).reinterpret_as_int(), 5)
  assert_eq(@core.read_u32_le(bs, 44).reinterpret_as_int(), 120)
  let out = decode_blockmax(bs)
  assert_eq(out.length(), 3)
  assert_eq(out[0].length(), 3)
  assert_eq(out[0][0].0, 3)
  assert_eq(out[0][0].1, 100)
  assert_eq(out[0][1].0, 2)
  assert_eq(out[0][1].1, 80)
  assert_eq(out[0][2].0, 5)
  assert_eq(out[0][2].1, 120)
  assert_eq(out[1].length(), 0)
  assert_eq(out[2].length(), 1)
  assert_eq(out[2][0].0, 1)
  assert_eq(out[2][0].1, 10)
  // 坏 magic
  try {
    let _ = decode_blockmax(b"garbage!!")
    panic()
  } catch {
    _ => ()
  }
}

///|
test "sq8/pq do not disturb existing f16 paths" {
  let dim = 2
  let data : Array[Float] = [1.0, 2.0, 3.0, 4.0]
  // SPNDVEC1 f16 dtype 仍是 7
  let vf = encode_vec_col(dim, data, true)
  match vf.get(8) {
    Some(x) => assert_eq(x.to_int(), DT_F16)
    None => fail("no dtype")
  }
  let (_, out) = decode_vec_col(vf)
  for i in 0..<4 {
    let err = (out[i].to_double() - data[i].to_double()).abs()
    assert_eq(err < 0.002, true)
  }
  // SPNDPRT1 f16 dtype 仍是 7
  let p : VecPart = { cid: 0, rows: [0, 1], dim, data }
  let pf = encode_part(p, true)
  match pf.get(18) {
    Some(x) => assert_eq(x.to_int(), DT_F16)
    None => fail("no dtype")
  }
  let p2 = decode_part(pf)
  assert_eq(p2.rows, [0, 1])
  // f32 路径 dtype 仍是 4
  let v32 = encode_vec_col(dim, data, false)
  match v32.get(8) {
    Some(x) => assert_eq(x.to_int(), DT_F32)
    None => fail("no dtype")
  }
}
