// BM25 倒排编解码。
//
// SPNDDIR1（fts/dir.bin，小、常驻缓存），16B 头：
//   [0..8)   magic "SPNDDIR1"
//   [8..12)  term_count u32 LE
//   [12..16) postings_bytes u32 LE
//   [16..20) doc_count u32 LE（该 segment 的文档数）
// 头 20 字节后是 term_count 条目录项（按 String::compare 序升序，内部自洽）：
//   term_len u8 + term UTF-8 bytes + offset u32 + size u32 + df u32
//   offset/size 相对 postings payload 起点（去掉 SPNDPOS1 16B 头之后）。
//
// SPNDPOS1（fts/postings.bin，大、范围读）：
//   [0..8)   magic "SPNDPOS1"
//   [8..12)  payload_bytes u32 LE
//   [12..16) 保留 u32
// payload：每个 term 的 posting list 依 dir 的 offset/size 存放：
//   repeated: row_delta uvarint（首条 = row+1，之后 = row - prev，恒 >= 1）+ tf uvarint

///|
pub const DIR_MAGIC : String = "SPNDDIR1"

///|
pub const POS_MAGIC : String = "SPNDPOS1"

///|
pub(all) struct Posting {
  row : Int
  tf : Int
} derive(Debug)

///|
pub(all) struct FtsDirEntry {
  term : String
  offset : Int
  size : Int
  df : Int
} derive(Debug)

///|
pub(all) struct FtsBuilt {
  dir : Bytes
  postings : Bytes
  entries : Array[FtsDirEntry]
  doc_count : Int
} derive(Debug)

///|
/// 序列化倒排：lists 为 (term, postings)，内部会按 term 排序对齐目录。
pub fn encode_fts(lists : Array[(String, Array[Posting])]) -> FtsBuilt {
  let sorted = lists.copy()
  sorted.sort_by(fn(a, b) { a.0.compare(b.0) })
  let payload = Buffer()
  let entries : Array[FtsDirEntry] = Array::new()
  let dir_meta = Buffer()
  for kv in sorted {
    let (term, posts) = kv
    let start = payload.length()
    let mut prev = -1
    for p in posts {
      @core.write_uvarint(payload, (p.row - prev).to_uint())
      @core.write_uvarint(payload, p.tf.to_uint())
      prev = p.row
    }
    let size = payload.length() - start
    let tb = @utf8.encode(term)
    dir_meta.write_byte(tb.length().to_byte())
    dir_meta.write_bytes(tb.view())
    dir_meta.write_uint_le(start.to_uint())
    dir_meta.write_uint_le(size.to_uint())
    dir_meta.write_uint_le(posts.length().to_uint())
    entries.push({ term, offset: start, size, df: posts.length() })
  }
  // DIR 头 20B
  let dir = Buffer()
  dir.write_string_utf8(DIR_MAGIC)
  dir.write_uint_le(sorted.length().to_uint())
  dir.write_uint_le(payload.length().to_uint())
  dir.write_uint_le(0U) // doc_count 由 build 侧回填，MVP 由 meta.json 承载
  dir.write_bytes(dir_meta.to_bytes().view())
  // POS 头 16B
  let pos = Buffer()
  pos.write_string_utf8(POS_MAGIC)
  pos.write_uint_le(payload.length().to_uint())
  pos.write_uint_le(0U)
  pos.write_bytes(payload.to_bytes().view())
  {
    dir: dir.to_bytes(),
    postings: pos.to_bytes(),
    entries,
    doc_count: 0,
  }
}

///|
pub fn decode_fts_dir(bs : Bytes) -> Array[FtsDirEntry] raise @core.SpndError {
  @core.check_magic(bs, DIR_MAGIC)
  let term_count = @core.read_u32_le(bs, 8).to_int()
  let out : Array[FtsDirEntry] = Array::new(capacity=term_count)
  let mut pos = 20
  for _ in 0..<term_count {
    let tlen = match bs.get(pos) {
      Some(x) => x.to_int()
      None => raise @core.Truncated("dir term_len")
    }
    pos += 1
    let term = @utf8.decode(bs.view(start=pos, end=pos + tlen)) catch {
      _ => raise @core.Corrupt("invalid utf8 in fts dir")
    }
    pos += tlen
    let offset = @core.read_u32_le(bs, pos).to_int()
    let size = @core.read_u32_le(bs, pos + 4).to_int()
    let df = @core.read_u32_le(bs, pos + 8).to_int()
    pos += 12
    out.push({ term, offset, size, df })
  }
  out
}

///|
/// 解码一个 term 的 posting list。blob 是完整 postings.bin；
/// entry.offset/size 相对 payload（16B 头之后）。
pub fn read_postings(blob : Bytes, entry : FtsDirEntry) -> Array[Posting] raise @core.SpndError {
  @core.check_magic(blob, POS_MAGIC)
  let base = 16 + entry.offset
  let end = base + entry.size
  if end > blob.length() {
    raise @core.Truncated("postings range")
  }
  let out : Array[Posting] = Array::new(capacity=entry.df)
  let mut prev = -1
  let mut pos = base
  while pos < end {
    let (delta, p1) = @core.read_uvarint(blob, pos)
    let (tf, p2) = @core.read_uvarint(blob, p1)
    prev = prev + delta.to_int()
    out.push({ row: prev, tf: tf.to_int() })
    pos = p2
  }
  out
}
