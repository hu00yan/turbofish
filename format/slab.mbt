// SlabV2 单文件段存储布局（Single-file segment layout）。
//
// 目的：消除每个段 5+ 个碎片文件（rows/id.bin, text.bin, category.bin, ts.bin,
// public.bin, fts/dir.bin, fts/postings.bin, fts/doc_len.bin, ...）带来的
// 对象存储请求放大与元数据开销。
//
// SlabV2 二进制布局：
//   Header (固定 14 字节)：
//     [0..4)   magic "SLAB"
//     [4..6)   version u16 LE (当前版本: 2)
//     [6..14)  index_offset u64 LE
//
//   Contiguous Data Blocks:
//     依次存放 ID 列、Attribute 列、FTS 目录、FTS postings 等各组件的数据块。
//
//   Index Table (位于 index_offset，可在文件尾部或紧随 Header 后的固定偏移)：
//     [0..4)   magic "SLIX"
//     [4..8)   entry_count u32 LE
//     repeated entries:
//       name_len u16 LE
//       name UTF-8 字节
//       offset u64 LE
//       length u64 LE
//       row_count u32 LE
//
//   Trailer (仅当 Index 位于文件尾部时追加，固定 16 字节)：
//     [0..8)   index_offset u64 LE
//     [8..12)  index_length u32 LE
//     [12..16) magic "SLAB"
//
// 读路径：通过 1 次 Range GET 请求拉取 Header + Index（或尾部 Trailer + Index），
// 然后针对所需组件按 (offset, length) 发起精确的局部 Range GET，实现零碎片、零多余数据拉取。

///|
#derive(Debug, Eq)
pub(all) enum SegmentFormat {
  LegacyMultiFile
  SlabV2
}

///|
pub fn SegmentFormat::to_string(self : SegmentFormat) -> String {
  match self {
    LegacyMultiFile => "legacy_multi_file"
    SlabV2 => "slab_v2"
  }
}

///|
pub fn SegmentFormat::from_string(s : String) -> SegmentFormat? {
  match s {
    "legacy_multi_file" | "legacy" => Some(LegacyMultiFile)
    "slab_v2" | "slab" | "v2" => Some(SlabV2)
    _ => None
  }
}

///|
pub const SLAB_MAGIC : String = "SLAB"

///|
pub const SLAB_VERSION : Int = 2

///|
pub const SLAB_INDEX_MAGIC : String = "SLIX"

///|
pub const SLAB_HEADER_LEN : Int = 14

///|
pub const SLAB_TRAILER_LEN : Int = 16

///|
#derive(Debug, Eq)
pub(all) enum SlabComponent {
  Id
  Text
  Category
  Ts
  Public
  Vector
  FtsDir
  FtsPostings
  FtsDocLen
  FtsBlockMax
  BlockStats
  Meta
  Custom(String)
}

///|
pub fn SlabComponent::to_name(self : SlabComponent) -> String {
  match self {
    Id => "id"
    Text => "text"
    Category => "category"
    Ts => "ts"
    Public => "public"
    Vector => "vector"
    FtsDir => "fts/dir"
    FtsPostings => "fts/postings"
    FtsDocLen => "fts/doc_len"
    FtsBlockMax => "fts/blockmax"
    BlockStats => "rows/blockstats"
    Meta => "meta"
    Custom(s) => s
  }
}

///|
pub fn SlabComponent::from_name(name : String) -> SlabComponent {
  match name {
    "id" | "rows/id.bin" | "col:id" => Id
    "text" | "rows/text.bin" | "col:text" => Text
    "category" | "rows/category.bin" | "col:category" => Category
    "ts" | "rows/ts.bin" | "col:ts" => Ts
    "public" | "rows/public.bin" | "col:public" => Public
    "vector" | "rows/vector.bin" | "col:vector" => Vector
    "fts/dir" | "fts/dir.bin" | "fts:dir" => FtsDir
    "fts/postings" | "fts/postings.bin" | "fts:postings" => FtsPostings
    "fts/doc_len" | "fts/doc_len.bin" | "fts:doc_len" => FtsDocLen
    "fts/blockmax" | "fts/blockmax.bin" | "fts:blockmax" => FtsBlockMax
    "rows/blockstats" | "rows/blockstats.bin" | "blockstats" => BlockStats
    "meta" | "meta.json" => Meta
    _ => Custom(name)
  }
}

///|
#derive(Debug, Eq)
pub(all) struct SlabEntry {
  name : String
  offset : Int64
  length : Int64
  row_count : Int
}

///|
#derive(Debug, Eq)
pub(all) struct SlabIndex {
  entries : Array[SlabEntry]
}

///|
pub fn SlabIndex::new() -> SlabIndex {
  { entries: Array() }
}

///|
fn normalize_slab_comp_name(name : String) -> String {
  match name {
    "id" | "rows/id.bin" | "col:id" => "id"
    "text" | "rows/text.bin" | "col:text" => "text"
    "category" | "rows/category.bin" | "col:category" => "category"
    "ts" | "rows/ts.bin" | "col:ts" => "ts"
    "public" | "rows/public.bin" | "col:public" => "public"
    "vector" | "rows/vector.bin" | "col:vector" => "vector"
    "fts/dir" | "fts/dir.bin" | "fts:dir" => "fts/dir"
    "fts/postings" | "fts/postings.bin" | "fts:postings" => "fts/postings"
    "fts/doc_len" | "fts/doc_len.bin" | "fts:doc_len" => "fts/doc_len"
    "fts/blockmax" | "fts/blockmax.bin" | "fts:blockmax" => "fts/blockmax"
    "rows/blockstats" | "rows/blockstats.bin" | "blockstats" => "rows/blockstats"
    "meta" | "meta.json" => "meta"
    _ => name
  }
}

///|
pub fn SlabIndex::get(self : SlabIndex, name : String) -> SlabEntry? {
  for e in self.entries {
    if e.name == name {
      return Some(e)
    }
  }
  let norm = normalize_slab_comp_name(name)
  for e in self.entries {
    if normalize_slab_comp_name(e.name) == norm {
      return Some(e)
    }
  }
  None
}

///|
pub fn SlabIndex::get_component(self : SlabIndex, comp : SlabComponent) -> SlabEntry? {
  self.get(comp.to_name())
}

///|
pub fn SlabIndex::has(self : SlabIndex, name : String) -> Bool {
  match self.get(name) {
    Some(_) => true
    None => false
  }
}

///|
pub fn SlabIndex::get_slice(self : SlabIndex, bs : Bytes, name : String) -> Bytes? {
  match self.get(name) {
    Some(e) => {
      let off = e.offset.to_int()
      let len = e.length.to_int()
      if off >= 0 && len >= 0 && off + len <= bs.length() {
        let b = Buffer()
        for i in 0..<len {
          b.write_byte(bs[off + i])
        }
        Some(b.to_bytes())
      } else {
        None
      }
    }
    None => None
  }
}

///|
#derive(Debug)
pub(all) struct SlabComponentPayload {
  name : String
  data : Bytes
  row_count : Int
}

///|
pub fn SlabComponentPayload::new(
  name : String,
  data : Bytes,
  row_count : Int,
) -> SlabComponentPayload {
  { name, data, row_count }
}

///|
pub fn encode_slab_header(version : Int, index_offset : Int64) -> Bytes {
  let b = Buffer()
  b.write_string_utf8(SLAB_MAGIC)
  b.write_uint16_le(version.to_uint16())
  b.write_int64_le(index_offset)
  b.to_bytes()
}

///|
pub fn decode_slab_header(bs : Bytes) -> (Int, Int64) raise @core.SpndError {
  if bs.length() < SLAB_HEADER_LEN {
    raise @core.Truncated("slab header too short: \{bs.length()}")
  }
  if bs[0] != b'S' || bs[1] != b'L' || bs[2] != b'A' || bs[3] != b'B' {
    raise @core.Corrupt("invalid slab header magic")
  }
  let fa = bs.to_fixedarray()
  let version = fa_u16(fa, 4)
  let index_offset = fa_i64(fa, 6)
  (version, index_offset)
}

///|
pub fn encode_slab_index(index : SlabIndex) -> Bytes {
  let b = Buffer()
  b.write_string_utf8(SLAB_INDEX_MAGIC)
  b.write_uint_le(index.entries.length().reinterpret_as_uint())
  for e in index.entries {
    let name_bs = @utf8.encode(e.name)
    b.write_uint16_le(name_bs.length().to_uint16())
    b.write_bytes(name_bs)
    b.write_int64_le(e.offset)
    b.write_int64_le(e.length)
    b.write_uint_le(e.row_count.reinterpret_as_uint())
  }
  b.to_bytes()
}

///|
/// 增量解码 SlabIndex：解出 [index_offset, ...) 处能完整解析的条目，返回
/// （已解条目, 条目总数, 已消费末位, 是否完整）。仅缺字节（截断）时返回
/// complete=false；magic/计数损坏仍 raise Corrupt。index 超出预读窗口时
/// 读侧按断点续拉剩余 index 字节（不拉数据区），完整后直接用已解条目。
pub fn scan_slab_index(
  bs : Bytes,
  index_offset : Int,
) -> (SlabIndex, Int, Int, Bool) raise @core.SpndError {
  if index_offset < 0 || index_offset + 8 > bs.length() {
    return ({ entries: Array() }, 0, index_offset, false)
  }
  if bs[index_offset] != b'S' ||
    bs[index_offset + 1] != b'L' ||
    bs[index_offset + 2] != b'I' ||
    bs[index_offset + 3] != b'X' {
    raise @core.Corrupt("invalid slab index magic")
  }
  let fa = bs.to_fixedarray()
  let count = fa_i32(fa, index_offset + 4)
  if count < 0 {
    raise @core.Corrupt("invalid slab index entry count \{count}")
  }
  let mut pos = index_offset + 8
  let entries : Array[SlabEntry] = Array(capacity=count)
  for _ in 0..<count {
    if pos + 2 > bs.length() {
      return ({ entries }, count, pos, false)
    }
    let nlen = fa_u16(fa, pos)
    if pos + nlen + 22 > bs.length() {
      return ({ entries }, count, pos, false)
    }
    let name_buf = Buffer()
    for j in 0..<nlen {
      name_buf.write_byte(bs[pos + 2 + j])
    }
    let name = @utf8.decode(name_buf.to_bytes().exact_view()) catch {
      _ => raise @core.Corrupt("slab entry name is not valid utf8")
    }
    pos += nlen + 2
    let offset = fa_i64(fa, pos)
    pos += 8
    let length = fa_i64(fa, pos)
    pos += 8
    let row_count = fa_i32(fa, pos)
    pos += 4
    entries.push({ name, offset, length, row_count })
  }
  ({ entries }, count, pos, true)
}

///|
pub fn decode_slab_index(
  bs : Bytes,
  index_offset : Int,
) -> SlabIndex raise @core.SpndError {
  if index_offset < 0 || index_offset + 8 > bs.length() {
    raise @core.Truncated("slab index out of bounds at \{index_offset}")
  }
  let (index, _count, _pos, done) = scan_slab_index(bs, index_offset)
  if !done {
    raise @core.Truncated("slab index entry payload at \{index_offset}")
  }
  index
}

///|
pub fn decode_slab_trailer(bs : Bytes) -> (Int64, Int) raise @core.SpndError {
  let len = bs.length()
  if len < SLAB_TRAILER_LEN {
    raise @core.Truncated("slab trailer too short: \{len}")
  }
  let t_off = len - SLAB_TRAILER_LEN
  if bs[t_off + 12] != b'S' ||
    bs[t_off + 13] != b'L' ||
    bs[t_off + 14] != b'A' ||
    bs[t_off + 15] != b'B' {
    raise @core.Corrupt("invalid slab trailer magic")
  }
  let fa = bs.to_fixedarray()
  let index_offset = fa_i64(fa, t_off)
  let index_len = fa_i32(fa, t_off + 8)
  if index_offset < 0L || index_len < 0 {
    raise @core.Corrupt("invalid slab trailer offset/length")
  }
  (index_offset, index_len)
}

///|
/// 解码从文件头部（偏移 0）拉取的 Header + Index 字节。
/// 当 Index 位于固定偏移 14 时，1 次 Range GET 即可完成全部索引解码。
pub fn decode_slab_index_from_header_bytes(
  bs : Bytes,
) -> (Int, SlabIndex) raise @core.SpndError {
  let (version, index_offset) = decode_slab_header(bs)
  let off = index_offset.to_int()
  if off < 0 || off >= bs.length() {
    raise @core.Truncated(
      "slab index offset \{off} exceeds provided header bytes \{bs.length()}",
    )
  }
  let index = decode_slab_index(bs, off)
  (version, index)
}

///|
/// 解码从文件末尾拉取的 Trailer + Index 字节。
/// 当 Index 位于文件末尾时，结合 SegmentMeta 的 size_bytes，
/// 1 次 Range GET（拉取末尾 tail_len 字节）即可完成全部索引解码。
pub fn decode_slab_index_from_tail_bytes(
  bs : Bytes,
  total_size : Int,
) -> SlabIndex raise @core.SpndError {
  let (index_offset, index_len) = decode_slab_trailer(bs)
  let slice_start = total_size - bs.length()
  let rel_offset = index_offset.to_int() - slice_start
  if rel_offset < 0 || rel_offset + index_len > bs.length() - SLAB_TRAILER_LEN {
    raise @core.Truncated("slab index not within tail slice")
  }
  decode_slab_index(bs, rel_offset)
}

///|
/// 解析完整 slab 文件内容，返回 (version, SlabIndex)。
pub fn decode_slab_file(bs : Bytes) -> (Int, SlabIndex) raise @core.SpndError {
  let (version, index_offset) = decode_slab_header(bs)
  let index = decode_slab_index(bs, index_offset.to_int())
  (version, index)
}

///|
/// 打包各组件为 SlabV2 单文件。
/// - index_at_end = true：连续数据块位于头部之后，Index 与 Trailer 位于文件末尾。
/// - index_at_end = false：Index 位于 Header (14B) 之后的固定偏移，连续数据块紧随其后。
pub fn encode_slab(
  components : Array[SlabComponentPayload],
  index_at_end~ : Bool = true,
) -> (Bytes, SlabIndex) {
  if index_at_end {
    let mut cur_offset = SLAB_HEADER_LEN
    let entries : Array[SlabEntry] = Array(capacity=components.length())
    for c in components {
      let offset = cur_offset.to_int64()
      let length = c.data.length().to_int64()
      entries.push({ name: c.name, offset, length, row_count: c.row_count })
      cur_offset += c.data.length()
    }
    let index : SlabIndex = { entries, }
    let index_offset = cur_offset.to_int64()
    let index_bytes = encode_slab_index(index)
    
    let b = Buffer()
    // Header (14B)
    b.write_string_utf8(SLAB_MAGIC)
    b.write_uint16_le(SLAB_VERSION.to_uint16())
    b.write_int64_le(index_offset)
    // Contiguous Data blocks
    for c in components {
      b.write_bytes(c.data)
    }
    // Index block
    b.write_bytes(index_bytes)
    // Trailer (16B)
    b.write_int64_le(index_offset)
    b.write_uint_le(index_bytes.length().reinterpret_as_uint())
    b.write_string_utf8(SLAB_MAGIC)
    (b.to_bytes(), index)
  } else {
    // 固定偏移 14 放置 Index
    let mut index_len = 8
    for c in components {
      let name_bs = @utf8.encode(c.name)
      index_len += 2 + name_bs.length() + 8 + 8 + 4
    }
    let mut cur_offset = SLAB_HEADER_LEN + index_len
    let entries : Array[SlabEntry] = Array(capacity=components.length())
    for c in components {
      let offset = cur_offset.to_int64()
      let length = c.data.length().to_int64()
      entries.push({ name: c.name, offset, length, row_count: c.row_count })
      cur_offset += c.data.length()
    }
    let index : SlabIndex = { entries, }
    let index_bytes = encode_slab_index(index)
    
    let b = Buffer()
    // Header (14B)
    b.write_string_utf8(SLAB_MAGIC)
    b.write_uint16_le(SLAB_VERSION.to_uint16())
    b.write_int64_le(SLAB_HEADER_LEN.to_int64())
    // Index block at offset 14
    b.write_bytes(index_bytes)
    // Contiguous Data blocks
    for c in components {
      b.write_bytes(c.data)
    }
    (b.to_bytes(), index)
  }
}

pub extend SegmentFormat with Debug::{to_repr}
pub extend SegmentFormat with Eq::{not_equal, equal}
pub extend SlabComponent with Debug::{to_repr}
pub extend SlabComponent with Eq::{not_equal, equal}
pub extend SlabEntry with Debug::{to_repr}
pub extend SlabEntry with Eq::{not_equal, equal}
pub extend SlabIndex with Debug::{to_repr}
pub extend SlabIndex with Eq::{not_equal, equal}
pub extend SlabComponentPayload with Debug::{to_repr}
