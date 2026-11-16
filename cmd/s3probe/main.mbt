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
fn mkdocs(n : Int, dim : Int) -> Array[@core.Doc] {
  let rng = @core.Rng::new(7U)
  let words = ["alpha", "beta", "gamma", "delta", "向量", "检索"]
  let docs : Array[@core.Doc] = Array(capacity=n)
  for i in 0..<n {
    let mut text = ""
    for _ in 0..<6 {
      let w = words[(rng.next_u32() % words.length().reinterpret_as_uint()).reinterpret_as_int()]
      text = text + w + " "
    }
    let v : Array[Float] = Array(capacity=dim)
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
  posts : Int
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
/// 计数存储包装：委托纯 MoonBit 异步 `@s3client.S3Client`，在方法层计数
/// （GET/PUT/LIST/HEAD/DELETE）并按 R2 Class A/B 口径分类。
/// `cum` 是累计值（reset 不清零），`gets`/`head_reqs` 是可清零的窗口值。
pub struct ProbeStore {
  inner : @s3client.S3Client
  mut gets : Int
  mut head_reqs : Int
  cum : OpCounts
}

// 便捷方法转发。
pub extend ProbeStore with @store.ObjectStore::{
  get,
  get_range,
  put,
  put_if_match,
  list,
  delete,
  head_version,
}

///|
fn ProbeStore::new(inner : @s3client.S3Client) -> ProbeStore {
  { inner, gets: 0, head_reqs: 0, cum: OpCounts::new() }
}

///|
fn ProbeStore::reset(self : ProbeStore) -> Unit {
  self.gets = 0
  self.head_reqs = 0
}

///|
fn ProbeStore::cumulative(self : ProbeStore) -> OpCounts {
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
/// 记录一次 GET（head log 读取单独计 head_reqs：冷启动 open 的探测面）。
fn ProbeStore::note_get(self : ProbeStore, key : String) -> Unit {
  self.gets += 1
  self.cum.gets += 1
  if key.contains("_heads") {
    self.head_reqs += 1
  }
}

///|
pub impl @store.ObjectStore for ProbeStore with get(self, key) {
  self.note_get(key)
  @s3client.S3Client::get(self.inner, key)
}

///|
pub impl @store.ObjectStore for ProbeStore with put(self, key, bs) {
  self.cum.puts += 1
  @s3client.S3Client::put(self.inner, key, bs)
}

///|
pub impl @store.ObjectStore for ProbeStore with put_if_match(
  self,
  key,
  expected,
  bs
) {
  self.cum.puts += 1
  @s3client.S3Client::put_if_match(self.inner, key, bs, expected)
}

///|
pub impl @store.ObjectStore for ProbeStore with get_range(
  self,
  key,
  offset,
  len
) {
  self.note_get(key)
  @s3client.S3Client::get_range(self.inner, key, offset, len)
}

///|
pub impl @store.ObjectStore for ProbeStore with list(self, prefix) {
  self.cum.lists += 1
  @s3client.S3Client::list(self.inner, prefix)
}

///|
pub impl @store.ObjectStore for ProbeStore with delete(self, key) {
  self.cum.deletes += 1
  @s3client.S3Client::delete(self.inner, key)
}

///|
pub impl @store.ObjectStore for ProbeStore with head_version(self, key) {
  self.cum.heads += 1
  @s3client.S3Client::head_version(self.inner, key)
}

///|
/// 桶是否可用（新版 MinIO 不自动建桶，`create_bucket` 也非对象存储语义；
/// 这里用一次 LIST 探测，失败只告警）。
async fn ProbeStore::bucket_ready(self : ProbeStore) -> Bool {
  let probe = try {
    Ok(@s3client.S3Client::list(self.inner, ""))
  } catch {
    e => Err(e)
  }
  self.cum.lists += 1
  match probe {
    Ok(_) => true
    Err(e) => {
      println("  WARNING: bucket LIST failed: \{err_msg(e)}")
      false
    }
  }
}
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
async fn run_case(
  store : ProbeStore,
  transport : ProbeStore,
  label : String,
  docs : Array[@core.Doc],
  cfg : @build.BuildConfig,
  use_cache : Bool,
) -> Unit {
  let ns = cfg.ns
  let c0 = transport.cumulative()
  transport.reset()
  let ti = @bench.monotonic_clock_start()
  @build.ingest(store, cfg, docs)
  let ti2 = @bench.monotonic_clock_end(ti)
  let ingest_heads = transport.head_reqs
  let cache : @query.MetadataCache[ProbeStore] = @query.MetadataCache::new()
  let open_one = async fn() -> @query.Namespace[ProbeStore] {
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
  let bm_ts : Array[Double] = Array()
  let bm_req : Array[Int] = Array()
  let vec_ts : Array[Double] = Array()
  let vec_req : Array[Int] = Array()
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
async fn run() -> Unit {
  let endpoint = env_or("S3_ENDPOINT", "http://127.0.0.1:19000")
  let bucket = env_or("S3_BUCKET", "seekpond")
  let region = env_or("S3_REGION", "us-east-1")
  let access = env_or("S3_ACCESS_KEY", env_or("AWS_ACCESS_KEY_ID", "minioadmin"))
  let secret = env_or(
    "S3_SECRET_KEY",
    env_or("AWS_SECRET_ACCESS_KEY", "minioadmin"),
  )
  let client = @s3client.S3Client::new(
    endpoint,
    bucket,
    region,
    access,
    secret,
    max_inflight=16,
  )
  let transport = ProbeStore::new(client)
  let store = transport
  let ns = "probe-\{@env.now()}"
  println("== S3 probe: endpoint=\{endpoint} bucket=\{bucket} ns=\{ns} (async S3Client)")
  // 新版 MinIO 不自动建桶；用一次 LIST 探测桶是否可用（失败只告警）。
  if !store.bucket_ready() {
    println("  WARNING: bucket not ready (create it first: mc mb ...)")
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
  let ts : Array[Double] = Array()
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
async fn main {
  let r = try {
    run()
    true
  } catch {
    e => {
      println("S3 PROBE FAILED: \{err_msg(e)}")
      false
    }
  }
  if r {
    println("S3 PROBE OK")
  }
}
