// 单调 ID 生成：MVP 无稳定 wall-clock API，用进程内单调计数器 + Crockford Base32
// 定宽编码。字典序 = 数值序，满足 spec 的可排序要求（snowflake 变体）。

///|
let crockford : Array[Char] = [
  '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F',
  'G', 'H', 'J', 'K', 'M', 'N', 'P', 'Q', 'R', 'S', 'T', 'V', 'W', 'X', 'Y', 'Z',
]

///|
let id_counter : Ref[UInt64] = Ref(0UL)

///|
pub fn next_id() -> String {
  id_counter.val = id_counter.val + 1UL
  let mut v = id_counter.val
  // 13 个 Base32 字符 = 65 bits，足够进程内单调计数
  let digits : Array[Char] = Array(capacity=13)
  for _ in 0..<13 {
    let d = (v & 31UL).to_int()
    digits.push(crockford[d])
    v = v >> 5
  }
  let out : Array[Char] = Array(capacity=13)
  for i in 0..<13 {
    out.push(digits[12 - i])
  }
  String::from_array(out.exact_view())
}

///|
pub fn next_segment_id() -> String {
  "seg-" + next_id()
}

///|
pub fn next_manifest_id() -> String {
  "manifest-" + next_id()
}

///|
pub fn next_centroid_version() -> String {
  "centroids-" + next_id()
}

///|
test "next_id monotonic sortable" {
  let a = next_segment_id()
  let b = next_segment_id()
  assert_eq(a.compare(b) < 0, true)
  assert_eq(a.length(), 17) // "seg-" + 13
  assert_eq(b.has_prefix("seg-"), true)
}
