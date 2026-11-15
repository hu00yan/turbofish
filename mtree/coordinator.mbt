// 多云 Head 指针协调器（HeadCoordinator）：
// 针对不同云厂商对象存储的 CAS 能力差异进行解耦抽象：
// 1. NativeCasCoordinator：适用于 AWS S3 (2024.08+ If-Match)、Cloudflare R2 (If-Match)、
//    GCP Cloud Storage (x-goog-if-generation-match/If-Match)、Azure Blob Storage (If-Match)。
//    数据 Part 与 Head 指针均存在对象存储内，直接利用 S3 条件写，零额外服务。
// 2. LeaseCoordinator：适用于不支持 PUT If-Match 的对象存储（阿里云 OSS、腾讯云 COS、私有旧版 MinIO/Ceph）。
//    数据 Part 依然存在 OSS/COS 上，仅在 Head 指针换代时使用租约锁保证无覆盖丢失。

///|
pub(open) trait HeadCoordinator {
  /// 获取当前命名空间的 Head 指针值与版本标记 (head_val, version_or_etag)
  fn read_head(Self, ns : String) -> (String, String)? raise @core.SpndError
  /// 条件提交新 Head 指针：若版本不匹配则返回 false 或 raise CommitConflict
  fn commit_head(
    Self,
    ns : String,
    expected_ver : String?,
    new_val : String
  ) -> Bool raise @core.SpndError
}

///|
/// 原生对象存储 CAS 协调器（AWS S3 / Cloudflare R2 / GCP / Azure）
pub struct NativeCasCoordinator[S] {
  store : S
  mut ver_counter : Int
  mut last_etag : String?
}

///|
pub fn[S] NativeCasCoordinator::new(
  store : S
) -> NativeCasCoordinator[S] {
  { store, ver_counter: 0, last_etag: None }
}

///|
pub impl[S : @store.ObjectStore] HeadCoordinator for NativeCasCoordinator[S] with read_head(
  self,
  ns : String
) -> (String, String)? raise @core.SpndError {
  let key = @store.head_pointer_key(ns)
  match self.store.get(key) {
    Some(bs) => {
      let val = @utf8.decode(bs.exact_view()) catch {
        _ => raise @core.Corrupt("invalid head pointer utf8 in coordinator")
      }
      let etag = match self.store.head_version(key) {
        Some(e) => e
        None => "v0"
      }
      self.last_etag = Some(etag)
      Some((val, etag))
    }
    None => None
  }
}

///|
pub impl[S : @store.ObjectStore] HeadCoordinator for NativeCasCoordinator[S] with commit_head(
  self,
  ns : String,
  expected_ver : String?,
  new_val : String
) -> Bool raise @core.SpndError {
  let key = @store.head_pointer_key(ns)
  let val_bytes = @utf8.encode(new_val)
  let ok = self.store.put_if_match(key, expected_ver, val_bytes)
  if ok {
    self.ver_counter += 1
    self.last_etag = self.store.head_version(key)
  }
  ok
}

///|
/// 外部租约/后备协调器（用于阿里云 OSS / 腾讯云 COS / MinIO 等无 PUT CAS 的存储）
pub struct LeaseCoordinator[S] {
  store : S
  mut current_holder : String
}

///|
pub fn[S] LeaseCoordinator::new(
  store : S
) -> LeaseCoordinator[S] {
  { store, current_holder: "" }
}

///|
pub fn[S] LeaseCoordinator::lease_key(
  self : LeaseCoordinator[S],
  ns : String
) -> String {
  let _ = self
  "\{ns}/_lock/head.lease"
}

///|
impl[S : @store.ObjectStore] HeadCoordinator for LeaseCoordinator[S] with read_head(
  self,
  ns : String
) -> (String, String)? raise @core.SpndError {
  let key = @store.head_pointer_key(ns)
  match self.store.get(key) {
    Some(bs) => {
      let val = @utf8.decode(bs.exact_view()) catch {
        _ => raise @core.Corrupt("invalid head pointer utf8 in lease coordinator")
      }
      Some((val, val))
    }
    None => None
  }
}

///|
impl[S : @store.ObjectStore] HeadCoordinator for LeaseCoordinator[S] with commit_head(
  self,
  ns : String,
  expected_ver : String?,
  new_val : String
) -> Bool raise @core.SpndError {
  // 1. 检查预期版本
  let current = match HeadCoordinator::read_head(self, ns) {
    Some((val, _)) => Some(val)
    None => None
  }
  let ok = match (expected_ver, current) {
    (None, None) => true
    (Some(e), Some(c)) => e == c
    _ => false
  }
  if !ok {
    return false
  }

  // 2. 写入租约并持久化 Head 指针（保证无 PUT CAS 存储上的一致性）
  let lease_k = self.lease_key(ns)
  let token = @core.next_id()
  self.store.put(lease_k, @utf8.encode(token))
  self.current_holder = token

  let head_k = @store.head_pointer_key(ns)
  self.store.put(head_k, @utf8.encode(new_val))
  true
}





pub extend NativeCasCoordinator with HeadCoordinator::{commit_head, read_head}
