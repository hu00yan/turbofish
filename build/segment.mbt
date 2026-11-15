// segment 构建与头指针发布：对象 key 构造、JSON 读写、CAS、列/倒排/分区落盘。
//
// key 约定：
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
fn tombstone_key(ns : String, manifest_id : String) -> String {
  "\{ns}/_tombstones/\{manifest_id}.roar"
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
  let s = @utf8.decode(bs.exact_view()) catch {
    _ => raise @core.Corrupt("\{what} is not valid utf8")
  }
  @json.parse(s) catch {
    _ => raise @core.Corrupt("\{what} is not valid json")
  }
}

///|
/// 读 namespace.json：不存在返回 None，损坏 raise Corrupt。
fn[S : @store.ObjectStore] read_namespace(
  store : S,
  ns : String,
) -> @format.NamespaceMeta? raise @core.SpndError {
  match store.get(ns_meta_key(ns)) {
    Some(bs) => {
      let m = @format.namespace_from_json(bytes_to_json(bs, "namespace.json"))
      // head 以 append-only _heads/ log 为准；namespace.json 的 head 只作旧数据 fallback
      let head = @store.read_head(store, ns, m.head_manifest)
      Some({ ..m, head_manifest: head })
    }
    None => None
  }
}

///|
/// 按 manifest id 读 manifest 对象；缺失 raise NotFound。
fn[S : @store.ObjectStore] load_manifest(
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
fn[S : @store.ObjectStore] load_centroids(
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
/// 首次创建 namespace：写静态 namespace.json + schema.json。
/// head 由 append-only `_heads/` log 维护；namespace.json 的 head_manifest 只作
/// 旧数据 fallback。
fn[S : @store.ObjectStore] init_namespace(
  store : S,
  cfg : BuildConfig,
) -> Unit raise @core.SpndError {
  let meta : @format.NamespaceMeta = {
    format: @core.FORMAT_NAME,
    ns_name: cfg.ns,
    head_manifest: "",
    vec_global_version: None,
    distance_metric: if cfg.distance_metric == "" {
      "cosine"
    } else {
      cfg.distance_metric
    },
    vector_dim: cfg.vector_dim,
    vector_dtype: if cfg.use_f16 {
      "f16"
    } else {
      "f32"
    },
    k1: @core.K1,
    b: @core.BM25_B,
    fts_tokenizer: Some(@core.tokenizer_to_string(cfg.fts_tokenizer)),
  }
  let key = ns_meta_key(cfg.ns)
  let bs = json_bytes(meta.to_json())
  if !store.put_if_match(key, None, bs) {
    match store.get(key) {
      Some(_) =>
        raise @core.CommitConflict("namespace already exists: \{cfg.ns}")
      None => store.put(key, bs) // 不支持条件创建 → 单写者 fallback
    }
  }
  store.put(schema_key(cfg.ns), @format.demo_schema_json())
}

///|
/// 发布 head：先把 manifest 确认落盘，再写 append-only `_heads/{manifest_id}`，
/// 最后读最大 id 仲裁。
///
/// `expected_head` 必须是**构建 manifest 时依据的基线 head**，不是发布时刻的
/// 当前 head；否则并发写者会静默丢掉对方的新段（review P0-1）。
/// 优点：不需要 If-Match，也不需要 lock 对象；只做 create PUT + LIST。
/// 若另一写者已经发布了更大的 manifest id，则本次发布输掉 → CommitConflict。
fn[S : @store.ObjectStore] publish_head(
  store : S,
  ns : String,
  expected_head : String,
  new_head : String,
) -> Unit raise @core.SpndError {
  // S3Store.put 在非 2xx 时静默；发布前确认 manifest 真的存在，避免 head 指向
  // 不存在的对象（review P1-2）。这是一次 GET，不增加 A 类 PUT。
  let mkey = manifest_key(ns, new_head)
  match store.get(mkey) {
    Some(_) => ()
    None => raise @core.NotFound(mkey)
  }
  publish_head_expect(store, ns, expected_head, new_head)
}

///|
/// manifest `descendant` 的 parent 链上是否包含 `ancestor`。用于 head log 的
/// fork 检测：两个并发写者都基于同一基线时，后写者必须发现先写者这个 sibling。
fn[S : @store.ObjectStore] manifest_is_ancestor(
  store : S,
  ns : String,
  descendant : String,
  ancestor : String,
) -> Bool raise @core.SpndError {
  let mut cur : String? = Some(descendant)
  let mut steps = 0
  while steps < 100000 {
    let id = match cur {
      Some(x) => x
      None => return false
    }
    if id == ancestor {
      return true
    }
    let m = load_manifest(store, ns, id)
    cur = m.parent
    steps += 1
  }
  false
}

///|
/// 带显式 expected 的 append-only head 发布（并发竞争测试入口）。
fn[S : @store.ObjectStore] publish_head_expect(
  store : S,
  ns : String,
  expected_head : String,
  new_head : String,
) -> Unit raise @core.SpndError {
  // legacy namespace 只有 namespace.json.head_manifest、没有 `_heads/` 记录：
  // 必须用 expected_head 作为 fallback，否则旧数据永远 CommitConflict（P0-3）。
  let cur = @store.read_head(store, ns, expected_head)
  if cur != expected_head {
    raise @core.CommitConflict("head moved: \{expected_head} -> \{cur}")
  }
  @store.write_head(store, ns, new_head)
  let (after, newer) = @store.read_head_state(store, ns, expected_head)
  if after != new_head {
    // 失败 ⇒ 不可见：删掉自己刚写的 head 记录，避免调用方重试时同一批 docs
    // 被重复入库（review P0-1 残留窗口②）。
    store.delete(@store.head_key(ns, new_head))
    raise @core.CommitConflict("head moved: \{expected_head} -> \{after}")
  }
  // 写后 fork 检测：如果存在另一个 > expected 的 head、且它不是 new_head 的
  // ancestor，说明两个写者都通过了 pre-check（append-only max 没有原子 CAS）。
  // 后写者主动回滚自己的 head（DELETE，不是额外 PUT），让先写者的 head 生效；
  // 调用方收到 CommitConflict 后从当前 head 重建重试。这样较小 id 的写者即使
  // 先返回成功，也不会被后写者静默覆盖（review P0-1 残留窗口）。
  for h in newer {
    if h == new_head {
      continue
    }
    let is_anc = manifest_is_ancestor(store, ns, new_head, h) catch {
      _ => false
    }
    if !is_anc {
      // DELETE 在 S3Store 里也是静默的：delete + 读回验证，最多 3 次；
      // 仍失败则抛冲突（head 可能短暂指向被回滚的 manifest，需维护 GC 修复）。
      let hk = @store.head_key(ns, new_head)
      let mut tries = 0
      while tries < 3 && @store.read_head(store, ns, expected_head) == new_head {
        store.delete(hk)
        tries += 1
      }
      raise @core.CommitConflict(
        "concurrent sibling head \{h}; rolled back \{new_head}",
      )
    }
  }
  // head 指针：给读者一个 1 次 GET 的 TTL 探测面（read_head_pointer）。
  // 放在 fork 仲裁之后：回滚路径不写指针；并发写者 last-writer-wins，
  // 最坏短暂指向已回滚的 sibling manifest——仍是有效快照，见 head.mbt 注释。
  @store.write_head_pointer(store, ns, new_head)
  // 旧 head 记录可安全 GC（读者已持有自己的 manifest id）；维护任务调用 gc_heads。
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

///|
/// seg meta.json 的统计段（write_stats=true）：
/// ts min/max、category 去重升序值集（>256 个值不写）、public 出现过的值。
fn build_stats_json(
  tss : Array[Int64],
  cats : Array[String],
  pubs : Array[Bool],
) -> Json {
  let stats : Map[String, Json] = Map([])
  if tss.length() > 0 {
    let mut lo = tss[0]
    let mut hi = tss[0]
    for v in tss {
      if v < lo {
        lo = v
      }
      if v > hi {
        hi = v
      }
    }
    let tsj : Map[String, Json] = Map([])
    tsj.set("min", Json::number(lo.to_double()))
    tsj.set("max", Json::number(hi.to_double()))
    stats.set("ts", Json::object(tsj))
  }
  let sorted = cats.copy()
  sorted.sort()
  let uniq : Array[String] = Array()
  for i in 0..<sorted.length() {
    if i == 0 || sorted[i] != sorted[i - 1] {
      uniq.push(sorted[i])
    }
  }
  if uniq.length() <= 256 {
    let vals : Array[Json] = Array(capacity=uniq.length())
    for v in uniq {
      vals.push(Json::string(v))
    }
    let cj : Map[String, Json] = Map([])
    cj.set("values", Json::array(vals))
    stats.set("category", Json::object(cj))
  }
  let mut has_true = false
  let mut has_false = false
  for p in pubs {
    if p {
      has_true = true
    } else {
      has_false = true
    }
  }
  let pvals : Array[Json] = Array()
  if has_false {
    pvals.push(Json::boolean(false))
  }
  if has_true {
    pvals.push(Json::boolean(true))
  }
  let pj : Map[String, Json] = Map([])
  pj.set("values", Json::array(pvals))
  stats.set("public", Json::object(pj))
  Json::object(stats)
}

///|
/// 256 行块级 ts min/max（rows/blockstats.bin）。
fn build_blockstats(tss : Array[Int64], block_size : Int) -> Bytes {
  let blocks : Array[(Int64, Int64)] = Array()
  let mut i = 0
  while i < tss.length() {
    let end = if i + block_size < tss.length() {
      i + block_size
    } else {
      tss.length()
    }
    let mut lo = tss[i]
    let mut hi = tss[i]
    for j in i..<end {
      if tss[j] < lo {
        lo = tss[j]
      }
      if tss[j] > hi {
        hi = tss[j]
      }
    }
    blocks.push((lo, hi))
    i = end
  }
  @format.encode_blockstats(blocks, block_size, tss.length())
}

///|
/// 写 fts/blockmax.bin：每 term 按 posting 顺序切 block（block_size 条），
/// 每 block 记 (max_tf, min_dl)。顺序与 built.entries（fts dir）一一对齐。
fn build_blockmax(
  entries : Array[@format.FtsDirEntry],
  term_map : Map[String, Array[@format.Posting]],
  doc_len : Array[Int],
  block_size : Int,
) -> Bytes {
  let per : Array[Array[(Int, Int)]] = Array(capacity=entries.length())
  for e in entries {
    let posts = match term_map.get(e.term) {
      Some(a) => a
      None => []
    }
    let blocks : Array[(Int, Int)] = Array()
    let mut i = 0
    while i < posts.length() {
      let end = if i + block_size < posts.length() {
        i + block_size
      } else {
        posts.length()
      }
      let mut max_tf = 0
      let mut min_dl = 0
      let mut first = true
      for k in i..<end {
        let p = posts[k]
        if p.tf > max_tf {
          max_tf = p.tf
        }
        let dl = if p.row >= 0 && p.row < doc_len.length() {
          doc_len[p.row]
        } else {
          0
        }
        if first || dl < min_dl {
          min_dl = dl
          first = false
        }
      }
      blocks.push((max_tf, min_dl))
      i = end
    }
    per.push(blocks)
  }
  @format.encode_blockmax(per, block_size)
}

///|
/// 写一个 segment（docs[start..end)）的全部对象并返回 manifest 元数据：
/// - rows/id|text|category|ts|public|vector.bin：六列编码；配置开关控制
///   category 字典 / public 位图 / 向量存储方式（VF16/VSq8/VPq16）
/// - fts/dir.bin + fts/postings.bin + fts/doc_len.bin；可选 fts/blockmax.bin
/// - vec/part-{cid}.bin：按 cosine 最近中心分配；VSq8 用整段同一套量化参数，
///   VPq16 用整段训练的码本（保证列与分区量化一致）
/// - meta.json：id/row_count/min_id/max_id/partitions + 可选 id_encoding/stats/
///   vec_storage
fn[S : @store.ObjectStore] write_segment(
  store : S,
  cfg : BuildConfig,
  cent : @format.Centroids,
  docs : Array[@core.Doc],
  start : Int,
  end : Int,
) -> @format.SegmentMeta {
  let n = end - start
  let seg_id = new_segment_id()
  let segp = "\{cfg.ns}/_segments/\{seg_id}"
  let dim = docs[start].vector.length()
  let use_global = cfg.global_vec_parts && cfg.vec_storage == VF16
  let ids : Array[UInt64] = Array(capacity=n)
  let texts : Array[String] = Array(capacity=n)
  let cats : Array[String] = Array(capacity=n)
  let tss : Array[Int64] = Array(capacity=n)
  let pubs : Array[Bool] = Array(capacity=n)
  let flat : Array[Float] = Array(capacity=n * dim)
  let doc_len : Array[Int] = Array(capacity=n)
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
    // fts：段内行号 r + tf（按行号升序追加，encode_fts 的 delta 恒 >= 1）
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
          let arr : Array[@format.Posting] = Array()
          arr.push(posting)
          term_map.set(kv.0, arr)
        }
      }
    }
  }
  // IVF 性能：写入前可选 L2 归一化，查询侧 cosine = dot（省两次 norm）
  let enc_flat = if cfg.normalize_vecs { pq_normalize(flat, dim) } else { flat }
  let mut size_bytes = 0
  // rows/id.bin（始终 u64 列；dense 标记在 meta.json）
  let bs_id = @format.encode_col(@format.ColU64(ids))
  store.put("\{segp}/rows/id.bin", bs_id)
  size_bytes += bs_id.length()
  // text 始终普通字符串列；category 由 use_dict_cols 控制
  let bs_text = @format.encode_col_str_plain(texts)
  store.put("\{segp}/rows/text.bin", bs_text)
  size_bytes += bs_text.length()
  let bs_cat = if cfg.use_dict_cols {
    @format.encode_col(@format.ColStr(cats))
  } else {
    @format.encode_col_str_plain(cats)
  }
  store.put("\{segp}/rows/category.bin", bs_cat)
  size_bytes += bs_cat.length()
  let bs_ts = @format.encode_col(@format.ColI64(tss))
  store.put("\{segp}/rows/ts.bin", bs_ts)
  size_bytes += bs_ts.length()
  let bs_pub = if cfg.use_bool_bitmap {
    @format.encode_col(@format.ColBool(pubs))
  } else {
    @format.encode_col_bool_plain(pubs)
  }
  store.put("\{segp}/rows/public.bin", bs_pub)
  size_bytes += bs_pub.length()
  let partitions : Array[Json] = Array()
  // 全局 IVF 模式：向量只存一份（global part），不写 rows/vector.bin
  if !use_global {
    // 向量列 + 分区（按 vec_storage 选择编码）
    let bs_vec = match cfg.vec_storage {
      VF16 => @format.encode_vec_col(dim, enc_flat, cfg.use_f16)
      VSq8 => {
        let (mins, scales) = @format.sq8_params_of(dim, enc_flat)
        @format.encode_vec_col_sq8(dim, enc_flat, mins, scales)
      }
      VPq16 => @format.encode_vec_col(dim, enc_flat, cfg.use_f16)
    }
    store.put("\{segp}/rows/vector.bin", bs_vec)
    size_bytes += bs_vec.length()
  }
  // fts/*
  let lists : Array[(String, Array[@format.Posting])] = Array()
  for kv in term_map.iter() {
    lists.push((kv.0, kv.1))
  }
  let built = @format.encode_fts(lists)
  // dir 头 [16..20) doc_count 回填为段行数（encode_fts 写 0，MVP 由 meta.json
  // 承载行数，这里顺手回填让 dir 自描述）
  let dir_b = Buffer()
  dir_b.write_bytesview(built.dir.exact_view(start=0, end=16))
  dir_b.write_uint_le(n.reinterpret_as_uint())
  dir_b.write_bytesview(built.dir.exact_view(start=20, end=built.dir.length()))
  let bs_dir = dir_b.to_bytes()
  store.put("\{segp}/fts/dir.bin", bs_dir)
  size_bytes += bs_dir.length()
  store.put("\{segp}/fts/postings.bin", built.postings)
  size_bytes += built.postings.length()
  let bs_dlen = @format.encode_col(@format.ColU32(doc_len))
  store.put("\{segp}/fts/doc_len.bin", bs_dlen)
  size_bytes += bs_dlen.length()
  if cfg.write_block_stats {
    let bs_bst = build_blockstats(tss, 256)
    store.put("\{segp}/rows/blockstats.bin", bs_bst)
    size_bytes += bs_bst.length()
  }
  if cfg.write_blockmax {
    let bs_blk = build_blockmax(built.entries, term_map, doc_len, 128)
    store.put("\{segp}/fts/blockmax.bin", bs_blk)
    size_bytes += bs_blk.length()
  }
  // 全局 IVF 模式：分区数据已由 global part 承载，跳过 per-segment parts
  if !use_global {
    // vec/part-{cid}.bin：cosine 最近中心分配
    let k = cent.k()
    let adim = if cent.dim > 0 { cent.dim } else { dim }
    let part_rows : Array[Array[Int]] = Array(capacity=k)
    for _ in 0..<k {
      part_rows.push(Array())
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
    // 量化参数/码本：整段一套（列与分区一致，暴力对照才有意义）
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
    // PQ16 共享码本：每段只写一次（避免每个 part 重复 256×dim f32）
    if cfg.vec_storage == VPq16 {
      let bs_cb = @format.encode_pq_codebook(dim, pq_m, pq_codebooks)
      store.put("\{segp}/vec/pq-codebook.bin", bs_cb)
      size_bytes += bs_cb.length()
    }
    for c in 0..<k {
      let rows = part_rows[c]
      if rows.length() == 0 {
        continue
      }
      let data : Array[Float] = Array(capacity=rows.length() * dim)
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
          let part_codes : Array[UInt] = Array(
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
      store.put("\{segp}/vec/part-\{c}.bin", bs_part)
      size_bytes += bs_part.length()
      partitions.push(Json::number(c.to_double()))
    }
  }
  // meta.json
  let mj : Map[String, Json] = Map([])
  mj.set("id", Json::string(seg_id))
  mj.set("row_count", Json::number(n.to_double()))
  mj.set("min_id", Json::number(min_id.to_double()))
  mj.set("max_id", Json::number(max_id.to_double()))
  mj.set("partitions", Json::array(partitions))
  if cfg.write_fts_bloom {
    let terms : Array[String] = Array()
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
  store.put("\{segp}/meta.json", bs_meta)
  size_bytes += bs_meta.length()
  { id: seg_id, row_count: n, min_id, max_id, doc_len_sum, size_bytes }
}
