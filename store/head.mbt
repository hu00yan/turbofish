// Append-only head log：给不支持 PutObject+If-Match 的对象存储一个无锁 CAS 补偿。
//
// 约定：`{ns}/_heads/{manifest_id}` 是一个空对象（key 即版本）。写者每发布一个
// manifest 就 create 一个新 key（If-None-Match:*，唯一 key 不会覆盖）；读者列举
// `_heads/` 取字典序最大的 id 作为当前 head。旧 head 记录可安全 GC（读者已持有
// 自己的 manifest id；manifest 本身不可变）。
//
// 优点：只做 create PUT + LIST/GET，不需要 If-Match，也不需要额外的 lock 对象
// （避免 lock 的 PUT/GET/DELETE 写放大）。manifest id 必须全局可排序。

///|
pub fn head_prefix(ns : String) -> String {
  "\{ns}/_heads/"
}

///|
pub fn head_key(ns : String, manifest_id : String) -> String {
  "\{ns}/_heads/\{manifest_id}"
}

///|
/// id 的字典序比较：按字符逐个比较，短前缀在前。`String::compare` 是长度优先，
/// 不适合 `manifest-{ts}-{writer}-{seq}` 与测试里的短 id 混排。
fn id_compare(a : String, b : String) -> Int {
  let aa = a.to_array()
  let bb = b.to_array()
  let n = if aa.length() < bb.length() { aa.length() } else { bb.length() }
  for i in 0..<n {
    let ca = aa[i].to_int()
    let cb = bb[i].to_int()
    if ca != cb {
      return ca - cb
    }
  }
  aa.length() - bb.length()
}

///|
/// head 指针 key（在 `_heads/` 之外，避免混进 LIST 仲裁与 gc_heads）。
/// 写者每发布一个 manifest 就 put 一次（last-writer-wins，payload = manifest id）；
/// 读者用 1 次 GET 探测 head 是否变化，替代每次 TTL 检查的 LIST `_heads/`。
/// 指针可能短暂落后于 head log（崩溃窗口）或指向被回滚的 sibling manifest，
/// 两者都仍是有效快照——只影响新鲜度，不影响正确性。
pub fn head_pointer_key(ns : String) -> String {
  "\{ns}/_head_ptr"
}

///|
/// 读 head 指针；缺失/非法 utf8 返回 None（旧数据/写者未升级）。
pub async fn[S : ObjectStore] read_head_pointer(store : S, ns : String) -> String? {
  match store.get(head_pointer_key(ns)) {
    Some(bs) =>
      // `try {..} catch`（而非 `try?`）：跨编译器版本可移植。
      (try {
        Some(@utf8.decode(bs.exact_view()))
      } catch {
        _ => None
      })
    None => None
  }
}

///|
/// 写 head 指针（普通 put；并发写者 last-writer-wins，详见 head_pointer_key 注释）。
pub async fn[S : ObjectStore] write_head_pointer(
  store : S,
  ns : String,
  manifest_id : String,
) -> Unit {
  store.put(head_pointer_key(ns), @utf8.encode(manifest_id))
}

///|
/// 列举 `_heads/`，返回 (最大 id, 大于 floor 的所有 id)。没有记录时 max 回退到
/// fallback（旧 namespace.json 的 head_manifest，兼容旧数据）。
/// 发布路径用同一份 LIST 结果做 max 仲裁 + fork 检测，避免重复 LIST。
pub async fn[S : ObjectStore] read_head_state(
  store : S,
  ns : String,
  fallback : String,
) -> (String, Array[String]) {
  let prefix = head_prefix(ns)
  let mut max = ""
  let newer : Array[String] = Array()
  for key in store.list(prefix) {
    if key.has_prefix(prefix) {
      let id = key[prefix.length():].to_owned()
      if max == "" || id_compare(id, max) > 0 {
        max = id
      }
      if id_compare(id, fallback) > 0 {
        newer.push(id)
      }
    }
  }
  let head = if max == "" { fallback } else { max }
  (head, newer)
}

///|
/// 列举 `_heads/` 取最大 id；优先用 1 次 GET 探测 `_head_ptr`（0 LIST），
/// 缺失时回退到列举 `_heads/` 或 fallback。
pub async fn[S : ObjectStore] read_head(
  store : S,
  ns : String,
  fallback : String,
) -> String {
  match read_head_pointer(store, ns) {
    Some(ptr) => if ptr != "" { ptr } else { fallback }
    None => read_head_state(store, ns, fallback).0
  }
}

///|
/// 写一个新 head 记录（create-only；不支持条件创建的 store 退化为 put，
/// 唯一 key 仍不会覆盖其他 writer 的记录）。
pub async fn[S : ObjectStore] write_head(
  store : S,
  ns : String,
  manifest_id : String,
) -> Unit {
  let key = head_key(ns, manifest_id)
  let payload = b""
  if !store.put_if_match(key, Expected(None), payload) {
    match store.get(key) {
      Some(_) => ()
      None => store.put(key, payload)
    }
  }
}

///|
/// 删除所有 id < keep_id 的 head 记录。并发写者写入更高的 id 时不会被删
/// （它不在本次 list 结果里；即使出现，也 > keep_id）。
pub async fn[S : ObjectStore] gc_heads(
  store : S,
  ns : String,
  keep_id : String,
) -> Unit {
  let prefix = head_prefix(ns)
  for key in store.list(prefix) {
    if key.has_prefix(prefix) {
      let id = key[prefix.length():].to_owned()
      if id_compare(id, keep_id) < 0 {
        store.delete(key)
      }
    }
  }
}
