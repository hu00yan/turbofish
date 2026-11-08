// ObjectStore 抽象：S3 的最小子集。
// - get/put/list/delete
// - put_if_match：CAS 头指针（对应 S3 conditional put / If-Match）
// - get_range：范围读（对应 S3 GetObject Range），用于只拉 posting 局部区间

///|
pub(open) trait ObjectStore {
  get(Self, String) -> Bytes?
  put(Self, String, Bytes) -> Unit
  /// CAS 写入：expected 为 None 时要求 key 不存在；返回 true 表示写入成功。
  put_if_match(Self, String, String?, Bytes) -> Bool
  /// 范围读 [offset, offset+len)，返回可能截短的 payload。
  get_range(Self, String, Int, Int) -> Bytes?
  /// 返回 prefix 下所有 key，升序。
  list(Self, String) -> Array[String]
  delete(Self, String) -> Unit
}

///|
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
} derive(Debug)

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
  b.write_string_utf8(
    "class          reqs      KB\n".view(),
  )
  for kv in self.classes {
    let (cls, reqs, bytes) = kv
    let kb = bytes.to_double() / 1024.0
    b.write_string_utf8("\{pad(cls, 15)}\{pad(reqs.to_string(), 6)}\{pad(kb.to_string(), 10)}\n")
  }
  b.write_string_utf8(
    "TOTAL reqs=\{self.total_requests()} readKB=\{self.total_read_bytes().to_double() / 1024.0} puts=\{self.puts} putKB=\{self.put_bytes.to_double() / 1024.0}\n".view(),
  )
  @utf8.decode(b.to_bytes().view()) catch {
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
