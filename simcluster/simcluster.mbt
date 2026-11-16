// 离散事件排队 + 成本模拟器。
//
// 模型：每个 serve 进程 = 1 条 CPU 时间线 + s3_slots_per_proc 条 S3 slot 时间线。
//
// CPU 时间线用「就绪时间 + 成本」的任务队列（CpuJob）驱动，而不是简单累加：
//   - 命中缓存的查询：ready = 到达时间，执行时直接算完 → CPU 空就能插空服务；
//   - 冷读查询（async_io=true）：提交时 IO 立刻占一条 slot，CPU 任务 ready = IO 完成时间，
//     所以一条 30ms 的 GET 在飞时，同进程的热查询照样能被服务（插空）；
//   - 冷读查询（async_io=false，老架构）：CPU 任务从到达时间起被 IO **整段霸占**，
//     热查询只能排在后面 → 30ms 的 GET 直接堵死一个进程，p99 爆炸；
//   - 写：先编码（CPU）再 PUT（IO）；每进程 slot 决定并发度；
//   - 压缩：每 l0_delta_count 个 L0 delta 一次，成本 = rows × l0_delta_count × compact_doc_us。
//     dedicated_compactd=false → 压缩作为 CPU 任务压在 serve 进程上（一次数百 ms 的硬阻塞）；
//     dedicated_compactd=true  → 压缩走独立进程时间线，serve 的 p99 不受影响。
//
// 写合并：group_commit_window_us>0 时，窗口内的写合并成一次 3-PUT Slab
// （data / manifest / 提交标记），PUT 次数 = 3 × 窗口数，而不是 1 × 写数。
//
// 确定性：单条 @core.Rng 流；事件到达时间 = i / 速率（无抖动）；rng 只在「事件提交」
// 时按固定顺序采样（先命中判定、再 TTFB 对数正态）→ 同 seed + 同配置 ⇒ 逐字段完全相同。

///|
/// 每次查询扫描的文档比例（占单租户文档数）：倒排/postings 扫描量。
const SCAN_FRACTION : Double = 0.05

///|
/// 每次查询解码的 Slab 字节量（KB）。
const QUERY_DECODE_KB : Double = 64.0

///|
/// 单篇文档的固定开销字节（id + 文本 + 元数据），存储费口径用。
const DOC_EXTRA_BYTES : Int = 256

///|
/// 一个月 = 30 天（秒）。
const MONTH_SECONDS : Double = 2592000.0

///|
/// 一个月的小时数（30 天口径，与 S3 存储费同一时间基准）。
const HOURS_PER_MONTH : Double = 730.0

///|
/// 每个事件流的事件数上限（防病态参数把仿真拖死）。
const MAX_EVENTS : Int = 400000

///|
/// 大数代替 +∞（到达时间归并 / 收尾排空的哨兵）。
const NO_ARRIVAL : Double = 1.0e30

///|
/// CPU 任务类型。
const JOB_QUERY : Int = 0 // 纯 CPU 查询（缓存命中）

///|
const JOB_QUERY_IO : Int = 1 // 冷读查询的计算段（IO 完成后 ready）

///|
const JOB_QUERY_SYNC : Int = 2 // 同步 IO 的冷读查询：CPU 被 IO 整段霸占

///|
const JOB_WRITE : Int = 3 // 编码后发 PUT 的写（直写 1 PUT / 组提交 3 PUT）

///|
const JOB_COMPACT : Int = 4 // 压缩：把 CPU 锁死 cost 微秒

///|
fn dmax(a : Double, b : Double) -> Double {
  if a > b {
    a
  } else {
    b
  }
}

///|
fn dmin(a : Double, b : Double) -> Double {
  if a < b {
    a
  } else {
    b
  }
}

///|
fn clamp01(x : Double) -> Double {
  if x < 0.0 {
    0.0
  } else if x > 1.0 {
    1.0
  } else {
    x
  }
}

///|
fn pow10i(d : Int) -> Int {
  let mut r = 1
  for _ in 0..<d {
    r = r * 10
  }
  r
}

///|
/// 定点格式化（不依赖 Double Show 的可变长度；负零安全）。
pub fn fmt_fixed(x : Double, digits : Int) -> String {
  let neg = x < 0.0
  let ax = if neg {
    -x
  } else {
    x
  }
  let d = pow10i(digits)
  let scaled = (ax * d.to_double() + 0.5).to_int()
  let ip = scaled / d
  if digits <= 0 {
    return if neg {
      "-" + ip.to_string()
    } else {
      ip.to_string()
    }
  }
  let fp = scaled % d
  let mut fs = fp.to_string()
  while fs.length() < digits {
    fs = "0" + fs
  }
  let body = "\{ip}.\{fs}"
  if neg {
    "-" + body
  } else {
    body
  }
}

///|
/// 最近秩百分位（内部拷贝排序，不破坏原数组）。
fn pct(arr : Array[Double], p : Double) -> Double {
  if arr.is_empty() {
    return 0.0
  }
  let s = arr.copy()
  s.sort()
  let i = (p * (s.length() - 1).to_double()).to_int()
  s[i]
}

///|
/// 一个 CPU 任务：何时 ready、占 CPU 多久、执行时对 IO / 计费做什么。
priv struct CpuJob {
  kind : Int
  proc : Int
  ready : Double
  cost : Double
  io_us : Double
  arrival : Double // 查询用：请求到达时间
  arrivals : Array[Double] // 写用：本次提交覆盖的写到达时间（组提交可能多个）
  puts : Int
}

///|
/// 模拟器内部状态（时间线 + 计数器）。
priv struct SimState {
  cfg : ClusterSimConfig
  wl : WorkloadSpec
  rng : @core.Rng
  horizon_us : Double
  // 每进程 CPU：空闲时间 + 任务队列
  cpu_free : Array[Double]
  jobs : Array[Array[CpuJob]]
  cpu_compute_busy : Array[Double]
  cpu_blocked_busy : Array[Double]
  // 每进程 s3_slots_per_proc 条 slot 时间线：下标 = proc * slots + k
  slot_avail : Array[Double]
  slot_busy : Array[Double]
  // 独立 compactd 进程时间线（dedicated_compactd=true 时才用）
  compact_avail : Array[Double]
  mut compaction_events : Int
  mut l0_pending : Int
  // 组提交窗口
  mut pending_arrivals : Array[Double]
  mut pending_rows : Int
  mut pending_count : Int
  mut pending_first_arrival : Double
  mut flush_seq : Int
  // 统计
  mut gets : Int
  mut puts : Int
  query_lat_ms : Array[Double]
  write_lat_ms : Array[Double]
  mut dropped_queries : Int
  mut dropped_writes : Int
}

///|
fn SimState::new(
  cfg : ClusterSimConfig,
  wl : WorkloadSpec,
  seed : UInt,
) -> SimState {
  let procs = cfg.serve_processes
  let slots = procs * cfg.s3_slots_per_proc
  let jobs : Array[Array[CpuJob]] = Array()
  for _ in 0..<procs {
    jobs.push(Array())
  }
  {
    cfg,
    wl,
    rng: @core.Rng::new(seed),
    horizon_us: wl.duration_sec * 1000000.0,
    cpu_free: Array::make(procs, 0.0),
    jobs,
    cpu_compute_busy: Array::make(procs, 0.0),
    cpu_blocked_busy: Array::make(procs, 0.0),
    slot_avail: Array::make(slots, 0.0),
    slot_busy: Array::make(slots, 0.0),
    compact_avail: Array::make(1, 0.0),
    compaction_events: 0,
    l0_pending: 0,
    pending_arrivals: Array(),
    pending_rows: 0,
    pending_count: 0,
    pending_first_arrival: 0.0,
    flush_seq: 0,
    gets: 0,
    puts: 0,
    query_lat_ms: Array(),
    write_lat_ms: Array(),
    dropped_queries: 0,
    dropped_writes: 0,
  }
}

///|
/// 本次仿真实际可达的缓存命中率：请求值受每进程 RAM 容量约束
/// （工作集 = total_docs × 每篇字节；全部装得下才不打折）。
fn SimState::effective_hit_ratio(self : SimState) -> Double {
  let ws = (self.wl.total_docs * doc_bytes(self.wl)).to_double()
  let ram = self.cfg.ram_cache_mb_per_proc *
    1048576.0 *
    self.cfg.serve_processes.to_double()
  if ram <= 0.0 {
    0.0
  } else if ws <= ram {
    self.wl.cache_hit_ratio
  } else {
    dmin(self.wl.cache_hit_ratio, ram / ws)
  }
}

///|
/// 对数正态样本（消耗恰好 2 个 uniform：先 u1 后 u2）。
fn SimState::sample_ttfb(self : SimState, p50 : Double) -> Double {
  let pi2 = 6.283185307179586
  let u1 = self.rng.next_f64()
  let u2 = self.rng.next_f64()
  let u1c = if u1 <= 1.0e-12 {
    1.0e-12
  } else if u1 >= 1.0 {
    1.0 - 1.0e-12
  } else {
    u1
  }
  let z = (-2.0 * @math.ln(u1c)).sqrt() * @math.cos(pi2 * u2)
  p50 * @math.exp(self.cfg.s3_ttfb_sigma * z)
}

///|
/// 每篇文档的字节数（存储费 / 传输时间口径）。
fn doc_bytes(wl : WorkloadSpec) -> Int {
  wl.dim * 4 + DOC_EXTRA_BYTES
}

///|
/// rows 篇文档的传输时间（微秒）：bytes / mbps。
fn SimState::rows_transfer_us(self : SimState, rows : Int) -> Double {
  (rows * doc_bytes(self.wl)).to_double() / self.cfg.s3_bw_mbps
}

///|
/// 单次查询的 CPU 成本（微秒）：IVF 质心探测 + postings 扫描 + top-K 重排 + Slab 解码。
/// 命中缓存的查询不需要解码冷 Slab。
fn SimState::query_cpu_us(self : SimState, hit : Bool) -> Double {
  let p = self.cfg.cpu
  let wl = self.wl
  let dim = wl.dim.to_double()
  let tenants = wl.num_tenants.to_double()
  let scan_docs = wl.total_docs.to_double() * SCAN_FRACTION / tenants
  let posting_us = scan_docs * p.bm25_posting_ns / 1000.0
  let centroid_us = wl.nprobe.to_double() * dim * p.vec_dot_ns_per_dim / 1000.0
  let rerank_docs = dmin(scan_docs, 100.0)
  let rerank_us = rerank_docs * dim * p.vec_dot_ns_per_dim / 1000.0
  let decode_us = if hit {
    0.0
  } else {
    QUERY_DECODE_KB * p.slab_decode_ns_per_kb / 1000.0
  }
  posting_us + centroid_us + rerank_us + decode_us
}

///|
/// 进程 p 上最空闲的 S3 slot 下标。
fn SimState::free_slot(self : SimState, p : Int) -> Int {
  let slots = self.cfg.s3_slots_per_proc
  let base = p * slots
  let mut idx = base
  for k in 1..<slots {
    if self.slot_avail[base + k] < self.slot_avail[idx] {
      idx = base + k
    }
  }
  idx
}

///|
fn SimState::push_job(self : SimState, job : CpuJob) -> Unit {
  self.jobs[job.proc].push(job)
}

///|
fn SimState::record_query(self : SimState, arrival : Double, finish : Double) -> Unit {
  if finish <= self.horizon_us {
    self.query_lat_ms.push((finish - arrival) / 1000.0)
  } else {
    self.dropped_queries += 1
  }
}

///|
fn SimState::record_write(self : SimState, arrival : Double, finish : Double) -> Unit {
  if finish <= self.horizon_us {
    self.write_lat_ms.push((finish - arrival) / 1000.0)
  } else {
    self.dropped_writes += 1
  }
}

///|
/// 把「压缩」排进时间线：每 l0_delta_count 个 L0 delta 一次。
fn SimState::submit_compact(self : SimState, at : Double, p : Int) -> Unit {
  let threshold = self.wl.l0_delta_count
  if threshold <= 0 {
    return
  }
  self.l0_pending += 1
  if self.l0_pending < threshold {
    return
  }
  self.l0_pending = 0
  let docs = self.wl.rows_per_write * threshold
  let cost = docs.to_double() * self.cfg.cpu.compact_doc_us
  self.compaction_events += 1
  if self.cfg.dedicated_compactd {
    // 独立进程：只推进它自己的时间线，serve 的 CPU 完全不受影响
    let start = dmax(at, self.compact_avail[0])
    self.compact_avail[0] = start + cost
    return
  }
  self.push_job({
    kind: JOB_COMPACT,
    proc: p,
    ready: at,
    cost,
    io_us: 0.0,
    arrival: at,
    arrivals: Array(),
    puts: 0,
  })
}

///|
/// 执行一个 CPU 任务（不推进队列，由 pump / drain 调用）。
fn SimState::exec_job(self : SimState, job : CpuJob) -> Unit {
  let p = job.proc
  let start = self.cpu_free[p]
  match job.kind {
    JOB_QUERY => {
      let finish = start + job.cost
      self.cpu_free[p] = finish
      self.cpu_compute_busy[p] += job.cost
      self.record_query(job.arrival, finish)
    }
    JOB_QUERY_IO => {
      // IO 已在提交时占好 slot，这里只做解码/重排
      let finish = start + job.cost
      self.cpu_free[p] = finish
      self.cpu_compute_busy[p] += job.cost
      self.record_query(job.arrival, finish)
    }
    JOB_QUERY_SYNC => {
      // 老架构：CPU 从 start 起被 TTFB 整段霸占，热查询无法插空
      let idx = self.free_slot(p)
      let io_start = dmax(start, self.slot_avail[idx])
      let io_done = io_start + job.io_us
      self.slot_avail[idx] = io_done
      self.slot_busy[idx] += job.io_us
      let finish = io_done + job.cost
      self.cpu_free[p] = finish
      self.cpu_compute_busy[p] += job.cost
      self.cpu_blocked_busy[p] += job.io_us + (io_start - start)
      self.record_query(job.arrival, finish)
    }
    JOB_WRITE => {
      let encode_done = start + job.cost
      self.cpu_compute_busy[p] += job.cost
      let idx = self.free_slot(p)
      let io_start = dmax(encode_done, self.slot_avail[idx])
      let io_done = io_start + job.io_us
      self.slot_avail[idx] = io_done
      self.slot_busy[idx] += job.io_us
      if self.cfg.async_io {
        self.cpu_free[p] = encode_done
      } else {
        self.cpu_free[p] = io_done
        self.cpu_blocked_busy[p] += job.io_us + (io_start - encode_done)
      }
      self.puts += job.puts
      for a in job.arrivals {
        self.record_write(a, io_done)
      }
      self.submit_compact(io_done, p)
    }
    _ => {
      // JOB_COMPACT：整段锁死 CPU
      let finish = start + job.cost
      self.cpu_free[p] = finish
      self.cpu_compute_busy[p] += job.cost
    }
  }
}

///|
/// 推进进程 p 的 CPU：按 ready 顺序执行所有「已经就绪」的任务
/// （ready <= max(CPU 空闲时间, 当前事件时间)）。未来才就绪的任务留到后续事件或收尾排空。
fn SimState::pump(self : SimState, p : Int, now : Double) -> Unit {
  while true {
    let q = self.jobs[p]
    if q.is_empty() {
      break
    }
    let mut idx = 0
    for i in 1..<q.length() {
      if q[i].ready < q[idx].ready {
        idx = i
      }
    }
    let ready = q[idx].ready
    if ready > dmax(self.cpu_free[p], now) {
      break
    }
    let start = dmax(self.cpu_free[p], ready)
    self.cpu_free[p] = start
    let job = q.remove(idx)
    self.exec_job(job)
  }
}

///|
/// 收尾：所有事件处理完后，按 ready 顺序把剩余任务全部执行（CPU 已经不空也照排）。
fn SimState::drain(self : SimState, p : Int) -> Unit {
  while !self.jobs[p].is_empty() {
    let q = self.jobs[p]
    let mut idx = 0
    for i in 1..<q.length() {
      if q[i].ready < q[idx].ready {
        idx = i
      }
    }
    let job = q.remove(idx)
    self.cpu_free[p] = dmax(self.cpu_free[p], job.ready)
    self.exec_job(job)
  }
}

///|
/// 查询：命中缓存 → 纯 CPU；冷读 → async_io 决定 IO 是否霸占 CPU。
fn SimState::handle_query(self : SimState, idx : Int, arrival : Double) -> Unit {
  let p = idx % self.cfg.serve_processes
  let hit = self.rng.next_f64() < self.effective_hit_ratio()
  let cpu_us = self.query_cpu_us(hit)
  if hit {
    self.push_job({
      kind: JOB_QUERY,
      proc: p,
      ready: arrival,
      cost: cpu_us,
      io_us: 0.0,
      arrival,
      arrivals: Array(),
      puts: 0,
    })
  } else {
    let io = self.sample_ttfb(self.cfg.s3_get_ttfb_p50_us) +
      QUERY_DECODE_KB / self.cfg.s3_bw_mbps
    self.gets += 1
    if self.cfg.async_io {
      // 只占一条 slot：IO 立刻起飞，CPU 任务等 IO 回来才 ready（期间热查询可插空）
      let slot = self.free_slot(p)
      let io_start = dmax(arrival, self.slot_avail[slot])
      let io_done = io_start + io
      self.slot_avail[slot] = io_done
      self.slot_busy[slot] += io
      self.push_job({
        kind: JOB_QUERY_IO,
        proc: p,
        ready: io_done,
        cost: cpu_us,
        io_us: io,
        arrival,
        arrivals: Array(),
        puts: 0,
      })
    } else {
      self.push_job({
        kind: JOB_QUERY_SYNC,
        proc: p,
        ready: arrival,
        cost: cpu_us,
        io_us: io,
        arrival,
        arrivals: Array(),
        puts: 0,
      })
    }
  }
  self.pump(p, arrival)
}

///|
/// 直写：每次写 1 次 PUT。
fn SimState::handle_direct_write(
  self : SimState,
  idx : Int,
  arrival : Double,
) -> Unit {
  let p = idx % self.cfg.serve_processes
  let rows = self.wl.rows_per_write
  let io = self.sample_ttfb(self.cfg.s3_put_ttfb_p50_us) +
    self.rows_transfer_us(rows)
  self.push_job({
    kind: JOB_WRITE,
    proc: p,
    ready: arrival,
    cost: rows.to_double() * self.cfg.cpu.ingest_doc_us,
    io_us: io,
    arrival,
    arrivals: [arrival],
    puts: 1,
  })
  self.pump(p, arrival)
}

///|
/// 把当前组提交窗口刷成一次 3-PUT Slab（data / manifest / 提交标记）。
fn SimState::flush_window(self : SimState, at : Double) -> Unit {
  if self.pending_count == 0 {
    return
  }
  let rows = self.pending_rows
  let arrivals = self.pending_arrivals
  let first = self.pending_first_arrival
  self.pending_count = 0
  self.pending_rows = 0
  self.pending_arrivals = Array()
  let p = self.flush_seq % self.cfg.serve_processes
  self.flush_seq += 1
  // 三个对象并发上传：最慢那次决定提交时间
  let mut ttfb = 0.0
  for _ in 0..<3 {
    ttfb = dmax(ttfb, self.sample_ttfb(self.cfg.s3_put_ttfb_p50_us))
  }
  let start_at = dmax(at, first + self.cfg.group_commit_window_us)
  self.push_job({
    kind: JOB_WRITE,
    proc: p,
    ready: start_at,
    cost: rows.to_double() * self.cfg.cpu.ingest_doc_us,
    io_us: ttfb + self.rows_transfer_us(rows),
    arrival: first,
    arrivals,
    puts: 3,
  })
  self.pump(p, start_at)
}

///|
fn SimState::handle_write(self : SimState, idx : Int, arrival : Double) -> Unit {
  if self.cfg.group_commit_window_us <= 0.0 {
    self.handle_direct_write(idx, arrival)
    return
  }
  if self.pending_count == 0 {
    self.pending_first_arrival = arrival
  }
  self.pending_arrivals.push(arrival)
  self.pending_rows += self.wl.rows_per_write
  self.pending_count += 1
  if arrival - self.pending_first_arrival >= self.cfg.group_commit_window_us {
    self.flush_window(arrival)
  }
}

///|
/// 事件数上限（病态参数保护）：一个事件流最多 MAX_EVENTS 个事件。
fn capped_events(n : Double) -> Int {
  if n <= 0.0 {
    return 0
  }
  let i = n.to_int()
  if i > MAX_EVENTS {
    MAX_EVENTS
  } else {
    i
  }
}

///|
/// 主循环：读事件与写事件按到达时间归并（到达时间 = i / 速率，确定且无抖动）。
fn SimState::run(self : SimState) -> Unit {
  let dur = self.wl.duration_sec
  let qps = self.wl.query_qps
  let wps = self.wl.write_rps
  let n_q = capped_events(qps * dur)
  let n_w = capped_events(wps * dur)
  let q_step = if qps > 0.0 {
    1000000.0 / qps
  } else {
    0.0
  }
  let w_step = if wps > 0.0 {
    1000000.0 / wps
  } else {
    0.0
  }
  let mut qi = 0
  let mut wi = 0
  while qi < n_q || wi < n_w {
    let q_t = if qi < n_q {
      qi.to_double() * q_step
    } else {
      NO_ARRIVAL
    }
    let w_t = if wi < n_w {
      wi.to_double() * w_step
    } else {
      NO_ARRIVAL
    }
    if q_t <= w_t {
      self.handle_query(qi, q_t)
      qi += 1
    } else {
      self.handle_write(wi, w_t)
      wi += 1
    }
  }
  // 收尾 1：把最后一个组提交窗口刷出去（PUT 计费必须覆盖全部写入）
  self.flush_window(self.horizon_us)
  // 收尾 2：排空剩余 CPU 任务（在飞 IO 的回调 / 排队中的压缩）
  for p in 0..<self.cfg.serve_processes {
    self.drain(p)
  }
}

///|
/// 参数止血：进程数/slots 至少 1，负速率归零，窗口非负。
fn sanitize_cfg(cfg : ClusterSimConfig) -> ClusterSimConfig {
  {
    ..cfg,
    serve_processes: if cfg.serve_processes < 1 {
      1
    } else {
      cfg.serve_processes
    },
    s3_slots_per_proc: if cfg.s3_slots_per_proc < 1 {
      1
    } else {
      cfg.s3_slots_per_proc
    },
    group_commit_window_us: dmax(cfg.group_commit_window_us, 0.0),
    s3_ttfb_sigma: dmax(cfg.s3_ttfb_sigma, 0.0),
    s3_bw_mbps: dmax(cfg.s3_bw_mbps, 1.0),
  }
}

///|
fn sanitize_wl(wl : WorkloadSpec) -> WorkloadSpec {
  {
    ..wl,
    duration_sec: dmax(wl.duration_sec, 0.0),
    query_qps: dmax(wl.query_qps, 0.0),
    write_rps: dmax(wl.write_rps, 0.0),
    rows_per_write: if wl.rows_per_write < 1 {
      1
    } else {
      wl.rows_per_write
    },
    dim: if wl.dim < 1 { 1 } else { wl.dim },
    nprobe: if wl.nprobe < 1 { 1 } else { wl.nprobe },
    num_tenants: if wl.num_tenants < 1 { 1 } else { wl.num_tenants },
    cache_hit_ratio: clamp01(wl.cache_hit_ratio),
    l0_delta_count: dmax(wl.l0_delta_count.to_double(), 0.0).to_int(),
  }
}

///|
/// 跑一次集群离散事件仿真。纯函数：不改 cfg/wl，不真睡、不建线程。
pub fn run_cluster_sim(
  cfg : ClusterSimConfig,
  wl : WorkloadSpec,
  seed~ : UInt = 42U,
) -> ClusterSimReport {
  let st = SimState::new(sanitize_cfg(cfg), sanitize_wl(wl), seed)
  st.run()
  st.report()
}
