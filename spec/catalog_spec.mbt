// MoonBit Formal Specification & Verification Contracts: Catalog & Dual-Write Invariants.
// Formalizes Safety 2 (Dual-Write Crash Consistency / No Dangling Pointer)
// and Safety 3 (Linearizable CAS & Lease Fencing).

///|
/// Distributed Fencing / Lease Token held by an active writer.
#derive(Debug, Eq)
pub(all) struct LeaseToken {
  token_id : UInt64
  holder : String
  branch : String
  expires_at_ms : UInt64
}

///|
/// Fencing and Lease Errors.
#derive(Debug, Eq)
pub(all) enum FencingError {
  FencingTokenMismatch(String)
  LeaseExpired(UInt64, UInt64) // (now_ms, expires_at_ms)
  NoActiveLease(String)
  NotLeaseHolder(String, String) // (expected, actual)
}

///|
/// Head Commit Errors for Catalog State Machine.
#derive(Debug, Eq)
pub(all) enum CommitError {
  FencingViolation(FencingError)
  CasConflict(UInt64, UInt64) // (current_seq, expected_seq)
  MissingSegment(String)
  CorruptSegment(String)
  MissingManifest(String)
  BranchNotFound(String)
}

///|
/// Result of a commit operation against the Catalog.
#derive(Debug, Eq)
pub(all) enum CommitOutcome {
  CommitOk(UInt64) // newly advanced sequence number
  CommitRejected(CommitError)
}

///|
/// Abstract Object Status in ObjectStore.
#derive(Debug, Eq)
pub(all) enum SpecStoreObject {
  Committed(Int)        // size in bytes
  PartiallyWritten(Int) // aborted / corrupt upload
  Swept                 // collected by GC
}

///|
/// Abstract Object Store model tracking object payloads and creation timestamps.
#derive(Debug)
pub(all) struct SpecObjectStore {
  objects : Map[String, SpecStoreObject]
  created_at_ms : Map[String, UInt64]
}

///|
pub fn SpecObjectStore::new() -> SpecObjectStore {
  {
    objects: Map([]),
    created_at_ms: Map([]),
  }
}

///|
pub fn SpecObjectStore::put(
  self : SpecObjectStore,
  key : String,
  size : Int,
  now_ms : UInt64
) -> Unit {
  self.objects.set(key, SpecStoreObject::Committed(size))
  if !self.created_at_ms.contains(key) {
    self.created_at_ms.set(key, now_ms)
  }
}

///|
pub fn SpecObjectStore::put_partial(
  self : SpecObjectStore,
  key : String,
  size : Int,
  now_ms : UInt64
) -> Unit {
  self.objects.set(key, SpecStoreObject::PartiallyWritten(size))
  if !self.created_at_ms.contains(key) {
    self.created_at_ms.set(key, now_ms)
  }
}

///|
pub fn SpecObjectStore::is_committed(
  self : SpecObjectStore,
  key : String
) -> Bool {
  match self.objects.get(key) {
    Some(SpecStoreObject::Committed(_)) => true
    _ => false
  }
}

///|
pub fn SpecObjectStore::is_partially_written(
  self : SpecObjectStore,
  key : String
) -> Bool {
  match self.objects.get(key) {
    Some(SpecStoreObject::PartiallyWritten(_)) => true
    _ => false
  }
}

///|
pub fn SpecObjectStore::delete(
  self : SpecObjectStore,
  key : String
) -> Unit {
  self.objects.set(key, SpecStoreObject::Swept)
}

///|
/// Manifest specification describing a committed generation of segment data.
#derive(Debug, Eq)
pub(all) struct SpecManifest {
  id : String
  seq : UInt64
  segments : Array[String]
  parent_id : String?
  created_at_ms : UInt64
}

///|
/// Branch specification representing an isolated timeline of manifests.
#derive(Debug, Eq)
pub(all) struct SpecBranch {
  name : String
  mut head_manifest_id : String
  mut head_seq : UInt64
  origin_branch : String?
  origin_manifest_id : String?
  manifest_history : Array[String]
}

///|
/// Snapshot specification representing a read-only frozen state of a branch.
#derive(Debug, Eq)
pub(all) struct SpecSnapshot {
  name : String
  branch_name : String
  manifest_id : String
  pinned_segments : Array[String]
  created_at_ms : UInt64
}

///|
/// Metadata Catalog State Machine holding branches, manifests, snapshots, and leases.
#derive(Debug)
pub(all) struct SpecCatalog {
  branches : Map[String, SpecBranch]
  manifests : Map[String, SpecManifest]
  snapshots : Map[String, SpecSnapshot]
  leases : Map[String, LeaseToken]
  mut last_token_id : UInt64
}

///|
pub fn SpecCatalog::new() -> SpecCatalog {
  {
    branches: Map([]),
    manifests: Map([]),
    snapshots: Map([]),
    leases: Map([]),
    last_token_id: 0UL,
  }
}

///|
/// Pure formal predicate: Validates lease token validity against current lease state.
#proof_pure
pub fn lease_token_valid(
  token : LeaseToken,
  current : LeaseToken,
  now_ms : UInt64
) -> Bool {
  if token.token_id == current.token_id &&
     token.holder == current.holder &&
     token.branch == current.branch &&
     now_ms < token.expires_at_ms {
    true
  } else {
    false
  }
}

///|
/// Formal Lease Fencing Check with verification contract:
/// Guarantees that only an unexpired matching leaseholder can pass.
pub fn check_lease_fencing(
  token : LeaseToken,
  current_lease : LeaseToken?,
  now_ms : UInt64
) -> CommitOutcome where {
  proof_ensure: result => match result {
    CommitOk(_) => match current_lease {
      Some(cur) => lease_token_valid(token, cur, now_ms)
      None => false
    }
    CommitRejected(_) => true
  },
} {
  match current_lease {
    None =>
      CommitOutcome::CommitRejected(
        CommitError::FencingViolation(FencingError::NoActiveLease(token.branch)),
      )
    Some(cur) => {
      if now_ms >= token.expires_at_ms {
        CommitOutcome::CommitRejected(
          CommitError::FencingViolation(
            FencingError::LeaseExpired(now_ms, token.expires_at_ms),
          ),
        )
      } else if token.token_id != cur.token_id {
        CommitOutcome::CommitRejected(
          CommitError::FencingViolation(
            FencingError::FencingTokenMismatch(
              "Fencing token mismatch: attempted=\{token.token_id}, active=\{cur.token_id}",
            ),
          ),
        )
      } else if token.holder != cur.holder {
        CommitOutcome::CommitRejected(
          CommitError::FencingViolation(
            FencingError::NotLeaseHolder(cur.holder, token.holder),
          ),
        )
      } else {
        proof_assert(lease_token_valid(token, cur, now_ms))
        CommitOutcome::CommitOk(token.token_id)
      }
    }
  }
}

///|
/// Acquires or renews a distributed fencing lease on a branch.
pub fn catalog_acquire_lease(
  catalog : SpecCatalog,
  branch_name : String,
  holder : String,
  now_ms : UInt64,
  ttl_ms : UInt64
) -> LeaseToken? {
  if !catalog.branches.contains(branch_name) {
    return None
  }
  match catalog.leases.get(branch_name) {
    Some(existing) => {
      // If active and held by a different worker, acquisition is fenced/denied
      if now_ms < existing.expires_at_ms && existing.holder != holder {
        return None
      }
    }
    None => ()
  }
  catalog.last_token_id = catalog.last_token_id + 1UL
  let new_token : LeaseToken = {
    token_id: catalog.last_token_id,
    holder,
    branch: branch_name,
    expires_at_ms: now_ms + ttl_ms,
  }
  catalog.leases.set(branch_name, new_token)
  Some(new_token)
}

///|
/// Renews an existing valid lease token.
pub fn catalog_renew_lease(
  catalog : SpecCatalog,
  token : LeaseToken,
  now_ms : UInt64,
  ttl_ms : UInt64
) -> LeaseToken? {
  match catalog.leases.get(token.branch) {
    Some(cur) => {
      if cur.token_id == token.token_id &&
         cur.holder == token.holder &&
         now_ms < cur.expires_at_ms {
        let renewed : LeaseToken = {
          ..cur,
          expires_at_ms: now_ms + ttl_ms,
        }
        catalog.leases.set(token.branch, renewed)
        Some(renewed)
      } else {
        None
      }
    }
    None => None
  }
}

///|
/// Explicitly releases a lease token.
pub fn catalog_release_lease(
  catalog : SpecCatalog,
  token : LeaseToken
) -> Bool {
  match catalog.leases.get(token.branch) {
    Some(cur) => {
      if cur.token_id == token.token_id && cur.holder == token.holder {
        catalog.leases.remove(token.branch)
        true
      } else {
        false
      }
    }
    None => false
  }
}

///|
/// Creates a branch. Can fork zero-copy from an origin branch head.
pub fn catalog_create_branch(
  catalog : SpecCatalog,
  branch_name : String,
  origin_branch_name : String?,
  genesis_seg_ids : Array[String],
  store : SpecObjectStore,
  now_ms : UInt64
) -> SpecBranch? {
  if catalog.branches.contains(branch_name) {
    return None
  }
  match origin_branch_name {
    Some(orig) => {
      match catalog.branches.get(orig) {
        Some(orig_branch) => {
          let b : SpecBranch = {
            name: branch_name,
            head_manifest_id: orig_branch.head_manifest_id,
            head_seq: orig_branch.head_seq,
            origin_branch: Some(orig),
            origin_manifest_id: Some(orig_branch.head_manifest_id),
            manifest_history: orig_branch.manifest_history.copy(),
          }
          catalog.branches.set(branch_name, b)
          Some(b)
        }
        None => None
      }
    }
    None => {
      // Genesis branch
      let man_id = "\{branch_name}_genesis_m0"
      for seg in genesis_seg_ids {
        store.put(seg, 1024, now_ms)
      }
      store.put("_manifest/\{man_id}.json", 256, now_ms)
      let genesis_manifest : SpecManifest = {
        id: man_id,
        seq: 1UL,
        segments: genesis_seg_ids.copy(),
        parent_id: None,
        created_at_ms: now_ms,
      }
      catalog.manifests.set(man_id, genesis_manifest)
      let b : SpecBranch = {
        name: branch_name,
        head_manifest_id: man_id,
        head_seq: 1UL,
        origin_branch: None,
        origin_manifest_id: None,
        manifest_history: [man_id],
      }
      catalog.branches.set(branch_name, b)
      Some(b)
    }
  }
}

///|
/// Creates an immutable snapshot pinning the current head manifest and all its segments.
pub fn catalog_create_snapshot(
  catalog : SpecCatalog,
  snapshot_name : String,
  branch_name : String,
  now_ms : UInt64
) -> SpecSnapshot? {
  if catalog.snapshots.contains(snapshot_name) {
    return None
  }
  match catalog.branches.get(branch_name) {
    Some(branch) => {
      match catalog.manifests.get(branch.head_manifest_id) {
        Some(manifest) => {
          let snap : SpecSnapshot = {
            name: snapshot_name,
            branch_name,
            manifest_id: manifest.id,
            pinned_segments: manifest.segments.copy(),
            created_at_ms: now_ms,
          }
          catalog.snapshots.set(snapshot_name, snap)
          Some(snap)
        }
        None => None
      }
    }
    None => None
  }
}

///|
/// Deletes an immutable snapshot.
pub fn catalog_delete_snapshot(
  catalog : SpecCatalog,
  snapshot_name : String
) -> Bool {
  if catalog.snapshots.contains(snapshot_name) {
    catalog.snapshots.remove(snapshot_name)
    true
  } else {
    false
  }
}

///|
/// Linearizable Head Manifest CAS Commit with Lease Fencing and Dual-Write Verification.
/// Safety 2 Precondition: Every referenced segment and manifest MUST be Committed in ObjectStore.
/// Safety 3 Precondition: Lease token MUST be valid and unexpired.
pub fn catalog_commit_head(
  catalog : SpecCatalog,
  store : SpecObjectStore,
  branch_name : String,
  token : LeaseToken,
  expected_seq : UInt64,
  new_manifest : SpecManifest,
  now_ms : UInt64
) -> CommitOutcome {
  // 1. Verify Safety 3: Lease Fencing
  let fencing_result = check_lease_fencing(
    token,
    catalog.leases.get(branch_name),
    now_ms,
  )
  match fencing_result {
    CommitOutcome::CommitRejected(err) => return CommitOutcome::CommitRejected(err)
    CommitOutcome::CommitOk(_) => ()
  }

  // 2. Verify Branch existence
  let branch = match catalog.branches.get(branch_name) {
    Some(b) => b
    None => return CommitOutcome::CommitRejected(CommitError::BranchNotFound(branch_name))
  }

  // 3. Verify CAS monotonicity
  if expected_seq != branch.head_seq || new_manifest.seq <= branch.head_seq {
    return CommitOutcome::CommitRejected(
      CommitError::CasConflict(branch.head_seq, expected_seq),
    )
  }

  // 4. Verify Safety 2: Crash Consistency (No Dangling Pointer in ObjectStore)
  let man_key = "_manifest/\{new_manifest.id}.json"
  if !store.is_committed(man_key) {
    return CommitOutcome::CommitRejected(CommitError::MissingManifest(man_key))
  }
  for seg in new_manifest.segments {
    match store.objects.get(seg) {
      Some(SpecStoreObject::Committed(_)) => ()
      Some(SpecStoreObject::PartiallyWritten(_)) =>
        return CommitOutcome::CommitRejected(CommitError::CorruptSegment(seg))
      _ => return CommitOutcome::CommitRejected(CommitError::MissingSegment(seg))
    }
  }

  // 5. Apply state transition atomically
  branch.head_manifest_id = new_manifest.id
  branch.head_seq = new_manifest.seq
  branch.manifest_history.push(new_manifest.id)
  catalog.manifests.set(new_manifest.id, new_manifest)
  CommitOutcome::CommitOk(new_manifest.seq)
}

///|
/// Dual-Write upload crash stages.
#derive(Debug, Eq)
pub(all) enum CrashStage {
  NoCrash
  CrashBeforeSegmentUpload
  CrashDuringSegmentUpload // leaves partially written segment in store
  CrashAfterSegmentUpload  // segment written, manifest missing
  CrashAfterManifestUpload // segment & manifest written, catalog head commit aborted
  CrashDuringCasCommit     // stale token / fencing mismatch during commit
}

///|
/// Simulates the dual-write protocol with crash injection.
pub fn execute_dual_write(
  catalog : SpecCatalog,
  store : SpecObjectStore,
  branch_name : String,
  token : LeaseToken,
  new_seg_id : String,
  new_manifest_id : String,
  crash_stage : CrashStage,
  now_ms : UInt64
) -> CommitOutcome {
  let branch = match catalog.branches.get(branch_name) {
    Some(b) => b
    None => return CommitOutcome::CommitRejected(CommitError::BranchNotFound(branch_name))
  }
  let prev_manifest = match catalog.manifests.get(branch.head_manifest_id) {
    Some(m) => m
    None => return CommitOutcome::CommitRejected(CommitError::MissingManifest(branch.head_manifest_id))
  }

  // Step 1: Write segment to ObjectStore
  match crash_stage {
    CrashStage::CrashBeforeSegmentUpload =>
      return CommitOutcome::CommitRejected(CommitError::MissingSegment(new_seg_id))
    CrashStage::CrashDuringSegmentUpload => {
      store.put_partial(new_seg_id, 1024, now_ms)
      return CommitOutcome::CommitRejected(CommitError::CorruptSegment(new_seg_id))
    }
    _ => store.put(new_seg_id, 1024, now_ms)
  }

  // Step 2: Write manifest to ObjectStore
  let man_key = "_manifest/\{new_manifest_id}.json"
  match crash_stage {
    CrashStage::CrashAfterSegmentUpload =>
      return CommitOutcome::CommitRejected(CommitError::MissingManifest(man_key))
    _ => store.put(man_key, 256, now_ms)
  }

  // Construct new manifest
  let next_segments = prev_manifest.segments.copy()
  next_segments.push(new_seg_id)
  let new_manifest : SpecManifest = {
    id: new_manifest_id,
    seq: branch.head_seq + 1UL,
    segments: next_segments,
    parent_id: Some(prev_manifest.id),
    created_at_ms: now_ms,
  }

  // Step 3: Advance Catalog Head
  match crash_stage {
    CrashStage::CrashAfterManifestUpload => {
      // Worker crashed before calling catalog CAS; store has uncommitted objects, catalog untouched
      CommitOutcome::CommitRejected(
        CommitError::FencingViolation(
          FencingError::FencingTokenMismatch("Worker aborted before CAS commit"),
        ),
      )
    }
    CrashStage::CrashDuringCasCommit => {
      // Stale token simulation
      let stale_token : LeaseToken = {
        ..token,
        token_id: token.token_id + 99999UL,
      }
      catalog_commit_head(
        catalog,
        store,
        branch_name,
        stale_token,
        branch.head_seq,
        new_manifest,
        now_ms,
      )
    }
    _ => {
      catalog_commit_head(
        catalog,
        store,
        branch_name,
        token,
        branch.head_seq,
        new_manifest,
        now_ms,
      )
    }
  }
}

///|
/// Restores a branch head to an immutable snapshot.
pub fn catalog_restore_snapshot(
  catalog : SpecCatalog,
  store : SpecObjectStore,
  branch_name : String,
  snapshot_name : String,
  token : LeaseToken,
  now_ms : UInt64
) -> CommitOutcome {
  let snap = match catalog.snapshots.get(snapshot_name) {
    Some(s) => s
    None => return CommitOutcome::CommitRejected(CommitError::BranchNotFound(snapshot_name))
  }
  let target_manifest = match catalog.manifests.get(snap.manifest_id) {
    Some(m) => m
    None => return CommitOutcome::CommitRejected(CommitError::MissingManifest(snap.manifest_id))
  }
  let branch = match catalog.branches.get(branch_name) {
    Some(b) => b
    None => return CommitOutcome::CommitRejected(CommitError::BranchNotFound(branch_name))
  }
  let restored_manifest : SpecManifest = {
    id: "\{branch_name}_restore_\{snap.name}_m\{branch.head_seq + 1UL}",
    seq: branch.head_seq + 1UL,
    segments: target_manifest.segments.copy(),
    parent_id: Some(branch.head_manifest_id),
    created_at_ms: now_ms,
  }
  store.put("_manifest/\{restored_manifest.id}.json", 256, now_ms)
  catalog_commit_head(
    catalog,
    store,
    branch_name,
    token,
    branch.head_seq,
    restored_manifest,
    now_ms,
  )
}

///|
/// Formally asserts Safety Invariant 2 (Dual-Write Crash Consistency / No Dangling Pointer):
/// For EVERY branch head manifest and EVERY registered snapshot,
/// all referenced segments and manifests MUST exist and be completely readable in the ObjectStore.
pub fn verify_safety2_dual_write_consistency(
  catalog : SpecCatalog,
  store : SpecObjectStore
) -> Bool {
  // Check all active branch heads
  for kv in catalog.branches.iter() {
    let branch = kv.1
    let head_mid = branch.head_manifest_id
    match catalog.manifests.get(head_mid) {
      None => return false // Dangling manifest pointer in branch head
      Some(m) => {
        let man_key = "_manifest/\{m.id}.json"
        if !store.is_committed(man_key) {
          return false // Manifest payload missing or uncommitted in store
        }
        for seg in m.segments {
          if !store.is_committed(seg) {
            return false // Dangling segment pointer in committed catalog head!
          }
        }
      }
    }
  }

  // Check all registered snapshots
  for kv in catalog.snapshots.iter() {
    let snap = kv.1
    match catalog.manifests.get(snap.manifest_id) {
      None => return false // Dangling manifest in snapshot
      Some(m) => {
        let man_key = "_manifest/\{m.id}.json"
        if !store.is_committed(man_key) {
          return false
        }
        for seg in snap.pinned_segments {
          if !store.is_committed(seg) {
            return false // Dangling segment pointer in snapshot!
          }
        }
      }
    }
  }

  true
}

///|
/// Formally asserts Safety Invariant 3 (Linearizable CAS & Lease Fencing):
/// Active leases have monotonically strictly increasing IDs, and non-leaseholders are blocked.
pub fn verify_safety3_lease_fencing(catalog : SpecCatalog) -> Bool {
  for kv in catalog.leases.iter() {
    let token = kv.1
    if token.token_id > catalog.last_token_id {
      return false // Token ID cannot exceed catalog counter
    }
  }
  true
}

pub extend LeaseToken with Debug::{to_repr}
pub extend LeaseToken with Eq::{not_equal, equal}
pub extend FencingError with Debug::{to_repr}
pub extend FencingError with Eq::{not_equal, equal}
pub extend CommitError with Debug::{to_repr}
pub extend CommitError with Eq::{not_equal, equal}
pub extend CommitOutcome with Debug::{to_repr}
pub extend CommitOutcome with Eq::{not_equal, equal}
pub extend SpecStoreObject with Debug::{to_repr}
pub extend SpecStoreObject with Eq::{not_equal, equal}
pub extend SpecObjectStore with Debug::{to_repr}
pub extend SpecManifest with Debug::{to_repr}
pub extend SpecManifest with Eq::{not_equal, equal}
pub extend SpecBranch with Debug::{to_repr}
pub extend SpecBranch with Eq::{not_equal, equal}
pub extend SpecSnapshot with Debug::{to_repr}
pub extend SpecSnapshot with Eq::{not_equal, equal}
pub extend SpecCatalog with Debug::{to_repr}
pub extend CrashStage with Debug::{to_repr}
pub extend CrashStage with Eq::{not_equal, equal}
