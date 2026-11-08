// segment 构建与头指针发布：对象 key 构造、JSON 读写、CAS、列/倒排/分区落盘。
//
// key 约定（与 NOTES.md 第 2 节对象布局一一对应）：
//   {ns}/_meta/namespace.json
//   {ns}/_meta/schema.json
//   {ns}/_manifest/{manifest_id}.json        manifest_id 存 next_manifest_id() 全名
//   {ns}/_segments/{seg_id}/...
//   {ns}/_centroids/{centroid_version}.bin   centroid_version 存 next_centroid_version() 全名
// manifest 的 head_manifest / centroid_version 字段保存上述完整 id 字符串，
// 读路径按 "{ns}/_manifest/\{head_manifest}.json" 等拼 key 即可。

///|
fn ns_meta_key(ns : String) -> String {
  "\{ns}/_meta/namespace.json"
}

///|
fn schema_key(ns : String) -> String {
  "\{ns}/_meta/schema.json"
}

///|
fn manifest_key(ns : String, manifest_id : String) -> String {
  "\{ns}/_manifest/\{manifest_id}.json"
}

///|
fn centroids_key(ns : String, centroid_version : String) -> String {
  "\{ns}/_centroids/\{centroid_version}.bin"
}

///|
/// Json → Bytes（UTF-8）。注：Json 枚举定义在 prelude（builtin），裸用；
/// @json 包只提供 parse。
fn json_bytes(j : Json) -> Bytes {
  @utf8.encode(j.stringify())
}

///|
/// Bytes → Json；编码/解析失败统一转 Corrupt。
fn bytes_to_json(bs : Bytes, what : String) -> Json raise @core.SpndError {
  let s = @utf8.decode(bs.view()) catch {
    _ => raise @core.Corrupt("\{what} is not valid utf8")
  }
  @json.parse(s) catch {
    _ => raise @core.Corrupt("\{what} is not valid json")
  }
}

///|
/// 读 namespace.json：不存在返回 None，损坏 raise Corrupt。
fn read_namespace[S : @store.ObjectStore](
  store : S,
  ns : String,
) -> @format.NamespaceMeta? raise @core.SpndError {
  match store.get(ns_meta_key(ns)) {
    Some(bs) => Some(@format.namespace_from_json(bytes_to_json(bs, "namespace.json")))
    None => None
  }
}

///|
/// 按 manifest id 读 manifest 对象；缺失 raise NotFound。
fn load_manifest[S : @store.ObjectStore](
  store : S,
  ns : String,
  manifest_id : String,
) -> @format.ManifestData raise @core.SpndError {
  let key = manifest_key(ns, manifest_id)
  match store.get(key) {
    Some(bs) => @format.manifest_from_json(bytes_to_json(bs, "manifest"))
    None => raise @core.NotFound(key)
  }
}

///|
/// 按 centroid_version 读中心对象；缺失 raise NotFound。
fn load_centroids[S : @store.ObjectStore](
  store : S,
  ns : String,
  centroid_version : String,
) -> @format.Centroids raise @core.SpndError {
  let key = centroids_key(ns, centroid_version)
  match store.get(key) {
    Some(bs) => @format.decode_centroids(bs)
    None => raise @core.NotFound(key)
  }
}

///|
/// 首次创建 namespace：namespace.json（head_manifest 占位 ""）+ schema.json。
/// 占位写用 put_if_match(expected=None) 独占创建；并发创建时后者 raise
/// CommitConflict。
fn init_namespace[S : @store.ObjectStore](
  store : S,
  cfg : BuildConfig,
) -> Unit raise @core.SpndError {
  let meta : @format.NamespaceMeta = {
    format: @core.FORMAT_NAME,
    namespace: cfg.ns,
    head_manifest: "",
    distance_metric: "cosine",
    vector_dim: cfg.vector_dim,
    vector_dtype: if cfg.use_f16 {
      "f16"
    } else {
      "f32"
    },
    k1: @core.K1,
    b: @core.BM25_B,
  }
  let ok = store.put_if_match(ns_meta_key(cfg.ns), None, json_bytes(meta.to_json()))
  if !ok {
    raise @core.CommitConflict("namespace already exists: \{cfg.ns}")
  }
  store.put(schema_key(cfg.ns), @format.demo_schema_json())
}

///|
/// CAS 发布头指针：读旧 namespace.json → 仅更新 head_manifest 字段 → put 回去。
///
/// CAS 语义（NOTES.md 第 3 节）：expected = 旧 head_manifest 字符串（对象内
/// 自带的逻辑期望值，下次发布可从 namespace.json 读到）。通用 ObjectStore
/// trait 拿不到 store 的内部版本号（如 MemStore 的 "v3"），因此 put_if_match
/// 返回 false 时重读 namespace.json 仲裁：
/// - head 已变（真并发冲突）→ raise CommitConflict；
/// - head 未变（store 按内部版本语义拒绝，MVP 单进程）→ 读改写一致，用 put 落盘。
fn publish_head[S : @store.ObjectStore](
  store : S,
  ns : String,
  new_head : String,
) -> Unit raise @core.SpndError {
  let key = ns_meta_key(ns)
  let meta = match read_namespace(store, ns) {
    Some(m) => m
    None => raise @core.NotFound(key)
  }
  let old_head = meta.head_manifest
  let updated : @format.NamespaceMeta = {
    format: meta.format,
    namespace: meta.namespace,
    head_manifest: new_head,
    distance_metric: meta.distance_metric,
    vector_dim: meta.vector_dim,
    vector_dtype: meta.vector_dtype,
    k1: meta.k1,
    b: meta.b,
  }
  let bs = json_bytes(updated.to_json())
  if store.put_if_match(key, Some(old_head), bs) {
    return
  }
  // put_if_match 被拒：重读仲裁是逻辑冲突还是版本语义差异
  let cur_head = match read_namespace(store, ns) {
    Some(m) => m.head_manifest
    None => raise @core.Corrupt("namespace.json vanished during publish")
  }
  if cur_head != old_head {
    raise @core.CommitConflict("head moved: \{old_head} -> \{cur_head}")
  }
  store.put(key, bs)
}

///|
/// 写一个 segment（docs[start..end)）的全部对象并返回 manifest 元数据：
/// - rows/id|text|category|ts|public|vector.bin：六列编码（vector 行主序拼接，
///   按 cfg.use_f16 可选 f16 量化）
/// - fts/dir.bin + fts/postings.bin：encode_fts（dir 头 doc_count 回填为段行数）；
///   fts/doc_len.bin：ColU32（每行 token 数）
/// - vec/part-{cid}.bin：每行按 cosine 最近中心分配（查询侧同语义），
///   只写非空分区，meta.json partitions 为实际写出的 cid 升序列表
/// - meta.json：{"id","row_count","min_id","max_id","partitions"}（JSON 数字）
/// size_bytes = 该段所有对象字节数之和（含 meta.json）。
fn write_segment[S : @store.ObjectStore](
  store : S,
  cfg : BuildConfig,
  cent : @format.Centroids,
  docs : Array[@core.Doc],
  start : Int,
  end : Int,
) -> @format.SegmentMeta raise @core.SpndError {
  let n = end - start
  let seg_id = @core.next_segment_id()
  let segp = "\{cfg.ns}/_segments/\{seg_id}"
  let dim = docs[start].vector.length()
  let ids : Array[UInt64] = Array::new(capacity=n)
  let texts : Array[String] = Array::new(capacity=n)
  let cats : Array[String] = Array::new(capacity=n)
  let tss : Array[Int64] = Array::new(capacity=n)
  let pubs : Array[Bool] = Array::new(capacity=n)
  let flat : Array[Float] = Array::new(capacity=n * dim)
  let doc_len : Array[Int] = Array::new(capacity=n)
  let term_map : Map[String, Array[@format.Posting]] = Map::new()
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
    // fts：段内行号 r + tf（按行号升序追加，encode_fts 的 delta 恒 >= 1）
    let toks = @core.tokenize(d.text)
    doc_len.push(toks.length())
    doc_len_sum += toks.length()
    let row_tf : Map[String, Int] = Map::new()
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
  let mut size_bytes = 0
  // rows/*.bin
  let bs_id = @format.encode_col(@format.ColU64(ids))
  store.put("\{segp}/rows/id.bin", bs_id)
  size_bytes += bs_id.length()
  let bs_text = @format.encode_col(@format.ColStr(texts))
  store.put("\{segp}/rows/text.bin", bs_text)
  size_bytes += bs_text.length()
  let bs_cat = @format.encode_col(@format.ColStr(cats))
  store.put("\{segp}/rows/category.bin", bs_cat)
  size_bytes += bs_cat.length()
  let bs_ts = @format.encode_col(@format.ColI64(tss))
  store.put("\{segp}/rows/ts.bin", bs_ts)
  size_bytes += bs_ts.length()
  let bs_pub = @format.encode_col(@format.ColBool(pubs))
  store.put("\{segp}/rows/public.bin", bs_pub)
  size_bytes += bs_pub.length()
  let bs_vec = @format.encode_vec_col(dim, flat, cfg.use_f16)
  store.put("\{segp}/rows/vector.bin", bs_vec)
  size_bytes += bs_vec.length()
  // fts/*
  let lists : Array[(String, Array[@format.Posting])] = Array::new()
  for kv in term_map.iter() {
    lists.push((kv.0, kv.1))
  }
  let built = @format.encode_fts(lists)
  // dir 头 [16..20) doc_count 回填为段行数（encode_fts 写 0，MVP 由 meta.json
  // 承载行数，这里顺手回填让 dir 自描述）
  let dir_b = Buffer()
  dir_b.write_bytesview(built.dir.view(start=0, end=16))
  dir_b.write_uint_le(n.to_uint())
  dir_b.write_bytesview(built.dir.view(start=20, end=built.dir.length()))
  let bs_dir = dir_b.to_bytes()
  store.put("\{segp}/fts/dir.bin", bs_dir)
  size_bytes += bs_dir.length()
  store.put("\{segp}/fts/postings.bin", built.postings)
  size_bytes += built.postings.length()
  let bs_dlen = @format.encode_col(@format.ColU32(doc_len))
  store.put("\{segp}/fts/doc_len.bin", bs_dlen)
  size_bytes += bs_dlen.length()
  // vec/part-{cid}.bin：cosine 最近中心分配
  let k = cent.k()
  let adim = if cent.dim > 0 {
    cent.dim
  } else {
    dim
  }
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
  let partitions : Array[Json] = Array::new()
  for c in 0..<k {
    let rows = part_rows[c]
    if rows.length() == 0 {
      continue
    }
    let data : Array[Float] = Array::new(capacity=rows.length() * dim)
    for r in rows {
      let v = docs[start + r].vector
      for f in v {
        data.push(f)
      }
    }
    let bs_part = @format.encode_part({ cid: c, rows, dim, data }, cfg.use_f16)
    store.put("\{segp}/vec/part-\{c}.bin", bs_part)
    size_bytes += bs_part.length()
    partitions.push(Json::number(c.to_double()))
  }
  // meta.json
  let mj : Map[String, Json] = Map::new()
  mj.set("id", Json::string(seg_id))
  mj.set("row_count", Json::number(n.to_double()))
  mj.set("min_id", Json::number(min_id.to_double()))
  mj.set("max_id", Json::number(max_id.to_double()))
  mj.set("partitions", Json::array(partitions))
  let bs_meta = json_bytes(Json::object(mj))
  store.put("\{segp}/meta.json", bs_meta)
  size_bytes += bs_meta.length()
  {
    id: seg_id,
    row_count: n,
    min_id,
    max_id,
    doc_len_sum,
    size_bytes,
  }
}
