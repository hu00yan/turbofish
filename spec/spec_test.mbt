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
