// BM25 读路径（spec 局部性语义）：
//
// query tokenize → 对 manifest.segments 每个 segment：
//   GET seg meta.json（row_count）→ GET fts/dir.bin（decode_fts_dir）→
//   命中 term 用 store.get_range(postings.bin, offset=16+entry.offset, len=entry.size)
//   拉局部 posting（16 = postings.bin 的 SPNDPOS1 头，见 NOTES 第 2 节）→
//   自写 delta-uvarint 解码（range 读回的字节没有 SPNDPOS1 头，read_postings 不适用）→
//   GET fts/doc_len.bin → okapi 打分（df/term/segment，N = segment.row_count，
//   avgdl = manifest.avg_doc_len，k1/b 来自 namespace.json）。
// per-segment top-k → 跨 segment 合并 → row→id → tombstone → top-k。
// Filter 在打分阶段按段内行号过滤（列整读，MVP 全扫），先于 row→id。

///|
/// 过滤列的行级匹配器：列一次性解码为数组，按行号判断。
enum RowMatcher {
  MStr(Array[String], String)
  MBool(Array[Bool], Bool)
  MI64(Array[Int64], Int64)
}

///|
fn filter_field(f : Filter) -> String {
  match f {
    FStr(field, _) => field
    FBool(field, _) => field
    FI64(field, _) => field
  }
}

///|
/// 加载某 segment 的过滤列并按 Filter 类型校验 dtype。
fn load_matcher[S : @store.ObjectStore](
  n : Namespace[S],
  seg_id : String,
  f : Filter,
) -> RowMatcher raise @core.SpndError {
  let key = "\{n.ns}/_segments/\{seg_id}/rows/\{filter_field(f)}.bin"
  let cd = read_col(n, key)
  match (f, cd) {
    (FStr(_, v), @format.ColStr(arr)) => MStr(arr, v)
    (FBool(_, v), @format.ColBool(arr)) => MBool(arr, v)
    (FI64(_, v), @format.ColI64(arr)) => MI64(arr, v)
    _ => raise @core.Corrupt("filter column dtype mismatch for \{filter_field(f)}")
  }
}

///|
fn matcher_at(m : RowMatcher, row : Int) -> Bool {
  match m {
    MStr(arr, v) =>
      match arr.get(row) {
        Some(x) => x == v
        None => false
      }
    MBool(arr, v) =>
      match arr.get(row) {
        Some(x) => x == v
        None => false
      }
    MI64(arr, v) =>
      match arr.get(row) {
        Some(x) => x == v
        None => false
      }
  }
}

///|
/// 解码 get_range 拉回的 posting 区间（无 SPNDPOS1 头）：
/// repeated (row_delta uvarint + tf uvarint)，首 delta = row+1（prev 初始 -1）。
fn decode_posting_slice(bs : Bytes) -> Array[@format.Posting] raise @core.SpndError {
  let out : Array[@format.Posting] = Array::new()
  let mut prev = -1
  let mut pos = 0
  let len = bs.length()
  while pos < len {
    let (delta, p1) = @core.read_uvarint(bs, pos)
    let (tf, p2) = @core.read_uvarint(bs, p1)
    prev = prev + delta.to_int()
    out.push({ row: prev, tf: tf.to_int() })
    pos = p2
  }
  out
}

///|
/// 在 fts 目录（按 String::compare 升序）中二分查找 term。
fn find_entry(
  entries : Array[@format.FtsDirEntry],
  term : String,
) -> @format.FtsDirEntry? {
  let mut lo = 0
  let mut hi = entries.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    let c = entries[mid].term.compare(term)
    if c == 0 {
      return Some(entries[mid])
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
/// 单 segment 的 BM25 候选：返回 (row, score) 降序 top-k。
fn bm25_segment[S : @store.ObjectStore](
  n : Namespace[S],
  seg : @format.SegmentMeta,
  terms : Array[String],
  avgdl : Double,
  k1 : Double,
  b : Double,
  k : Int,
  filter : Filter?,
) -> Array[(Int, Double)] raise @core.SpndError {
  let base = "\{n.ns}/_segments/\{seg.id}"
  let meta_bs = get_object(n.store, "\{base}/meta.json")
  let (row_count, _) = parse_seg_meta(meta_bs)
  let dir_bs = get_object(n.store, "\{base}/fts/dir.bin")
  let entries = @format.decode_fts_dir(dir_bs)
  // 先解析全部命中 term；无命中则不再读 doc_len / postings
  let matched : Array[@format.FtsDirEntry] = Array::new()
  for t in terms {
    match find_entry(entries, t) {
      Some(e) => matched.push(e)
      None => ()
    }
  }
  if matched.is_empty() {
    return []
  }
  let matcher : RowMatcher? = match filter {
    Some(f) => Some(load_matcher(n, seg.id, f))
    None => None
  }
  let doc_len = match read_col(n, "\{base}/fts/doc_len.bin") {
    @format.ColU32(arr) => arr
    _ => raise @core.Corrupt("doc_len column dtype is not u32")
  }
  let scores : Map[Int, Double] = Map::new()
  for e in matched {
    // 只拉 term 的局部 posting 区间（外层 16 = SPNDPOS1 头）
    let slice = match n.store.get_range("\{base}/fts/postings.bin", 16 + e.offset, e.size) {
      Some(x) => x
      None => raise @core.NotFound("\{base}/fts/postings.bin range")
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
  let arr : Array[(Int, Double)] = Array::new()
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
/// BM25 检索：per-segment top-k → 合并 → tombstone → top-k（score 降序）。
pub fn bm25_search[S : @store.ObjectStore](
  n : Namespace[S],
  query : String,
  k : Int,
  filter : Filter?,
) -> Array[QueryResult] raise @core.SpndError {
  let terms = dedupe_terms(@core.tokenize(query))
  if terms.is_empty() || k <= 0 {
    return []
  }
  let tomb = tombstone_set(n.manifest)
  let cands : Array[(Int, Int, Double)] = Array::new()
  for si in 0..<n.manifest.segments.length() {
    let seg = n.manifest.segments[si]
    for c in bm25_segment(n, seg, terms, n.manifest.avg_doc_len, n.meta.k1, n.meta.b, k, filter) {
      cands.push((si, c.0, c.1))
    }
  }
  results_from_candidates(n, cands, tomb, k)
}
