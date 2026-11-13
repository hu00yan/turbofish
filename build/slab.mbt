// SlabV2 单文件段存储写入与读取（Single-file segment builder & reader）。
//
// 提供 pluggable SegmentFormat 支持：
// - LegacyMultiFile: 传统的每段 5+ 个碎片文件布局（rows/id.bin, rows/text.bin 等）
// - SlabV2: 单个 segment.slab 紧凑文件布局，包含 Header, Contiguous Data Blocks, Index Table

///|
pub fn segment_slab_key(ns : String, seg_id : String) -> String {
  "\{ns}/_segments/\{seg_id}/segment.slab"
}

///|
#derive(Debug)
pub(all) struct SlabBuilder {
  components : Array[@format.SlabComponentPayload]
}

///|
pub fn SlabBuilder::new() -> SlabBuilder {
  { components: Array::new() }
}

///|
pub fn SlabBuilder::add(
  self : SlabBuilder,
  name : String,
  data : Bytes,
  row_count : Int,
) -> Unit {
  self.components.push(@format.SlabComponentPayload::new(name, data, row_count))
}

///|
pub fn SlabBuilder::build(
  self : SlabBuilder,
  index_at_end~ : Bool = true,
) -> (Bytes, @format.SlabIndex) {
  @format.encode_slab(self.components, index_at_end~)
}

///|
/// 通过 1 次 Range GET 读取位于固定偏移 14 处的 Index Header。
pub fn[S : @store.ObjectStore] read_slab_index_from_start(
  store : S,
  ns : String,
  seg_id : String,
  prefetch_len? : Int,
) -> @format.SlabIndex raise @core.SpndError {
  let key = segment_slab_key(ns, seg_id)
  let plen = match prefetch_len {
    Some(l) => l
    None => 1024
  }
  match store.get_range(key, 0, plen) {
    Some(bs) => {
      let (_ver, index) = @format.decode_slab_index_from_header_bytes(bs)
      index
    }
    None => raise @core.NotFound(key)
  }
}

///|
/// 通过 1 次 Range GET 读取位于文件末尾的 Trailer + Index Table。
pub fn[S : @store.ObjectStore] read_slab_index_from_tail(
  store : S,
  ns : String,
  seg_id : String,
  size_bytes : Int,
  tail_len? : Int,
) -> @format.SlabIndex raise @core.SpndError {
  let key = segment_slab_key(ns, seg_id)
  let tlen = match tail_len {
    Some(l) => l
    None => if size_bytes < 1024 { size_bytes } else { 1024 }
  }
  match store.get_range(key, size_bytes - tlen, tlen) {
    Some(tail_bs) =>
      @format.decode_slab_index_from_tail_bytes(tail_bs, size_bytes)
    None => raise @core.NotFound(key)
  }
}

///|
/// 自适应单次 Range GET 读取 Slab Index：
/// 1. 先尝试拉取头部 [0..1024)；
/// 2. 若 index_offset == 14（固定偏移），则在同一响应内完成解码（1 次请求）；
/// 3. 若 index_offset 位于末尾，则按 size_bytes 拉取末尾完成解码。
pub fn[S : @store.ObjectStore] read_slab_index(
  store : S,
  ns : String,
  seg_id : String,
  size_bytes : Int,
) -> @format.SlabIndex raise @core.SpndError {
  let key = segment_slab_key(ns, seg_id)
  let prefetch_len = if size_bytes < 1024 { size_bytes } else { 1024 }
  match store.get_range(key, 0, prefetch_len) {
    Some(hdr_bs) => {
      let (_ver, index_offset) = @format.decode_slab_header(hdr_bs)
      let off = index_offset.to_int()
      if off == @format.SLAB_HEADER_LEN {
        @format.decode_slab_index(hdr_bs, @format.SLAB_HEADER_LEN)
      } else {
        read_slab_index_from_tail(store, ns, seg_id, size_bytes)
      }
    }
    None => raise @core.NotFound(key)
  }
}

///|
/// 按 SlabEntry 精确范围读取单一组件的原始字节切片。
pub fn[S : @store.ObjectStore] read_slab_component(
  store : S,
  ns : String,
  seg_id : String,
  entry : @format.SlabEntry,
) -> Bytes raise @core.SpndError {
  let key = segment_slab_key(ns, seg_id)
  let off = entry.offset.to_int()
  let len = entry.length.to_int()
  match store.get_range(key, off, len) {
    Some(bs) => bs
    None => raise @core.NotFound("\{key} range [\{off}, \{off + len})")
  }
}

///|
/// 按组件名称通过 Index 范围读取单一组件原始字节。
pub fn[S : @store.ObjectStore] read_slab_component_by_name(
  store : S,
  ns : String,
  seg_id : String,
  index : @format.SlabIndex,
  name : String,
) -> Bytes raise @core.SpndError {
  match index.get(name) {
    Some(entry) => read_slab_component(store, ns, seg_id, entry)
    None =>
      raise @core.NotFound(
        "component '\{name}' not in \{segment_slab_key(ns, seg_id)}",
      )
  }
}

///|
/// 范围读取并解码列数据（ColData）。
pub fn[S : @store.ObjectStore] read_slab_column(
  store : S,
  ns : String,
  seg_id : String,
  index : @format.SlabIndex,
  col_name : String,
) -> @format.ColData raise @core.SpndError {
  let bs = read_slab_component_by_name(store, ns, seg_id, index, col_name)
  @format.decode_col(bs)
}

///|
/// 范围读取并解码全文倒排目录（FtsDirEntry）。
pub fn[S : @store.ObjectStore] read_slab_fts_dir(
  store : S,
  ns : String,
  seg_id : String,
  index : @format.SlabIndex,
) -> Array[@format.FtsDirEntry] raise @core.SpndError {
  let bs = read_slab_component_by_name(store, ns, seg_id, index, "fts/dir")
  @format.decode_fts_dir(bs)
}

///|
/// BM25 查询路径：直接从 segment.slab 内部对应的 postings 区间按需读取单个 term 的 postings 切片。
/// （无独立 postings.bin 文件，零对象碎片）。
pub fn[S : @store.ObjectStore] read_slab_fts_postings_range(
  store : S,
  ns : String,
  seg_id : String,
  index : @format.SlabIndex,
  term_offset : Int,
  term_size : Int,
) -> Bytes raise @core.SpndError {
  let entry = match index.get("fts/postings") {
    Some(e) => e
    None =>
      raise @core.NotFound(
        "fts/postings not in \{segment_slab_key(ns, seg_id)}",
      )
  }
  let key = segment_slab_key(ns, seg_id)
  let abs_off = entry.offset.to_int() + 16 + term_offset
  match store.get_range(key, abs_off, term_size) {
    Some(bs) => bs
    None =>
      raise @core.NotFound(
        "\{key} postings range [\{abs_off}, \{abs_off + term_size})",
      )
  }
}

///|
/// 构建并写入 SlabV2 单文件段（segment.slab 与 meta.json）。
/// 所有 ID 列、属性列、倒排索引及元数据紧凑拼接在单一 segment.slab 内。
pub fn[S : @store.ObjectStore] write_segment_slab(
  store : S,
  cfg : BuildConfig,
  cent : @format.Centroids,
  docs : Array[@core.Doc],
  start : Int,
  end : Int,
  index_at_end~ : Bool = true,
) -> @format.SegmentMeta {
  let n = end - start
  let seg_id = new_segment_id()
  let segp = "\{cfg.ns}/_segments/\{seg_id}"
  let dim = docs[start].vector.length()
  let use_global = cfg.global_vec_parts && cfg.vec_storage == VF16

  let ids : Array[UInt64] = Array::new(capacity=n)
  let texts : Array[String] = Array::new(capacity=n)
  let cats : Array[String] = Array::new(capacity=n)
  let tss : Array[Int64] = Array::new(capacity=n)
  let pubs : Array[Bool] = Array::new(capacity=n)
  let flat : Array[Float] = Array::new(capacity=n * dim)
  let doc_len : Array[Int] = Array::new(capacity=n)
  let term_map : Map[String, Array[@format.Posting]] = Map([])
  let mut min_id = docs[start].id
  let mut max_id = docs[start].id
  let mut doc_len_sum = 0

  for r in 0..<n {
    let d = docs[start + r]
    ids.push(d.id)
    if d.id < min_id {
      min_id = d.id
    }
    if d.id > max_id {
      max_id = d.id
    }
    texts.push(d.text)
    cats.push(d.category)
    tss.push(d.ts)
    pubs.push(d.public)
    for f in d.vector {
      flat.push(f)
    }
    let toks = @core.tokenize_with(cfg.fts_tokenizer, d.text)
    doc_len.push(toks.length())
    doc_len_sum += toks.length()
    let row_tf : Map[String, Int] = Map([])
    for t in toks {
      let c = match row_tf.get(t) {
        Some(c) => c
        None => 0
      }
      row_tf.set(t, c + 1)
    }
    for kv in row_tf.iter() {
      let posting : @format.Posting = { row: r, tf: kv.1 }
      match term_map.get(kv.0) {
        Some(arr) => arr.push(posting)
        None => {
          let arr : Array[@format.Posting] = Array::new()
          arr.push(posting)
          term_map.set(kv.0, arr)
        }
      }
    }
  }

  let enc_flat = if cfg.normalize_vecs { pq_normalize(flat, dim) } else { flat }
  let components : Array[@format.SlabComponentPayload] = Array::new()

  // 1. ID column
  let bs_id = @format.encode_col(@format.ColU64(ids))
  components.push(@format.SlabComponentPayload::new("id", bs_id, n))

  // 2. Text column
  let bs_text = @format.encode_col_str_plain(texts)
  components.push(@format.SlabComponentPayload::new("text", bs_text, n))

  // 3. Category column
  let bs_cat = if cfg.use_dict_cols {
    @format.encode_col(@format.ColStr(cats))
  } else {
    @format.encode_col_str_plain(cats)
  }
  components.push(@format.SlabComponentPayload::new("category", bs_cat, n))

  // 4. TS column
  let bs_ts = @format.encode_col(@format.ColI64(tss))
  components.push(@format.SlabComponentPayload::new("ts", bs_ts, n))

  // 5. Public column
  let bs_pub = if cfg.use_bool_bitmap {
    @format.encode_col(@format.ColBool(pubs))
  } else {
    @format.encode_col_bool_plain(pubs)
  }
  components.push(@format.SlabComponentPayload::new("public", bs_pub, n))

  // 6. Vector column (if not global)
  if !use_global {
    let bs_vec = match cfg.vec_storage {
      VF16 => @format.encode_vec_col(dim, enc_flat, cfg.use_f16)
      VSq8 => {
        let (mins, scales) = @format.sq8_params_of(dim, enc_flat)
        @format.encode_vec_col_sq8(dim, enc_flat, mins, scales)
      }
      VPq16 => @format.encode_vec_col(dim, enc_flat, cfg.use_f16)
    }
    components.push(@format.SlabComponentPayload::new("vector", bs_vec, n))
  }

  // 7. FTS components
  let lists : Array[(String, Array[@format.Posting])] = Array::new()
  for kv in term_map.iter() {
    lists.push((kv.0, kv.1))
  }
  let built = @format.encode_fts(lists)
  let dir_b = Buffer()
  dir_b.write_bytesview(built.dir.view(start=0, end=16))
  dir_b.write_uint_le(n.reinterpret_as_uint())
  dir_b.write_bytesview(built.dir.view(start=20, end=built.dir.length()))
  let bs_dir = dir_b.to_bytes()

  components.push(
    @format.SlabComponentPayload::new("fts/dir", bs_dir, lists.length()),
  )
  components.push(
    @format.SlabComponentPayload::new(
      "fts/postings",
      built.postings,
      built.entries.length(),
    ),
  )

  let bs_dlen = @format.encode_col(@format.ColU32(doc_len))
  components.push(@format.SlabComponentPayload::new("fts/doc_len", bs_dlen, n))

  // 8. Optional block stats & blockmax
  if cfg.write_block_stats {
    let bs_bst = build_blockstats(tss, 256)
    components.push(
      @format.SlabComponentPayload::new("rows/blockstats", bs_bst, n),
    )
  }
  if cfg.write_blockmax {
    let bs_blk = build_blockmax(built.entries, term_map, doc_len, 128)
    components.push(
      @format.SlabComponentPayload::new("fts/blockmax", bs_blk, built.entries.length()),
    )
  }

  // 9. Vector partitions (if not global)
  let partitions : Array[Json] = Array::new()
  if !use_global {
    let k = cent.k()
    let adim = if cent.dim > 0 { cent.dim } else { dim }
    let part_rows : Array[Array[Int]] = Array::new(capacity=k)
    for _ in 0..<k {
      part_rows.push(Array::new())
    }
    if k > 0 {
      for r in 0..<n {
        let v = docs[start + r].vector
        let mut best = 0
        let mut best_d = @core.cosine_dist_f32(v, 0, cent.data, 0, adim)
        for c in 1..<k {
          let d = @core.cosine_dist_f32(v, 0, cent.data, c * adim, adim)
          if d < best_d {
            best_d = d
            best = c
          }
        }
        part_rows[best].push(r)
      }
    }
    let (sq8_mins, sq8_scales) = if cfg.vec_storage == VSq8 {
      @format.sq8_params_of(dim, enc_flat)
    } else {
      ([], [])
    }
    let pq_m = if cfg.vec_storage == VPq16 { pq_m_for(dim) } else { 0 }
    let (pq_codebooks, pq_codes) = if cfg.vec_storage == VPq16 {
      train_pq(dim, enc_flat)
    } else {
      ([], [])
    }
    if cfg.vec_storage == VPq16 {
      let bs_cb = @format.encode_pq_codebook(dim, pq_m, pq_codebooks)
      components.push(
        @format.SlabComponentPayload::new("vec/pq-codebook", bs_cb, pq_m),
      )
    }
    for c in 0..<k {
      let rows = part_rows[c]
      if rows.length() == 0 {
        continue
      }
      let data : Array[Float] = Array::new(capacity=rows.length() * dim)
      for r in rows {
        for d in 0..<dim {
          data.push(enc_flat[r * dim + d])
        }
      }
      let bs_part = match cfg.vec_storage {
        VF16 => @format.encode_part({ cid: c, rows, dim, data }, cfg.use_f16)
        VSq8 =>
          @format.encode_part_sq8(
            { cid: c, rows, dim, data },
            sq8_mins,
            sq8_scales,
          )
        VPq16 => {
          let part_codes : Array[UInt] = Array::new(
            capacity=rows.length() * pq_m,
          )
          for r in rows {
            for s in 0..<pq_m {
              part_codes.push(pq_codes[r * pq_m + s])
            }
          }
          @format.encode_pq_part_shared(rows, dim, pq_m, part_codes)
        }
      }
      components.push(
        @format.SlabComponentPayload::new("vec/part-\{c}", bs_part, rows.length()),
      )
      partitions.push(Json::number(c.to_double()))
    }
  }

  // 10. Meta JSON
  let mj : Map[String, Json] = Map([])
  mj.set("id", Json::string(seg_id))
  mj.set("row_count", Json::number(n.to_double()))
  mj.set("min_id", Json::number(min_id.to_double()))
  mj.set("max_id", Json::number(max_id.to_double()))
  mj.set("partitions", Json::array(partitions))
  mj.set("format", Json::string("slab_v2"))
  if cfg.write_fts_bloom {
    let terms : Array[String] = Array::new()
    for kv in term_map.iter() {
      terms.push(kv.0)
    }
    if !terms.is_empty() {
      let bl = @format.build_bloom(terms, 10)
      mj.set("bloom", Json::string(@format.bloom_to_hex(bl)))
      mj.set("bloom_m", Json::number(bl.m.to_double()))
      mj.set("bloom_k", Json::number(bl.k.to_double()))
    }
  }
  if cfg.id_dense {
    let mut dense = true
    for r in 0..<n {
      if ids[r] != min_id + r.to_uint64() {
        dense = false
        break
      }
    }
    if dense {
      mj.set("id_encoding", Json::string("dense_u64"))
    }
  }
  if cfg.write_stats {
    mj.set("stats", build_stats_json(tss, cats, pubs))
  }
  let vs = match cfg.vec_storage {
    VF16 => if cfg.use_f16 { "f16" } else { "f32" }
    VSq8 => "sq8"
    VPq16 => "pq16"
  }
  mj.set("vec_storage", Json::string(vs))
  if cfg.normalize_vecs {
    mj.set("vec_normalized", Json::boolean(true))
  }
  let bs_meta = json_bytes(Json::object(mj))
  components.push(@format.SlabComponentPayload::new("meta", bs_meta, 1))

  // 打包为单一 segment.slab
  let (slab_bytes, _index) = @format.encode_slab(components, index_at_end~)
  store.put(segment_slab_key(cfg.ns, seg_id), slab_bytes)
  store.put("\{segp}/meta.json", bs_meta)

  let size_bytes = slab_bytes.length()
  { id: seg_id, row_count: n, min_id, max_id, doc_len_sum, size_bytes }
}

///|
/// 可插拔 segment 写入函数：按 SegmentFormat 自动派发至 LegacyMultiFile 或 SlabV2。
pub fn[S : @store.ObjectStore] write_segment_pluggable(
  store : S,
  cfg : BuildConfig,
  cent : @format.Centroids,
  docs : Array[@core.Doc],
  start : Int,
  end : Int,
  format : @format.SegmentFormat,
  index_at_end~ : Bool = true,
) -> @format.SegmentMeta {
  match format {
    LegacyMultiFile => write_segment(store, cfg, cent, docs, start, end)
    SlabV2 =>
      write_segment_slab(store, cfg, cent, docs, start, end, index_at_end~)
  }
}
