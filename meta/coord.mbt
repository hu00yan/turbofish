// metad 控制面协调原语（纯内存、纯 MoonBit、无 libcurl）。
//
// 这两件东西是 compactd / 写者进程之间协调的全部共享状态：
//   - LeaseTable：资源租约（`compact:{ns}` 等），单调毫秒时钟 @env.now() 判定过期，
//     同 holder 重复 acquire 等价于续期，每次授予 +1 epoch（fencing token）。
//   - DirtyQueue：待合并 namespace 的 FIFO 脏队列，天然去重；claim 时逐个尝试
//     抢租约，抢不到就留在队列里等下一轮（不丢、不乱序）。
//
// 两个结构都自带 @async.Mutex，可被多个 HTTP 连接协程并发调用。

///|
/// 单调毫秒时钟（epoch ms）。
pub fn now_ms() -> UInt64 {
  @env.now()
}

///|
/// 一条租约。
pub struct Lease {
  mut holder : String
  mut epoch : UInt64
  mut expires_at : UInt64
}

///|
/// acquire 的结果。
pub(all) enum AcquireResult {
  /// 授予（或续期）成功，携带新的 fencing epoch
  Granted(UInt64)
  /// 已被其他 holder 占用（未过期）
  Denied(String)
}

///|
/// 资源租约表。所有方法都是协程安全的。
pub struct LeaseTable {
  lock : @async.Mutex
  leases : Map[String, Lease]
  mut epoch : UInt64
}

///|
pub fn LeaseTable::new() -> LeaseTable {
  { lock: @async.Mutex::Mutex(), leases: Map([]), epoch: 0UL }
}

///|
fn ttl_deadline(now : UInt64, ttl_ms : Int) -> UInt64 {
  if ttl_ms <= 0 {
    now
  } else {
    now + ttl_ms.to_uint64()
  }
}

///|
/// 申请租约：
///   - 未被占用 / 已过期 / 当前 holder 就是自己 → 授予（续期），epoch +1
///   - 被其他 holder 占用且未过期 → Denied(当前 holder)
pub async fn LeaseTable::acquire(
  self : LeaseTable,
  resource : String,
  holder : String,
  ttl_ms : Int,
) -> AcquireResult {
  self.lock.acquire()
  let now = now_ms()
  let expiry = ttl_deadline(now, ttl_ms)
  let result = match self.leases.get(resource) {
    Some(l) =>
      if l.holder == holder || now >= l.expires_at {
        l.holder = holder
        l.expires_at = expiry
        self.epoch += 1
        l.epoch = self.epoch
        AcquireResult::Granted(l.epoch)
      } else {
        AcquireResult::Denied(l.holder)
      }
    None => {
      self.epoch += 1
      self.leases.set(
        resource,
        { holder, epoch: self.epoch, expires_at: expiry },
      )
      AcquireResult::Granted(self.epoch)
    }
  }
  self.lock.release()
  result
}

///|
/// 续期：仅当资源存在、holder 匹配且**未过期**时成功。
/// 过期租约不再能被原 holder 续期（需要重新 acquire，可能已被别人拿走）。
pub async fn LeaseTable::renew(
  self : LeaseTable,
  resource : String,
  holder : String,
  ttl_ms : Int,
) -> Bool {
  self.lock.acquire()
  let now = now_ms()
  let ok = match self.leases.get(resource) {
    Some(l) =>
      if l.holder == holder && now < l.expires_at {
        l.expires_at = ttl_deadline(now, ttl_ms)
        true
      } else {
        false
      }
    None => false
  }
  self.lock.release()
  ok
}

///|
/// 释放：holder 匹配（或资源本就不存在）时成功，返回 true。
pub async fn LeaseTable::release(
  self : LeaseTable,
  resource : String,
  holder : String,
) -> Bool {
  self.lock.acquire()
  let ok = match self.leases.get(resource) {
    Some(l) =>
      if l.holder == holder {
        self.leases.remove(resource)
        true
      } else {
        false
      }
    None => true
  }
  self.lock.release()
  ok
}

///|
/// 当前（未过期）holder；不存在或已过期返回 None。
pub async fn LeaseTable::holder_of(
  self : LeaseTable,
  resource : String,
) -> String? {
  self.lock.acquire()
  let now = now_ms()
  let h = match self.leases.get(resource) {
    Some(l) => if now >= l.expires_at { None } else { Some(l.holder) }
    None => None
  }
  self.lock.release()
  h
}

///|
/// 当前 epoch（fencing token）；不存在返回 None。
pub async fn LeaseTable::epoch_of(
  self : LeaseTable,
  resource : String,
) -> UInt64? {
  self.lock.acquire()
  let e = match self.leases.get(resource) {
    Some(l) => Some(l.epoch)
    None => None
  }
  self.lock.release()
  e
}

///|
/// 活跃租约数（观测用）。
pub async fn LeaseTable::len(self : LeaseTable) -> Int {
  self.lock.acquire()
  let n = self.leases.length()
  self.lock.release()
  n
}

///|
/// claim 的结果。
pub(all) enum ClaimResult {
  /// 脏队列为空（或所有待合并 namespace 都被别的 compactor 持有）
  Empty
  /// 抢到了该 namespace 的 compact 租约，携带 epoch
  Claimed(String, UInt64)
}

///|
/// 待合并 namespace 的 FIFO 脏队列（去重）。
pub struct DirtyQueue {
  lock : @async.Mutex
  items : Array[String]
  members : Map[String, Bool]
}

///|
pub fn DirtyQueue::new() -> DirtyQueue {
  { lock: @async.Mutex::Mutex(), items: [], members: Map([]) }
}

///|
/// 生产端 name 入队；返回 true 表示本次是新增（幂等重复入队返回 false）。
pub async fn DirtyQueue::mark(self : DirtyQueue, ns : String) -> Bool {
  self.lock.acquire()
  let added = !self.members.contains(ns)
  if added {
    self.items.push(ns)
    self.members.set(ns, true)
  }
  self.lock.release()
  added
}

///|
/// 消费端 claim：按 FIFO 扫描，弹出第一个能成功拿到 `compact:{ns}` 租约的 ns。
/// 抢不到租约的 ns 原样留在队列里（等其他 compactor 释放）。
pub async fn DirtyQueue::claim(
  self : DirtyQueue,
  leases : LeaseTable,
  holder : String,
  ttl_ms : Int,
) -> ClaimResult {
  self.lock.acquire()
  let n = self.items.length()
  let mut i = 0
  let mut found : ClaimResult = ClaimResult::Empty
  while i < n {
    let ns = self.items[i]
    match leases.acquire("compact:" + ns, holder, ttl_ms) {
      AcquireResult::Granted(epoch) => {
        ignore(self.items.remove(i))
        self.members.remove(ns)
        found = ClaimResult::Claimed(ns, epoch)
        break
      }
      AcquireResult::Denied(_) => i += 1
    }
  }
  self.lock.release()
  found
}

///|
/// 队列长度（观测用）。
pub async fn DirtyQueue::len(self : DirtyQueue) -> Int {
  self.lock.acquire()
  let n = self.items.length()
  self.lock.release()
  n
}

///|
/// 队列快照（观测用，FIFO 顺序）。
pub async fn DirtyQueue::snapshot(self : DirtyQueue) -> Array[String] {
  self.lock.acquire()
  let out = self.items.copy()
  self.lock.release()
  out
}
