// 列文件编解码。
//
// SPNDCOL1（定长/字符串/布尔列），20B 头：
//   [0..8)   magic "SPNDCOL1"
//   [8]      dtype: 1=u64 2=u32 3=i64 4=f32 5=string 6=bool
//   [9]      flags: bit0=字典编码字符串列 bit1=位图布尔列（其余保留，写 0）
//   [10..14) count u32 LE
//   [14..18) extra u32 LE（普通 string: data 字节数；字典 string: dict_data 字节数；其余 0）
//   [18..20) 保留 u16
// 定长 payload：count × item_size
// string payload（flags bit0=0，旧格式）：(count+1) × u32 offsets + UTF-8 data 紧凑拼接
// string payload（flags bit0=1，字典编码）：
//   dict_count u32 + dict_offsets u32×(dict_count+1) + dict_data（extra 字节）
//   + codes u16×count（code ∈ [0, dict_count)，字典按首次出现顺序）
// bool payload（flags bit1=0，旧格式）：count × 1B（0/1）
// bool payload（flags bit1=1，位图）：ceil(count/8) 字节，行 i = 字节 i/8 的 bit(i%8)（小端位序）
// 解码对两种 flags 都兼容；encode_col 新写文件字符串一律走字典（distinct > 65535
// 自动回退普通串列）、bool 一律走位图。
//
// SPNDVEC1（向量列），16B 头：
//   [0..8)   magic "SPNDVEC1"
//   [8]      dtype: 4=f32 7=f16 8=sq8（payload 见 quant.mbt）
//   [9..11)  dim u16 LE
//   [11..15) count u32 LE
//   [15..16) 保留
// payload：f32/f16 = count × dim × item_size 行主序。解码一律展开为 f32 数组。

///|
pub const COL_MAGIC : String = "SPNDCOL1"

///|
pub const VEC_MAGIC : String = "SPNDVEC1"

///|
pub const DT_U64 : Int = 1

///|
pub const DT_U32 : Int = 2

///|
pub const DT_I64 : Int = 3

///|
pub const DT_F32 : Int = 4

///|
pub const DT_STR : Int = 5

///|
pub const DT_BOOL : Int = 6

///|
pub const DT_F16 : Int = 7

///|
/// SQ8 量化向量（SPNDVEC1/SPNDPRT1），payload 布局见 quant.mbt。
pub const DT_SQ8 : Int = 8

///|
/// SPNDCOL1 flags bit0：字符串列字典编码。
pub const COL_FLAG_DICT : Int = 1

///|
/// SPNDCOL1 flags bit1：布尔列位图。
pub const COL_FLAG_BITMAP : Int = 2

///|
#derive(Debug)
pub(all) enum ColData {
  ColU64(Array[UInt64])
  ColU32(Array[Int])
  ColI64(Array[Int64])
  ColF32(Array[Float])
  ColStr(Array[String])
  ColBool(Array[Bool])
  ColVec(Int, Array[Float])
}

///|
fn write_col_header(
  b : Buffer,
  dtype : Int,
  flags : Int,
  count : Int,
  extra : Int,
) -> Unit {
  b.write_string_utf8(COL_MAGIC)
  b.write_byte(dtype.to_byte())
  b.write_byte(flags.to_byte())
  b.write_uint_le(count.reinterpret_as_uint())
  b.write_uint_le(extra.reinterpret_as_uint())
  b.write_uint16_le((0).to_uint16())
}

///|
/// 字典编码字符串列的回退阈值：distinct 超过它（codes u16 放不下）时
/// encode_col 自动回退普通字符串列（flags=0）。
const DICT_MAX_UNIQUE : Int = 65535

///|
/// 字符串列字典编码（flags bit0=1）。distinct > DICT_MAX_UNIQUE 时返回 None，
/// 调用方回退普通字符串列。extra = dict_data 字节数。
fn encode_col_str_dict(arr : Array[String]) -> Bytes? {
  let count = arr.length()
  let dict_idx : Map[String, Int] = Map([])
  let dict : Array[String] = Array()
  let codes : Array[UInt16] = Array(capacity=count)
  for s in arr {
    match dict_idx.get(s) {
      Some(ix) => codes.push(ix.to_uint16())
      None => {
        if dict.length() >= DICT_MAX_UNIQUE {
          return None
        }
        let ix = dict.length()
        dict.push(s)
        dict_idx.set(s, ix)
        codes.push(ix.to_uint16())
      }
    }
  }
  let data = Buffer()
  let offs = Buffer()
  let mut total = 0
  for s in dict {
    offs.write_uint_le(total.reinterpret_as_uint())
    let e = @utf8.encode(s)
    data.write_bytes(e.exact_view())
    total += e.length()
  }
  offs.write_uint_le(total.reinterpret_as_uint())
  let b = Buffer()
  write_col_header(b, DT_STR, COL_FLAG_DICT, count, total)
  b.write_uint_le(dict.length().reinterpret_as_uint())
  b.write_bytes(offs.to_bytes().exact_view())
  b.write_bytes(data.to_bytes().exact_view())
  for c in codes {
    b.write_uint16_le(c)
  }
  Some(b.to_bytes())
}

///|
/// 普通（非字典）字符串列编码（flags=0）：(count+1) offsets + UTF-8 data。
/// `use_dict_cols=false` 的默认路径用这个。
pub fn encode_col_str_plain(arr : Array[String]) -> Bytes {
  let datas = Buffer()
  let offs = Buffer()
  let mut total = 0
  for s in arr {
    offs.write_uint_le(total.reinterpret_as_uint())
    let e = @utf8.encode(s)
    datas.write_bytes(e.exact_view())
    total += e.length()
  }
  offs.write_uint_le(total.reinterpret_as_uint())
  let b = Buffer()
  write_col_header(b, DT_STR, 0, arr.length(), total)
  b.write_bytes(offs.to_bytes().exact_view())
  b.write_bytes(datas.to_bytes().exact_view())
  b.to_bytes()
}

///|
/// 旧格式布尔列编码（每值 1B，flags=0）。
/// `use_bool_bitmap=false` 的默认路径用这个。
pub fn encode_col_bool_plain(arr : Array[Bool]) -> Bytes {
  let b = Buffer()
  write_col_header(b, DT_BOOL, 0, arr.length(), 0)
  for v in arr {
    b.write_byte(if v { b'\x01' } else { b'\x00' })
  }
  b.to_bytes()
}

///|
/// 列文件是否为字典编码字符串列（用于 query 侧按 code 比对过滤）。
pub fn is_dict_col(bs : Bytes) -> Bool {
  match (bs.get(8), bs.get(9)) {
    (Some(d), Some(f)) =>
      d.to_int() == DT_STR && (f.to_int() & COL_FLAG_DICT) != 0
    _ => false
  }
}

///|
/// 列文件是否为位图布尔列（用于 query 侧直接查位过滤）。
pub fn is_bitmap_bool(bs : Bytes) -> Bool {
  match (bs.get(8), bs.get(9)) {
    (Some(d), Some(f)) =>
      d.to_int() == DT_BOOL && (f.to_int() & COL_FLAG_BITMAP) != 0
    _ => false
  }
}

///|
pub fn encode_col(cd : ColData) -> Bytes {
  let b = Buffer()
  match cd {
    ColU64(arr) => {
      write_col_header(b, DT_U64, 0, arr.length(), 0)
      for v in arr {
        b.write_uint64_le(v)
      }
    }
    ColU32(arr) => {
      write_col_header(b, DT_U32, 0, arr.length(), 0)
      for v in arr {
        b.write_uint_le(v.reinterpret_as_uint())
      }
    }
    ColI64(arr) => {
      write_col_header(b, DT_I64, 0, arr.length(), 0)
      for v in arr {
        b.write_int64_le(v)
      }
    }
    ColF32(arr) => {
      write_col_header(b, DT_F32, 0, arr.length(), 0)
      for v in arr {
        b.write_float_le(v)
      }
    }
    ColStr(arr) =>
      // 新文件默认字典编码；distinct > 65535（u16 code 放不下）自动回退普通串列
      match encode_col_str_dict(arr) {
        Some(bs) => b.write_bytes(bs.exact_view())
        None => b.write_bytes(encode_col_str_plain(arr).exact_view())
      }
    ColBool(arr) => {
      // 新文件一律位图：ceil(count/8) 字节，行 i = 字节 i/8 的 bit(i%8)
      let count = arr.length()
      write_col_header(b, DT_BOOL, COL_FLAG_BITMAP, count, 0)
      let nbytes = (count + 7) / 8
      for bi in 0..<nbytes {
        let mut byte = 0
        let base = bi * 8
        let mut j = 0
        while j < 8 && base + j < count {
          if arr[base + j] {
            byte = byte | (1 << j)
          }
          j += 1
        }
        b.write_byte(byte.to_byte())
      }
    }
    ColVec(dim, data) => encode_vec_into(b, dim, data, false)
  }
  b.to_bytes()
}

///|
/// 向量列编码，可选 f16 量化存储（解码统一回 f32）。
pub fn encode_vec_into(
  b : Buffer,
  dim : Int,
  data : Array[Float],
  use_f16 : Bool,
) -> Unit {
  let count = if dim > 0 { data.length() / dim } else { 0 }
  b.write_string_utf8(VEC_MAGIC)
  b.write_byte(if use_f16 { DT_F16.to_byte() } else { DT_F32.to_byte() })
  b.write_uint16_le(dim.to_uint16())
  b.write_uint_le(count.reinterpret_as_uint())
  b.write_byte(b'\x00')
  if use_f16 {
    for v in data {
      b.write_uint16_le(@core.f32_to_f16_bits(v))
    }
  } else {
    for v in data {
      b.write_float_le(v)
    }
  }
}

///|
pub fn encode_vec_col(dim : Int, data : Array[Float], use_f16 : Bool) -> Bytes {
  let b = Buffer()
  encode_vec_into(b, dim, data, use_f16)
  b.to_bytes()
}

///|
pub fn decode_col(bs : Bytes) -> ColData raise @core.SpndError {
  @core.check_magic(bs, COL_MAGIC)
  let fa = bs.to_fixedarray()
  let dtype8 = match bs.get(8) {
    Some(x) => x.to_int()
    None => raise @core.Truncated("col header")
  }
  let flags8 = match bs.get(9) {
    Some(x) => x.to_int()
    None => raise @core.Truncated("col header")
  }
  let count = fa_i32(fa, 10)
  let extra = fa_i32(fa, 14)
  if count < 0 || extra < 0 {
    raise @core.Corrupt("col header")
  }
  match dtype8 {
    d if d == DT_U64 => {
      if 20 + count * 8 > bs.length() {
        raise @core.Truncated("u64 col payload")
      }
      let arr : Array[UInt64] = Array(capacity=count)
      for i in 0..<count {
        arr.push(fa_u64(fa, 20 + i * 8))
      }
      ColU64(arr)
    }
    d if d == DT_U32 => {
      if 20 + count * 4 > bs.length() {
        raise @core.Truncated("u32 col payload")
      }
      let arr : Array[Int] = Array(capacity=count)
      for i in 0..<count {
        arr.push(fa_i32(fa, 20 + i * 4))
      }
      ColU32(arr)
    }
    d if d == DT_I64 => {
      if 20 + count * 8 > bs.length() {
        raise @core.Truncated("i64 col payload")
      }
      let arr : Array[Int64] = Array(capacity=count)
      for i in 0..<count {
        arr.push(fa_i64(fa, 20 + i * 8))
      }
      ColI64(arr)
    }
    d if d == DT_F32 => {
      if 20 + count * 4 > bs.length() {
        raise @core.Truncated("f32 col payload")
      }
      let arr : Array[Float] = Array(capacity=count)
      for i in 0..<count {
        arr.push(fa_f32(fa, 20 + i * 4))
      }
      ColF32(arr)
    }
    d if d == DT_STR =>
      if (flags8 & COL_FLAG_DICT) != 0 {
        // 字典列：读 dict + codes 后展开为 ColStr（下游零改动）
        let (dict, codes) = decode_col_dict_payload(bs, count, extra)
        let arr : Array[String] = Array(capacity=count)
        for c in codes {
          let ix = c.to_int()
          if ix >= dict.length() {
            raise @core.Corrupt("dict code out of range")
          }
          arr.push(dict[ix])
        }
        ColStr(arr)
      } else {
        if 20 + (count + 1) * 4 > bs.length() {
          raise @core.Truncated("string offsets")
        }
        let arr : Array[String] = Array(capacity=count)
        let offs_pos = 20
        let data_pos = offs_pos + (count + 1) * 4
        let mut prev = fa_i32(fa, offs_pos)
        for i in 0..<count {
          let cur = fa_i32(fa, offs_pos + (i + 1) * 4)
          if cur < prev || data_pos + cur > bs.length() {
            raise @core.Corrupt("string offsets")
          }
          arr.push(
            @utf8.decode(bs.exact_view(start=data_pos + prev, end=data_pos + cur)) catch {
              _ => raise @core.Corrupt("invalid utf8 in string column")
            },
          )
          prev = cur
        }
        let _ = extra
        ColStr(arr)
      }
    d if d == DT_BOOL => {
      let arr : Array[Bool] = Array(capacity=count)
      if (flags8 & COL_FLAG_BITMAP) != 0 {
        if 20 + (count + 7) / 8 > bs.length() {
          raise @core.Truncated("bool bitmap col")
        }
        for i in 0..<count {
          let byte = fa[20 + i / 8].to_int()
          arr.push(((byte >> (i % 8)) & 1) != 0)
        }
      } else {
        if 20 + count > bs.length() {
          raise @core.Truncated("bool col")
        }
        for i in 0..<count {
          arr.push(fa[20 + i].to_int() != 0)
        }
      }
      ColBool(arr)
    }
    other => raise @core.Corrupt("unknown column dtype \{other}")
  }
}

///|
/// 解码字典编码字符串列（flags bit0=1），返回（字典, 每行 code）。
/// 非 DT_STR 或非字典列（flags bit0=0）抛 Corrupt。
pub fn decode_col_dict(
  bs : Bytes,
) -> (Array[String], Array[UInt16]) raise @core.SpndError {
  @core.check_magic(bs, COL_MAGIC)
  let dtype8 = match bs.get(8) {
    Some(x) => x.to_int()
    None => raise @core.Truncated("col header")
  }
  if dtype8 != DT_STR {
    raise @core.Corrupt("dict col requires dtype=str, got \{dtype8}")
  }
  let flags8 = match bs.get(9) {
    Some(x) => x.to_int()
    None => raise @core.Truncated("col header")
  }
  if (flags8 & COL_FLAG_DICT) == 0 {
    raise @core.Corrupt("not a dict-encoded string column")
  }
  let count = fa_i32(bs.to_fixedarray(), 10)
  let extra = fa_i32(bs.to_fixedarray(), 14)
  decode_col_dict_payload(bs, count, extra)
}

///|
/// 字典 payload 读取（20B 头之后）：
///   dict_count u32 + dict_offsets u32×(dict_count+1) + dict_data（extra 字节）
///   + codes u16×count
fn decode_col_dict_payload(
  bs : Bytes,
  count : Int,
  extra : Int,
) -> (Array[String], Array[UInt16]) raise @core.SpndError {
  if count < 0 || extra < 0 {
    raise @core.Corrupt("dict col header")
  }
  let fa = bs.to_fixedarray()
  let dict_count = fa_i32(fa, 20)
  if dict_count < 0 {
    raise @core.Corrupt("dict count")
  }
  let offs_pos = 24
  let data_pos = offs_pos + (dict_count + 1) * 4
  let codes_pos = data_pos + extra
  if data_pos > bs.length() ||
    codes_pos > bs.length() ||
    codes_pos + count * 2 > bs.length() {
    raise @core.Corrupt("dict payload size")
  }
  let dict : Array[String] = Array(capacity=dict_count)
  for i in 0..<dict_count {
    let start = fa_i32(fa, offs_pos + i * 4)
    let end = fa_i32(fa, offs_pos + (i + 1) * 4)
    if end < start || data_pos + end > bs.length() {
      raise @core.Corrupt("dict offsets")
    }
    dict.push(
      @utf8.decode(bs.exact_view(start=data_pos + start, end=data_pos + end)) catch {
        _ => raise @core.Corrupt("invalid utf8 in dict data")
      },
    )
  }
  let codes : Array[UInt16] = Array(capacity=count)
  for i in 0..<count {
    codes.push(fa_u16(fa, codes_pos + i * 2).to_uint16())
  }
  (dict, codes)
}

///|
/// 解码向量列（SPNDVEC1），f16/sq8 存储自动展开为 f32。
pub fn decode_vec_col(bs : Bytes) -> (Int, Array[Float]) raise @core.SpndError {
  @core.check_magic(bs, VEC_MAGIC)
  let fa = bs.to_fixedarray()
  let dtype8 = match bs.get(8) {
    Some(x) => x.to_int()
    None => raise @core.Truncated("vec header")
  }
  let dim = fa_u16(fa, 9)
  let count = fa_i32(fa, 11)
  if count < 0 || dim < 0 {
    raise @core.Corrupt("vec header")
  }
  let n = count * dim
  let data : Array[Float] = Array(capacity=n)
  if dtype8 == DT_SQ8 {
    let scales_pos = 16 + dim * 4
    let codes_pos = scales_pos + dim * 4
    if codes_pos + n > bs.length() {
      raise @core.Truncated("sq8 vec payload")
    }
    let mins : Array[Float] = Array(capacity=dim)
    for d in 0..<dim {
      mins.push(fa_f32(fa, 16 + d * 4))
    }
    let scales : Array[Float] = Array(capacity=dim)
    for d in 0..<dim {
      scales.push(fa_f32(fa, scales_pos + d * 4))
    }
    for i in 0..<n {
      let d = i % dim
      let inv = scales[d]
      let code = Float::from_int(fa[codes_pos + i].to_int())
      data.push(if inv == 0.0 { mins[d] } else { mins[d] + code / inv })
    }
  } else {
    let item = if dtype8 == DT_F16 { 2 } else { 4 }
    if 16 + n * item > bs.length() {
      raise @core.Truncated("vec payload")
    }
    for i in 0..<n {
      let pos = 16 + i * item
      if dtype8 == DT_F16 {
        data.push(@core.f16_bits_to_f32(fa_u16(fa, pos).to_uint16()))
      } else {
        data.push(fa_f32(fa, pos))
      }
    }
  }
  (dim, data)
}

///|
/// 读 SPNDVEC1 头，返回（dim, dtype, count）。用于 query 侧按块 get_range 精排。
pub fn vec_col_info(bs : Bytes) -> (Int, Int, Int) raise @core.SpndError {
  @core.check_magic(bs, VEC_MAGIC)
  let fa = bs.to_fixedarray()
  let dtype8 = match bs.get(8) {
    Some(x) => x.to_int()
    None => raise @core.Truncated("vec header")
  }
  let dim = fa_u16(fa, 9)
  let count = fa_i32(fa, 11)
  if dim < 0 || count < 0 {
    raise @core.Corrupt("vec header")
  }
  (dim, dtype8, count)
}

///|
/// 解码一段连续向量的 payload（不含 16B 头）。仅支持 f16/f32；
/// SQ8 走 decode_vec_col 的整列路径（PQ 精排的 rows/vector.bin 恒为 f16/f32）。
pub fn decode_vec_payload(
  bs : Bytes,
  dtype : Int,
  dim : Int,
  count : Int,
) -> Array[Float] raise @core.SpndError {
  let fa = bs.to_fixedarray()
  let n = count * dim
  let item = if dtype == DT_F16 {
    2
  } else if dtype == DT_F32 {
    4
  } else {
    raise @core.Corrupt("vec payload dtype \{dtype} not rerankable")
  }
  if n * item > bs.length() {
    raise @core.Truncated("vec payload")
  }
  let data : Array[Float] = Array(capacity=n)
  for i in 0..<n {
    let pos = i * item
    if dtype == DT_F16 {
      data.push(@core.f16_bits_to_f32(fa_u16(fa, pos).to_uint16()))
    } else {
      data.push(fa_f32(fa, pos))
    }
  }
  data
}

pub extend ColData with Debug::{to_repr}
