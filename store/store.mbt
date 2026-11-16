// ObjectStore 抽象：S3 的最小子集。
// - get/put/list/delete
// - put_if_match：CAS 头指针（对应 S3 conditional put / If-Match）
// - get_range：范围读（对应 S3 GetObject Range），用于只拉 posting 局部区间

///|
/// CAS 期望版本：`Expected(None)` = 仅当对象不存在；`Expected(Some(v))` = 仅当版本为 v。
/// 类型化包装（newtype），防止 `put_if_match` 在不同实现间 (key, expected, value) /
/// (key, body, expected) 参数顺序混用（真实逃逸事故根因）。
#derive(Debug, Eq)
pub(all) struct Expected(String?)


///|
/// 范围读参数：`[off, off + len)`。类型化包装，防止 offset/len 顺序颠倒。
#derive(Debug, Eq)
pub(all) struct ByteRange {
  off : Int
  len : Int
}

///|
/// 批量范围读元素：key + 范围。
#derive(Debug, Eq)
pub(all) struct KeyRange {
  key : String
  off : Int
  len : Int
}

///|
pub(open) trait ObjectStore {
  async fn get(Self, String) -> Bytes?
  async fn put(Self, String, Bytes) -> Unit
  /// CAS 写入：`Expected(None)` 时要求 key 不存在；返回 true 表示写入成功。
  async fn put_if_match(Self, String, Expected, Bytes) -> Bool
  /// 范围读 [br.off, br.off + br.len)，返回可能截短的 payload。
  async fn get_range(Self, String, ByteRange) -> Bytes?
  /// 返回 prefix 下所有 key，升序。
  async fn list(Self, String) -> Array[String]
  async fn delete(Self, String) -> Unit
  /// 获取对象的当前版本/ETag（用于 CAS 条件写 put_if_match 的 expected 校验）
  async fn head_version(Self, String) -> String?
  /// 批量整读。默认顺序调用 `get`，返回与输入同长同序；`None` 保持在原下标。
  async fn get_many(Self, Array[String]) -> Array[Bytes?] = _
  /// 批量范围读。默认顺序调用 `get_range`，语义与单键完全一致。
  async fn get_range_many(Self, Array[KeyRange]) -> Array[Bytes?] = _
  /// 批量写入。默认顺序调用 `put`；异步后端覆盖为并发上传。
  async fn put_many(Self, Array[(String, Bytes)]) -> Unit = _
}

///|
#derive(Debug)
pub struct CostSnapshot {
  gets : Int
  get_bytes : Int
  ranged_gets : Int
  ranged_bytes : Int
  lists : Int
  puts : Int
  put_bytes : Int
  deletes : Int
  cas_ok : Int
  cas_fail : Int
  // (class, reqs, bytes)，读路径按 key 语义分类
  classes : Array[(String, Int, Int)]
}

///|
pub fn CostSnapshot::total_requests(self : CostSnapshot) -> Int {
  self.gets + self.ranged_gets + self.lists
}

///|
pub fn CostSnapshot::total_read_bytes(self : CostSnapshot) -> Int {
  self.get_bytes + self.ranged_bytes
}

///|
pub fn CostSnapshot::show_table(self : CostSnapshot) -> String {
  let b = Buffer()
  b.write_string_utf8("class          reqs      KB\n".exact_view())
  for kv in self.classes {
    let (cls, reqs, bytes) = kv
    let kb = bytes.to_double() / 1024.0
    b.write_string_utf8(
      "\{pad(cls, 15)}\{pad(reqs.to_string(), 6)}\{pad(kb.to_string(), 10)}\n",
    )
  }
  b.write_string_utf8(
    "TOTAL reqs=\{self.total_requests()} readKB=\{self.total_read_bytes().to_double() / 1024.0} puts=\{self.puts} putKB=\{self.put_bytes.to_double() / 1024.0}\n".exact_view(),
  )
  @utf8.decode(b.to_bytes().exact_view()) catch {
    _ => ""
  }
}

///|
fn pad(s : String, w : Int) -> String {
  let mut out = s
  while out.length() < w {
    out = out + " "
  }
  out
}

pub extend CostSnapshot with Debug::{to_repr}
