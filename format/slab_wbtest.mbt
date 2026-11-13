// format/slab_wbtest.mbt - Unit tests for SlabV2 storage layout

///|
test "slab: header encode and decode" {
  let hdr = encode_slab_header(2, 1024L)
  assert_eq(hdr.length(), SLAB_HEADER_LEN)
  let (ver, offset) = decode_slab_header(hdr)
  assert_eq(ver, 2)
  assert_eq(offset, 1024L)

  // Corrupted magic
  let bad_magic = Buffer()
  bad_magic.write_string_utf8("XXXX")
  bad_magic.write_uint16_le((2).to_uint16())
  bad_magic.write_int64_le(1024L)
  let mut caught_bad = false
  try {
    let _ = decode_slab_header(bad_magic.to_bytes())
    ()
  } catch {
    @core.Corrupt(_) => caught_bad = true
    _ => ()
  }
  assert_eq(caught_bad, true)

  // Truncated header
  let trunc = Buffer()
  trunc.write_string_utf8("SLA")
  let mut caught_trunc = false
  try {
    let _ = decode_slab_header(trunc.to_bytes())
    ()
  } catch {
    @core.Truncated(_) => caught_trunc = true
    _ => ()
  }
  assert_eq(caught_trunc, true)
}

///|
test "slab: index encode and decode" {
  let entries : Array[SlabEntry] = [
    { name: "id", offset: 14L, length: 128L, row_count: 10 },
    { name: "text", offset: 142L, length: 256L, row_count: 10 },
    { name: "category", offset: 398L, length: 64L, row_count: 10 },
    { name: "ts", offset: 462L, length: 80L, row_count: 10 },
    { name: "public", offset: 542L, length: 16L, row_count: 10 },
    { name: "fts/dir", offset: 558L, length: 120L, row_count: 5 },
    { name: "fts/postings", offset: 678L, length: 300L, row_count: 15 },
  ]
  let index : SlabIndex = { entries, }
  let bs = encode_slab_index(index)
  let decoded = decode_slab_index(bs, 0)
  assert_eq(decoded.entries.length(), entries.length())

  for i in 0..<entries.length() {
    let orig = entries[i]
    let dec = decoded.entries[i]
    assert_eq(dec.name, orig.name)
    assert_eq(dec.offset, orig.offset)
    assert_eq(dec.length, orig.length)
    assert_eq(dec.row_count, orig.row_count)
  }

  // Lookup by exact name and aliases
  let e_id = decoded.get("id")
  assert_eq(e_id.map(fn(e) { e.name }), Some("id"))
  let e_id_alias = decoded.get("rows/id.bin")
  assert_eq(e_id_alias.map(fn(e) { e.name }), Some("id"))
  let e_id_comp = decoded.get_component(Id)
  assert_eq(e_id_comp.map(fn(e) { e.name }), Some("id"))

  let e_dir_alias = decoded.get("fts/dir.bin")
  assert_eq(e_dir_alias.map(fn(e) { e.name }), Some("fts/dir"))
  let e_dir_comp = decoded.get_component(FtsDir)
  assert_eq(e_dir_comp.map(fn(e) { e.name }), Some("fts/dir"))

  let e_post_alias = decoded.get("fts/postings.bin")
  assert_eq(e_post_alias.map(fn(e) { e.name }), Some("fts/postings"))
  let e_post_comp = decoded.get_component(FtsPostings)
  assert_eq(e_post_comp.map(fn(e) { e.name }), Some("fts/postings"))

  assert_eq(decoded.has("id"), true)
  assert_eq(decoded.has("nonexistent"), false)
}

///|
test "slab: full slab file roundtrip with index at end" {
  let ids : Array[UInt64] = [1001UL, 1002UL, 1003UL]
  let texts : Array[String] = ["apple pie", "banana bread", "apple cider"]
  let cats : Array[String] = ["food", "food", "drink"]
  let tss : Array[Int64] = [1000L, 2000L, 3000L]
  let pubs : Array[Bool] = [true, false, true]

  let bs_id = encode_col(ColU64(ids))
  let bs_text = encode_col_str_plain(texts)
  let bs_cat = encode_col_str_plain(cats)
  let bs_ts = encode_col(ColI64(tss))
  let bs_pub = encode_col_bool_plain(pubs)

  let lists : Array[(String, Array[Posting])] = [
    ("apple", [{ row: 0, tf: 1 }, { row: 2, tf: 1 }]),
    ("banana", [{ row: 1, tf: 1 }]),
  ]
  let fts_built = encode_fts(lists)

  let components : Array[SlabComponentPayload] = [
    { name: "id", data: bs_id, row_count: 3 },
    { name: "text", data: bs_text, row_count: 3 },
    { name: "category", data: bs_cat, row_count: 3 },
    { name: "ts", data: bs_ts, row_count: 3 },
    { name: "public", data: bs_pub, row_count: 3 },
    { name: "fts/dir", data: fts_built.dir, row_count: 2 },
    { name: "fts/postings", data: fts_built.postings, row_count: 3 },
  ]

  let (slab_bytes, _index) = encode_slab(components, index_at_end=true)
  assert_eq(slab_bytes.length() > SLAB_HEADER_LEN + SLAB_TRAILER_LEN, true)

  // 1. Decode full file
  let (ver, decoded_index) = decode_slab_file(slab_bytes)
  assert_eq(ver, SLAB_VERSION)
  assert_eq(decoded_index.entries.length(), components.length())

  // 2. Decode trailer + index from tail (1 Range request simulation)
  let (trailer_off, trailer_len) = decode_slab_trailer(slab_bytes)
  assert_eq(trailer_off > 0L, true)
  assert_eq(trailer_len > 0, true)

  let tail_slice_len = trailer_len + SLAB_TRAILER_LEN
  let tail_buf = Buffer()
  let start_tail = slab_bytes.length() - tail_slice_len
  for i in 0..<tail_slice_len {
    tail_buf.write_byte(slab_bytes[start_tail + i])
  }
  let tail_index = decode_slab_index_from_tail_bytes(
    tail_buf.to_bytes(),
    slab_bytes.length(),
  )
  assert_eq(tail_index.entries.length(), components.length())

  // 3. Extract and verify data slices
  let slice_id = decoded_index.get_slice(slab_bytes, "id")
  assert_eq(slice_id is Some(_), true)
  let dec_id = match decode_col(slice_id.unwrap()) {
    ColU64(arr) => arr
    _ => []
  }
  assert_eq(dec_id, ids)

  let slice_ts = decoded_index.get_slice(slab_bytes, "ts")
  let dec_ts = match decode_col(slice_ts.unwrap()) {
    ColI64(arr) => arr
    _ => []
  }
  assert_eq(dec_ts, tss)

  let slice_dir = decoded_index.get_slice(slab_bytes, "fts/dir")
  let dec_dir = decode_fts_dir(slice_dir.unwrap())
  assert_eq(dec_dir.length(), 2)
  assert_eq(dec_dir[0].term, "apple")
  assert_eq(dec_dir[1].term, "banana")
}

///|
test "slab: full slab file roundtrip with index at fixed offset" {
  let ids : Array[UInt64] = [501UL, 502UL]
  let texts : Array[String] = ["hello slab", "world v2"]
  let bs_id = encode_col(ColU64(ids))
  let bs_text = encode_col_str_plain(texts)

  let components : Array[SlabComponentPayload] = [
    { name: "id", data: bs_id, row_count: 2 },
    { name: "text", data: bs_text, row_count: 2 },
  ]

  let (slab_bytes, _index) = encode_slab(components, index_at_end=false)
  let (ver, index_offset) = decode_slab_header(slab_bytes)
  assert_eq(ver, SLAB_VERSION)
  assert_eq(index_offset, SLAB_HEADER_LEN.to_int64())

  // In 1 Range request, reader reads first 512 bytes:
  let prefetch_len = if slab_bytes.length() < 512 { slab_bytes.length() } else { 512 }
  let prefetch_buf = Buffer()
  for i in 0..<prefetch_len {
    prefetch_buf.write_byte(slab_bytes[i])
  }
  let (hdr_ver, hdr_index) = decode_slab_index_from_header_bytes(
    prefetch_buf.to_bytes(),
  )
  assert_eq(hdr_ver, SLAB_VERSION)
  assert_eq(hdr_index.entries.length(), 2)
  assert_eq(hdr_index.get("id").unwrap().row_count, 2)
  assert_eq(hdr_index.get("text").unwrap().row_count, 2)

  // Verify slice reading
  let slice_id = hdr_index.get_slice(slab_bytes, "id")
  let dec_id = match decode_col(slice_id.unwrap()) {
    ColU64(arr) => arr
    _ => []
  }
  assert_eq(dec_id, ids)
}

///|
test "slab: SegmentFormat enum string roundtrip" {
  assert_eq(LegacyMultiFile.to_string(), "legacy_multi_file")
  assert_eq(SlabV2.to_string(), "slab_v2")

  assert_eq(SegmentFormat::from_string("legacy_multi_file"), Some(LegacyMultiFile))
  assert_eq(SegmentFormat::from_string("legacy"), Some(LegacyMultiFile))
  assert_eq(SegmentFormat::from_string("slab_v2"), Some(SlabV2))
  assert_eq(SegmentFormat::from_string("slab"), Some(SlabV2))
  assert_eq(SegmentFormat::from_string("v2"), Some(SlabV2))
  assert_eq(SegmentFormat::from_string("other"), None)
}
