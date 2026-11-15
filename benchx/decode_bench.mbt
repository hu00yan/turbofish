// format decode 批量化的 micro-bench。
//
// 构造典型列/分区/倒排对象，跑 decode 20 轮取 p50（µs/次）。数据在计时区外
// 生成；每轮结果累加进校验和防止死代码消除。

///|
const DEC_N : Int = 20000

///|
const DEC_VEC_ROWS : Int = 200

///|
const DEC_DIM : Int = 768

///|
const DEC_TERMS : Int = 5000

///|
fn dec_data() -> (Bytes, Bytes, Bytes, Bytes, Bytes, Bytes, Bytes) {
  let ids : Array[UInt64] = Array::new(capacity=DEC_N)
  let strs : Array[String] = Array::new(capacity=DEC_N)
  let bools : Array[Bool] = Array::new(capacity=DEC_N)
  let vec : Array[Float] = Array::new(capacity=DEC_VEC_ROWS * DEC_DIM)
  let part_data : Array[Float] = Array::new(capacity=DEC_VEC_ROWS * DEC_DIM)
  let rows : Array[Int] = Array::new(capacity=DEC_VEC_ROWS)
  for i in 0..<DEC_N {
    ids.push((i + 1).to_uint64())
    strs.push("cat\{i % 100}")
    bools.push(i % 3 != 0)
  }
  let rng = @core.Rng::new(99U)
  for i in 0..<DEC_VEC_ROWS {
    rows.push(i)
    for _ in 0..<DEC_DIM {
      vec.push(Float::from_double(rng.next_range(-1.0, 1.0)))
      part_data.push(Float::from_double(rng.next_range(-1.0, 1.0)))
    }
  }
  let col_u64 = @format.encode_col(@format.ColU64(ids))
  let col_str = @format.encode_col(@format.ColStr(strs))
  let col_bool = @format.encode_col(@format.ColBool(bools))
  let col_vec = @format.encode_vec_col(DEC_DIM, vec, true)
  let part = @format.encode_part(
    { cid: 0, rows, dim: DEC_DIM, data: part_data },
    true,
  )
  let lists : Array[(String, Array[@format.Posting])] = Array::new(
    capacity=DEC_TERMS + 1,
  )
  let big : Array[@format.Posting] = Array::new(capacity=DEC_N)
  for i in 0..<DEC_N {
    big.push({ row: i, tf: 1 + i % 5 })
  }
  lists.push(("big", big))
  for i in 0..<DEC_TERMS {
    lists.push(("term\{i}", [{ row: i % DEC_VEC_ROWS, tf: 1 + i % 5 }]))
  }
  let built = @format.encode_fts(lists)
  (col_u64, col_str, col_bool, col_vec, part, built.dir, built.postings)
}

///|
/// 跑 decode micro-bench，返回汇总文本。
pub fn run_decode_bench() -> String raise @core.SpndError {
  let (col_u64, col_str, col_bool, col_vec, part, dir, postings) = dec_data()
  let dir_dec = @format.decode_fts_dir(dir)
  // "big" 排序在 "term..." 之前（b < t）
  let entry0 = dir_dec[0]
  let lines : Array[String] = Array::new()
  lines.push("")
  lines.push(
    "[3] format decode micro-bench（20000 列值 / 200×768 向量 / 5000 term dir）",
  )
  let (p_ids, ck_ids) = bench_p50(WARMUP, ROUNDS, 1, fn() raise @core.SpndError {
    match @format.decode_col(col_u64) {
      @format.ColU64(a) => a[0].to_double() + a[a.length() - 1].to_double()
      _ => 0.0
    }
  })
  lines.push(
    "  decode_col u64        : \{fmt_fixed(p_ids, 2)} µs   checksum=\{fmt_fixed(ck_ids, 0)}",
  )
  let (p_str, ck_str) = bench_p50(WARMUP, ROUNDS, 1, fn() raise @core.SpndError {
    match @format.decode_col(col_str) {
      @format.ColStr(a) => {
        let mut s = 0
        for x in a {
          s += x.length()
        }
        s.to_double()
      }
      _ => 0.0
    }
  })
  lines.push(
    "  decode_col str(dict)  : \{fmt_fixed(p_str, 2)} µs   checksum=\{fmt_fixed(ck_str, 0)}",
  )
  let (p_bool, ck_bool) = bench_p50(WARMUP, ROUNDS, 1, fn() raise @core.SpndError {
    match @format.decode_col(col_bool) {
      @format.ColBool(a) => {
        let mut c = 0
        for x in a {
          if x {
            c += 1
          }
        }
        c.to_double()
      }
      _ => 0.0
    }
  })
  lines.push(
    "  decode_col bool(bitmap): \{fmt_fixed(p_bool, 2)} µs   checksum=\{fmt_fixed(ck_bool, 0)}",
  )
  let (p_vec, ck_vec) = bench_p50(WARMUP, ROUNDS, 1, fn() raise @core.SpndError {
    let (_, d) = @format.decode_vec_col(col_vec)
    d[0].abs().to_double() + d[d.length() - 1].abs().to_double()
  })
  lines.push(
    "  decode_vec_col f16    : \{fmt_fixed(p_vec, 2)} µs   checksum=\{fmt_fixed(ck_vec, 3)}",
  )
  let (p_part, ck_part) = bench_p50(WARMUP, ROUNDS, 1, fn() raise @core.SpndError {
    let p = @format.decode_part(part)
    p.data[0].abs().to_double() + p.data[p.data.length() - 1].abs().to_double()
  })
  lines.push(
    "  decode_part f16       : \{fmt_fixed(p_part, 2)} µs   checksum=\{fmt_fixed(ck_part, 3)}",
  )
  let (p_dir, ck_dir) = bench_p50(WARMUP, ROUNDS, 1, fn() raise @core.SpndError {
    let d = @format.decode_fts_dir(dir)
    d.length().to_double()
  })
  lines.push(
    "  decode_fts_dir        : \{fmt_fixed(p_dir, 2)} µs   checksum=\{fmt_fixed(ck_dir, 0)}",
  )
  let (p_post, ck_post) = bench_p50(WARMUP, ROUNDS, 1, fn() raise @core.SpndError {
    let ps = @format.read_postings(postings, entry0)
    ps.length().to_double()
  })
  lines.push(
    "  read_postings(20k post): \{fmt_fixed(p_post, 2)} µs   checksum=\{fmt_fixed(ck_post, 0)}",
  )
  let mut out = ""
  for i in 0..<lines.length() {
    if i > 0 {
      out = out + "\n"
    }
    out = out + lines[i]
  }
  out
}
