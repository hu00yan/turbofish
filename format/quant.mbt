// 量化编码：SQ8 向量（SPNDVEC1/SPNDPRT1 dtype=8）与 PQ16 分区（SPNDPQP1）。
//
// SQ8 payload（SPNDVEC1 dtype=8 时在 16B 头后；SPNDPRT1 dtype=8 时在
// 16B 头 + rows u32×count 之后）：
//   per_dim_min f32 × dim
//   per_dim_inv_scale f32 × dim      // inv_scale = 255/(max-min)；max==min 时 0
//   codes u8 × (count × dim)         // 行主序，第 i 行第 d 维 = codes[i*dim+d]
// 解码：v = min + code × (1/inv_scale)；inv_scale == 0 时 v = min（全存 code 0）。
// 编码：code = clamp(round((v-min)×inv_scale), 0, 255)。
//
// SPNDPQP1（PQ16 分区，新 magic），20B 头：
//   [0..8)    magic "SPNDPQP1"
//   [8..10)   m u16 LE（子量化器个数）
//   [10..12)  dsub u16 LE（每子空间维度，m × dsub == dim 校验在解码端）
//   [12..16)  count u32 LE（行数）
//   [16..18)  dim u16 LE
//   [18..20)  pad u16 LE（0）
// payload（rows 与 SPNDPRT1 的 rows-first 约定一致）：
//   rows u32 × count（segment 内行号）
//   codebooks f32 × (m × 256 × dsub)，行主序：第 c 个 codebook 的第 j 个中心
//     的第 l 维 = codebooks[(c*256 + j)*dsub + l]
//   codes u8 × (count × m)：第 i 行第 c 个子空间中心号 = codes[i*m + c]

///|
pub const PQ_MAGIC : String = "SPNDPQP1"

///|
/// PQ16 分区。codebooks 长 m×256×dsub（行主序），codes 长 count×m（u8 中心号）。
#derive(Debug)
pub(all) struct PQPart {
  rows : Array[Int] // segment 内行号
  dim : Int
  m : Int
  dsub : Int
  codebooks : Array[Float]
  codes : Array[UInt]
}

///|
/// SQ8 code = clamp(round((v-min)×inv_scale), 0, 255)；inv_scale==0 时恒 0。
fn sq8_encode_code(v : Float, min : Float, inv_scale : Float) -> Int {
  if inv_scale == 0.0 {
    return 0
  }
  let mut q = ((v - min) * inv_scale + 0.5).to_int()
  if q < 0 {
    q = 0
  } else if q > 255 {
    q = 255
  }
  q
}

///|
/// 从数据自算每维 min 与 inv_scale = 255/(max-min)（max==min → 0）。
/// count = data.length / dim。公开给 build 侧，保证向量列与分区用同一套量化参数。
pub fn sq8_params_of(
  dim : Int,
  data : Array[Float],
) -> (Array[Float], Array[Float]) {
  sq8_params(dim, data)
}

///|
/// 从数据自算每维 min 与 inv_scale = 255/(max-min)（max==min → 0）。
/// count = data.length / dim。
fn sq8_params(dim : Int, data : Array[Float]) -> (Array[Float], Array[Float]) {
  let count = if dim > 0 { data.length() / dim } else { 0 }
  let mins : Array[Float] = Array(capacity=dim)
  let scales : Array[Float] = Array(capacity=dim)
  for d in 0..<dim {
    let mut lo = if count > 0 { data[d] } else { 0.0 }
    let mut hi = lo
    for i in 1..<count {
      let v = data[i * dim + d]
      if v < lo {
        lo = v
      }
      if v > hi {
        hi = v
      }
    }
    mins.push(lo)
    let range = hi - lo
    scales.push(if range > 0.0 { 255.0 / range } else { 0.0 })
  }
  (mins, scales)
}

///|
/// SQ8 payload 写入（mins/inv_scales 各 dim 个；data 行主序 count×dim）。
fn write_sq8_payload(
  b : Buffer,
  dim : Int,
  count : Int,
  mins : Array[Float],
  inv_scales : Array[Float],
  data : Array[Float],
) -> Unit {
  for d in 0..<dim {
    b.write_float_le(mins[d])
  }
  for d in 0..<dim {
    b.write_float_le(inv_scales[d])
  }
  for i in 0..<(count * dim) {
    let d = i % dim
    b.write_byte(sq8_encode_code(data[i], mins[d], inv_scales[d]).to_byte())
  }
}

///|
/// SQ8 向量列（SPNDVEC1 dtype=8）：mins/inv_scales 由调用方提供（每维一个）。
pub fn encode_vec_col_sq8(
  dim : Int,
  data : Array[Float],
  mins : Array[Float],
  inv_scales : Array[Float],
) -> Bytes {
  let b = Buffer()
  let count = if dim > 0 { data.length() / dim } else { 0 }
  b.write_string_utf8(VEC_MAGIC)
  b.write_byte(DT_SQ8.to_byte())
  b.write_uint16_le(dim.to_uint16())
  b.write_uint_le(count.reinterpret_as_uint())
  b.write_byte(b'\x00')
  write_sq8_payload(b, dim, count, mins, inv_scales, data)
  b.to_bytes()
}

///|
/// SQ8 向量列：per_dim min/max 从数据自算。
pub fn encode_vec_col_sq8_auto(dim : Int, data : Array[Float]) -> Bytes {
  let (mins, scales) = sq8_params(dim, data)
  encode_vec_col_sq8(dim, data, mins, scales)
}

///|
/// SQ8 分区（SPNDPRT1 dtype=8）：mins/inv_scales 由调用方提供（每维一个）。
pub fn encode_part_sq8(
  p : VecPart,
  mins : Array[Float],
  inv_scales : Array[Float],
) -> Bytes {
  let b = Buffer()
  b.write_string_utf8(PART_MAGIC)
  b.write_uint_le(p.cid.reinterpret_as_uint())
  b.write_uint_le(p.rows.length().reinterpret_as_uint())
  b.write_uint16_le(p.dim.to_uint16())
  b.write_byte(DT_SQ8.to_byte())
  b.write_byte(b'\x00')
  for r in p.rows {
    b.write_uint_le(r.reinterpret_as_uint())
  }
  write_sq8_payload(b, p.dim, p.rows.length(), mins, inv_scales, p.data)
  b.to_bytes()
}

///|
/// SQ8 分区：per_dim min/max 从本分区数据自算。
pub fn encode_part_sq8_auto(p : VecPart) -> Bytes {
  let (mins, scales) = sq8_params(p.dim, p.data)
  encode_part_sq8(p, mins, scales)
}

///|
/// 解码 SQ8 分区原始 payload：返回（每维 min, 每维 inv_scale, codes 平铺 u8）。
/// 仅接受 SPNDPRT1 dtype=8；行主序 codes[i*dim + d]。
pub fn decode_part_sq8_raw(
  bs : Bytes,
) -> (Array[Float], Array[Float], Array[UInt]) raise @core.SpndError {
  @core.check_magic(bs, PART_MAGIC)
  let dtype8 = match bs.get(18) {
    Some(x) => x.to_int()
    None => raise @core.Truncated("part header")
  }
  if dtype8 != DT_SQ8 {
    raise @core.Corrupt("part is not sq8 (dtype=\{dtype8})")
  }
  let count = @core.read_u32_le(bs, 12).reinterpret_as_int()
  let dim = @core.read_u16_le(bs, 16).to_int()
  if count < 0 || dim < 0 {
    raise @core.Corrupt("sq8 part header")
  }
  let vec_base = 20 + count * 4
  let scales_pos = vec_base + dim * 4
  let codes_pos = scales_pos + dim * 4
  if codes_pos > bs.length() || codes_pos + count * dim > bs.length() {
    raise @core.Truncated("sq8 payload")
  }
  let mins : Array[Float] = Array(capacity=dim)
  for d in 0..<dim {
    mins.push(@core.read_f32_le(bs, vec_base + d * 4))
  }
  let scales : Array[Float] = Array(capacity=dim)
  for d in 0..<dim {
    scales.push(@core.read_f32_le(bs, scales_pos + d * 4))
  }
  let codes : Array[UInt] = Array(capacity=count * dim)
  for i in 0..<(count * dim) {
    let byte = match bs.get(codes_pos + i) {
      Some(x) => x
      None => raise @core.Truncated("sq8 codes")
    }
    codes.push(byte.to_int().reinterpret_as_uint())
  }
  (mins, scales, codes)
}

///|
/// 编码 PQ16 分区（SPNDPQP1）。dsub = dim / m（dim 须被 m 整除，否则
/// 解码端 m×dsub==dim 校验抛 Corrupt）。codebooks 长 m×256×dsub（行主序），
/// codes 长 rows.length()×m（每字节一个中心号，0..255）。
pub fn encode_pq_part(
  rows : Array[Int],
  dim : Int,
  m : Int,
  codebooks : Array[Float],
  codes : Array[UInt],
) -> Bytes {
  let dsub = if m > 0 { dim / m } else { 0 }
  let count = rows.length()
  let b = Buffer()
  b.write_string_utf8(PQ_MAGIC)
  b.write_uint16_le(m.to_uint16())
  b.write_uint16_le(dsub.to_uint16())
  b.write_uint_le(count.reinterpret_as_uint())
  b.write_uint16_le(dim.to_uint16())
  b.write_uint16_le((0).to_uint16())
  for r in rows {
    b.write_uint_le(r.reinterpret_as_uint())
  }
  for v in codebooks {
    b.write_float_le(v)
  }
  for c in codes {
    b.write_byte(c.to_byte())
  }
  b.to_bytes()
}

///|
/// 分区文件是否为 PQ16 分区（SPNDPQP1，用于 query 侧 ADC 路径）。
pub fn is_pq_part(bs : Bytes) -> Bool {
  let m = @core.magic_bytes(PQ_MAGIC)
  if bs.length() < m.length() {
    return false
  }
  for i in 0..<m.length() {
    match (bs.get(i), m.get(i)) {
      (Some(a), Some(b)) => if a.to_int() != b.to_int() { return false }
      _ => return false
    }
  }
  true
}

///|
/// 解码 PQ16 分区（SPNDPQP1）。校验 m×dsub==dim 与 payload 完整性。
pub fn decode_pq_part(bs : Bytes) -> PQPart raise @core.SpndError {
  @core.check_magic(bs, PQ_MAGIC)
  let m = @core.read_u16_le(bs, 8).to_int()
  let dsub = @core.read_u16_le(bs, 10).to_int()
  let count = @core.read_u32_le(bs, 12).reinterpret_as_int()
  let dim = @core.read_u16_le(bs, 16).to_int()
  if m <= 0 || dsub <= 0 || count < 0 {
    raise @core.Corrupt("pq header")
  }
  if m.to_int64() * dsub.to_int64() != dim.to_int64() {
    raise @core.Corrupt("pq m*dsub != dim")
  }
  let rows_end64 = 20L + count.to_int64() * 4L
  let cb_len64 = m.to_int64() * 256L * dsub.to_int64()
  let codes_pos64 = rows_end64 + cb_len64 * 4L
  let codes_len64 = count.to_int64() * m.to_int64()
  if codes_pos64 + codes_len64 > bs.length().to_int64() {
    raise @core.Truncated("pq payload")
  }
  let rows : Array[Int] = Array(capacity=count)
  for i in 0..<count {
    rows.push(@core.read_u32_le(bs, 20 + i * 4).reinterpret_as_int())
  }
  let cb_base = rows_end64.to_int()
  let cb_len = cb_len64.to_int()
  let codebooks : Array[Float] = Array(capacity=cb_len)
  for i in 0..<cb_len {
    codebooks.push(@core.read_f32_le(bs, cb_base + i * 4))
  }
  let codes_pos = codes_pos64.to_int()
  let codes : Array[UInt] = Array(capacity=count * m)
  for i in 0..<(count * m) {
    let byte = match bs.get(codes_pos + i) {
      Some(x) => x
      None => raise @core.Truncated("pq codes")
    }
    codes.push(byte.to_int().reinterpret_as_uint())
  }
  { rows, dim, m, dsub, codebooks, codes }
}

// ---------------------------------------------------------------------------
// PQ16 共享码本变体（避免每个 IVF part 重复 256×dim f32 码本）：
//   SPNDPQB1（每 segment 一个码本对象）：
//     magic8 + m u16 + dsub u16 + dim u16 + pad u16
//     + codebooks f32×(m×256×dsub)
//   SPNDPQS1（每 part）：
//     magic8 + m u16 + dsub u16 + count u32 + dim u16 + pad u16
//     + rows u32×count + codes u8×(count×m)
// 解码后与 SPNDPQP1 的 PQPart 同构（codebooks 由外部码本对象提供）。

///|
pub const PQ_CB_MAGIC : String = "SPNDPQB1"

///|
pub const PQ_SHARED_MAGIC : String = "SPNDPQS1"

///|
pub fn encode_pq_codebook(
  dim : Int,
  m : Int,
  codebooks : Array[Float],
) -> Bytes {
  let dsub = if m > 0 { dim / m } else { 0 }
  let b = Buffer()
  b.write_string_utf8(PQ_CB_MAGIC)
  b.write_uint16_le(m.to_uint16())
  b.write_uint16_le(dsub.to_uint16())
  b.write_uint16_le(dim.to_uint16())
  b.write_uint16_le((0).to_uint16())
  for v in codebooks {
    b.write_float_le(v)
  }
  b.to_bytes()
}

///|
/// 解码共享码本，返回（m, dsub, dim, codebooks）。
pub fn decode_pq_codebook(
  bs : Bytes,
) -> (Int, Int, Int, Array[Float]) raise @core.SpndError {
  @core.check_magic(bs, PQ_CB_MAGIC)
  let fa = bs.to_fixedarray()
  let m = fa_u16(fa, 8)
  let dsub = fa_u16(fa, 10)
  let dim = fa_u16(fa, 12)
  if m <= 0 || dsub <= 0 || m * dsub != dim {
    raise @core.Corrupt("pq codebook header")
  }
  let n = m * 256 * dsub
  if 16 + n * 4 > bs.length() {
    raise @core.Truncated("pq codebook payload")
  }
  let cbs : Array[Float] = Array(capacity=n)
  for i in 0..<n {
    cbs.push(fa_f32(fa, 16 + i * 4))
  }
  (m, dsub, dim, cbs)
}

///|
/// 编码共享码本的 PQ16 分区（SPNDPQS1）：rows + codes，不含码本。
pub fn encode_pq_part_shared(
  rows : Array[Int],
  dim : Int,
  m : Int,
  codes : Array[UInt],
) -> Bytes {
  let dsub = if m > 0 { dim / m } else { 0 }
  let count = rows.length()
  let b = Buffer()
  b.write_string_utf8(PQ_SHARED_MAGIC)
  b.write_uint16_le(m.to_uint16())
  b.write_uint16_le(dsub.to_uint16())
  b.write_uint_le(count.reinterpret_as_uint())
  b.write_uint16_le(dim.to_uint16())
  b.write_uint16_le((0).to_uint16())
  for r in rows {
    b.write_uint_le(r.reinterpret_as_uint())
  }
  for c in codes {
    b.write_byte(c.to_byte())
  }
  b.to_bytes()
}

///|
/// 是否为共享码本分区（SPNDPQS1）。
pub fn is_pq_shared_part(bs : Bytes) -> Bool {
  let m = @core.magic_bytes(PQ_SHARED_MAGIC)
  if bs.length() < m.length() {
    return false
  }
  for i in 0..<m.length() {
    match (bs.get(i), m.get(i)) {
      (Some(a), Some(b)) => if a.to_int() != b.to_int() { return false }
      _ => return false
    }
  }
  true
}

///|
/// 解码共享码本分区，返回 PQPart（codebooks 为空，调用方从码本对象取）。
pub fn decode_pq_part_shared(bs : Bytes) -> PQPart raise @core.SpndError {
  @core.check_magic(bs, PQ_SHARED_MAGIC)
  let fa = bs.to_fixedarray()
  let m = fa_u16(fa, 8)
  let dsub = fa_u16(fa, 10)
  let count = fa_i32(fa, 12)
  let dim = fa_u16(fa, 16)
  if m <= 0 || dsub <= 0 || count < 0 || m * dsub != dim {
    raise @core.Corrupt("pq shared part header")
  }
  let rows_end = 20 + count * 4
  let codes_end = rows_end + count * m
  if codes_end > bs.length() {
    raise @core.Truncated("pq shared part payload")
  }
  let rows : Array[Int] = Array(capacity=count)
  for i in 0..<count {
    rows.push(fa_i32(fa, 20 + i * 4))
  }
  let codes : Array[UInt] = Array(capacity=count * m)
  for i in 0..<(count * m) {
    codes.push(fa[rows_end + i].to_int().reinterpret_as_uint())
  }
  { rows, dim, m, dsub, codebooks: [], codes }
}

pub extend PQPart with Debug::{to_repr}
