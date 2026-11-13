// simstore/chaos.mbt
// 确定性仿真测试 (DST) 与混沌故障注入引擎 (Chaos Engine)
//
// 核心能力：
// 1. ChaosStore[S : @store.ObjectStore]：包裹底层存储，以 64 位确定性伪随机数（UInt64）驱动混沌注入。
// 2. 可配置故障规则集：
//    - S3 503 RateLimit / SlowDown
//    - S3 412 PreconditionFailed（CAS 冲突）
//    - S3 404 NotFound
//    - ConnectionReset / Timeout
//    - TruncatedRangeGet：截断 Range GET 尾部字节，测试 EOF / Truncated / Corrupt 恢复
//    - 虚拟时钟（Virtual Time）：以微秒为单位累加延迟，不引入真实 sleep / 线程阻塞
// 3. 执行时序轨迹（Execution Trace Logging）：高保真记录每一次存储调用及故障注入详情，
//    提供同种子 100% 幂等确定性回放（Deterministic Replay）。
// 4. 重试韧性（Retry Resilience）与白盒验证辅助。

///|
#derive(Eq, Debug)
pub(all) enum InjectedFault {
  RateLimit503(String)
  PreconditionFailed412(String)
  NotFound404(String)
  ConnectionReset(String)
  TruncatedRangeGet(Int)
  LatencySpike(Double)
}

///|
pub fn InjectedFault::to_string(self : InjectedFault) -> String {
  match self {
    RateLimit503(msg) => "503 RateLimit/SlowDown: \{msg}"
    PreconditionFailed412(msg) => "412 PreconditionFailed: \{msg}"
    NotFound404(msg) => "404 NotFound: \{msg}"
    ConnectionReset(msg) => "ConnectionReset/Timeout: \{msg}"
    TruncatedRangeGet(n) => "TruncatedRangeGet(-\{n}B)"
    LatencySpike(us) => "LatencySpike(+\{us}us)"
  }
}

///|
#derive(Eq, Debug)
pub(all) enum ChaosOp {
  OpGet(String)
  OpPut(String, Int)
  OpPutIfMatch(String, String?, Int)
  OpGetRange(String, Int, Int)
  OpList(String)
  OpDelete(String)
  OpHeadVersion(String)
}

///|
pub fn ChaosOp::to_string(self : ChaosOp) -> String {
  match self {
    OpGet(k) => "GET \{k}"
    OpPut(k, sz) => "PUT \{k} (\{sz}B)"
    OpPutIfMatch(k, exp, sz) => {
      let e = match exp {
        Some(v) => "expected=\"\{v}\""
        None => "expected=None"
      }
      "PUT_IF_MATCH \{k} (\{e}, \{sz}B)"
    }
    OpGetRange(k, off, len) => "GET_RANGE \{k} [\{off}, \{off + len})"
    OpList(prefix) => "LIST prefix=\"\{prefix}\""
    OpDelete(k) => "DELETE \{k}"
    OpHeadVersion(k) => "HEAD_VERSION \{k}"
  }
}

///|
#derive(Eq, Debug)
pub(all) struct ChaosTraceEvent {
  step : Int
  virtual_time_us : Double
  op : ChaosOp
  injected_fault : InjectedFault?
  success : Bool
  result_summary : String
}

///|
pub fn ChaosTraceEvent::to_string(self : ChaosTraceEvent) -> String {
  let fault_str = match self.injected_fault {
    Some(f) => " [FAULT: \{f.to_string()}]"
    None => ""
  }
  let st = if self.success { "OK" } else { "FAIL" }
  "#\{self.step} t=\{self.virtual_time_us}us \{self.op.to_string()}\{fault_str} => \{st} (\{self.result_summary})"
}

///|
pub struct ChaosRng {
  mut state : UInt64
}

///|
pub fn ChaosRng::new(seed : UInt64) -> ChaosRng {
  let s = if seed == 0UL { 0x853C49E6748FEA9BUL } else { seed }
  { state: s }
}

///|
pub fn ChaosRng::next_u64(self : ChaosRng) -> UInt64 {
  self.state = self.state + 0x9E3779B97F4A7C15UL
  let mut z = self.state
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL
  z ^ (z >> 31)
}

///|
pub fn ChaosRng::next_f64(self : ChaosRng) -> Double {
  let u = self.next_u64() >> 11
  u.to_double() / 9007199254740992.0
}

///|
#derive(Debug)
pub(all) struct FaultRule {
  name : String
  op_pattern : String
  key_prefix : String
  probability : Double
  fault : InjectedFault
  latency_us : Double
  mut max_triggers : Int
  mut triggered_count : Int
}

///|
pub fn FaultRule::rate_limit_503(
  name~ : String = "503-slowdown",
  key_prefix~ : String = "",
  probability~ : Double = 1.0,
  latency_us~ : Double = 10000.0,
  max_triggers~ : Int = -1,
  msg~ : String = "SlowDown",
) -> FaultRule {
  {
    name,
    op_pattern: "*",
    key_prefix,
    probability,
    fault: RateLimit503(msg),
    latency_us,
    max_triggers,
    triggered_count: 0,
  }
}

///|
pub fn FaultRule::cas_conflict_412(
  name~ : String = "412-conflict",
  key_prefix~ : String = "",
  probability~ : Double = 1.0,
  latency_us~ : Double = 1000.0,
  max_triggers~ : Int = -1,
  msg~ : String = "PreconditionFailed",
) -> FaultRule {
  {
    name,
    op_pattern: "PUT_IF_MATCH",
    key_prefix,
    probability,
    fault: PreconditionFailed412(msg),
    latency_us,
    max_triggers,
    triggered_count: 0,
  }
}

///|
pub fn FaultRule::not_found_404(
  name~ : String = "404-notfound",
  key_prefix~ : String = "",
  probability~ : Double = 1.0,
  latency_us~ : Double = 500.0,
  max_triggers~ : Int = -1,
  msg~ : String = "NoSuchKey",
) -> FaultRule {
  {
    name,
    op_pattern: "*",
    key_prefix,
    probability,
    fault: NotFound404(msg),
    latency_us,
    max_triggers,
    triggered_count: 0,
  }
}

///|
pub fn FaultRule::connection_reset(
  name~ : String = "connection-reset",
  key_prefix~ : String = "",
  probability~ : Double = 1.0,
  latency_us~ : Double = 20000.0,
  max_triggers~ : Int = -1,
  msg~ : String = "ConnectionReset",
) -> FaultRule {
  {
    name,
    op_pattern: "*",
    key_prefix,
    probability,
    fault: ConnectionReset(msg),
    latency_us,
    max_triggers,
    triggered_count: 0,
  }
}

///|
pub fn FaultRule::truncated_range_get(
  drop_bytes : Int,
  name~ : String = "truncate-range",
  key_prefix~ : String = "",
  probability~ : Double = 1.0,
  latency_us~ : Double = 2000.0,
  max_triggers~ : Int = -1,
) -> FaultRule {
  {
    name,
    op_pattern: "GET_RANGE",
    key_prefix,
    probability,
    fault: TruncatedRangeGet(drop_bytes),
    latency_us,
    max_triggers,
    triggered_count: 0,
  }
}

///|
pub fn FaultRule::latency_spike(
  spike_us : Double,
  name~ : String = "latency-spike",
  key_prefix~ : String = "",
  probability~ : Double = 1.0,
  max_triggers~ : Int = -1,
) -> FaultRule {
  {
    name,
    op_pattern: "*",
    key_prefix,
    probability,
    fault: LatencySpike(spike_us),
    latency_us: spike_us,
    max_triggers,
    triggered_count: 0,
  }
}

///|
pub struct ChaosStore[S] {
  inner : S
  seed : UInt64
  rng : ChaosRng
  rules : Array[FaultRule]
  trace : Array[ChaosTraceEvent]
  mut virtual_time_us : Double
  mut base_latency_us : Double
  mut step : Int
  mut faults_injected : Int
  mut total_calls : Int
  mut last_injected_fault : InjectedFault?
  mut enabled : Bool
}

///|
pub fn[S] ChaosStore::new(inner : S, seed : UInt64) -> ChaosStore[S] {
  {
    inner,
    seed,
    rng: ChaosRng::new(seed),
    rules: [],
    trace: [],
    virtual_time_us: 0.0,
    base_latency_us: 1000.0,
    step: 0,
    faults_injected: 0,
    total_calls: 0,
    last_injected_fault: None,
    enabled: true,
  }
}

///|
pub fn[S] ChaosStore::inner(self : ChaosStore[S]) -> S {
  self.inner
}

///|
pub fn[S] ChaosStore::seed(self : ChaosStore[S]) -> UInt64 {
  self.seed
}

///|
pub fn[S] ChaosStore::virtual_time_us(self : ChaosStore[S]) -> Double {
  self.virtual_time_us
}

///|
pub fn[S] ChaosStore::elapsed_virtual_ms(self : ChaosStore[S]) -> Double {
  self.virtual_time_us / 1000.0
}

///|
pub fn[S] ChaosStore::set_base_latency(
  self : ChaosStore[S],
  us : Double,
) -> Unit {
  self.base_latency_us = us
}

///|
pub fn[S] ChaosStore::set_enabled(self : ChaosStore[S], enabled : Bool) -> Unit {
  self.enabled = enabled
}

///|
pub fn[S] ChaosStore::add_rule(self : ChaosStore[S], rule : FaultRule) -> Unit {
  self.rules.push(rule)
}

///|
pub fn[S] ChaosStore::clear_rules(self : ChaosStore[S]) -> Unit {
  self.rules.clear()
}

///|
pub fn[S] ChaosStore::faults_injected(self : ChaosStore[S]) -> Int {
  self.faults_injected
}

///|
pub fn[S] ChaosStore::total_calls(self : ChaosStore[S]) -> Int {
  self.total_calls
}

///|
pub fn[S] ChaosStore::last_fault(self : ChaosStore[S]) -> InjectedFault? {
  self.last_injected_fault
}

///|
pub fn[S] ChaosStore::get_trace(
  self : ChaosStore[S],
) -> Array[ChaosTraceEvent] {
  self.trace
}

///|
pub fn[S] ChaosStore::clear_trace(self : ChaosStore[S]) -> Unit {
  self.trace.clear()
}

///|
pub fn[S] ChaosStore::dump_trace(self : ChaosStore[S]) -> String {
  let mut out = ""
  for ev in self.trace {
    out = out + ev.to_string() + "\n"
  }
  out
}

///|
pub fn[S] ChaosStore::trace_summary(self : ChaosStore[S]) -> String {
  "ChaosStore[seed=\{self.seed}]: \{self.total_calls} calls, \{self.faults_injected} faults injected, virtual_time=\{self.virtual_time_us}us"
}

///|
pub fn[S] ChaosStore::replay_reset(self : ChaosStore[S]) -> Unit {
  self.rng.state = if self.seed == 0UL { 0x853C49E6748FEA9BUL } else { self.seed }
  self.trace.clear()
  self.virtual_time_us = 0.0
  self.step = 0
  self.faults_injected = 0
  self.total_calls = 0
  self.last_injected_fault = None
  for r in self.rules {
    r.triggered_count = 0
  }
}

///|
pub fn[S] ChaosStore::inject_503(
  self : ChaosStore[S],
  key_prefix~ : String = "",
  probability~ : Double = 1.0,
  latency_us~ : Double = 10000.0,
  max_triggers~ : Int = -1,
  msg~ : String = "SlowDown",
) -> Unit {
  self.add_rule(
    FaultRule::rate_limit_503(
      key_prefix~,
      probability~,
      latency_us~,
      max_triggers~,
      msg~,
    ),
  )
}

///|
pub fn[S] ChaosStore::inject_412(
  self : ChaosStore[S],
  key_prefix~ : String = "",
  probability~ : Double = 1.0,
  latency_us~ : Double = 1000.0,
  max_triggers~ : Int = -1,
  msg~ : String = "PreconditionFailed",
) -> Unit {
  self.add_rule(
    FaultRule::cas_conflict_412(
      key_prefix~,
      probability~,
      latency_us~,
      max_triggers~,
      msg~,
    ),
  )
}

///|
pub fn[S] ChaosStore::inject_404(
  self : ChaosStore[S],
  key_prefix~ : String = "",
  probability~ : Double = 1.0,
  latency_us~ : Double = 500.0,
  max_triggers~ : Int = -1,
  msg~ : String = "NoSuchKey",
) -> Unit {
  self.add_rule(
    FaultRule::not_found_404(
      key_prefix~,
      probability~,
      latency_us~,
      max_triggers~,
      msg~,
    ),
  )
}

///|
pub fn[S] ChaosStore::inject_connection_reset(
  self : ChaosStore[S],
  key_prefix~ : String = "",
  probability~ : Double = 1.0,
  latency_us~ : Double = 20000.0,
  max_triggers~ : Int = -1,
  msg~ : String = "ConnectionReset",
) -> Unit {
  self.add_rule(
    FaultRule::connection_reset(
      key_prefix~,
      probability~,
      latency_us~,
      max_triggers~,
      msg~,
    ),
  )
}

///|
pub fn[S] ChaosStore::inject_truncated_range(
  self : ChaosStore[S],
  drop_bytes : Int,
  key_prefix~ : String = "",
  probability~ : Double = 1.0,
  latency_us~ : Double = 2000.0,
  max_triggers~ : Int = -1,
) -> Unit {
  self.add_rule(
    FaultRule::truncated_range_get(
      drop_bytes,
      key_prefix~,
      probability~,
      latency_us~,
      max_triggers~,
    ),
  )
}

///|
pub fn[S] ChaosStore::inject_latency_spike(
  self : ChaosStore[S],
  spike_us : Double,
  key_prefix~ : String = "",
  probability~ : Double = 1.0,
  max_triggers~ : Int = -1,
) -> Unit {
  self.add_rule(
    FaultRule::latency_spike(
      spike_us,
      key_prefix~,
      probability~,
      max_triggers~,
    ),
  )
}

///|
fn[S] ChaosStore::record_trace(
  self : ChaosStore[S],
  op : ChaosOp,
  injected_fault : InjectedFault?,
  success : Bool,
  summary : String,
) -> Unit {
  let ev = {
    step: self.step,
    virtual_time_us: self.virtual_time_us,
    op,
    injected_fault,
    success,
    result_summary: summary,
  }
  self.trace.push(ev)
  self.step += 1
}

///|
fn[S] ChaosStore::evaluate_fault(
  self : ChaosStore[S],
  op_name : String,
  key : String,
) -> InjectedFault? {
  self.total_calls += 1
  self.last_injected_fault = None
  if !self.enabled {
    return None
  }
  for r in self.rules {
    if r.max_triggers >= 0 && r.triggered_count >= r.max_triggers {
      continue
    }
    if r.op_pattern != "*" && r.op_pattern != op_name {
      continue
    }
    if r.key_prefix != "" && !key.has_prefix(r.key_prefix) {
      continue
    }
    let fires = if r.probability >= 1.0 {
      true
    } else if r.probability <= 0.0 {
      false
    } else {
      self.rng.next_f64() < r.probability
    }
    if fires {
      r.triggered_count += 1
      self.faults_injected += 1
      self.last_injected_fault = Some(r.fault)
      self.virtual_time_us += r.latency_us
      return Some(r.fault)
    }
  }
  None
}

///|
pub impl[S : @store.ObjectStore] @store.ObjectStore for ChaosStore[S] with fn get(
  self : ChaosStore[S],
  key : String,
) -> Bytes? {
  let op = OpGet(key)
  let fault = self.evaluate_fault("GET", key)
  match fault {
    Some(RateLimit503(msg)) => {
      self.record_trace(op, fault, false, "503 SlowDown: \{msg}")
      None
    }
    Some(PreconditionFailed412(msg)) => {
      self.record_trace(op, fault, false, "412 PreconditionFailed: \{msg}")
      None
    }
    Some(NotFound404(msg)) => {
      self.record_trace(op, fault, false, "404 NotFound: \{msg}")
      None
    }
    Some(ConnectionReset(msg)) => {
      self.record_trace(op, fault, false, "ConnectionReset/Timeout: \{msg}")
      None
    }
    Some(TruncatedRangeGet(_)) => {
      self.virtual_time_us += self.base_latency_us
      let res = self.inner.get(key)
      let (succ, desc) = match res {
        Some(bs) => (true, "Some(\{bs.length()}B)")
        None => (false, "None")
      }
      self.record_trace(op, None, succ, desc)
      res
    }
    Some(LatencySpike(us)) => {
      self.virtual_time_us += self.base_latency_us
      let res = self.inner.get(key)
      let (succ, desc) = match res {
        Some(bs) => (true, "Some(\{bs.length()}B)")
        None => (false, "None")
      }
      self.record_trace(op, fault, succ, "\{desc} [spike +\{us}us]")
      res
    }
    None => {
      self.virtual_time_us += self.base_latency_us
      let res = self.inner.get(key)
      let (succ, desc) = match res {
        Some(bs) => (true, "Some(\{bs.length()}B)")
        None => (false, "None")
      }
      self.record_trace(op, None, succ, desc)
      res
    }
  }
}

///|
pub impl[S : @store.ObjectStore] @store.ObjectStore for ChaosStore[S] with fn put(
  self : ChaosStore[S],
  key : String,
  value : Bytes,
) -> Unit {
  let op = OpPut(key, value.length())
  let fault = self.evaluate_fault("PUT", key)
  match fault {
    Some(RateLimit503(msg)) => {
      self.record_trace(op, fault, false, "503 SlowDown: \{msg}")
      ()
    }
    Some(PreconditionFailed412(msg)) => {
      self.record_trace(op, fault, false, "412 Conflict: \{msg}")
      ()
    }
    Some(NotFound404(msg)) => {
      self.record_trace(op, fault, false, "404 NotFound: \{msg}")
      ()
    }
    Some(ConnectionReset(msg)) => {
      self.record_trace(op, fault, false, "ConnectionReset/Timeout: \{msg}")
      ()
    }
    Some(LatencySpike(us)) => {
      self.virtual_time_us += self.base_latency_us
      self.inner.put(key, value)
      self.record_trace(
        op,
        fault,
        true,
        "OK (\{value.length()}B) [spike +\{us}us]",
      )
    }
    Some(TruncatedRangeGet(_)) => {
      self.virtual_time_us += self.base_latency_us
      self.inner.put(key, value)
      self.record_trace(op, None, true, "OK (\{value.length()}B)")
    }
    None => {
      self.virtual_time_us += self.base_latency_us
      self.inner.put(key, value)
      self.record_trace(op, None, true, "OK (\{value.length()}B)")
    }
  }
}

///|
pub impl[S : @store.ObjectStore] @store.ObjectStore for ChaosStore[S] with fn put_if_match(
  self : ChaosStore[S],
  key : String,
  expected : String?,
  value : Bytes,
) -> Bool {
  let op = OpPutIfMatch(key, expected, value.length())
  let fault = self.evaluate_fault("PUT_IF_MATCH", key)
  match fault {
    Some(PreconditionFailed412(msg)) => {
      self.record_trace(
        op,
        fault,
        false,
        "412 PreconditionFailed (CAS conflict): \{msg}",
      )
      false
    }
    Some(RateLimit503(msg)) => {
      self.record_trace(op, fault, false, "503 SlowDown: \{msg}")
      false
    }
    Some(ConnectionReset(msg)) => {
      self.record_trace(op, fault, false, "ConnectionReset/Timeout: \{msg}")
      false
    }
    Some(NotFound404(msg)) => {
      self.record_trace(op, fault, false, "404 NotFound: \{msg}")
      false
    }
    Some(LatencySpike(us)) => {
      self.virtual_time_us += self.base_latency_us
      let ok = self.inner.put_if_match(key, expected, value)
      self.record_trace(op, fault, ok, "CAS=\{ok} [spike +\{us}us]")
      ok
    }
    Some(TruncatedRangeGet(_)) => {
      self.virtual_time_us += self.base_latency_us
      let ok = self.inner.put_if_match(key, expected, value)
      self.record_trace(op, None, ok, "CAS=\{ok}")
      ok
    }
    None => {
      self.virtual_time_us += self.base_latency_us
      let ok = self.inner.put_if_match(key, expected, value)
      self.record_trace(op, None, ok, "CAS=\{ok}")
      ok
    }
  }
}

///|
pub impl[S : @store.ObjectStore] @store.ObjectStore for ChaosStore[S] with fn get_range(
  self : ChaosStore[S],
  key : String,
  offset : Int,
  len : Int,
) -> Bytes? {
  let op = OpGetRange(key, offset, len)
  let fault = self.evaluate_fault("GET_RANGE", key)
  match fault {
    Some(RateLimit503(msg)) => {
      self.record_trace(op, fault, false, "503 SlowDown: \{msg}")
      None
    }
    Some(PreconditionFailed412(msg)) => {
      self.record_trace(op, fault, false, "412 PreconditionFailed: \{msg}")
      None
    }
    Some(NotFound404(msg)) => {
      self.record_trace(op, fault, false, "404 NotFound: \{msg}")
      None
    }
    Some(ConnectionReset(msg)) => {
      self.record_trace(op, fault, false, "ConnectionReset/Timeout: \{msg}")
      None
    }
    Some(TruncatedRangeGet(drop_bytes)) => {
      self.virtual_time_us += self.base_latency_us
      let res = self.inner.get_range(key, offset, len)
      match res {
        Some(payload) => {
          let orig_len = payload.length()
          let keep_len = if orig_len > drop_bytes {
            orig_len - drop_bytes
          } else {
            0
          }
          let truncated = if keep_len <= 0 {
            Bytes::make(0, b'\x00')
          } else {
            payload[0:keep_len].to_owned()
          }
          self.record_trace(
            op,
            fault,
            false,
            "Truncated \{orig_len}B -> \{keep_len}B (dropped \{drop_bytes}B)",
          )
          Some(truncated)
        }
        None => {
          self.record_trace(op, fault, false, "None")
          None
        }
      }
    }
    Some(LatencySpike(us)) => {
      self.virtual_time_us += self.base_latency_us
      let res = self.inner.get_range(key, offset, len)
      let (succ, desc) = match res {
        Some(bs) => (true, "Some(\{bs.length()}B)")
        None => (false, "None")
      }
      self.record_trace(op, fault, succ, "\{desc} [spike +\{us}us]")
      res
    }
    None => {
      self.virtual_time_us += self.base_latency_us
      let res = self.inner.get_range(key, offset, len)
      let (succ, desc) = match res {
        Some(bs) => (true, "Some(\{bs.length()}B)")
        None => (false, "None")
      }
      self.record_trace(op, None, succ, desc)
      res
    }
  }
}

///|
pub impl[S : @store.ObjectStore] @store.ObjectStore for ChaosStore[S] with fn list(
  self : ChaosStore[S],
  prefix : String,
) -> Array[String] {
  let op = OpList(prefix)
  let fault = self.evaluate_fault("LIST", prefix)
  match fault {
    Some(RateLimit503(msg)) => {
      self.record_trace(op, fault, false, "503 SlowDown: \{msg}")
      []
    }
    Some(PreconditionFailed412(msg)) => {
      self.record_trace(op, fault, false, "412 Conflict: \{msg}")
      []
    }
    Some(NotFound404(msg)) => {
      self.record_trace(op, fault, false, "404 NotFound: \{msg}")
      []
    }
    Some(ConnectionReset(msg)) => {
      self.record_trace(op, fault, false, "ConnectionReset/Timeout: \{msg}")
      []
    }
    Some(LatencySpike(us)) => {
      self.virtual_time_us += self.base_latency_us
      let res = self.inner.list(prefix)
      self.record_trace(
        op,
        fault,
        true,
        "count=\{res.length()} [spike +\{us}us]",
      )
      res
    }
    Some(TruncatedRangeGet(_)) => {
      self.virtual_time_us += self.base_latency_us
      let res = self.inner.list(prefix)
      self.record_trace(op, None, true, "count=\{res.length()}")
      res
    }
    None => {
      self.virtual_time_us += self.base_latency_us
      let res = self.inner.list(prefix)
      self.record_trace(op, None, true, "count=\{res.length()}")
      res
    }
  }
}

///|
pub impl[S : @store.ObjectStore] @store.ObjectStore for ChaosStore[S] with fn delete(
  self : ChaosStore[S],
  key : String,
) -> Unit {
  let op = OpDelete(key)
  let fault = self.evaluate_fault("DELETE", key)
  match fault {
    Some(RateLimit503(msg)) => {
      self.record_trace(op, fault, false, "503 SlowDown: \{msg}")
      ()
    }
    Some(PreconditionFailed412(msg)) => {
      self.record_trace(op, fault, false, "412 Conflict: \{msg}")
      ()
    }
    Some(NotFound404(msg)) => {
      self.record_trace(op, fault, false, "404 NotFound: \{msg}")
      ()
    }
    Some(ConnectionReset(msg)) => {
      self.record_trace(op, fault, false, "ConnectionReset/Timeout: \{msg}")
      ()
    }
    Some(LatencySpike(us)) => {
      self.virtual_time_us += self.base_latency_us
      self.inner.delete(key)
      self.record_trace(op, fault, true, "OK [spike +\{us}us]")
    }
    Some(TruncatedRangeGet(_)) => {
      self.virtual_time_us += self.base_latency_us
      self.inner.delete(key)
      self.record_trace(op, None, true, "OK")
    }
    None => {
      self.virtual_time_us += self.base_latency_us
      self.inner.delete(key)
      self.record_trace(op, None, true, "OK")
    }
  }
}

///|
pub impl[S : @store.ObjectStore] @store.ObjectStore for ChaosStore[S] with fn head_version(
  self : ChaosStore[S],
  key : String,
) -> String? {
  let op = OpHeadVersion(key)
  let fault = self.evaluate_fault("HEAD_VERSION", key)
  match fault {
    Some(RateLimit503(msg)) => {
      self.record_trace(op, fault, false, "503 SlowDown: \{msg}")
      None
    }
    Some(PreconditionFailed412(msg)) => {
      self.record_trace(op, fault, false, "412 Conflict: \{msg}")
      None
    }
    Some(NotFound404(msg)) => {
      self.record_trace(op, fault, false, "404 NotFound: \{msg}")
      None
    }
    Some(ConnectionReset(msg)) => {
      self.record_trace(op, fault, false, "ConnectionReset/Timeout: \{msg}")
      None
    }
    Some(LatencySpike(us)) => {
      self.virtual_time_us += self.base_latency_us
      let res = self.inner.head_version(key)
      let (succ, desc) = match res {
        Some(v) => (true, "Some(\"\{v}\")")
        None => (false, "None")
      }
      self.record_trace(op, fault, succ, "\{desc} [spike +\{us}us]")
      res
    }
    Some(TruncatedRangeGet(_)) => {
      self.virtual_time_us += self.base_latency_us
      let res = self.inner.head_version(key)
      let (succ, desc) = match res {
        Some(v) => (true, "Some(\"\{v}\")")
        None => (false, "None")
      }
      self.record_trace(op, None, succ, desc)
      res
    }
    None => {
      self.virtual_time_us += self.base_latency_us
      let res = self.inner.head_version(key)
      let (succ, desc) = match res {
        Some(v) => (true, "Some(\"\{v}\")")
        None => (false, "None")
      }
      self.record_trace(op, None, succ, desc)
      res
    }
  }
}

///|
pub extend ChaosStore with @store.ObjectStore::{
  get,
  put,
  put_if_match,
  get_range,
  list,
  delete,
  head_version,
}

///|
pub fn[S : @store.ObjectStore] ChaosStore::get_or_raise(
  self : ChaosStore[S],
  key : String,
) -> Bytes raise @core.SpndError {
  match self.get(key) {
    Some(b) => b
    None => raise @core.NotFound("ChaosStore: get failed for key \{key}")
  }
}

///|
pub fn[S : @store.ObjectStore] ChaosStore::get_range_or_raise(
  self : ChaosStore[S],
  key : String,
  offset : Int,
  len : Int,
) -> Bytes raise @core.SpndError {
  match self.get_range(key, offset, len) {
    Some(b) => {
      if b.length() < len {
        raise @core.Truncated(
          "ChaosStore: partial range read for \{key}: expected \{len}B, got \{b.length()}B",
        )
      }
      b
    }
    None => raise @core.NotFound("ChaosStore: get_range failed for key \{key}")
  }
}

///|
pub fn[S : @store.ObjectStore] ChaosStore::retry_get(
  self : ChaosStore[S],
  key : String,
  max_attempts : Int,
) -> Bytes? {
  for _ in 0..<max_attempts {
    match self.get(key) {
      Some(v) => return Some(v)
      None =>
        match self.last_injected_fault {
          None => return None
          Some(_) => ()
        }
    }
  }
  None
}

///|
pub fn[S : @store.ObjectStore] ChaosStore::retry_get_range(
  self : ChaosStore[S],
  key : String,
  offset : Int,
  len : Int,
  max_attempts : Int,
) -> Bytes? {
  for _ in 0..<max_attempts {
    match self.get_range(key, offset, len) {
      Some(v) => if v.length() >= len { return Some(v) }
      None =>
        match self.last_injected_fault {
          None => return None
          Some(_) => ()
        }
    }
  }
  None
}

///|
pub fn[S : @store.ObjectStore] ChaosStore::retry_put(
  self : ChaosStore[S],
  key : String,
  value : Bytes,
  max_attempts : Int,
) -> Bool {
  for _ in 0..<max_attempts {
    self.put(key, value)
    match self.last_injected_fault {
      None => return true
      Some(LatencySpike(_)) => return true
      Some(_) => ()
    }
  }
  false
}

///|
pub fn[S : @store.ObjectStore] ChaosStore::retry_cas(
  self : ChaosStore[S],
  key : String,
  max_attempts : Int,
  mutate : (Bytes?) -> Bytes,
) -> Bool {
  for _ in 0..<max_attempts {
    let cur_ver = self.head_version(key)
    let cur_val = self.get(key)
    let next_val = mutate(cur_val)
    if self.put_if_match(key, cur_ver, next_val) {
      return true
    }
  }
  false
}
