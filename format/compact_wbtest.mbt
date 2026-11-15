// Compact Part 格式白盒测试：
// 单文件固化、Footer 索引、Trailer 解析、Docs 往返保真度、Range GET 模拟。

///|
fn sample_docs(n : Int, dim : Int) -> Array[@core.Doc] {
  let docs : Array[@core.Doc] = Array(capacity=n)
  for i in 0..<n {
    let v : Array[Float] = Array(capacity=dim)
    for d in 0..<dim {
      v.push(Float::from_int(i * dim + d) * 0.1)
    }
    docs.push({
      id: (i + 100).to_uint64(),
      text: "document number \{i} with search keyword",
      vector: v,
      category: if i % 2 == 0 { "news" } else { "tech" },
      ts: (1700000000 + i * 60).to_int64(),
      public: i % 3 != 0,
    })
  }
  docs
}

///|
test "compact part roundtrip and section marks" {
  let dim = 4
  let docs = sample_docs(10, dim)
  let (part_bytes, footer) = encode_compact_part(docs, dim, false, None)

  // 1. Trailer 解析
  let (f_off, f_len) = decode_compact_part_trailer(part_bytes)
  assert_eq(f_off + f_len + COMPACT_TRAILER_LEN, part_bytes.length())

  // 2. Footer 解析
  let decoded_footer = decode_compact_part_footer(part_bytes, f_off, f_len)
  assert_eq(decoded_footer.sections.length(), footer.sections.length())
  assert_eq(decoded_footer.has("col:id"), true)
  assert_eq(decoded_footer.has("col:text"), true)
  assert_eq(decoded_footer.has("col:category"), true)
  assert_eq(decoded_footer.has("col:ts"), true)
  assert_eq(decoded_footer.has("col:public"), true)
  assert_eq(decoded_footer.has("col:vector"), true)
  assert_eq(decoded_footer.has("fts:dir"), true)
  assert_eq(decoded_footer.has("fts:postings"), true)
  assert_eq(decoded_footer.has("fts:doc_len"), true)

  // 3. 各 section 不重叠且连续紧密
  let mut prev_end = 0
  for sec in decoded_footer.sections {
    assert_eq(sec.offset, prev_end)
    assert_eq(sec.length > 0, true)
    prev_end = sec.offset + sec.length
  }
  assert_eq(prev_end, f_off)

  // 4. Docs 往返一致性
  let back_docs = decode_compact_part_docs(part_bytes, decoded_footer)
  assert_eq(back_docs.length(), docs.length())
  for i in 0..<docs.length() {
    assert_eq(back_docs[i].id, docs[i].id)
    assert_eq(back_docs[i].text, docs[i].text)
    assert_eq(back_docs[i].category, docs[i].category)
    assert_eq(back_docs[i].ts, docs[i].ts)
    assert_eq(back_docs[i].public, docs[i].public)
    assert_eq(back_docs[i].vector.length(), dim)
    for d in 0..<dim {
      assert_eq(back_docs[i].vector[d], docs[i].vector[d])
    }
  }
}

///|
test "compact part range get simulation" {
  let dim = 4
  let docs = sample_docs(5, dim)
  let (part_bytes, _) = encode_compact_part(docs, dim, false, None)
  let total_len = part_bytes.length()

  // 模拟 S3 Range GET 1: 读取末尾 16 字节获取 trailer
  let trailer_slice = part_bytes.exact_view(
    start=total_len - COMPACT_TRAILER_LEN,
    end=total_len,
  ).to_owned()
  let (footer_off, footer_len) = decode_compact_part_trailer(trailer_slice)

  // 模拟 S3 Range GET 2: 读取 footer 切片
  let footer_slice = part_bytes.exact_view(
    start=footer_off,
    end=footer_off + footer_len,
  ).to_owned()
  let footer = decode_compact_part_footer(footer_slice, 0, footer_len)

  // 模拟 S3 Range GET 3: 仅读取 col:id 列
  let id_sec = match footer.get("col:id") {
    Some(s) => s
    None => fail("missing col:id")
  }
  let id_slice = part_bytes.exact_view(
    start=id_sec.offset,
    end=id_sec.offset + id_sec.length,
  ).to_owned()
  let id_col = decode_col(id_slice)
  match id_col {
    ColU64(ids) => {
      assert_eq(ids.length(), 5)
      assert_eq(ids[0], 100UL)
      assert_eq(ids[4], 104UL)
    }
    _ => fail("expected ColU64")
  }

  // 模拟 S3 Range GET 4: 仅读取 fts:dir
  let fts_dir_sec = match footer.get("fts:dir") {
    Some(s) => s
    None => fail("missing fts:dir")
  }
  let fts_dir_slice = part_bytes.exact_view(
    start=fts_dir_sec.offset,
    end=fts_dir_sec.offset + fts_dir_sec.length,
  ).to_owned()
  let entries = decode_fts_dir(fts_dir_slice)
  assert_eq(entries.length() > 0, true)
}

///|
test "compact part with ivf centroids" {
  let dim = 2
  let docs : Array[@core.Doc] = [
    {
      id: 1UL,
      text: "hello",
      vector: [1.0, 0.0],
      category: "a",
      ts: 100L,
      public: true,
    },
    {
      id: 2UL,
      text: "world",
      vector: [0.0, 1.0],
      category: "b",
      ts: 200L,
      public: false,
    },
  ]
  let centroids : Centroids = {
    dim: 2,
    data: [1.0, 0.0, 0.0, 1.0], // 2 centroids
  }
  let (part_bytes, _) = encode_compact_part(docs, dim, false, Some(centroids))
  let (f_off, f_len) = decode_compact_part_trailer(part_bytes)
  let decoded_footer = decode_compact_part_footer(part_bytes, f_off, f_len)

  // 应该有两个向量分区
  assert_eq(decoded_footer.has("vec:part:0"), true)
  assert_eq(decoded_footer.has("vec:part:1"), true)

  let p0_sec = decoded_footer.get("vec:part:0").unwrap()
  let p0_bytes = read_compact_section(part_bytes, p0_sec)
  let p0 = decode_part(p0_bytes)
  assert_eq(p0.cid, 0)
  assert_eq(p0.rows, [0])

  let p1_sec = decoded_footer.get("vec:part:1").unwrap()
  let p1_bytes = read_compact_section(part_bytes, p1_sec)
  let p1 = decode_part(p1_bytes)
  assert_eq(p1.cid, 1)
  assert_eq(p1.rows, [1])
}
