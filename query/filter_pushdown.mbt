// Predicate Pushdown Filtering Engine
// Vectorized / columnar evaluation of Filter expressions against segment columnar data
// producing BitSets and Doc ID Sets for candidate pruning before vector probe scans.

///|
/// 高性能 BitSet，用于 segment / partition 级存活与匹配行的紧凑位图表示。
/// 采用 64 位整型数组存储，支持位级并行 AND, OR, NOT 与 popcount 统计。
#derive(Debug)
pub(all) struct BitSet {
  size : Int
  words : Array[UInt64]
}

///|
fn popcount64(x : UInt64) -> Int {
  let mut v = x
  v = v - ((v >> 1) & 0x5555555555555555UL)
  v = (v & 0x3333333333333333UL) + ((v >> 2) & 0x3333333333333333UL)
  v = (v + (v >> 4)) & 0x0F0F0F0F0F0F0F0FUL
  let total = (v * 0x0101010101010101UL) >> 56
  total.to_int()
}

///|
/// 创建全 0 的 BitSet。
pub fn BitSet::new(size : Int) -> BitSet {
  let num_words = (size + 63) / 64
  let words = Array::make(num_words, 0UL)
  { size, words }
}

///|
/// 创建全 1 的 BitSet（有效位均置 1，高位无用位清 0）。
pub fn BitSet::all_set(size : Int) -> BitSet {
  let num_words = (size + 63) / 64
  let words = Array::make(num_words, 0xFFFFFFFFFFFFFFFFUL)
  let bs = { size, words }
  bs.mask_last_word()
  bs
}

///|
fn BitSet::mask_last_word(self : BitSet) -> Unit {
  let rem = self.size % 64
  if rem != 0 && !(self.words.is_empty()) {
    let last = self.words.length() - 1
    let mask = (1UL << rem) - 1UL
    self.words[last] = self.words[last] & mask
  }
}

///|
pub fn BitSet::set(self : BitSet, idx : Int) -> Unit {
  if idx >= 0 && idx < self.size {
    let w = idx >> 6
    let b = idx & 63
    self.words[w] = self.words[w] | (1UL << b)
  }
}

///|
pub fn BitSet::unset(self : BitSet, idx : Int) -> Unit {
  if idx >= 0 && idx < self.size {
    let w = idx >> 6
    let b = idx & 63
    self.words[w] = self.words[w] & (1UL << b).lnot()
  }
}

///|
pub fn BitSet::get(self : BitSet, idx : Int) -> Bool {
  if idx >= 0 && idx < self.size {
    let w = idx >> 6
    let b = idx & 63
    (self.words[w] & (1UL << b)) != 0UL
  } else {
    false
  }
}

///|
/// 返回置位数量（popcount 并行统计）。
pub fn BitSet::count(self : BitSet) -> Int {
  let mut c = 0
  for w in self.words {
    if w != 0UL {
      c += popcount64(w)
    }
  }
  c
}

///|
pub fn BitSet::is_empty(self : BitSet) -> Bool {
  for w in self.words {
    if w != 0UL {
      return false
    }
  }
  true
}

///|
/// 原地按位与：64 行/指令。
pub fn BitSet::and_inplace(self : BitSet, other : BitSet) -> Unit {
  let len = if self.words.length() < other.words.length() {
    self.words.length()
  } else {
    other.words.length()
  }
  for i in 0..<len {
    self.words[i] = self.words[i] & other.words[i]
  }
  for i in len..<self.words.length() {
    self.words[i] = 0UL
  }
}

///|
/// 原地按位或：64 行/指令。
pub fn BitSet::or_inplace(self : BitSet, other : BitSet) -> Unit {
  let len = if self.words.length() < other.words.length() {
    self.words.length()
  } else {
    other.words.length()
  }
  for i in 0..<len {
    self.words[i] = self.words[i] | other.words[i]
  }
  self.mask_last_word()
}

///|
/// 原地按位取反（高位自动 mask 清 0）。
pub fn BitSet::not_inplace(self : BitSet) -> Unit {
  for i in 0..<self.words.length() {
    self.words[i] = self.words[i].lnot()
  }
  self.mask_last_word()
}

///|
pub fn BitSet::clone(self : BitSet) -> BitSet {
  let words = Array::make(self.words.length(), 0UL)
  for i in 0..<self.words.length() {
    words[i] = self.words[i]
  }
  { size: self.size, words }
}

///|
/// 导出所有置位行号（用于向量扫描候选行迭代）。
pub fn BitSet::to_rows(self : BitSet) -> Array[Int] {
  let res : Array[Int] = Array(capacity=self.count())
  for w in 0..<self.words.length() {
    let word = self.words[w]
    if word == 0UL {
      continue
    }
    let base = w * 64
    for b in 0..<64 {
      let r = base + b
      if r >= self.size {
        break
      }
      if (word & (1UL << b)) != 0UL {
        res.push(r)
      }
    }
  }
  res
}

///|
/// 跨段 pushdown 过滤求值产物：
/// - total_matched: 满足过滤的全局存活文档数
/// - total_docs: namespace 总文档数
/// - selectivity: 过滤选择率 (total_matched / total_docs)，<=0.05 代表重度过滤（5%）
/// - seg_bitsets: 各 segment 命中的行号 BitSet（已剔除 tombstone）
/// - allowed_ids: 全局允许的 Doc ID 集合
pub(all) struct MatchedDocSet {
  total_matched : Int
  total_docs : Int
  selectivity : Double
  seg_bitsets : Map[String, BitSet]
  allowed_ids : Set[UInt64]
}

///|
pub fn MatchedDocSet::is_empty(self : MatchedDocSet) -> Bool {
  self.total_matched == 0
}

///|
pub fn MatchedDocSet::contains_id(self : MatchedDocSet, id : UInt64) -> Bool {
  self.allowed_ids.contains(id)
}

///|
pub fn MatchedDocSet::get_seg_bitset(
  self : MatchedDocSet,
  seg_id : String,
) -> BitSet? {
  self.seg_bitsets.get(seg_id)
}

///|
/// 解码后的列数据类型，支持字典列、位图布尔列、普通列等。
pub(all) enum ColumnValues {
  ColDict(Array[String], Array[UInt16])
  ColStr(Array[String])
  ColBool(Array[Bool])
  ColBitmap(Bytes)
  ColI64(Array[Int64])
  ColU64(Array[UInt64])
}

///|
/// 读取并缓存 segment 的列数据。对于 dense id 段，直接按 min_id 合成数组，零 S3 I/O。
async fn[S : @store.ObjectStore] load_column_values(
  n : Namespace[S],
  cs : CachedSeg,
  seg_id : String,
  field : String,
  cache : Map[String, ColumnValues],
) -> ColumnValues {
  match cache.get(field) {
    Some(cv) => cv
    None => {
      if field == "id" {
        if cs.id_dense {
          let ids : Array[UInt64] = Array(capacity=cs.row_count)
          for r in 0..<cs.row_count {
            ids.push(cs.min_id + r.to_uint64())
          }
          let cv = ColU64(ids)
          cache.set(field, cv)
          return cv
        } else {
          let cv = ColU64(seg_ids(n, cs, seg_id).to_array())
          cache.set(field, cv)
          return cv
        }
      }
      let bs = seg_read_component_or_fail(
        n, seg_id, cs, "rows/\{field}.bin",
      )
      let cv = if @format.is_dict_col(bs) {
        let (dict, codes) = @format.decode_col_dict(bs)
        ColDict(dict, codes)
      } else if @format.is_bitmap_bool(bs) {
        ColBitmap(bs)
      } else {
        match @format.decode_col(bs) {
          @format.ColStr(arr) => ColStr(arr)
          @format.ColBool(arr) => ColBool(arr)
          @format.ColI64(arr) => ColI64(arr)
          @format.ColU64(arr) => ColU64(arr)
          _ => raise @core.Corrupt("unsupported column type for \{field}")
        }
      }
      cache.set(field, cv)
      cv
    }
  }
}

///|
/// 单 segment 向量化/列式求值核心：将任意嵌套的 Filter AST 转化为 BitSet。
async fn[S : @store.ObjectStore] eval_filter_columnar_with_cache(
  n : Namespace[S],
  cs : CachedSeg,
  seg_id : String,
  filter : Filter,
  cache : Map[String, ColumnValues],
) -> BitSet {
  let row_count = cs.row_count
  if row_count == 0 {
    return BitSet::new(0)
  }
  match filter {
    Eq(field, v) => eval_eq_columnar(n, cs, seg_id, field, v, cache)
    Neq(field, v) => {
      let bs = eval_eq_columnar(n, cs, seg_id, field, v, cache)
      bs.not_inplace()
      bs
    }
    In(field, vals) => eval_in_columnar(n, cs, seg_id, field, vals, cache)
    NotIn(field, vals) => {
      let bs = eval_in_columnar(n, cs, seg_id, field, vals, cache)
      bs.not_inplace()
      bs
    }
    Lt(field, v) => eval_cmp_columnar(n, cs, seg_id, field, CMP_LT, v, cache)
    Lte(field, v) => eval_cmp_columnar(n, cs, seg_id, field, CMP_LTE, v, cache)
    Gt(field, v) => eval_cmp_columnar(n, cs, seg_id, field, CMP_GT, v, cache)
    Gte(field, v) => eval_cmp_columnar(n, cs, seg_id, field, CMP_GTE, v, cache)
    Glob(field, pat) => eval_glob_columnar(n, cs, seg_id, field, pat, cache)
    And(children) => {
      if children.is_empty() {
        return BitSet::all_set(row_count)
      }
      let bs = eval_filter_columnar_with_cache(
        n,
        cs,
        seg_id,
        children[0],
        cache,
      )
      if bs.is_empty() {
        return bs
      }
      for i in 1..<children.length() {
        let child_bs = eval_filter_columnar_with_cache(
          n,
          cs,
          seg_id,
          children[i],
          cache,
        )
        bs.and_inplace(child_bs)
        if bs.is_empty() {
          return bs
        }
      }
      bs
    }
    Or(children) => {
      if children.is_empty() {
        return BitSet::new(row_count)
      }
      let bs = eval_filter_columnar_with_cache(
        n,
        cs,
        seg_id,
        children[0],
        cache,
      )
      if bs.count() == row_count {
        return bs
      }
      for i in 1..<children.length() {
        let child_bs = eval_filter_columnar_with_cache(
          n,
          cs,
          seg_id,
          children[i],
          cache,
        )
        bs.or_inplace(child_bs)
        if bs.count() == row_count {
          return bs
        }
      }
      bs
    }
    Not(child) => {
      let bs = eval_filter_columnar_with_cache(n, cs, seg_id, child, cache)
      bs.not_inplace()
      bs
    }
  }
}

///|
/// 列式等值判断（Eq）。
async fn[S : @store.ObjectStore] eval_eq_columnar(
  n : Namespace[S],
  cs : CachedSeg,
  seg_id : String,
  field : String,
  v : FVal,
  cache : Map[String, ColumnValues],
) -> BitSet {
  let cv = load_column_values(n, cs, seg_id, field, cache)
  let bs = BitSet::new(cs.row_count)
  match (cv, v) {
    (ColDict(dict, codes), S(target)) => {
      let mut target_code : UInt16? = None
      for i in 0..<dict.length() {
        if dict[i] == target {
          target_code = Some(i.to_uint16())
          break
        }
      }
      match target_code {
        None => ()
        Some(tc) =>
          for i in 0..<codes.length() {
            if codes[i] == tc {
              bs.set(i)
            }
          }
      }
    }
    (ColStr(arr), S(target)) =>
      for i in 0..<arr.length() {
        if arr[i] == target {
          bs.set(i)
        }
      }
    (ColBitmap(bytes), B(target)) => {
      let count = cs.row_count
      let num_words = (count + 63) / 64
      for w in 0..<num_words {
        let off = 20 + w * 8
        if off + 8 <= bytes.length() {
          let raw = @core.read_u64_le(bytes, off)
          bs.words[w] = if target { raw } else { raw.lnot() }
        } else {
          // 边界不足 8 字节按字节填入
          let mut raw = 0UL
          for b in 0..<8 {
            let boff = off + b
            if boff < bytes.length() {
              raw = raw | (bytes[boff].to_uint64() << (b * 8))
            }
          }
          bs.words[w] = if target { raw } else { raw.lnot() }
        }
      }
      bs.mask_last_word()
    }
    (ColBool(arr), B(target)) =>
      for i in 0..<arr.length() {
        if arr[i] == target {
          bs.set(i)
        }
      }
    (ColI64(arr), I(target)) =>
      for i in 0..<arr.length() {
        if arr[i] == target {
          bs.set(i)
        }
      }
    (ColU64(arr), I(target)) => {
      let tu64 = target.reinterpret_as_uint64()
      for i in 0..<arr.length() {
        if arr[i] == tu64 {
          bs.set(i)
        }
      }
    }
    _ => raise @core.Corrupt("type mismatch in Eq filter for \{field}")
  }
  bs
}

///|
/// 列式集合包含判断（In）。
async fn[S : @store.ObjectStore] eval_in_columnar(
  n : Namespace[S],
  cs : CachedSeg,
  seg_id : String,
  field : String,
  vals : Array[FVal],
  cache : Map[String, ColumnValues],
) -> BitSet {
  let bs = BitSet::new(cs.row_count)
  if vals.is_empty() {
    return bs
  }
  let cv = load_column_values(n, cs, seg_id, field, cache)
  match cv {
    ColDict(dict, codes) => {
      let str_targets : Set[String] = Set([])
      for v in vals {
        match v {
          S(s) => str_targets.add(s)
          _ => raise @core.Corrupt("In(\{field}) mixed value types")
        }
      }
      let code_targets : Set[UInt16] = Set([])
      for i in 0..<dict.length() {
        if str_targets.contains(dict[i]) {
          code_targets.add(i.to_uint16())
        }
      }
      if !(code_targets.is_empty()) {
        for i in 0..<codes.length() {
          if code_targets.contains(codes[i]) {
            bs.set(i)
          }
        }
      }
    }
    ColStr(arr) => {
      let str_targets : Set[String] = Set([])
      for v in vals {
        match v {
          S(s) => str_targets.add(s)
          _ => raise @core.Corrupt("In(\{field}) mixed value types")
        }
      }
      for i in 0..<arr.length() {
        if str_targets.contains(arr[i]) {
          bs.set(i)
        }
      }
    }
    ColI64(arr) => {
      let i64_targets : Set[Int64] = Set([])
      for v in vals {
        match v {
          I(x) => i64_targets.add(x)
          _ => raise @core.Corrupt("In(\{field}) mixed value types")
        }
      }
      for i in 0..<arr.length() {
        if i64_targets.contains(arr[i]) {
          bs.set(i)
        }
      }
    }
    ColU64(arr) => {
      let u64_targets : Set[UInt64] = Set([])
      for v in vals {
        match v {
          I(x) => u64_targets.add(x.reinterpret_as_uint64())
          _ => raise @core.Corrupt("In(\{field}) mixed value types")
        }
      }
      for i in 0..<arr.length() {
        if u64_targets.contains(arr[i]) {
          bs.set(i)
        }
      }
    }
    ColBool(arr) => {
      let mut has_t = false
      let mut has_f = false
      for v in vals {
        match v {
          B(true) => has_t = true
          B(false) => has_f = true
          _ => raise @core.Corrupt("In(\{field}) mixed value types")
        }
      }
      if has_t && has_f {
        return BitSet::all_set(cs.row_count)
      }
      if has_t {
        for i in 0..<arr.length() {
          if arr[i] {
            bs.set(i)
          }
        }
      } else if has_f {
        for i in 0..<arr.length() {
          if !(arr[i]) {
            bs.set(i)
          }
        }
      }
    }
    ColBitmap(_) => {
      let mut has_t = false
      let mut has_f = false
      for v in vals {
        match v {
          B(true) => has_t = true
          B(false) => has_f = true
          _ => raise @core.Corrupt("In(\{field}) mixed value types")
        }
      }
      if has_t && has_f {
        return BitSet::all_set(cs.row_count)
      }
      if has_t {
        return eval_eq_columnar(n, cs, seg_id, field, B(true), cache)
      } else if has_f {
        return eval_eq_columnar(n, cs, seg_id, field, B(false), cache)
      }
    }
  }
  bs
}

///|
/// 列式范围比较（Lt, Lte, Gt, Gte）。
async fn[S : @store.ObjectStore] eval_cmp_columnar(
  n : Namespace[S],
  cs : CachedSeg,
  seg_id : String,
  field : String,
  op : Int,
  v : FVal,
  cache : Map[String, ColumnValues],
) -> BitSet {
  let cv = load_column_values(n, cs, seg_id, field, cache)
  let bs = BitSet::new(cs.row_count)
  match (cv, v) {
    (ColI64(arr), I(target)) =>
      for i in 0..<arr.length() {
        if i64_cmp(arr[i], op, target) {
          bs.set(i)
        }
      }
    (ColU64(arr), I(target)) => {
      let tu64 = target.reinterpret_as_uint64()
      for i in 0..<arr.length() {
        let ok = match op {
          CMP_LT => arr[i] < tu64
          CMP_LTE => arr[i] <= tu64
          CMP_GT => arr[i] > tu64
          _ => arr[i] >= tu64
        }
        if ok {
          bs.set(i)
        }
      }
    }
    (ColDict(dict, codes), S(target)) => {
      let matched : Array[Bool] = Array::make(dict.length(), false)
      for c in 0..<dict.length() {
        let cmp = @format.term_compare(dict[c], target)
        matched[c] = match op {
          CMP_LT => cmp < 0
          CMP_LTE => cmp <= 0
          CMP_GT => cmp > 0
          _ => cmp >= 0
        }
      }
      for i in 0..<codes.length() {
        let c = codes[i].to_int()
        if c < matched.length() && matched[c] {
          bs.set(i)
        }
      }
    }
    (ColStr(arr), S(target)) =>
      for i in 0..<arr.length() {
        let cmp = @format.term_compare(arr[i], target)
        let ok = match op {
          CMP_LT => cmp < 0
          CMP_LTE => cmp <= 0
          CMP_GT => cmp > 0
          _ => cmp >= 0
        }
        if ok {
          bs.set(i)
        }
      }
    (ColBool(_) | ColBitmap(_), _) =>
      raise @core.Corrupt(
        "range comparison not supported for bool column \{field}",
      )
    _ => raise @core.Corrupt("type mismatch in range comparison for \{field}")
  }
  bs
}

///|
/// 列式通配符匹配（Glob）。
async fn[S : @store.ObjectStore] eval_glob_columnar(
  n : Namespace[S],
  cs : CachedSeg,
  seg_id : String,
  field : String,
  pat : String,
  cache : Map[String, ColumnValues],
) -> BitSet {
  let cv = load_column_values(n, cs, seg_id, field, cache)
  let bs = BitSet::new(cs.row_count)
  match cv {
    ColDict(dict, codes) => {
      let matched : Array[Bool] = Array::make(dict.length(), false)
      for c in 0..<dict.length() {
        matched[c] = glob_match(dict[c], pat)
      }
      for i in 0..<codes.length() {
        let c = codes[i].to_int()
        if c < matched.length() && matched[c] {
          bs.set(i)
        }
      }
    }
    ColStr(arr) =>
      for i in 0..<arr.length() {
        if glob_match(arr[i], pat) {
          bs.set(i)
        }
      }
    _ => raise @core.Corrupt("Glob filter requires string column for \{field}")
  }
  bs
}

///|
/// 对指定 segment 进行向量化列式求值，返回命中的 BitSet。
pub async fn[S : @store.ObjectStore] eval_filter_columnar(
  n : Namespace[S],
  cs : CachedSeg,
  seg_id : String,
  filter : Filter,
) -> BitSet {
  let cache : Map[String, ColumnValues] = Map([])
  eval_filter_columnar_with_cache(n, cs, seg_id, filter, cache)
}

///|
/// 全局谓词下推引擎（Predicate Pushdown Filtering Engine）。
/// 遍历 namespace 下全部 segment：
/// 1. stats 预判整段跳过；
/// 2. 向量化列式求值 Filter AST，生成存活行 BitSet；
/// 3. 原地消除已软删除 (tombstone) 文档；
/// 4. 统计选择率并构建全局 allowed Doc ID Set。
pub async fn[S : @store.ObjectStore] eval_pushdown_filter(
  n : Namespace[S],
  filter : Filter,
) -> MatchedDocSet {
  let total_docs = n.manifest.num_docs
  let tomb = tombstones_of(n)
  let seg_bitsets : Map[String, BitSet] = Map([])
  let allowed_ids : Set[UInt64] = Set([])
  let mut total_matched = 0

  for si in 0..<n.manifest.segments.length() {
    let seg = n.manifest.segments[si]
    let cs = ensure_seg(n, si)
    if !(seg_may_match(cs, Some(filter))) {
      continue
    }
    let col_cache : Map[String, ColumnValues] = Map([])
    let bs = eval_filter_columnar_with_cache(n, cs, seg.id, filter, col_cache)
    // 剔除 tombstone
    if !(tomb.is_empty()) {
      let rows = bs.to_rows()
      for r in rows {
        let id = row_id(n, cs, seg.id, r)
        if tomb.contains(id) {
          bs.unset(r)
        }
      }
    }
    let cnt = bs.count()
    if cnt > 0 {
      total_matched += cnt
      seg_bitsets.set(seg.id, bs)
      let rows = bs.to_rows()
      for r in rows {
        let id = row_id(n, cs, seg.id, r)
        allowed_ids.add(id)
      }
    }
  }

  let selectivity = if total_docs > 0 {
    total_matched.to_double() / total_docs.to_double()
  } else {
    0.0
  }

  {
    total_matched,
    total_docs,
    selectivity,
    seg_bitsets,
    allowed_ids,
  }
}


pub extend BitSet with Debug::{to_repr}
