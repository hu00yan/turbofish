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
struct WbStore {
  data : Map[String, Bytes]
  versions : Map[String, Int]
  mut next_ver : Int
}

///|
fn WbStore::new() -> WbStore {
  { data: Map::new(), versions: Map::new(), next_ver: 1 }
}

///|
fn WbStore::put_raw(self : WbStore, key : String, value : Bytes) -> Unit {
  self.data.set(key, value)
  self.versions.set(key, self.next_ver)
  self.next_ver += 1
}

///|
impl @store.ObjectStore for WbStore with get(self : WbStore, key : String) -> Bytes? {
  self.data.get(key)
}

///|
impl @store.ObjectStore for WbStore with put(self : WbStore, key : String, value : Bytes) -> Unit {
  self.put_raw(key, value)
}

///|
impl @store.ObjectStore for WbStore with put_if_match(
  self : WbStore,
  key : String,
  expected : String?,
  value : Bytes,
) -> Bool {
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
impl @store.ObjectStore for WbStore with get_range(
  self : WbStore,
  key : String,
  offset : Int,
  len : Int,
) -> Bytes? {
  match self.data.get(key) {
    Some(value) => {
      let lo = if offset < 0 {
        0
      } else {
        offset
      }
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
impl @store.ObjectStore for WbStore with list(self : WbStore, prefix : String) -> Array[String] {
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
impl @store.ObjectStore for WbStore with delete(self : WbStore, key : String) -> Unit {
  self.data.remove(key)
  self.versions.remove(key)
}

///|
/// 确定性生成 n 条 docs（Rng 种子固定；id = id_base + i，文本含 ASCII 与中文词）。
fn mkdocs(n : Int, dim : Int, id_base : UInt64, seed : UInt) -> Array[@core.Doc] {
  let rng = @core.Rng::new(seed)
  let words = [
    "alpha", "beta", "gamma", "delta", "search", "engine", "向量", "检索",
  ]
  let docs : Array[@core.Doc] = Array::new()
  for i in 0..<n {
    let mut text = ""
    let ntok = 5 + (rng.next_u32() % 6U).to_int()
    for _ in 0..<ntok {
      let w = words[(rng.next_u32() % words.length().to_uint()).to_int()]
      text = text + w + " "
    }
    let vec : Array[Float] = Array::new(capacity=dim)
    for _ in 0..<dim {
      vec.push(rng.next_range(-1.0, 1.0).to_float())
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
fn must_get[S : @store.ObjectStore](store : S, key : String) -> Bytes raise @core.SpndError {
  match store.get(key) {
    Some(b) => b
    None => raise @core.NotFound("missing object: \{key}")
  }
}

///|
fn head_manifest_of[S : @store.ObjectStore](
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
fn seg_partitions[S : @store.ObjectStore](
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
  let cfg : BuildConfig = { ns: "t1", segment_rows: 8, nlist: 4, use_f16: true, vector_dim: 8 }
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
  assert_eq(ns.namespace, "t1")
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
  let (vdim, vdata) = @format.decode_vec_col(must_get(store, "\{p0}/rows/vector.bin"))
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
  assert_eq(@core.read_u32_le(dir_bs, 16).to_int(), 8)
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
  let cfg : BuildConfig = { ns: "t2", segment_rows: 8, nlist: 4, use_f16: false, vector_dim: 8 }
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
  assert_eq(ns2.namespace, "t2")
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
  let (vdim, vdata) = @format.decode_vec_col(must_get(store, "\{pl}/rows/vector.bin"))
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
  let cfg : BuildConfig = { ns: "t3", segment_rows: 8, nlist: 4, use_f16: true, vector_dim: 8 }
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
  let cfg : BuildConfig = { ns: "ghost", segment_rows: 8, nlist: 4, use_f16: true, vector_dim: 8 }
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
    namespace: "fresh",
    head_manifest: "",
    distance_metric: "cosine",
    vector_dim: 8,
    vector_dtype: "f16",
    k1: 1.2,
    b: 0.75,
  }
  store.put("fresh/_meta/namespace.json", @utf8.encode(meta.to_json().stringify()))
  let cfg : BuildConfig = { ns: "fresh", segment_rows: 8, nlist: 4, use_f16: true, vector_dim: 8 }
  try {
    delete_docs(store, cfg, [1UL])
    panic()
  } catch {
    _ => ()
  }
}
