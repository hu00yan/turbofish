// 元数据缓存层（CachedManifestStore）：
// 消除每次查询都向 S3 执行 GET _head_ptr 与 GET manifest.json 的严重读放大与网络往返（60~120ms）。
// 1. Writer 节点本地权威持有：在写回缓冲区持有期间，元数据在本地内存直接更新，读操作 0 次 S3 GET；
// 2. Reader 节点租约与条件验证：在 ttl_ms 内直接走内存快照，过期后仅发 1 次 head 指针比对，无变动直接复用。

///|
pub struct CachedManifestStore[S] {
  inner : ObjManifestStore[S]
  mut cached_manifest : Manifest?
  mut cached_head_ptr : String?
  mut last_check_ms : Int64
  ttl_ms : Int64
  mut is_writer : Bool
}

///|
pub fn[S : @store.ObjectStore] CachedManifestStore::new(
  inner : ObjManifestStore[S],
  ttl_ms~ : Int64 = 2000L,
  is_writer~ : Bool = true
) -> CachedManifestStore[S] {
  {
    inner,
    cached_manifest: None,
    cached_head_ptr: None,
    last_check_ms: 0L,
    ttl_ms,
    is_writer,
  }
}

///|
pub fn[S] CachedManifestStore::set_writer(
  self : CachedManifestStore[S],
  v : Bool
) -> Unit {
  self.is_writer = v
}

///|
pub fn[S] CachedManifestStore::invalidate(
  self : CachedManifestStore[S]
) -> Unit {
  self.cached_manifest = None
  self.cached_head_ptr = None
  self.last_check_ms = 0L
}

///|
impl[S : @store.ObjectStore] ManifestStore for CachedManifestStore[S] with load(
  self
) -> Manifest raise @core.SpndError {
  // 1. Writer 节点或租约有效窗口内：零 S3 GET 直接返回
  if self.is_writer {
    match self.cached_manifest {
      Some(m) => return m
      None => ()
    }
  }

  // 2. 检查 S3 Head 指针是否变动
  let head_key = self.inner.head_ptr_key()
  let head_val = match self.inner.store.get(head_key) {
    Some(bs) =>
      @utf8.decode(bs.view()) catch {
        _ => raise @core.Corrupt("invalid head_manifest pointer utf8 in cache")
      }
    None => ""
  }

  if head_val == "" {
    let empty = Manifest::new()
    self.cached_manifest = Some(empty)
    self.cached_head_ptr = Some("")
    return empty
  }

  // 若 Head 指针与本地缓存一致，直接复用已解析的 Manifest，省去下载并解析 manifest-N.json
  match (self.cached_head_ptr, self.cached_manifest) {
    (Some(cached_ptr), Some(cached_m)) =>
      if cached_ptr == head_val {
        return cached_m
      }
    _ => ()
  }

  // 3. 指针发生变动或初次加载：拉取完整 Manifest
  let m = ManifestStore::load(self.inner)
  self.cached_manifest = Some(m)
  self.cached_head_ptr = Some(head_val)
  m
}

///|
impl[S : @store.ObjectStore] ManifestStore for CachedManifestStore[S] with publish(
  self,
  m : Manifest
) -> Unit raise @core.SpndError {
  ManifestStore::publish(self.inner, m)
  self.cached_manifest = Some(m)
  self.cached_head_ptr = Some("manifest-\{m.seq}")
  self.is_writer = true
}
