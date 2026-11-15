// BM25 读路径（spec 局部性语义）。
//
// query tokenize → 对 manifest.segments 每个 segment：
//   seg meta.json（缓存，含 stats 预判）→ fts/dir.bin（缓存）→
//   命中 term 用 store.get_range(postings.bin, offset=16+entry.offset, len=entry.size)
//   拉局部 posting（16 = postings.bin 的 SPNDPOS1 头）→
//   自写 delta-uvarint 解码（range 读回的字节没有 SPNDPOS1 头）→
//   fts/doc_len.bin（缓存）→ okapi 打分（df/term/segment，N = segment.row_count，
//   avgdl = manifest.avg_doc_len，k1/b 来自 namespace.json）。
//
// fts/blockmax.bin 存在时走 block-max WAND（块上界 + 全局词上界），
// 正确性与逐 posting 路径一致（测试硬门）。filter 在打分阶段按段内行号过滤
// （列缓存 + 字典 code / bool 位图直查），stats 不相交的段整段跳过。
// per-segment top-k → 跨 segment 合并 → row→id → tombstone → top-k。

///|
/// 过滤列的行级匹配器（字典列按 code、bool 位图直接查位）。
/// v1 扩展：集合/范围比较 + And/Or/Not 组合（子匹配器递归求值）。
pub(all) enum RowMatcher {
  MStr(Array[String], String)
  MDict(Array[UInt16], UInt16) // codes, target code（65535 = 值不在字典）
  MBool(Array[Bool], Bool)
  MBitmap(Bytes, Bool) // 位图字节, target
  MI64(Array[Int64], Int64)
  MMask(FixedArray[Bool]) // 块级 stats 跳过后只标记可能命中的行
  // —— v1 过滤扩展 ——
  MStrSet(Array[String], Set[String]) // In（普通 str 列）
  MDictSet(Array[UInt16], Set[UInt16]) // In（字典列）
  MI64Set(Array[Int64], Set[Int64]) // In（i64 列）
  MI64Cmp(Array[Int64], Int, Int64) // 范围比较；op: 0=lt 1=lte 2=gt 3=gte
  MStrCmp(Array[String], Int, String) // string 范围（term_compare 字节序）
  MDictCmp(Array[UInt16], Array[String], Int, String) // 字典列范围
  MGlob(Array[String], String) // 通配符匹配（* 任意多字符，? 恰好一字符）
  MAnd(Array[RowMatcher]) // 空数组恒 true
  MOr(Array[RowMatcher]) // 空数组恒 false
  MNot(RowMatcher)
}

///|
/// 范围比较 op 常量（MI64Cmp / MStrCmp / MDictCmp 共用）。
const CMP_LT : Int = 0

const CMP_LTE : Int = 1

const CMP_GT : Int = 2

const CMP_GTE : Int = 3

///|
fn i64_cmp(x : Int64, op : Int, v : Int64) -> Bool {
  match op {
    CMP_LT => x < v
    CMP_LTE => x <= v
    CMP_GT => x > v
    _ => x >= v
  }
}

///|
/// 块级 [lo, hi] 与范围谓词是否可能相交（ts block-stats 跳块用）。
fn block_may_match(lo : Int64, hi : Int64, op : Int, v : Int64) -> Bool {
  match op {
    CMP_LT => lo < v
    CMP_LTE => lo <= v
    CMP_GT => hi > v
    _ => hi >= v
  }
}

///|
fn fval_key(v : FVal) -> String {
  match v {
    S(s) => "s:\{s}"
    B(b) => "b:\{b}"
    I(i) => "i:\{i}"
  }
}

///|
fn val_list_key(vals : Array[FVal]) -> String {
  let mut s = ""
  for i, v in vals {
    if i > 0 {
      s = s + ","
    }
    s = s + fval_key(v)
  }
  s
}

///|
/// 匹配器缓存 key：整棵过滤子树的规范化序列化（子匹配器各自也会缓存）。
fn filter_key(f : Filter) -> String {
  match f {
    Eq(field, v) => "eq(\{field},\{fval_key(v)})"
    Neq(field, v) => "ne(\{field},\{fval_key(v)})"
    Lt(field, v) => "lt(\{field},\{fval_key(v)})"
    Lte(field, v) => "le(\{field},\{fval_key(v)})"
    Gt(field, v) => "gt(\{field},\{fval_key(v)})"
    Gte(field, v) => "ge(\{field},\{fval_key(v)})"
    In(field, vals) => "in(\{field},[\{val_list_key(vals)}])"
    NotIn(field, vals) => "ni(\{field},[\{val_list_key(vals)}])"
    And(children) => {
      let mut s = "and("
      for i, c in children {
        if i > 0 {
          s = s + ","
        }
        s = s + filter_key(c)
      }
      s + ")"
    }
    Or(children) => {
      let mut s = "or("
      for i, c in children {
        if i > 0 {
          s = s + ","
        }
        s = s + filter_key(c)
      }
      s + ")"
    }
    Not(inner) => "not(\{filter_key(inner)})"
    Glob(field, pat) => "glob(\{field},\{pat})"
  }
}

///|
/// 加载（或从缓存取）某 segment 的过滤匹配器。支持完整过滤树：
/// 组合节点递归加载子匹配器，叶子按列 dtype 分派（dict / bitmap / 普通列 /
/// ts 块级 stats）。空 In = MOr([])（恒 false），NotIn(空) = 恒 true。
fn[S : @store.ObjectStore] load_matcher(
  n : Namespace[S],
  cs : CachedSeg,
  seg_id : String,
  f : Filter,
) -> RowMatcher raise @core.SpndError {
  let key = filter_key(f)
  match cs.matchers.get(key) {
    Some(m) => m
    None => {
      let m = match f {
        Eq(field, v) => load_eq_matcher(n, cs, seg_id, field, v)
        Neq(field, v) => MNot(load_eq_matcher(n, cs, seg_id, field, v))
        In(field, vals) => load_in_matcher(n, cs, seg_id, field, vals)
        NotIn(field, vals) => MNot(load_in_matcher(n, cs, seg_id, field, vals))
        Lt(field, v) => load_cmp_matcher(n, cs, seg_id, field, CMP_LT, v)
        Lte(field, v) => load_cmp_matcher(n, cs, seg_id, field, CMP_LTE, v)
        Gt(field, v) => load_cmp_matcher(n, cs, seg_id, field, CMP_GT, v)
        Gte(field, v) => load_cmp_matcher(n, cs, seg_id, field, CMP_GTE, v)
        And(children) => {
          let ms : Array[RowMatcher] = Array(
            capacity=children.length(),
          )
          for c in children {
            ms.push(load_matcher(n, cs, seg_id, c))
          }
          MAnd(ms)
        }
        Or(children) => {
          let ms : Array[RowMatcher] = Array(
            capacity=children.length(),
          )
          for c in children {
            ms.push(load_matcher(n, cs, seg_id, c))
          }
          MOr(ms)
        }
        Not(inner) => MNot(load_matcher(n, cs, seg_id, inner))
        Glob(field, pat) => {
          let col_key = "\{n.ns}/_segments/\{seg_id}/rows/\{field}.bin"
          let bs = get_object(n.store, col_key)
          match @format.decode_col(bs) {
            @format.ColStr(arr) => MGlob(arr, pat)
            _ =>
              raise @core.Corrupt(
                "Glob filter requires string column for \{field}",
              )
          }
        }
      }
      cs.matchers.set(key, m)
      m
    }
  }
}

///|
/// 等值叶子：字典列按 code、bool 位图直查、ts 块级 stats（只读相交块）。
fn[S : @store.ObjectStore] load_eq_matcher(
  n : Namespace[S],
  cs : CachedSeg,
  seg_id : String,
  field : String,
  v : FVal,
) -> RowMatcher raise @core.SpndError {
  let col_key = "\{n.ns}/_segments/\{seg_id}/rows/\{field}.bin"
  let bs = get_object(n.store, col_key)
  match v {
    S(s) =>
      if @format.is_dict_col(bs) {
        let (dict, codes) = @format.decode_col_dict(bs)
        let mut target : UInt16 = (65535).to_uint16()
        for i in 0..<dict.length() {
          if dict[i] == s {
            target = i.to_uint16()
            break
          }
        }
        MDict(codes, target)
      } else {
        match @format.decode_col(bs) {
          @format.ColStr(arr) => MStr(arr, s)
          _ =>
            raise @core.Corrupt(
              "filter column dtype mismatch for \{field}",
            )
        }
      }
    B(b) =>
      // dtype=bool 且 flags bit1=位图 → 直接查位，不展开
      if @format.is_bitmap_bool(bs) {
        MBitmap(bs, b)
      } else {
        match @format.decode_col(bs) {
          @format.ColBool(arr) => MBool(arr, b)
          _ =>
            raise @core.Corrupt(
              "filter column dtype mismatch for \{field}",
            )
        }
      }
    I(i) =>
      if field == "ts" {
        match seg_block_stats(n, cs, seg_id) {
          Some((block_size, row_count, blocks)) => {
            let mask : FixedArray[Bool] = FixedArray::make(
              cs.row_count,
              false,
            )
            let ts_key = "\{n.ns}/_segments/\{seg_id}/rows/ts.bin"
            let mut ok = true
            for b in 0..<blocks.length() {
              let (lo, hi) = blocks[b]
              if i >= lo && i <= hi {
                let start = b * block_size
                let nrows = if start + block_size < row_count {
                  block_size
                } else {
                  row_count - start
                }
                match n.store.get_range(ts_key, 20 + start * 8, nrows * 8) {
                  Some(pbs) =>
                    if pbs.length() >= nrows * 8 {
                      for x in 0..<nrows {
                        if @core.read_i64_le(pbs, x * 8) == i {
                          mask[start + x] = true
                        }
                      }
                    } else {
                      ok = false
                      break
                    }
                  None => {
                    ok = false
                    break
                  }
                }
              }
            }
            if ok {
              MMask(mask)
            } else {
              match @format.decode_col(bs) {
                @format.ColI64(arr) => MI64(arr, i)
                _ => raise @core.Corrupt("filter column dtype mismatch for ts")
              }
            }
          }
          None =>
            match @format.decode_col(bs) {
              @format.ColI64(arr) => MI64(arr, i)
              _ => raise @core.Corrupt("filter column dtype mismatch for ts")
            }
        }
      } else {
        match @format.decode_col(bs) {
          @format.ColI64(arr) => MI64(arr, i)
          _ =>
            raise @core.Corrupt(
              "filter column dtype mismatch for \{field}",
            )
        }
      }
  }
}

///|
/// In 叶子：值集合同型校验（兜底）→ 按值类型分派列编码。
fn[S : @store.ObjectStore] load_in_matcher(
  n : Namespace[S],
  cs : CachedSeg,
  seg_id : String,
  field : String,
  vals : Array[FVal],
) -> RowMatcher raise @core.SpndError {
  if vals.is_empty() {
    return MOr([]) // 空集合恒 false
  }
  let head = vals[0]
  for v in vals {
    let same = match (head, v) {
      (S(_), S(_)) | (B(_), B(_)) | (I(_), I(_)) => true
      _ => false
    }
    if !same {
      raise @core.Corrupt(
        "In(\{field}) values must be homogeneous: \{head.describe()} vs \{v.describe()}",
      )
    }
  }
  let col_key = "\{n.ns}/_segments/\{seg_id}/rows/\{field}.bin"
  let bs = get_object(n.store, col_key)
  match head {
    B(_) => {
      // bool In：最多两个不同值，展开为 Or(Eq..)（复用位图/普通列等值路径）
      let ms : Array[RowMatcher] = Array(capacity=vals.length())
      for v in vals {
        match v {
          B(b) => ms.push(load_eq_matcher(n, cs, seg_id, field, B(b)))
          _ => raise @core.Corrupt("In(\{field}) mixed value types")
        }
      }
      MOr(ms)
    }
    I(_) => {
      let set : Set[Int64] = Set([])
      for v in vals {
        match v {
          I(i) => set.add(i)
          _ => raise @core.Corrupt("In(\{field}) mixed value types")
        }
      }
      match @format.decode_col(bs) {
        @format.ColI64(arr) => MI64Set(arr, set)
        _ =>
          raise @core.Corrupt(
            "filter column dtype mismatch for \{field}",
          )
      }
    }
    S(_) => {
      let set : Set[String] = Set([])
      for v in vals {
        match v {
          S(s) => set.add(s)
          _ => raise @core.Corrupt("In(\{field}) mixed value types")
        }
      }
      if @format.is_dict_col(bs) {
        let (dict, codes) = @format.decode_col_dict(bs)
        let targets : Set[UInt16] = Set([])
        for i in 0..<dict.length() {
          if set.contains(dict[i]) {
            targets.add(i.to_uint16())
          }
        }
        MDictSet(codes, targets)
      } else {
        match @format.decode_col(bs) {
          @format.ColStr(arr) => MStrSet(arr, set)
          _ =>
            raise @core.Corrupt(
              "filter column dtype mismatch for \{field}",
            )
        }
      }
    }
  }
}

///|
/// 范围叶子：i64 数值比较 / string 字节序字典序。bool 列不支持范围。
/// ts 走块级 mask：只读与谓词范围相交的块（块内逐行比较）。
fn[S : @store.ObjectStore] load_cmp_matcher(
  n : Namespace[S],
  cs : CachedSeg,
  seg_id : String,
  field : String,
  op : Int,
  v : FVal,
) -> RowMatcher raise @core.SpndError {
  let col_key = "\{n.ns}/_segments/\{seg_id}/rows/\{field}.bin"
  let bs = get_object(n.store, col_key)
  match v {
    B(_) =>
      raise @core.Corrupt(
        "range comparison not supported for bool column \{field}",
      )
    I(i) =>
      if field == "ts" {
        match seg_block_stats(n, cs, seg_id) {
          Some((block_size, row_count, blocks)) => {
            let mask : FixedArray[Bool] = FixedArray::make(
              cs.row_count,
              false,
            )
            let ts_key = "\{n.ns}/_segments/\{seg_id}/rows/ts.bin"
            let mut ok = true
            for b in 0..<blocks.length() {
              let (lo, hi) = blocks[b]
              if block_may_match(lo, hi, op, i) {
                let start = b * block_size
                let nrows = if start + block_size < row_count {
                  block_size
                } else {
                  row_count - start
                }
                match n.store.get_range(ts_key, 20 + start * 8, nrows * 8) {
                  Some(pbs) =>
                    if pbs.length() >= nrows * 8 {
                      for x in 0..<nrows {
                        if i64_cmp(@core.read_i64_le(pbs, x * 8), op, i) {
                          mask[start + x] = true
                        }
                      }
                    } else {
                      ok = false
                      break
                    }
                  None => {
                    ok = false
                    break
                  }
                }
              }
            }
            if ok {
              MMask(mask)
            } else {
              match @format.decode_col(bs) {
                @format.ColI64(arr) => MI64Cmp(arr, op, i)
                _ => raise @core.Corrupt("filter column dtype mismatch for ts")
              }
            }
          }
          None =>
            match @format.decode_col(bs) {
              @format.ColI64(arr) => MI64Cmp(arr, op, i)
              _ => raise @core.Corrupt("filter column dtype mismatch for ts")
            }
        }
      } else {
        match @format.decode_col(bs) {
          @format.ColI64(arr) => MI64Cmp(arr, op, i)
          _ =>
            raise @core.Corrupt(
              "filter column dtype mismatch for \{field}",
            )
        }
      }
    S(s) => {
      if @format.is_dict_col(bs) {
        let (dict, codes) = @format.decode_col_dict(bs)
        MDictCmp(codes, dict, op, s)
      } else {
        match @format.decode_col(bs) {
          @format.ColStr(arr) => MStrCmp(arr, op, s)
          _ =>
            raise @core.Corrupt(
              "filter column dtype mismatch for \{field}",
            )
        }
      }
    }
  }
}

///|
/// 通配符匹配：`*` 匹配 0 个或多个任意字符，`?` 匹配恰好 1 个字符。
/// 使用动态规划（DP）实现，避免回溯式递归的指数复杂度。
fn glob_match(text : String, pat : String) -> Bool {
  let tc = text.to_array()
  let pc = pat.to_array()
  let n = tc.length()
  let m = pc.length()
  // dp[i][j] = pat[0..j) 是否匹配 text[0..i)
  // 用两行滚动数组降低内存
  let mut prev : Array[Bool] = Array::make(m + 1, false)
  prev[0] = true
  // pat 以 '*' 开头时扩展空匹配
  for j in 1..=m {
    if pc[j - 1] == '*' {
      prev[j] = prev[j - 1]
    } else {
      break
    }
  }
  for i in 1..=n {
    let curr : Array[Bool] = Array::make(m + 1, false)
    for j in 1..=m {
      let p = pc[j - 1]
      if p == '*' {
        // '*' 匹配空串（curr[j-1]）或多消耗一个 text 字符（prev[j]）
        curr[j] = curr[j - 1] || prev[j]
      } else if p == '?' || p == tc[i - 1] {
        curr[j] = prev[j - 1]
      }
    }
    prev = curr
  }
  prev[m]
}

///|
/// 行级谓词求值（组合节点递归）。MAnd 空 = true，MOr 空 = false。
fn matcher_at(m : RowMatcher, row : Int) -> Bool {
  match m {
    MStr(arr, v) =>
      match arr.get(row) {
        Some(x) => x == v
        None => false
      }
    MDict(codes, target) =>
      match codes.get(row) {
        Some(x) => x == target
        None => false
      }
    MBool(arr, v) =>
      match arr.get(row) {
        Some(x) => x == v
        None => false
      }
    MBitmap(bs, v) =>
      match bs.get(20 + row / 8) {
        Some(b) => (((b.to_int() >> (row % 8)) & 1) != 0) == v
        None => false
      }
    MI64(arr, v) =>
      match arr.get(row) {
        Some(x) => x == v
        None => false
      }
    MMask(mask) =>
      if row >= 0 && row < mask.length() {
        mask[row]
      } else {
        false
      }
    MStrSet(arr, set) =>
      match arr.get(row) {
        Some(x) => set.contains(x)
        None => false
      }
    MDictSet(codes, targets) =>
      match codes.get(row) {
        Some(x) => targets.contains(x)
        None => false
      }
    MI64Set(arr, set) =>
      match arr.get(row) {
        Some(x) => set.contains(x)
        None => false
      }
    MI64Cmp(arr, op, v) =>
      match arr.get(row) {
        Some(x) => i64_cmp(x, op, v)
        None => false
      }
    MStrCmp(arr, op, v) =>
      match arr.get(row) {
        Some(x) =>
          match op {
            CMP_LT => @format.term_compare(x, v) < 0
            CMP_LTE => @format.term_compare(x, v) <= 0
            CMP_GT => @format.term_compare(x, v) > 0
            _ => @format.term_compare(x, v) >= 0
          }
        None => false
      }
    MDictCmp(codes, dict, op, v) =>
      match codes.get(row) {
        Some(c) =>
          if c.to_int() < dict.length() {
            let x = dict[c.to_int()]
            match op {
              CMP_LT => @format.term_compare(x, v) < 0
              CMP_LTE => @format.term_compare(x, v) <= 0
              CMP_GT => @format.term_compare(x, v) > 0
              _ => @format.term_compare(x, v) >= 0
            }
          } else {
            false
          }
        None => false
      }
    MAnd(ms) => {
      for x in ms {
        if !matcher_at(x, row) {
          return false
        }
      }
      true
    }
    MOr(ms) => {
      for x in ms {
        if matcher_at(x, row) {
          return true
        }
      }
      false
    }
    MNot(inner) => !matcher_at(inner, row)
    MGlob(arr, pat) =>
      match arr.get(row) {
        Some(x) => glob_match(x, pat)
        None => false
      }
  }
}

///|
/// 解码 get_range 拉回的 posting 区间（无 SPNDPOS1 头）：
/// repeated (row_delta uvarint + tf uvarint)，首 delta = row+1（prev 初始 -1）。
fn decode_posting_slice(
  bs : Bytes,
) -> Array[@format.Posting] raise @core.SpndError {
  let out : Array[@format.Posting] = Array()
  let fa = bs.to_fixedarray()
  let mut prev = -1
  let mut pos = 0
  let len = bs.length()
  while pos < len {
    let (delta, p1) = @format.fa_uvarint(fa, pos, len)
    let (tf, p2) = @format.fa_uvarint(fa, p1, len)
    prev = prev + delta.reinterpret_as_int()
    out.push({ row: prev, tf: tf.reinterpret_as_int() })
    pos = p2
  }
  out
}

///|
/// 在 fts 目录（按 @format.term_compare = UTF-8 字节序升序）中二分查找 term。
/// 比较器必须与 encode_fts 的排序一致：String::compare 长度优先，
/// 与字节序二分错位会导致 CJK 多字 term 查询失败。
fn find_entry_idx(entries : Array[@format.FtsDirEntry], term : String) -> Int? {
  let mut lo = 0
  let mut hi = entries.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    let c = @format.term_compare(entries[mid].term, term)
    if c == 0 {
      return Some(mid)
    }
    if c < 0 {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  None
}

///|
/// okapi BM25 打分（与 NOTES 第 2 节公式一致）。
fn bm25_score(
  tf : Int,
  df : Int,
  n_docs : Int,
  dl : Int,
  avgdl : Double,
  k1 : Double,
  b : Double,
) -> Double {
  let tfd = tf.to_double()
  let dfd = df.to_double()
  let idf = @math.ln(1.0 + (n_docs.to_double() - dfd + 0.5) / (dfd + 0.5))
  let avg = if avgdl > 0.0 { avgdl } else { 1.0 }
  let denom = tfd + k1 * (1.0 - b + b * (dl.to_double() / avg))
  idf * (tfd * (k1 + 1.0)) / denom
}

///|
/// WAND 迭代器（一个 term 的 posting 游标 + 块上界）。
priv struct WandIter {
  posts : Array[@format.Posting]
  block_ubs : Array[Double]
  ub_global : Double
  df : Int
  mut pos : Int
  mut row : Int
}

///|
const WAND_END : Int = 0x3FFFFFFF

///|
fn wand_advance(it : WandIter) -> Unit {
  it.pos = it.pos + 1
  if it.pos < it.posts.length() {
    it.row = it.posts[it.pos].row
  } else {
    it.row = WAND_END
  }
}

///|
/// 把游标推进到第一个 row >= target；途中若「当前块上界 + 其他词上界 < θ」，
/// 整块跳过（block-max 剪枝）。θ 为当前 top-k 的第 k 名分数（未满 k 时为 0）。
fn wand_advance_to(
  it : WandIter,
  target : Int,
  block_size : Int,
  theta : Double,
  rest_ub : Double,
) -> Unit {
  while it.pos < it.posts.length() && it.posts[it.pos].row < target {
    let b = if block_size > 0 { it.pos / block_size } else { 0 }
    let ub = if b < it.block_ubs.length() {
      it.block_ubs[b]
    } else {
      it.ub_global
    }
    if ub + rest_ub < theta {
      let next = (b + 1) * block_size
      if next > it.pos {
        it.pos = next
      } else {
        it.pos = it.pos + 1
      }
    } else {
      it.pos = it.pos + 1
    }
  }
  if it.pos < it.posts.length() {
    it.row = it.posts[it.pos].row
  } else {
    it.row = WAND_END
  }
}

///|
/// 单 segment 的 block-max WAND。正确性：全局/块上界都是 BM25 的合法上界
/// （tf 越大分越高、dl 越小分越高），因此跳过的块不可能进入 top-k。
fn[S : @store.ObjectStore] bm25_segment_wand(
  n : Namespace[S],
  seg_id : String,
  matched : Array[(Int, @format.FtsDirEntry)],
  blk : Array[Array[(Int, Int)]],
  block_size : Int,
  doc_len : Array[Int],
  row_count : Int,
  avgdl : Double,
  k1 : Double,
  b : Double,
  k : Int,
  matcher : RowMatcher?,
) -> Array[(Int, Double)] raise @core.SpndError {
  let iters : Array[WandIter] = Array()
  for m in matched {
    let (di, e) = m
    let slice = match
      n.store.get_range(
        "\{n.ns}/_segments/\{seg_id}/fts/postings.bin",
        16 + e.offset,
        e.size,
      ) {
      Some(x) => x
      None =>
        raise @core.NotFound(
          "\{n.ns}/_segments/\{seg_id}/fts/postings.bin range",
        )
    }
    let posts = decode_posting_slice(slice)
    if posts.is_empty() {
      continue
    }
    let blocks = if di < blk.length() { blk[di] } else { [] }
    let block_ubs : Array[Double] = Array(capacity=blocks.length())
    let mut ub_global = 0.0
    for x in blocks {
      let u = bm25_score(x.0, e.df, row_count, x.1, avgdl, k1, b)
      block_ubs.push(u)
      if u > ub_global {
        ub_global = u
      }
    }
    if block_ubs.is_empty() {
      let mut max_tf = 0
      let mut min_dl = 0
      let mut first = true
      for p in posts {
        if p.tf > max_tf {
          max_tf = p.tf
        }
        let dl = if p.row >= 0 && p.row < doc_len.length() {
          doc_len[p.row]
        } else {
          0
        }
        if first || dl < min_dl {
          min_dl = dl
          first = false
        }
      }
      ub_global = bm25_score(max_tf, e.df, row_count, min_dl, avgdl, k1, b)
      block_ubs.push(ub_global)
    }
    iters.push({
      posts,
      block_ubs,
      ub_global,
      df: e.df,
      pos: 0,
      row: posts[0].row,
    })
  }
  if iters.is_empty() {
    return []
  }
  let top : Array[(Int, Double)] = Array()
  let mut theta = 0.0
  while iters.length() > 0 {
    // 移除耗尽迭代器
    let alive : Array[WandIter] = Array()
    for it in iters {
      if it.row != WAND_END {
        alive.push(it)
      }
    }
    iters.clear()
    for it in alive {
      iters.push(it)
    }
    if iters.is_empty() {
      break
    }
    iters.sort_by(fn(a, b) { a.row.compare(b.row) })
    // pivot：按 row 累加全局上界，首次 >= θ 的位置
    let mut sum = 0.0
    let mut pivot_i = -1
    for i in 0..<iters.length() {
      sum += iters[i].ub_global
      if sum >= theta {
        pivot_i = i
        break
      }
    }
    if pivot_i < 0 {
      break
    }
    let pivot_row = iters[pivot_i].row
    if iters[0].row == pivot_row {
      // 完整打分 pivot 行（所有当前 row == pivot 的 term）
      let mut s = 0.0
      for i in 0..<iters.length() {
        let it = iters[i]
        if it.row == pivot_row {
          let p = it.posts[it.pos]
          let ok = match matcher {
            Some(m) => matcher_at(m, pivot_row)
            None => true
          }
          if ok {
            let dl = match doc_len.get(pivot_row) {
              Some(x) => x
              None => 0
            }
            s += bm25_score(p.tf, it.df, row_count, dl, avgdl, k1, b)
          }
          wand_advance(it)
        }
      }
      if s > 0.0 {
        top.push((pivot_row, s))
        if top.length() > k {
          let mut mi = 0
          for j in 1..<top.length() {
            if top[j].1 < top[mi].1 {
              mi = j
            }
          }
          let _ = top.remove(mi)
        }
        if top.length() >= k {
          let mut m = top[0].1
          for j in 1..<top.length() {
            if top[j].1 < m {
              m = top[j].1
            }
          }
          theta = m
        }
      }
    } else {
      // 推进最小 row 的迭代器到 pivot（可整块跳过）
      let mut rest = 0.0
      for i in 1..<iters.length() {
        rest += iters[i].ub_global
      }
      wand_advance_to(iters[0], pivot_row, block_size, theta, rest)
    }
  }
  top.sort_by(fn(a, b) { b.1.compare(a.1) })
  if top.length() > k {
    top.truncate(k)
  }
  top
}

///|
/// 单 segment 的 BM25 候选：返回 (row, score) 降序 top-k。
/// use_wand=true 且该段有 blockmax.bin 时走 WAND，否则逐 posting 累积。
fn[S : @store.ObjectStore] bm25_segment(
  n : Namespace[S],
  seg_idx : Int,
  terms : Array[String],
  avgdl : Double,
  k1 : Double,
  b : Double,
  k : Int,
  filter : Filter?,
  use_wand : Bool,
) -> Array[(Int, Double)] raise @core.SpndError {
  let seg = n.manifest.segments[seg_idx]
  let cs = ensure_seg(n, seg_idx)
  if !seg_may_match(cs, filter) {
    return []
  }
  // LSM 式 Bloom：term 不可能存在时直接跳过 dir/postings/doc_len
  match cs.bloom {
    Some(bl) => {
      let mut any = false
      for t in terms {
        if @format.bloom_may_contain(bl, t) {
          any = true
          break
        }
      }
      if !any {
        return []
      }
    }
    None => ()
  }
  let entries = seg_dir(n, cs, seg.id)
  // 先解析全部命中 term；无命中则不再读 doc_len / postings
  let matched : Array[(Int, @format.FtsDirEntry)] = Array()
  for t in terms {
    match find_entry_idx(entries, t) {
      Some(i) => matched.push((i, entries[i]))
      None => ()
    }
  }
  if matched.is_empty() {
    return []
  }
  let matcher : RowMatcher? = match filter {
    Some(f) => Some(load_matcher(n, cs, seg.id, f))
    None => None
  }
  let doc_len = seg_doc_len(n, cs, seg.id)
  let row_count = cs.row_count
  if use_wand {
    match seg_blockmax(n, cs, seg.id) {
      Some(blk) =>
        return bm25_segment_wand(
          n,
          seg.id,
          matched,
          blk,
          cs.blockmax_size,
          doc_len,
          row_count,
          avgdl,
          k1,
          b,
          k,
          matcher,
        )
      None => ()
    }
  }
  let scores : Map[Int, Double] = Map([])
  for m in matched {
    let (_, e) = m
    // 只拉 term 的局部 posting 区间（外层 16 = SPNDPOS1 头）
    let slice = match
      n.store.get_range(
        "\{n.ns}/_segments/\{seg.id}/fts/postings.bin",
        16 + e.offset,
        e.size,
      ) {
      Some(x) => x
      None =>
        raise @core.NotFound(
          "\{n.ns}/_segments/\{seg.id}/fts/postings.bin range",
        )
    }
    let posts = decode_posting_slice(slice)
    for p in posts {
      if p.row >= row_count {
        continue
      }
      let ok = match matcher {
        Some(m) => matcher_at(m, p.row)
        None => true
      }
      if !ok {
        continue
      }
      let dl = match doc_len.get(p.row) {
        Some(x) => x
        None => 0
      }
      let s = bm25_score(p.tf, e.df, row_count, dl, avgdl, k1, b)
      let cur = match scores.get(p.row) {
        Some(v) => v
        None => 0.0
      }
      scores.set(p.row, cur + s)
    }
  }
  let arr : Array[(Int, Double)] = Array()
  for kv in scores.iter() {
    arr.push((kv.0, kv.1))
  }
  arr.sort_by(fn(x, y) { y.1.compare(x.1) })
  if arr.length() > k {
    arr.truncate(k)
  }
  arr
}

///|
/// BM25 检索实现（use_wand=false 用于正确性对照测试）。
fn[S : @store.ObjectStore] bm25_search_impl(
  n : Namespace[S],
  query : String,
  k : Int,
  filter : Filter?,
  use_wand : Bool,
) -> Array[QueryResult] raise @core.SpndError {
  // 查询侧用 namespace 配置的分词器（与索引侧同一选择，见 init_namespace）。
  let qtok = match n.meta.fts_tokenizer {
    Some(s) =>
      match @core.parse_tokenizer(s) {
        Some(t) => t
        None => @core.Word
      }
    None => @core.Word
  }
  let terms = dedupe_terms(@core.tokenize_with(qtok, query))
  if terms.is_empty() || k <= 0 {
    return []
  }
  let tomb = tombstones_of(n)
  let cands : Array[(Int, Int, Double)] = Array()
  for si in 0..<n.manifest.segments.length() {
    for
      c in bm25_segment(
        n,
        si,
        terms,
        n.manifest.avg_doc_len,
        n.meta.k1,
        n.meta.b,
        k,
        filter,
        use_wand,
      ) {
      cands.push((si, c.0, c.1))
    }
  }
  results_from_candidates(n, cands, tomb, k)
}

///|
/// BM25 检索：per-segment top-k → 合并 → tombstone → top-k（score 降序）。
/// 有 blockmax.bin 的段自动走 WAND。
pub fn[S : @store.ObjectStore] bm25_search(
  n : Namespace[S],
  query : String,
  k : Int,
  filter : Filter?,
) -> Array[QueryResult] raise @core.SpndError {
  bm25_search_impl(n, query, k, filter, true)
}
