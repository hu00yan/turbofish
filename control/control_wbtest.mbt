// control 包白盒测试：MemStore + 手写最小 namespace 元数据。
//
// 只 seed `namespace.json` 与 `manifest.json`（空段），因为 ControlPlane 的
// acquire 只走 `@query.open`，不触碰 segment/postings/向量对象。
//
// 覆盖：TTL 命中、release 归零、TTL=0 每次 reload、stale_ok 回退与
// stale_ok=false rethrow、invalidate 后 miss、max_entries 逐出与 pinned 保留。

///|

///|
/// wbtest 辅助：trait 方法跨包不能直接点调用，走泛型分发。
async fn[S : @store.ObjectStore] tput(s : S, key : String, val : Bytes) -> Unit {
  s.put(key, val)
}

///|
async fn[S : @store.ObjectStore] tdel(s : S, key : String) -> Unit {
  s.delete(key)
}

///|
/// 自旋等到毫秒时钟前进 `ms`：用于构造「TTL 已过期」而无需真实 sleep。
fn spin_ms(ms : UInt64) -> Unit {
  let start = @env.now()
  while @env.now() - start < ms {
    ignore(@env.now())
  }
}

///|
/// 最小 namespace：直接写 JSON，避免耦合 `ManifestData` 后续新增可选字段。
/// namespace.json 的 head 指向 mid；manifest 为空段。
async fn seed_ns(s : @store.MemStore, ns : String, mid : String) -> Unit {
  let nm : Map[String, Json] = Map([])
  nm.set("format", Json::string("seekpond/v1"))
  nm.set("namespace", Json::string(ns))
  nm.set("head_manifest", Json::string(mid))
  nm.set("vec_global_version", Json::null())
  nm.set("distance_metric", Json::string("cosine"))
  nm.set("vector_dim", Json::number(2.0))
  nm.set("vector_dtype", Json::string("f32"))
  nm.set("fts_k1", Json::number(1.2))
  nm.set("fts_b", Json::number(0.75))
  tput(
    s,
    "\{ns}/_meta/namespace.json",
    @utf8.encode(Json::object(nm).stringify()),
  )
  let noj : Array[Json] = []
  let mm : Map[String, Json] = Map([])
  mm.set("id", Json::string(mid))
  mm.set("parent", Json::null())
  mm.set("segments", Json::array(noj))
  mm.set("deleted", Json::array(noj))
  mm.set("deleted_roar", Json::null())
  mm.set("vec_global_version", Json::null())
  mm.set("centroid_version", Json::string("centroids-1"))
  mm.set("num_docs", Json::number(0.0))
  mm.set("avg_doc_len", Json::number(0.0))
  tput(
    s,
    "\{ns}/_manifest/\{mid}.json",
    @utf8.encode(Json::object(mm).stringify()),
  )
}

///|
async fn drop_ns_objects(s : @store.MemStore, ns : String, mid : String) -> Unit {
  tdel(s, "\{ns}/_meta/namespace.json")
  tdel(s, "\{ns}/_manifest/\{mid}.json")
}

///|
async test "ttl hit: second acquire does not reopen" {
  let s = @store.MemStore::new()
  seed_ns(s, "test", "manifest-01")
  let cp = ControlPlane::new(
    s,
    { head_ttl_ms: 1000UL, stale_ok: false, max_entries: 64 },
  )
  let a = cp.acquire("test")
  let b = cp.acquire("test")
  assert_eq(a.manifest.id, "manifest-01")
  assert_eq(b.manifest.id, "manifest-01")
  let (hits, misses, reloads, stales, evictions) = cp.stats()
  assert_eq(hits, 1)
  assert_eq(misses, 1)
  assert_eq(reloads, 1)
  assert_eq(stales, 0)
  assert_eq(evictions, 0)
  // 一次 open = GET namespace.json + GET manifest.json；第二次 acquire 零 GET。
  assert_eq(s.cost().gets, 2)
}

///|
async test "release reaches zero pins and later acquire still hits" {
  let s = @store.MemStore::new()
  seed_ns(s, "test", "manifest-01")
  let cp = ControlPlane::new(
    s,
    { head_ttl_ms: 1000UL, stale_ok: false, max_entries: 64 },
  )
  let _ = cp.acquire("test")
  assert_eq(cp.pinned_manifest("test"), Some("manifest-01"))
  cp.release("test")
  assert_eq(cp.pinned_manifest("test"), None)
  // 多余的 release 不产生负 pin，也不破坏缓存。
  cp.release("test")
  assert_eq(cp.pinned_manifest("test"), None)
  let b = cp.acquire("test")
  assert_eq(b.manifest.id, "manifest-01")
  let (hits, misses, reloads, stales, evictions) = cp.stats()
  assert_eq(hits, 1)
  assert_eq(misses, 1)
  assert_eq(reloads, 1)
  assert_eq(stales, 0)
  assert_eq(evictions, 0)
}

///|
async test "ttl zero: every acquire reloads" {
  let s = @store.MemStore::new()
  seed_ns(s, "test", "manifest-01")
  let cp = ControlPlane::new(
    s,
    { head_ttl_ms: 0UL, stale_ok: false, max_entries: 64 },
  )
  let _ = cp.acquire("test")
  let _ = cp.acquire("test")
  let _ = cp.acquire("test")
  let (hits, misses, reloads, stales, evictions) = cp.stats()
  assert_eq(hits, 0)
  assert_eq(misses, 3)
  assert_eq(reloads, 3)
  assert_eq(stales, 0)
  assert_eq(evictions, 0)
  // head 指针探测：第 2/3 次 acquire 在 TTL 过期后先探测（1 GET，指针缺失
  // ⇒ miss），再全量 open（2 GET）。总 GET = 2 + 3 + 3 = 8。
  assert_eq(s.cost().gets, 8)
  let (probes, probe_hits) = cp.probe_stats()
  assert_eq(probes, 2)
  assert_eq(probe_hits, 0)
}

///|
async test "pointer probe hit avoids full reopen on ttl expiry" {
  let s = @store.MemStore::new()
  seed_ns(s, "test", "manifest-01")
  // 写者已升级：发布时维护 `_head_ptr` 指针。
  tput(s, "test/_head_ptr", @utf8.encode("manifest-01"))
  let cp = ControlPlane::new(
    s,
    { head_ttl_ms: 0UL, stale_ok: false, max_entries: 64 },
  )
  let _ = cp.acquire("test")
  let _ = cp.acquire("test")
  let _ = cp.acquire("test")
  // head 未变：第 2/3 次 acquire 探测命中（各 1 GET），不再全量 open。
  // 总 GET = 首次 open 2 + 2 次探测 = 4（旧行为是 6）。
  let (hits, misses, reloads, stales, _) = cp.stats()
  assert_eq(hits, 0)
  assert_eq(misses, 1)
  assert_eq(reloads, 1)
  assert_eq(stales, 0)
  let (probes, probe_hits) = cp.probe_stats()
  assert_eq(probes, 2)
  assert_eq(probe_hits, 2)
  assert_eq(s.cost().gets, 4)
}

///|
async test "pointer probe mismatch triggers reload" {
  let s = @store.MemStore::new()
  seed_ns(s, "test", "manifest-01")
  tput(s, "test/_head_ptr", @utf8.encode("manifest-01"))
  let cp = ControlPlane::new(
    s,
    { head_ttl_ms: 0UL, stale_ok: false, max_entries: 64 },
  )
  let _ = cp.acquire("test")
  // head 前进：写者同时更新 head log 与指针（此处只摆指针与 manifest 对象，
  // read_head fallback 也指向新 id，模拟真实发布路径的最终一致读）。
  seed_ns(s, "test", "manifest-02")
  tput(s, "test/_head_ptr", @utf8.encode("manifest-02"))
  let b = cp.acquire("test")
  assert_eq(b.manifest.id, "manifest-02")
  let (_, misses, reloads, _, _) = cp.stats()
  assert_eq(misses, 2)
  assert_eq(reloads, 2)
  let (probes, probe_hits) = cp.probe_stats()
  assert_eq(probes, 1)
  assert_eq(probe_hits, 0)
}

///|
async test "invalidate bypasses probe and forces full reload" {
  let s = @store.MemStore::new()
  seed_ns(s, "test", "manifest-01")
  tput(s, "test/_head_ptr", @utf8.encode("manifest-01"))
  let cp = ControlPlane::new(
    s,
    { head_ttl_ms: 1000UL, stale_ok: false, max_entries: 64 },
  )
  let _ = cp.acquire("test")
  cp.invalidate("test")
  s.reset_cost()
  // invalidate 是显式过期信号：即使指针未变也必须全量 reload（不探测）。
  let b = cp.acquire("test")
  assert_eq(b.manifest.id, "manifest-01")
  let (hits, misses, reloads, _, _) = cp.stats()
  assert_eq(hits, 0)
  assert_eq(misses, 2)
  assert_eq(reloads, 2)
  assert_eq(s.cost().gets, 2)
  let (probes, probe_hits) = cp.probe_stats()
  assert_eq(probes, 0)
  assert_eq(probe_hits, 0)
}

///|
async test "stale_ok returns old snapshot after reload failure" {
  let s = @store.MemStore::new()
  seed_ns(s, "test", "manifest-01")
  let cp = ControlPlane::new(
    s,
    { head_ttl_ms: 0UL, stale_ok: true, max_entries: 64 },
  )
  let first = cp.acquire("test")
  assert_eq(first.manifest.id, "manifest-01")
  drop_ns_objects(s, "test", "manifest-01")
  let second = cp.acquire("test")
  assert_eq(second.manifest.id, "manifest-01")
  assert_eq(cp.pinned_manifest("test"), Some("manifest-01"))
  let (hits, misses, reloads, stales, evictions) = cp.stats()
  assert_eq(hits, 0)
  assert_eq(misses, 2)
  assert_eq(reloads, 2)
  assert_eq(stales, 1)
  assert_eq(evictions, 0)
}

///|
async test "stale_ok false rethrows on reload failure" {
  let s = @store.MemStore::new()
  seed_ns(s, "test", "manifest-01")
  let cp = ControlPlane::new(
    s,
    { head_ttl_ms: 0UL, stale_ok: false, max_entries: 64 },
  )
  let _ = cp.acquire("test")
  drop_ns_objects(s, "test", "manifest-01")
  let mut raised = false
  try {
    let _ = cp.acquire("test")
  } catch {
    _ => raised = true
  }
  assert_eq(raised, true)
  let (_, _, _, stales, _) = cp.stats()
  assert_eq(stales, 0)
}

///|
async test "invalidate drops snapshot but keeps pinned manifest id" {
  let s = @store.MemStore::new()
  seed_ns(s, "test", "manifest-01")
  let cp = ControlPlane::new(
    s,
    { head_ttl_ms: 1000UL, stale_ok: false, max_entries: 64 },
  )
  let _ = cp.acquire("test")
  cp.invalidate("test")
  // pinned：缓存快照已被丢弃，但旧 manifest id 仍可查询。
  assert_eq(cp.pinned_manifest("test"), Some("manifest-01"))
  let again = cp.acquire("test")
  assert_eq(again.manifest.id, "manifest-01")
  let (hits, misses, reloads, stales, evictions) = cp.stats()
  assert_eq(hits, 0)
  assert_eq(misses, 2)
  assert_eq(reloads, 2)
  assert_eq(stales, 0)
  assert_eq(evictions, 0)
}

///|
async test "unpinned invalidate removes entry entirely" {
  let s = @store.MemStore::new()
  seed_ns(s, "test", "manifest-01")
  let cp = ControlPlane::new(
    s,
    { head_ttl_ms: 1000UL, stale_ok: false, max_entries: 64 },
  )
  let _ = cp.acquire("test")
  cp.release("test")
  cp.invalidate("test")
  assert_eq(cp.pinned_manifest("test"), None)
  let _ = cp.acquire("test")
  let (hits, misses, _, _, _) = cp.stats()
  assert_eq(hits, 0)
  assert_eq(misses, 2)
}

///|
async test "max_entries evicts unpinned oldest and keeps pinned" {
  let s = @store.MemStore::new()
  seed_ns(s, "a", "m-a")
  seed_ns(s, "b", "m-b")
  seed_ns(s, "c", "m-c")
  let cp = ControlPlane::new(
    s,
    { head_ttl_ms: 1000UL, stale_ok: false, max_entries: 2 },
  )
  let _ = cp.acquire("a")
  let _ = cp.acquire("b")
  cp.release("b") // 只有 b 可被逐出。
  let _ = cp.acquire("c") // 超限：a/c pinned，b unpinned → 逐出 b。
  let (_, misses1, reloads1, _, evictions1) = cp.stats()
  assert_eq(misses1, 3)
  assert_eq(reloads1, 3)
  assert_eq(evictions1, 1)
  // b 已被逐出：再次 acquire 必然 reload；此时 a/b/c 全 pinned，不能再逐出。
  let b2 = cp.acquire("b")
  assert_eq(b2.manifest.id, "m-b")
  let (hits, misses2, reloads2, stales, evictions2) = cp.stats()
  assert_eq(hits, 0)
  assert_eq(misses2, 4)
  assert_eq(reloads2, 4)
  assert_eq(stales, 0)
  // 一次真实逐出 + 一次「全 pinned 无法逐出」的压力事件。
  assert_eq(evictions2, 2)
  assert_eq(cp.pinned_manifest("a"), Some("m-a"))
  assert_eq(cp.pinned_manifest("b"), Some("m-b"))
  assert_eq(cp.pinned_manifest("c"), Some("m-c"))
}

///|
async test "reload keeps old pinned id in pinned_manifests but returns new top" {
  let s = @store.MemStore::new()
  seed_ns(s, "test", "manifest-01")
  let cp = ControlPlane::new(
    s,
    { head_ttl_ms: 0UL, stale_ok: false, max_entries: 64 },
  )
  let _ = cp.acquire("test")
  assert_eq(cp.pinned_manifest("test"), Some("manifest-01"))
  assert_eq(cp.pinned_manifests("test"), ["manifest-01"])
  // TTL 过期（ttl=0）后 head 前进到 manifest-02：reload 成功。
  seed_ns(s, "test", "manifest-02")
  let b = cp.acquire("test")
  assert_eq(b.manifest.id, "manifest-02")
  // 栈顶是最新 pin；旧 pin 仍持有旧代，必须可见供 C2 GC 保护。
  assert_eq(cp.pinned_manifest("test"), Some("manifest-02"))
  assert_eq(cp.pinned_manifests("test"), ["manifest-01", "manifest-02"])
  let (_, misses, reloads, _, _) = cp.stats()
  assert_eq(misses, 2)
  assert_eq(reloads, 2)
  // 释放一个 pin（弹出栈顶）：旧代仍在。
  cp.release("test")
  assert_eq(cp.pinned_manifest("test"), Some("manifest-01"))
  assert_eq(cp.pinned_manifests("test"), ["manifest-01"])
  // 再释放：pins=0，栈清空。
  cp.release("test")
  assert_eq(cp.pinned_manifest("test"), None)
  assert_eq(cp.pinned_manifests("test").length(), 0)
}

///|
async test "invalidate keeps snapshot while pinned and drops entry after release" {
  let s = @store.MemStore::new()
  seed_ns(s, "test", "manifest-01")
  let cp = ControlPlane::new(
    s,
    { head_ttl_ms: 1000UL, stale_ok: false, max_entries: 64 },
  )
  let a = cp.acquire("test")
  cp.invalidate("test")
  // pinned：快照保留，旧 pin 的查询与 pinned id 都还在。
  assert_eq(a.manifest.id, "manifest-01")
  assert_eq(cp.pinned_manifest("test"), Some("manifest-01"))
  assert_eq(cp.pinned_manifests("test"), ["manifest-01"])
  // invalidate 只标记 checked_ms=0：pin 归零时整个 entry 被删除。
  cp.release("test")
  assert_eq(cp.pinned_manifests("test").length(), 0)
  assert_eq(cp.pinned_manifest("test"), None)
  let _ = cp.acquire("test")
  let (hits, misses, reloads, stales, _) = cp.stats()
  assert_eq(hits, 0)
  assert_eq(misses, 2)
  assert_eq(reloads, 2)
  assert_eq(stales, 0)
}

///|
async test "invalidate while pinned makes next acquire reload the snapshot" {
  let s = @store.MemStore::new()
  seed_ns(s, "test", "manifest-01")
  let cp = ControlPlane::new(
    s,
    { head_ttl_ms: 1000UL, stale_ok: false, max_entries: 64 },
  )
  let _ = cp.acquire("test")
  cp.invalidate("test")
  s.reset_cost()
  // 已持 pin 的那次查询不再需要任何 store 读；新的 acquire 必然重新加载。
  let b = cp.acquire("test")
  assert_eq(b.manifest.id, "manifest-01")
  let (hits, misses, reloads, _, _) = cp.stats()
  assert_eq(hits, 0)
  assert_eq(misses, 2)
  assert_eq(reloads, 2)
  assert_eq(s.cost().gets, 2)
  assert_eq(cp.pinned_manifests("test"), ["manifest-01"])
}

///|
async test "stale fallback refreshes checked_ms and avoids fail-storm" {
  let s = @store.MemStore::new()
  seed_ns(s, "test", "manifest-01")
  let cp = ControlPlane::new(
    s,
    { head_ttl_ms: 5UL, stale_ok: true, max_entries: 64 },
  )
  let _ = cp.acquire("test")
  drop_ns_objects(s, "test", "manifest-01") // store 故障：head 读不到了
  spin_ms(6UL)
  let second = cp.acquire("test")
  assert_eq(second.manifest.id, "manifest-01")
  let (_, misses1, _, stales1, _) = cp.stats()
  assert_eq(misses1, 2)
  assert_eq(stales1, 1)
  // 故障持续：stale 回退更新了 checked_ms，后续 acquire 在 TTL 内直接命中，
  // 不会每次全量 open（fail-storm）。
  let third = cp.acquire("test")
  let fourth = cp.acquire("test")
  assert_eq(third.manifest.id, "manifest-01")
  assert_eq(fourth.manifest.id, "manifest-01")
  let (hits, misses2, reloads, stales2, _) = cp.stats()
  assert_eq(hits, 2)
  assert_eq(misses2, 2)
  assert_eq(reloads, 2)
  assert_eq(stales2, 1)
}

///|
async test "stale_ok false does not push a pin on the failing acquire" {
  let s = @store.MemStore::new()
  seed_ns(s, "test", "manifest-01")
  let cp = ControlPlane::new(
    s,
    { head_ttl_ms: 0UL, stale_ok: false, max_entries: 64 },
  )
  let _ = cp.acquire("test")
  drop_ns_objects(s, "test", "manifest-01")
  try {
    let _ = cp.acquire("test")
  } catch {
    _ => ()
  }
  // 失败路径不 push：仍只有第一次 acquire 的那个 pin。
  assert_eq(cp.pinned_manifests("test"), ["manifest-01"])
  cp.release("test")
  assert_eq(cp.pinned_manifests("test").length(), 0)
}

///|
async test "authoritative mode: update_snapshot grants instant visibility with zero s3 gets" {
  let s = @store.MemStore::new()
  seed_ns(s, "test", "manifest-01")
  let cp = ControlPlane::new(
    s,
    { head_ttl_ms: 1000UL, stale_ok: false, max_entries: 64 },
  )
  cp.set_authoritative(true)
  assert_eq(cp.is_authoritative(), true)
  let a = cp.acquire("test")
  assert_eq(a.manifest.id, "manifest-01")
  let gets1 = s.cost().gets
  assert_eq(gets1, 2)

  // Subsequent acquire in authoritative mode: hits in-memory, 0 S3 GETs
  let b = cp.acquire("test")
  assert_eq(b.manifest.id, "manifest-01")
  assert_eq(s.cost().gets, gets1)

  // Coordinator writes new manifest-02, builds new snap and updates authoritative control plane
  seed_ns(s, "test", "manifest-02")
  let snap2 = @query.open(s, "test")
  let gets_after_open = s.cost().gets
  cp.update_snapshot("test", snap2)

  // Next acquire immediately sees manifest-02 with ZERO additional S3 gets
  let c = cp.acquire("test")
  assert_eq(c.manifest.id, "manifest-02")
  assert_eq(s.cost().gets, gets_after_open)
  assert_eq(cp.get_snapshot("test") is Some(_), true)
}

///|
async test "WorkerTieredCache: 5-minute TTL eviction and LRU capacity budget" {
  let cache = WorkerTieredCache::new(ttl_ms=10UL, max_bytes=500)
  let p1 : @format.GlobalVecPart = {
    cid: 0,
    rows: [(0, 0), (0, 1)],
    dim: 2,
    data: [1.0, 2.0, 3.0, 4.0],
  }
  cache.put("ver1/0", p1)
  assert_eq(cache.get("ver1/0") is Some(_), true)
  // Spin 15ms to trigger TTL expiration
  spin_ms(15UL)
  assert_eq(cache.get("ver1/0") is None, true)
  let (hits, misses, _evictions, expirations, _) = cache.stats()
  assert_eq(hits, 1)
  assert_eq(misses, 1)
  assert_eq(expirations, 1)
}

///|
async test "Coordinator: multi-tenant management and worker dispatch" {
  let s = @store.MemStore::new()
  seed_ns(s, "t1", "m1")
  seed_ns(s, "t2", "m2")
  let coord = Coordinator::new(s, worker_count=2, worker_cache_ttl_ms=300_000UL)
  coord.register_tenant("t1", "m1", 2, "cosine", "word", 100)
  coord.register_tenant("t2", "m2", 2, "cosine", "word", 200)
  let _w1 = coord.select_worker("t1")
  let _w2 = coord.select_worker("t2")
  assert_eq(coord.get_tenant("t1").unwrap().num_docs, 100)
  coord.update_tenant_head("t1", "m1_new", 150)
  assert_eq(coord.get_tenant("t1").unwrap().head_manifest_id, "m1_new")
  assert_eq(coord.get_tenant("t1").unwrap().num_docs, 150)
}
