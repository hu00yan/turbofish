// query 批量读路径白盒测试：用计数 wrapper 证明 warm_namespace / BM25 走批量入口。

///|
struct CountingBatchStore {
  inner : @store.MemStore
  mut many_calls : Int
  mut many_items : Int
  mut range_calls : Int
}

///|
fn CountingBatchStore::new(inner : @store.MemStore) -> CountingBatchStore {
  { inner, many_calls: 0, many_items: 0, range_calls: 0 }
}

///|
fn CountingBatchStore::reset_counts(self : CountingBatchStore) -> Unit {
  self.many_calls = 0
  self.many_items = 0
  self.range_calls = 0
}

///|
pub impl @store.ObjectStore for CountingBatchStore with fn get(
  self : CountingBatchStore,
  key : String,
) -> Bytes? {
  self.inner.get(key)
}

///|
pub impl @store.ObjectStore for CountingBatchStore with fn put(
  self : CountingBatchStore,
  key : String,
  value : Bytes,
) -> Unit {
  self.inner.put(key, value)
}

///|
pub impl @store.ObjectStore for CountingBatchStore with fn put_if_match(
  self : CountingBatchStore,
  key : String,
  e : @store.Expected,
  value : Bytes,
) -> Bool {
  let @store.Expected(expected) = e
  self.inner.put_if_match(key, @store.Expected(expected), value)
}

///|
pub impl @store.ObjectStore for CountingBatchStore with fn get_range(
  self : CountingBatchStore,
  key : String,
  br : @store.ByteRange,
) -> Bytes? {
  let offset = br.off
  let len = br.len
  self.inner.get_range(key, @store.ByteRange::{ off: offset, len: len })
}

///|
pub impl @store.ObjectStore for CountingBatchStore with fn list(
  self : CountingBatchStore,
  prefix : String,
) -> Array[String] {
  self.inner.list(prefix)
}

///|
pub impl @store.ObjectStore for CountingBatchStore with fn delete(
  self : CountingBatchStore,
  key : String,
) -> Unit {
  self.inner.delete(key)
}

///|
pub impl @store.ObjectStore for CountingBatchStore with fn head_version(
  self : CountingBatchStore,
  key : String,
) -> String? {
  self.inner.head_version(key)
}

///|
pub impl @store.ObjectStore for CountingBatchStore with fn get_many(
  self : CountingBatchStore,
  keys : Array[String],
) -> Array[Bytes?] {
  self.many_calls += 1
  self.many_items += keys.length()
  @store.BatchStore::get_many(self.inner, keys)
}

///|
pub impl @store.ObjectStore for CountingBatchStore with fn get_range_many(
  self : CountingBatchStore,
  ranges : Array[@store.KeyRange],
) -> Array[Bytes?] {
  self.range_calls += 1
  @store.BatchStore::get_range_many(self.inner, ranges)
}

///|
/// 批量写在计数 wrapper 里同样走内层批量实现（10 个 trait 方法全量补齐）。
pub impl @store.ObjectStore for CountingBatchStore with fn put_many(
  self : CountingBatchStore,
  items : Array[(String, Bytes)],
) -> Unit {
  self.inner.put_many(items)
}

pub extend CountingBatchStore with @store.ObjectStore::{
  get,
  put,
  put_if_match,
  get_range,
  list,
  delete,
  head_version,
  get_many,
  get_range_many,
  put_many,
}

///|
async test "warm_namespace / BM25 走批量读入口且结果不变" {
  let inner = make_test_store([])
  let s = CountingBatchStore::new(inner)
  let n = open(s, "test")
  warm_namespace(n)
  // 两个段 meta（+ 非 dense id 列）应通过批量入口读取。
  assert_eq(s.many_calls > 0, true)
  assert_eq(s.many_items >= 2, true)
  // BM25 冷读：dir/doc_len 应通过批量入口读取。
  s.reset_counts()
  let before = bm25_search(n, "fox", 5, None)
  assert_eq(before.length() > 0, true)
  assert_eq(s.many_calls > 0, true)
  // 再查一次：列/dir/doc_len 全部缓存命中，不再产生批量整读请求；
  // 只剩批量 Range 读：**每段 1 次**（该段多个 term 的 posting 局部区间合并）。
  s.reset_counts()
  let after = bm25_search(n, "fox", 5, None)
  assert_eq(after.length(), before.length())
  assert_eq(s.many_calls, 0)
  assert_eq(s.range_calls, 2)
}
