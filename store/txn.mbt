// 唯一发布原语（INV-4）。
//
// 事故根因之一是发布用的 CAS 状态机（读 head → rebase → 条件写 → 冲突重试）
// 散落在 compact/ingest/lease 多处、各写各的重试循环，导致"逃逸"式的局部正确、
// 全局丢更新。收敛为**唯一发布原语**后：
// - 发布路径只有 `commit_with_rebase` 一条；
// - rebase 策略是纯函数（观察状态 → 新负载），无法夹带跨重试的隐藏状态；
// - publish 冲突（返回 false）⇒ **整体重算**，绝不原地重试旧负载。

///|
/// 发布结果：`ok` = 是否发布成功；`attempts` = 实际尝试次数（≥ 1）。
#derive(Debug, Eq)
pub(all) struct CommitResult {
  ok : Bool
  attempts : Int
}

///|
/// 唯一发布原语：观察 → rebase → 发布 → 冲突整体重试。
///
/// 每次尝试：
/// 1. `observe()` 读取当前发布状态（CAS 场景下应为 (版本, 内容)）；
/// 2. `build(attempt, observed)` 纯函数计算新负载，`None` = 干净放弃（ok=false）；
/// 3. `publish(observed, payload)` 发布；`false` = 冲突（输给并发写者）→ 整体重试。
///
/// 重试预算耗尽 ⇒ `CommitResult::{ ok: false, attempts: max_attempts }`。
///
/// 顺序约束（CAS 场景）：observe 内必须**先读版本再读内容**——内容只会比版本
/// 新（读间隙被并发写者推进），此时以旧版本为 expected 的条件写必然失败 ⇒
/// 重试；不存在"负载基于旧内容、CAS 却通过"的丢失更新窗口。
pub async fn[T] commit_with_rebase(
  max_attempts : Int,
  observe : async () -> T,
  build : (Int, T) -> Bytes?,
  publish : async (T, Bytes) -> Bool,
) -> CommitResult {
  let mut attempt = 0
  while attempt < max_attempts {
    attempt += 1
    let observed = observe()
    let payload = match build(attempt, observed) {
      None => return CommitResult::{ ok: false, attempts: attempt }
      Some(p) => p
    }
    if publish(observed, payload) {
      return CommitResult::{ ok: true, attempts: attempt }
    }
  }
  CommitResult::{ ok: false, attempts: attempt }
}

///|
/// CAS 键发布（S3 If-Match 语义）的常用包装：
/// 观察 = (head_version, get)，发布 = `put_if_match(key, Expected(ver), payload)`。
/// `rebase` 收到 (attempt, 版本, 内容)；`None` = 干净放弃。
pub async fn[S : ObjectStore] commit_cas_on(
  store : S,
  head_key : String,
  max_attempts : Int,
  rebase : (Int, String?, Bytes?) -> Bytes?,
) -> CommitResult {
  commit_with_rebase(
    max_attempts,
    async fn () {
      // 先版本后内容（顺序契约，见 commit_with_rebase 文档）
      let ver = store.head_version(head_key)
      let body = store.get(head_key)
      (ver, body)
    },
    fn (attempt, observed) {
      let (ver, body) = observed
      rebase(attempt, ver, body)
    },
    async fn (observed, payload) {
      let (ver, _) = observed
      store.put_if_match(head_key, Expected(ver), payload)
    },
  )
}
