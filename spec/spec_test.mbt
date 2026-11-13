// Comprehensive Property & Invariant Verification Test Suite.

///|
test "formal spec: cas head monotonicity and atomicity" {
  let s0 : @spec.CasState = { seq: 1UL, manifest_key: "ns/manifest_v1.json", epoch: 1UL }

  // 1. Monotonic transition succeeds
  let outcome1 = @spec.cas_arbitrate(s0, 1UL, 2UL, "ns/manifest_v2.json")
  match outcome1 {
    @spec.CasOutcome::Success(s1) => {
      assert_eq(s1.seq, 2UL)
      assert_eq(s1.manifest_key, "ns/manifest_v2.json")
      assert_eq(s1.epoch, 2UL)

      // 2. Concurrent worker with stale expected_ver (1UL) conflicts against s1 (seq 2UL)
      let outcome_stale = @spec.cas_arbitrate(s1, 1UL, 3UL, "ns/manifest_v3_stale.json")
      match outcome_stale {
        @spec.CasOutcome::Conflict(cur, attempted) => {
          assert_eq(cur, 2UL)
          assert_eq(attempted, 1UL)
        }
        @spec.CasOutcome::Success(_) => fail("Split-brain! Stale expected_ver succeeded.")
      }

      // 3. Monotonic non-increasing next_ver rejected
      let outcome_regress = @spec.cas_arbitrate(s1, 2UL, 2UL, "ns/manifest_v2_same.json")
      match outcome_regress {
        @spec.CasOutcome::Conflict(cur, attempted) => {
          assert_eq(cur, 2UL)
          assert_eq(attempted, 2UL)
        }
        @spec.CasOutcome::Success(_) => fail("Non-increasing seq succeeded.")
      }
    }
    @spec.CasOutcome::Conflict(_, _) => fail("Valid initial CAS failed.")
  }

  // 4. Verify chain monotonicity
  let chain : Array[(UInt64, String)] = [
    (2UL, "k2"),
    (5UL, "k5"),
    (10UL, "k10"),
    (100UL, "k100"),
  ]
  assert_eq(@spec.verify_cas_monotonicity(s0, chain), true)
}

///|
test "formal spec: mergetree live doc preservation under soft deletion and compaction" {
  let p1 : @spec.SpecPart = {
    part_id: "part_base_1",
    level: 1,
    ids: [10UL, 20UL, 30UL, 40UL],
    min_id: 10UL,
    max_id: 40UL,
  }
  let tree0 : @spec.SpecMergeTree = {
    parts: [p1],
    tombstones: [],
  }

  // Initial state: docs 10, 20, 30, 40 are live
  assert_eq(@spec.doc_is_live(tree0, 10UL), true)
  assert_eq(@spec.doc_is_live(tree0, 20UL), true)
  assert_eq(@spec.doc_is_live(tree0, 50UL), false)

  // Append L0 delta part with docs 50, 60
  let tree1 = @spec.apply_append_l0(tree0, "part_l0_delta_1", [50UL, 60UL])
  assert_eq(@spec.doc_is_live(tree1, 10UL), true)
  assert_eq(@spec.doc_is_live(tree1, 50UL), true)
  assert_eq(@spec.doc_is_live(tree1, 60UL), true)

  // Soft delete doc 20 (base) and doc 50 (L0 delta)
  let tree2 = @spec.apply_soft_delete(tree1, [20UL, 50UL])
  assert_eq(@spec.doc_is_live(tree2, 10UL), true)
  assert_eq(@spec.doc_is_live(tree2, 20UL), false) // Soft-deleted from base
  assert_eq(@spec.doc_is_live(tree2, 30UL), true)
  assert_eq(@spec.doc_is_live(tree2, 40UL), true)
  assert_eq(@spec.doc_is_live(tree2, 50UL), false) // Soft-deleted from L0 delta
  assert_eq(@spec.doc_is_live(tree2, 60UL), true)

  // Compact parts: merges base and L0 delta into new consolidated base
  let tree3 = @spec.apply_compaction(tree2, "part_consolidated_base_2")

  // Verify Inductive Invariant: Live docs PRESERVED 100% across universe!
  let universe : Array[UInt64] = [
    5UL, 10UL, 15UL, 20UL, 25UL, 30UL, 35UL, 40UL, 45UL, 50UL, 55UL, 60UL, 65UL,
  ]
  assert_eq(@spec.verify_compaction_live_doc_preservation(tree2, tree3, universe), true)

  // Explicit verification: soft-deleted doc 50 (L0) and 20 (base) did NOT resurrect!
  assert_eq(@spec.doc_is_live(tree3, 10UL), true)
  assert_eq(@spec.doc_is_live(tree3, 20UL), false)
  assert_eq(@spec.doc_is_live(tree3, 30UL), true)
  assert_eq(@spec.doc_is_live(tree3, 40UL), true)
  assert_eq(@spec.doc_is_live(tree3, 50UL), false)
  assert_eq(@spec.doc_is_live(tree3, 60UL), true)
}

///|
test "formal spec: roaring bitmap membership equivalence and roundtrip" {
  // 1. Sparse array container
  let sparse_ids : Array[UInt64] = [
    1UL, 2UL, 42UL, 1000UL, 65535UL, 65536UL, 100000UL, 0x1_0000_0000UL,
  ]
  let queries : Array[UInt64] = [
    0UL, 1UL, 2UL, 3UL, 42UL, 43UL, 1000UL, 65535UL, 65536UL, 65537UL,
    100000UL, 0x1_0000_0000UL, 0x1_0000_0001UL,
  ]
  assert_eq(@spec.verify_roaring_equivalence(sparse_ids, queries), true)
  assert_eq(@spec.verify_roaring_roundtrip(sparse_ids), true)

  // 2. Dense bitmap container (> 4096 elements)
  let dense_ids : Array[UInt64] = Array(capacity=5000)
  for i in 0..<5000 {
    dense_ids.push((i * 3).to_uint64()) // 0, 3, 6, 9...
  }
  let dense_queries : Array[UInt64] = [
    0UL, 1UL, 2UL, 3UL, 4UL, 6UL, 99UL, 100UL, 14997UL, 14998UL, 15000UL,
  ]
  assert_eq(@spec.verify_roaring_equivalence(dense_ids, dense_queries), true)
  assert_eq(@spec.verify_roaring_roundtrip(dense_ids), true)
}

///|
test "formal spec: safety 3 linearizable cas and lease fencing" {
  let catalog = @spec.SpecCatalog::new()
  let store = @spec.SpecObjectStore::new()
  let now_ms = 1_000_000UL
  let ttl_ms = 5_000UL

  // 1. Initialize genesis branch
  let branch_opt = @spec.catalog_create_branch(
    catalog,
    "main",
    None,
    ["seg_m0"],
    store,
    now_ms,
  )
  assert_eq(branch_opt is None, false)

  // 2. Worker 1 acquires lease
  let token1_opt = @spec.catalog_acquire_lease(catalog, "main", "worker_1", now_ms, ttl_ms)
  assert_eq(token1_opt is None, false)
  let token1 = token1_opt.unwrap()
  assert_eq(token1.token_id, 1UL)
  assert_eq(token1.holder, "worker_1")
  assert_eq(token1.expires_at_ms, now_ms + ttl_ms)

  // 3. Worker 2 attempts to acquire lease on same branch while unexpired -> Fenced/Blocked!
  let token2_opt = @spec.catalog_acquire_lease(catalog, "main", "worker_2", now_ms + 1000UL, ttl_ms)
  assert_eq(token2_opt is None, true)

  // 4. Worker 1 successfully commits head manifest
  let man1 : @spec.SpecManifest = {
    id: "main_man_1",
    seq: 2UL,
    segments: ["seg_m0", "seg_m1"],
    parent_id: Some("main_genesis_m0"),
    created_at_ms: now_ms + 100UL,
  }
  store.put("seg_m1", 2048, now_ms + 100UL)
  store.put("_manifest/main_man_1.json", 256, now_ms + 100UL)

  let commit1 = @spec.catalog_commit_head(catalog, store, "main", token1, 1UL, man1, now_ms + 200UL)
  assert_eq(commit1, @spec.CommitOutcome::CommitOk(2UL))

  // 5. Worker 2 attempts commit with forged / mismatched fencing token -> MUST fail with FencingTokenMismatch!
  let rogue_token : @spec.LeaseToken = {
    token_id: 999UL,
    holder: "worker_2",
    branch: "main",
    expires_at_ms: now_ms + ttl_ms,
  }
  let rogue_man : @spec.SpecManifest = {
    id: "main_man_rogue",
    seq: 3UL,
    segments: ["seg_m0", "seg_m1"],
    parent_id: Some("main_man_1"),
    created_at_ms: now_ms + 300UL,
  }
  store.put("_manifest/main_man_rogue.json", 256, now_ms + 300UL)

  let rogue_commit = @spec.catalog_commit_head(catalog, store, "main", rogue_token, 2UL, rogue_man, now_ms + 300UL)
  match rogue_commit {
    @spec.CommitOutcome::CommitRejected(@spec.CommitError::FencingViolation(@spec.FencingError::FencingTokenMismatch(_))) => ()
    _ => fail("Safety 3 violated: rogue commit with mismatched fencing token was not rejected!")
  }

  // 6. Worker 1 lease expires -> commit fails with LeaseExpired!
  let late_ms = now_ms + ttl_ms + 1000UL
  let expired_man : @spec.SpecManifest = {
    id: "main_man_expired",
    seq: 3UL,
    segments: ["seg_m0", "seg_m1"],
    parent_id: Some("main_man_1"),
    created_at_ms: late_ms,
  }
  store.put("_manifest/main_man_expired.json", 256, late_ms)
  let expired_commit = @spec.catalog_commit_head(catalog, store, "main", token1, 2UL, expired_man, late_ms)
  match expired_commit {
    @spec.CommitOutcome::CommitRejected(@spec.CommitError::FencingViolation(@spec.FencingError::LeaseExpired(_, _))) => ()
    _ => fail("Safety 3 violated: expired lease commit was not rejected!")
  }

  // 7. Verify Safety 3 Invariant function holds
  assert_eq(@spec.verify_safety3_lease_fencing(catalog), true)
}

///|
test "formal spec: safety 2 dual-write crash consistency and no dangling pointers" {
  let catalog = @spec.SpecCatalog::new()
  let store = @spec.SpecObjectStore::new()
  let now_ms = 1_000_000UL
  let ttl_ms = 10_000UL

  let _ = @spec.catalog_create_branch(catalog, "main", None, ["seg_init"], store, now_ms)
  let token = @spec.catalog_acquire_lease(catalog, "main", "uploader_1", now_ms, ttl_ms).unwrap()

  // Initial state check: no dangling pointer
  assert_eq(@spec.verify_safety2_dual_write_consistency(catalog, store), true)

  // 1. Crash before segment upload -> fails, no dangling pointer
  let res_c1 = @spec.execute_dual_write(
    catalog,
    store,
    "main",
    token,
    "seg_crash_1",
    "man_crash_1",
    @spec.CrashStage::CrashBeforeSegmentUpload,
    now_ms,
  )
  assert_eq(res_c1, @spec.CommitOutcome::CommitRejected(@spec.CommitError::MissingSegment("seg_crash_1")))
  assert_eq(@spec.verify_safety2_dual_write_consistency(catalog, store), true)

  // 2. Crash during segment upload (leaves corrupted / partial segment) -> rejected
  let res_c2 = @spec.execute_dual_write(
    catalog,
    store,
    "main",
    token,
    "seg_crash_2",
    "man_crash_2",
    @spec.CrashStage::CrashDuringSegmentUpload,
    now_ms,
  )
  assert_eq(res_c2, @spec.CommitOutcome::CommitRejected(@spec.CommitError::CorruptSegment("seg_crash_2")))
  assert_eq(@spec.verify_safety2_dual_write_consistency(catalog, store), true)

  // 3. Crash after segment upload (manifest missing) -> rejected
  let res_c3 = @spec.execute_dual_write(
    catalog,
    store,
    "main",
    token,
    "seg_crash_3",
    "man_crash_3",
    @spec.CrashStage::CrashAfterSegmentUpload,
    now_ms,
  )
  assert_eq(res_c3, @spec.CommitOutcome::CommitRejected(@spec.CommitError::MissingManifest("_manifest/man_crash_3.json")))
  assert_eq(@spec.verify_safety2_dual_write_consistency(catalog, store), true)

  // 4. Crash after manifest upload (CAS commit never made) -> catalog head unchanged!
  let res_c4 = @spec.execute_dual_write(
    catalog,
    store,
    "main",
    token,
    "seg_crash_4",
    "man_crash_4",
    @spec.CrashStage::CrashAfterManifestUpload,
    now_ms,
  )
  match res_c4 {
    @spec.CommitOutcome::CommitRejected(_) => ()
    _ => fail("Expected rejection on aborted CAS upload")
  }
  let branch_after_c4 = catalog.branches.get("main").unwrap()
  assert_eq(branch_after_c4.head_seq, 1UL) // head never advanced!
  assert_eq(@spec.verify_safety2_dual_write_consistency(catalog, store), true)

  // 5. Successful dual-write without crash
  let res_ok = @spec.execute_dual_write(
    catalog,
    store,
    "main",
    token,
    "seg_success_5",
    "man_success_5",
    @spec.CrashStage::NoCrash,
    now_ms,
  )
  assert_eq(res_ok, @spec.CommitOutcome::CommitOk(2UL))
  let branch_ok = catalog.branches.get("main").unwrap()
  assert_eq(branch_ok.head_seq, 2UL)
  assert_eq(branch_ok.head_manifest_id, "man_success_5")
  assert_eq(@spec.verify_safety2_dual_write_consistency(catalog, store), true)
}

///|
test "formal spec: safety 1 snapshot reachability and gc safety" {
  let catalog = @spec.SpecCatalog::new()
  let store = @spec.SpecObjectStore::new()
  let now_ms = 1_000_000UL
  let ttl_ms = 10_000UL
  let grace_ms = 5_000UL
  let swept_history : Set[String] = Set([])

  // 1. Create main branch with initial segment
  let _ = @spec.catalog_create_branch(catalog, "main", None, ["seg_root"], store, now_ms)
  let token1 = @spec.catalog_acquire_lease(catalog, "main", "w1", now_ms, ttl_ms).unwrap()

  // 2. Commit segment 1
  let res1 = @spec.execute_dual_write(
    catalog,
    store,
    "main",
    token1,
    "seg_v1",
    "man_v1",
    @spec.CrashStage::NoCrash,
    now_ms,
  )
  assert_eq(res1, @spec.CommitOutcome::CommitOk(2UL))

  // 3. Snapshot pinned at man_v1 (containing seg_root and seg_v1)
  let snap1 = @spec.catalog_create_snapshot(catalog, "snap_v1", "main", now_ms).unwrap()
  assert_eq(snap1.pinned_segments.length(), 2)

  // 4. Advance main branch with segment 2
  let res2 = @spec.execute_dual_write(
    catalog,
    store,
    "main",
    token1,
    "seg_v2",
    "man_v2",
    @spec.CrashStage::NoCrash,
    now_ms + 100UL,
  )
  assert_eq(res2, @spec.CommitOutcome::CommitOk(3UL))

  // 5. Fork zero-copy child branch from main
  let _ = @spec.catalog_create_branch(catalog, "feature", Some("main"), [], store, now_ms + 200UL)
  let token_feat = @spec.catalog_acquire_lease(catalog, "feature", "w_feat", now_ms + 200UL, ttl_ms).unwrap()

  // 6. Write feature segment
  let res3 = @spec.execute_dual_write(
    catalog,
    store,
    "feature",
    token_feat,
    "seg_feat_1",
    "man_feat_1",
    @spec.CrashStage::NoCrash,
    now_ms + 300UL,
  )
  assert_eq(res3, @spec.CommitOutcome::CommitOk(4UL))

  // 7. Inject an orphan segment in store (simulating an upload aborted prior to manifest commit)
  store.put("seg_orphan_aborted", 512, now_ms + 400UL)

  // 8. Run GC Identification within grace period -> orphan NOT marked unreferenced yet
  let unref_early = @spec.gc_identify_unreferenced(catalog, store, now_ms + 400UL + 1000UL, grace_ms)
  assert_eq(unref_early.is_empty(), true)

  // 9. Advance beyond grace period -> orphan IS identified as unreferenced
  let unref_late = @spec.gc_identify_unreferenced(catalog, store, now_ms + 400UL + grace_ms + 100UL, grace_ms)
  assert_eq(unref_late.length(), 1)
  assert_eq(unref_late[0], "seg_orphan_aborted")

  // 10. Crucial Safety 1 Invariant: NONE of the snapshot or lineage segments are unreferenced!
  let reachable = @spec.collect_reachable_segments(catalog)
  assert_eq(reachable.contains("seg_root"), true)
  assert_eq(reachable.contains("seg_v1"), true)
  assert_eq(reachable.contains("seg_v2"), true)
  assert_eq(reachable.contains("seg_feat_1"), true)
  assert_eq(reachable.contains("seg_orphan_aborted"), false)

  // 11. Run GC sweep
  let (swept_count, swept_list) = @spec.gc_sweep(
    catalog,
    store,
    swept_history,
    now_ms + 400UL + grace_ms + 100UL,
    grace_ms,
  )
  assert_eq(swept_count, 1)
  assert_eq(swept_list[0], "seg_orphan_aborted")
  assert_eq(store.is_committed("seg_orphan_aborted"), false)

  // 12. Verify Safety 1 holds 100%
  assert_eq(@spec.verify_safety1_snapshot_gc_safety(catalog, swept_history, store), true)
}

///|
test "formal spec: 10,000-iteration randomized state machine model checker" {
  let stats = @spec.run_randomized_state_machine_model_checker(10000, 0xcafe_babe_dead_beefUL)

  assert_eq(stats.total_steps, 10000)
  assert_eq(stats.safety1_checks_passed, 10000)
  assert_eq(stats.safety2_checks_passed, 10000)
  assert_eq(stats.safety3_checks_passed, 10000)
  assert_eq(stats.all_invariants_held, true)

  // Verify transition coverage across state machine
  assert_eq(stats.branches_created > 0, true)
  assert_eq(stats.docs_written > 0, true)
  assert_eq(stats.crashes_injected > 0, true)
  assert_eq(stats.snapshots_created > 0, true)
  assert_eq(stats.leases_expired > 0, true)
  assert_eq(stats.concurrent_cas_runs > 0, true)
  assert_eq(stats.fencing_mismatches_caught > 0, true)
  assert_eq(stats.gc_sweeps_run > 0, true)
}

