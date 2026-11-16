// Pluggable Metadata Catalog & Relational State Machine
//
// 提供了统一的 MetadataCatalog trait 以及两个具体实现：
// 1. S3CasCatalog[S : @store.ObjectStore]：无服务器纯 S3 CAS 实现，利用 _head_ptr、_heads/ 与不可变 Manifest
// 2. MemRdbCatalog：具有 ACID MVCC 快照隔离与事务回滚的内存关系模型状态机

///|
/// Metadata catalog 统一错误类型。
#derive(Debug, Eq)
pub(all) suberror CatalogError {
  FencingTokenMismatch(String)
  CommitConflict(String)
  NotFound(String)
  LeaseExpired(String)
  TxAborted(String)
}

///|
/// 分布式 Fencing 租约令牌。
#derive(Debug, Eq)
pub(all) struct LeaseToken {
  ns : String
  worker_id : String
  epoch : UInt64
  expires_at_ms : UInt64
}

///|
/// Pluggable Metadata Catalog 接口抽象。
pub(open) trait MetadataCatalog {
  // Namespace lifecycle
  async fn create_namespace(Self, @format.NamespaceMeta) -> Unit
  async fn get_namespace(Self, String) -> @format.NamespaceMeta?
  async fn update_head_manifest(
    Self,
    String,
    String,
    expected_head? : String,
    lease_token? : LeaseToken
  ) -> Unit

  // Distributed Fencing / Lease management
  async fn acquire_lease(Self, String, String, UInt64) -> LeaseToken?
  async fn renew_lease(Self, LeaseToken, UInt64) -> LeaseToken?
  async fn release_lease(Self, LeaseToken) -> Bool

  // Lineage & Snapshot DAG
  async fn register_snapshot(Self, String, String, String) -> Unit
  async fn resolve_snapshot(Self, String, String) -> String?
  async fn record_branch_origin(Self, String, String) -> Unit
  async fn get_lineage(Self, String) -> Array[String]

  // GC Safety Active Reference Tracking
  async fn list_active_segment_ids(Self, String) -> Set[String]
  async fn mark_segment_referenced(Self, String, String) -> Unit
  async fn get_unreferenced_segments(Self, String, UInt64) -> Array[String]
}

///|
/// 默认构造 NamespaceMeta 的辅助函数。
pub fn default_namespace_meta(
  ns_name : String,
  head_manifest? : String,
  vector_dim? : Int,
  distance_metric? : String,
  fts_tokenizer? : String
) -> @format.NamespaceMeta {
  {
    format: @core.FORMAT_NAME,
    ns_name,
    head_manifest: match head_manifest {
      Some(h) => h
      None => ""
    },
    vec_global_version: None,
    distance_metric: match distance_metric {
      Some(m) => m
      None => "cosine"
    },
    vector_dim: match vector_dim {
      Some(d) => d
      None => 128
    },
    vector_dtype: "f32",
    k1: @core.K1,
    b: @core.BM25_B,
    fts_tokenizer,
  }
}

// ----------------------------------------------------------------------
// JSON 序列化与解析辅助函数
// ----------------------------------------------------------------------

///|
fn bytes_to_json(bs : Bytes, what : String) -> Json raise CatalogError {
  let s = @utf8.decode(bs.exact_view()) catch {
    _ => raise CatalogError::NotFound("\{what} is not valid utf8")
  }
  @json.parse(s) catch {
    _ => raise CatalogError::NotFound("malformed json in \{what}")
  }
}

///|
fn lease_token_to_json(token : LeaseToken) -> String {
  let m : Map[String, Json] = Map([])
  m.set("ns", Json::string(token.ns))
  m.set("worker_id", Json::string(token.worker_id))
  m.set("epoch", Json::number(token.epoch.to_double()))
  m.set("expires_at_ms", Json::number(token.expires_at_ms.to_double()))
  Json::object(m).stringify()
}

///|
fn parse_lease_json(j : Json) -> (String, UInt64, UInt64) raise CatalogError {
  match j {
    Object(m) => {
      let worker_id = match m.get("worker_id") {
        Some(String(s)) => s
        _ => raise CatalogError::NotFound("missing worker_id in lease")
      }
      let epoch = match m.get("epoch") {
        Some(Number(n, ..)) => n.to_uint64()
        _ => 1UL
      }
      let expires_at_ms = match m.get("expires_at_ms") {
        Some(Number(n, ..)) => n.to_uint64()
        _ => 0UL
      }
      (worker_id, epoch, expires_at_ms)
    }
    _ => raise CatalogError::NotFound("expected lease json object")
  }
}

// ----------------------------------------------------------------------
// 1. S3CasCatalog: Serverless Pure S3 CAS Implementation
// ----------------------------------------------------------------------

///|
/// 基于对象存储 CAS 条件写与不可变 Head 日志的无服务目录实现。
pub struct S3CasCatalog[S] {
  store : S
  mut mock_time_ms : UInt64?
}

///|
pub fn[S] S3CasCatalog::new(store : S) -> S3CasCatalog[S] {
  { store, mock_time_ms: None }
}

///|
pub fn[S] S3CasCatalog::set_mock_time(
  self : S3CasCatalog[S],
  time_ms : UInt64?
) -> Unit {
  self.mock_time_ms = time_ms
}

///|
fn[S] S3CasCatalog::now(self : S3CasCatalog[S]) -> UInt64 {
  match self.mock_time_ms {
    Some(t) => t
    None => @env.now()
  }
}

///|
fn s3_meta_key(ns : String) -> String {
  "\{ns}/namespace.json"
}

///|
fn s3_manifest_key(ns : String, mid : String) -> String {
  "\{ns}/_manifest/\{mid}.json"
}

///|
fn s3_lease_key(ns : String) -> String {
  "\{ns}/_leases/current.json"
}

///|
fn s3_snapshot_key(ns : String, name : String) -> String {
  "\{ns}/_snapshots/\{name}.json"
}

///|
fn s3_snapshots_prefix(ns : String) -> String {
  "\{ns}/_snapshots/"
}

///|
fn s3_branch_origin_key(ns : String) -> String {
  "\{ns}/_branch_origin.json"
}

///|
fn s3_active_ref_key(ns : String, seg_id : String) -> String {
  "\{ns}/_active_refs/\{seg_id}"
}

///|
fn s3_active_refs_prefix(ns : String) -> String {
  "\{ns}/_active_refs/"
}

///|
fn s3_segments_prefix(ns : String) -> String {
  "\{ns}/_segments/"
}

///|
/// 向 S3CasCatalog 写入 Manifest 对象（用于预注册或测试）。
pub async fn[S : @store.ObjectStore] S3CasCatalog::register_manifest(
  self : S3CasCatalog[S],
  ns : String,
  manifest : @format.ManifestData
) -> Unit {
  let mkey = s3_manifest_key(ns, manifest.id)
  self.store.put(mkey, @utf8.encode(manifest.to_json().stringify()))
}

///|
/// 模拟写入段元数据对象（用于测试或双写上传）。
pub async fn[S : @store.ObjectStore] S3CasCatalog::seed_segment(
  self : S3CasCatalog[S],
  ns : String,
  seg_id : String
) -> Unit {
  let skey = "\{ns}/_segments/\{seg_id}/meta.json"
  let m : Map[String, Json] = Map([])
  m.set("id", Json::string(seg_id))
  m.set("row_count", Json::number(1.0))
  self.store.put(skey, @utf8.encode(Json::object(m).stringify()))
}

///|
impl[S : @store.ObjectStore] MetadataCatalog for S3CasCatalog[S] with create_namespace(
  self,
  meta : @format.NamespaceMeta
) -> Unit {
  let key = s3_meta_key(meta.ns_name)
  let bytes = @utf8.encode(meta.to_json().stringify())
  self.store.put(key, bytes)
  if meta.head_manifest != "" {
    @store.write_head_pointer(self.store, meta.ns_name, meta.head_manifest)
    @store.write_head(self.store, meta.ns_name, meta.head_manifest)
  }
}

///|
impl[S : @store.ObjectStore] MetadataCatalog for S3CasCatalog[S] with get_namespace(
  self,
  ns : String
) -> @format.NamespaceMeta? {
  let key = s3_meta_key(ns)
  match self.store.get(key) {
    Some(bytes) => {
      let j = bytes_to_json(bytes, "namespace.json")
      let meta = try {
        @format.namespace_from_json(j)
      } catch {
        _ => raise CatalogError::NotFound("Invalid namespace metadata format in \{ns}")
      }
      let latest_head = match @store.read_head_pointer(self.store, ns) {
        Some(ptr) => ptr
        None => meta.head_manifest
      }
      Some({ ..meta, head_manifest: latest_head })
    }
    None => None
  }
}

///|
impl[S : @store.ObjectStore] MetadataCatalog for S3CasCatalog[S] with update_head_manifest(
  self,
  ns : String,
  new_mid : String,
  expected_head? : String,
  lease_token? : LeaseToken
) -> Unit {
  let now = self.now()

  // 1. Fencing Token & Lease 校验
  let lkey = s3_lease_key(ns)
  match self.store.get(lkey) {
    Some(lbs) => {
      let lj = bytes_to_json(lbs, "lease")
      let (lease_worker, lease_epoch, lease_exp) = parse_lease_json(lj)
      if now < lease_exp {
        match lease_token {
          Some(t) => {
            if now >= t.expires_at_ms {
              raise CatalogError::FencingTokenMismatch("Lease token is expired")
            }
            if t.epoch != lease_epoch || t.worker_id != lease_worker {
              raise CatalogError::FencingTokenMismatch(
                "Fencing token epoch mismatch: current (\{lease_worker}, \{lease_epoch}), given (\{t.worker_id}, \{t.epoch})",
              )
            }
          }
          None =>
            raise CatalogError::FencingTokenMismatch(
              "Namespace \{ns} is actively leased by \{lease_worker}",
            )
        }
      } else {
        match lease_token {
          Some(t) =>
            if now >= t.expires_at_ms {
              raise CatalogError::FencingTokenMismatch("Lease token is expired")
            }
          None => ()
        }
      }
    }
    None =>
      match lease_token {
        Some(t) =>
          if now >= t.expires_at_ms {
            raise CatalogError::FencingTokenMismatch("Lease token is expired")
          }
        None => ()
      }
  }

  // 2. Dual-Write Crash Consistency / No Dangling Pointer 校验 (Safety 2)
  let mkey = s3_manifest_key(ns, new_mid)
  let mbs = match self.store.get(mkey) {
    Some(b) => b
    None => raise CatalogError::NotFound("Manifest \{new_mid} not found in store")
  }
  let mj = bytes_to_json(mbs, "manifest")
  let man = try {
    @format.manifest_from_json(mj)
  } catch {
    _ => raise CatalogError::NotFound("Corrupt manifest \{new_mid}")
  }
  for seg in man.segments {
    let seg_meta_k = "\{ns}/_segments/\{seg.id}/meta.json"
    let seg_exists = match self.store.get(seg_meta_k) {
      Some(_) => true
      None => !self.store.list("\{ns}/_segments/\{seg.id}").is_empty()
    }
    if !seg_exists {
      raise CatalogError::NotFound(
        "Dangling pointer: segment \{seg.id} not found in store for manifest \{new_mid}",
      )
    }
  }

  // 3. @store.Expected Head CAS 校验
  let cur_head = match @store.read_head_pointer(self.store, ns) {
    Some(ptr) => ptr
    None => ""
  }
  match expected_head {
    Some(exp) =>
      if exp != cur_head {
        raise CatalogError::CommitConflict(
          "CAS head mismatch: expected \{exp}, current \{cur_head}",
        )
      }
    None => ()
  }

  // 4. 原子更新 _head_ptr 与 _heads/ 日志
  let head_k = @store.head_pointer_key(ns)
  let exp_ver = if cur_head == "" {
    None
  } else {
    self.store.head_version(head_k)
  }
  let ok = self.store.put_if_match(head_k, exp_ver, @utf8.encode(new_mid))
  if !ok {
    raise CatalogError::CommitConflict(
      "CAS put_if_match failed on _head_ptr for namespace \{ns}",
    )
  }

  @store.write_head(self.store, ns, new_mid)

  // 5. 若存在 namespace.json，同步回填 head_manifest
  match self.store.get(s3_meta_key(ns)) {
    Some(nbs) => {
      let nj = bytes_to_json(nbs, "namespace.json")
      let meta = try {
        @format.namespace_from_json(nj)
      } catch {
        _ => return ()
      }
      let updated_meta = { ..meta, head_manifest: new_mid }
      self.store.put(
        s3_meta_key(ns),
        @utf8.encode(updated_meta.to_json().stringify()),
      )
    }
    None => ()
  }
}

///|
impl[S : @store.ObjectStore] MetadataCatalog for S3CasCatalog[S] with acquire_lease(
  self,
  ns : String,
  worker_id : String,
  ttl_ms : UInt64
) -> LeaseToken? {
  let now = self.now()
  let lkey = s3_lease_key(ns)
  let cur_opt = self.store.get(lkey)
  let (epoch, exp_ver) = match cur_opt {
    Some(bs) => {
      let j = bytes_to_json(bs, "lease")
      let (cur_worker, cur_epoch, cur_exp) = parse_lease_json(j)
      if now < cur_exp && cur_worker != worker_id {
        return None
      }
      (cur_epoch + 1UL, self.store.head_version(lkey))
    }
    None => (1UL, None)
  }
  let new_exp = now + ttl_ms
  let token : LeaseToken = {
    ns,
    worker_id,
    epoch,
    expires_at_ms: new_exp,
  }
  let json_str = lease_token_to_json(token)
  let ok = self.store.put_if_match(lkey, exp_ver, @utf8.encode(json_str))
  if ok {
    Some(token)
  } else {
    None
  }
}

///|
impl[S : @store.ObjectStore] MetadataCatalog for S3CasCatalog[S] with renew_lease(
  self,
  token : LeaseToken,
  ttl_ms : UInt64
) -> LeaseToken? {
  let now = self.now()
  let lkey = s3_lease_key(token.ns)
  match self.store.get(lkey) {
    Some(bs) => {
      let j = bytes_to_json(bs, "lease")
      let (cur_worker, cur_epoch, cur_exp) = parse_lease_json(j)
      if cur_epoch != token.epoch || cur_worker != token.worker_id || now > cur_exp {
        return None
      }
      let new_exp = now + ttl_ms
      let new_token : LeaseToken = { ..token, expires_at_ms: new_exp }
      let json_str = lease_token_to_json(new_token)
      let exp_ver = self.store.head_version(lkey)
      let ok = self.store.put_if_match(lkey, exp_ver, @utf8.encode(json_str))
      if ok {
        Some(new_token)
      } else {
        None
      }
    }
    None => None
  }
}

///|
impl[S : @store.ObjectStore] MetadataCatalog for S3CasCatalog[S] with release_lease(
  self,
  token : LeaseToken
) -> Bool {
  let lkey = s3_lease_key(token.ns)
  match self.store.get(lkey) {
    Some(bs) => {
      let j = bytes_to_json(bs, "lease")
      let (cur_worker, cur_epoch, _) = parse_lease_json(j)
      if cur_epoch == token.epoch && cur_worker == token.worker_id {
        self.store.delete(lkey)
        true
      } else {
        false
      }
    }
    None => false
  }
}

///|
impl[S : @store.ObjectStore] MetadataCatalog for S3CasCatalog[S] with register_snapshot(
  self,
  ns : String,
  snap_name : String,
  mid : String
) -> Unit {
  let skey = s3_snapshot_key(ns, snap_name)
  let now = self.now()
  let m : Map[String, Json] = Map([])
  m.set("name", Json::string(snap_name))
  m.set("manifest_id", Json::string(mid))
  m.set("created_at_ms", Json::number(now.to_double()))
  self.store.put(skey, @utf8.encode(Json::object(m).stringify()))
}

///|
impl[S : @store.ObjectStore] MetadataCatalog for S3CasCatalog[S] with resolve_snapshot(
  self,
  ns : String,
  snap_name : String
) -> String? {
  let skey = s3_snapshot_key(ns, snap_name)
  match self.store.get(skey) {
    Some(bs) => {
      let j = bytes_to_json(bs, "snapshot")
      match j {
        Object(m) =>
          match m.get("manifest_id") {
            Some(String(s)) => Some(s)
            _ => None
          }
        _ => None
      }
    }
    None => None
  }
}

///|
impl[S : @store.ObjectStore] MetadataCatalog for S3CasCatalog[S] with record_branch_origin(
  self,
  branch_ns : String,
  parent_ns : String
) -> Unit {
  let bkey = s3_branch_origin_key(branch_ns)
  let now = self.now()
  let m : Map[String, Json] = Map([])
  m.set("branch_ns", Json::string(branch_ns))
  m.set("parent_ns", Json::string(parent_ns))
  m.set("created_at_ms", Json::number(now.to_double()))
  self.store.put(bkey, @utf8.encode(Json::object(m).stringify()))
}

///|
impl[S : @store.ObjectStore] MetadataCatalog for S3CasCatalog[S] with get_lineage(
  self,
  ns : String
) -> Array[String] {
  let lineage : Array[String] = [ns]
  let mut cur = ns
  while true {
    let bkey = s3_branch_origin_key(cur)
    match self.store.get(bkey) {
      Some(bs) => {
        let j = bytes_to_json(bs, "branch origin")
        let parent = match j {
          Object(m) =>
            match m.get("parent_ns") {
              Some(String(p)) => p
              _ => ""
            }
          _ => ""
        }
        if parent == "" || lineage.contains(parent) {
          break
        }
        lineage.push(parent)
        cur = parent
      }
      None => break
    }
  }
  lineage
}

///|
impl[S : @store.ObjectStore] MetadataCatalog for S3CasCatalog[S] with mark_segment_referenced(
  self,
  ns : String,
  seg_id : String
) -> Unit {
  let key = s3_active_ref_key(ns, seg_id)
  let now = self.now()
  let m : Map[String, Json] = Map([])
  m.set("seg_id", Json::string(seg_id))
  m.set("timestamp_ms", Json::number(now.to_double()))
  self.store.put(key, @utf8.encode(Json::object(m).stringify()))
}

///|
impl[S : @store.ObjectStore] MetadataCatalog for S3CasCatalog[S] with list_active_segment_ids(
  self,
  ns : String
) -> Set[String] {
  let active : Set[String] = Set([])
  let lineage = MetadataCatalog::get_lineage(self, ns)
  for ancestor in lineage {
    // 1. Head Manifest 中的段
    match @store.read_head_pointer(self.store, ancestor) {
      Some(head_mid) =>
        if head_mid != "" {
          match self.store.get(s3_manifest_key(ancestor, head_mid)) {
            Some(mbs) => {
              let mj = bytes_to_json(mbs, "manifest")
              let man = try {
                @format.manifest_from_json(mj)
              } catch {
                _ => continue
              }
              for seg in man.segments {
                active.add(seg.id)
              }
            }
            None => ()
          }
        }
      None => ()
    }
    // 2. 全部快照中的段
    let snap_prefix = s3_snapshots_prefix(ancestor)
    for k in self.store.list(snap_prefix) {
      match self.store.get(k) {
        Some(sbs) => {
          let sj = bytes_to_json(sbs, "snapshot")
          let mid = match sj {
            Object(m) =>
              match m.get("manifest_id") {
                Some(String(s)) => s
                _ => ""
              }
            _ => ""
          }
          if mid != "" {
            match self.store.get(s3_manifest_key(ancestor, mid)) {
              Some(mbs) => {
                let mj = bytes_to_json(mbs, "manifest")
                let man = try {
                  @format.manifest_from_json(mj)
                } catch {
                  _ => continue
                }
                for seg in man.segments {
                  active.add(seg.id)
                }
              }
              None => ()
            }
          }
        }
        None => ()
      }
    }
  }
  active
}

///|
impl[S : @store.ObjectStore] MetadataCatalog for S3CasCatalog[S] with get_unreferenced_segments(
  self,
  ns : String,
  grace_period_ms : UInt64
) -> Array[String] {
  let now = self.now()
  let active = MetadataCatalog::list_active_segment_ids(self, ns)
  let unref : Array[String] = []

  let seg_prefix = s3_segments_prefix(ns)
  let all_segs : Set[String] = Set([])
  for k in self.store.list(seg_prefix) {
    if k.has_prefix(seg_prefix) {
      let rest = k[seg_prefix.length():].to_owned()
      let parts = rest.split("/").collect()
      if parts.length() > 0 {
        let seg_id = parts[0].to_owned()
        if seg_id != "" {
          all_segs.add(seg_id)
        }
      }
    }
  }

  let refs_prefix = s3_active_refs_prefix(ns)
  for k in self.store.list(refs_prefix) {
    if k.has_prefix(refs_prefix) {
      let seg_id = k[refs_prefix.length():].to_owned()
      if seg_id != "" {
        all_segs.add(seg_id)
      }
    }
  }

  for seg_id in all_segs {
    if !active.contains(seg_id) {
      let ref_k = s3_active_ref_key(ns, seg_id)
      let in_grace = match self.store.get(ref_k) {
        Some(bs) => {
          let j = bytes_to_json(bs, "active ref")
          let ts = match j {
            Object(m) =>
              match m.get("timestamp_ms") {
                Some(Number(n, ..)) => n.to_uint64()
                _ => 0UL
              }
            _ => 0UL
          }
          now >= ts && now - ts < grace_period_ms
        }
        None => false
      }
      if !in_grace {
        unref.push(seg_id)
      }
    }
  }
  unref
}

// ----------------------------------------------------------------------
// 2. MemRdbCatalog: Transactional Relational Model with ACID MVCC
// ----------------------------------------------------------------------

///|
#derive(Debug)
struct RdbTenant {
  ns : String
  meta : @format.NamespaceMeta
  created_at_ms : UInt64
  updated_at_ms : UInt64
  tx_id_created : UInt64
  mut tx_id_expired : UInt64
}

///|
#derive(Debug)
struct RdbLease {
  ns : String
  worker_id : String
  epoch : UInt64
  expires_at_ms : UInt64
  acquired_at_ms : UInt64
  tx_id_created : UInt64
  mut tx_id_expired : UInt64
}

///|
#derive(Debug)
struct RdbSnapshot {
  key : String
  ns : String
  name : String
  manifest_id : String
  created_at_ms : UInt64
  tx_id_created : UInt64
  mut tx_id_expired : UInt64
}

///|
#derive(Debug)
struct RdbLineage {
  branch_ns : String
  parent_ns : String
  created_at_ms : UInt64
  tx_id_created : UInt64
  mut tx_id_expired : UInt64
}

///|
#derive(Debug)
struct RdbSegmentRef {
  key : String
  ns : String
  seg_id : String
  active : Bool
  last_referenced_ms : UInt64
  tx_id_created : UInt64
  mut tx_id_expired : UInt64
}

///|
#derive(Debug)
struct RdbManifest {
  key : String
  ns : String
  manifest_id : String
  segment_ids : Array[String]
  created_at_ms : UInt64
  tx_id_created : UInt64
  mut tx_id_expired : UInt64
}

///|
enum UndoOp {
  TenantInserted(String)
  TenantExpired(String, UInt64)
  LeaseInserted(String)
  LeaseExpired(String, UInt64)
  SnapshotInserted(String)
  SnapshotExpired(String, UInt64)
  LineageInserted(String)
  LineageExpired(String, UInt64)
  SegmentRefInserted(String)
  SegmentRefExpired(String, UInt64)
  ManifestInserted(String)
  ManifestExpired(String, UInt64)
}

///|
/// 具有 ACID MVCC 快照隔离与关系表结构（tenants, leases, snapshots, segment_refs）
/// 以及写失败自动回滚的内存目录。
pub struct MemRdbCatalog {
  mut next_tx_id : UInt64
  mut active_tx_id : UInt64?
  tenants : Map[String, Array[RdbTenant]]
  leases : Map[String, Array[RdbLease]]
  snapshots : Map[String, Array[RdbSnapshot]]
  lineages : Map[String, Array[RdbLineage]]
  segment_refs : Map[String, Array[RdbSegmentRef]]
  manifests : Map[String, Array[RdbManifest]]
  undo_stack : Array[UndoOp]
  mut mock_time_ms : UInt64?
}

///|
pub fn MemRdbCatalog::new() -> MemRdbCatalog {
  {
    next_tx_id: 1UL,
    active_tx_id: None,
    tenants: Map([]),
    leases: Map([]),
    snapshots: Map([]),
    lineages: Map([]),
    segment_refs: Map([]),
    manifests: Map([]),
    undo_stack: [],
    mock_time_ms: None,
  }
}

///|
pub fn MemRdbCatalog::set_mock_time(
  self : MemRdbCatalog,
  time_ms : UInt64?
) -> Unit {
  self.mock_time_ms = time_ms
}

///|
fn MemRdbCatalog::now(self : MemRdbCatalog) -> UInt64 {
  match self.mock_time_ms {
    Some(t) => t
    None => @env.now()
  }
}

///|
fn is_mvcc_visible(
  created : UInt64,
  expired : UInt64,
  read_tx : UInt64
) -> Bool {
  created <= read_tx && (expired == 0UL || expired > read_tx)
}

///|
fn MemRdbCatalog::current_read_tx(self : MemRdbCatalog) -> UInt64 {
  match self.active_tx_id {
    Some(tx) => tx
    None => self.next_tx_id
  }
}

// ----------------------------------------------------------------------
// MemRdbCatalog 事务支持 (ACID)
// ----------------------------------------------------------------------

///|
/// 显式开启事务，返回分配的事务编号。若当前已在事务中则返回当前 tx_id。
pub fn MemRdbCatalog::begin_transaction(self : MemRdbCatalog) -> UInt64 {
  match self.active_tx_id {
    Some(tx) => tx
    None => {
      let tx = self.next_tx_id
      self.next_tx_id += 1UL
      self.active_tx_id = Some(tx)
      tx
    }
  }
}

///|
/// 提交当前事务。
pub fn MemRdbCatalog::commit_transaction(self : MemRdbCatalog) -> Unit {
  self.undo_stack.clear()
  self.active_tx_id = None
}

///|
/// 回滚当前事务，按 LIFO 顺序还原所有写操作。
pub fn MemRdbCatalog::rollback_transaction(self : MemRdbCatalog) -> Unit {
  while self.undo_stack.length() > 0 {
    let op = self.undo_stack.pop().unwrap()
    match op {
      TenantInserted(k) =>
        match self.tenants.get(k) {
          Some(arr) => {
            let _ = arr.pop()
            if arr.is_empty() {
              self.tenants.remove(k)
            }
          }
          None => ()
        }
      TenantExpired(k, prev_exp) =>
        match self.tenants.get(k) {
          Some(arr) =>
            if arr.length() > 0 {
              arr[arr.length() - 1].tx_id_expired = prev_exp
            }
          None => ()
        }
      LeaseInserted(k) =>
        match self.leases.get(k) {
          Some(arr) => {
            let _ = arr.pop()
            if arr.is_empty() {
              self.leases.remove(k)
            }
          }
          None => ()
        }
      LeaseExpired(k, prev_exp) =>
        match self.leases.get(k) {
          Some(arr) =>
            if arr.length() > 0 {
              arr[arr.length() - 1].tx_id_expired = prev_exp
            }
          None => ()
        }
      SnapshotInserted(k) =>
        match self.snapshots.get(k) {
          Some(arr) => {
            let _ = arr.pop()
            if arr.is_empty() {
              self.snapshots.remove(k)
            }
          }
          None => ()
        }
      SnapshotExpired(k, prev_exp) =>
        match self.snapshots.get(k) {
          Some(arr) =>
            if arr.length() > 0 {
              arr[arr.length() - 1].tx_id_expired = prev_exp
            }
          None => ()
        }
      LineageInserted(k) =>
        match self.lineages.get(k) {
          Some(arr) => {
            let _ = arr.pop()
            if arr.is_empty() {
              self.lineages.remove(k)
            }
          }
          None => ()
        }
      LineageExpired(k, prev_exp) =>
        match self.lineages.get(k) {
          Some(arr) =>
            if arr.length() > 0 {
              arr[arr.length() - 1].tx_id_expired = prev_exp
            }
          None => ()
        }
      SegmentRefInserted(k) =>
        match self.segment_refs.get(k) {
          Some(arr) => {
            let _ = arr.pop()
            if arr.is_empty() {
              self.segment_refs.remove(k)
            }
          }
          None => ()
        }
      SegmentRefExpired(k, prev_exp) =>
        match self.segment_refs.get(k) {
          Some(arr) =>
            if arr.length() > 0 {
              arr[arr.length() - 1].tx_id_expired = prev_exp
            }
          None => ()
        }
      ManifestInserted(k) =>
        match self.manifests.get(k) {
          Some(arr) => {
            let _ = arr.pop()
            if arr.is_empty() {
              self.manifests.remove(k)
            }
          }
          None => ()
        }
      ManifestExpired(k, prev_exp) =>
        match self.manifests.get(k) {
          Some(arr) =>
            if arr.length() > 0 {
              arr[arr.length() - 1].tx_id_expired = prev_exp
            }
          None => ()
        }
    }
  }
  self.active_tx_id = None
}

///|
/// 在事务块内运行 f，若失败自动执行回滚并重新抛出异常；若成功则自动提交。
/// 接受 async 闭包（S3 侧目录方法本身就是 async），失败自动回滚。
pub async fn[T] MemRdbCatalog::with_transaction(
  self : MemRdbCatalog,
  f : async () -> T
) -> T {
  let was_in_tx = self.active_tx_id is Some(_)
  let _ = self.begin_transaction()
  let res : Result[T, Error] = try {
    Ok(f())
  } catch {
    err => Err(err)
  }
  match res {
    Ok(v) => {
      if !was_in_tx {
        self.commit_transaction()
      }
      v
    }
    Err(err) => {
      if !was_in_tx {
        self.rollback_transaction()
      }
      raise err
    }
  }
}

// ----------------------------------------------------------------------
// MemRdbCatalog 内部行查找与写入
// ----------------------------------------------------------------------

///|
fn MemRdbCatalog::find_visible_tenant(
  self : MemRdbCatalog,
  ns : String,
  read_tx : UInt64
) -> RdbTenant? {
  match self.tenants.get(ns) {
    Some(arr) => {
      let mut i = arr.length() - 1
      while i >= 0 {
        let rec = arr[i]
        if is_mvcc_visible(rec.tx_id_created, rec.tx_id_expired, read_tx) {
          return Some(rec)
        }
        i -= 1
      }
      None
    }
    None => None
  }
}

///|
fn MemRdbCatalog::find_visible_lease(
  self : MemRdbCatalog,
  ns : String,
  read_tx : UInt64
) -> RdbLease? {
  match self.leases.get(ns) {
    Some(arr) => {
      let mut i = arr.length() - 1
      while i >= 0 {
        let rec = arr[i]
        if is_mvcc_visible(rec.tx_id_created, rec.tx_id_expired, read_tx) {
          return Some(rec)
        }
        i -= 1
      }
      None
    }
    None => None
  }
}

///|
fn MemRdbCatalog::find_visible_snapshot(
  self : MemRdbCatalog,
  key : String,
  read_tx : UInt64
) -> RdbSnapshot? {
  match self.snapshots.get(key) {
    Some(arr) => {
      let mut i = arr.length() - 1
      while i >= 0 {
        let rec = arr[i]
        if is_mvcc_visible(rec.tx_id_created, rec.tx_id_expired, read_tx) {
          return Some(rec)
        }
        i -= 1
      }
      None
    }
    None => None
  }
}

///|
fn MemRdbCatalog::find_visible_lineage(
  self : MemRdbCatalog,
  branch_ns : String,
  read_tx : UInt64
) -> RdbLineage? {
  match self.lineages.get(branch_ns) {
    Some(arr) => {
      let mut i = arr.length() - 1
      while i >= 0 {
        let rec = arr[i]
        if is_mvcc_visible(rec.tx_id_created, rec.tx_id_expired, read_tx) {
          return Some(rec)
        }
        i -= 1
      }
      None
    }
    None => None
  }
}

///|
fn MemRdbCatalog::find_visible_segment_ref(
  self : MemRdbCatalog,
  key : String,
  read_tx : UInt64
) -> RdbSegmentRef? {
  match self.segment_refs.get(key) {
    Some(arr) => {
      let mut i = arr.length() - 1
      while i >= 0 {
        let rec = arr[i]
        if is_mvcc_visible(rec.tx_id_created, rec.tx_id_expired, read_tx) {
          return Some(rec)
        }
        i -= 1
      }
      None
    }
    None => None
  }
}

///|
fn MemRdbCatalog::find_visible_manifest(
  self : MemRdbCatalog,
  key : String,
  read_tx : UInt64
) -> RdbManifest? {
  match self.manifests.get(key) {
    Some(arr) => {
      let mut i = arr.length() - 1
      while i >= 0 {
        let rec = arr[i]
        if is_mvcc_visible(rec.tx_id_created, rec.tx_id_expired, read_tx) {
          return Some(rec)
        }
        i -= 1
      }
      None
    }
    None => None
  }
}

///|
/// 注册 Manifest 所包含的 Segment ID 映射，供关系模型进行外键及活跃段追踪。
pub async fn MemRdbCatalog::register_manifest_segments(
  self : MemRdbCatalog,
  ns : String,
  manifest_id : String,
  segment_ids : Array[String]
) -> Unit {
  let _ = self.with_transaction(fn() {
    let tx = self.current_read_tx()
    let now = self.now()
    let mkey = "\{ns}/\{manifest_id}"
    match self.find_visible_manifest(mkey, tx) {
      Some(old) => {
        let prev_exp = old.tx_id_expired
        old.tx_id_expired = tx
        self.undo_stack.push(UndoOp::ManifestExpired(mkey, prev_exp))
      }
      None => ()
    }
    let rec : RdbManifest = {
      key: mkey,
      ns,
      manifest_id,
      segment_ids,
      created_at_ms: now,
      tx_id_created: tx,
      tx_id_expired: 0UL,
    }
    match self.manifests.get(mkey) {
      Some(arr) => arr.push(rec)
      None => self.manifests.set(mkey, [rec])
    }
    self.undo_stack.push(UndoOp::ManifestInserted(mkey))

    for sid in segment_ids {
      let rkey = "\{ns}/\{sid}"
      match self.find_visible_segment_ref(rkey, tx) {
        Some(old_ref) => {
          let prev_exp = old_ref.tx_id_expired
          old_ref.tx_id_expired = tx
          self.undo_stack.push(UndoOp::SegmentRefExpired(rkey, prev_exp))
        }
        None => ()
      }
      let ref_rec : RdbSegmentRef = {
        key: rkey,
        ns,
        seg_id: sid,
        active: true,
        last_referenced_ms: now,
        tx_id_created: tx,
        tx_id_expired: 0UL,
      }
      match self.segment_refs.get(rkey) {
        Some(arr) => arr.push(ref_rec)
        None => self.segment_refs.set(rkey, [ref_rec])
      }
      self.undo_stack.push(UndoOp::SegmentRefInserted(rkey))
    }
  }) catch {
    _ => ()
  }
}

///|
/// 从 ManifestData 自动提取段信息并注册到 MemRdbCatalog。
pub async fn MemRdbCatalog::register_manifest(
  self : MemRdbCatalog,
  ns : String,
  manifest : @format.ManifestData
) -> Unit {
  let seg_ids : Array[String] = []
  for seg in manifest.segments {
    seg_ids.push(seg.id)
  }
  self.register_manifest_segments(ns, manifest.id, seg_ids)
}

///|
/// MVCC 快照点查询：获取指定事务编号时刻可见的命名空间元数据。
pub fn MemRdbCatalog::get_namespace_at(
  self : MemRdbCatalog,
  ns : String,
  tx_id : UInt64
) -> @format.NamespaceMeta? {
  match self.find_visible_tenant(ns, tx_id) {
    Some(rec) => Some(rec.meta)
    None => None
  }
}

// ----------------------------------------------------------------------
// MemRdbCatalog 的 MetadataCatalog Trait 实现
// ----------------------------------------------------------------------

///|
impl MetadataCatalog for MemRdbCatalog with create_namespace(
  self,
  meta : @format.NamespaceMeta
) -> Unit {
  self.with_transaction(fn() {
    let tx = self.current_read_tx()
    let now = self.now()
    let ns = meta.ns_name
    match self.find_visible_tenant(ns, tx) {
      Some(old) => {
        let prev_exp = old.tx_id_expired
        old.tx_id_expired = tx
        self.undo_stack.push(UndoOp::TenantExpired(ns, prev_exp))
      }
      None => ()
    }
    let rec : RdbTenant = {
      ns,
      meta,
      created_at_ms: now,
      updated_at_ms: now,
      tx_id_created: tx,
      tx_id_expired: 0UL,
    }
    match self.tenants.get(ns) {
      Some(arr) => arr.push(rec)
      None => self.tenants.set(ns, [rec])
    }
    self.undo_stack.push(UndoOp::TenantInserted(ns))
  })
}

///|
impl MetadataCatalog for MemRdbCatalog with get_namespace(
  self,
  ns : String
) -> @format.NamespaceMeta? {
  let tx = self.current_read_tx()
  match self.find_visible_tenant(ns, tx) {
    Some(rec) => Some(rec.meta)
    None => None
  }
}

///|
impl MetadataCatalog for MemRdbCatalog with update_head_manifest(
  self,
  ns : String,
  new_mid : String,
  expected_head? : String,
  lease_token? : LeaseToken
) -> Unit {
  self.with_transaction(fn() raise {
    let tx = self.current_read_tx()
    let now = self.now()

    // 1. 租约与 Fencing Token 校验
    match self.find_visible_lease(ns, tx) {
      Some(rec) =>
        if now < rec.expires_at_ms {
          match lease_token {
            Some(t) => {
              if now >= t.expires_at_ms {
                raise CatalogError::FencingTokenMismatch(
                  "Lease token is expired",
                )
              }
              if t.epoch != rec.epoch || t.worker_id != rec.worker_id {
                raise CatalogError::FencingTokenMismatch(
                  "Fencing token epoch mismatch: current (\{rec.worker_id}, \{rec.epoch}), given (\{t.worker_id}, \{t.epoch})",
                )
              }
            }
            None =>
              raise CatalogError::FencingTokenMismatch(
                "Namespace \{ns} is actively leased by \{rec.worker_id}",
              )
          }
        } else {
          match lease_token {
            Some(t) =>
              if now >= t.expires_at_ms {
                raise CatalogError::FencingTokenMismatch(
                  "Lease token is expired",
                )
              }
            None => ()
          }
        }
      None =>
        match lease_token {
          Some(t) =>
            if now >= t.expires_at_ms {
              raise CatalogError::FencingTokenMismatch("Lease token is expired")
            }
          None => ()
        }
    }

    // 2. @store.Expected Head CAS 校验
    let old_tenant = match self.find_visible_tenant(ns, tx) {
      Some(rec) => rec
      None => raise CatalogError::NotFound("Namespace \{ns} not found")
    }
    match expected_head {
      Some(exp) =>
        if exp != old_tenant.meta.head_manifest {
          raise CatalogError::CommitConflict(
            "CAS head mismatch: expected \{exp}, current \{old_tenant.meta.head_manifest}",
          )
        }
      None => ()
    }

    // 3. 更新 Tenant 行
    let prev_exp = old_tenant.tx_id_expired
    old_tenant.tx_id_expired = tx
    self.undo_stack.push(UndoOp::TenantExpired(ns, prev_exp))

    let updated_meta = { ..old_tenant.meta, head_manifest: new_mid }
    let new_tenant : RdbTenant = {
      ns,
      meta: updated_meta,
      created_at_ms: old_tenant.created_at_ms,
      updated_at_ms: now,
      tx_id_created: tx,
      tx_id_expired: 0UL,
    }
    match self.tenants.get(ns) {
      Some(arr) => arr.push(new_tenant)
      None => self.tenants.set(ns, [new_tenant])
    }
    self.undo_stack.push(UndoOp::TenantInserted(ns))

    // 4. 若新 Manifest 已有段记录，同步标记活跃引用
    let mkey = "\{ns}/\{new_mid}"
    match self.find_visible_manifest(mkey, tx) {
      Some(man_rec) =>
        for sid in man_rec.segment_ids {
          let rkey = "\{ns}/\{sid}"
          match self.find_visible_segment_ref(rkey, tx) {
            Some(old_ref) => {
              let pexp = old_ref.tx_id_expired
              old_ref.tx_id_expired = tx
              self.undo_stack.push(UndoOp::SegmentRefExpired(rkey, pexp))
            }
            None => ()
          }
          let nref : RdbSegmentRef = {
            key: rkey,
            ns,
            seg_id: sid,
            active: true,
            last_referenced_ms: now,
            tx_id_created: tx,
            tx_id_expired: 0UL,
          }
          match self.segment_refs.get(rkey) {
            Some(arr) => arr.push(nref)
            None => self.segment_refs.set(rkey, [nref])
          }
          self.undo_stack.push(UndoOp::SegmentRefInserted(rkey))
        }
      None => ()
    }
  })
}

///|
impl MetadataCatalog for MemRdbCatalog with acquire_lease(
  self,
  ns : String,
  worker_id : String,
  ttl_ms : UInt64
) -> LeaseToken? {
  self.with_transaction(fn() {
    let tx = self.current_read_tx()
    let now = self.now()
    let cur_lease = self.find_visible_lease(ns, tx)
    let epoch = match cur_lease {
      Some(rec) => {
        if now < rec.expires_at_ms && rec.worker_id != worker_id {
          return None
        }
        let prev_exp = rec.tx_id_expired
        rec.tx_id_expired = tx
        self.undo_stack.push(UndoOp::LeaseExpired(ns, prev_exp))
        rec.epoch + 1UL
      }
      None => 1UL
    }
    let new_exp = now + ttl_ms
    let new_rec : RdbLease = {
      ns,
      worker_id,
      epoch,
      expires_at_ms: new_exp,
      acquired_at_ms: now,
      tx_id_created: tx,
      tx_id_expired: 0UL,
    }
    match self.leases.get(ns) {
      Some(arr) => arr.push(new_rec)
      None => self.leases.set(ns, [new_rec])
    }
    self.undo_stack.push(UndoOp::LeaseInserted(ns))

    Some({ ns, worker_id, epoch, expires_at_ms: new_exp })
  })
}

///|
impl MetadataCatalog for MemRdbCatalog with renew_lease(
  self,
  token : LeaseToken,
  ttl_ms : UInt64
) -> LeaseToken? {
  self.with_transaction(fn() {
    let tx = self.current_read_tx()
    let now = self.now()
    match self.find_visible_lease(token.ns, tx) {
      Some(rec) => {
        if rec.epoch != token.epoch ||
          rec.worker_id != token.worker_id ||
          now > rec.expires_at_ms {
          return None
        }
        let prev_exp = rec.tx_id_expired
        rec.tx_id_expired = tx
        self.undo_stack.push(UndoOp::LeaseExpired(token.ns, prev_exp))

        let new_exp = now + ttl_ms
        let renewed : RdbLease = {
          ns: token.ns,
          worker_id: token.worker_id,
          epoch: token.epoch,
          expires_at_ms: new_exp,
          acquired_at_ms: rec.acquired_at_ms,
          tx_id_created: tx,
          tx_id_expired: 0UL,
        }
        match self.leases.get(token.ns) {
          Some(arr) => arr.push(renewed)
          None => self.leases.set(token.ns, [renewed])
        }
        self.undo_stack.push(UndoOp::LeaseInserted(token.ns))

        Some({ ..token, expires_at_ms: new_exp })
      }
      None => None
    }
  })
}

///|
impl MetadataCatalog for MemRdbCatalog with release_lease(
  self,
  token : LeaseToken
) -> Bool {
  self.with_transaction(fn() {
    let tx = self.current_read_tx()
    match self.find_visible_lease(token.ns, tx) {
      Some(rec) =>
        if rec.epoch == token.epoch && rec.worker_id == token.worker_id {
          let prev_exp = rec.tx_id_expired
          rec.tx_id_expired = tx
          self.undo_stack.push(UndoOp::LeaseExpired(token.ns, prev_exp))
          true
        } else {
          false
        }
      None => false
    }
  })
}

///|
impl MetadataCatalog for MemRdbCatalog with register_snapshot(
  self,
  ns : String,
  snap_name : String,
  mid : String
) -> Unit {
  self.with_transaction(fn() {
    let tx = self.current_read_tx()
    let now = self.now()
    let skey = "\{ns}/\{snap_name}"
    match self.find_visible_snapshot(skey, tx) {
      Some(old) => {
        let prev_exp = old.tx_id_expired
        old.tx_id_expired = tx
        self.undo_stack.push(UndoOp::SnapshotExpired(skey, prev_exp))
      }
      None => ()
    }
    let rec : RdbSnapshot = {
      key: skey,
      ns,
      name: snap_name,
      manifest_id: mid,
      created_at_ms: now,
      tx_id_created: tx,
      tx_id_expired: 0UL,
    }
    match self.snapshots.get(skey) {
      Some(arr) => arr.push(rec)
      None => self.snapshots.set(skey, [rec])
    }
    self.undo_stack.push(UndoOp::SnapshotInserted(skey))
  })
}

///|
impl MetadataCatalog for MemRdbCatalog with resolve_snapshot(
  self,
  ns : String,
  snap_name : String
) -> String? {
  let tx = self.current_read_tx()
  let skey = "\{ns}/\{snap_name}"
  match self.find_visible_snapshot(skey, tx) {
    Some(rec) => Some(rec.manifest_id)
    None => None
  }
}

///|
impl MetadataCatalog for MemRdbCatalog with record_branch_origin(
  self,
  branch_ns : String,
  parent_ns : String
) -> Unit {
  self.with_transaction(fn() {
    let tx = self.current_read_tx()
    let now = self.now()
    match self.find_visible_lineage(branch_ns, tx) {
      Some(old) => {
        let prev_exp = old.tx_id_expired
        old.tx_id_expired = tx
        self.undo_stack.push(UndoOp::LineageExpired(branch_ns, prev_exp))
      }
      None => ()
    }
    let rec : RdbLineage = {
      branch_ns,
      parent_ns,
      created_at_ms: now,
      tx_id_created: tx,
      tx_id_expired: 0UL,
    }
    match self.lineages.get(branch_ns) {
      Some(arr) => arr.push(rec)
      None => self.lineages.set(branch_ns, [rec])
    }
    self.undo_stack.push(UndoOp::LineageInserted(branch_ns))
  })
}

///|
impl MetadataCatalog for MemRdbCatalog with get_lineage(
  self,
  ns : String
) -> Array[String] {
  let tx = self.current_read_tx()
  let lineage : Array[String] = [ns]
  let mut cur = ns
  while true {
    match self.find_visible_lineage(cur, tx) {
      Some(rec) => {
        let p = rec.parent_ns
        if p == "" || lineage.contains(p) {
          break
        }
        lineage.push(p)
        cur = p
      }
      None => break
    }
  }
  lineage
}

///|
impl MetadataCatalog for MemRdbCatalog with mark_segment_referenced(
  self,
  ns : String,
  seg_id : String
) -> Unit {
  self.with_transaction(fn() {
    let tx = self.current_read_tx()
    let now = self.now()
    let rkey = "\{ns}/\{seg_id}"
    match self.find_visible_segment_ref(rkey, tx) {
      Some(old) => {
        let prev_exp = old.tx_id_expired
        old.tx_id_expired = tx
        self.undo_stack.push(UndoOp::SegmentRefExpired(rkey, prev_exp))
      }
      None => ()
    }
    let rec : RdbSegmentRef = {
      key: rkey,
      ns,
      seg_id,
      active: true,
      last_referenced_ms: now,
      tx_id_created: tx,
      tx_id_expired: 0UL,
    }
    match self.segment_refs.get(rkey) {
      Some(arr) => arr.push(rec)
      None => self.segment_refs.set(rkey, [rec])
    }
    self.undo_stack.push(UndoOp::SegmentRefInserted(rkey))
  })
}

///|
impl MetadataCatalog for MemRdbCatalog with list_active_segment_ids(
  self,
  ns : String
) -> Set[String] {
  let tx = self.current_read_tx()
  let active : Set[String] = Set([])
  let lineage = MetadataCatalog::get_lineage(self, ns)

  for ancestor in lineage {
    // 1. Ancestor Head Manifest 中的段
    match self.find_visible_tenant(ancestor, tx) {
      Some(tenant) => {
        let mid = tenant.meta.head_manifest
        if mid != "" {
          let mkey = "\{ancestor}/\{mid}"
          match self.find_visible_manifest(mkey, tx) {
            Some(mrec) =>
              for sid in mrec.segment_ids {
                active.add(sid)
              }
            None => ()
          }
        }
      }
      None => ()
    }
    // 2. Ancestor 快照中的段
    for kv in self.snapshots {
      let (k, arr) = kv
      if k.has_prefix("\{ancestor}/") {
        let mut i = arr.length() - 1
        while i >= 0 {
          let srec = arr[i]
          if is_mvcc_visible(srec.tx_id_created, srec.tx_id_expired, tx) {
            let mkey = "\{ancestor}/\{srec.manifest_id}"
            match self.find_visible_manifest(mkey, tx) {
              Some(mrec) =>
                for sid in mrec.segment_ids {
                  active.add(sid)
                }
              None => ()
            }
            break
          }
          i -= 1
        }
      }
    }
  }

  active
}

///|
impl MetadataCatalog for MemRdbCatalog with get_unreferenced_segments(
  self,
  ns : String,
  grace_period_ms : UInt64
) -> Array[String] {
  let tx = self.current_read_tx()
  let now = self.now()
  let active = MetadataCatalog::list_active_segment_ids(self, ns)
  let unref : Array[String] = []

  for kv in self.segment_refs {
    let (k, arr) = kv
    if k.has_prefix("\{ns}/") {
      let mut i = arr.length() - 1
      while i >= 0 {
        let rrec = arr[i]
        if is_mvcc_visible(rrec.tx_id_created, rrec.tx_id_expired, tx) {
          if !active.contains(rrec.seg_id) {
            if now >= rrec.last_referenced_ms &&
              now - rrec.last_referenced_ms >= grace_period_ms {
              unref.push(rrec.seg_id)
            }
          }
          break
        }
        i -= 1
      }
    }
  }

  unref
}

pub extend CatalogError with Debug::{to_repr}
pub extend CatalogError with Eq::{not_equal, equal}
pub extend LeaseToken with Debug::{to_repr}
pub extend LeaseToken with Eq::{not_equal, equal}
pub extend RdbTenant with Debug::{to_repr}
pub extend RdbLease with Debug::{to_repr}
pub extend RdbSnapshot with Debug::{to_repr}
pub extend RdbLineage with Debug::{to_repr}
pub extend RdbSegmentRef with Debug::{to_repr}
pub extend RdbManifest with Debug::{to_repr}
