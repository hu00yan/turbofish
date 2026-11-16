// ClusterSimReport：仿真结果 + JSON 序列化 + 摘要表。
//
// 口径说明：
// - 延迟百分位只统计 **在仿真时间窗内完成** 的请求；窗口内没排完的被计为 dropped
//   （开环压测下这就是"被过载打挂"的部分）。因此饱和场景的 achieved_qps 反映真实
//   吞吐，而不是 offered 速率。
// - 月度成本 = 本次仿真的请求量按 duration 外推到 30 天。
// - avg_cpu_util 把「同步 IO 被 S3 等待霸占的时间」也算成 CPU 占用（这正是老架构的病根），
//   上限截断到 100%；被外部判断为 100% 时说明该进程已经彻底饱和。

///|
pub(all) struct ClusterSimReport {
  cfg_label : String
  serve_processes : Int
  query_p50_ms : Double
  query_p95_ms : Double
  query_p99_ms : Double
  achieved_qps : Double
  offered_qps : Double
  completed_queries : Int
  dropped_queries : Int
  write_p50_ms : Double
  write_p99_ms : Double
  completed_writes : Int
  dropped_writes : Int
  avg_cpu_util : Double
  avg_s3_slot_util : Double
  total_s3_gets : Int
  total_s3_puts : Int
  compaction_events : Int
  monthly_s3_get_usd : Double
  monthly_s3_put_usd : Double
  monthly_storage_usd : Double
  monthly_compute_usd : Double
  monthly_total_usd : Double
  bottleneck : String
}

///|
/// 仿真结果 → 报告（内部接口，只有 run_cluster_sim 调用）。
fn SimState::report(self : SimState) -> ClusterSimReport {
  let cfg = self.cfg
  let procs = cfg.serve_processes
  let horizon = self.horizon_us
  let mut busy = 0.0
  let mut blocked = 0.0
  for i in 0..<procs {
    busy += self.cpu_compute_busy[i] + self.cpu_blocked_busy[i]
    blocked += self.cpu_blocked_busy[i]
  }
  let mut slot_busy = 0.0
  for v in self.slot_busy {
    slot_busy += v
  }
  let cpu_util = if horizon > 0.0 {
    clamp01(busy / (procs.to_double() * horizon))
  } else {
    0.0
  }
  let blocked_frac = if horizon > 0.0 {
    clamp01(blocked / (procs.to_double() * horizon))
  } else {
    0.0
  }
  let slot_den = (procs * cfg.s3_slots_per_proc).to_double() * horizon
  let slot_util = if slot_den > 0.0 {
    clamp01(slot_busy / slot_den)
  } else {
    0.0
  }
  let dur = if self.wl.duration_sec > 0.0 {
    self.wl.duration_sec
  } else {
    1.0
  }
  let completed = self.query_lat_ms.length()
  let achieved = completed.to_double() / dur
  let bottleneck = classify_bottleneck(
    cpu_util, slot_util, blocked_frac, cfg.async_io,
  )
  let month_scale = MONTH_SECONDS / dur
  let get_usd = self.gets.to_double() * cfg.rates.get_per_1k / 1000.0 * month_scale
  let put_usd = self.puts.to_double() * cfg.rates.put_per_1k / 1000.0 * month_scale
  let storage_bytes = (self.wl.total_docs * doc_bytes(self.wl)).to_double()
  let storage_usd = storage_bytes / 1073741824.0 *
    cfg.rates.storage_per_gb_month
  let compute_procs = procs + (if cfg.dedicated_compactd { 1 } else { 0 })
  let compute_usd = cfg.vcpu_price_per_hour *
    compute_procs.to_double() *
    HOURS_PER_MONTH
  {
    cfg_label: cfg_label(cfg),
    serve_processes: procs,
    query_p50_ms: pct(self.query_lat_ms, 0.50),
    query_p95_ms: pct(self.query_lat_ms, 0.95),
    query_p99_ms: pct(self.query_lat_ms, 0.99),
    achieved_qps: achieved,
    offered_qps: self.wl.query_qps,
    completed_queries: completed,
    dropped_queries: self.dropped_queries,
    write_p50_ms: pct(self.write_lat_ms, 0.50),
    write_p99_ms: pct(self.write_lat_ms, 0.99),
    completed_writes: self.write_lat_ms.length(),
    dropped_writes: self.dropped_writes,
    avg_cpu_util: cpu_util,
    avg_s3_slot_util: slot_util,
    total_s3_gets: self.gets,
    total_s3_puts: self.puts,
    compaction_events: self.compaction_events,
    monthly_s3_get_usd: get_usd,
    monthly_s3_put_usd: put_usd,
    monthly_storage_usd: storage_usd,
    monthly_compute_usd: compute_usd,
    monthly_total_usd: get_usd + put_usd + storage_usd + compute_usd,
    bottleneck,
  }
}

///|
/// 瓶颈判定：同步 IO 霸占 CPU（event_loop_blocked）优先于纯 CPU 饱和，
/// 因为前者是"看起来 CPU 满了、其实是事件循环被网络等待堵死"。
fn classify_bottleneck(
  cpu_util : Double,
  slot_util : Double,
  blocked_frac : Double,
  async_io : Bool,
) -> String {
  if !async_io && blocked_frac > 0.25 {
    "event_loop_blocked"
  } else if cpu_util >= 0.85 {
    "cpu_bound"
  } else if slot_util >= 0.85 {
    "s3_slot_bound"
  } else {
    "underutilized"
  }
}

///|
/// 配置标签（报告与对照表用，让人一眼看出架构差异）。
pub fn cfg_label(cfg : ClusterSimConfig) -> String {
  let io = if cfg.async_io { "async_io" } else { "sync_io" }
  let gc = if cfg.group_commit_window_us > 0.0 {
    "group_commit_" + fmt_fixed(cfg.group_commit_window_us / 1000.0, 0) + "ms"
  } else {
    "direct_put"
  }
  let cd = if cfg.dedicated_compactd {
    "compactd"
  } else {
    "inline_compact"
  }
  "\{cfg.serve_processes}proc/\{io}/\{gc}/\{cd}"
}

///|
/// JSON 序列化（字段顺序固定，便于 diff 与"同 seed 逐字节相等"断言）。
pub fn ClusterSimReport::to_json_string(self : ClusterSimReport) -> String {
  let b = StringBuilder()
  b.write_string("{\n")
  b.write_string("  \"cfg_label\": \"" + self.cfg_label + "\",\n")
  b.write_string("  \"serve_processes\": " + self.serve_processes.to_string() + ",\n")
  b.write_string("  \"query_p50_ms\": " + fmt_fixed(self.query_p50_ms, 3) + ",\n")
  b.write_string("  \"query_p95_ms\": " + fmt_fixed(self.query_p95_ms, 3) + ",\n")
  b.write_string("  \"query_p99_ms\": " + fmt_fixed(self.query_p99_ms, 3) + ",\n")
  b.write_string("  \"achieved_qps\": " + fmt_fixed(self.achieved_qps, 3) + ",\n")
  b.write_string("  \"offered_qps\": " + fmt_fixed(self.offered_qps, 3) + ",\n")
  b.write_string(
    "  \"completed_queries\": " + self.completed_queries.to_string() + ",\n",
  )
  b.write_string("  \"dropped_queries\": " + self.dropped_queries.to_string() + ",\n")
  b.write_string("  \"write_p50_ms\": " + fmt_fixed(self.write_p50_ms, 3) + ",\n")
  b.write_string("  \"write_p99_ms\": " + fmt_fixed(self.write_p99_ms, 3) + ",\n")
  b.write_string("  \"completed_writes\": " + self.completed_writes.to_string() + ",\n")
  b.write_string("  \"dropped_writes\": " + self.dropped_writes.to_string() + ",\n")
  b.write_string("  \"avg_cpu_util\": " + fmt_fixed(self.avg_cpu_util, 4) + ",\n")
  b.write_string(
    "  \"avg_s3_slot_util\": " + fmt_fixed(self.avg_s3_slot_util, 4) + ",\n",
  )
  b.write_string("  \"total_s3_gets\": " + self.total_s3_gets.to_string() + ",\n")
  b.write_string("  \"total_s3_puts\": " + self.total_s3_puts.to_string() + ",\n")
  b.write_string("  \"compaction_events\": " + self.compaction_events.to_string() + ",\n")
  b.write_string(
    "  \"monthly_s3_get_usd\": " + fmt_fixed(self.monthly_s3_get_usd, 4) + ",\n",
  )
  b.write_string(
    "  \"monthly_s3_put_usd\": " + fmt_fixed(self.monthly_s3_put_usd, 4) + ",\n",
  )
  b.write_string(
    "  \"monthly_storage_usd\": " + fmt_fixed(self.monthly_storage_usd, 4) + ",\n",
  )
  b.write_string(
    "  \"monthly_compute_usd\": " + fmt_fixed(self.monthly_compute_usd, 4) + ",\n",
  )
  b.write_string(
    "  \"monthly_total_usd\": " + fmt_fixed(self.monthly_total_usd, 4) + ",\n",
  )
  b.write_string("  \"bottleneck\": \"" + self.bottleneck + "\"\n")
  b.write_string("}\n")
  b.to_string()
}

///|
fn pad_right(s : String, w : Int) -> String {
  let mut out = s
  while out.length() < w {
    out = out + " "
  }
  out
}

///|
fn pad_left(s : String, w : Int) -> String {
  let mut out = s
  while out.length() < w {
    out = " " + out
  }
  out
}

///|
/// 单次仿真摘要表（等宽纯文本）。
pub fn ClusterSimReport::format_summary_table(self : ClusterSimReport) -> String {
  let b = StringBuilder()
  b.write_string("=== cluster sim: \{self.cfg_label} ===\n")
  let rows : Array[(String, String)] = [
    ("query p50 (ms)", fmt_fixed(self.query_p50_ms, 3)),
    ("query p95 (ms)", fmt_fixed(self.query_p95_ms, 3)),
    ("query p99 (ms)", fmt_fixed(self.query_p99_ms, 3)),
    (
      "achieved qps",
      fmt_fixed(self.achieved_qps, 1) +
      " / offered " +
      fmt_fixed(self.offered_qps, 1),
    ),
    (
      "completed / dropped queries",
      self.completed_queries.to_string() +
      " / " +
      self.dropped_queries.to_string(),
    ),
    ("write p50 (ms)", fmt_fixed(self.write_p50_ms, 3)),
    ("write p99 (ms)", fmt_fixed(self.write_p99_ms, 3)),
    (
      "completed / dropped writes",
      self.completed_writes.to_string() + " / " + self.dropped_writes.to_string(),
    ),
    ("avg cpu util", fmt_fixed(self.avg_cpu_util * 100.0, 1) + "%"),
    ("avg s3 slot util", fmt_fixed(self.avg_s3_slot_util * 100.0, 1) + "%"),
    (
      "s3 gets / puts",
      self.total_s3_gets.to_string() + " / " + self.total_s3_puts.to_string(),
    ),
    ("compaction events", self.compaction_events.to_string()),
    ("monthly s3 get (usd)", "$" + fmt_fixed(self.monthly_s3_get_usd, 2)),
    ("monthly s3 put (usd)", "$" + fmt_fixed(self.monthly_s3_put_usd, 2)),
    ("monthly storage (usd)", "$" + fmt_fixed(self.monthly_storage_usd, 2)),
    ("monthly compute (usd)", "$" + fmt_fixed(self.monthly_compute_usd, 2)),
    ("monthly total (usd)", "$" + fmt_fixed(self.monthly_total_usd, 2)),
    ("bottleneck", self.bottleneck),
  ]
  for r in rows {
    b.write_string("  " + pad_right(r.0, 30) + pad_left(r.1, 22) + "\n")
  }
  b.to_string()
}

///|
/// 两套架构对照表：latency / 吞吐 / 成本同屏。
/// 最后一列 = 右侧 / 左侧的倍数（延迟与成本 < 1 表示变好，吞吐 > 1 表示变好）。
pub fn format_comparison_table(
  label_a : String,
  a : ClusterSimReport,
  label_b : String,
  b : ClusterSimReport,
) -> String {
  let sb = StringBuilder()
  sb.write_string("=== architecture comparison ===\n")
  sb.write_string(pad_right("metric", 28))
  sb.write_string(pad_left(label_a, 16))
  sb.write_string(pad_left(label_b, 16))
  sb.write_string(pad_left("b/a", 10))
  sb.write_string("\n")
  // (指标, 左值, 右值, 单位)：0 = 数值，1 = 美元
  let rows : Array[(String, Double, Double, Int)] = [
    ("query p50 (ms)", a.query_p50_ms, b.query_p50_ms, 0),
    ("query p95 (ms)", a.query_p95_ms, b.query_p95_ms, 0),
    ("query p99 (ms)", a.query_p99_ms, b.query_p99_ms, 0),
    ("write p50 (ms)", a.write_p50_ms, b.write_p50_ms, 0),
    ("write p99 (ms)", a.write_p99_ms, b.write_p99_ms, 0),
    ("achieved qps", a.achieved_qps, b.achieved_qps, 0),
    ("dropped queries", a.dropped_queries.to_double(), b.dropped_queries.to_double(), 0),
    ("s3 gets", a.total_s3_gets.to_double(), b.total_s3_gets.to_double(), 0),
    ("s3 puts", a.total_s3_puts.to_double(), b.total_s3_puts.to_double(), 0),
    ("avg cpu util %", a.avg_cpu_util * 100.0, b.avg_cpu_util * 100.0, 0),
    ("monthly s3 get", a.monthly_s3_get_usd, b.monthly_s3_get_usd, 1),
    ("monthly s3 put", a.monthly_s3_put_usd, b.monthly_s3_put_usd, 1),
    ("monthly storage", a.monthly_storage_usd, b.monthly_storage_usd, 1),
    ("monthly compute", a.monthly_compute_usd, b.monthly_compute_usd, 1),
    ("monthly total", a.monthly_total_usd, b.monthly_total_usd, 1),
  ]
  for r in rows {
    let va = if r.3 == 1 {
      "$" + fmt_fixed(r.1, 2)
    } else {
      fmt_fixed(r.1, 2)
    }
    let vb = if r.3 == 1 {
      "$" + fmt_fixed(r.2, 2)
    } else {
      fmt_fixed(r.2, 2)
    }
    let ratio = if r.1 > 0.0 {
      fmt_fixed(r.2 / r.1, 2) + "x"
    } else {
      "-"
    }
    sb.write_string(pad_right(r.0, 28))
    sb.write_string(pad_left(va, 16))
    sb.write_string(pad_left(vb, 16))
    sb.write_string(pad_left(ratio, 10))
    sb.write_string("\n")
  }
  sb.write_string("\n  bottleneck: ")
  sb.write_string(a.bottleneck)
  sb.write_string(" -> ")
  sb.write_string(b.bottleneck)
  sb.write_string("\n  b/a < 1 表示右侧更好（延迟/成本），> 1 表示右侧更差；\n")
  sb.write_string(
    "  achieved qps / s3 puts 的解读相反（吞吐越大越好，PUT 越少越便宜）。\n",
  )
  sb.to_string()
}
