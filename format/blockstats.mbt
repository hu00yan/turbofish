// 块级统计（256 行 row-group），用于 filter 时只读命中的 ts 块。
//
// SPNDBST1，20B 头：
//   [0..8)   magic "SPNDBST1"
//   [8..12)  block_size u32
//   [12..16) block_count u32
//   [16..20) row_count u32
// per block: ts_min i64 + ts_max i64（16B，小端）
//
// 目前只存 ts min/max：category/public 的段级统计已在 seg meta.json；
// 块级 category 需要额外字典，收益在 500 行/段以下不明显，暂不实现。

///|
pub const BLOCKSTATS_MAGIC : String = "SPNDBST1"

///|
pub fn encode_blockstats(
  blocks : Array[(Int64, Int64)],
  block_size : Int,
  row_count : Int,
) -> Bytes {
  let b = Buffer()
  b.write_string_utf8(BLOCKSTATS_MAGIC)
  b.write_uint_le(block_size.reinterpret_as_uint())
  b.write_uint_le(blocks.length().reinterpret_as_uint())
  b.write_uint_le(row_count.reinterpret_as_uint())
  for blk in blocks {
    b.write_int64_le(blk.0)
    b.write_int64_le(blk.1)
  }
  b.to_bytes()
}

///|
/// 返回（block_size, row_count, 每块 (ts_min, ts_max)）。
pub fn decode_blockstats(
  bs : Bytes,
) -> (Int, Int, Array[(Int64, Int64)]) raise @core.SpndError {
  @core.check_magic(bs, BLOCKSTATS_MAGIC)
  let fa = bs.to_fixedarray()
  let block_size = fa_i32(fa, 8)
  let block_count = fa_i32(fa, 12)
  let row_count = fa_i32(fa, 16)
  if block_size <= 0 || block_count < 0 || row_count < 0 {
    raise @core.Corrupt("blockstats header")
  }
  if 20 + block_count * 16 > bs.length() {
    raise @core.Truncated("blockstats payload")
  }
  let out : Array[(Int64, Int64)] = Array::new(capacity=block_count)
  for i in 0..<block_count {
    out.push((fa_i64(fa, 20 + i * 16), fa_i64(fa, 28 + i * 16)))
  }
  (block_size, row_count, out)
}
