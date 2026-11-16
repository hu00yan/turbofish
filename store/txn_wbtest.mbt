///|
/// 观察→rebase→发布 一遍成功。
async test "commit_with_rebase: 一次成功发布" {
  let s = MemStore::new()
  s.put("head", b"v1")
  let r = commit_with_rebase(
    3,
    async fn () {
      s.get("head")
    },
    fn (_attempt, observed) {
      match observed {
        Some(body) => Some(body + b"->v2")
        None => None
      }
    },
    async fn (_observed, payload) {
      s.put("head", payload)
      true
    },
  )
  assert_eq(r.ok, true)
  assert_eq(r.attempts, 1)
  assert_eq(s.get("head"), Some(b"v1->v2"))
}

///|
/// 发布冲突 ⇒ 整体重试：第二次观察到新状态，rebase 基于新状态计算（无丢失更新）。
async test "commit_with_rebase: 冲突整体重试，rebase 每次基于新观察" {
  let s = MemStore::new()
  s.put("head", b"A")
  let attempts_seen : Array[Int] = Array()
  let payloads : Array[Bytes] = Array()
  // 模拟并发写者：第一次发布前抢跑把 head 改成 B
  let mut raced = false
  let r = commit_with_rebase(
    3,
    async fn () {
      s.get("head")
    },
    fn (attempt, observed) {
      attempts_seen.push(attempt)
      match observed {
        Some(body) => Some(body + "+mine")
        None => None
      }
    },
    async fn (observed, payload) {
      payloads.push(payload)
      if !raced {
        raced = true
        s.put("head", b"B")
        return false // 冲突：本次发布失败，必须整体重试
      }
      s.put("head", payload)
      true
    },
  )
  assert_eq(r.ok, true)
  assert_eq(r.attempts, 2)
  assert_eq(attempts_seen, [1, 2])
  // 第二次 payload 基于重试后观察（B），不是旧负载（A+mine）
  assert_eq(payloads, [b"A+mine", b"B+mine"])
  assert_eq(s.get("head"), Some(b"B+mine"))
}

///|
/// build 返回 None = 干净放弃：不发布、不重试。
async test "commit_with_rebase: rebase 放弃则不发布" {
  let s = MemStore::new()
  let mut publishes = 0
  let r = commit_with_rebase(
    5,
    async fn () {
      42
    },
    fn (_attempt, _observed) {
      None
    },
    async fn (_observed, _payload) {
      publishes += 1
      true
    },
  )
  assert_eq(r.ok, false)
  assert_eq(r.attempts, 1)
  assert_eq(publishes, 0)
}

///|
/// 重试预算耗尽 ⇒ ok=false 且 attempts == max_attempts。
async test "commit_with_rebase: 预算耗尽返回失败" {
  let mut tries = 0
  let r = commit_with_rebase(
    3,
    async fn () {
      ()
    },
    fn (_attempt, _observed) {
      Some(b"x")
    },
    async fn (_observed, _payload) {
      tries += 1
      false // 永远冲突
    },
  )
  assert_eq(r.ok, false)
  assert_eq(r.attempts, 3)
  assert_eq(tries, 3)
}

///|
/// commit_cas_on：If-Match 语义（版本漂移 ⇒ 发布失败 ⇒ 整体重试）。
async test "commit_cas_on: 版本漂移冲突后重试成功" {
  let s = MemStore::new()
  s.put("head", b"base")
  let v0 = s.head_version("head")
  let seen_vers : Array[String?] = Array()
  let r = commit_cas_on(
    s,
    "head",
    3,
    fn (_attempt, ver, body) {
      seen_vers.push(ver)
      match body {
        Some(b) => Some(b + b"/next")
        None => None
      }
    },
  )
  // 没有并发干扰时一遍成功；观察到的版本 = v0
  assert_eq(r.ok, true)
  assert_eq(r.attempts, 1)
  assert_eq(seen_vers.length(), 1)
  assert_eq(seen_vers[0], v0)
  assert_eq(s.get("head"), Some(b"base/next"))
  // 并发推进版本：CAS 冲突
  let v1 = s.head_version("head")
  s.put("head", b"raced") // 版本推进
  assert_eq(s.head_version("head") != v1, true)
  let r2 = commit_cas_on(
    s,
    "head",
    3,
    fn (_attempt, _ver, body) {
      match body {
        Some(b) => Some(b + b"/mine")
        None => None
      }
    },
  )
  assert_eq(r2.ok, true)
  assert_eq(s.get("head"), Some(b"raced/mine"))
}

///|
/// commit_cas_on：观察版本匹配即覆盖（expected = 观察版本的 If-Match）。
async test "commit_cas_on: 观察版本匹配即覆盖" {
  let s = MemStore::new()
  s.put("head", b"exists")
  let r = commit_cas_on(
    s,
    "head",
    2,
    fn (_attempt, _ver, _body) {
      Some(b"created")
    },
  )
  assert_eq(r.ok, true)
  assert_eq(s.get("head"), Some(b"created"))
}
