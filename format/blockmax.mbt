// block-max 索引（fts/blockmax.bin，新文件，WAND 块跳过用）。
//
// SPNDBLK1，20B 头：
//   [0..8)    magic "SPNDBLK1"
//   [8..12)   term_count u32 LE
//   [12..16)  block_size u32 LE（构建参数，如 128，原样存回）
//   [16..20)  pad u32 LE（0）
// 之后逐 term（顺序与 fts dir 的 term 序一致，按下标对齐，本格式不存 term）：
//   block_count u32 + block_count × (max_tf u32, min_dl u32)
// 即每 block 8B：max_tf u32 LE + min_dl u32 LE。

///|
pub const BLK_MAGIC : String = "SPNDBLK1"

///|
/// 编码 block-max 索引。per_term_blocks[t] = 第 t 个 term 的块列表
/// (max_tf, min_dl)，顺序必须与 fts dir 的 term 顺序一致。
pub fn encode_blockmax(
  per_term_blocks : Array[Array[(Int, Int)]],
  block_size : Int,
) -> Bytes {
  let b = Buffer()
  b.write_string_utf8(BLK_MAGIC)
  b.write_uint_le(per_term_blocks.length().reinterpret_as_uint())
  b.write_uint_le(block_size.reinterpret_as_uint())
  b.write_uint_le(0U)
  for blocks in per_term_blocks {
    b.write_uint_le(blocks.length().reinterpret_as_uint())
    for blk in blocks {
      b.write_uint_le(blk.0.reinterpret_as_uint())
      b.write_uint_le(blk.1.reinterpret_as_uint())
    }
  }
  b.to_bytes()
}

///|
/// 解码 block-max 索引，返回每 term 的 (max_tf, min_dl) 块列表。
pub fn decode_blockmax(
  bs : Bytes,
) -> Array[Array[(Int, Int)]] raise @core.SpndError {
  @core.check_magic(bs, BLK_MAGIC)
  let term_count = @core.read_u32_le(bs, 8).reinterpret_as_int()
  let _block_size = @core.read_u32_le(bs, 12).reinterpret_as_int()
  if term_count < 0 {
    raise @core.Corrupt("blockmax term_count")
  }
  let out : Array[Array[(Int, Int)]] = Array(capacity=term_count)
  let mut pos = 20
  for _ in 0..<term_count {
    let block_count = @core.read_u32_le(bs, pos).reinterpret_as_int()
    pos += 4
    if block_count < 0 || pos + block_count * 8 > bs.length() {
      raise @core.Corrupt("blockmax block_count")
    }
    let blocks : Array[(Int, Int)] = Array(capacity=block_count)
    for _ in 0..<block_count {
      let max_tf = @core.read_u32_le(bs, pos).reinterpret_as_int()
      let min_dl = @core.read_u32_le(bs, pos + 4).reinterpret_as_int()
      pos += 8
      blocks.push((max_tf, min_dl))
    }
    out.push(blocks)
  }
  out
}
