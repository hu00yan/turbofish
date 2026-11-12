// BatchStore：顺序等价的批取扩展（Mimo 设计评审）。
//
// 契约：
// - 只影响调度（调用方可以把多个单键请求合并成一次调用），不影响缓存 / 计费 / 404 语义：
//   批量结果必须与逐项调用现有 get / get_range 完全一致（顺序等价）。
// - 返回数组长度与输入一致；缺失 key 的 None 保持在原下标位置，不压缩、不重排。
// - 顺序 fallback 契约：不引入真实并发 / 线程，逐项委托现有单键方法，
//   记账 / 缓存 / 字节统计逻辑原样保留、不复制。

///|
/// 顺序等价的批取能力；只影响调度，不影响缓存/计费/404 语义。
///
/// `None` 与单键 `get`/`get_range` 完全一致：表示 key 缺失**或**不可读；
/// 调用方不得用 `None` 区分 404 与 transient 错误。波次化接入时应把消费点
/// 收敛到单一 wrapper，未来若需要错误通道再替换为 BatchResult。
pub(open) trait BatchStore : ObjectStore {
  fn get_many(Self, Array[String]) -> Array[Bytes?]
  fn get_range_many(Self, Array[(String, Int, Int)]) -> Array[Bytes?]
}

///|
/// 顺序 fallback：逐项委托现有单键 get，计费 / 缓存 / 404 语义不变。
pub impl BatchStore for MemStore with fn get_many(
  self : MemStore,
  keys : Array[String],
) -> Array[Bytes?] {
  let out : Array[Bytes?] = Array::new()
  for k in keys {
    out.push(self.get(k))
  }
  out
}

///|
/// 顺序 fallback：逐项委托现有单键 get_range（元素为 (key, offset, len)）。
pub impl BatchStore for MemStore with fn get_range_many(
  self : MemStore,
  ranges : Array[(String, Int, Int)],
) -> Array[Bytes?] {
  let out : Array[Bytes?] = Array::new()
  for r in ranges {
    out.push(self.get_range(r.0, r.1, r.2))
  }
  out
}