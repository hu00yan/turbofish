// IVF 向量分区编解码。
//
// SPNDCEN1（_centroids/centroids-{ver}.bin），16B 头：
//   [0..8)   magic "SPNDCEN1"
//   [8..12)  k u32 LE
//   [12..14) dim u16 LE
//   [14]     dtype: 4=f32（中心恒为 f32，保证精排一致性）
//   [15]     保留
// payload：k × dim × 4B f32
//
// SPNDPRT1（_segments/{seg}/vec/part-{cid}.bin），16B 头：
//   [0..8)   magic "SPNDPRT1"
//   [8..12)  cid u32 LE
//   [12..16) count u32 LE
//   [16..18) dim u16 LE
//   [18]     dtype: 4=f32 7=f16
//   [19]     保留
// payload：row_ids u32 × count（segment 内行号），随后 count × dim × item_size 向量。
// 解码一律展开为 f32。

///|
pub const CEN_MAGIC : String = "SPNDCEN1"

///|
pub const PART_MAGIC : String = "SPNDPRT1"

///|
pub(all) struct Centroids {
  dim : Int
  data : Array[Float] // k*dim 行主序
} derive(Debug)

///|
pub fn Centroids::k(self : Centroids) -> Int {
  self.data.length() / self.dim
}

///|
pub fn encode_centroids(c : Centroids) -> Bytes {
  let b = Buffer()
  b.write_string_utf8(CEN_MAGIC)
  b.write_uint_le(c.k().to_uint())
  b.write_uint16_le(c.dim.to_uint16())
  b.write_byte(DT_F32.to_byte())
  b.write_byte(b'\x00')
  for v in c.data {
    b.write_float_le(v)
  }
  b.to_bytes()
}

///|
pub fn decode_centroids(bs : Bytes) -> Centroids raise @core.SpndError {
  @core.check_magic(bs, CEN_MAGIC)
  let k = @core.read_u32_le(bs, 8).to_int()
  let dim = @core.read_u16_le(bs, 12).to_int()
  let data : Array[Float] = Array::new(capacity=k * dim)
  for i in 0..<(k * dim) {
    data.push(@core.read_f32_le(bs, 16 + i * 4))
  }
  { dim, data }
}

///|
pub(all) struct VecPart {
  cid : Int
  rows : Array[Int] // segment 内行号
  dim : Int
  data : Array[Float] // rows.length * dim
} derive(Debug)

///|
pub fn encode_part(p : VecPart, use_f16 : Bool) -> Bytes {
  let b = Buffer()
  b.write_string_utf8(PART_MAGIC)
  b.write_uint_le(p.cid.to_uint())
  b.write_uint_le(p.rows.length().to_uint())
  b.write_uint16_le(p.dim.to_uint16())
  b.write_byte(if use_f16 { DT_F16.to_byte() } else { DT_F32.to_byte() })
  b.write_byte(b'\x00')
  for r in p.rows {
    b.write_uint_le(r.to_uint())
  }
  if use_f16 {
    for v in p.data {
      b.write_uint16_le(@core.f32_to_f16_bits(v))
    }
  } else {
    for v in p.data {
      b.write_float_le(v)
    }
  }
  b.to_bytes()
}

///|
pub fn decode_part(bs : Bytes) -> VecPart raise @core.SpndError {
  @core.check_magic(bs, PART_MAGIC)
  let cid = @core.read_u32_le(bs, 8).to_int()
  let count = @core.read_u32_le(bs, 12).to_int()
  let dim = @core.read_u16_le(bs, 16).to_int()
  let dtype8 = match bs.get(18) {
    Some(x) => x.to_int()
    None => raise @core.Truncated("part header")
  }
  let item = if dtype8 == DT_F16 { 2 } else { 4 }
  let rows : Array[Int] = Array::new(capacity=count)
  for i in 0..<count {
    rows.push(@core.read_u32_le(bs, 20 + i * 4).to_int())
  }
  let vec_base = 20 + count * 4
  let data : Array[Float] = Array::new(capacity=count * dim)
  for i in 0..<(count * dim) {
    let pos = vec_base + i * item
    if dtype8 == DT_F16 {
      data.push(@core.f16_bits_to_f32(@core.read_u16_le(bs, pos)))
    } else {
      data.push(@core.read_f32_le(bs, pos))
    }
  }
  { cid, rows, dim, data }
}
