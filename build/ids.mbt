// 全局可排序 ID：manifest head log 依赖字典序 = 发布时间序。
//
// 格式：{prefix}-{13 位毫秒时间戳}-{writer_id}-{6 位进程内序号}
// - 时间戳定宽，字符串比较先比时间；
// - writer_id 默认由 env + PID + 真随机 64-bit + 进程内计数器生成，可用
//   TURBOFISH_WRITER_ID 显式指定；非 native 后端没有 PID/随机源，生产多写者
//   必须显式设置 TURBOFISH_WRITER_ID；非法 env 值会被静默忽略并回退自动生成。
// - 同毫秒内用进程内序号保证唯一/有序。
// 跨进程写者必须设置不同的 TURBOFISH_WRITER_ID（或接受时钟/随机碰撞风险）。

///|
let id_seq : Ref[UInt64] = Ref(0UL)

///|
let writer_id_ref : Ref[String] = Ref("")

///|
fn pad_left(s : String, width : Int) -> String {
  let n = width - s.length()
  let mut out = ""
  if n > 0 {
    for _ in 0..<n {
      out = out + "0"
    }
  }
  out + s
}

///|
/// writer id 只允许 [A-Za-z0-9-]：`/` 会破坏 `_heads/{id}` 的 key 布局，非 ASCII
/// 会破坏字节序与 `id_compare` 的一致性。非法 env 值忽略，回退到自动生成。
fn valid_writer_token(s : String) -> Bool {
  if s == "" {
    return false
  }
  for c in s.iter() {
    let v = c.to_int()
    let ok = (v >= 48 && v <= 57) ||
      (v >= 65 && v <= 90) ||
      (v >= 97 && v <= 122) ||
      v == 45
    if !ok {
      return false
    }
  }
  true
}

///|
fn writer_id() -> String {
  if writer_id_ref.val != "" {
    return writer_id_ref.val
  }
  let fallback = "w\{@env.now()}-p\{@core.process_id()}-r\{@core.random_u64()}-\{@core.next_id()}"
  let id = match @env.get_env_var("TURBOFISH_WRITER_ID") {
    Some(v) => if valid_writer_token(v) { v } else { fallback }
    None => fallback
  }
  writer_id_ref.val = id
  id
}

///|
fn new_scoped_id(prefix : String) -> String {
  id_seq.val += 1UL
  let ts = pad_left(@env.now().to_string(), 13)
  let seq = pad_left(id_seq.val.to_string(), 6)
  "\{prefix}-\{ts}-\{writer_id()}-\{seq}"
}

///|
fn new_manifest_id() -> String {
  new_scoped_id("manifest")
}

///|
fn new_segment_id() -> String {
  new_scoped_id("seg")
}

///|
fn new_centroid_version() -> String {
  new_scoped_id("centroids")
}
