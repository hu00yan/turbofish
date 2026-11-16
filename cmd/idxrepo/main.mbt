// idxrepo：用「大 repo 真实代码」作为数据集，构建 seekpond/v1 索引并验证
// BM25 + 向量检索。
//
// 数据集：IDX_ROOT 目录树下全部文本源码，按 60 行一块切块（换行对齐）：
//   id       = FNV-1a64("<relpath>:<start_line>")   UInt64
//   text     = 代码块
//   category = 扩展名（rs/mbt/toml/…）
//   ts       = 文件 mtime
//   vector   = 128 维确定性 hash embedding：@core.tokenize 的每个 term 用
//              FNV-1a64 落桶（mixed % dim）+ 词频累加，L2 归一化（无随机数）
//
// 构建：@build.ingest（首批）+ @build.ingest_delta_opts(max_deltas=0,
//       auto_compact=false)（后续批）+ compact_global + compact（多段时合并）。
//       BuildConfig::single_copy + nlist=256, segment_rows=2000，
//       fts_tokenizer 默认 Word（代码 ASCII 为主）。BENCH 式批次：IDX_BATCH。
// 存储：@s3store.S3Store + @s3http.CurlTransport → MinIO 直连
//       （127.0.0.1:9000，不走 toxiproxy）。
// 查询：每查询 @query.open + bm25_search / vec_search；CountingTransport 在
//       transport 层计 GET 数；@bench 单调钟测 p50/p99（每查询多次采样，
//       每次 open+search 全新计）。
//
// 环境变量：
//   IDX_ROOT          语料根目录（必需）
//   IDX_NS            namespace（默认 idxrepo）
//   IDX_BATCH         每批 docs 数（默认 2000）
//   IDX_CHUNK         每块行数（默认 60）
//   IDX_DIM           向量维度（默认 128）
//   IDX_NPROBE        vec_search nprobe（默认 32）
//   IDX_K             top-k（默认 5）
//   IDX_RUNS          每查询采样次数（默认 10）
//   IDX_QUERIES       分号分隔的查询；缺省用内置 5 条
//   IDX_FRESH         默认 1：构建前清空 namespace 下旧对象
//   IDX_SKIP_BUILD=1  跳过构建只查询
//   S3_ENDPOINT       默认 http://127.0.0.1:9000（MinIO 直连）
//   S3_BUCKET         默认 seekpond
//   S3_REGION         默认 us-east-1
//   S3_ACCESS_KEY / S3_SECRET_KEY  默认 minioadmin/minioadmin

///|
struct Chunk {
  id : UInt64
  ext : String
  mtime : Int64
  text : String
}

///|
fn env_or(key : String, fallback : String) -> String {
  match @env.get_env_var(key) {
    Some(v) => v
    None => fallback
  }
}

///|
fn need_env(key : String) -> String raise @core.SpndError {
  match @env.get_env_var(key) {
    Some(v) => v
    None => raise @core.Corrupt("missing env \{key}")
  }
}

///|
fn parse_int(s : String) -> Int? {
  let mut n = 0
  let mut any = false
  for ch in s.iter() {
    if ch >= '0' && ch <= '9' {
      n = n * 10 + (ch.to_int() - 48)
      any = true
    } else {
      return None
    }
  }
  if any {
    Some(n)
  } else {
    None
  }
}

///|
fn env_int(key : String, fallback : Int) -> Int {
  match @env.get_env_var(key) {
    Some(v) =>
      match parse_int(v) {
        Some(n) => n
        None => fallback
      }
    None => fallback
  }
}

///|
fn err_msg(e : Error) -> String {
  match e {
    @core.BadMagic(s) => "BadMagic(\{s})"
    @core.Truncated(s) => "Truncated(\{s})"
    @core.Corrupt(s) => "Corrupt(\{s})"
    @core.NotFound(s) => "NotFound(\{s})"
    @core.CommitConflict(s) => "CommitConflict(\{s})"
    _ => "\{e}"
  }
}

///|
fn cstr(s : String) -> Bytes {
  let b = Buffer()
  b.write_string_utf8(s)
  b.write_byte(b'\x00')
  b.to_bytes()
}

///|
/// Buffer 内容按 UTF-8 解码为 String（Buffer::to_string 走 Show，
/// 不做 UTF-8 解码，repo 内一律用 to_bytes + @utf8.decode）。
fn buf_to_str(b : Buffer) -> String {
  @utf8.decode(b.to_bytes().exact_view()) catch {
    _ => ""
  }
}

///|
fn now_us() -> Double {
  idxfs_now_us().to_double()
}

///|
fn imin(a : Int, b : Int) -> Int {
  if a < b {
    a
  } else {
    b
  }
}

///|
/// FNV-1a 64-bit（UTF-8 字节）。
fn fnv1a64(s : String) -> UInt64 {
  let b = Buffer()
  b.write_string_utf8(s)
  let bs = b.to_bytes()
  let mut h : UInt64 = 0xcbf29ce484222325UL
  for i in 0..<bs.length() {
    h = h ^ bs[i].to_uint64()
    h = h * 0x100000001b3UL
  }
  h
}

///|
/// 确定性 hash embedding：term → FNV-1a64 → 高低位混合 → % dim 落桶，
/// 词频累加后 L2 归一化。无随机数，同文本必得同向量。
fn embed(text : String, dim : Int) -> Array[Float] {
  let counts : Array[Double] = Array::make(dim, 0.0)
  let dim_u : UInt64 = dim.to_uint64()
  for term in @core.tokenize(text) {
    let h = fnv1a64(term)
    let mixed = h ^ (h >> 32)
    let b = (mixed % dim_u).to_int()
    if b >= 0 && b < dim {
      counts[b] += 1.0
    }
  }
  let mut s = 0.0
  for i in 0..<dim {
    s = s + counts[i] * counts[i]
  }
  let norm = s.sqrt()
  let v : Array[Float] = Array(capacity=dim)
  for i in 0..<dim {
    let x = if norm > 0.0 {
      counts[i] / norm
    } else {
      0.0
    }
    v.push(Float::from_double(x))
  }
  v
}

///|
fn trim_str(s : String) -> String {
  let cs = s.to_array()
  let mut lo = 0
  let mut hi = cs.length()
  while lo < hi && (cs[lo] == ' ' || cs[lo] == '\t' || cs[lo] == '\r') {
    lo += 1
  }
  while hi > lo &&
        (cs[hi - 1] == ' ' || cs[hi - 1] == '\t' || cs[hi - 1] == '\r') {
    hi -= 1
  }
  let b = Buffer()
  for i in lo..<hi {
    b.write_char_utf8(cs[i])
  }
  buf_to_str(b)
}

///|
/// 首个非空行的截断片段（≤max_chars 字符）。
fn first_line_snippet(text : String, max_chars : Int) -> String {
  for ln in split_lines(text) {
    let t = trim_str(ln)
    if t != "" {
      let cs = t.to_array()
      let b = Buffer()
      let n = imin(cs.length(), max_chars)
      for i in 0..<n {
        b.write_char_utf8(cs[i])
      }
      if cs.length() > max_chars {
        b.write_string_utf8("...")
      }
      return buf_to_str(b)
    }
  }
  ""
}

///|
fn split_lines(s : String) -> Array[String] {
  let lines : Array[String] = Array()
  let b = Buffer()
  for ch in s.iter() {
    if ch == '\n' {
      lines.push(buf_to_str(b))
      b.reset()
    } else {
      b.write_char_utf8(ch)
    }
  }
  if b.length() > 0 {
    lines.push(buf_to_str(b))
  }
  lines
}

///|
fn join_lines(lines : Array[String], lo : Int, hi : Int) -> String {
  let b = Buffer()
  for i in lo..<hi {
    if i > lo {
      b.write_char_utf8('\n')
    }
    b.write_string_utf8(lines[i])
  }
  buf_to_str(b)
}

///|
/// 小写扩展名（无扩展名返回 ""）。
fn ext_of(path : String) -> String {
  let cs = path.to_array()
  let mut dot = -1
  let mut slash = -1
  for i in 0..<cs.length() {
    let c = cs[i]
    if c == '/' {
      slash = i
      dot = -1
    }
    if c == '.' {
      dot = i
    }
  }
  if dot < 0 || dot <= slash || dot == cs.length() - 1 {
    return ""
  }
  let b = Buffer()
  for i in (dot + 1)..<cs.length() {
    b.write_char_utf8(cs[i])
  }
  buf_to_str(b).to_lower()
}

///|
fn wanted_ext(ext : String) -> Bool {
  // 代码/文档为主；纯日志文本（wrk.txt/raw.txt/rss.txt 等 bench 产物）
  // 不算代码，排除以免污染检索。
  match ext {
    "rs" | "mbt" | "mbti" | "c" | "h" | "go" | "py" | "toml" | "md" | "json" | "sh" | "yml" | "yaml" | "mk" =>
      true
    _ => false
  }
}

///|
fn rel_of(path : String, root : String) -> String {
  let pl = root.length() + 1
  if path.length() > pl {
    let head = path[0:pl].to_owned()
    if head == root + "/" {
      return path[pl:].to_owned()
    }
  }
  path
}

///|
fn base_name(p : String) -> String {
  let cs = p.to_array()
  let mut last = -1
  for i in 0..<cs.length() {
    if cs[i] == '/' {
      last = i
    }
  }
  if last < 0 || last == cs.length() - 1 {
    return p
  }
  let b = Buffer()
  for i in (last + 1)..<cs.length() {
    b.write_char_utf8(cs[i])
  }
  buf_to_str(b)
}

///|
struct CorpusStats {
  mut files : Int
  mut skipped : Int
  mut lines : Int
  mut text_bytes : Int
}

///|
/// 收集一个根目录下的全部 chunk（IDX_ROOT colon 分隔多根时逐根调用）。
fn collect_root(
  root : String,
  chunk_lines : Int,
  chunks : Array[Chunk],
  locs : Map[UInt64, String],
  snips : Map[UInt64, String],
  st : CorpusStats,
) -> Unit {
  let need = idxfs_walk(cstr(root), FixedArray::make(0, b'\x00'), 0)
  if need <= 0 {
    println("  WARNING: walk returned no files for \{root}")
    return
  }
  let buf : FixedArray[Byte] = FixedArray::make(need, b'\x00')
  let _ = idxfs_walk(cstr(root), buf, need)
  let walk_str = @utf8.decode(Bytes::from_array(buf.exact_view()).exact_view()) catch {
    _ => ""
  }
  let rel_prefix = base_name(root) + "/"
  for piece in walk_str.split("\n") {
    let p = piece.to_owned()
    if p == "" {
      continue
    }
    st.files += 1
    let ext = ext_of(p)
    if env_or("IDX_DEBUG", "0") == "1" {
      println("    file: \{p} ext=[\{ext}] wanted=\{wanted_ext(ext)}")
    }
    if !wanted_ext(ext) {
      st.skipped += 1
      continue
    }
    // 自排除：索引工具自己的代码不进语料（查询词都在 main.mbt 里，
    // 不排除的话 BM25 top1 永远是自己）。
    if p.find("/cmd/idxrepo/") is Some(_) {
      st.skipped += 1
      continue
    }
    let size = idxfs_file_size(cstr(p))
    if size <= 0 || size > 1000000 {
      println("    skip(size=\{size}): \{p}")
      st.skipped += 1
      continue
    }
    let content = match read_file(p, size) {
      Some(s) => s
      None => {
        println("    skip(read/decode): \{p}")
        st.skipped += 1
        ""
      }
    }
    if content == "" {
      continue
    }
    let rel = rel_prefix + rel_of(p, root)
    let mtime = idxfs_file_mtime(cstr(p))
    let lines = split_lines(content)
    let mut li = 0
    while li < lines.length() {
      let hi = imin(li + chunk_lines, lines.length())
      let text = join_lines(lines, li, hi)
      if @core.tokenize(text).length() > 0 {
        let start_line = li + 1
        let id = fnv1a64("\{rel}:\{start_line}")
        chunks.push({
          id,
          ext,
          mtime,
          text,
        })
        st.lines += hi - li
        st.text_bytes += text.length()
        locs.set(id, "\{rel}:\{start_line}-\{hi}")
        snips.set(id, first_line_snippet(text, 90))
      }
      li = hi
    }
  }
}

///|
/// 读文件并按 UTF-8 解码；失败（含非文本）返回 None。
fn read_file(path : String, size : Int) -> String? {
  let buf : FixedArray[Byte] = FixedArray::make(size, b'\x00')
  let n = idxfs_read_file(cstr(path), buf, size)
  if n <= 0 {
    return None
  }
  let bs = Bytes::from_array(buf.exact_view(start=0, end=n))
  let s = @utf8.decode(bs.exact_view()) catch {
    _ => ""
  }
  if s == "" {
    // n>0 但解码为空 ⇒ 非 UTF-8（二进制）文件，跳过
    None
  } else {
    Some(s)
  }
}

///|
/// 计数存储包装：委托纯 MoonBit 异步 `@s3client.S3Client`，在方法层计数
/// GET / PUT / 写入字节（替代旧的 `@s3http.CurlTransport` transport 计数）。
pub struct CountingStore {
  inner : @s3client.S3Client
  mut gets : Int
  mut puts : Int
  mut put_bytes : Int
}

///|
fn CountingStore::new(inner : @s3client.S3Client) -> CountingStore {
  { inner, gets: 0, puts: 0, put_bytes: 0 }
}

///|
fn CountingStore::reset(self : CountingStore) -> Unit {
  self.gets = 0
  self.puts = 0
  self.put_bytes = 0
}

///|
pub impl @store.ObjectStore for CountingStore with get(self, key) {
  self.gets += 1
  @s3client.S3Client::get(self.inner, key)
}

///|
pub impl @store.ObjectStore for CountingStore with put(self, key, bs) {
  self.puts += 1
  self.put_bytes += bs.length()
  @s3client.S3Client::put(self.inner, key, bs)
}

///|
pub impl @store.ObjectStore for CountingStore with put_if_match(self, key, expected : @store.Expected, bs) {
  self.puts += 1
  self.put_bytes += bs.length()
  @s3client.S3Client::conditional_put(self.inner, key, bs, expected.0)
}

///|
pub impl @store.ObjectStore for CountingStore with get_range(self, key, br : @store.ByteRange) {
  let offset = br.off
  let len = br.len
  self.gets += 1
  @s3client.S3Client::fetch_range(self.inner, key, offset, len)
}

///|
pub impl @store.ObjectStore for CountingStore with list(self, prefix) {
  @s3client.S3Client::list(self.inner, prefix)
}

///|
pub impl @store.ObjectStore for CountingStore with delete(self, key) {
  @s3client.S3Client::delete(self.inner, key)
}

///|
pub impl @store.ObjectStore for CountingStore with head_version(self, key) {
  @s3client.S3Client::head_version(self.inner, key)
}

// 便捷方法转发。
pub extend CountingStore with @store.ObjectStore::{
  get,
  get_range,
  put,
  put_if_match,
  list,
  delete,
  head_version,
}

///|
/// 桶可用性探测（新版 MinIO 不自动建桶；失败只告警）。
async fn CountingStore::bucket_ready(self : CountingStore) -> Bool {
  let probe = try {
    Ok(@s3client.S3Client::list(self.inner, ""))
  } catch {
    e => Err(e)
  }
  match probe {
    Ok(_) => true
    Err(e) => {
      println("  WARNING: bucket LIST failed: \{err_msg(e)}")
      false
    }
  }
}

///|
fn fmt_f(x : Double, digits : Int) -> String {
  let mut scale = 1.0
  for _ in 0..<digits {
    scale = scale * 10.0
  }
  let n = (x * scale + 0.5).to_int()
  if digits == 0 {
    return n.to_string()
  }
  let whole = n / scale.to_int()
  let frac = n % scale.to_int()
  let fs = frac.to_string()
  let mut zs = ""
  for _ in 0..<(digits - fs.length()) {
    zs = zs + "0"
  }
  "\{whole}.\{zs}\{fs}"
}

///|
fn mean_i(a : Array[Int]) -> Double {
  let mut s = 0
  for x in a {
    s += x
  }
  if a.length() == 0 {
    0.0
  } else {
    s.to_double() / a.length().to_double()
  }
}

///|
/// 最近邻百分位（nearest-rank）。
fn pct_nearest(ts : Array[Double], p : Double) -> Double {
  let c = ts.copy()
  c.sort()
  let n = c.length()
  if n == 0 {
    return 0.0
  }
  let rank = ((p * n.to_double()) + 0.5).to_int()
  let idx = if rank < 1 {
    0
  } else if rank > n {
    n - 1
  } else {
    rank - 1
  }
  c[idx]
}

///|
fn chunk_to_doc(c : Chunk, dim : Int) -> @core.Doc {
  {
    id: c.id,
    text: c.text,
    vector: embed(c.text, dim),
    category: c.ext,
    ts: c.mtime,
    public: true,
  }
}

///|
fn default_queries() -> Array[String] {
  [
    "io_uring completion queue",
    "SigV4 canonical request",
    "kmeans centroid assignment",
    "separation logic frame rule",
    "PQ16 quantization",
  ]
}

///|
/// 单查询报告：BM25 + 向量各 runs 次「open + search」采样（GET 计数 + 延迟），
/// 首轮结果打印 top-k（位置 = 相对路径:起始行-结束行）。
async fn run_query(
  store : CountingStore,
  transport : CountingStore,
  ns : String,
  q : String,
  qv : Array[Float],
  k : Int,
  nprobe : Int,
  runs : Int,
  locs : Map[UInt64, String],
  snips : Map[UInt64, String],
) -> Unit {
  let bm_ts : Array[Double] = Array()
  let bm_gets : Array[Int] = Array()
  let mut bm_top : Array[@query.QueryResult] = Array()
  let vec_ts : Array[Double] = Array()
  let vec_gets : Array[Int] = Array()
  let mut vec_top : Array[@query.QueryResult] = Array()
  for r in 0..<runs {
    transport.reset()
    let t0 = now_us()
    let n = @query.open(store, ns)
    let rs = @query.bm25_search(n, q, k, None)
    let dt = now_us() - t0
    bm_ts.push(dt)
    bm_gets.push(transport.gets)
    if r == 0 {
      bm_top = rs
    }
  }
  for r in 0..<runs {
    transport.reset()
    let t0 = now_us()
    let n = @query.open(store, ns)
    let rs = @query.vec_search(n, qv, k, nprobe, None)
    let dt = now_us() - t0
    vec_ts.push(dt)
    vec_gets.push(transport.gets)
    if r == 0 {
      vec_top = rs
    }
  }
  println("[q] \"\{q}\"")
  println(
    "  bm25: GET/q=\{fmt_f(mean_i(bm_gets), 1)} p50=\{fmt_f(pct_nearest(bm_ts, 0.5) / 1000.0, 2)}ms p99=\{fmt_f(pct_nearest(bm_ts, 0.99) / 1000.0, 2)}ms (\{runs} runs)",
  )
  let mut rank = 0
  for r in bm_top {
    rank += 1
    let loc = match locs.get(r.id) {
      Some(l) => l
      None => "?"
    }
    let sn = match snips.get(r.id) {
      Some(s) => s
      None => ""
    }
    println("    \{rank}. \{fmt_f(r.score, 4)}  \{loc}  | \{sn}")
  }
  println(
    "  vec:  GET/q=\{fmt_f(mean_i(vec_gets), 1)} p50=\{fmt_f(pct_nearest(vec_ts, 0.5) / 1000.0, 2)}ms p99=\{fmt_f(pct_nearest(vec_ts, 0.99) / 1000.0, 2)}ms (nprobe=\{nprobe}, \{runs} runs)",
  )
  rank = 0
  for r in vec_top {
    rank += 1
    let loc = match locs.get(r.id) {
      Some(l) => l
      None => "?"
    }
    let sn = match snips.get(r.id) {
      Some(s) => s
      None => ""
    }
    println("    \{rank}. \{fmt_f(r.score, 4)}  \{loc}  | \{sn}")
  }
}

///|
async fn run() -> Unit {
  let root = need_env("IDX_ROOT")
  let ns = env_or("IDX_NS", "idxrepo")
  let batch_size = env_int("IDX_BATCH", 2000)
  let chunk_lines = env_int("IDX_CHUNK", 60)
  let dim = env_int("IDX_DIM", 128)
  let nprobe = env_int("IDX_NPROBE", 32)
  let k = env_int("IDX_K", 5)
  let runs = env_int("IDX_RUNS", 10)
  let fresh = env_or("IDX_FRESH", "1") != "0"
  let skip_build = env_or("IDX_SKIP_BUILD", "0") == "1"
  let endpoint = env_or("S3_ENDPOINT", "http://127.0.0.1:9000")
  let bucket = env_or("S3_BUCKET", "seekpond")
  let region = env_or("S3_REGION", "us-east-1")
  let access = env_or("S3_ACCESS_KEY", "minioadmin")
  let secret = env_or("S3_SECRET_KEY", "minioadmin")
  println("== idxrepo ==")
  println(
    "  root=\{root} ns=\{ns} batch=\{batch_size} chunk=\{chunk_lines}lines dim=\{dim}",
  )
  println(
    "  endpoint=\{endpoint} bucket=\{bucket} (MinIO 直连, 不经 toxiproxy)",
  )
  let client = @s3client.S3Client::new(
    endpoint,
    bucket,
    region,
    access,
    secret,
    max_inflight=16,
  )
  let transport = CountingStore::new(client)
  let store = transport
  if !store.bucket_ready() {
    println("  WARNING: bucket not ready (create it first: mc mb ...)")
  }
  if fresh && !skip_build {
    let olds = store.list("\{ns}/")
    for key in olds {
      store.delete(key)
    }
    if olds.length() > 0 {
      println("  cleaned old ns: \{olds.length()} objects")
    }
  }
  // ---- 收集语料 ----
  let chunks : Array[Chunk] = Array()
  let locs : Map[UInt64, String] = Map([])
  let snips : Map[UInt64, String] = Map([])
  if !skip_build {
    // IDX_ROOT 支持 colon 分隔多根（如 rust-miniss:turbofish:moonbit-core），
    // rel 路径带上根目录 basename，避免跨 repo 撞 id。
    let roots : Array[String] = Array()
    for piece in root.split(":") {
      let mut t = trim_str(piece.to_owned())
      while t.has_suffix("/") {
        t = t[:t.length() - 1].to_owned()
      }
      if t != "" {
        roots.push(t)
      }
    }
    if roots.length() == 0 {
      raise @core.Corrupt("IDX_ROOT empty")
    }
    let st : CorpusStats = { files: 0, skipped: 0, lines: 0, text_bytes: 0 }
    for r in roots {
      collect_root(r, chunk_lines, chunks, locs, snips, st)
    }
    println(
      "  corpus: roots=\{roots.length()} files=\{st.files} kept_chunks=\{chunks.length()} lines=\{st.lines} text=\{fmt_f(st.text_bytes.to_double() / 1048576.0, 2)}MB (skipped_files=\{st.skipped})",
    )
    if chunks.length() == 0 {
      raise @core.NotFound("no indexable chunks under \{root}")
    }
  } else {
    println("  IDX_SKIP_BUILD=1：跳过构建，直接查询（locs 表为空）")
  }
  // ---- 构建 ----
  let cfg : @build.BuildConfig = {
    ..@build.BuildConfig::single_copy(ns),
    nlist: 256,
    segment_rows: 2000,
    vector_dim: dim,
  }
  if !skip_build {
    let build_t0 = now_us()
    let mut built = 0
    let mut batch_no = 0
    let mut put_bytes_total = 0
    while built < chunks.length() {
      let hi = imin(built + batch_size, chunks.length())
      let batch : Array[@core.Doc] = Array(capacity=hi - built)
      for i in built..<hi {
        batch.push(chunk_to_doc(chunks[i], dim))
      }
      transport.reset()
      let t0 = now_us()
      if batch_no == 0 {
        @build.ingest(store, cfg, batch)
      } else {
        @build.ingest_delta_opts(store, cfg, batch, 0, false)
      }
      let dt = now_us() - t0
      put_bytes_total += transport.put_bytes
      println(
        "  batch \{batch_no + 1}: \{batch.length()} docs \{fmt_f(dt / 1000.0, 1)}ms puts=\{transport.puts} put_bytes=\{fmt_f(transport.put_bytes.to_double() / 1048576.0, 2)}MB",
      )
      built = hi
      batch_no += 1
    }
    if batch_no > 1 {
      transport.reset()
      let t0 = now_us()
      @build.compact_global(store, cfg, ns)
      let dt = now_us() - t0
      put_bytes_total += transport.put_bytes
      println(
        "  compact_global: \{fmt_f(dt / 1000.0, 1)}ms puts=\{transport.puts} put_bytes=\{fmt_f(transport.put_bytes.to_double() / 1048576.0, 2)}MB",
      )
    }
    let n0 = @query.open(store, ns)
    let segs = n0.manifest.segments.length()
    if segs > 1 {
      transport.reset()
      let t0 = now_us()
      @build.compact(store, cfg, ns)
      let dt = now_us() - t0
      put_bytes_total += transport.put_bytes
      println(
        "  compact: \{segs} segments -> 1 \{fmt_f(dt / 1000.0, 1)}ms put_bytes=\{fmt_f(transport.put_bytes.to_double() / 1048576.0, 2)}MB",
      )
    }
    let build_ms = now_us() - build_t0
    // 索引规模：objects + live bytes（逐对象 GET 累计 payload；顺带验证可读）
    let keys = store.list("\{ns}/")
    transport.reset()
    let mut live_bytes = 0
    for key in keys {
      match store.get(key) {
        Some(b) => live_bytes += b.length()
        None => ()
      }
    }
    println(
      "  index: docs=\{chunks.length()} objects=\{keys.length()} live=\{fmt_f(live_bytes.to_double() / 1048576.0, 2)}MB put_payload_total=\{fmt_f(put_bytes_total.to_double() / 1048576.0, 2)}MB build=\{fmt_f(build_ms / 1000.0, 2)}s",
    )
  }
  // ---- 查询验证 ----
  let queries : Array[String] = match @env.get_env_var("IDX_QUERIES") {
    Some(s) => {
      let qs : Array[String] = Array()
      for piece in s.split(";") {
        let t = trim_str(piece.to_owned())
        if t != "" {
          qs.push(t)
        }
      }
      if qs.length() > 0 {
        qs
      } else {
        default_queries()
      }
    }
    None => default_queries()
  }
  println("== queries (\{queries.length()} x bm25/vec, k=\{k}, runs=\{runs}) ==")
  let mut qi = 0
  for q in queries {
    qi += 1
    let qv = embed(q, dim)
    run_query(store, transport, ns, q, qv, k, nprobe, runs, locs, snips)
    let _ = qi
  }
  println("IDXREPO OK")
}

///|
async fn main {
  try {
    run()
  } catch {
    e => println("IDXREPO FAILED: \{err_msg(e)}")
  }
}
