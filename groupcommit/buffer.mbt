// 通用「每 Namespace 组提交」缓冲器（Group Commit）。
//
// 目标：把同一 namespace 上并发到达的小批量写入合并成一次 S3 刷盘，并且
// **绝不丢已确认写**（严格模式）。
//
// 关键机制：
//   - 每个 namespace 一份 NsState：一个正在积累的 PendingBatch + 一批等待者。
//   - 触发条件二选一：凑满 max_batch_rows / max_batch_bytes，或等待满
//     flush_interval_ms（由后台计时协程在 TaskGroup 上 spawn 出来）。
//   - 切批与“唤醒谁”在同一把锁内完成：切批时把 pending 与 waiters 一起搬走，
//     生成新的一代（gen），因此新到的 submit 自然落到下一批（双缓冲流水线）。
//   - 刷盘在锁外执行：前一批正在跑慢速 S3 flush_fn 时，新到达的 submit 立即
//     进入下一批积累，互不阻塞。
//   - flush_fn 成功 → 本批所有等待者拿到同一个 head；失败 → 本批等待者全部
//     收到错误，不影响下一批。
//   - 活跃 L0 批次数达到 max_l0_pending 时 submit 立即返回 Backpressure
//     （对应 HTTP 429），避免无界堆积。
//
// 说明：等待者使用「一次性信号量」而不是条件变量，release 在没有等待者时
// 也会累加计数，因此天然不存在丢失唤醒的窗口。

///|
/// 组提交错误。
pub suberror GroupCommitError {
  /// 当前 namespace 的活跃 L0 批次数已达上限（快速拒绝，语义对应 HTTP 429）。
  Backpressure(String)
  /// 注入的 flush 闭包失败：本批所有等待者都会收到该错误。
  FlushFailed(String)
}

///|
/// 单次提交的结果。
pub(all) enum SubmitResult {
  /// lazy 模式：已进入当前批次，立即返回，不保证已经持久化。
  AckedLazy
  /// 严格模式：本批已刷盘，返回新的 head manifest id（非空）。
  Flushed(String)
}

///|
/// 取严格模式下刷盘后的 head；lazy 模式返回 None。
pub fn SubmitResult::head(self : SubmitResult) -> String? {
  match self {
    AckedLazy => None
    Flushed(h) => Some(h)
  }
}

///|
/// 组提交配置。
pub struct GroupCommitConfig {
  /// 攒批等待上限（毫秒）
  flush_interval_ms : Int
  /// 单批行数上限
  max_batch_rows : Int
  /// 单批字节上限
  max_batch_bytes : Int
  /// 同一 namespace 允许的活跃 L0 批次数上限
  max_l0_pending : Int
}

///|
/// 默认配置：25ms / 2048 行 / 8MB / 12 个活跃 L0 批次。
pub fn GroupCommitConfig::default() -> GroupCommitConfig {
  {
    flush_interval_ms: 25,
    max_batch_rows: 2048,
    max_batch_bytes: 8 * 1024 * 1024,
    max_l0_pending: 12,
  }
}

///|
/// 一条待刷记录：行数、字节数与该记录对应的不透明 payload。
priv struct PendingEntry {
  rows : Int
  bytes : Int
  payload : Bytes
}

///|
/// 一批等待者的完成信号（一次性事件）。
priv struct Completion {
  sem : @semaphore.Semaphore
  mut ok : Bool
  mut head : String
  mut err : Error?
}

///|
fn Completion::new() -> Completion {
  {
    sem: @semaphore.Semaphore::Semaphore(1, initial_value=0),
    ok: false,
    head: "",
    err: None,
  }
}

///|
/// 单个 namespace 的组提交状态。
struct NsState {
  /// 正在积累的批次
  mut pending : Array[PendingEntry]
  /// 属于当前积累批次的严格模式等待者（与 pending 同生共死）
  mut waiters : Array[Completion]
  mut pending_rows : Int
  mut pending_bytes : Int
  /// 批代号：每次切批 +1，新到的 submit 落到新的一代
  mut gen : Int
  /// 是否已有计时协程在为本批计时
  mut timer_active : Bool
  /// 当前活跃（正在跑 flush_fn）的批次数
  mut inflight : Int
}

///|
fn NsState::new() -> NsState {
  {
    pending: [],
    waiters: [],
    pending_rows: 0,
    pending_bytes: 0,
    gen: 0,
    timer_active: false,
    inflight: 0,
  }
}

///|
/// 每 namespace 组提交管理器。
///
/// `group` 用于派发后台计时/刷盘协程（调用方持有 TaskGroup 生命周期）。
/// `flush_fn(ns, payloads) -> head_manifest_id` 是注入的异步刷盘闭包
/// （真实实现通常是一次 S3 批量 PUT）。
pub struct GroupCommitManager {
  group : @async.TaskGroup[Unit]
  flush_fn : async (String, Array[Bytes]) -> String
  config : GroupCommitConfig
  lock : @async.Mutex
  states : Map[String, NsState]
  mut flush_calls : Int
  mut flushed_rows : Int
  mut flushed_bytes : Int
}

///|
/// 创建管理器。`group` 的生命周期必须覆盖所有提交与刷盘。
pub fn GroupCommitManager::new(
  group : @async.TaskGroup[Unit],
  flush_fn : async (String, Array[Bytes]) -> String,
  config? : GroupCommitConfig = GroupCommitConfig::default(),
) -> GroupCommitManager {
  {
    group,
    flush_fn,
    config,
    lock: @async.Mutex::Mutex(),
    states: Map([]),
    flush_calls: 0,
    flushed_rows: 0,
    flushed_bytes: 0,
  }
}

///|
/// 取（必要时创建）namespace 状态。必须在持有 self.lock 时调用。
fn GroupCommitManager::state(
  self : GroupCommitManager,
  ns : String,
) -> NsState {
  match self.states.get(ns) {
    Some(s) => s
    None => {
      let s = NsState::new()
      self.states.set(ns, s)
      s
    }
  }
}

///|
/// 派发一次「到点切批并刷盘」的后台协程。
fn GroupCommitManager::spawn_timer(
  self : GroupCommitManager,
  ns : String,
  gen : Int,
) -> Unit {
  self.group.spawn_bg(
    no_wait=true,
    allow_failure=true,
    async fn () {
      @async.sleep(self.config.flush_interval_ms)
      self.lock.acquire()
      let st = self.state(ns)
      // 本代已被别的协程切走（凑满批或已刷完）→ 计时器过期，直接退出。
      let same_gen = st.gen == gen
      if same_gen {
        st.timer_active = false
      }
      let has_pending = same_gen && !st.pending.is_empty()
      self.lock.release()
      if has_pending {
        self.flush_ns(ns)
      }
    },
  )
}

///|
/// 派发一次「立即切批并刷盘」的后台协程。
fn GroupCommitManager::spawn_flush(
  self : GroupCommitManager,
  ns : String,
) -> Unit {
  self.group.spawn_bg(
    no_wait=true,
    allow_failure=true,
    async fn () {
      self.flush_ns(ns)
    },
  )
}

///|
/// 切出当前批次并刷盘；没有待刷记录时是幂等空操作。
///
/// 切批（清 pending、搬走 waiters、gen+1、inflight+1）在锁内完成，
/// 真正的 `flush_fn` 调用在锁外执行，因此下一批可以并行积累。
async fn GroupCommitManager::flush_ns(
  self : GroupCommitManager,
  ns : String,
) -> Unit {
  self.lock.acquire()
  let st = self.state(ns)
  if st.pending.is_empty() {
    st.timer_active = false
    self.lock.release()
    return
  }
  if st.inflight >= self.config.max_l0_pending {
    // 活跃批次已满：保留 pending 不丢，稍后再试（submit 侧已快速拒绝新请求）。
    let retry = !st.timer_active
    if retry {
      st.timer_active = true
    }
    let gen = st.gen
    self.lock.release()
    if retry {
      self.spawn_timer(ns, gen)
    }
    return
  }
  let entries = st.pending
  let waiters = st.waiters
  st.pending = []
  st.waiters = []
  st.pending_rows = 0
  st.pending_bytes = 0
  st.gen += 1
  st.timer_active = false
  st.inflight += 1
  self.lock.release()
  let payloads : Array[Bytes] = []
  let mut rows = 0
  let mut bytes = 0
  for e in entries {
    payloads.push(e.payload)
    rows += e.rows
    bytes += e.bytes
  }
  let res : Result[String, Error] = try {
    Ok((self.flush_fn)(ns, payloads))
  } catch {
    e => Err(e)
  }
  self.lock.acquire()
  st.inflight -= 1
  match res {
    Ok(head) => {
      for w in waiters {
        w.ok = true
        w.head = head
      }
    }
    Err(e) => {
      for w in waiters {
        w.err = Some(e)
      }
    }
  }
  self.flush_calls += 1
  self.flushed_rows += rows
  self.flushed_bytes += bytes
  self.lock.release()
  // 信号量 release 即使暂时无人等待也会累加计数，不存在丢失唤醒。
  for w in waiters {
    w.sem.release()
  }
}

///|
/// 提交一条写入。
///
/// - `durability_strict = true`（默认）：加入当前批次并等待整批刷盘，
///   返回 `Flushed(head)`；批次凑满或等待满 `flush_interval_ms` 即触发刷盘。
/// - `durability_strict = false`：只入批并确保有计时协程，立即返回 `AckedLazy`。
///
/// 活跃 L0 批次达到 `max_l0_pending` 时立即 `raise Backpressure`（不排队）。
pub async fn GroupCommitManager::submit(
  self : GroupCommitManager,
  ns : String,
  row_count : Int,
  byte_size : Int,
  payload : Bytes,
  durability_strict? : Bool = true,
) -> SubmitResult {
  let completion = Completion::new()
  let mut arm_timer = false
  let mut flush_now = false
  let mut timer_gen = 0
  self.lock.acquire()
  let st = self.state(ns)
  if st.inflight >= self.config.max_l0_pending {
    self.lock.release()
    raise GroupCommitError::Backpressure(
      "namespace \{ns} already has \{st.inflight} in-flight L0 batches",
    )
  }
  st.pending.push({
    rows: if row_count < 0 { 0 } else { row_count },
    bytes: if byte_size < 0 { 0 } else { byte_size },
    payload,
  })
  st.pending_rows += if row_count < 0 { 0 } else { row_count }
  st.pending_bytes += if byte_size < 0 { 0 } else { byte_size }
  if durability_strict {
    st.waiters.push(completion)
  }
  let full = st.pending_rows >= self.config.max_batch_rows ||
    st.pending_bytes >= self.config.max_batch_bytes
  if full {
    st.timer_active = false
    flush_now = true
  } else if !st.timer_active {
    st.timer_active = true
    arm_timer = true
    timer_gen = st.gen
  }
  self.lock.release()
  if flush_now {
    self.spawn_flush(ns)
  } else if arm_timer {
    self.spawn_timer(ns, timer_gen)
  }
  if !durability_strict {
    return AckedLazy
  }
  completion.sem.acquire()
  match completion.err {
    Some(e) => raise e
    None =>
      if completion.ok {
        Flushed(completion.head)
      } else {
        raise GroupCommitError::FlushFailed("batch completed without head")
      }
  }
}

///|
/// 累计 `flush_fn` 调用次数（观测/测试用）。
pub async fn GroupCommitManager::flush_count(
  self : GroupCommitManager,
) -> Int {
  self.lock.acquire()
  let n = self.flush_calls
  self.lock.release()
  n
}

///|
/// 累计已刷盘行数（观测/测试用）。
pub async fn GroupCommitManager::flushed_rows(
  self : GroupCommitManager,
) -> Int {
  self.lock.acquire()
  let n = self.flushed_rows
  self.lock.release()
  n
}

///|
/// 某个 namespace 当前活跃的 L0 批次数（观测/测试用）。
pub async fn GroupCommitManager::inflight(
  self : GroupCommitManager,
  ns : String,
) -> Int {
  self.lock.acquire()
  let n = self.state(ns).inflight
  self.lock.release()
  n
}

///|
/// 组提交错误对应的 HTTP 状态码：反压 → 429，刷盘失败 → 500。
/// （服务层把 submit 的错误直接映射成响应码时使用。）
pub fn GroupCommitError::http_status(self : GroupCommitError) -> Int {
  match self {
    Backpressure(_) => 429
    FlushFailed(_) => 500
  }
}
