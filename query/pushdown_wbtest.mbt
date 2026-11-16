// Predicate Pushdown Filtering Engine White-Box Tests
// Verifies:
// 1. BitSet bitwise operations, multi-word indexing, popcount, and row extraction.
// 2. Vectorized columnar evaluation across all @query.Filter variants:
//    Eq, Neq, In, NotIn, Lt, Lte, Gt, Gte, Glob, And, Or, Not
// 3. Complex multi-level nested filter ASTs.
// 4. Integration into vector search candidate pruning (zero-match pruning, heavy filter pruning, tombstone pruning).

///|
async test "pushdown bitset: basic bit operations and popcount" {
  let bs = BitSet::new(130)
  assert_eq(bs.count(), 0)
  assert_eq(bs.is_empty(), true)

  bs.set(0)
  bs.set(63)
  bs.set(64)
  bs.set(127)
  bs.set(129)

  assert_eq(bs.get(0), true)
  assert_eq(bs.get(1), false)
  assert_eq(bs.get(63), true)
  assert_eq(bs.get(64), true)
  assert_eq(bs.get(127), true)
  assert_eq(bs.get(128), false)
  assert_eq(bs.get(129), true)
  assert_eq(bs.count(), 5)
  assert_eq(bs.is_empty(), false)

  // Unset bit
  bs.unset(63)
  assert_eq(bs.get(63), false)
  assert_eq(bs.count(), 4)

  // to_rows extraction
  let rows = bs.to_rows()
  assert_eq(rows, [0, 64, 127, 129])
}

///|
async test "pushdown bitset: all_set, not_inplace, and mask_last_word" {
  let bs = BitSet::all_set(70)
  assert_eq(bs.count(), 70)
  for i in 0..<70 {
    assert_eq(bs.get(i), true)
  }
  // Out of range should be false
  assert_eq(bs.get(70), false)
  assert_eq(bs.get(71), false)

  // not_inplace should turn all 70 bits to 0
  bs.not_inplace()
  assert_eq(bs.count(), 0)
  assert_eq(bs.is_empty(), true)

  // not_inplace again should turn them back to 1
  bs.not_inplace()
  assert_eq(bs.count(), 70)
}

///|
async test "pushdown bitset: and_inplace and or_inplace" {
  let a = BitSet::new(100)
  let b = BitSet::new(100)

  a.set(10)
  a.set(20)
  a.set(70)

  b.set(20)
  b.set(30)
  b.set(70)
  b.set(90)

  // Clone a and OR with b
  let c = a.clone()
  c.or_inplace(b)
  assert_eq(c.count(), 5)
  assert_eq(c.to_rows(), [10, 20, 30, 70, 90])

  // AND with b
  a.and_inplace(b)
  assert_eq(a.count(), 2)
  assert_eq(a.to_rows(), [20, 70])
}

///|
async test "pushdown filter: columnar Eq and Neq evaluation" {
  let n = open(make_test_store([]), "test")
  let cs0 = ensure_seg(n, 0) // seg-01A (4 docs: 1, 2, 3, 4)
  // seg-01A data:
  // id: 1, 2, 3, 4
  // category: "a", "b", "a", "c"
  // ts: 100L, 200L, 300L, 400L
  // public: true, false, true, false

  // 1. String Eq
  let bs_cat_a = eval_filter_columnar(n, cs0, "seg-01A", Eq("category", S("a")))
  assert_eq(bs_cat_a.to_rows(), [0, 2])

  // 2. String Neq
  let bs_cat_neq_a = eval_filter_columnar(
    n,
    cs0,
    "seg-01A",
    Neq("category", S("a")),
  )
  assert_eq(bs_cat_neq_a.to_rows(), [1, 3])

  // 3. Bool Eq
  let bs_pub_true = eval_filter_columnar(
    n,
    cs0,
    "seg-01A",
    Eq("public", B(true)),
  )
  assert_eq(bs_pub_true.to_rows(), [0, 2])

  // 4. Int64 Eq
  let bs_ts_200 = eval_filter_columnar(n, cs0, "seg-01A", Eq("ts", I(200L)))
  assert_eq(bs_ts_200.to_rows(), [1])

  // 5. UInt64 (id) Eq
  let bs_id_3 = eval_filter_columnar(n, cs0, "seg-01A", Eq("id", I(3L)))
  assert_eq(bs_id_3.to_rows(), [2])
}

///|
async test "pushdown filter: columnar In and NotIn evaluation" {
  let n = open(make_test_store([]), "test")
  let cs0 = ensure_seg(n, 0)

  // In strings
  let bs_in_cat = eval_filter_columnar(
    n,
    cs0,
    "seg-01A",
    In("category", [S("b"), S("c")]),
  )
  assert_eq(bs_in_cat.to_rows(), [1, 3])

  // NotIn strings
  let bs_notin_cat = eval_filter_columnar(
    n,
    cs0,
    "seg-01A",
    NotIn("category", [S("b"), S("c")]),
  )
  assert_eq(bs_notin_cat.to_rows(), [0, 2])

  // In i64
  let bs_in_ts = eval_filter_columnar(
    n,
    cs0,
    "seg-01A",
    In("ts", [I(100L), I(400L), I(999L)]),
  )
  assert_eq(bs_in_ts.to_rows(), [0, 3])

  // In empty should match 0 rows
  let bs_in_empty = eval_filter_columnar(n, cs0, "seg-01A", In("category", []))
  assert_eq(bs_in_empty.is_empty(), true)

  // NotIn empty should match all rows
  let bs_notin_empty = eval_filter_columnar(
    n,
    cs0,
    "seg-01A",
    NotIn("category", []),
  )
  assert_eq(bs_notin_empty.count(), cs0.row_count)
}

///|
async test "pushdown filter: columnar range comparison (Lt, Lte, Gt, Gte)" {
  let n = open(make_test_store([]), "test")
  let cs0 = ensure_seg(n, 0)

  // ts: 100, 200, 300, 400
  let bs_lt = eval_filter_columnar(n, cs0, "seg-01A", Lt("ts", I(300L)))
  assert_eq(bs_lt.to_rows(), [0, 1])

  let bs_lte = eval_filter_columnar(n, cs0, "seg-01A", Lte("ts", I(300L)))
  assert_eq(bs_lte.to_rows(), [0, 1, 2])

  let bs_gt = eval_filter_columnar(n, cs0, "seg-01A", Gt("ts", I(200L)))
  assert_eq(bs_gt.to_rows(), [2, 3])

  let bs_gte = eval_filter_columnar(n, cs0, "seg-01A", Gte("ts", I(200L)))
  assert_eq(bs_gte.to_rows(), [1, 2, 3])

  // String range (category: "a", "b", "a", "c")
  let bs_str_lte = eval_filter_columnar(
    n,
    cs0,
    "seg-01A",
    Lte("category", S("b")),
  )
  assert_eq(bs_str_lte.to_rows(), [0, 1, 2])
}

///|
async test "pushdown filter: columnar Glob evaluation" {
  let n = open(make_test_store([]), "test")
  let cs0 = ensure_seg(n, 0)
  // text: "the quick brown fox", "the lazy dog sleeps", "fox and fox run", "猫追狗"

  let bs_fox = eval_filter_columnar(n, cs0, "seg-01A", Glob("text", "*fox*"))
  assert_eq(bs_fox.to_rows(), [0, 2])

  let bs_sleeps = eval_filter_columnar(
    n,
    cs0,
    "seg-01A",
    Glob("text", "*sleeps"),
  )
  assert_eq(bs_sleeps.to_rows(), [1])
}

///|
async test "pushdown filter: complex nested filters (And, Or, Not)" {
  let n = open(make_test_store([]), "test")
  let cs0 = ensure_seg(n, 0)

  // And([Eq(category, "a"), Gt(ts, 150L)])
  // row 0: cat "a", ts 100 -> false
  // row 2: cat "a", ts 300 -> true
  let f1 = And([Eq("category", S("a")), Gt("ts", I(150L))])
  assert_eq(eval_filter_columnar(n, cs0, "seg-01A", f1).to_rows(), [2])

  // Complex nested:
  // Or([
  //   And([Eq("category", S("a")), Lt("ts", I(200L))]),  -> row 0
  //   And([Eq("category", S("c")), Eq("public", B(false))]) -> row 3
  // ])
  let f2 = Or([
    And([Eq("category", S("a")), Lt("ts", I(200L))]),
    And([Eq("category", S("c")), Eq("public", B(false))]),
  ])
  assert_eq(eval_filter_columnar(n, cs0, "seg-01A", f2).to_rows(), [0, 3])

  // Triple nested with Not:
  // And([
  //   Not(Eq("category", S("b"))),                        -> {0, 2, 3}
  //   Or([Eq("public", B(true)), Gte("ts", I(400L))])    -> {0, 2, 3}
  // ])
  let f3 = And([
    Not(Eq("category", S("b"))),
    Or([Eq("public", B(true)), Gte("ts", I(400L))]),
  ])
  assert_eq(eval_filter_columnar(n, cs0, "seg-01A", f3).to_rows(), [0, 2, 3])
}

///|
async test "pushdown filter: global eval_pushdown_filter with selectivity and tombstones" {
  // Store with doc 1 deleted
  let s = make_test_store([1UL])
  let n = open(s, "test")

  // Filter: Eq("category", S("a"))
  // Without tombstone: id 1 (seg-01A row 0), id 3 (seg-01A row 2), id 5 (seg-01B row 0)
  // With tombstone: id 1 deleted -> survives id 3 and id 5
  let p = eval_pushdown_filter(n, Eq("category", S("a")))

  assert_eq(p.total_matched, 2)
  assert_eq(p.contains_id(1UL), false) // tombstone pruned!
  assert_eq(p.contains_id(3UL), true)
  assert_eq(p.contains_id(5UL), true)

  // Check segment bitsets
  let bs_a = p.get_seg_bitset("seg-01A").unwrap()
  assert_eq(bs_a.to_rows(), [2]) // row 0 pruned by tombstone!

  let bs_b = p.get_seg_bitset("seg-01B").unwrap()
  assert_eq(bs_b.to_rows(), [0]) // id 5
}

///|
async test "pushdown filter: vector candidate pruning and zero-match short circuit" {
  let s = make_test_store([])
  let n = open(s, "test")
  let qv : Array[Float] = [10.0, 0.0]

  // 1. Zero-match filter: category == "nonexistent"
  // Should immediately return [] without computing dot products
  let res_empty = vec_search(
    n,
    qv,
    5,
    2,
    Some(Eq("category", S("nonexistent"))),
  )
  assert_eq(res_empty.is_empty(), true)

  // 2. Heavy filter: only 1 document survives out of 6 (selectivity = 16.7%)
  // id 2: category "b", ts 200
  let res_single = vec_search(
    n,
    qv,
    5,
    2,
    Some(And([Eq("category", S("b")), Eq("ts", I(200L))])),
  )
  assert_eq(res_single.length(), 1)
  assert_eq(res_single[0].id, 2UL)

  // 3. Multi-condition pushdown: id 5 only
  // id 5: category "a", public true, ts >= 500
  let res_5 = vec_search(
    n,
    qv,
    5,
    2,
    Some(
      And([
        Eq("category", S("a")),
        Eq("public", B(true)),
        Gte("ts", I(500L)),
      ]),
    ),
  )
  assert_eq(res_5.length(), 1)
  assert_eq(res_5[0].id, 5UL)
}

///|
async test "pushdown filter: count_docs and matching_ids use pushdown" {
  let s = make_test_store([])
  let n = open(s, "test")

  let f = And([Eq("category", S("a")), Eq("public", B(true))])
  // Matches id 1 (seg-01A), id 3 (seg-01A), id 5 (seg-01B) = 3 docs
  let cnt = count_docs(n, Some(f))
  assert_eq(cnt, 3)

  let ids = matching_ids(n, f)
  assert_eq(ids.length(), 3)
  let s_ids : Set[UInt64] = Set([])
  for id in ids {
    s_ids.add(id)
  }
  assert_eq(s_ids.contains(1UL), true)
  assert_eq(s_ids.contains(3UL), true)
  assert_eq(s_ids.contains(5UL), true)
}
