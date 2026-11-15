// 单文件紧凑 Part 格式（ClickHouse-style Compact Part layout）。
//
// 所有列、全文倒排索引和向量 IVF 分区打包在单一紧凑文件中，尾部附加 Mark / Offset 索引（Footer），
// 读路径通过 Range GET 按需读取各个列或倒排/向量切片，零全量 GET，零多文件碎片。
//
// 二进制布局：
//   [0 .. footer_offset)           Section Bodies（列数据、倒排 dir/postings/doc_len、向量分区）
//   [footer_offset .. trailer_off) Footer (Mark / Offset 索引)
//   [trailer_off .. L)             Trailer (固定 16 字节)
//
// Footer 布局：
//   [0..8)   magic "SPNDFOOT"
//   [8..12)  section_count u32 LE
//   repeated sections:
//     name_len u16 LE + name UTF-8 + offset u64 LE + length u64 LE + extra u32 LE
//
// Trailer 布局（文件末尾 16 字节）：
//   [0..8)   footer_offset u64 LE
//   [8..12)  footer_length u32 LE
//   [12..16) magic "CPT1"

///|
pub const COMPACT_FOOTER_MAGIC : String = "SPNDFOOT"

///|
pub const COMPACT_TRAILER_MAGIC : String = "CPT1"

///|
pub const COMPACT_TRAILER_LEN : Int = 16

///|
#derive(Debug, Eq)
pub(all) struct CompactSection {
  name : String
  offset : Int
  length : Int
  extra : Int
}

///|
#derive(Debug, Eq)
pub(all) struct CompactFooter {
  sections : Array[CompactSection]
}

///|
pub fn CompactFooter::get(self : CompactFooter, name : String) -> CompactSection? {
  for sec in self.sections {
    if sec.name == name {
      return Some(sec)
    }
  }
  None
}

///|
pub fn CompactFooter::has(self : CompactFooter, name : String) -> Bool {
  match self.get(name) {
    Some(_) => true
    None => false
  }
}

///|
/// 解码文件尾部 16 字节的 Trailer，返回 (footer_offset, footer_length)。
pub fn decode_compact_part_trailer(bs : Bytes) -> (Int, Int) raise @core.SpndError {
  let len = bs.length()
  if len < COMPACT_TRAILER_LEN {
    raise @core.Truncated("compact part trailer too short")
  }
  let t_off = len - COMPACT_TRAILER_LEN
  if bs[t_off + 12] != b'C' ||
    bs[t_off + 13] != b'P' ||
    bs[t_off + 14] != b'T' ||
    bs[t_off + 15] != b'1' {
    raise @core.Corrupt("invalid compact part trailer magic")
  }
  let fa = bs.to_fixedarray()
  let footer_offset = fa_u64(fa, t_off).to_int()
  let footer_len = fa_i32(fa, t_off + 8)
  if footer_offset < 0 || footer_len < 0 {
    raise @core.Corrupt("invalid compact part footer offset/length in trailer")
  }
  if len > COMPACT_TRAILER_LEN && footer_offset + footer_len != t_off {
    raise @core.Corrupt("compact part footer offset/length does not match trailer position")
  }
  (footer_offset, footer_len)
}

///|
/// 解码 Footer。bs 可以是包含 footer 的完整 part 字节，也可以是单独 Range GET 下来的 footer 字节（此时 footer_offset=0）。
pub fn decode_compact_part_footer(
  bs : Bytes,
  footer_offset : Int,
  footer_len : Int
) -> CompactFooter raise @core.SpndError {
  if footer_offset < 0 ||
    footer_len < 12 ||
    footer_offset + footer_len > bs.length() {
    raise @core.Truncated("compact footer slice out of bounds")
  }
  let fa = bs.to_fixedarray()
  // 检查 "SPNDFOOT" 魔数 (8 字节)
  if fa[footer_offset] != b'S' ||
    fa[footer_offset + 1] != b'P' ||
    fa[footer_offset + 2] != b'N' ||
    fa[footer_offset + 3] != b'D' ||
    fa[footer_offset + 4] != b'F' ||
    fa[footer_offset + 5] != b'O' ||
    fa[footer_offset + 6] != b'O' ||
    fa[footer_offset + 7] != b'T' {
    raise @core.Corrupt("invalid compact footer magic")
  }
  let count = fa_i32(fa, footer_offset + 8)
  if count < 0 {
    raise @core.Corrupt("negative compact footer section count")
  }
  let sections : Array[CompactSection] = Array(capacity=count)
  let mut pos = footer_offset + 12
  let end_pos = footer_offset + footer_len
  for _ in 0..<count {
    if pos + 2 > end_pos {
      raise @core.Truncated("compact footer section name_len")
    }
    let name_len = fa_u16(fa, pos)
    pos += 2
    if pos + name_len + 20 > end_pos {
      raise @core.Truncated("compact footer section entry")
    }
    let name_bytes = bs.exact_view(start=pos, end=pos + name_len).to_owned()
    let name = @utf8.decode(name_bytes.exact_view()) catch {
      _ => raise @core.Corrupt("compact footer section name is not valid utf-8")
    }
    pos += name_len
    let sec_offset = fa_u64(fa, pos).to_int()
    pos += 8
    let sec_len = fa_u64(fa, pos).to_int()
    pos += 8
    let extra = fa_i32(fa, pos)
    pos += 4
    sections.push({
      name,
      offset: sec_offset,
      length: sec_len,
      extra,
    })
  }
  { sections, }
}

///|
/// 从整个 part 字节中提取指定 section 的字节数据（用于全量在内存时的便捷读取）。
pub fn read_compact_section(
  part_bytes : Bytes,
  sec : CompactSection
) -> Bytes raise @core.SpndError {
  if sec.offset < 0 ||
    sec.length < 0 ||
    sec.offset + sec.length > part_bytes.length() {
    raise @core.Truncated("compact section range out of bounds: \{sec.name}")
  }
  part_bytes.exact_view(start=sec.offset, end=sec.offset + sec.length).to_owned()
}

///|
/// 紧凑 Part 编码器：将一整批 Doc 及其列、全文倒排与可选 IVF 向量分区打包为单个 consolidated part 字节。
pub fn encode_compact_part(
  docs : Array[@core.Doc],
  dim : Int,
  use_f16 : Bool,
  centroids : Centroids?
) -> (Bytes, CompactFooter) {
  let n = docs.length()
  let ids : Array[UInt64] = Array(capacity=n)
  let texts : Array[String] = Array(capacity=n)
  let cats : Array[String] = Array(capacity=n)
  let tss : Array[Int64] = Array(capacity=n)
  let pubs : Array[Bool] = Array(capacity=n)
  let vecs : Array[Float] = Array(capacity=n * dim)

  for d in docs {
    ids.push(d.id)
    texts.push(d.text)
    cats.push(d.category)
    tss.push(d.ts)
    pubs.push(d.public)
    for v in d.vector {
      vecs.push(v)
    }
  }

  // 1. 编码各列
  let id_bytes = encode_col(ColU64(ids))
  let text_bytes = encode_col(ColStr(texts))
  let cat_bytes = encode_col(ColStr(cats))
  let ts_bytes = encode_col(ColI64(tss))
  let pub_bytes = encode_col(ColBool(pubs))
  let vec_bytes = encode_vec_col(dim, vecs, use_f16)

  // 2. 编码全文倒排
  let term_map : Map[String, Array[Posting]] = Map([])
  let doc_lens : Array[Int] = Array(capacity=n)
  for i in 0..<n {
    let tokens = @core.tokenize(texts[i])
    doc_lens.push(tokens.length())
    let doc_tf : Map[String, Int] = Map([])
    for t in tokens {
      match doc_tf.get(t) {
        Some(c) => doc_tf.set(t, c + 1)
        None => doc_tf.set(t, 1)
      }
    }
    for kv in doc_tf {
      let (term, tf) = kv
      let list = match term_map.get(term) {
        Some(a) => a
        None => {
          let a : Array[Posting] = Array()
          term_map.set(term, a)
          a
        }
      }
      list.push({ row: i, tf })
    }
  }

  let term_lists : Array[(String, Array[Posting])] = Array()
  for kv in term_map {
    term_lists.push(kv)
  }
  let fts_built = encode_fts(term_lists)
  let doc_len_bytes = encode_col(ColU32(doc_lens))

  // 3. 编码 IVF 向量分区（如果提供了中心）
  let vec_part_bytes : Array[(String, Bytes)] = Array()
  match centroids {
    Some(cen) =>
      if cen.k() > 0 && n > 0 {
        let part_rows : Map[Int, Array[Int]] = Map([])
        let part_vecs : Map[Int, Array[Float]] = Map([])
        for i in 0..<n {
          let mut best_c = 0
          let mut best_d = @core.cosine_dist_f32(vecs, i * dim, cen.data, 0, dim)
          for c in 1..<cen.k() {
            let d = @core.cosine_dist_f32(vecs, i * dim, cen.data, c * dim, dim)
            if d < best_d {
              best_d = d
              best_c = c
            }
          }
          let rows = match part_rows.get(best_c) {
            Some(a) => a
            None => {
              let a : Array[Int] = Array()
              part_rows.set(best_c, a)
              a
            }
          }
          rows.push(i)
          let pdata = match part_vecs.get(best_c) {
            Some(a) => a
            None => {
              let a : Array[Float] = Array()
              part_vecs.set(best_c, a)
              a
            }
          }
          for d_idx in 0..<dim {
            pdata.push(vecs[i * dim + d_idx])
          }
        }
        for kv in part_rows {
          let (cid, rows) = kv
          let data = match part_vecs.get(cid) {
            Some(a) => a
            None => []
          }
          let vp : VecPart = { cid, dim, rows, data }
          let pbytes = encode_part(vp, use_f16)
          vec_part_bytes.push(("vec:part:\{cid}", pbytes))
        }
      }
    None => ()
  }

  // 4. 将各 section 紧凑写入 Buffer 并记录 offset/length
  let b = Buffer()
  let sections : Array[CompactSection] = Array()

  let append_sec = fn(name : String, data : Bytes, extra : Int) {
    let offset = b.length()
    b.write_bytes(data.exact_view())
    let length = data.length()
    sections.push({ name, offset, length, extra })
  }

  append_sec("col:id", id_bytes, n)
  append_sec("col:text", text_bytes, n)
  append_sec("col:category", cat_bytes, n)
  append_sec("col:ts", ts_bytes, n)
  append_sec("col:public", pub_bytes, n)
  append_sec("col:vector", vec_bytes, n)
  append_sec("fts:dir", fts_built.dir, term_lists.length())
  append_sec("fts:postings", fts_built.postings, 0)
  append_sec("fts:doc_len", doc_len_bytes, n)

  for kv in vec_part_bytes {
    let (pname, pbytes) = kv
    append_sec(pname, pbytes, 0)
  }

  // 5. 写入 Footer (Mark Index)
  let footer_offset = b.length()
  b.write_string_utf8(COMPACT_FOOTER_MAGIC)
  b.write_uint_le(sections.length().reinterpret_as_uint())
  for sec in sections {
    let nb = @utf8.encode(sec.name)
    b.write_uint16_le(nb.length().to_uint16())
    b.write_bytes(nb.exact_view())
    b.write_uint64_le(sec.offset.to_uint64())
    b.write_uint64_le(sec.length.to_uint64())
    b.write_uint_le(sec.extra.reinterpret_as_uint())
  }
  let footer_length = b.length() - footer_offset

  // 6. 写入 Trailer (固定 16 字节)
  b.write_uint64_le(footer_offset.to_uint64())
  b.write_uint_le(footer_length.reinterpret_as_uint())
  b.write_string_utf8(COMPACT_TRAILER_MAGIC)

  (b.to_bytes(), { sections, })
}

///|
/// 从 Compact Part 中解码全部文档对象。
pub fn decode_compact_part_docs(
  part_bytes : Bytes,
  footer : CompactFooter
) -> Array[@core.Doc] raise @core.SpndError {
  let get_sec = fn(name : String) -> CompactSection raise @core.SpndError {
    match footer.get(name) {
      Some(s) => s
      None => raise @core.NotFound("compact part missing section \{name}")
    }
  }

  let ids = match decode_col(read_compact_section(part_bytes, get_sec("col:id"))) {
    ColU64(a) => a
    _ => raise @core.Corrupt("col:id is not u64")
  }
  let texts = match decode_col(read_compact_section(part_bytes, get_sec("col:text"))) {
    ColStr(a) => a
    _ => raise @core.Corrupt("col:text is not str")
  }
  let cats = match decode_col(read_compact_section(part_bytes, get_sec("col:category"))) {
    ColStr(a) => a
    _ => raise @core.Corrupt("col:category is not str")
  }
  let tss = match decode_col(read_compact_section(part_bytes, get_sec("col:ts"))) {
    ColI64(a) => a
    _ => raise @core.Corrupt("col:ts is not i64")
  }
  let pubs = match decode_col(read_compact_section(part_bytes, get_sec("col:public"))) {
    ColBool(a) => a
    _ => raise @core.Corrupt("col:public is not bool")
  }
  let (dim, flat_vecs) = decode_vec_col(
    read_compact_section(part_bytes, get_sec("col:vector")),
  )

  let n = ids.length()
  if texts.length() != n ||
    cats.length() != n ||
    tss.length() != n ||
    pubs.length() != n ||
    flat_vecs.length() != n * dim {
    raise @core.Corrupt("compact part column length mismatch")
  }

  let docs : Array[@core.Doc] = Array(capacity=n)
  for i in 0..<n {
    let v : Array[Float] = Array(capacity=dim)
    for d in 0..<dim {
      v.push(flat_vecs[i * dim + d])
    }
    docs.push({
      id: ids[i],
      text: texts[i],
      vector: v,
      category: cats[i],
      ts: tss[i],
      public: pubs[i],
    })
  }
  docs
}

pub extend CompactSection with Debug::{to_repr}
pub extend CompactSection with Eq::{not_equal, equal}
pub extend CompactFooter with Debug::{to_repr}
pub extend CompactFooter with Eq::{not_equal, equal}
