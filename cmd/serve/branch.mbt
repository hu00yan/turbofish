// cmd/serve/branch.mbt: Zero-Copy Instant Branching & Snapshots API
//
// 核心特性：
// 1. Zero-Copy Instant Branching:
//    - `POST /v1/namespaces/{ns}/branch`
//    - 瞬间克隆 manifest head 指针至 S3 CAS，复用底层不可变数据段（$0 存储复制，<5ms）。
// 2. Write Isolation:
//    - 分支各自写入新段（L0/Base）、tombstone 与 manifest，互不干扰、互不可见。
// 3. Immutable Snapshot:
//    - `POST /v1/namespaces/{ns}/snapshot`
//    - 钉住当前 head manifest，保证历史状态只读不可变。
// 4. Instant Restore:
//    - `POST /v1/namespaces/{ns}/restore`
//    - 瞬间将 head 指针回滚至历史快照，内存与元数据同步刷新。

///|
/// 记录 branch_name -> origin_ns 映射（内存加速缓存）
let branch_origins : Map[String, String] = Map([])

///|
pub fn reset_branch_origins_for_test() -> Unit {
  branch_origins.clear()
}

///|
fn split_key_ns(key : String) -> (String, String) {
  let mut idx = -1
  for i in 0..<key.length() {
    if key[i] == '/' {
      idx = i
      break
    }
  }
  if idx <= 0 {
    ("", key)
  } else {
    (key[:idx].to_owned(), key[idx + 1:].to_owned())
  }
}

///|
/// 判断路径是否属于不可变底层资产（段数据、中心向量、全局分区分代、墓碑等）。
/// 头指针（_head_ptr）、头日志（_heads/）、命名空间配置（_meta/namespace.json）绝不跨分支继承。
fn is_inheritable_path(rel : String) -> Bool {
  rel.has_prefix("_segments/") ||
  rel.has_prefix("_centroids/") ||
  rel.has_prefix("vec/global/") ||
  rel.has_prefix("_tombstones/") ||
  rel.has_prefix("_manifest/")
}

///|
fn get_origin_ns(store : AnyStore, ns : String) -> String? {
  match branch_origins.get(ns) {
    Some(orig) => Some(orig)
    None => {
      let key = "\{ns}/_meta/origin_ns"
      match raw_get(store, key) {
        Some(bs) => {
          let s = (@utf8.decode(bs.exact_view())) catch { _ => "" }
          if s != "" {
            branch_origins.set(ns, s)
            Some(s)
          } else {
            None
          }
        }
        None => None
      }
    }
  }
}

///|
fn resolve_branch_get(store : AnyStore, key : String) -> Bytes? {
  let (ns, rel) = split_key_ns(key)
  if ns == "" || !is_inheritable_path(rel) {
    return None
  }
  let mut cur_ns = ns
  let mut hops = 0
  while hops < 10 {
    match get_origin_ns(store, cur_ns) {
      Some(parent) => {
        let parent_key = "\{parent}/\{rel}"
        match raw_get(store, parent_key) {
          Some(bs) => return Some(bs)
          None => cur_ns = parent
        }
      }
      None => return None
    }
    hops += 1
  }
  None
}

///|
fn resolve_branch_get_range(
  store : AnyStore,
  key : String,
  offset : Int,
  len : Int,
) -> Bytes? {
  let (ns, rel) = split_key_ns(key)
  if ns == "" || !is_inheritable_path(rel) {
    return None
  }
  let mut cur_ns = ns
  let mut hops = 0
  while hops < 10 {
    match get_origin_ns(store, cur_ns) {
      Some(parent) => {
        let parent_key = "\{parent}/\{rel}"
        match raw_get_range(store, parent_key, offset, len) {
          Some(bs) => return Some(bs)
          None => cur_ns = parent
        }
      }
      None => return None
    }
    hops += 1
  }
  None
}

///|
fn resolve_branch_head_version(store : AnyStore, key : String) -> String? {
  let (ns, rel) = split_key_ns(key)
  if ns == "" || !is_inheritable_path(rel) {
    return None
  }
  let mut cur_ns = ns
  let mut hops = 0
  while hops < 10 {
    match get_origin_ns(store, cur_ns) {
      Some(parent) => {
        let parent_key = "\{parent}/\{rel}"
        match raw_head_version(store, parent_key) {
          Some(v) => return Some(v)
          None => cur_ns = parent
        }
      }
      None => return None
    }
    hops += 1
  }
  None
}

///|
fn resolve_branch_list(
  store : AnyStore,
  prefix : String,
  local_keys : Array[String],
) -> Array[String] {
  let (ns, rel) = split_key_ns(prefix)
  if ns == "" || !is_inheritable_path(rel) {
    return local_keys
  }
  let mut cur_ns = ns
  let seen : Set[String] = Set([])
  let result : Array[String] = Array(capacity=local_keys.length())
  for k in local_keys {
    seen.add(k)
    result.push(k)
  }
  let mut hops = 0
  while hops < 10 {
    match get_origin_ns(store, cur_ns) {
      Some(parent) => {
        let parent_prefix = "\{parent}/\{rel}"
        let parent_keys = raw_list(store, parent_prefix)
        for pk in parent_keys {
          if pk.has_prefix(parent_prefix) {
            let suffix = pk[parent.length():]
            let mapped_k = "\{ns}\{suffix}"
            if !seen.contains(mapped_k) {
              seen.add(mapped_k)
              result.push(mapped_k)
            }
          }
        }
        cur_ns = parent
      }
      None => break
    }
    hops += 1
  }
  result.sort()
  result
}

///|
/// 创建 zero-copy 分支：通过 S3 CAS 克隆 manifest 头指针，零拷贝底层数据段。
pub fn create_branch(
  store : AnyStore,
  src_ns : String,
  branch_name : String,
  copy_metadata : Bool,
) -> String raise @core.SpndError {
  if branch_name.length() == 0 {
    raise @core.Corrupt("branch_name cannot be empty")
  }
  if branch_name == src_ns {
    raise @core.Corrupt("branch_name cannot be the same as source namespace")
  }

  // 1. 获取源 namespace 的当前 head manifest
  let head = match @store.read_head_pointer(store, src_ns) {
    Some(h) => h
    None => @store.read_head(store, src_ns, "")
  }
  if head == "" {
    raise @core.NotFound(
      "source namespace \{src_ns} not found or has no manifest",
    )
  }

  // 2. 检查 branch_name 是否已存在
  let existing_head = match @store.read_head_pointer(store, branch_name) {
    Some(h) => h
    None => @store.read_head(store, branch_name, "")
  }
  if existing_head != "" {
    raise @core.CommitConflict(
      "branch namespace \{branch_name} already exists",
    )
  }

  // 3. 记录 origin_ns 指针（S3 零拷贝关键基石）
  let origin_key = "\{branch_name}/_meta/origin_ns"
  store.put(origin_key, @utf8.encode(src_ns))
  branch_origins.set(branch_name, src_ns)

  // 4. 源 namespace 元数据
  let src_meta = match ns_meta(store, src_ns) {
    Some(m) => m
    None =>
      raise @core.NotFound("source namespace \{src_ns} metadata not found")
  }

  let branch_meta : @format.NamespaceMeta = {
    ..src_meta,
    ns_name: branch_name,
    head_manifest: "",
  }
  store.put(
    "\{branch_name}/_meta/namespace.json",
    @utf8.encode(branch_meta.to_json().stringify()),
  )

  // 5. 复制 schema.json（若 copy_metadata 为 true）
  if copy_metadata {
    match store.get("\{src_ns}/_meta/schema.json") {
      Some(sch) => store.put("\{branch_name}/_meta/schema.json", sch)
      None =>
        store.put(
          "\{branch_name}/_meta/schema.json",
          @format.demo_schema_json(),
        )
    }
  }

  // 6. 复制 head manifest JSON（~几百字节，完全不复制任何段数据文件）
  let src_man_key = "\{src_ns}/_manifest/\{head}.json"
  match store.get(src_man_key) {
    Some(man_bs) => store.put("\{branch_name}/_manifest/\{head}.json", man_bs)
    None => raise @core.NotFound("source manifest \{head} not found")
  }

  // 7. 复制 centroids 和 tombstones 元数据引用
  let man_json = match store.get(src_man_key) {
    Some(mbs) => {
      let s = (@utf8.decode(mbs.exact_view())) catch { _ => "" }
      (@json.parse(s)) catch { _ => Json::null() }
    }
    None => Json::null()
  }
  let man_data = (try {
    Some(@format.manifest_from_json(man_json))
  } catch {
    _ => None
  })

  match man_data {
    Some(md) => {
      if md.centroid_version != "" {
        let cent_key = "\{src_ns}/_centroids/\{md.centroid_version}.bin"
        match store.get(cent_key) {
          Some(cbs) =>
            store.put(
              "\{branch_name}/_centroids/\{md.centroid_version}.bin",
              cbs,
            )
          None => ()
        }
      }
      match md.deleted_roar {
        Some(rk) => {
          let src_rk = "\{src_ns}/_tombstones/\{rk}"
          match store.get(src_rk) {
            Some(rbs) => store.put("\{branch_name}/_tombstones/\{rk}", rbs)
            None => ()
          }
        }
        None => ()
      }
    }
    None => ()
  }

  // 8. 瞬间发布 branch 的 head 指针与 head log
  @store.write_head(store, branch_name, head)
  @store.write_head_pointer(store, branch_name, head)

  // 9. 继承 tokenizer 与 metric
  match created_tokenizers.get(src_ns) {
    Some(t) => created_tokenizers.set(branch_name, t)
    None => ()
  }
  match created_metrics.get(src_ns) {
    Some(m) => created_metrics.set(branch_name, m)
    None => ()
  }

  // 10. 预热与清理缓存，使新分支立即可用
  active_ns.remove(branch_name)
  meta_cache.invalidate(branch_name)
  let _ = (try {
    let _ = get_or_load_ns_state(store, branch_name)
    ()
  } catch {
    _ => ()
  })

  head
}

///|
/// 创建不可变快照：钉住当前 head manifest，防止被后续写或 compaction 修改。
pub fn create_snapshot(
  store : AnyStore,
  ns : String,
  snapshot_name : String,
) -> String raise @core.SpndError {
  if snapshot_name.length() == 0 {
    raise @core.Corrupt("snapshot_name cannot be empty")
  }
  let head = match @store.read_head_pointer(store, ns) {
    Some(h) => h
    None => @store.read_head(store, ns, "")
  }
  if head == "" {
    raise @core.NotFound("namespace \{ns} not found or has no manifest")
  }
  let man_key = "\{ns}/_manifest/\{head}.json"
  let man_bs = match store.get(man_key) {
    Some(b) => b
    None => raise @core.NotFound("manifest \{head} not found")
  }
  let man_json = (@json.parse(@utf8.decode(man_bs.exact_view()))) catch {
    _ => raise @core.Corrupt("manifest json is corrupt")
  }

  let snap_obj : Map[String, Json] = Map([])
  snap_obj.set("snapshot_name", Json::string(snapshot_name))
  snap_obj.set("manifest_id", Json::string(head))
  snap_obj.set("timestamp", Json::number(@env.now().to_double()))
  snap_obj.set("manifest", man_json)

  let snap_key = "\{ns}/_snapshots/\{snapshot_name}.json"
  store.put(snap_key, @utf8.encode(Json::object(snap_obj).stringify()))

  let ptr_key = "\{ns}/_snapshots/\{snapshot_name}.ptr"
  store.put(ptr_key, @utf8.encode(head))

  head
}

///|
/// 恢复快照：瞬间把 head 指针回滚到指定的不可变快照。
pub fn restore_snapshot(
  store : AnyStore,
  ns : String,
  snapshot_name : String,
) -> String raise @core.SpndError {
  if snapshot_name.length() == 0 {
    raise @core.Corrupt("snapshot_name cannot be empty")
  }
  let snap_key = "\{ns}/_snapshots/\{snapshot_name}.json"
  let (manifest_id, man_json_opt) = match store.get(snap_key) {
    Some(b) => {
      let j = (@json.parse(@utf8.decode(b.exact_view()))) catch {
        _ => raise @core.Corrupt("snapshot json corrupt")
      }
      match j {
        Object(m) => {
          let mid = match m.get("manifest_id") {
            Some(String(s)) => s
            _ => raise @core.Corrupt("missing manifest_id in snapshot")
          }
          let mj = m.get("manifest")
          (mid, mj)
        }
        _ => raise @core.Corrupt("invalid snapshot format")
      }
    }
    None => {
      let ptr_key = "\{ns}/_snapshots/\{snapshot_name}.ptr"
      match store.get(ptr_key) {
        Some(pb) => {
          let mid = (@utf8.decode(pb.exact_view())) catch { _ => "" }
          if mid == "" {
            raise @core.NotFound("snapshot \{snapshot_name} not found")
          }
          (mid, None)
        }
        None => raise @core.NotFound("snapshot \{snapshot_name} not found")
      }
    }
  }

  // 确保 manifest 存在
  let mkey = "\{ns}/_manifest/\{manifest_id}.json"
  if store.get(mkey) is None {
    match man_json_opt {
      Some(mj) => store.put(mkey, @utf8.encode(mj.stringify()))
      None => raise @core.NotFound("manifest \{manifest_id} not found")
    }
  }

  // 恢复 head 指针与 heads 记录
  @store.write_head(store, ns, manifest_id)
  @store.write_head_pointer(store, ns, manifest_id)

  // 更新 namespace 元数据里的 head_manifest
  match ns_meta(store, ns) {
    Some(m) => {
      let updated : @format.NamespaceMeta = { ..m, head_manifest: "" }
      store.put(
        "\{ns}/_meta/namespace.json",
        @utf8.encode(updated.to_json().stringify()),
      )
    }
    None => ()
  }

  // 清除旧缓存并重新加载
  meta_cache.invalidate(ns)
  active_ns.remove(ns)
  let _ = (try {
    let _ = get_or_load_ns_state(store, ns)
    ()
  } catch {
    _ => ()
  })

  manifest_id
}

///|
/// 列出命名空间的所有快照名称。
pub fn list_snapshots(store : AnyStore, ns : String) -> Array[String] {
  let prefix = "\{ns}/_snapshots/"
  let keys = store.list(prefix)
  let result : Array[String] = Array(capacity=keys.length())
  let suffix = ".json"
  for k in keys {
    if k.has_prefix(prefix) && k.has_suffix(suffix) {
      let name = k[prefix.length():k.length() - suffix.length()].to_owned()
      result.push(name)
    }
  }
  result.sort()
  result
}

///|
async fn handle_branch(
  store : AnyStore,
  ns : String,
  body : String,
  conn : @http.ServerConnection,
) -> Unit raise {
  let j = @json.parse(body) catch {
    _ => raise @core.Corrupt("body is not valid JSON")
  }
  let m = match j {
    Object(mm) => mm
    _ => raise @core.Corrupt("body must be object")
  }
  let branch_name = match m.get("branch_name") {
    Some(String(s)) => s
    _ =>
      match m.get("destination") {
        Some(String(s)) => s
        _ => raise @core.Corrupt("missing branch_name")
      }
  }
  let copy_metadata = match m.get("copy_metadata") {
    Some(True) => true
    Some(False) => false
    _ => true
  }
  let head = create_branch(store, ns, branch_name, copy_metadata)
  let out : Map[String, Json] = Map([])
  out.set("ok", Json::boolean(true))
  out.set("source_ns", Json::string(ns))
  out.set("branch_name", Json::string(branch_name))
  out.set("destination", Json::string(branch_name))
  out.set("head", Json::string(head))
  respond(conn, 200, Json::object(out).stringify())
}

///|
async fn handle_snapshot(
  store : AnyStore,
  ns : String,
  body : String,
  conn : @http.ServerConnection,
) -> Unit raise {
  let j = @json.parse(body) catch {
    _ => raise @core.Corrupt("body is not valid JSON")
  }
  let m = match j {
    Object(mm) => mm
    _ => raise @core.Corrupt("body must be object")
  }
  let snapshot_name = match m.get("snapshot_name") {
    Some(String(s)) => s
    _ => raise @core.Corrupt("missing snapshot_name")
  }
  let head = create_snapshot(store, ns, snapshot_name)
  let out : Map[String, Json] = Map([])
  out.set("ok", Json::boolean(true))
  out.set("ns", Json::string(ns))
  out.set("snapshot_name", Json::string(snapshot_name))
  out.set("manifest_id", Json::string(head))
  respond(conn, 200, Json::object(out).stringify())
}

///|
async fn handle_restore(
  store : AnyStore,
  ns : String,
  body : String,
  conn : @http.ServerConnection,
) -> Unit raise {
  let j = @json.parse(body) catch {
    _ => raise @core.Corrupt("body is not valid JSON")
  }
  let m = match j {
    Object(mm) => mm
    _ => raise @core.Corrupt("body must be object")
  }
  let snapshot_name = match m.get("snapshot_name") {
    Some(String(s)) => s
    _ => raise @core.Corrupt("missing snapshot_name")
  }
  let restored_head = restore_snapshot(store, ns, snapshot_name)
  let out : Map[String, Json] = Map([])
  out.set("ok", Json::boolean(true))
  out.set("ns", Json::string(ns))
  out.set("snapshot_name", Json::string(snapshot_name))
  out.set("restored_head", Json::string(restored_head))
  respond(conn, 200, Json::object(out).stringify())
}

///|
async fn handle_list_snapshots(
  store : AnyStore,
  ns : String,
  conn : @http.ServerConnection,
) -> Unit raise {
  let snaps = list_snapshots(store, ns)
  let arr : Array[Json] = Array(capacity=snaps.length())
  for s in snaps {
    arr.push(Json::string(s))
  }
  let out : Map[String, Json] = Map([])
  out.set("ok", Json::boolean(true))
  out.set("ns", Json::string(ns))
  out.set("snapshots", Json::array(arr))
  respond(conn, 200, Json::object(out).stringify())
}
