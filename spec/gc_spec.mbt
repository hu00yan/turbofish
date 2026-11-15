// MoonBit Formal Specification & Verification Contracts: Garbage Collection & Model Checker.
// Formalizes Safety 1 (Snapshot Reachability / GC Safety)
// and implements the 10,000-iteration Randomized State Machine Model Checker.

///|
/// Collects all reachable segments across the entire lineage DAG of active branches
/// and all registered snapshots.
pub fn collect_reachable_segments(catalog : SpecCatalog) -> Set[String] {
  let reachable : Set[String] = Set([])

  // 1. Reachable from all active branches (head manifest + full lineage history)
  for kv in catalog.branches.iter() {
    let branch = kv.1
    // Head manifest segments
    match catalog.manifests.get(branch.head_manifest_id) {
      Some(head_man) => {
        for seg in head_man.segments {
          reachable.add(seg)
        }
      }
      None => ()
    }
    // Historical lineage manifests
    for mid in branch.manifest_history {
      match catalog.manifests.get(mid) {
        Some(man) => {
          for seg in man.segments {
            reachable.add(seg)
          }
        }
        None => ()
      }
    }
  }

  // 2. Reachable from all registered snapshots
  for kv in catalog.snapshots.iter() {
    let snap = kv.1
    for seg in snap.pinned_segments {
      reachable.add(seg)
    }
    match catalog.manifests.get(snap.manifest_id) {
      Some(man) => {
        for seg in man.segments {
          reachable.add(seg)
        }
      }
      None => ()
    }
  }

  reachable
}

///|
/// Predicate identifying whether a key in ObjectStore represents a segment data payload.
#proof_pure
pub fn is_segment_key(key : String) -> Bool {
  !key.has_prefix("_manifest/")
}

///|
/// Identifies segments eligible for GC sweep:
/// A segment is unreferenced IF AND ONLY IF it is not reachable by ANY active snapshot
/// or branch lineage, and its age exceeds grace_period_ms.
pub fn gc_identify_unreferenced(
  catalog : SpecCatalog,
  store : SpecObjectStore,
  now_ms : UInt64,
  grace_period_ms : UInt64
) -> Array[String] {
  let reachable = collect_reachable_segments(catalog)
  let unreferenced : Array[String] = []

  for kv in store.objects.iter() {
    let key = kv.0
    let status = kv.1
    match status {
      SpecStoreObject::Swept => () // already swept
      _ => {
        if is_segment_key(key) {
          if !reachable.contains(key) {
            let created_at = match store.created_at_ms.get(key) {
              Some(t) => t
              None => 0UL
            }
            if now_ms >= created_at + grace_period_ms {
              unreferenced.push(key)
            }
          }
        }
      }
    }
  }
  unreferenced
}

///|
/// Executes GC sweep on ObjectStore with Safety 1 assertions.
pub fn gc_sweep(
  catalog : SpecCatalog,
  store : SpecObjectStore,
  swept_history : Set[String],
  now_ms : UInt64,
  grace_period_ms : UInt64
) -> (Int, Array[String]) {
  let unreferenced = gc_identify_unreferenced(
    catalog,
    store,
    now_ms,
    grace_period_ms,
  )
  let reachable = collect_reachable_segments(catalog)
  let swept : Array[String] = []

  for seg in unreferenced {
    // Assert Safety 1 invariant: Never sweep a reachable segment
    if reachable.contains(seg) {
      abort("Safety 1 Violation: Attempted to sweep reachable segment " + seg)
    }
    store.delete(seg)
    swept_history.add(seg)
    swept.push(seg)
  }

  (swept.length(), swept)
}

///|
/// Formally asserts Safety Invariant 1 (Snapshot Reachability / GC Safety):
/// Any segment referenced by ANY active snapshot or branch lineage
/// MUST NOT be marked unreferenced or swept by GC, and MUST be committed in ObjectStore.
pub fn verify_safety1_snapshot_gc_safety(
  catalog : SpecCatalog,
  swept_history : Set[String],
  store : SpecObjectStore
) -> Bool {
  let reachable = collect_reachable_segments(catalog)
  for seg in reachable {
    // 1. Must never have been swept by GC
    if swept_history.contains(seg) {
      return false
    }
    // 2. Must be committed in object store
    if !store.is_committed(seg) {
      return false
    }
  }
  true
}

///|
/// Fast deterministic 64-bit XorShift Pseudo-Random Number Generator.
#derive(Debug)
pub(all) struct SpecRng {
  mut state : UInt64
}

///|
pub fn SpecRng::new(seed : UInt64) -> SpecRng {
  let s = if seed == 0UL { 0x853c49e6748fea9bUL } else { seed }
  { state: s }
}

///|
pub fn SpecRng::next_u64(self : SpecRng) -> UInt64 {
  let mut x = self.state
  x = x ^ (x << 13)
  x = x ^ (x >> 7)
  x = x ^ (x << 17)
  self.state = x
  x
}

///|
pub fn SpecRng::next_int(self : SpecRng, bound : Int) -> Int {
  if bound <= 0 {
    0
  } else {
    (self.next_u64() % bound.to_uint64()).to_int()
  }
}

///|
/// Comprehensive Statistics from Randomized State Machine Model Checker.
#derive(Debug, Eq)
pub(all) struct ModelCheckerStats {
  total_steps : Int
  branches_created : Int
  docs_written : Int
  crashes_injected : Int
  snapshots_created : Int
  snapshots_deleted : Int
  snapshots_restored : Int
  leases_expired : Int
  concurrent_cas_runs : Int
  fencing_mismatches_caught : Int
  gc_sweeps_run : Int
  segments_swept : Int
  safety1_checks_passed : Int
  safety2_checks_passed : Int
  safety3_checks_passed : Int
  all_invariants_held : Bool
}

///|
/// Executes 10,000 randomized state transitions:
/// - Branch creation
/// - Doc writes with dual-write upload crash points
/// - Snapshot registration, restore, and deletion
/// - Lease acquisition, expiration, and fencing
/// - Concurrent CAS arbitration
/// - GC identification and sweeping
/// Formally asserts Safety 1, Safety 2, and Safety 3 at EVERY step.
pub fn run_randomized_state_machine_model_checker(
  steps : Int,
  seed : UInt64
) -> ModelCheckerStats {
  let rng = SpecRng::new(seed)
  let catalog = SpecCatalog::new()
  let store = SpecObjectStore::new()
  let swept_history : Set[String] = Set([])
  let mut now_ms = 1_000_000UL
  let lease_ttl = 5_000UL
  let gc_grace_ms = 10_000UL

  // Initial genesis branch
  let branches : Array[String] = ["main"]
  let _ = catalog_create_branch(
    catalog,
    "main",
    None,
    ["seg_main_genesis_1"],
    store,
    now_ms,
  )

  let snapshots : Array[String] = []

  let mut branches_created = 0
  let mut docs_written = 0
  let mut crashes_injected = 0
  let mut snapshots_created = 0
  let mut snapshots_deleted = 0
  let mut snapshots_restored = 0
  let mut leases_expired = 0
  let mut concurrent_cas_runs = 0
  let mut fencing_mismatches_caught = 0
  let mut gc_sweeps_run = 0
  let mut segments_swept = 0
  let mut safety1_checks_passed = 0
  let mut safety2_checks_passed = 0
  let mut safety3_checks_passed = 0

  let mut seg_counter = 100
  let mut man_counter = 100
  let mut snap_counter = 100

  for step in 0..<steps {
    now_ms = now_ms + 10UL
    let action = rng.next_int(8) // 0..7

    match action {
      0 => {
        // Create Branch (Zero-Copy fork)
        if branches.length() < 12 {
          let origin_idx = rng.next_int(branches.length())
          let origin_name = branches[origin_idx]
          let new_branch_name = "br_\{step}_\{rng.next_int(1000)}"
          match catalog_create_branch(catalog, new_branch_name, Some(origin_name), [], store, now_ms) {
            Some(_) => {
              branches.push(new_branch_name)
              branches_created = branches_created + 1
            }
            None => ()
          }
        }
      }

      1 => {
        // Write Doc with Dual-Write Protocol & Crash Injection
        let b_idx = rng.next_int(branches.length())
        let b_name = branches[b_idx]
        let worker_id = "worker_\{rng.next_int(5)}"

        // Acquire or use lease
        let token_opt = match catalog_acquire_lease(catalog, b_name, worker_id, now_ms, lease_ttl) {
          Some(t) => Some(t)
          None => catalog.leases.get(b_name)
        }

        match token_opt {
          Some(token) => {
            seg_counter = seg_counter + 1
            man_counter = man_counter + 1
            let seg_id = "seg_\{b_name}_\{seg_counter}"
            let man_id = "man_\{b_name}_\{man_counter}"

            // Random crash point
            let crash_dice = rng.next_int(100)
            let crash_stage = if crash_dice < 55 {
              CrashStage::NoCrash
            } else if crash_dice < 64 {
              CrashStage::CrashBeforeSegmentUpload
            } else if crash_dice < 73 {
              CrashStage::CrashDuringSegmentUpload
            } else if crash_dice < 82 {
              CrashStage::CrashAfterSegmentUpload
            } else if crash_dice < 91 {
              CrashStage::CrashAfterManifestUpload
            } else {
              CrashStage::CrashDuringCasCommit
            }

            if crash_stage != CrashStage::NoCrash {
              crashes_injected = crashes_injected + 1
            }

            let outcome = execute_dual_write(
              catalog,
              store,
              b_name,
              token,
              seg_id,
              man_id,
              crash_stage,
              now_ms,
            )

            match outcome {
              CommitOutcome::CommitOk(_) => {
                docs_written = docs_written + 1
              }
              CommitOutcome::CommitRejected(err) => {
                match err {
                  CommitError::FencingViolation(_) =>
                    fencing_mismatches_caught = fencing_mismatches_caught + 1
                  _ => ()
                }
              }
            }
          }
          None => ()
        }
      }

      2 => {
        // Create Snapshot
        let b_idx = rng.next_int(branches.length())
        let b_name = branches[b_idx]
        snap_counter = snap_counter + 1
        let snap_name = "snap_\{snap_counter}"
        match catalog_create_snapshot(catalog, snap_name, b_name, now_ms) {
          Some(_) => {
            snapshots.push(snap_name)
            snapshots_created = snapshots_created + 1
          }
          None => ()
        }
      }

      3 => {
        // Delete Snapshot
        if snapshots.length() > 3 {
          let s_idx = rng.next_int(snapshots.length())
          let s_name = snapshots[s_idx]
          if catalog_delete_snapshot(catalog, s_name) {
            let _ = snapshots.remove(s_idx)
            snapshots_deleted = snapshots_deleted + 1
          }
        }
      }

      4 => {
        // Restore Snapshot
        if snapshots.length() > 0 {
          let s_idx = rng.next_int(snapshots.length())
          let s_name = snapshots[s_idx]
          let snap = catalog.snapshots.get(s_name).unwrap()
          let b_name = snap.branch_name
          let worker_id = "restorer_1"
          match catalog_acquire_lease(catalog, b_name, worker_id, now_ms, lease_ttl) {
            Some(token) => {
              let outcome = catalog_restore_snapshot(
                catalog,
                store,
                b_name,
                s_name,
                token,
                now_ms,
              )
              match outcome {
                CommitOutcome::CommitOk(_) => snapshots_restored = snapshots_restored + 1
                _ => ()
              }
            }
            None => ()
          }
        }
      }

      5 => {
        // Lease Expiration
        now_ms = now_ms + lease_ttl + 500UL
        leases_expired = leases_expired + 1
      }

      6 => {
        // Concurrent CAS & Fencing Token Arbitration
        concurrent_cas_runs = concurrent_cas_runs + 1
        let b_idx = rng.next_int(branches.length())
        let b_name = branches[b_idx]

        // Worker 1 acquires legitimate lease
        match catalog_acquire_lease(catalog, b_name, "cas_worker_1", now_ms, lease_ttl) {
          Some(token1) => {
            let branch = catalog.branches.get(b_name).unwrap()
            let prev_man = catalog.manifests.get(branch.head_manifest_id).unwrap()

            // Worker 2 attempts rogue commit with forged/stale token
            let stale_token : LeaseToken = {
              token_id: token1.token_id - 1UL,
              holder: "rogue_worker_2",
              branch: b_name,
              expires_at_ms: now_ms + lease_ttl,
            }
            let rogue_man : SpecManifest = {
              id: "man_rogue_\{man_counter}",
              seq: branch.head_seq + 1UL,
              segments: prev_man.segments.copy(),
              parent_id: Some(branch.head_manifest_id),
              created_at_ms: now_ms,
            }
            store.put("_manifest/\{rogue_man.id}.json", 256, now_ms)
            let rogue_outcome = catalog_commit_head(
              catalog,
              store,
              b_name,
              stale_token,
              branch.head_seq,
              rogue_man,
              now_ms,
            )
            // Safety 3 Assertion: Rogue commit MUST be rejected
            match rogue_outcome {
              CommitOutcome::CommitRejected(CommitError::FencingViolation(_)) =>
                fencing_mismatches_caught = fencing_mismatches_caught + 1
              _ => abort("Safety 3 Violation: Stale token CAS unexpectedly succeeded!")
            }

            // Legitimate Worker 1 commits successfully
            man_counter = man_counter + 1
            let valid_man : SpecManifest = {
              id: "man_valid_\{man_counter}",
              seq: branch.head_seq + 1UL,
              segments: prev_man.segments.copy(),
              parent_id: Some(branch.head_manifest_id),
              created_at_ms: now_ms,
            }
            store.put("_manifest/\{valid_man.id}.json", 256, now_ms)
            let valid_outcome = catalog_commit_head(
              catalog,
              store,
              b_name,
              token1,
              branch.head_seq,
              valid_man,
              now_ms,
            )
            match valid_outcome {
              CommitOutcome::CommitOk(_) => ()
              _ => abort("Legitimate CAS failed!")
            }
          }
          None => ()
        }
      }

      _ => {
        // GC Sweep
        now_ms = now_ms + gc_grace_ms + 100UL
        let (n_swept, _) = gc_sweep(
          catalog,
          store,
          swept_history,
          now_ms,
          gc_grace_ms,
        )
        gc_sweeps_run = gc_sweeps_run + 1
        segments_swept = segments_swept + n_swept
      }
    }

    // CONTINUOUS FORMAL INVARIANT VERIFICATION AT EVERY SINGLE STEP
    // Safety 1: Snapshot Reachability / GC Safety
    if !verify_safety1_snapshot_gc_safety(catalog, swept_history, store) {
      abort("Safety 1 Violation: Active snapshot or branch segment swept/missing!")
    }
    safety1_checks_passed = safety1_checks_passed + 1

    // Safety 2: Dual-Write Crash Consistency / No Dangling Pointer
    if !verify_safety2_dual_write_consistency(catalog, store) {
      abort("Safety 2 Violation: Dangling pointer in catalog head or snapshot!")
    }
    safety2_checks_passed = safety2_checks_passed + 1

    // Safety 3: Linearizable CAS & Lease Fencing
    if !verify_safety3_lease_fencing(catalog) {
      abort("Safety 3 Violation: Lease fencing invariant broken!")
    }
    safety3_checks_passed = safety3_checks_passed + 1
  }

  {
    total_steps: steps,
    branches_created,
    docs_written,
    crashes_injected,
    snapshots_created,
    snapshots_deleted,
    snapshots_restored,
    leases_expired,
    concurrent_cas_runs,
    fencing_mismatches_caught,
    gc_sweeps_run,
    segments_swept,
    safety1_checks_passed,
    safety2_checks_passed,
    safety3_checks_passed,
    all_invariants_held: true,
  }
}
