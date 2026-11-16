// ObjectStore 一致性契约（T2 conformance 层）。
//
// 同一套契约跑遍所有后端（MemStore / FsStore / S3Client / S3Store / SimStore…）：
// 每个后端的 wbtest 只需调用 `conformance_report`，任何语义漂移（读写回环、
// CAS 语义、范围读截短、批量一致性、list 顺序、删除幂等）都在此集中暴露，
// 无法靠"改断言"过关——契约文本只在本文件维护。
//
// 返回空串 = 全部通过；否则返回人类可读的违规清单（一行一条）。

///|
/// 一致性契约：对 factory 给出的新后端实例执行全套行为断言。
/// factory 必须每次返回**空的**（或可清空的）后端实例。
pub async fn[S : @store.ObjectStore] conformance_report(factory : () -> S) -> String {
  let fails : Array[String] = Array()
  let s = factory()

  // ---- 1. put/get 往返 & 缺失读 ----
  let v1 = Bytes::makei(64, i => i.to_byte())
  s.put("c/k1", v1)
  match s.get("c/k1") {
    Some(b) => if b != v1 {
      fails.push("put/get 往返字节不一致")
    }
    None => fails.push("put 后 get 返回 None")
  }
  match s.get("c/missing") {
    None => ()
    Some(_) => fails.push("缺失 key 的 get 应为 None")
  }

  // ---- 2. CAS：Expected(None) 仅创建一次（INV-7） ----
  if !s.put_if_match("c/cas", @store.Expected(None), b"first") {
    fails.push("Expected(None) 创建应成功")
  }
  if s.put_if_match("c/cas", @store.Expected(None), b"second") {
    fails.push("Expected(None) 对已存在 key 应失败")
  }
  match s.get("c/cas") {
    Some(b) => if b != b"first" {
      fails.push("失败的 CAS 不得改变值")
    }
    None => fails.push("c/cas 丢失")
  }

  // ---- 3. CAS：Expected(Some(v)) 版本匹配（INV-5/7） ----
  let ver = s.head_version("c/cas")
  if ver is None {
    fails.push("head_version 对已存在 key 不应为 None")
  }
  if !s.put_if_match("c/cas", @store.Expected(ver), b"third") {
    fails.push("Expected(Some(当前版本)) 应成功")
  }
  if s.put_if_match("c/cas", @store.Expected(ver), b"fourth") {
    fails.push("Expected(Some(旧版本)) 应失败")
  }
  match s.get("c/cas") {
    Some(b) => if b != b"third" {
      fails.push("旧版本 CAS 失败后值应为 third")
    }
    None => fails.push("c/cas 丢失")
  }
  let ver2 = s.head_version("c/cas")
  if ver2 == ver {
    fails.push("成功写入后 head_version 必须变化（INV-5）")
  }

  // ---- 4. 范围读：逐字节一致 / 越界截短 / len<=0 空（INV-8） ----
  let whole = s.get_range("c/k1", @store.ByteRange::{ off: 0, len: 10000 })
  match whole {
    Some(b) => if b != v1 {
      fails.push("超长 get_range 应截短为整个对象")
    }
    None => fails.push("get_range 对已存在 key 不应为 None")
  }
  let mid = s.get_range("c/k1", @store.ByteRange::{ off: 10, len: 8 })
  match mid {
    Some(b) => if b != v1[10:18].to_owned() {
      fails.push("get_range 中段字节不一致")
    }
    None => fails.push("get_range 中段返回 None")
  }
  let zero = s.get_range("c/k1", @store.ByteRange::{ off: 10, len: 0 })
  match zero {
    Some(b) => if b.length() != 0 {
      fails.push("len=0 的 get_range 应为空字节串")
    }
    None => ()
  }
  match s.get_range("c/missing", @store.ByteRange::{ off: 0, len: 4 }) {
    None => ()
    Some(_) => fails.push("缺失 key 的 get_range 应为 None")
  }

  // ---- 5. 批量范围读：与单键逐位一致、缺失原位 None（INV-9） ----
  let ranges = [
    @store.KeyRange::{ key: "c/k1", off: 0, len: 4 },
    @store.KeyRange::{ key: "c/missing", off: 0, len: 4 },
    @store.KeyRange::{ key: "c/k1", off: 60, len: 100 },
    @store.KeyRange::{ key: "c/k1", off: 5, len: 0 },
  ]
  let batch = s.get_range_many(ranges)
  if batch.length() != 4 {
    fails.push("get_range_many 输出长度应与输入相同")
  } else {
    for i in 0..<4 {
      let single = s.get_range(ranges[i].key, @store.ByteRange::{ off: ranges[i].off, len: ranges[i].len })
      if batch[i] != single {
        fails.push("get_range_many 与单键不一致 @\{i}")
      }
    }
    if batch[1] is Some(_) {
      fails.push("get_range_many 缺失 key 原位应为 None")
    }
  }

  // ---- 6. 批量整读：与单键一致、缺失原位 None ----
  let gkeys = ["c/k1", "c/missing", "c/cas"]
  let gmany = s.get_many(gkeys)
  if gmany.length() != 3 {
    fails.push("get_many 输出长度应与输入相同")
  } else {
    for i in 0..<3 {
      if gmany[i] != s.get(gkeys[i]) {
        fails.push("get_many 与单键不一致 @\{i}")
      }
    }
  }

  // ---- 7. put_many 与单键一致 ----
  s.put_many([
    ("c/b1", b"beta1"),
    ("c/b2", b"beta2"),
  ])
  match (s.get("c/b1"), s.get("c/b2")) {
    (Some(a), Some(b)) => if a != b"beta1" || b != b"beta2" {
      fails.push("put_many 写入值不一致")
    }
    _ => fails.push("put_many 后 key 丢失")
  }

  // ---- 8. list：升序、prefix 过滤 ----
  let all = s.list("c/")
  let mut sorted = true
  let mut i = 1
  while i < all.length() {
    if all[i - 1] > all[i] {
      sorted = false
    }
    i += 1
  }
  if !sorted {
    fails.push("list 必须升序")
  }
  let has = fn(k) {
    all.iter().any(x => x == k)
  }
  if !has("c/k1") || !has("c/cas") || !has("c/b1") {
    fails.push("list 缺少已写入的 key")
  }
  if has("c/missing") {
    fails.push("list 出现未写入的 key")
  }
  let only_b = s.list("c/b")
  if only_b.length() != 2 || !has("c/b1") {
    fails.push("prefix 过滤异常")
  }

  // ---- 9. delete：幂等、读回 None ----
  s.delete("c/b1")
  s.delete("c/b1")
  match s.get("c/b1") {
    None => ()
    Some(_) => fails.push("delete 后 get 应为 None")
  }

  // ---- 10. head_version：缺失为 None ----
  match s.head_version("c/missing") {
    None => ()
    Some(_) => fails.push("缺失 key 的 head_version 应为 None")
  }

  if fails.is_empty() {
    ""
  } else {
    {
      let mut out = "[conformance] "
      let mut j = 0
      while j < fails.length() {
        if j > 0 {
          out = out + "; "
        }
        out = out + fails[j]
        j += 1
      }
      out
    }
  }
}
