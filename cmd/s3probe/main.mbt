// 真实 S3/MinIO 端到端探针（native + libcurl）。
//
// 环境变量：
//   S3_ENDPOINT   http://127.0.0.1:19000（toxiproxy → MinIO）
//   S3_BUCKET     seekpond
//   S3_REGION     us-east-1
//   S3_ACCESS_KEY / S3_SECRET_KEY
//
// 流程：put/get/get_range/list/put_if_match/delete → 两组 build+query 对照：
//   baseline : 旧布局（per-segment vector/parts）+ 每查询 open
//   optimized: BuildConfig::single_copy（global IVF + normalize + bloom）
//              + MetadataCache/open_cached
// 统计每种查询的 p50 和 HTTP 请求数。
//
// R2 计费口径（https://developers.cloudflare.com/r2/pricing/）：
//   Class A $4.50/1M：PutObject/PutBucket/POST/ListObjects(ListObjectsV2)/CopyObject 等
//   Class B $0.36/1M：GetObject/HeadObject/HeadBucket/GetBucketLocation 等
//   免费：DeleteObject/DeleteBucket/AbortMultipartUpload
// CountingTransport 按 HTTP method + LIST 查询特征分类，并按场景输出
// 次数 × 单价 = $ 的成本表（baseline vs optimized）。

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
fn err_msg(e : @core.SpndError) -> String {
  match e {
    @core.BadMagic(s) => "BadMagic(\{s})"
    @core.Truncated(s) => "Truncated(\{s})"
    @core.Corrupt(s) => "Corrupt(\{s})"
    @core.NotFound(s) => "NotFound(\{s})"
    @core.CommitConflict(s) => "CommitConflict(\{s})"
  }
}

///|
fn mkdocs(n : Int, dim : Int) -> Array[@core.Doc] {
  let rng = @core.Rng::new(7U)
  let words = ["alpha", "beta", "gamma", "delta", "向量", "检索"]
  let docs : Array[@core.Doc] = Array::new(capacity=n)
  for i in 0..<n {
    let mut text = ""
    for _ in 0..<6 {
      let w = words[(rng.next_u32() % words.length().reinterpret_as_uint()).reinterpret_as_int()]
      text = text + w + " "
    }
    let v : Array[Float] = Array::new(capacity=dim)
    for _ in 0..<dim {
      v.push(Float::from_double(rng.next_range(-1.0, 1.0)))
    }
    docs.push({
      id: i.to_uint64(),
      text,
      vector: v,
      category: "cat\{i % 3}",
      ts: (1700000000 + i).to_int64(),
      public: i % 3 != 0,
    })
  }
  docs
}

///|
/// R2 计费单价（每 100 万次请求，USD）：
///   Class A（List/Put/Copy/Post 等"改状态"操作）$4.50
///   Class B（Get/Head 等"读状态"操作）$0.36
///   Delete 类操作免费（DeleteObject/DeleteBucket/AbortMultipartUpload）
/// 来源：https://developers.cloudflare.com/r2/pricing/
const R2_CLASS_A_USD_PER_M : Double = 4.50

///|
const R2_CLASS_B_USD_PER_M : Double = 0.36

///|
/// 按操作类型累计的请求数（cumulative，不受 reset 影响）。
/// 分类规则（R2 口径，按 HTTP method + 查询特征）：
///   PUT  → PutObject/PutBucket（Class A）
///   POST →（Class A；本探针目前不产生 POST，保留口径）
///   GET  + ?list-type=… → ListObjectsV2（Class A）
///   GET  其它 → GetObject/GetBucketLocation（Class B）
///   HEAD → HeadObject/HeadBucket（Class B）
///   DELETE → DeleteObject（免费，单列）
struct OpCounts {
  mut puts : Int
  mut posts : Int
  mut lists : Int
  mut gets : Int
  mut heads : Int
  mut deletes : Int
}

///|
fn OpCounts::new() -> OpCounts {
  { puts: 0, posts: 0, lists: 0, gets: 0, heads: 0, deletes: 0 }
}

///|
/// after - before（场景级 delta）
fn OpCounts::delta(before : OpCounts, after : OpCounts) -> OpCounts {
  {
    puts: after.puts - before.puts,
    posts: after.posts - before.posts,
    lists: after.lists - before.lists,
    gets: after.gets - before.gets,
    heads: after.heads - before.heads,
    deletes: after.deletes - before.deletes,
  }
}

///|
fn OpCounts::class_a(self : OpCounts) -> Int {
  self.puts + self.posts + self.lists
}

///|
fn OpCounts::class_b(self : OpCounts) -> Int {
  self.gets + self.heads
}

///|
/// 计数 HTTP transport：委托 CurlTransport，并记录请求数/响应字节 +
/// R2 Class A/B 计费口径的操作分类（cum_* 累计，reset 不清零）。
struct CountingTransport {
  inner : @s3http.CurlTransport
  mut reqs : Int
  mut gets : Int
  mut puts : Int
  mut bytes : Int
  mut head_reqs : Int
  cum : OpCounts
}

///|
fn CountingTransport::new(inner : @s3http.CurlTransport) -> CountingTransport {
  { inner, reqs: 0, gets: 0, puts: 0, bytes: 0, head_reqs: 0, cum: OpCounts::new() }
}

///|
fn CountingTransport::reset(self : CountingTransport) -> Unit {
  self.reqs = 0
  self.gets = 0
  self.puts = 0
  self.bytes = 0
  self.head_reqs = 0
}

///|
fn CountingTransport::cumulative(self : CountingTransport) -> OpCounts {
  {
    puts: self.cum.puts,
    posts: self.cum.posts,
    lists: self.cum.lists,
    gets: self.cum.gets,
    heads: self.cum.heads,
    deletes: self.cum.deletes,
  }
}

///|
pub impl @s3store.HttpTransport for CountingTransport with fn execute(
  self : CountingTransport,
  http_method : String,
  url : String,
  headers : Array[(String, String)],
  body : Bytes,
) -> (Int, Array[(String, String)], Bytes) {
  self.reqs += 1
  match url.find("_heads") {
    Some(_) => self.head_reqs += 1
    None => ()
  }
  if http_method == "GET" {
    self.gets += 1
  } else if http_method == "PUT" {
    self.puts += 1
  }
  // R2 计费分类（cumulative）
  if http_method == "PUT" {
    self.cum.puts += 1
  } else if http_method == "POST" {
    self.cum.posts += 1
  } else if http_method == "DELETE" {
    self.cum.deletes += 1
  } else if http_method == "HEAD" {
    self.cum.heads += 1
  } else if http_method == "GET" {
    // ListObjectsV2：GET /{bucket}?list-type=2&…（GET 桶根 + list-type 查询）
    match url.find("list-type=") {
      Some(_) => self.cum.lists += 1
      None => self.cum.gets += 1
    }
  }
  let (st, hs, b) = self.inner.execute(http_method, url, headers, body)
  self.bytes += b.length()
  (st, hs, b)
}

///|
/// 右对齐填充 ASCII 空格（成本表列对齐用；表内全是 ASCII）
fn pad_right(s : String, w : Int) -> String {
  let n = s.length()
  if n >= w {
    return s
  }
  let mut out = s
  for _ in n..<w {
    out = out + " "
  }
  out
}

///|
/// 定点格式化（digits 位小数，四舍五入），避免 Double Show 的可变长度。
fn fmt_dec(x : Double, digits : Int) -> String {
  if digits <= 0 {
    return (x + 0.5).to_int().to_string()
  }
  let mut p = 1.0
  for _ in 0..<digits {
    p = p * 10.0
  }
  let n = (x * p + 0.5).to_int64()
  let pi = p.to_int64()
  let mut frac = (n % pi).to_int()
  let mut fbuf = ""
  for _ in 0..<digits {
    fbuf = "\{frac % 10}" + fbuf
    frac = frac / 10
  }
  "\{(n / pi).to_int()}.\{fbuf}"
}

///|
/// 输出单个场景的 R2 成本表：各操作次数 × 单价（$/1M）= 实际 $
fn print_r2_cost_table(label : String, c : OpCounts) -> Unit {
  let rows : Array[(String, Int, Double, String)] = [
    ("PUT   Class A", c.puts, R2_CLASS_A_USD_PER_M, "$4.50/1M"),
    ("POST  Class A", c.posts, R2_CLASS_A_USD_PER_M, "$4.50/1M"),
    ("LIST  Class A", c.lists, R2_CLASS_A_USD_PER_M, "$4.50/1M"),
    ("GET   Class B", c.gets, R2_CLASS_B_USD_PER_M, "$0.36/1M"),
    ("HEAD  Class B", c.heads, R2_CLASS_B_USD_PER_M, "$0.36/1M"),
    ("DELETE 免费", c.deletes, 0.0, "free"),
  ]
  println(
    "  [R2 成本表 \{label}] 次数 × 单价 = $（Class A $4.50/1M，Class B $0.36/1M，DELETE 免费）",
  )
  let mut total_usd = 0.0
  for r in rows {
    let usd = r.1.to_double() * r.2 / 1000000.0
    total_usd += usd
    println(
      "    \{pad_right(r.0, 14)} n=\{pad_right(r.1.to_string(), 6)} \{pad_right(r.3, 9)} $\{fmt_dec(usd, 6)}",
    )
  }
  let ca = c.class_a()
  let cb = c.class_b()
  let usd_a = ca.to_double() * R2_CLASS_A_USD_PER_M / 1000000.0
  let usd_b = cb.to_double() * R2_CLASS_B_USD_PER_M / 1000000.0
  println(
    "    合计: Class A=\{ca} ($\{fmt_dec(usd_a, 6)})  Class B=\{cb} ($\{fmt_dec(usd_b, 6)})  总计 $\{fmt_dec(total_usd, 6)}",
  )
}

///|
fn p50(ts : Array[Double]) -> Double {
  let c = ts.copy()
  c.sort()
  c[c.length() / 2]
}

///|
fn run_case(
  store : @s3store.S3Store[CountingTransport],
  transport : CountingTransport,
  label : String,
  docs : Array[@core.Doc],
  cfg : @build.BuildConfig,
  use_cache : Bool,
) -> Unit raise @core.SpndError {
  let ns = cfg.ns
  let c0 = transport.cumulative()
  transport.reset()
  let ti = @bench.monotonic_clock_start()
  @build.ingest(store, cfg, docs)
  let ti2 = @bench.monotonic_clock_end(ti)
  let ingest_heads = transport.head_reqs
  let cache : @query.MetadataCache[@s3store.S3Store[CountingTransport]] = @query.MetadataCache::new()
  let open_one = fn() -> @query.Namespace[@s3store.S3Store[CountingTransport]] raise @core.SpndError {
    if use_cache {
      @query.open_cached(cache, store, ns)
    } else {
      @query.open(store, ns)
    }
  }
  // 预热：优化路径首查询填充 metadata cache
  let n0 = open_one()
  let _ = @query.bm25_search(n0, "alpha", 5, None)
  let _ = @query.vec_search(n0, docs[0].vector, 5, 4, None)
  let bm_ts : Array[Double] = Array::new()
  let bm_req : Array[Int] = Array::new()
  let vec_ts : Array[Double] = Array::new()
  let vec_req : Array[Int] = Array::new()
  for _ in 0..<5 {
    transport.reset()
    let t0 = @bench.monotonic_clock_start()
    let n = open_one()
    let _ = @query.bm25_search(n, "alpha", 5, None)
    let dt = @bench.monotonic_clock_end(t0)
    bm_ts.push(dt)
    bm_req.push(transport.gets)
  }
  for _ in 0..<5 {
    transport.reset()
    let t0 = @bench.monotonic_clock_start()
    let n = open_one()
    let _ = @query.vec_search(n, docs[0].vector, 5, 4, None)
    let dt = @bench.monotonic_clock_end(t0)
    vec_ts.push(dt)
    vec_req.push(transport.gets)
  }
  let mut bm_r = 0
  for x in bm_req {
    bm_r += x
  }
  let mut vec_r = 0
  for x in vec_req {
    vec_r += x
  }
  println(
    "  [\{label}] ingest=\{ti2 / 1000.0}ms (head_reqs=\{ingest_heads}) | bm25 p50=\{p50(bm_ts) / 1000.0}ms GET/q=\{bm_r.to_double() / 5.0} | vec p50=\{p50(vec_ts) / 1000.0}ms GET/q=\{vec_r.to_double() / 5.0}",
  )
  for key in store.list("\{ns}/") {
    store.delete(key)
  }
  // 场景级 R2 成本表：ingest + 查询 + 清理全程的 HTTP 分类计数
  print_r2_cost_table(label, OpCounts::delta(c0, transport.cumulative()))
}

///|
fn run() -> Unit raise @core.SpndError {
  let endpoint = env_or("S3_ENDPOINT", "http://127.0.0.1:19000")
  let bucket = env_or("S3_BUCKET", "seekpond")
  let region = env_or("S3_REGION", "us-east-1")
  let access = need_env("S3_ACCESS_KEY")
  let secret = need_env("S3_SECRET_KEY")
  let transport = CountingTransport::new(@s3http.CurlTransport::new())
  let store = @s3store.S3Store::new(
    endpoint,
    bucket,
    region,
    { access_key: access, secret_key: secret },
    transport,
    fn() { @s3http.now_amz_date() },
  )
  let ns = "probe-\{@env.now()}"
  println(
    "== S3 probe: endpoint=\{endpoint} bucket=\{bucket} ns=\{ns} amz=\{@s3http.now_amz_date()}",
  )
  // 新版 MinIO 不自动建桶；create_bucket 幂等（已存在返回 409 也算成功）。
  if !store.create_bucket() {
    println("  WARNING: create_bucket failed (status != 200/409)")
  }
  let k = "\{ns}/hello.txt"
  store.put(k, b"hello s3")
  let got = match store.get(k) {
    Some(v) => v
    None => raise @core.NotFound(k)
  }
  println("  put/get: \{got.length()} bytes")
  let part = match store.get_range(k, 0, 5) {
    Some(v) => v
    None => raise @core.NotFound(k)
  }
  println("  get_range: \{part.length()} bytes")
  println("  list: \{store.list("\{ns}/").length()} keys")
  let ts : Array[Double] = Array::new()
  for _ in 0..<20 {
    let t0 = @bench.monotonic_clock_start()
    let _ = store.get(k)
    ts.push(@bench.monotonic_clock_end(t0))
  }
  ts.sort()
  println("  GET latency p50=\{ts[10]}µs p99=\{ts[19]}µs")
  let cas_new = store.put_if_match("\{ns}/cas.txt", None, b"v1")
  let ver = match store.head_version("\{ns}/cas.txt") {
    Some(v) => v
    None => "missing"
  }
  let cas_ok = store.put_if_match("\{ns}/cas.txt", Some(ver), b"v2")
  let cas_stale = store.put_if_match("\{ns}/cas.txt", Some(ver), b"v3")
  println(
    "  CAS: create=\{cas_new} update=\{cas_ok} stale=\{cas_stale} ver=\{ver}",
  )
  if !cas_ok {
    println(
      "  note: MinIO 不支持 PutObject+If-Match；CAS 更新需 AWS S3（create 的 If-None-Match:* 可用）",
    )
  }
  for key in store.list("\{ns}/") {
    store.delete(key)
  }
  // 两组对照：旧布局 vs single_copy + metadata cache
  let docs = mkdocs(120, 8)
  let base = @build.BuildConfig::default("bench-base")
  let cfg_base = {
    ..base,
    segment_rows: 40,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
  }
  let opt = @build.BuildConfig::single_copy("bench-opt")
  let cfg_opt = {
    ..opt,
    segment_rows: 40,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
  }
  println("== real S3/MinIO + toxiproxy: baseline vs single_copy ==")
  run_case(store, transport, "baseline", docs, cfg_base, false)
  run_case(store, transport, "optimized", docs, cfg_opt, true)
}

///|
fn main {
  try {
    run()
    println("S3 PROBE OK")
  } catch {
    e => println("S3 PROBE FAILED: \{err_msg(e)}")
  }
}
