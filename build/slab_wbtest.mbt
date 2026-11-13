// build/slab_wbtest.mbt - Unit tests for SlabV2 storage layout in build package

///|
fn make_test_docs() -> Array[@core.Doc] {
  [
    {
      id: 101UL,
      text: "quick brown fox",
      vector: [0.1, 0.2, 0.3, 0.4],
      category: "animal",
      ts: 1000L,
      public: true,
    },
    {
      id: 102UL,
      text: "lazy dog sleep",
      vector: [0.5, 0.6, 0.7, 0.8],
      category: "animal",
      ts: 2000L,
      public: false,
    },
    {
      id: 103UL,
      text: "quick brown dog",
      vector: [0.2, 0.3, 0.4, 0.5],
      category: "pet",
      ts: 3000L,
      public: true,
    },
  ]
}

///|
test "build: write_segment_slab single-file layout and read back" {
  let store = @store.MemStore::new()
  let cfg = BuildConfig::default("slab_test")
  let cent : @format.Centroids = { dim: 4, data: [0.1, 0.2, 0.3, 0.4] }
  let docs = make_test_docs()

  let meta = write_segment_slab(
    store,
    cfg,
    cent,
    docs,
    0,
    docs.length(),
    index_at_end=true,
  )

  assert_eq(meta.row_count, 3)
  assert_eq(meta.min_id, 101UL)
  assert_eq(meta.max_id, 103UL)
  assert_eq(meta.size_bytes > 0, true)

  let slab_k = segment_slab_key(cfg.ns, meta.id)
  let slab_bs = store.get(slab_k)
  assert_eq(slab_bs is Some(_), true)

  // Verify that individual legacy column files do NOT exist
  let legacy_id_key = "\{cfg.ns}/_segments/\{meta.id}/rows/id.bin"
  assert_eq(store.get(legacy_id_key) is None, true)
  let legacy_text_key = "\{cfg.ns}/_segments/\{meta.id}/rows/text.bin"
  assert_eq(store.get(legacy_text_key) is None, true)
  let legacy_fts_key = "\{cfg.ns}/_segments/\{meta.id}/fts/dir.bin"
  assert_eq(store.get(legacy_fts_key) is None, true)

  // Read index via read_slab_index
  let index = read_slab_index(store, cfg.ns, meta.id, meta.size_bytes)
  assert_eq(index.has("id"), true)
  assert_eq(index.has("text"), true)
  assert_eq(index.has("category"), true)
  assert_eq(index.has("ts"), true)
  assert_eq(index.has("public"), true)
  assert_eq(index.has("fts/dir"), true)
  assert_eq(index.has("fts/postings"), true)

  // Read and decode columns
  let col_id = read_slab_column(store, cfg.ns, meta.id, index, "id")
  match col_id {
    ColU64(ids) => assert_eq(ids, [101UL, 102UL, 103UL])
    _ => fail("expected ColU64")
  }

  let col_ts = read_slab_column(store, cfg.ns, meta.id, index, "ts")
  match col_ts {
    ColI64(tss) => assert_eq(tss, [1000L, 2000L, 3000L])
    _ => fail("expected ColI64")
  }

  // Read and decode FTS directory
  let fts_dir = read_slab_fts_dir(store, cfg.ns, meta.id, index)
  assert_eq(fts_dir.length() > 0, true)
  let mut found_fox = false
  for entry in fts_dir {
    if entry.term == "fox" {
      found_fox = true
      assert_eq(entry.df, 1)
      // Read postings for "fox" using range
      let postings_bs = read_slab_fts_postings_range(
        store,
        cfg.ns,
        meta.id,
        index,
        entry.offset,
        entry.size,
      )
      assert_eq(postings_bs.length(), entry.size)
    }
  }
  assert_eq(found_fox, true)
}

///|
test "build: 1 Range request reads index header at fixed offset" {
  let store = @store.MemStore::new()
  let cfg = BuildConfig::default("range_test")
  let cent : @format.Centroids = { dim: 4, data: [0.1, 0.2, 0.3, 0.4] }
  let docs = make_test_docs()

  // Write segment with index at fixed offset 14 (at the front)
  let meta = write_segment_slab(
    store,
    cfg,
    cent,
    docs,
    0,
    docs.length(),
    index_at_end=false,
  )

  let before = store.cost().ranged_gets
  let index = read_slab_index_from_start(store, cfg.ns, meta.id, prefetch_len=1024)
  let after = store.cost().ranged_gets
  // EXACTLY 1 Range request performed!
  assert_eq(after - before, 1)
  assert_eq(index.has("id"), true)
  assert_eq(index.has("text"), true)

  // Now fetch specific column using 1 more range request
  let before_col = store.cost().ranged_gets
  let col_id = read_slab_column(store, cfg.ns, meta.id, index, "id")
  let after_col = store.cost().ranged_gets
  assert_eq(after_col - before_col, 1)
  match col_id {
    ColU64(ids) => assert_eq(ids, [101UL, 102UL, 103UL])
    _ => fail("expected ColU64")
  }
}

///|
test "build: 1 Range request reads index trailer at tail" {
  let store = @store.MemStore::new()
  let cfg = BuildConfig::default("tail_test")
  let cent : @format.Centroids = { dim: 4, data: [0.1, 0.2, 0.3, 0.4] }
  let docs = make_test_docs()

  // Write segment with index at end
  let meta = write_segment_slab(
    store,
    cfg,
    cent,
    docs,
    0,
    docs.length(),
    index_at_end=true,
  )

  let before = store.cost().ranged_gets
  let index = read_slab_index_from_tail(
    store,
    cfg.ns,
    meta.id,
    meta.size_bytes,
    tail_len=1024,
  )
  let after = store.cost().ranged_gets
  // EXACTLY 1 Range request to read index at tail!
  assert_eq(after - before, 1)
  assert_eq(index.has("id"), true)
  assert_eq(index.has("text"), true)
}

///|
test "build: pluggable format switch LegacyMultiFile vs SlabV2" {
  let store = @store.MemStore::new()
  let cfg = BuildConfig::default("pluggable_test")
  let cent : @format.Centroids = { dim: 4, data: [0.1, 0.2, 0.3, 0.4] }
  let docs = make_test_docs()

  // 1. LegacyMultiFile: produces 5+ separate files
  let legacy_meta = write_segment_pluggable(
    store,
    cfg,
    cent,
    docs,
    0,
    docs.length(),
    LegacyMultiFile,
  )
  let leg_id_key = "\{cfg.ns}/_segments/\{legacy_meta.id}/rows/id.bin"
  let leg_text_key = "\{cfg.ns}/_segments/\{legacy_meta.id}/rows/text.bin"
  let leg_fts_key = "\{cfg.ns}/_segments/\{legacy_meta.id}/fts/dir.bin"
  assert_eq(store.get(leg_id_key) is Some(_), true)
  assert_eq(store.get(leg_text_key) is Some(_), true)
  assert_eq(store.get(leg_fts_key) is Some(_), true)
  let leg_slab_key = segment_slab_key(cfg.ns, legacy_meta.id)
  assert_eq(store.get(leg_slab_key) is None, true)

  // 2. SlabV2: produces single segment.slab file
  let slab_meta = write_segment_pluggable(
    store,
    cfg,
    cent,
    docs,
    0,
    docs.length(),
    SlabV2,
  )
  let slab_k = segment_slab_key(cfg.ns, slab_meta.id)
  assert_eq(store.get(slab_k) is Some(_), true)
  let slab_id_key = "\{cfg.ns}/_segments/\{slab_meta.id}/rows/id.bin"
  assert_eq(store.get(slab_id_key) is None, true)
}
