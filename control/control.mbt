// control 包：单机 in-memory ControlPlane MVP。
//
// 职责：以 namespace 名为 key 缓存 `@query.Namespace` 快照，按 TTL 决定是否
// 重新 `@query.open`；统计 hits/misses/reloads/stales/evictions。
//
// 语义要点：
// - TTL 内 acquire：命中缓存（hits++、pins++）。
// - TTL 外 acquire：重新 open（misses++、reloads++、pins++），成功后替换快照。
// - open 失败：stale_ok 且有旧快照时返回旧快照（stales++、pins++），并把
//   `checked_ms` 推到 now——故障期间不会每次 acquire 都全量重试（fail-storm）；
//   否则 rethrow（失败路径不 push pin）。
// - 每次成功 pin 都把该快照的 manifest id 压入 `pinned_ids`（acquire 顺序），
//   release 弹出一个；`pinned_manifests` 给 C2 做 GC/一致性检查用。
// - release：pins--（不为负），pinned_ids 同步出栈（栈空 no-op）。
// - invalidate：pins=0 直接删 entry；pins>0 保留旧快照（pinned 查询仍能完成），
//   只把 `checked_ms` 置 0 让下一次 acquire 重新加载。pin 归零时清掉该 entry。
// - max_entries：超限时优先逐出 pins=0 的最旧项；全 pinned 时无法逐出，
//   记一次 eviction 压力事件（evictions++）。
//
// 本 MVP 只做进程内单机实现，不落盘、不跨进程共享；S3 仍是唯一 durable source
// of truth，缓存丢失只影响冷启动。

///|
/// ControlPlane 配置。`new()` 提供默认值：TTL=1000ms、stale_ok=false、
/// max_entries=64。
pub(all) struct CtrlConfig {
  /// 快照头检查 TTL（ms）；TTL 内 acquire 直接命中。
  head_ttl_ms : UInt64
  /// reload 失败时是否返回旧快照。
  stale_ok : Bool
  /// 最多缓存的 namespace 数；超限时逐出 unpinned 的最旧项。
  max_entries : Int
}

///|
pub fn CtrlConfig::new() -> CtrlConfig {
  { head_ttl_ms: 1000UL, stale_ok: false, max_entries: 64 }
}

///|
/// 单 namespace 的内存条目。
/// - `checked_ms = 0` 表示「被 invalidate 标记，需要下一次 acquire 重新加载」；
///   快照本身仍保留，所以已持 pin 的调用方还能继续查。
/// - `pinned_ids` 按 acquire 顺序记录每次 pin 到的 manifest id（可重复），
///   栈顶即 `pinned_manifest` 的返回值；`pinned_manifests` 返回去重后的视图。
pub struct CtrlEntry[S] {
  mut snap : @query.Namespace[S]
  mut checked_ms : UInt64
  mut pins : Int
  mut last_used : UInt64
  pinned_ids : Array[String]
}

///|
/// 单机 in-memory 控制面：namespace → Namespace 快照缓存 + TTL + pin 计数。
pub struct ControlPlane[S] {
  store : S
  cfg : CtrlConfig
  entries : Map[String, CtrlEntry[S]]
  mut hits : Int
  mut misses : Int
  mut reloads : Int
  mut stales : Int
  mut evictions : Int
  /// TTL 过期后的轻量 head 探测次数（read_head_pointer，1 GET/次）。
  mut probes : Int
  /// 探测确认 head 未变、免去全量 re-open 的次数。
  mut probe_hits : Int
  /// 是否为 authoritative 模式（权威内存拥有者，不走 TTL/S3 探测）
  mut authoritative : Bool
}

///|
pub fn[S] ControlPlane::new(
  store : S,
  cfg : CtrlConfig,
) -> ControlPlane[S] {
  {
    store,
    cfg,
    entries: Map([]),
    hits: 0,
    misses: 0,
    reloads: 0,
    stales: 0,
    evictions: 0,
    probes: 0,
    probe_hits: 0,
    authoritative: false,
  }
}

///|
pub fn[S] ControlPlane::set_authoritative(
  self : ControlPlane[S],
  auth : Bool,
) -> Unit {
  self.authoritative = auth
}

///|
pub fn[S] ControlPlane::is_authoritative(
  self : ControlPlane[S],
) -> Bool {
  self.authoritative
}

///|
/// 取快照：TTL 内命中缓存；TTL 过期先做 1 次 GET 的 head 指针探测
/// （`{ns}/_head_ptr`，见 @store.head_pointer_key），指针仍指向当前快照
/// 就续期复用，否则才全量 re-open。旧 store（无指针对象）回退全量 open。
/// open 失败时按 stale_ok + 旧快照决定返回旧快照或 rethrow。
pub fn[S : @store.ObjectStore] ControlPlane::acquire(
  self : ControlPlane[S],
  ns : String,
) -> @query.Namespace[S] raise @core.SpndError {
  let now = @env.now()
  let entry : CtrlEntry[S]? = self.entries.get(ns)
  match entry {
    Some(e) =>
      // authoritative 模式下直接命中权威内存快照；非 authoritative 按 TTL 判定。
      if self.authoritative ||
        (e.checked_ms != 0UL && now - e.checked_ms < self.cfg.head_ttl_ms) {
        self.hits += 1
        e.pins += 1
        e.pinned_ids.push(e.snap.manifest.id)
        e.last_used = now
        return e.snap
      }
    None => ()
  }
  match entry {
    // 正常 TTL 过期（checked_ms != 0）+ 已有快照：先做 1 次 GET 指针探测。
    // 指针缺失（旧写者/旧数据）或指向别的 manifest ⇒ 落到下面的全量 re-open。
    // invalidate 标记（checked_ms=0）**不走探测**：invalidate 是显式的
    // 「快照已过期」信号，必须全量 reload（语义与探测优化无关）。
    Some(e) if e.checked_ms != 0UL => {
      // 探测 = 1 次 GET（无论指针是否存在都计入 attempts）。
      self.probes += 1
      match @store.read_head_pointer(self.store, ns) {
        Some(id) =>
          if id == e.snap.manifest.id {
            self.probe_hits += 1
            e.checked_ms = now
            e.pins += 1
            e.pinned_ids.push(e.snap.manifest.id)
            e.last_used = now
            return e.snap
          }
        None => ()
      }
    }
    Some(_) => ()
    None => ()
  }
  self.misses += 1
  self.reloads += 1
  let opened : Result[@query.Namespace[S], @core.SpndError] = try {
    Ok(@query.open(self.store, ns))
  } catch {
    err => Err(err)
  }
  match opened {
    Ok(snap) => {
      let mid = snap.manifest.id
      match entry {
        Some(e) => {
          e.snap = snap
          e.checked_ms = now
          e.pins += 1
          e.pinned_ids.push(mid)
          e.last_used = now
        }
        None =>
          self.entries.set(ns, {
            snap,
            checked_ms: now,
            pins: 1,
            last_used: now,
            pinned_ids: [mid],
          })
      }
      self.enforce_limit()
      snap
    }
    Err(err) =>
      match entry {
        Some(e) =>
          if self.cfg.stale_ok {
            self.stales += 1
            e.pins += 1
            e.pinned_ids.push(e.snap.manifest.id)
            // 记住这次失败的检查：TTL 内的后续 acquire 直接命中旧快照，
            // 避免 store 故障时每次 acquire 都全量 open（fail-storm）。
            e.checked_ms = now
            e.last_used = now
            e.snap
          } else {
            raise err
          }
        None => raise err
      }
  }
}

///|
/// 释放一个 pin：pins--（不为负），并弹出一个 pinned id（栈空 no-op）。
/// pin 归零时，若条目已被 invalidate 标记（checked_ms=0）则删除整个 entry。
pub fn[S] ControlPlane::release(
  self : ControlPlane[S],
  ns : String,
) -> Unit {
  match self.entries.get(ns) {
    Some(e) => {
      if e.pins > 0 {
        e.pins -= 1
        if e.pinned_ids.length() > 0 {
          let _ = e.pinned_ids.pop()
        }
      }
      if e.pins == 0 && e.checked_ms == 0UL {
        self.entries.remove(ns)
      }
    }
    None => ()
  }
}

///|
/// 主动失效：pins=0 时直接删 entry；仍有 pin 时**保留旧快照**（已持 pin 的
/// 调用方查询不受影响），只把 `checked_ms` 置 0，让下一次 acquire 重新加载。
/// pin 归零后由 release 删掉这个已被标记的 entry。
pub fn[S] ControlPlane::invalidate(
  self : ControlPlane[S],
  ns : String,
) -> Unit {
  match self.entries.get(ns) {
    Some(e) =>
      if e.pins > 0 {
        e.checked_ms = 0UL
      } else {
        self.entries.remove(ns)
      }
    None => ()
  }
}

///|
/// 权威控制面主动更新快照：用于写入、补丁、Compaction 完成后直接替换快照，
/// 无需查询路径向 S3 轮询或 re-open。
pub fn[S] ControlPlane::update_snapshot(
  self : ControlPlane[S],
  ns : String,
  snap : @query.Namespace[S],
) -> Unit {
  let now = @env.now()
  match self.entries.get(ns) {
    Some(e) => {
      e.snap = snap
      e.checked_ms = now
      e.last_used = now
    }
    None => {
      self.entries.set(ns, {
        snap,
        checked_ms: now,
        pins: 0,
        last_used: now,
        pinned_ids: [],
      })
      self.enforce_limit()
    }
  }
}

///|
/// 查询是否存在已缓存的权威快照（不发起任何 I/O）。
pub fn[S] ControlPlane::get_snapshot(
  self : ControlPlane[S],
  ns : String,
) -> @query.Namespace[S]? {
  match self.entries.get(ns) {
    Some(e) => Some(e.snap)
    None => None
  }
}

///|
/// (hits, misses, reloads, stales, evictions)。
pub fn[S] ControlPlane::stats(
  self : ControlPlane[S],
) -> (Int, Int, Int, Int, Int) {
  (self.hits, self.misses, self.reloads, self.stales, self.evictions)
}

///|
/// (probes, probe_hits)：TTL 过期后的轻量探测次数 / 免全量 re-open 的次数。
/// 单独成对，保持 stats() 既有 5 元组签名不破坏现有调用点。
pub fn[S] ControlPlane::probe_stats(
  self : ControlPlane[S],
) -> (Int, Int) {
  (self.probes, self.probe_hits)
}

///|
/// 最近一次 pin 到的 manifest id（`pinned_ids` 栈顶）；无 pin 时返回 None。
/// 注意：reload 之后栈里仍保留旧代的 id，栈顶始终是「最新一次 pin」。
pub fn[S] ControlPlane::pinned_manifest(
  self : ControlPlane[S],
  ns : String,
) -> String? {
  match self.entries.get(ns) {
    Some(e) => if e.pins > 0 { e.pinned_ids.last() } else { None }
    None => None
  }
}

///|
/// 当前仍被 pin 的全部 manifest id（去重，保持首次 pin 的顺序）。
/// 供 C2 的 GC / 一致性检查保护「旧 pin 仍持有但已不是 head」的代。
pub fn[S] ControlPlane::pinned_manifests(
  self : ControlPlane[S],
  ns : String,
) -> Array[String] {
  let out : Array[String] = []
  match self.entries.get(ns) {
    Some(e) =>
      for id in e.pinned_ids {
        if !out.contains(id) {
          out.push(id)
        }
      }
    None => ()
  }
  out
}

///|
/// 容量控制：超限时逐出 pins=0 且 last_used 最小的条目。
/// 若所有条目都被 pin，则不逐出，只记一次 eviction 压力事件。
fn[S] ControlPlane::enforce_limit(
  self : ControlPlane[S],
) -> Unit {
  while self.entries.length() > self.cfg.max_entries {
    let mut victim : String? = None
    let mut victim_used : UInt64 = 0UL
    for kv in self.entries.iter() {
      let (key, e) = kv
      if e.pins == 0 {
        match victim {
          None => {
            victim = Some(key)
            victim_used = e.last_used
          }
          Some(_) =>
            if e.last_used < victim_used {
              victim = Some(key)
              victim_used = e.last_used
            }
        }
      }
    }
    match victim {
      Some(key) => {
        self.entries.remove(key)
        self.evictions += 1
      }
      None => {
        self.evictions += 1
        break
      }
    }
  }
}
