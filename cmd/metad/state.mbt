// metad 的控制面状态（租约 + 脏队列 + head 写穿缓存）。
//
// 全部状态都在进程内存里（LeaseTable / DirtyQueue / heads），
// 元数据对象本体落在本机 FsStore（SSD）；compactor 通过 metad 的 HTTP 端点
// 协调，不再依赖任何 libcurl。

///|
/// head 快包的结果。
pub(all) enum BundleReply {
  /// 客户端 known_head 与当前 head 相同：304，无 body
  NotModified
  /// (head, namespace_json)
  Payload(String, String)
  /// 该 namespace 还没有 head
  NoHead
}

///|
pub struct MetadState {
  root : String
  store : @fsstore.FsStore
  leases : @meta.LeaseTable
  dirty : @meta.DirtyQueue
  head_lock : @async.Mutex
  /// ns -> head manifest id（PUT /kv/{ns}/_head_ptr 时写穿）
  heads : Map[String, String]
}

///|
pub fn MetadState::new(root : String) -> MetadState {
  {
    root,
    store: @fsstore.FsStore::new(root),
    leases: @meta.LeaseTable::new(),
    dirty: @meta.DirtyQueue::new(),
    head_lock: @async.Mutex::Mutex(),
    heads: Map([]),
  }
}

///|
pub fn MetadState::root(self : MetadState) -> String {
  self.root
}

///|
pub fn MetadState::store(self : MetadState) -> @fsstore.FsStore {
  self.store
}

///|
pub fn MetadState::leases(self : MetadState) -> @meta.LeaseTable {
  self.leases
}

///|
pub fn MetadState::dirty(self : MetadState) -> @meta.DirtyQueue {
  self.dirty
}

///|
/// key = "{ns}/_head_ptr" → ns；不是 head 指针则 None。
pub fn ns_of_head_ptr(key : String) -> String? {
  let suffix = "/_head_ptr"
  if key.has_suffix(suffix) {
    let ns = key[:key.length() - suffix.length()].to_owned()
    if ns == "" {
      None
    } else {
      Some(ns)
    }
  } else {
    None
  }
}

///|
fn text_of(bs : Bytes) -> String {
  @utf8.decode_lossy(bs.exact_view())
}

///|
/// 从 `{ns}/_meta/namespace.json` 里回退取 head（head 指针缺失时）。
fn head_from_namespace_json(bs : Bytes) -> String? {
  let j = @json.parse(text_of(bs)) catch {
    _ => return None
  }
  match j {
    Object(m) =>
      match m.get("head") {
        Some(String(h)) => Some(h)
        _ => None
      }
    _ => None
  }
}

///|
/// 当前 head：内存写穿缓存 → `{ns}/_head_ptr` → `{ns}/_meta/namespace.json`。
pub async fn MetadState::head_of(
  self : MetadState,
  ns : String,
) -> String? {
  self.head_lock.acquire()
  let cached = self.heads.get(ns)
  self.head_lock.release()
  match cached {
    Some(h) => Some(h)
    None => {
      let head = match self.store.get(ns + "/_head_ptr") {
        Some(bs) => Some(text_of(bs))
        None =>
          match self.store.get(ns + "/_meta/namespace.json") {
            Some(bs) => head_from_namespace_json(bs)
            None => None
          }
      }
      match head {
        Some(h) => {
          self.head_lock.acquire()
          self.heads.set(ns, h)
          self.head_lock.release()
          Some(h)
        }
        None => None
      }
    }
  }
}

///|
/// 命名空间配置原文（不存在 → None）。
pub async fn MetadState::namespace_json(
  self : MetadState,
  ns : String,
) -> String? {
  match self.store.get(ns + "/_meta/namespace.json") {
    Some(bs) => Some(text_of(bs))
    None => None
  }
}

///|
/// 写路径的写穿通知：kv PUT 后同步更新 head 缓存。
pub async fn MetadState::note_put(
  self : MetadState,
  key : String,
  value : Bytes,
) -> Unit {
  match ns_of_head_ptr(key) {
    Some(ns) => {
      self.head_lock.acquire()
      self.heads.set(ns, text_of(value))
      self.head_lock.release()
    }
    None => ()
  }
}

///|
/// 删除路径的写穿通知。
pub async fn MetadState::note_delete(
  self : MetadState,
  key : String,
) -> Unit {
  match ns_of_head_ptr(key) {
    Some(ns) => {
      self.head_lock.acquire()
      self.heads.remove(ns)
      self.head_lock.release()
    }
    None => ()
  }
}

///|
/// 单次 RTT 元数据快包：known_head 命中当前 head 时只回 304。
pub async fn MetadState::bundle(
  self : MetadState,
  ns : String,
  known_head : String?,
) -> BundleReply {
  let head = self.head_of(ns)
  let current = match head {
    Some(h) => h
    None => ""
  }
  if current != "" {
    match known_head {
      Some(k) =>
        if k == current {
          return BundleReply::NotModified
        }
      None => ()
    }
  }
  if head is None {
    return BundleReply::NoHead
  }
  let ns_json = match self.namespace_json(ns) {
    Some(s) => s
    None => ""
  }
  BundleReply::Payload(current, ns_json)
}
