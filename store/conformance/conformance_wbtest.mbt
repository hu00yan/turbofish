///|
/// 坏后端：put_if_match 无视条件永远成功、get_range 无视 offset 永远返回开头。
/// 用途：证明 conformance 契约**能抓住语义漂移**（负向对照），防止契约本身
/// 被"顺手改宽"后变成永远通过的摆设。
struct BadStore {
  inner : @store.MemStore
}

///|
impl @store.ObjectStore for BadStore with fn get(self, key) {
  self.inner.get(key)
}

///|
impl @store.ObjectStore for BadStore with fn put(self, key, value) {
  self.inner.put(key, value)
}

///|
impl @store.ObjectStore for BadStore with fn put_if_match(self, key, _expected, value) {
  // BUG（故意）：无视 CAS 条件
  self.inner.put(key, value)
  true
}

///|
impl @store.ObjectStore for BadStore with fn get_range(self, key, br) {
  // BUG（故意）：无视 off，永远返回 [0, len)
  self.inner.get_range(key, @store.ByteRange::{ off: 0, len: br.len })
}

///|
impl @store.ObjectStore for BadStore with fn list(self, prefix) {
  self.inner.list(prefix)
}

///|
impl @store.ObjectStore for BadStore with fn delete(self, key) {
  self.inner.delete(key)
}

///|
impl @store.ObjectStore for BadStore with fn head_version(self, key) {
  self.inner.head_version(key)
}

///|
async test "conformance: MemStore 通过全部契约" {
  let report = conformance_report(fn () { @store.MemStore::new() })
  assert_eq(report, "")
}

///|
async test "conformance: 坏后端被契约抓住（负向对照）" {
  let report = conformance_report(fn () { BadStore::{ inner: @store.MemStore::new() } })
  // 必须非空，且必须点名 CAS 与 get_range 两处违规
  assert_eq(report != "", true)
  assert_eq(report.contains("Expected(None) 对已存在 key 应失败"), true)
  assert_eq(report.contains("get_range 中段字节不一致"), true)
}
