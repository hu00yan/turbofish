// 列文件编解码。
//
// SPNDCOL1（定长/字符串/布尔列），16B 头：
//   [0..8)   magic "SPNDCOL1"
//   [8]      dtype: 1=u64 2=u32 3=i64 4=f32 5=string 6=bool
//   [9]      flags 保留
//   [10..14) count u32 LE
//   [14..18) extra u32 LE（string: data 字节数；其余 0）
//   [18..20) 保留 u16
// 定长 payload：count × item_size（bool 每值 1B）
// string payload：(count+1) × u32 offsets + UTF-8 data 紧凑拼接
//
// SPNDVEC1（向量列），16B 头：
//   [0..8)   magic "SPNDVEC1"
//   [8]      dtype: 4=f32 7=f16
//   [9..11)  dim u16 LE
//   [11..15) count u32 LE
//   [15..16) 保留
// payload：count × dim × item_size，行主序。解码一律展开为 f32 数组。

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
pub(all) enum ColData {
  ColU64(Array[UInt64])
  ColU32(Array[Int])
  ColI64(Array[Int64])
  ColF32(Array[Float])
  ColStr(Array[String])
  ColBool(Array[Bool])
  ColVec(Int, Array[Float])
} derive(Debug)

///|
fn write_col_header(b : Buffer, dtype : Int, count : Int, extra : Int) -> Unit {
  b.write_string_utf8(COL_MAGIC)
  b.write_byte(dtype.to_byte())
  b.write_byte(b'\x00')
  b.write_uint_le(count.to_uint())
  b.write_uint_le(extra.to_uint())
  b.write_uint16_le((0).to_uint16())
}

///|
pub fn encode_col(cd : ColData) -> Bytes {
  let b = Buffer()
  match cd {
    ColU64(arr) => {
      write_col_header(b, DT_U64, arr.length(), 0)
      for v in arr {
        b.write_uint64_le(v)
      }
    }
    ColU32(arr) => {
      write_col_header(b, DT_U32, arr.length(), 0)
      for v in arr {
        b.write_uint_le(v.to_uint())
      }
    }
    ColI64(arr) => {
      write_col_header(b, DT_I64, arr.length(), 0)
      for v in arr {
        b.write_int64_le(v)
      }
    }
    ColF32(arr) => {
      write_col_header(b, DT_F32, arr.length(), 0)
      for v in arr {
        b.write_float_le(v)
      }
    }
    ColStr(arr) => {
      let datas = Buffer()
      let offs = Buffer()
      let mut total = 0
      for s in arr {
        offs.write_uint_le(total.to_uint())
        let e = @utf8.encode(s)
        datas.write_bytes(e.view())
        total += e.length()
      }
      offs.write_uint_le(total.to_uint())
      write_col_header(b, DT_STR, arr.length(), total)
      b.write_bytes(offs.to_bytes().view())
      b.write_bytes(datas.to_bytes().view())
    }
    ColBool(arr) => {
      write_col_header(b, DT_BOOL, arr.length(), 0)
      for v in arr {
        b.write_byte(if v { b'\x01' } else { b'\x00' })
      }
    }
    ColVec(dim, data) => encode_vec_into(b, dim, data, false)
  }
  b.to_bytes()
}

///|
/// 向量列编码，可选 f16 量化存储（解码统一回 f32）。
pub fn encode_vec_into(b : Buffer, dim : Int, data : Array[Float], use_f16 : Bool) -> Unit {
  let count = if dim > 0 { data.length() / dim } else { 0 }
  b.write_string_utf8(VEC_MAGIC)
  b.write_byte(if use_f16 { DT_F16.to_byte() } else { DT_F32.to_byte() })
  b.write_uint16_le(dim.to_uint16())
  b.write_uint_le(count.to_uint())
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
  let dtype8 = match bs.get(8) {
    Some(x) => x.to_int()
    None => raise @core.Truncated("col header")
  }
  let count = @core.read_u32_le(bs, 10).to_int()
  let extra = @core.read_u32_le(bs, 14).to_int()
  match dtype8 {
    d if d == DT_U64 => {
      let arr : Array[UInt64] = Array::new(capacity=count)
      for i in 0..<count {
        arr.push(@core.read_u64_le(bs, 20 + i * 8))
      }
      ColU64(arr)
    }
    d if d == DT_U32 => {
      let arr : Array[Int] = Array::new(capacity=count)
      for i in 0..<count {
        arr.push(@core.read_u32_le(bs, 20 + i * 4).to_int())
      }
      ColU32(arr)
    }
    d if d == DT_I64 => {
      let arr : Array[Int64] = Array::new(capacity=count)
      for i in 0..<count {
        arr.push(@core.read_i64_le(bs, 20 + i * 8))
      }
      ColI64(arr)
    }
    d if d == DT_F32 => {
      let arr : Array[Float] = Array::new(capacity=count)
      for i in 0..<count {
        arr.push(@core.read_f32_le(bs, 20 + i * 4))
      }
      ColF32(arr)
    }
    d if d == DT_STR => {
      let arr : Array[String] = Array::new(capacity=count)
      let offs_pos = 20
      let data_pos = offs_pos + (count + 1) * 4
      let mut prev = @core.read_u32_le(bs, offs_pos).to_int()
      for i in 0..<count {
        let cur = @core.read_u32_le(bs, offs_pos + (i + 1) * 4).to_int()
        arr.push(
          @utf8.decode(bs.view(start=data_pos + prev, end=data_pos + cur)) catch {
            _ => raise @core.Corrupt("invalid utf8 in string column")
          },
        )
        prev = cur
      }
      let _ = extra
      ColStr(arr)
    }
    d if d == DT_BOOL => {
      let arr : Array[Bool] = Array::new(capacity=count)
      for i in 0..<count {
        arr.push(match bs.get(20 + i) {
          Some(x) => x.to_int() != 0
          None => raise @core.Truncated("bool col")
        })
      }
      ColBool(arr)
    }
    other => raise @core.Corrupt("unknown column dtype \{other}")
  }
}

///|
/// 解码向量列（SPNDVEC1），f16 存储自动展开为 f32。
pub fn decode_vec_col(bs : Bytes) -> (Int, Array[Float]) raise @core.SpndError {
  @core.check_magic(bs, VEC_MAGIC)
  let dtype8 = match bs.get(8) {
    Some(x) => x.to_int()
    None => raise @core.Truncated("vec header")
  }
  let dim = @core.read_u16_le(bs, 9).to_int()
  let count = @core.read_u32_le(bs, 11).to_int()
  let data : Array[Float] = Array::new(capacity=count * dim)
  let item = if dtype8 == DT_F16 { 2 } else { 4 }
  for i in 0..<(count * dim) {
    let pos = 16 + i * item
    if dtype8 == DT_F16 {
      data.push(@core.f16_bits_to_f32(@core.read_u16_le(bs, pos)))
    } else {
      data.push(@core.read_f32_le(bs, pos))
    }
  }
  (dim, data)
}
