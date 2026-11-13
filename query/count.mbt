// count 聚合：对齐 turbopuffer aggregations=["Count"]。
//
// - 无 filter：num_docs - tombstone 数（零列读，只读 tombstone 对象）。
// - 带 filter：逐段 stats 预判 → 行级 matcher 全扫（匹配器走统一缓存）→
//   row→id → tombstone 排除。与检索路径同一套 stats/matcher/row_id 语义，
//   计数与 query 结果严格一致。

///|
/// 命名空间内满足 filter 的存活文档数（精确值）。
pub fn[S : @store.ObjectStore] count_docs(
  n : Namespace[S],
  filter : Filter?,
) -> Int raise @core.SpndError {
  let tomb = tombstones_of(n)
  match filter {
    None => {
      let deleted = tomb.length()
      let total = n.manifest.num_docs
      if total > deleted {
        total - deleted
      } else {
        0
      }
    }
    Some(f) => {
      let p = eval_pushdown_filter(n, f)
      p.total_matched
    }
  }
}

///|
/// 命名空间内满足 filter（可选）的存活文档的某数值属性之和（Double）。
/// field 对应 rows/{field}.bin，必须是 i64 列（否则报 Corrupt）。
/// 无 filter 时对全部存活文档求和。
pub fn[S : @store.ObjectStore] sum_field(
  n : Namespace[S],
  field : String,
  filter : Filter?,
) -> Double raise @core.SpndError {
  let tomb = tombstones_of(n)
  let mut total = 0.0
  for si in 0..<n.manifest.segments.length() {
    let seg = n.manifest.segments[si]
    let cs = ensure_seg(n, si)
    if !seg_may_match(cs, filter) {
      continue
    }
    // 加载字段列
    let col_key = "\{n.ns}/_segments/\{seg.id}/rows/\{field}.bin"
    let col_bs = match n.store.get(col_key) {
      Some(b) => b
      None => raise @core.NotFound(col_key)
    }
    let vals = match @format.decode_col(col_bs) {
      @format.ColI64(arr) => arr
      _ =>
        raise @core.Corrupt(
          "sum_field: column \{field} is not i64",
        )
    }
    // 可选 filter 匹配器
    let matcher : RowMatcher? = match filter {
      Some(f) => Some(load_matcher(n, cs, seg.id, f))
      None => None
    }
    for row in 0..<cs.row_count {
      let ok = match matcher {
        Some(m) => matcher_at(m, row)
        None => true
      }
      if ok {
        let id = row_id(n, cs, seg.id, row)
        if !tomb.contains(id) {
          match vals.get(row) {
            Some(v) => total += v.to_double()
            None => ()
          }
        }
      }
    }
  }
  total
}

///|
/// 命名空间内满足 filter 的所有存活文档 ID（无序，用于 delete_by_filter）。
pub fn[S : @store.ObjectStore] matching_ids(
  n : Namespace[S],
  filter : Filter,
) -> Array[UInt64] raise @core.SpndError {
  let p = eval_pushdown_filter(n, filter)
  let out : Array[UInt64] = Array::new(capacity=p.total_matched)
  for id in p.allowed_ids {
    out.push(id)
  }
  out
}
