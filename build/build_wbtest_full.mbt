///|
using @test {assert_eq}

// ============================================================================
// 【暂不可编译】build 包完整白盒测试（6 个测试块）。
//
// 激活步骤（等集成时执行）：
//   1. store/mem.mbt 中 6 处 `impl ObjectStore for MemStore with ...` 改为
//      `pub impl ObjectStore for MemStore with ...`（MoonBit 2026：封闭 pub
//      trait 的实现跨包可见必须写 pub impl；不改任何签名与行为，moonbitlang
//      core 库全部如此写）。
//   2. 把本文件重命名为 build_wbtest_full.mbt（.disabled 后缀不会被构建系统
//      匹配，当前处于惰性状态）。
//   3. moon test -p turbofish/build → 全过。
//
// 覆盖内容：
// 1) 20 行小批次 ingest：对象齐全、列回读一致、fts dir 可查测试词、
//    part 行号并集 = 段行号、向量 f16 误差内对齐
// 2) 二次 ingest 追加：segments 数量 3+3、num_docs=40、parent 链、
//    centroid 复用（_centroids/ 对象数不变、版本号不变）、f32 精确回读
// 3) delete_docs：tombstone 合并去重升序、物理段不动
// 4) f16（test 1）/ f32（test 2）双量化路径
// 5) train_centroids：确定性、归一化、k 收缩、空输入（已另在 build_wbtest.mbt 激活）
// 6) namespace 缺失 / 尚未发布 manifest 时 delete_docs 报 NotFound
//
// 测试用包内 WbStore（CAS 语义与 MemStore 一致）代替 MemStore——ObjectStore
// 是封闭 pub trait（4145 readonly），包外无法自行实现。
// ============================================================================

///|
/// 包内测试存储：Map 模拟对象存储；put_if_match 与 MemStore 同语义
/// （expected=None 要求 key 不存在，Some(s) 比对内部版本 "v{n}"）。
priv struct WbStore {
  data : Map[String, Bytes]
  versions : Map[String, Int]
  mut next_ver : Int
  mut cas_enabled : Bool
}

///|
fn WbStore::new() -> WbStore {
  { data: Map([]), versions: Map([]), next_ver: 1, cas_enabled: true }
}

///|
fn WbStore::put_raw(self : WbStore, key : String, value : Bytes) -> Unit {
  self.data.set(key, value)
  self.versions.set(key, self.next_ver)
  self.next_ver += 1
}

///|
impl @store.ObjectStore for WbStore with fn get(self : WbStore, key : String) -> Bytes? {
  self.data.get(key)
}

///|
impl @store.ObjectStore for WbStore with fn put(
  self : WbStore,
  key : String,
  value : Bytes,
) -> Unit {
  self.put_raw(key, value)
}

///|
impl @store.ObjectStore for WbStore with fn put_if_match(
  self : WbStore,
  key : String,
  expected : String?,
  value : Bytes,
) -> Bool {
  if !self.cas_enabled {
    return false
  }
  let current = match self.versions.get(key) {
    Some(v) => Some("v\{v}")
    None => None
  }
  let ok = match (expected, current) {
    (None, None) => true
    (Some(e), Some(c)) => e == c
    _ => false
  }
  if ok {
    self.put_raw(key, value)
    true
  } else {
    false
  }
}

///|
impl @store.ObjectStore for WbStore with fn get_range(
  self : WbStore,
  key : String,
  offset : Int,
  len : Int,
) -> Bytes? {
  match self.data.get(key) {
    Some(value) => {
      let lo = if offset < 0 { 0 } else { offset }
      let hi = if offset + len > value.length() {
        value.length()
      } else {
        offset + len
      }
      if hi <= lo {
        Some(Bytes::make(0, b'\x00'))
      } else {
        let b = Buffer()
        b.write_bytesview(value.view(start=lo, end=hi))
        Some(b.to_bytes())
      }
    }
    None => None
  }
}

///|
impl @store.ObjectStore for WbStore with fn list(
  self : WbStore,
  prefix : String,
) -> Array[String] {
  let out : Array[String] = Array::new()
  for kv in self.data.iter() {
    if kv.0.has_prefix(prefix) {
      out.push(kv.0)
    }
  }
  out.sort()
  out
}

///|
impl @store.ObjectStore for WbStore with fn delete(self : WbStore, key : String) -> Unit {
  self.data.remove(key)
  self.versions.remove(key)
}

///|
impl @store.ObjectStore for WbStore with fn head_version(
  self : WbStore,
  key : String
) -> String? {
  match self.versions.get(key) {
    Some(v) => Some("v\{v}")
    None => None
  }
}

///|
/// 确定性生成 n 条 docs（Rng 种子固定；id = id_base + i，文本含 ASCII 与中文词）。
fn mkdocs(
  n : Int,
  dim : Int,
  id_base : UInt64,
  seed : UInt,
) -> Array[@core.Doc] {
  let rng = @core.Rng::new(seed)
  let words = [
    "alpha", "beta", "gamma", "delta", "search", "engine", "向量", "检索",
  ]
  let docs : Array[@core.Doc] = Array::new()
  for i in 0..<n {
    let mut text = ""
    let ntok = 5 + (rng.next_u32() % 6U).reinterpret_as_int()
    for _ in 0..<ntok {
      let w = words[(rng.next_u32() % words.length().reinterpret_as_uint()).reinterpret_as_int()]
      text = text + w + " "
    }
    let vec : Array[Float] = Array::new(capacity=dim)
    for _ in 0..<dim {
      vec.push(Float::from_double(rng.next_range(-1.0, 1.0)))
    }
    docs.push({
      id: id_base + i.to_uint64(),
      text,
      vector: vec,
      category: "cat\{i % 3}",
      ts: (1700000000 + i).to_int64(),
      public: i % 3 != 0,
    })
  }
  docs
}

///|
fn[S : @store.ObjectStore] must_get(
  store : S,
  key : String,
) -> Bytes raise @core.SpndError {
  match store.get(key) {
    Some(b) => b
    None => raise @core.NotFound("missing object: \{key}")
  }
}

///|
fn[S : @store.ObjectStore] head_manifest_of(
  store : S,
  ns : String,
) -> @format.ManifestData raise @core.SpndError {
  match read_namespace(store, ns) {
    Some(m) => load_manifest(store, ns, m.head_manifest)
    None => raise @core.NotFound("namespace missing: \{ns}")
  }
}

///|
/// 读 seg meta.json 的 partitions（cid 升序数组）。
fn[S : @store.ObjectStore] seg_partitions(
  store : S,
  segp : String,
) -> Array[Int] raise @core.SpndError {
  let j = bytes_to_json(must_get(store, "\{segp}/meta.json"), "seg meta")
  let m : Map[String, Json] = match j {
    Object(m) => m
    _ => raise @core.Corrupt("seg meta not object")
  }
  let arr = match m.get("partitions") {
    Some(Array(a)) => a
    _ => raise @core.Corrupt("seg meta partitions missing")
  }
  let out : Array[Int] = Array::new()
  for pj in arr {
    match pj {
      Number(d, ..) => out.push(d.to_int())
      _ => raise @core.Corrupt("partition not a number")
    }
  }
  out
}

///|
test "ingest small batch: objects complete and columns roundtrip" {
  let store = WbStore::new()
  let cfg : BuildConfig = {
    ns: "t1",
    segment_rows: 8,
    nlist: 4,
    use_f16: true,
    vector_dim: 8,
    write_stats: false,
    id_dense: false,
    use_dict_cols: false,
    use_bool_bitmap: false,
    vec_storage: VF16,
    write_blockmax: false,
    normalize_vecs: false,
    write_block_stats: false,
    global_vec_parts: false,
    write_fts_bloom: true,
    global_pack_size: 1,
    fts_tokenizer: @core.Word,
  }
  let docs = mkdocs(20, 8, 1UL, 7U)
  ingest(store, cfg, docs)
  // meta 对象齐全
  let _ = must_get(store, "t1/_meta/namespace.json")
  let _ = must_get(store, "t1/_meta/schema.json")
  let ns = match read_namespace(store, "t1") {
    Some(m) => m
    None => fail("namespace.json missing")
  }
  assert_eq(ns.format, @core.FORMAT_NAME)
  assert_eq(ns.ns_name, "t1")
  assert_eq(ns.distance_metric, "cosine")
  assert_eq(ns.vector_dim, 8)
  assert_eq(ns.vector_dtype, "f16")
  assert_eq(ns.k1, 1.2)
  assert_eq(ns.b, 0.75)
  assert_eq(ns.head_manifest.has_prefix("manifest-"), true)
  let manifest = load_manifest(store, "t1", ns.head_manifest)
  // 20 行、segment_rows=8 → 3 段
  assert_eq(manifest.segments.length(), 3)
  assert_eq(manifest.num_docs, 20)
  assert_eq(manifest.centroid_version.has_prefix("centroids-"), true)
  match manifest.parent {
    Some(_) => fail("first manifest should have no parent")
    None => ()
  }
  // centroids 对象：k=nlist、dim 正确
  let cent_keys = store.list("t1/_centroids/")
  assert_eq(cent_keys.length(), 1)
  let cent = @format.decode_centroids(must_get(store, cent_keys[0]))
  assert_eq(cent.k(), 4)
  assert_eq(cent.dim, 8)
  // 每段对象齐全 + 统计合理
  for sm in manifest.segments {
    let p = "t1/_segments/\{sm.id}"
    let _ = must_get(store, "\{p}/meta.json")
    let _ = must_get(store, "\{p}/rows/id.bin")
    let _ = must_get(store, "\{p}/rows/text.bin")
    let _ = must_get(store, "\{p}/rows/category.bin")
    let _ = must_get(store, "\{p}/rows/ts.bin")
    let _ = must_get(store, "\{p}/rows/public.bin")
    let _ = must_get(store, "\{p}/rows/vector.bin")
    let _ = must_get(store, "\{p}/fts/dir.bin")
    let _ = must_get(store, "\{p}/fts/postings.bin")
    let _ = must_get(store, "\{p}/fts/doc_len.bin")
    assert_eq(sm.row_count > 0, true)
    assert_eq(sm.doc_len_sum > 0, true)
    assert_eq(sm.size_bytes > 0, true)
  }
  // 段 0：列回读与输入一致
  let seg0 = manifest.segments[0]
  assert_eq(seg0.row_count, 8)
  let p0 = "t1/_segments/\{seg0.id}"
  match @format.decode_col(must_get(store, "\{p0}/rows/id.bin")) {
    @format.ColU64(arr) =>
      for i in 0..<8 {
        assert_eq(arr[i], docs[i].id)
      }
    _ => fail("id column wrong dtype")
  }
  match @format.decode_col(must_get(store, "\{p0}/rows/text.bin")) {
    @format.ColStr(arr) =>
      for i in 0..<8 {
        assert_eq(arr[i], docs[i].text)
      }
    _ => fail("text column wrong dtype")
  }
  match @format.decode_col(must_get(store, "\{p0}/rows/category.bin")) {
    @format.ColStr(arr) => assert_eq(arr[2], docs[2].category)
    _ => fail("category column wrong dtype")
  }
  match @format.decode_col(must_get(store, "\{p0}/rows/ts.bin")) {
    @format.ColI64(arr) => assert_eq(arr[3], docs[3].ts)
    _ => fail("ts column wrong dtype")
  }
  match @format.decode_col(must_get(store, "\{p0}/rows/public.bin")) {
    @format.ColBool(arr) => assert_eq(arr[3], docs[3].public)
    _ => fail("public column wrong dtype")
  }
  // vector 列（f16 路径）：量化误差在千分量级
  let (vdim, vdata) = @format.decode_vec_col(
    must_get(store, "\{p0}/rows/vector.bin"),
  )
  assert_eq(vdim, 8)
  assert_eq(vdata.length(), 64)
  for i in 0..<64 {
    let expect = docs[i / 8].vector[i % 8].to_double()
    let err = (vdata[i].to_double() - expect).abs()
    assert_eq(err < 0.01, true)
  }
  // fts：dir 能查到测试词，posting 行号/tf 与 tokenize 一致，doc_len 一致
  let dir_bs = must_get(store, "\{p0}/fts/dir.bin")
  // dir 头 doc_count 回填为段行数
  assert_eq(@core.read_u32_le(dir_bs, 16).reinterpret_as_int(), 8)
  let dir = @format.decode_fts_dir(dir_bs)
  let postings_blob = must_get(store, "\{p0}/fts/postings.bin")
  let toks0 = @core.tokenize(docs[0].text)
  let term0 = toks0[0]
  let mut tf0 = 0
  for t in toks0 {
    if t == term0 {
      tf0 += 1
    }
  }
  let mut entry0 : @format.FtsDirEntry? = None
  for e in dir {
    if e.term == term0 {
      entry0 = Some(e)
    }
  }
  match entry0 {
    Some(e) => {
      let ps = @format.read_postings(postings_blob, e)
      assert_eq(ps.length() >= 1, true)
      assert_eq(ps[0].row, 0)
      assert_eq(ps[0].tf, tf0)
    }
    None => fail("token of doc0 missing in fts dir")
  }
  match @format.decode_col(must_get(store, "\{p0}/fts/doc_len.bin")) {
    @format.ColU32(arr) => assert_eq(arr[0], toks0.length())
    _ => fail("doc_len column wrong dtype")
  }
  // vec 分区：meta partitions 升序 = 实际写出的 part 文件数；
  // 行号并集恰为 0..8；分区内向量与源行对齐（f16 误差内）
  let part_ids = seg_partitions(store, p0)
  assert_eq(part_ids.length() > 0, true)
  for i in 1..<part_ids.length() {
    assert_eq(part_ids[i - 1] < part_ids[i], true)
  }
  let vec_keys = store.list("\{p0}/vec/")
  assert_eq(vec_keys.length(), part_ids.length())
  let seen_rows : Array[Int] = Array::new()
  for cid in part_ids {
    let part = @format.decode_part(must_get(store, "\{p0}/vec/part-\{cid}.bin"))
    assert_eq(part.cid, cid)
    assert_eq(part.dim, 8)
    for i in 1..<part.rows.length() {
      assert_eq(part.rows[i - 1] < part.rows[i], true)
    }
    for j in 0..<part.rows.length() {
      let r = part.rows[j]
      seen_rows.push(r)
      for d in 0..<8 {
        let expect = docs[r].vector[d].to_double()
        let got = part.data[j * 8 + d].to_double()
        assert_eq((got - expect).abs() < 0.01, true)
      }
    }
  }
  seen_rows.sort()
  assert_eq(seen_rows.length(), 8)
  for i in 0..<8 {
    assert_eq(seen_rows[i], i)
  }
}

///|
test "second ingest appends and reuses centroids" {
  let store = WbStore::new()
  let cfg : BuildConfig = {
    ns: "t2",
    segment_rows: 8,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
    write_stats: false,
    id_dense: false,
    use_dict_cols: false,
    use_bool_bitmap: false,
    vec_storage: VF16,
    write_blockmax: false,
    normalize_vecs: false,
    write_block_stats: false,
    global_vec_parts: false,
    write_fts_bloom: true,
    global_pack_size: 1,
    fts_tokenizer: @core.Word,
  }
  let docs1 = mkdocs(20, 8, 1UL, 7U)
  ingest(store, cfg, docs1)
  let ns1 = match read_namespace(store, "t2") {
    Some(m) => m
    None => fail("namespace missing")
  }
  let m1 = load_manifest(store, "t2", ns1.head_manifest)
  let cent_keys1 = store.list("t2/_centroids/")
  assert_eq(cent_keys1.length(), 1)
  assert_eq(ns1.vector_dtype, "f32")
  let docs2 = mkdocs(20, 8, 100UL, 99U)
  ingest(store, cfg, docs2)
  let ns2 = match read_namespace(store, "t2") {
    Some(m) => m
    None => fail("namespace missing")
  }
  let m2 = load_manifest(store, "t2", ns2.head_manifest)
  // 追加：旧 3 段 + 新 3 段
  assert_eq(m2.segments.length(), 6)
  assert_eq(m2.num_docs, 40)
  match m2.parent {
    Some(p) => assert_eq(p, m1.id)
    None => fail("second manifest should link parent")
  }
  // namespace.json 其余字段在发布时保留
  assert_eq(ns2.ns_name, "t2")
  assert_eq(ns2.format, @core.FORMAT_NAME)
  assert_eq(ns2.distance_metric, "cosine")
  assert_eq(ns2.vector_dim, 8)
  assert_eq(ns2.vector_dtype, "f32")
  assert_eq(ns2.k1, 1.2)
  assert_eq(ns2.b, 0.75)
  // centroid 复用：对象数与版本号不变
  let cent_keys2 = store.list("t2/_centroids/")
  assert_eq(cent_keys2.length(), 1)
  assert_eq(cent_keys2[0], cent_keys1[0])
  assert_eq(m2.centroid_version, m1.centroid_version)
  // 最后一段（4 行，id 116..119）f32 精确回读
  let seg_last = m2.segments[m2.segments.length() - 1]
  assert_eq(seg_last.row_count, 4)
  assert_eq(seg_last.min_id, 116UL)
  assert_eq(seg_last.max_id, 119UL)
  let pl = "t2/_segments/\{seg_last.id}"
  let (vdim, vdata) = @format.decode_vec_col(
    must_get(store, "\{pl}/rows/vector.bin"),
  )
  assert_eq(vdim, 8)
  assert_eq(vdata.length(), 32)
  for i in 0..<4 {
    for d in 0..<8 {
      assert_eq(vdata[i * 8 + d], docs2[16 + i].vector[d])
    }
  }
  // f32 分区精确对齐，行号并集 = 0..4
  let part_ids = seg_partitions(store, pl)
  let seen_rows : Array[Int] = Array::new()
  for cid in part_ids {
    let part = @format.decode_part(must_get(store, "\{pl}/vec/part-\{cid}.bin"))
    for j in 0..<part.rows.length() {
      let r = part.rows[j]
      seen_rows.push(r)
      for d in 0..<8 {
        assert_eq(part.data[j * 8 + d], docs2[16 + r].vector[d])
      }
    }
  }
  seen_rows.sort()
  assert_eq(seen_rows.length(), 4)
  for i in 0..<4 {
    assert_eq(seen_rows[i], i)
  }
}

///|
test "delete_docs merges and dedups tombstones" {
  let store = WbStore::new()
  let cfg : BuildConfig = {
    ns: "t3",
    segment_rows: 8,
    nlist: 4,
    use_f16: true,
    vector_dim: 8,
    write_stats: false,
    id_dense: false,
    use_dict_cols: false,
    use_bool_bitmap: false,
    vec_storage: VF16,
    write_blockmax: false,
    normalize_vecs: false,
    write_block_stats: false,
    global_vec_parts: false,
    write_fts_bloom: true,
    global_pack_size: 1,
    fts_tokenizer: @core.Word,
  }
  let docs = mkdocs(20, 8, 1UL, 7U)
  ingest(store, cfg, docs)
  let m1 = head_manifest_of(store, "t3")
  assert_eq(m1.deleted.length(), 0)
  delete_docs(store, cfg, [2UL, 4UL, 999UL])
  let m2 = head_manifest_of(store, "t3")
  assert_eq(m2.deleted.length(), 3)
  assert_eq(m2.deleted[0], 2UL)
  assert_eq(m2.deleted[1], 4UL)
  assert_eq(m2.deleted[2], 999UL)
  match m2.parent {
    Some(p) => assert_eq(p, m1.id)
    None => fail("delete manifest should link parent")
  }
  // 物理段与统计不动
  assert_eq(m2.segments.length(), 3)
  assert_eq(m2.num_docs, 20)
  assert_eq(m2.centroid_version, m1.centroid_version)
  // 再次删除：去重 + 升序合并
  delete_docs(store, cfg, [4UL, 7UL, 4UL])
  let m3 = head_manifest_of(store, "t3")
  assert_eq(m3.deleted.length(), 4)
  assert_eq(m3.deleted[0], 2UL)
  assert_eq(m3.deleted[1], 4UL)
  assert_eq(m3.deleted[2], 7UL)
  assert_eq(m3.deleted[3], 999UL)
  match m3.parent {
    Some(p) => assert_eq(p, m2.id)
    None => fail("third manifest should link parent")
  }
}

///|
test "train_centroids deterministic normalized and clamped" {
  let docs = mkdocs(20, 8, 1UL, 42U)
  let c1 = train_centroids(docs, 4, 3)
  let c2 = train_centroids(docs, 4, 3)
  assert_eq(c1.dim, 8)
  assert_eq(c1.k(), 4)
  assert_eq(c1.data, c2.data)
  // 中心归一化（cosine 语义）
  for c in 0..<c1.k() {
    let norm = @core.norm_f32(c1.data, c * 8, 8)
    assert_eq((norm - 1.0).abs() < 1.0e-3, true)
  }
  // 少量 docs：k 收缩到样本数
  let small = train_centroids(mkdocs(3, 8, 1UL, 9U), 8, 2)
  assert_eq(small.k(), 3)
  // 空输入
  let empty = train_centroids([], 4, 3)
  assert_eq(empty.dim, 0)
  assert_eq(empty.data.length(), 0)
}

///|
test "delete_docs on missing namespace raises" {
  let store = WbStore::new()
  let cfg : BuildConfig = {
    ns: "ghost",
    segment_rows: 8,
    nlist: 4,
    use_f16: true,
    vector_dim: 8,
    write_stats: false,
    id_dense: false,
    use_dict_cols: false,
    use_bool_bitmap: false,
    vec_storage: VF16,
    write_blockmax: false,
    normalize_vecs: false,
    write_block_stats: false,
    global_vec_parts: false,
    write_fts_bloom: true,
    global_pack_size: 1,
    fts_tokenizer: @core.Word,
  }
  try {
    delete_docs(store, cfg, [1UL])
    panic()
  } catch {
    _ => ()
  }
}

///|
test "delete_docs before first publish raises" {
  let store = WbStore::new()
  // 手工放一个 head_manifest 仍为占位 "" 的 namespace.json
  let meta : @format.NamespaceMeta = {
    format: @core.FORMAT_NAME,
    ns_name: "fresh",
    head_manifest: "",
    vec_global_version: None,
    distance_metric: "cosine",
    vector_dim: 8,
    vector_dtype: "f16",
    k1: 1.2,
    b: 0.75,
    fts_tokenizer: None,
  }
  store.put(
    "fresh/_meta/namespace.json",
    @utf8.encode(meta.to_json().stringify()),
  )
  let cfg : BuildConfig = {
    ns: "fresh",
    segment_rows: 8,
    nlist: 4,
    use_f16: true,
    vector_dim: 8,
    write_stats: false,
    id_dense: false,
    use_dict_cols: false,
    use_bool_bitmap: false,
    vec_storage: VF16,
    write_blockmax: false,
    normalize_vecs: false,
    write_block_stats: false,
    global_vec_parts: false,
    write_fts_bloom: true,
    global_pack_size: 1,
    fts_tokenizer: @core.Word,
  }
  try {
    delete_docs(store, cfg, [1UL])
    panic()
  } catch {
    _ => ()
  }
}

// ============================================================================
// B1：stats / id_dense / 新编码 / vec_storage / blockmax / compact / CAS 竞争
// ============================================================================

///|
/// 读 seg meta.json 为 Map。
fn[S : @store.ObjectStore] seg_meta_map(
  store : S,
  segp : String,
) -> Map[String, Json] raise @core.SpndError {
  match bytes_to_json(must_get(store, "\{segp}/meta.json"), "seg meta") {
    Object(m) => m
    _ => raise @core.Corrupt("seg meta not object")
  }
}

///|
test "B1 stats, dense id, dict/bitmap encodings, sq8 and blockmax" {
  let store = WbStore::new()
  let cfg : BuildConfig = {
    ns: "b1",
    segment_rows: 16,
    nlist: 4,
    use_f16: true,
    vector_dim: 8,
    write_stats: true,
    id_dense: true,
    use_dict_cols: true,
    use_bool_bitmap: true,
    vec_storage: VSq8,
    write_blockmax: true,
    normalize_vecs: false,
    write_block_stats: false,
    global_vec_parts: false,
    write_fts_bloom: true,
    global_pack_size: 1,
    fts_tokenizer: @core.Word,
  }
  let docs = mkdocs(20, 8, 1UL, 7U)
  ingest(store, cfg, docs)
  let man = head_manifest_of(store, "b1")
  assert_eq(man.segments.length(), 2)
  let seg0 = man.segments[0]
  let p0 = "b1/_segments/\{seg0.id}"
  let meta = seg_meta_map(store, p0)
  // id_encoding = dense_u64（ids 恰为 min_id + 行号）
  assert_eq(meta.get("id_encoding"), Some(Json::string("dense_u64")))
  assert_eq(meta.get("vec_storage"), Some(Json::string("sq8")))
  // stats：ts min/max、category 字典值、public 值
  let stats = match meta.get("stats") {
    Some(Object(m)) => m
    _ => fail("stats missing")
  }
  let ts = match stats.get("ts") {
    Some(Object(m)) => m
    _ => fail("ts stats missing")
  }
  assert_eq(ts.get("min"), Some(Json::number(docs[0].ts.to_double())))
  assert_eq(ts.get("max"), Some(Json::number(docs[15].ts.to_double())))
  let cat = match stats.get("category") {
    Some(Object(m)) => m
    _ => fail("category stats missing")
  }
  assert_eq(
    cat.get("values"),
    Some(
      Json::array([
        Json::string("cat0"),
        Json::string("cat1"),
        Json::string("cat2"),
      ]),
    ),
  )
  let pub_stats = match stats.get("public") {
    Some(Object(m)) => m
    _ => fail("public stats missing")
  }
  assert_eq(
    pub_stats.get("values"),
    Some(Json::array([Json::boolean(false), Json::boolean(true)])),
  )
  // 编码 flags：category 字典、public 位图、text 普通列
  let cat_bs = must_get(store, "\{p0}/rows/category.bin")
  assert_eq(@format.is_dict_col(cat_bs), true)
  let pub_bs = must_get(store, "\{p0}/rows/public.bin")
  assert_eq(
    match pub_bs.get(9) {
      Some(b) => (b.to_int() & 2) != 0
      None => false
    },
    true,
  )
  let text_bs = must_get(store, "\{p0}/rows/text.bin")
  assert_eq(@format.is_dict_col(text_bs), false)
  // blockmax：term 数与 dir 一致，块统计可解码
  let dir = @format.decode_fts_dir(must_get(store, "\{p0}/fts/dir.bin"))
  let blk = @format.decode_blockmax(must_get(store, "\{p0}/fts/blockmax.bin"))
  assert_eq(blk.length(), dir.length())
  // sq8 向量列：解码误差在量化步长内
  let (vdim, vdata) = @format.decode_vec_col(
    must_get(store, "\{p0}/rows/vector.bin"),
  )
  assert_eq(vdim, 8)
  for i in 0..<64 {
    let expect = docs[i / 8].vector[i % 8].to_double()
    assert_eq((vdata[i].to_double() - expect).abs() < 0.02, true)
  }
}

///|
test "B1 vec_storage pq16 writes SPNDPQP1 parts" {
  let store = WbStore::new()
  let cfg : BuildConfig = {
    ns: "b1pq",
    segment_rows: 16,
    nlist: 4,
    use_f16: true,
    vector_dim: 8,
    write_stats: false,
    id_dense: false,
    use_dict_cols: false,
    use_bool_bitmap: false,
    vec_storage: VPq16,
    write_blockmax: false,
    normalize_vecs: false,
    write_block_stats: false,
    global_vec_parts: false,
    write_fts_bloom: true,
    global_pack_size: 1,
    fts_tokenizer: @core.Word,
  }
  ingest(store, cfg, mkdocs(20, 8, 1UL, 9U))
  let man = head_manifest_of(store, "b1pq")
  let p0 = "b1pq/_segments/\{man.segments[0].id}"
  let parts = seg_partitions(store, p0)
  assert_eq(parts.length() > 0, true)
  let bs = must_get(store, "\{p0}/vec/part-\{parts[0]}.bin")
  assert_eq(@format.is_pq_shared_part(bs), true)
  let pq = @format.decode_pq_part_shared(bs)
  assert_eq(pq.dim, 8)
  assert_eq(pq.m * pq.dsub, 8)
  assert_eq(pq.codes.length(), pq.rows.length() * pq.m)
  // 共享码本对象：每段一个，长度 m×256×dsub
  let (m, dsub, dim, cbs) = @format.decode_pq_codebook(
    must_get(store, "\{p0}/vec/pq-codebook.bin"),
  )
  assert_eq(m, pq.m)
  assert_eq(dim, 8)
  assert_eq(dsub, pq.dsub)
  assert_eq(cbs.length(), pq.m * 256 * pq.dsub)
}

///|
test "B1 compact merges segments and physicalizes tombstones" {
  let store = WbStore::new()
  let cfg : BuildConfig = {
    ns: "b1c",
    segment_rows: 8,
    nlist: 4,
    use_f16: true,
    vector_dim: 8,
    write_stats: true,
    id_dense: true,
    use_dict_cols: true,
    use_bool_bitmap: true,
    vec_storage: VF16,
    write_blockmax: true,
    normalize_vecs: false,
    write_block_stats: false,
    global_vec_parts: false,
    write_fts_bloom: true,
    global_pack_size: 1,
    fts_tokenizer: @core.Word,
  }
  let docs = mkdocs(20, 8, 1UL, 7U)
  ingest(store, cfg, docs)
  let m1 = head_manifest_of(store, "b1c")
  assert_eq(m1.segments.length(), 3)
  // 删除 2 个 id 后 compact：段数 1、tombstone 物理化、行数 18
  delete_docs(store, cfg, [docs[2].id, docs[4].id])
  let m_del = head_manifest_of(store, "b1c")
  compact(store, cfg, "b1c")
  let m2 = head_manifest_of(store, "b1c")
  assert_eq(m2.segments.length(), 1)
  assert_eq(m2.deleted.length(), 0)
  assert_eq(m2.num_docs, 18)
  match m2.parent {
    Some(p) => assert_eq(p, m_del.id)
    None => fail("compact manifest should link parent")
  }
  let p0 = "b1c/_segments/\{m2.segments[0].id}"
  let ids = match @format.decode_col(must_get(store, "\{p0}/rows/id.bin")) {
    @format.ColU64(a) => a
    _ => fail("id column dtype")
  }
  assert_eq(ids.length(), 18)
  for id in ids {
    assert_eq(id == docs[2].id || id == docs[4].id, false)
  }
  // 重建后的 fts / doc_len / 分区齐全
  let _ = must_get(store, "\{p0}/fts/dir.bin")
  let _ = must_get(store, "\{p0}/fts/postings.bin")
  let _ = must_get(store, "\{p0}/fts/doc_len.bin")
  let _ = must_get(store, "\{p0}/fts/blockmax.bin")
  let parts = seg_partitions(store, p0)
  let mut seen = 0
  for cid in parts {
    let part = @format.decode_part(must_get(store, "\{p0}/vec/part-\{cid}.bin"))
    seen += part.rows.length()
  }
  assert_eq(seen, 18)
}

///|
test "B1 CAS conflict: stale writer loses, build reports CommitConflict" {
  let store = WbStore::new()
  let cfg : BuildConfig = {
    ns: "b1cas",
    segment_rows: 8,
    nlist: 4,
    use_f16: true,
    vector_dim: 8,
    write_stats: false,
    id_dense: false,
    use_dict_cols: false,
    use_bool_bitmap: false,
    vec_storage: VF16,
    write_blockmax: false,
    normalize_vecs: false,
    write_block_stats: false,
    global_vec_parts: false,
    write_fts_bloom: true,
    global_pack_size: 1,
    fts_tokenizer: @core.Word,
  }
  ingest(store, cfg, mkdocs(8, 8, 1UL, 7U))
  let h1 = head_manifest_of(store, "b1cas").id
  // W2 抢先用 h1 作为 expected 发布 v2
  publish_head_expect(store, "b1cas", h1, "manifest-w2")
  // W1 仍拿 h1 作 expected：CAS 必须失败，build 侧仲裁为 CommitConflict
  try {
    publish_head_expect(store, "b1cas", h1, "manifest-w1")
    panic()
  } catch {
    @core.CommitConflict(_) => ()
    _ => fail("expected CommitConflict")
  }
  // 直接 CAS 也应被拒
  let ns_key = "b1cas/_meta/namespace.json"
  assert_eq(store.put_if_match(ns_key, Some(h1), b"x"), false)
}

///|
test "B1 PQ reconstruction is close to normalized data" {
  // 200 行 × 16 维，两簇；训练后按 codes 重建，L2 误差应远小于簇间距
  let dim = 16
  let n = 200
  let rng = @core.Rng::new(5U)
  let data : Array[Float] = Array::new(capacity=n * dim)
  for i in 0..<n {
    let c = i % 2
    for _ in 0..<dim {
      let base = if c == 0 { 0.5 } else { -0.5 }
      data.push(Float::from_double(base + rng.next_range(-0.1, 0.1)))
    }
  }
  let (codebooks, codes) = train_pq(dim, data)
  let m = pq_m_for(dim)
  let dsub = dim / m
  assert_eq(codebooks.length(), m * 256 * dsub)
  assert_eq(codes.length(), n * m)
  // 归一化数据
  let norm = pq_normalize(data, dim)
  let mut sum_err = 0.0
  for i in 0..<n {
    for c in 0..<m {
      let code = codes[i * m + c].reinterpret_as_int()
      for d in 0..<dsub {
        let rec = codebooks[(c * 256 + code) * dsub + d].to_double()
        let orig = norm[i * dim + c * dsub + d].to_double()
        sum_err += (rec - orig) * (rec - orig)
      }
    }
  }
  let rmse = (sum_err / (n * dim).to_double()).sqrt()
  assert_eq(rmse < 0.05, true)
}

///|
test "B1 PQ16 ADC ranking matches brute force on separable clusters" {
  let dim = 32
  let n = 400
  let rng = @core.Rng::new(11U)
  // 4 簇：中心为 one-hot 块
  let data : Array[Float] = Array::new(capacity=n * dim)
  for i in 0..<n {
    let c = i % 4
    for d in 0..<dim {
      let v = if d / 8 == c { 1.0 } else { 0.0 }
      data.push(Float::from_double(v + rng.next_range(-0.02, 0.02)))
    }
  }
  let (codebooks, codes) = train_pq(dim, data)
  let m = pq_m_for(dim)
  let rows : Array[Int] = Array::new(capacity=n)
  for i in 0..<n {
    rows.push(i)
  }
  let part = @format.encode_pq_part(rows, dim, m, codebooks, codes)
  let pq = @format.decode_pq_part(part)
  // ADC 打分（与 query 包 pq_adc_candidates 同公式）
  let qv : Array[Float] = Array::new(capacity=dim)
  for d in 0..<dim {
    qv.push(
      Float::from_double(data[d].to_double() + rng.next_range(-0.01, 0.01)),
    )
  }
  let qn = @core.norm_f32(qv, 0, dim)
  let qnorm : Array[Float] = Array::new(capacity=dim)
  for v in qv {
    qnorm.push(Float::from_double(v.to_double() / qn))
  }
  let lut : Array[Double] = Array::new(capacity=m * 256)
  for c in 0..<m {
    for j in 0..<256 {
      let mut dist = 0.0
      for d in 0..<pq.dsub {
        let diff = qnorm[c * pq.dsub + d].to_double() -
          pq.codebooks[(c * 256 + j) * pq.dsub + d].to_double()
        dist += diff * diff
      }
      lut.push(dist)
    }
  }
  let adc : Array[(Double, Int)] = Array::new(capacity=n)
  for i in 0..<n {
    let mut dist = 0.0
    for c in 0..<m {
      dist += lut[c * 256 + pq.codes[i * m + c].reinterpret_as_int()]
    }
    adc.push((1.0 - dist / 2.0, i))
  }
  adc.sort_by(fn(a, b) { b.0.compare(a.0) })
  let brute : Array[(Double, Int)] = Array::new(capacity=n)
  for i in 0..<n {
    brute.push((1.0 - @core.cosine_dist_f32(qv, 0, data, i * dim, dim), i))
  }
  brute.sort_by(fn(a, b) { b.0.compare(a.0) })
  let want : Set[Int] = Set([])
  for i in 0..<10 {
    want.add(brute[i].1)
  }
  let mut hits = 0
  for i in 0..<10 {
    if want.contains(adc[i].1) {
      hits += 1
    }
  }
  assert_eq(hits >= 9, true)
}

///|
test "B1 PQ16 ADC on 768-dim random clusters" {
  let dim = 768
  let n = 400
  let rng = @core.Rng::new(21U)
  let inv = 1.0 / dim.to_double().sqrt()
  let centers : Array[Float] = Array::new(capacity=8 * dim)
  for _ in 0..<(8 * dim) {
    centers.push(Float::from_double(rng.next_range(-1.0, 1.0) * inv))
  }
  let data : Array[Float] = Array::new(capacity=n * dim)
  for i in 0..<n {
    let c = i % 8
    for d in 0..<dim {
      data.push(
        Float::from_double(
          centers[c * dim + d].to_double() + rng.next_range(-0.02, 0.02),
        ),
      )
    }
  }
  let (codebooks, codes) = train_pq(dim, data)
  let m = pq_m_for(dim)
  let rows : Array[Int] = Array::new(capacity=n)
  for i in 0..<n {
    rows.push(i)
  }
  let pq = @format.decode_pq_part(
    @format.encode_pq_part(rows, dim, m, codebooks, codes),
  )
  // 查询 = doc 11 + 噪声
  let qv : Array[Float] = Array::new(capacity=dim)
  for d in 0..<dim {
    qv.push(
      Float::from_double(
        data[11 * dim + d].to_double() + rng.next_range(-0.01, 0.01),
      ),
    )
  }
  let qn = @core.norm_f32(qv, 0, dim)
  let qnorm : Array[Float] = Array::new(capacity=dim)
  for v in qv {
    qnorm.push(Float::from_double(v.to_double() / qn))
  }
  let lut : Array[Double] = Array::new(capacity=m * 256)
  for c in 0..<m {
    for j in 0..<256 {
      let mut dist = 0.0
      for d in 0..<pq.dsub {
        let diff = qnorm[c * pq.dsub + d].to_double() -
          pq.codebooks[(c * 256 + j) * pq.dsub + d].to_double()
        dist += diff * diff
      }
      lut.push(dist)
    }
  }
  let adc : Array[(Double, Int)] = Array::new(capacity=n)
  for i in 0..<n {
    let mut dist = 0.0
    for c in 0..<m {
      dist += lut[c * 256 + pq.codes[i * m + c].reinterpret_as_int()]
    }
    adc.push((1.0 - dist / 2.0, i))
  }
  adc.sort_by(fn(a, b) { b.0.compare(a.0) })
  let brute : Array[(Double, Int)] = Array::new(capacity=n)
  for i in 0..<n {
    brute.push((1.0 - @core.cosine_dist_f32(qv, 0, data, i * dim, dim), i))
  }
  brute.sort_by(fn(a, b) { b.0.compare(a.0) })
  // PQ 无精排时簇内精确 top-10 会被量化噪声重排；这里验证 ADC 的
  // cluster 级正确性：top-10 必须全部来自查询所在簇（11 % 8 == 3）。
  let mut same_cluster = 0
  for i in 0..<10 {
    if adc[i].1 % 8 == 3 {
      same_cluster += 1
    }
  }
  assert_eq(same_cluster, 10)
  assert_eq(adc[0].1 % 8, 3)
}

///|
test "B1 normalize_vecs stores unit vectors and meta flag" {
  let store = WbStore::new()
  let cfg : BuildConfig = {
    ns: "b1n",
    segment_rows: 16,
    nlist: 4,
    use_f16: true,
    vector_dim: 8,
    write_stats: false,
    id_dense: false,
    use_dict_cols: false,
    use_bool_bitmap: false,
    vec_storage: VF16,
    write_blockmax: false,
    normalize_vecs: true,
    write_block_stats: false,
    global_vec_parts: false,
    write_fts_bloom: true,
    global_pack_size: 1,
    fts_tokenizer: @core.Word,
  }
  ingest(store, cfg, mkdocs(12, 8, 1UL, 7U))
  let man = head_manifest_of(store, "b1n")
  let p0 = "b1n/_segments/\{man.segments[0].id}"
  let meta = seg_meta_map(store, p0)
  assert_eq(meta.get("vec_normalized"), Some(Json::boolean(true)))
  let (dim, data) = @format.decode_vec_col(
    must_get(store, "\{p0}/rows/vector.bin"),
  )
  assert_eq(dim, 8)
  for i in 0..<12 {
    let n = @core.norm_f32(data, i * dim, dim)
    assert_eq((n - 1.0).abs() < 0.01, true)
  }
  // 分区里的向量也必须归一化（否则 query 的 dot 路径不对）
  for cid in seg_partitions(store, p0) {
    let part = @format.decode_part(must_get(store, "\{p0}/vec/part-\{cid}.bin"))
    for j in 0..<part.rows.length() {
      let n = @core.norm_f32(part.data, j * dim, dim)
      assert_eq((n - 1.0).abs() < 0.01, true)
    }
  }
}

///|
test "B1 delete_docs writes roaring tombstone object" {
  let store = WbStore::new()
  let cfg : BuildConfig = {
    ns: "b1r",
    segment_rows: 8,
    nlist: 4,
    use_f16: true,
    vector_dim: 8,
    write_stats: false,
    id_dense: false,
    use_dict_cols: false,
    use_bool_bitmap: false,
    vec_storage: VF16,
    write_blockmax: false,
    normalize_vecs: false,
    write_block_stats: false,
    global_vec_parts: false,
    write_fts_bloom: true,
    global_pack_size: 1,
    fts_tokenizer: @core.Word,
  }
  ingest(store, cfg, mkdocs(20, 8, 1UL, 7U))
  delete_docs(store, cfg, [2UL, 4UL, 999UL])
  let m = head_manifest_of(store, "b1r")
  match m.deleted_roar {
    Some(mid) => {
      let bs = must_get(store, "b1r/_tombstones/\{mid}.roar")
      let ids = @format.decode_roaring(bs)
      assert_eq(ids.length(), 3)
      assert_eq(ids[0], 2UL)
      assert_eq(ids[1], 4UL)
      assert_eq(ids[2], 999UL)
    }
    None => fail("deleted_roar missing")
  }
}

///|
test "B1 blockstats stores 256-row ts min/max" {
  let store = WbStore::new()
  let cfg : BuildConfig = {
    ns: "b1bst",
    segment_rows: 8,
    nlist: 4,
    use_f16: true,
    vector_dim: 8,
    write_stats: true,
    id_dense: false,
    use_dict_cols: false,
    use_bool_bitmap: false,
    vec_storage: VF16,
    write_blockmax: false,
    normalize_vecs: false,
    write_block_stats: true,
    global_vec_parts: false,
    write_fts_bloom: true,
    global_pack_size: 1,
    fts_tokenizer: @core.Word,
  }
  let docs = mkdocs(20, 8, 1UL, 7U)
  ingest(store, cfg, docs)
  let man = head_manifest_of(store, "b1bst")
  let p0 = "b1bst/_segments/\{man.segments[0].id}"
  let (block_size, row_count, blocks) = @format.decode_blockstats(
    must_get(store, "\{p0}/rows/blockstats.bin"),
  )
  assert_eq(block_size, 256)
  assert_eq(row_count, 8)
  assert_eq(blocks.length(), 1)
  assert_eq(blocks[0].0, docs[0].ts)
  assert_eq(blocks[0].1, docs[7].ts)
}

///|
test "B1 global vec parts merge segments" {
  let store = WbStore::new()
  let cfg : BuildConfig = {
    ns: "b1g",
    segment_rows: 8,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
    write_stats: false,
    id_dense: false,
    use_dict_cols: false,
    use_bool_bitmap: false,
    vec_storage: VF16,
    write_blockmax: false,
    normalize_vecs: false,
    write_block_stats: false,
    global_vec_parts: true,
    write_fts_bloom: true,
    global_pack_size: 1,
    fts_tokenizer: @core.Word,
  }
  ingest(store, cfg, mkdocs(20, 8, 1UL, 7U))
  let man = head_manifest_of(store, "b1g")
  assert_eq(man.segments.length(), 3)
  // 单副本：global 模式下不再写 per-segment 向量列/part
  for sm in man.segments {
    let p = "b1g/_segments/\{sm.id}"
    assert_eq(store.get("\{p}/rows/vector.bin"), None)
    assert_eq(store.get("\{p}/vec/part-0.bin"), None)
  }
  let meta_bs = must_get(store, "b1g/vec/global/\{man.id}/meta.json")
  let m = match bytes_to_json(meta_bs, "global meta") {
    Object(mm) => mm
    _ => fail("global meta not object")
  }
  let cids = match m.get("cids") {
    Some(Array(a)) => a
    _ => fail("global cids missing")
  }
  assert_eq(cids.length() > 0, true)
  let mut total = 0
  for c in cids {
    let cid = match c {
      Number(d, ..) => d.to_int()
      _ => fail("cid not number")
    }
    let gp = @format.decode_global_part(
      must_get(store, "b1g/vec/global/\{man.id}/part-\{cid}.bin"),
    )
    assert_eq(gp.dim, 8)
    assert_eq(gp.data.length(), gp.rows.length() * 8)
    for r in gp.rows {
      assert_eq(r.0 >= 0 && r.0 < man.segments.length(), true)
      assert_eq(r.1 >= 0 && r.1 < man.segments[r.0].row_count, true)
    }
    total += gp.rows.length()
  }
  assert_eq(total, 20)
}

///|
test "B1 seg meta embeds FTS bloom" {
  let store = WbStore::new()
  let cfg : BuildConfig = {
    ns: "b1bl",
    segment_rows: 20,
    nlist: 4,
    use_f16: true,
    vector_dim: 8,
    write_stats: false,
    id_dense: false,
    use_dict_cols: false,
    use_bool_bitmap: false,
    vec_storage: VF16,
    write_blockmax: false,
    normalize_vecs: false,
    write_block_stats: false,
    global_vec_parts: false,
    write_fts_bloom: true,
    global_pack_size: 1,
    fts_tokenizer: @core.Word,
  }
  let docs = mkdocs(20, 8, 1UL, 7U)
  ingest(store, cfg, docs)
  let man = head_manifest_of(store, "b1bl")
  let p0 = "b1bl/_segments/\{man.segments[0].id}"
  let meta = seg_meta_map(store, p0)
  let hex = match meta.get("bloom") {
    Some(String(s)) => s
    _ => fail("bloom missing")
  }
  let m = match meta.get("bloom_m") {
    Some(Number(d, ..)) => d.to_int()
    _ => fail("bloom_m missing")
  }
  let k = match meta.get("bloom_k") {
    Some(Number(d, ..)) => d.to_int()
    _ => fail("bloom_k missing")
  }
  let bl = @format.bloom_from_hex(m, k, hex)
  let term = @core.tokenize(docs[0].text)[0]
  assert_eq(@format.bloom_may_contain(bl, term), true)
  assert_eq(@format.bloom_may_contain(bl, "not-in-this-segment-xyz"), false)
}

///|
test "B1 compact global single-copy keeps one generation" {
  let store = WbStore::new()
  let cfg : BuildConfig = {
    ns: "b1gc",
    segment_rows: 8,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
    write_stats: true,
    id_dense: false,
    use_dict_cols: false,
    use_bool_bitmap: false,
    vec_storage: VF16,
    write_blockmax: false,
    normalize_vecs: true,
    write_block_stats: false,
    global_vec_parts: true,
    write_fts_bloom: true,
    global_pack_size: 1,
    fts_tokenizer: @core.Word,
  }
  let docs = mkdocs(20, 8, 1UL, 7U)
  ingest(store, cfg, docs)
  delete_docs(store, cfg, [docs[2].id, docs[4].id])
  let old = head_manifest_of(store, "b1gc")
  let old_ver = old.vec_global_version
  compact(store, cfg, "b1gc")
  let m = head_manifest_of(store, "b1gc")
  assert_eq(m.segments.length(), 1)
  assert_eq(m.num_docs, 18)
  // 新代 global part 存在；旧代在 GC grace 内保留（in-flight 查询仍可能引用）。
  assert_eq(m.vec_global_version is Some(_), true)
  let new_ver = match m.vec_global_version {
    Some(v) => v
    None => fail("no global version")
  }
  assert_eq(store.get("b1gc/vec/global/\{new_ver}/meta.json") is Some(_), true)
  match old_ver {
    Some(v) =>
      assert_eq(store.get("b1gc/vec/global/\{v}/meta.json") is Some(_), true)
    None => ()
  }
  // 单副本：新段没有 rows/vector.bin / vec/part-*
  let p = "b1gc/_segments/\{m.segments[0].id}"
  assert_eq(store.get("\{p}/rows/vector.bin"), None)
  assert_eq(store.get("\{p}/vec/part-0.bin"), None)
  // grace 内保留当前代 + 旧代；显式 GC 后才只剩一个 generation。
  let versions : Set[String] = Set([])
  for k in store.list("b1gc/vec/global/") {
    let parts = k.split("/").to_array()
    if parts.length() >= 4 {
      versions.add(parts[3].to_owned())
    }
  }
  assert_eq(versions.length(), 2)
  gc_global_versions(store, "b1gc", new_ver)
  let after : Set[String] = Set([])
  for k in store.list("b1gc/vec/global/") {
    let parts = k.split("/").to_array()
    if parts.length() >= 4 {
      after.add(parts[3].to_owned())
    }
  }
  assert_eq(after.length(), 1)
}

///|
test "B1 no-CAS store falls back to append-only head log" {
  let store = WbStore::new()
  store.cas_enabled = false
  let cfg : BuildConfig = {
    ns: "nocas",
    segment_rows: 8,
    nlist: 4,
    use_f16: true,
    vector_dim: 8,
    write_stats: true,
    id_dense: true,
    use_dict_cols: true,
    use_bool_bitmap: true,
    vec_storage: VF16,
    write_blockmax: true,
    normalize_vecs: true,
    write_block_stats: true,
    global_vec_parts: true,
    write_fts_bloom: true,
    global_pack_size: 1,
    fts_tokenizer: @core.Word,
  }
  let docs = mkdocs(20, 8, 1UL, 7U)
  ingest(store, cfg, docs)
  let m1 = head_manifest_of(store, "nocas")
  assert_eq(m1.segments.length(), 3)
  delete_docs(store, cfg, [docs[2].id, docs[4].id])
  compact(store, cfg, "nocas")
  let m2 = head_manifest_of(store, "nocas")
  assert_eq(m2.segments.length(), 1)
  assert_eq(m2.num_docs, 18)
  // 旧 lock 设计已废弃：只应有 head log 记录，不应有 _locks 对象。
  assert_eq(store.get("nocas/_locks/head.lock"), None)
  assert_eq(store.list("nocas/_heads/").length() > 0, true)
}

///|
test "B1 publish_head uses build baseline, not publish-time head" {
  let store = WbStore::new()
  let cfg : BuildConfig = {
    ns: "b1base",
    segment_rows: 8,
    nlist: 4,
    use_f16: true,
    vector_dim: 8,
    write_stats: false,
    id_dense: false,
    use_dict_cols: false,
    use_bool_bitmap: false,
    vec_storage: VF16,
    write_blockmax: false,
    normalize_vecs: false,
    write_block_stats: false,
    global_vec_parts: false,
    write_fts_bloom: true,
    global_pack_size: 1,
    fts_tokenizer: @core.Word,
  }
  ingest(store, cfg, mkdocs(8, 8, 1UL, 7U))
  let base = head_manifest_of(store, "b1base")
  // W1 基于 base 构建了一个 manifest（但尚未发布）。
  let stale : @format.ManifestData = {
    id: "manifest-stale",
    parent: Some(base.id),
    segments: base.segments,
    deleted: base.deleted,
    deleted_roar: None,
    vec_global_version: None,
    global_gen: None,
    centroid_version: base.centroid_version,
    num_docs: base.num_docs,
    avg_doc_len: base.avg_doc_len,
  }
  store.put("b1base/_manifest/manifest-stale.json", json_bytes(stale.to_json()))
  // W2 先完成并发布，head 已从 base 前移。
  ingest(store, cfg, mkdocs(8, 8, 101UL, 7U))
  // W1 仍拿 base 作 expected：必须冲突，不能把 W2 的段静默丢掉。
  try {
    publish_head(store, "b1base", base.id, "manifest-stale")
    fail("expected CommitConflict")
  } catch {
    @core.CommitConflict(_) => ()
    _ => fail("expected CommitConflict")
  }
  // 最终 head 仍是 W2 的 manifest，未被 stale 覆盖。
  assert_eq(head_manifest_of(store, "b1base").id != "manifest-stale", true)
}

///|
test "B1 legacy namespace without head log can still publish" {
  let store = WbStore::new()
  let cfg : BuildConfig = {
    ns: "b1legacy",
    segment_rows: 8,
    nlist: 4,
    use_f16: true,
    vector_dim: 8,
    write_stats: false,
    id_dense: false,
    use_dict_cols: false,
    use_bool_bitmap: false,
    vec_storage: VF16,
    write_blockmax: false,
    normalize_vecs: false,
    write_block_stats: false,
    global_vec_parts: false,
    write_fts_bloom: true,
    global_pack_size: 1,
    fts_tokenizer: @core.Word,
  }
  let docs = mkdocs(20, 8, 1UL, 7U)
  ingest(store, cfg, docs)
  let m1 = head_manifest_of(store, "b1legacy")
  // 模拟旧版本数据：namespace.json 里直接写 head_manifest，_heads/ 为空。
  let meta = match read_namespace(store, "b1legacy") {
    Some(m) => m
    None => fail("namespace missing")
  }
  let legacy = { ..meta, head_manifest: m1.id }
  store.put("b1legacy/_meta/namespace.json", json_bytes(legacy.to_json()))
  for k in store.list("b1legacy/_heads/") {
    store.delete(k)
  }
  assert_eq(store.list("b1legacy/_heads/").length(), 0)
  // 旧 namespace 必须仍可写；发布后补上 head log 记录。
  delete_docs(store, cfg, [docs[0].id])
  let m2 = head_manifest_of(store, "b1legacy")
  assert_eq(m2.parent, Some(m1.id))
  assert_eq(store.list("b1legacy/_heads/").length(), 1)
}

///|
test "B1 single-copy global parts store normalized vectors" {
  let store = WbStore::new()
  let cfg = {
    ..BuildConfig::single_copy("b1norm"),
    segment_rows: 8,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
  }
  let docs = mkdocs(20, 8, 1UL, 7U)
  // 模长差异明显：如果 global part 存原始向量，dot 打分会被模长污染。
  for i in 0..<docs.length() {
    let scale = (i % 5 + 1).to_double()
    let v = docs[i].vector
    for d in 0..<v.length() {
      v[d] = Float::from_double(v[d].to_double() * scale)
    }
  }
  ingest(store, cfg, docs)
  let check = fn(man : @format.ManifestData) -> Unit raise @core.SpndError {
    let ver = match man.vec_global_version {
      Some(v) => v
      None => raise @core.Corrupt("expected global version")
    }
    for seg in man.segments {
      let p = "b1norm/_segments/\{seg.id}"
      let meta = seg_meta_map(store, p)
      if meta.get("vec_normalized") != Some(Json::boolean(true)) {
        raise @core.Corrupt("global segment must record vec_normalized=true")
      }
    }
    let gm = read_global_meta(store, "b1norm", ver)
    for cid in global_meta_cids(gm) {
      let gp = @format.decode_global_part(
        must_get(store, "b1norm/vec/global/\{ver}/part-\{cid}.bin"),
      )
      for i in 0..<gp.rows.length() {
        let n = @core.norm_f32(gp.data, i * gp.dim, gp.dim)
        let err = if n > 1.0 { n - 1.0 } else { 1.0 - n }
        if err >= 1.0e-4 {
          raise @core.Corrupt("global part vector is not normalized: norm=\{n}")
        }
      }
    }
  }
  check(head_manifest_of(store, "b1norm"))
  compact(store, cfg, "b1norm")
  check(head_manifest_of(store, "b1norm"))
}

///|
test "B1 compact rejects missing global part instead of zero-filling" {
  let store = WbStore::new()
  let cfg = {
    ..BuildConfig::single_copy("b1miss"),
    segment_rows: 8,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
  }
  ingest(store, cfg, mkdocs(20, 8, 1UL, 7U))
  let man = head_manifest_of(store, "b1miss")
  let ver = match man.vec_global_version {
    Some(v) => v
    None => raise @core.Corrupt("expected global version")
  }
  let gm = read_global_meta(store, "b1miss", ver)
  let cids = global_meta_cids(gm)
  assert_eq(cids.length() > 0, true)
  store.delete("b1miss/vec/global/\{ver}/part-\{cids[0]}.bin")
  try {
    compact(store, cfg, "b1miss")
    fail("expected missing part error")
  } catch {
    @core.NotFound(_) => ()
    @core.Corrupt(_) => ()
    _ => fail("expected NotFound/Corrupt")
  }
}

///|
/// 模拟“两个写者都通过 pre-check”的竞态：第一次 LIST `_heads/` 隐藏并发 sibling，
/// 写入后再返回全部 head。用于测试 publish 的写后 fork 检测/回滚。
priv struct ForkStore {
  inner : WbStore
  mut head_lists : Int
}

///|
impl @store.ObjectStore for ForkStore with fn get(
  self : ForkStore,
  key : String,
) -> Bytes? {
  self.inner.get(key)
}

///|
impl @store.ObjectStore for ForkStore with fn put(
  self : ForkStore,
  key : String,
  value : Bytes,
) -> Unit {
  self.inner.put(key, value)
}

///|
impl @store.ObjectStore for ForkStore with fn put_if_match(
  self : ForkStore,
  key : String,
  expected : String?,
  value : Bytes,
) -> Bool {
  self.inner.put_if_match(key, expected, value)
}

///|
impl @store.ObjectStore for ForkStore with fn get_range(
  self : ForkStore,
  key : String,
  offset : Int,
  len : Int,
) -> Bytes? {
  self.inner.get_range(key, offset, len)
}

///|
impl @store.ObjectStore for ForkStore with fn list(
  self : ForkStore,
  prefix : String,
) -> Array[String] {
  let all = self.inner.list(prefix)
  if prefix.has_suffix("/_heads/") && self.head_lists == 0 {
    self.head_lists += 1
    let out : Array[String] = Array::new()
    for key in all {
      if !key.has_suffix("/manifest-0002") {
        out.push(key)
      }
    }
    return out
  }
  all
}

///|
impl @store.ObjectStore for ForkStore with fn delete(
  self : ForkStore,
  key : String,
) -> Unit {
  self.inner.delete(key)
}

///|
impl @store.ObjectStore for ForkStore with fn head_version(
  self : ForkStore,
  key : String
) -> String? {
  self.inner.head_version(key)
}

///|
test "B1 publish rolls back fork when both writers passed pre-check" {
  let inner = WbStore::new()
  let base : @format.ManifestData = {
    id: "manifest-0001",
    parent: None,
    segments: [],
    deleted: [],
    deleted_roar: None,
    vec_global_version: None,
    global_gen: None,
    centroid_version: "centroids-0001",
    num_docs: 0,
    avg_doc_len: 0.0,
  }
  let sibling : @format.ManifestData = {
    ..base,
    id: "manifest-0002",
    parent: Some("manifest-0001"),
  }
  let mine : @format.ManifestData = {
    ..base,
    id: "manifest-0003",
    parent: Some("manifest-0001"),
  }
  inner.put("fork/_manifest/manifest-0001.json", json_bytes(base.to_json()))
  inner.put("fork/_manifest/manifest-0002.json", json_bytes(sibling.to_json()))
  inner.put("fork/_manifest/manifest-0003.json", json_bytes(mine.to_json()))
  inner.put("fork/_heads/manifest-0001", b"")
  inner.put("fork/_heads/manifest-0002", b"")
  let store : ForkStore = { inner, head_lists: 0 }
  // pre-check 只看到 manifest-0001；写后看到 sibling manifest-0002 与新 head。
  try {
    publish_head_expect(store, "fork", "manifest-0001", "manifest-0003")
    fail("expected fork CommitConflict")
  } catch {
    @core.CommitConflict(_) => ()
    _ => fail("expected CommitConflict")
  }
  // 后写者回滚自己的 head，先写者 manifest-0002 保留。
  assert_eq(@store.read_head(store, "fork", ""), "manifest-0002")
}

///|
test "B1 gc grace anchors at replacement time, not creation time" {
  let store = WbStore::new()
  let cfg = {
    ..BuildConfig::single_copy("b1gca"),
    segment_rows: 8,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
  }
  ingest(store, cfg, mkdocs(20, 8, 1UL, 7U))
  let oldv = match head_manifest_of(store, "b1gca").vec_global_version {
    Some(v) => v
    None => fail("expected old global version")
  }
  ingest(store, cfg, mkdocs(5, 8, 101UL, 7U))
  let newv = match head_manifest_of(store, "b1gca").vec_global_version {
    Some(v) => v
    None => fail("expected new global version")
  }
  let set_created = fn(
    ver : String,
    ms : UInt64,
  ) -> Unit raise @core.SpndError {
    let m = read_global_meta(store, "b1gca", ver)
    m.set("created_ms", Json::number(ms.to_double()))
    store.put("b1gca/vec/global/\{ver}/meta.json", json_bytes(Json::object(m)))
  }
  let now = @env.now()
  // 旧代创建于 2 小时前，但 10 秒前才被新代替代：grace 应从替代时刻起算，
  // 所以旧代必须保留。
  set_created(oldv, now - 7200000UL)
  set_created(newv, now - 10000UL)
  gc_global_versions_grace(store, "b1gca", newv, 60000UL)
  assert_eq(store.get("b1gca/vec/global/\{oldv}/meta.json") is Some(_), true)
  // 新代已替代 2 分钟：旧代超过 grace，可以删。
  set_created(newv, now - 120000UL)
  gc_global_versions_grace(store, "b1gca", newv, 60000UL)
  assert_eq(store.get("b1gca/vec/global/\{oldv}/meta.json"), None)
}

///|
test "B1 writer id token validation" {
  assert_eq(valid_writer_token("w1-p2-000001"), true)
  assert_eq(valid_writer_token("bad/id"), false)
  assert_eq(valid_writer_token("bad_id"), false)
  assert_eq(valid_writer_token("含中文"), false)
}

// ============================================================================
// S1：global IVF delta 写路径（`ingest_delta`）。只验证写路径，不查 delta 数据
// （读路径 = S2）。
// ============================================================================

///|
/// 一个 global 代目录下所有 part 的行数之和（(seg_idx,row) 逐行解码）。
fn[S : @store.ObjectStore] global_gen_rows(
  store : S,
  ns : String,
  ver : String,
) -> Int raise @core.SpndError {
  let gm = read_global_meta(store, ns, ver)
  let mut total = 0
  for cid in global_meta_cids(gm) {
    let gp = @format.decode_global_part(
      must_get(store, "\{ns}/vec/global/\{ver}/part-\{cid}.bin"),
    )
    total += gp.rows.length()
  }
  total
}

///|
/// 一个 global 代目录下所有对象 key（升序），用于验证「旧代未被改写」。
fn[S : @store.ObjectStore] global_gen_keys(
  store : S,
  ns : String,
  ver : String,
) -> Array[String] {
  let out : Array[String] = Array::new()
  for k in store.list("\{ns}/vec/global/\{ver}/") {
    out.push(k)
  }
  out.sort()
  out
}

///|
/// global meta 的 (kind, base, seg_ids)；字段缺失时分别为 ""、""、[]。
fn meta_of_kind_base(m : Map[String, Json]) -> (String, String, Array[String]) {
  let kind = match m.get("kind") {
    Some(String(s)) => s
    _ => ""
  }
  let base = match m.get("base") {
    Some(String(s)) => s
    _ => ""
  }
  let seg_ids : Array[String] = Array::new()
  match m.get("seg_ids") {
    Some(Array(a)) =>
      for x in a {
        match x {
          String(s) => seg_ids.push(s)
          _ => ()
        }
      }
    _ => ()
  }
  (kind, base, seg_ids)
}

///|
test "S1 ingest_delta appends one delta and leaves base untouched" {
  let store = WbStore::new()
  let cfg : BuildConfig = {
    ns: "b1dl",
    segment_rows: 8,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
    write_stats: false,
    id_dense: false,
    use_dict_cols: false,
    use_bool_bitmap: false,
    vec_storage: VF16,
    write_blockmax: false,
    normalize_vecs: true,
    write_block_stats: false,
    global_vec_parts: true,
    write_fts_bloom: true,
    global_pack_size: 1,
    fts_tokenizer: @core.Word,
  }
  // 第一次：全量 base（旧 ingest 行为不变：global_gen = None，单向全量代）
  ingest(store, cfg, mkdocs(400, 8, 1UL, 7U))
  let m1 = head_manifest_of(store, "b1dl")
  assert_eq(m1.global_gen is None, true)
  assert_eq(m1.segments.length(), 50)
  let base = match m1.vec_global_version {
    Some(v) => v
    None => fail("expected global version")
  }
  assert_eq(base, m1.id)
  let base_keys = global_gen_keys(store, "b1dl", base)
  assert_eq(base_keys.length() > 1, true)
  let base_rows = global_gen_rows(store, "b1dl", base)
  assert_eq(base_rows, 400)

  // 第二次：ingest_delta 只追加一个 delta 代
  let b2 = mkdocs(12, 8, 101UL, 7U)
  ingest_delta(store, cfg, b2)
  let m2 = head_manifest_of(store, "b1dl")
  assert_eq(m2.parent, Some(m1.id))
  assert_eq(m2.segments.length(), m1.segments.length() + 2)
  // base 不变，deltas 长度 1
  assert_eq(m2.vec_global_version, Some(base))
  let g2 = match m2.global_gen {
    Some(g) => g
    None => fail("global_gen missing after ingest_delta")
  }
  assert_eq(g2.base, base)
  assert_eq(g2.deltas.length(), 1)
  let d1 = g2.deltas[0]
  assert_eq(d1, m2.id)
  // delta 代 meta：kind=delta、base=<旧 base>、seg_ids 只列新段
  let dm = read_global_meta(store, "b1dl", d1)
  let (kind, base_field, dseg_ids) = meta_of_kind_base(dm)
  assert_eq(kind, "delta")
  assert_eq(base_field, base)
  assert_eq(dseg_ids.length(), 2)
  // delta part 行数 = 第二批新行数；row 的 seg_idx 落在新段区间
  let mut dtotal = 0
  for cid in global_meta_cids(dm) {
    let gp = @format.decode_global_part(
      must_get(store, "b1dl/vec/global/\{d1}/part-\{cid}.bin"),
    )
    assert_eq(gp.dim, 8)
    for r in gp.rows {
      assert_eq(r.0 >= m1.segments.length(), true)
      assert_eq(r.0 < m2.segments.length(), true)
      assert_eq(r.1 >= 0 && r.1 < m2.segments[r.0].row_count, true)
    }
    dtotal += gp.rows.length()
  }
  assert_eq(dtotal, 12)
  // 归一化语义与 base 路径一致：delta 行也是 L2 归一化后的向量
  // （读路径用 dot 打分，两代口径必须相同）
  for cid in global_meta_cids(dm) {
    let gp = @format.decode_global_part(
      must_get(store, "b1dl/vec/global/\{d1}/part-\{cid}.bin"),
    )
    for i in 0..<gp.rows.length() {
      let n = @core.norm_f32(gp.data, i * gp.dim, gp.dim)
      let err = if n > 1.0 { n - 1.0 } else { 1.0 - n }
      assert_eq(err < 1.0e-4, true)
    }
  }
  // 旧 base 未被改写：key 集合、对象版本号、行数都不变
  let base_keys_after = global_gen_keys(store, "b1dl", base)
  assert_eq(base_keys_after.length(), base_keys.length())
  for i in 0..<base_keys.length() {
    assert_eq(base_keys_after[i], base_keys[i])
    // WbStore 每次 put 都会推进内部版本：版本号不变 ⇒ 该对象没被重写
    assert_eq(store.versions.get(base_keys[i]) is Some(_), true)
  }
  assert_eq(global_gen_rows(store, "b1dl", base), 400)

  // 第三次：已有 global_gen ⇒ base 不变、deltas 追加（链式）
  let before_base_ver = store.versions.get(base_keys[0])
  ingest_delta(store, cfg, mkdocs(4, 8, 201UL, 7U))
  let m3 = head_manifest_of(store, "b1dl")
  let g3 = match m3.global_gen {
    Some(g) => g
    None => fail("global_gen missing on third ingest_delta")
  }
  assert_eq(g3.base, base)
  assert_eq(g3.deltas.length(), 2)
  assert_eq(g3.deltas[0], d1)
  assert_eq(g3.deltas[1], m3.id)
  assert_eq(m3.vec_global_version, Some(base))
  // base 代仍然没有被重写（第三次也是纯追加）
  assert_eq(store.versions.get(base_keys[0]) is Some(_), true)
  match before_base_ver {
    Some(v) => assert_eq(store.versions.get(base_keys[0]).unwrap_or(-1), v)
    None => fail("base object vanished")
  }
  assert_eq(global_gen_rows(store, "b1dl", base), 400)
  assert_eq(global_gen_rows(store, "b1dl", m3.id), 4)
}

///|
test "S1 ingest_delta without old global writes full base" {
  let store = WbStore::new()
  let cfg : BuildConfig = {
    ns: "b1dl0",
    segment_rows: 8,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
    write_stats: false,
    id_dense: false,
    use_dict_cols: false,
    use_bool_bitmap: false,
    vec_storage: VF16,
    write_blockmax: false,
    normalize_vecs: true,
    write_block_stats: false,
    global_vec_parts: true,
    write_fts_bloom: true,
    global_pack_size: 1,
    fts_tokenizer: @core.Word,
  }
  // 首次写者用 ingest_delta：没有旧 global ⇒ 全量 base，deltas 为空
  ingest_delta(store, cfg, mkdocs(16, 8, 1UL, 7U))
  let m1 = head_manifest_of(store, "b1dl0")
  assert_eq(m1.vec_global_version, Some(m1.id))
  let g1 = match m1.global_gen {
    Some(g) => g
    None => fail("global_gen missing on first ingest_delta")
  }
  assert_eq(g1.base, m1.id)
  assert_eq(g1.deltas.length(), 0)
  assert_eq(m1.segments.length(), 2)
  assert_eq(global_gen_rows(store, "b1dl0", m1.id), 16)
  // 旧布局（per-segment part）namespace 追加：旧段向量被拷进全量 base
  let store2 = WbStore::new()
  let cfg_legacy = { ..cfg, ns: "b1dl1", global_vec_parts: false }
  ingest(store2, cfg_legacy, mkdocs(12, 8, 1UL, 7U))
  let l1 = head_manifest_of(store2, "b1dl1")
  assert_eq(l1.vec_global_version is None, true)
  assert_eq(store2.get("b1dl1/vec/global/\{l1.id}/meta.json"), None)
  let cfg2 = { ..cfg, ns: "b1dl1" }
  ingest_delta(store2, cfg2, mkdocs(8, 8, 101UL, 7U))
  let m2 = head_manifest_of(store2, "b1dl1")
  let g2 = match m2.global_gen {
    Some(g) => g
    None => fail("global_gen missing after legacy upgrade")
  }
  assert_eq(g2.base, m2.id)
  assert_eq(g2.deltas.length(), 0)
  assert_eq(m2.vec_global_version, Some(m2.id))
  // 12 旧行（从 per-segment part 拷入）+ 8 新行
  assert_eq(global_gen_rows(store2, "b1dl1", m2.id), 20)
}

// ============================================================================
// S2b：build / compact 读 global 代际链（base + deltas）。
//
// 旧实现只读 `vec_global_version`（base），delta 之后再普通 `ingest` / `compact`
// 会丢掉 delta 代里的新段向量。这里直接读 global part/meta 校验，不依赖 query 包。
// ============================================================================

///|
/// 读一个 global 代的全部行，按 manifest 段顺序展平成 `vecs`
/// （index = 段起始行号 + 段内行号；缺行为 None），同时返回 dim 与每段行数。
fn[S : @store.ObjectStore] flat_global_vectors(
  store : S,
  ns : String,
  ver : String,
  manifest : @format.ManifestData,
) -> (Int, Array[Array[Float]?], Array[Int]) raise {
  let gm = read_global_meta(store, ns, ver)
  let cids = global_meta_cids(gm)
  let seg_off : Array[Int] = Array::new(capacity=manifest.segments.length())
  let counts : Array[Int] = Array::new(capacity=manifest.segments.length())
  let mut off = 0
  for s in manifest.segments {
    seg_off.push(off)
    counts.push(0)
    off += s.row_count
  }
  let vecs : Array[Array[Float]?] = Array::new(capacity=off)
  for _ in 0..<off {
    vecs.push(None)
  }
  let mut dim = 0
  for cid in cids {
    let gp = @format.decode_global_part(
      must_get(store, "\{ns}/vec/global/\{ver}/part-\{cid}.bin"),
    )
    if dim == 0 {
      dim = gp.dim
    } else {
      assert_eq(gp.dim, dim)
    }
    for i in 0..<gp.rows.length() {
      let (si, row) = gp.rows[i]
      assert_eq(si >= 0 && si < manifest.segments.length(), true)
      assert_eq(row >= 0 && row < manifest.segments[si].row_count, true)
      let v : Array[Float] = Array::new(capacity=gp.dim)
      for d in 0..<gp.dim {
        v.push(gp.data[i * gp.dim + d])
      }
      vecs[seg_off[si] + row] = Some(v)
      counts[si] += 1
    }
  }
  (dim, vecs, counts)
}

///|
/// 断言一个已展平 global 代的某行与原始 doc 向量同向（normalize_vecs ⇒ L2 归一化
/// 后的方向；f16 关闭，误差只来自 f32）。
fn assert_vec_dir(
  got : Array[Float],
  raw : Array[Float],
  dim : Int,
  label : String,
) -> Unit raise {
  assert_eq(got.length(), dim)
  let want = pq_normalize(raw, dim)
  for d in 0..<dim {
    let diff = got[d].to_double() - want[d].to_double()
    let err = if diff < 0.0 { -diff } else { diff }
    if err >= 1.0e-4 {
      fail("\{label}: component \{d} mismatch (\{err})")
    }
  }
}

///|
test "S2b ingest after ingest_delta keeps delta rows in new base" {
  let store = WbStore::new()
  let cfg : BuildConfig = {
    ns: "b1rb",
    segment_rows: 8,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
    write_stats: false,
    id_dense: false,
    use_dict_cols: false,
    use_bool_bitmap: false,
    vec_storage: VF16,
    write_blockmax: false,
    normalize_vecs: true,
    write_block_stats: false,
    global_vec_parts: true,
    write_fts_bloom: true,
    global_pack_size: 1,
    fts_tokenizer: @core.Word,
  }
  let d1 = mkdocs(400, 8, 1UL, 7U)
  let d2 = mkdocs(12, 8, 101UL, 11U)
  let d3 = mkdocs(4, 8, 201UL, 13U)
  ingest(store, cfg, d1)
  let m1 = head_manifest_of(store, "b1rb")
  let base = match m1.vec_global_version {
    Some(v) => v
    None => fail("expected global version")
  }
  assert_eq(base, m1.id)
  ingest_delta(store, cfg, d2)
  let m2 = head_manifest_of(store, "b1rb")
  let g2 = match m2.global_gen {
    Some(g) => g
    None => fail("global_gen missing after ingest_delta")
  }
  assert_eq(g2.base, base)
  assert_eq(g2.deltas.length(), 1)
  assert_eq(global_gen_rows(store, "b1rb", base), 400)
  assert_eq(global_gen_rows(store, "b1rb", m2.id), 12)

  // 普通 ingest（全量重写 base）：必须把 delta 代的 12 行也拷进新 base。
  ingest(store, cfg, d3)
  let m3 = head_manifest_of(store, "b1rb")
  assert_eq(m3.parent, Some(m2.id))
  assert_eq(m3.num_docs, 416)
  assert_eq(m3.global_gen is None, true)
  assert_eq(m3.vec_global_version, Some(m3.id))
  // 新 base 行数 = 三批之和（旧实现只剩 20 + 4 = 24）
  assert_eq(global_gen_rows(store, "b1rb", m3.id), 416)
  let (dim, vecs, counts) = flat_global_vectors(store, "b1rb", m3.id, m3)
  assert_eq(dim, 8)
  for si in 0..<m3.segments.length() {
    assert_eq(counts[si], m3.segments[si].row_count)
  }
  // 逐行同向校验：(si,row) 顺序 = d1 ++ d2 ++ d3 的拼接顺序。
  let src : Array[Array[Float]] = Array::new()
  for d in d1 {
    src.push(d.vector)
  }
  for d in d2 {
    src.push(d.vector)
  }
  for d in d3 {
    src.push(d.vector)
  }
  let seg_off : Array[Int] = Array::new(capacity=m3.segments.length())
  let mut off = 0
  for s in m3.segments {
    seg_off.push(off)
    off += s.row_count
  }
  assert_eq(off, 416)
  for si in 0..<m3.segments.length() {
    for r in 0..<m3.segments[si].row_count {
      let v = match vecs[seg_off[si] + r] {
        Some(v) => v
        None => fail("missing row (\{si},\{r}) in new base")
      }
      assert_vec_dir(v, src[seg_off[si] + r], 8, "new base (\{si},\{r})")
    }
  }
  // delta 行确实进了新 base：第二、三批的 seg_idx 区间（3..5）非空。
  assert_eq(counts[3] > 0, true)
  assert_eq(counts[4] > 0, true)
  assert_eq(counts[5] > 0, true)
}

///|
test "S2b compact reads global delta chain and folds it into one base" {
  let store = WbStore::new()
  let cfg : BuildConfig = {
    ns: "b1cb",
    segment_rows: 8,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
    write_stats: false,
    id_dense: false,
    use_dict_cols: false,
    use_bool_bitmap: false,
    vec_storage: VF16,
    write_blockmax: false,
    normalize_vecs: true,
    write_block_stats: false,
    global_vec_parts: true,
    write_fts_bloom: true,
    global_pack_size: 1,
    fts_tokenizer: @core.Word,
  }
  let d1 = mkdocs(400, 8, 1UL, 7U)
  let d2 = mkdocs(12, 8, 101UL, 11U)
  ingest(store, cfg, d1)
  let m1 = head_manifest_of(store, "b1cb")
  let base = match m1.vec_global_version {
    Some(v) => v
    None => fail("expected global version")
  }
  ingest_delta(store, cfg, d2)
  let m2 = head_manifest_of(store, "b1cb")
  let g2 = match m2.global_gen {
    Some(g) => g
    None => fail("global_gen missing after ingest_delta")
  }
  let delta = g2.deltas[0]
  assert_eq(store.get("b1cb/vec/global/\{base}/meta.json") is Some(_), true)
  assert_eq(store.get("b1cb/vec/global/\{delta}/meta.json") is Some(_), true)

  compact(store, cfg, "b1cb")
  let m3 = head_manifest_of(store, "b1cb")
  assert_eq(m3.num_docs, 412)
  // compact 后只剩一个段，且段行数 = 总数（旧实现只装 base 的 20 行 + 缺行 raise）
  assert_eq(m3.segments.length(), 1)
  assert_eq(m3.segments[0].row_count, 412)
  // 新的全量 base：global_gen 复位、vec_global_version 指向自己
  assert_eq(m3.global_gen is None, true)
  assert_eq(m3.vec_global_version, Some(m3.id))
  assert_eq(global_gen_rows(store, "b1cb", m3.id), 412)
  let (dim, vecs, counts) = flat_global_vectors(store, "b1cb", m3.id, m3)
  assert_eq(dim, 8)
  assert_eq(counts[0], 412)
  // 逐行同向校验：d1 ++ d2（compact 按段顺序拼接）
  let src : Array[Array[Float]] = Array::new()
  for d in d1 {
    src.push(d.vector)
  }
  for d in d2 {
    src.push(d.vector)
  }
  for r in 0..<412 {
    let v = match vecs[r] {
      Some(v) => v
      None => fail("missing compact row \{r}")
    }
    assert_vec_dir(v, src[r], 8, "compact row \{r}")
  }
  // 旧 base / delta 未被新 manifest 引用：显式 GC 后对象必须消失（keep-set 只留新代）。
  gc_global_versions(store, "b1cb", m3.id)
  assert_eq(store.get("b1cb/vec/global/\{base}/meta.json"), None)
  assert_eq(store.get("b1cb/vec/global/\{delta}/meta.json"), None)
  assert_eq(store.get("b1cb/vec/global/\{m3.id}/meta.json") is Some(_), true)
}

// ============================================================================
// S3：global delta 链的阈值合并 / compact_global。
// ============================================================================

///|
test "S3 ingest_delta auto compacts global chain at third delta" {
  let store = WbStore::new()
  let cfg : BuildConfig = {
    ns: "b1gc3",
    segment_rows: 8,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
    write_stats: false,
    id_dense: false,
    use_dict_cols: false,
    use_bool_bitmap: false,
    vec_storage: VF16,
    write_blockmax: false,
    normalize_vecs: true,
    write_block_stats: false,
    global_vec_parts: true,
    write_fts_bloom: true,
    global_pack_size: 1,
    fts_tokenizer: @core.Word,
  }
  let d1 = mkdocs(400, 8, 1UL, 7U)
  let d2 = mkdocs(12, 8, 101UL, 11U)
  let d3 = mkdocs(4, 8, 201UL, 13U)
  let d4 = mkdocs(8, 8, 301UL, 17U)
  ingest(store, cfg, d1)
  let m1 = head_manifest_of(store, "b1gc3")
  let base = match m1.vec_global_version {
    Some(v) => v
    None => fail("expected global version")
  }
  ingest_delta(store, cfg, d2)
  ingest_delta(store, cfg, d3)
  let m2 = head_manifest_of(store, "b1gc3")
  let g2 = match m2.global_gen {
    Some(g) => g
    None => fail("global_gen missing before threshold")
  }
  assert_eq(g2.base, base)
  assert_eq(g2.deltas.length(), 2)
  let old_versions : Array[String] = Array::new()
  old_versions.push(base)
  for d in g2.deltas {
    old_versions.push(d)
  }
  // 第 3 次 delta：用可配置 max_deltas=3 验证自动合并。
  ingest_delta_opts(store, cfg, d4, 3, true)
  let m3 = head_manifest_of(store, "b1gc3")
  assert_eq(m3.parent is Some(_), true)
  assert_eq(m3.num_docs, 424)
  assert_eq(m3.global_gen is None, true)
  let newv = match m3.vec_global_version {
    Some(v) => v
    None => fail("auto compact lost global version")
  }
  assert_eq(newv, m3.id)
  assert_eq(newv == base, false)
  assert_eq(global_gen_rows(store, "b1gc3", newv), 424)
  // 旧 base + deltas 在 grace 内仍然存在（in-flight 查询可读）。
  for v in old_versions {
    assert_eq(store.get("b1gc3/vec/global/\{v}/meta.json") is Some(_), true)
  }
  // 显式 GC（grace=0）只保留新 base。
  gc_global_versions(store, "b1gc3", newv)
  for v in old_versions {
    assert_eq(store.get("b1gc3/vec/global/\{v}/meta.json"), None)
  }
  let prefix = "b1gc3/vec/global/"
  for k in store.list(prefix) {
    let ver = match global_version_of_key(prefix, k) {
      Some(v) => v
      None => ""
    }
    assert_eq(ver, newv)
  }
  assert_eq(store.get("b1gc3/vec/global/\{newv}/meta.json") is Some(_), true)
}

///|
test "S3 compact_global folds one delta and no-ops on empty chain" {
  let store = WbStore::new()
  let cfg : BuildConfig = {
    ns: "b1gcm",
    segment_rows: 8,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
    write_stats: false,
    id_dense: false,
    use_dict_cols: false,
    use_bool_bitmap: false,
    vec_storage: VF16,
    write_blockmax: false,
    normalize_vecs: true,
    write_block_stats: false,
    global_vec_parts: true,
    write_fts_bloom: true,
    global_pack_size: 1,
    fts_tokenizer: @core.Word,
  }
  let d1 = mkdocs(400, 8, 1UL, 7U)
  let d2 = mkdocs(12, 8, 101UL, 11U)
  ingest(store, cfg, d1)
  let m1 = head_manifest_of(store, "b1gcm")
  let base = match m1.vec_global_version {
    Some(v) => v
    None => fail("expected global version")
  }
  ingest_delta(store, cfg, d2)
  let m2 = head_manifest_of(store, "b1gcm")
  let g2 = match m2.global_gen {
    Some(g) => g
    None => fail("global_gen missing after ingest_delta")
  }
  assert_eq(g2.deltas.length(), 1)
  let delta = g2.deltas[0]
  // 手工合并在 deltas=1 时也工作。
  compact_global(store, cfg, "b1gcm")
  let m3 = head_manifest_of(store, "b1gcm")
  assert_eq(m3.parent, Some(m2.id))
  assert_eq(m3.global_gen is None, true)
  assert_eq(m3.num_docs, 412)
  let newv = match m3.vec_global_version {
    Some(v) => v
    None => fail("compact_global lost global version")
  }
  assert_eq(newv, m3.id)
  assert_eq(newv == base, false)
  assert_eq(global_gen_rows(store, "b1gcm", newv), 412)
  // grace 内旧链保留。
  assert_eq(store.get("b1gcm/vec/global/\{base}/meta.json") is Some(_), true)
  assert_eq(store.get("b1gcm/vec/global/\{delta}/meta.json") is Some(_), true)
  // 已无 global_gen / deltas ⇒ no-op（不发布新 manifest）。
  compact_global(store, cfg, "b1gcm")
  let m4 = head_manifest_of(store, "b1gcm")
  assert_eq(m4.id, m3.id)
  // 显式 GC 后旧链消失，新 base 保留。
  gc_global_versions(store, "b1gcm", newv)
  assert_eq(store.get("b1gcm/vec/global/\{base}/meta.json"), None)
  assert_eq(store.get("b1gcm/vec/global/\{delta}/meta.json"), None)
  assert_eq(store.get("b1gcm/vec/global/\{newv}/meta.json") is Some(_), true)

  // 有 global_gen 但 deltas 为空：no-op。
  let store2 = WbStore::new()
  let cfg2 = { ..cfg, ns: "b1gce" }
  ingest_delta(store2, cfg2, mkdocs(16, 8, 1UL, 7U))
  let e1 = head_manifest_of(store2, "b1gce")
  let eg = match e1.global_gen {
    Some(g) => g
    None => fail("first ingest_delta should write full base")
  }
  assert_eq(eg.deltas.length(), 0)
  compact_global(store2, cfg2, "b1gce")
  let e2 = head_manifest_of(store2, "b1gce")
  assert_eq(e2.id, e1.id)
  assert_eq(global_gen_rows(store2, "b1gce", e1.id), 16)
}

///|
test "S2b delete_docs preserves global delta chain" {
  let store = WbStore::new()
  let cfg = {
    ..BuildConfig::single_copy("b1delchain"),
    segment_rows: 8,
    nlist: 4,
    use_f16: false,
    vector_dim: 8,
  }
  let d1 = mkdocs(400, 8, 1UL, 7U)
  let d2 = mkdocs(12, 8, 101UL, 11U)
  ingest(store, cfg, d1)
  ingest_delta(store, cfg, d2)
  let before = head_manifest_of(store, "b1delchain")
  let before_gen = match before.global_gen {
    Some(g) => g
    None => fail("expected global_gen")
  }
  delete_docs(store, cfg, [d1[0].id, d2[0].id])
  let after = head_manifest_of(store, "b1delchain")
  let after_gen = match after.global_gen {
    Some(g) => g
    None => fail("delete_docs lost global_gen")
  }
  assert_eq(after_gen.base, before_gen.base)
  assert_eq(after_gen.deltas, before_gen.deltas)
  assert_eq(after.deleted.length() >= 2, true)
}
