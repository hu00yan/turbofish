// namespace 级全局 IVF 分区（每 cid 一个对象，跨 segment 合并）。
//
// 目的：消除 `nprobe × live_segments` 的向量请求放大。全局分区按 manifest id
// 分代（`vec/global/{manifest_id}/part-{cid}.bin`），旧 manifest 快照仍读旧代，
// 新 ingest/compact 写新代，避免读写竞争。
//
// SPNDGVP1，20B 头：
//   [0..8)   magic "SPNDGVP1"
//   [8..12)  cid u32
//   [12..16) count u32
//   [16..18) dim u16
//   [18]     dtype: 4=f32 7=f16
//   [19]     pad
// payload:
//   rows: count × (seg_idx u32, row u32)   // seg_idx = manifest.segments 下标
//   data: count × dim × item_size 行主序

///|
pub const GLOBAL_VEC_MAGIC : String = "SPNDGVP1"

///|
#derive(Debug)
pub(all) struct GlobalVecPart {
  cid : Int
  rows : Array[(Int, Int)] // (seg_idx, segment 内行号)
  dim : Int
  data : Array[Float]
}

///|
pub fn encode_global_part(
  cid : Int,
  rows : Array[(Int, Int)],
  dim : Int,
  data : Array[Float],
  use_f16 : Bool,
) -> Bytes {
  let b = Buffer()
  b.write_string_utf8(GLOBAL_VEC_MAGIC)
  b.write_uint_le(cid.reinterpret_as_uint())
  b.write_uint_le(rows.length().reinterpret_as_uint())
  b.write_uint16_le(dim.to_uint16())
  b.write_byte(if use_f16 { DT_F16.to_byte() } else { DT_F32.to_byte() })
  b.write_byte(b'\x00')
  for r in rows {
    b.write_uint_le(r.0.reinterpret_as_uint())
    b.write_uint_le(r.1.reinterpret_as_uint())
  }
  if use_f16 {
    for v in data {
      b.write_uint16_le(@core.f32_to_f16_bits(v))
    }
  } else {
    for v in data {
      b.write_float_le(v)
    }
  }
  b.to_bytes()
}

///|
pub fn decode_global_part(bs : Bytes) -> GlobalVecPart raise @core.SpndError {
  @core.check_magic(bs, GLOBAL_VEC_MAGIC)
  let fa = bs.to_fixedarray()
  let cid = fa_i32(fa, 8)
  let count = fa_i32(fa, 12)
  let dim = fa_u16(fa, 16)
  let dtype = match bs.get(18) {
    Some(x) => x.to_int()
    None => raise @core.Truncated("global vec header")
  }
  if count < 0 || dim < 0 {
    raise @core.Corrupt("global vec header")
  }
  let rows_end = 20 + count * 8
  let item = if dtype == DT_F16 {
    2
  } else if dtype == DT_F32 {
    4
  } else {
    raise @core.Corrupt("global vec dtype \{dtype}")
  }
  if rows_end + count * dim * item > bs.length() {
    raise @core.Truncated("global vec payload")
  }
  let rows : Array[(Int, Int)] = Array(capacity=count)
  for i in 0..<count {
    rows.push((fa_i32(fa, 20 + i * 8), fa_i32(fa, 24 + i * 8)))
  }
  let data : Array[Float] = Array(capacity=count * dim)
  let base = rows_end
  for i in 0..<(count * dim) {
    let pos = base + i * item
    if dtype == DT_F16 {
      data.push(@core.f16_bits_to_f32(fa_u16(fa, pos).to_uint16()))
    } else {
      data.push(fa_f32(fa, pos))
    }
  }
  { cid, rows, dim, data }
}

// ---------- global part pack（SPNDGVPK）----------
//
// 目的：把同一代里相邻 cid 的 part 打包成更少的对象，降低 cold 查询的 GET 数
// （nprobe 个 cid 命中的 distinct pack 数 < nprobe）。字节总量不变；真 S3 同区
// 域读带宽远大于单请求成本，整 pack 读的延迟代价可接受（toxiproxy 限带宽场景
// 除外）。pack 信息记录在该代 meta.json 的 `"pack_size"` 字段，读者缺省未打包。
//
// SPNDGVPK 布局：
//   [0..8)   magic "SPNDGVPK"
//   [8..12)  part_count u32
//   [12..16) pad u32
//   index: part_count × (cid u32, offset u32, len u32)
//     offset/len = 该 part 的 SPNDGVP1 blob 在 pack 内的绝对 [offset, offset+len)
//   payload: part_count 个 SPNDGVP1 blob 依序拼接（cid 升序）

///|
pub const GLOBAL_PACK_MAGIC : String = "SPNDGVPK"

///|
/// 打包若干 (cid, part blob)。调用方（写路径）按 cid 升序传入相邻 cid 组；
/// blob 必须是标准 `encode_global_part` 输出。
pub fn encode_global_pack(entries : Array[(Int, Bytes)]) -> Bytes {
  let b = Buffer()
  b.write_string_utf8(GLOBAL_PACK_MAGIC)
  b.write_uint_le(entries.length().reinterpret_as_uint())
  b.write_uint_le(0U)
  // 先算 index：blob 起始 = 16 + part_count*12
  let mut off = 16 + entries.length() * 12
  for e in entries {
    b.write_uint_le(e.0.reinterpret_as_uint())
    b.write_uint_le(off.reinterpret_as_uint())
    b.write_uint_le(e.1.length().reinterpret_as_uint())
    off += e.1.length()
  }
  for e in entries {
    b.write_bytes(e.1)
  }
  b.to_bytes()
}

///|
/// 解 pack index：返回 (cid, offset, len) 列表（按 pack 内顺序，cid 升序）。
pub fn decode_global_pack_index(bs : Bytes) -> Array[(Int, Int, Int)] raise @core.SpndError {
  @core.check_magic(bs, GLOBAL_PACK_MAGIC)
  let fa = bs.to_fixedarray()
  let n = fa_i32(fa, 8)
  if n < 0 || 16 + n * 12 > bs.length() {
    raise @core.Truncated("global pack header")
  }
  let out : Array[(Int, Int, Int)] = Array(capacity=n)
  for i in 0..<n {
    let pos = 16 + i * 12
    let cid = fa_i32(fa, pos)
    let off = fa_i32(fa, pos + 4)
    let len = fa_i32(fa, pos + 8)
    if off < 0 || len < 0 || off + len > bs.length() {
      raise @core.Truncated("global pack index")
    }
    out.push((cid, off, len))
  }
  out
}

///|
/// 从 pack 的绝对 [offset, offset+len) 解出一个标准 global part（不复制 blob）。
pub fn decode_global_part_at(
  bs : Bytes,
  offset : Int,
  len : Int,
) -> GlobalVecPart raise @core.SpndError {
  if offset < 0 || len < 20 || offset + len > bs.length() {
    raise @core.Truncated("global pack slice")
  }
  // 子区间是一个标准 SPNDGVP1 part blob：magic 校验在 offset 处
  // （check_magic 只支持 offset=0，这里内联校验）。
  for i in 0..<8 {
    let want = GLOBAL_VEC_MAGIC[i].to_int()
    match bs.get(offset + i) {
      Some(x) =>
        if x.to_int() != want {
          raise @core.BadMagic(GLOBAL_VEC_MAGIC)
        }
      None => raise @core.Truncated("magic \{GLOBAL_VEC_MAGIC}")
    }
  }
  let fa = bs.to_fixedarray()
  let cid = fa_i32(fa, offset + 8)
  let count = fa_i32(fa, offset + 12)
  let dim = fa_u16(fa, offset + 16)
  let dtype = match bs.get(offset + 18) {
    Some(x) => x.to_int()
    None => raise @core.Truncated("global vec header")
  }
  if count < 0 || dim < 0 {
    raise @core.Corrupt("global vec header")
  }
  // 与 decode_global_part 同构：rows 在 header(20B) 后，data 在 rows 之后。
  let rows_off = offset + 20
  let rows_end = rows_off + count * 8
  let item = if dtype == DT_F16 {
    2
  } else if dtype == DT_F32 {
    4
  } else {
    raise @core.Corrupt("global vec dtype \{dtype}")
  }
  if rows_end + count * dim * item > offset + len {
    raise @core.Truncated("global vec payload")
  }
  let rows : Array[(Int, Int)] = Array(capacity=count)
  for i in 0..<count {
    rows.push((fa_i32(fa, rows_off + i * 8), fa_i32(fa, rows_off + i * 8 + 4)))
  }
  let data : Array[Float] = Array(capacity=count * dim)
  let base = rows_end
  for i in 0..<(count * dim) {
    let pos = base + i * item
    if dtype == DT_F16 {
      data.push(@core.f16_bits_to_f32(fa_u16(fa, pos).to_uint16()))
    } else {
      data.push(fa_f32(fa, pos))
    }
  }
  { cid, rows, dim, data }
}

pub extend GlobalVecPart with Debug::{to_repr}
