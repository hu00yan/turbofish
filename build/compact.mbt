// compact 合并器（spec P1）：把 manifest 里全部 live 段合并为一个新段。
//
// 语义：
// - 行 = 各段按 (segment 顺序, 段内行号) 拼接，跳过 manifest.deleted 里的 id
// - fts/doc_len/vec 全量重建；centroids 复用头 manifest 钉住的版本（不重训）
// - 编码按传入 cfg 的开关（stats/id_dense/dict/bitmap/vec_storage）
// - 新 manifest 只含 1 段、deleted=[]、parent=旧 manifest，CAS 发布
//
// 收益：消除 per-segment 局部性放大（向量查询读 part 文件数 = nprobe × 段数）。

///|
/// 读一个 segment 的六列并重建 Doc 数组（顺序 = 段内行号）。
async fn[S : @store.ObjectStore] compact_load_docs(
  store : S,
  ns : String,
  seg_id : String,
  preloaded : Array[Float]?,
  preloaded_dim : Int,
) -> Array[@core.Doc] {
  let base = "\{ns}/_segments/\{seg_id}"
  let get = async fn(key : String) -> Bytes {
    match store.get(key) {
      Some(b) => b
      None => raise @core.NotFound(key)
    }
  }
  let ids = match @format.decode_col(get("\{base}/rows/id.bin")) {
    @format.ColU64(a) => a
    _ => raise @core.Corrupt("id column dtype is not u64")
  }
  let texts = match @format.decode_col(get("\{base}/rows/text.bin")) {
    @format.ColStr(a) => a
    _ => raise @core.Corrupt("text column dtype is not str")
  }
  let cats = match @format.decode_col(get("\{base}/rows/category.bin")) {
    @format.ColStr(a) => a
    _ => raise @core.Corrupt("category column dtype is not str")
  }
  let tss = match @format.decode_col(get("\{base}/rows/ts.bin")) {
    @format.ColI64(a) => a
    _ => raise @core.Corrupt("ts column dtype is not i64")
  }
  let pubs = match @format.decode_col(get("\{base}/rows/public.bin")) {
    @format.ColBool(a) => a
    _ => raise @core.Corrupt("public column dtype is not bool")
  }
  let (dim, vec) = match preloaded {
    Some(v) => (preloaded_dim, v)
    None => @format.decode_vec_col(get("\{base}/rows/vector.bin"))
  }
  let n = ids.length()
  if texts.length() != n ||
    cats.length() != n ||
    tss.length() != n ||
    pubs.length() != n ||
    vec.length() != n * dim {
    raise @core.Corrupt("compact: column length mismatch in \{seg_id}")
  }
  let docs : Array[@core.Doc] = Array(capacity=n)
  for i in 0..<n {
    let v : Array[Float] = Array(capacity=dim)
    for d in 0..<dim {
      v.push(vec[i * dim + d])
    }
    docs.push({
      id: ids[i],
      text: texts[i],
      vector: v,
      category: cats[i],
      ts: tss[i],
      public: pubs[i],
    })
  }
  docs
}

///|
/// 合并 namespace 的全部 live 段为一个新段并 CAS 发布新 manifest。
/// 空 live 集（全部被 tombstone）时发布空段列表 manifest。
pub async fn[S : @store.ObjectStore] compact(
  store : S,
  cfg : BuildConfig,
  ns : String,
) -> Unit {
  let meta = match read_namespace(store, ns) {
    Some(m) => m
    None => raise @core.NotFound("namespace not found: \{ns}")
  }
  if meta.head_manifest == "" {
    raise @core.NotFound("no manifest published yet: \{ns}")
  }
  let old = load_manifest(store, ns, meta.head_manifest)
  let tomb : Set[UInt64] = Set([])
  for d in old.deleted {
    tomb.add(d)
  }
  let has_global = old.vec_global_version is Some(_) ||
    old.global_gen is Some(_)
  let (global_vecs, gdim) : (Map[Int, Array[Float]], Int) = if has_global {
    load_global_vec_rows(store, ns, old)
  } else {
    (Map([]), 0)
  }
  let live : Array[@core.Doc] = Array()
  for si in 0..<old.segments.length() {
    let seg = old.segments[si]
    let pre : Array[Float]? = if has_global {
      if seg.row_count == 0 {
        Some(Array())
      } else {
        match global_vecs.get(si) {
          Some(a) => Some(a)
          None =>
            raise @core.Corrupt("missing preloaded vectors for segment \{si}")
        }
      }
    } else {
      None
    }
    for d in compact_load_docs(store, ns, seg.id, pre, gdim) {
      if !tomb.contains(d.id) {
        live.push(d)
      }
    }
  }
  let c = { ..cfg, ns, }
  let parent = Some(old.id)
  if live.length() == 0 {
    let manifest : @format.ManifestData = {
      id: new_manifest_id(),
      parent,
      segments: [],
      deleted: [],
      deleted_roar: None,
      vec_global_version: None,
      global_gen: None,
      centroid_version: old.centroid_version,
      num_docs: 0,
      avg_doc_len: 0.0,
    }
    store.put(manifest_key(ns, manifest.id), json_bytes(manifest.to_json()))
    publish_head(store, ns, old.id, manifest.id)
    if old.vec_global_version is Some(_) {
      gc_global_versions_grace(store, ns, manifest.id, GLOBAL_GC_GRACE_MS)
    }
    return
  }
  // centroids 复用（不重训）
  let cent = load_centroids(store, ns, old.centroid_version)
  let seg = write_segment(store, c, cent, live, 0, live.length())
  let avg = if seg.row_count > 0 {
    seg.doc_len_sum.to_double() / seg.row_count.to_double()
  } else {
    0.0
  }
  let want_global = c.global_vec_parts && c.vec_storage == VF16
  let new_id = new_manifest_id()
  let manifest : @format.ManifestData = {
    id: new_id,
    parent,
    segments: [seg],
    deleted: [],
    deleted_roar: None,
    vec_global_version: if want_global {
      Some(new_id)
    } else {
      None
    },
    // compact 把整条 delta 链压成一个新的全量 base：global_gen 复位。
    global_gen: None,
    centroid_version: old.centroid_version,
    num_docs: seg.row_count,
    avg_doc_len: avg,
  }
  if want_global {
    let _ = rebuild_global_vec_parts(
      store,
      c,
      ns,
      cent,
      manifest,
      None,
      None,
      live,
      [(0, live.length())],
      0,
    )
  }
  store.put(manifest_key(ns, manifest.id), json_bytes(manifest.to_json()))
  publish_head(store, ns, old.id, manifest.id)
  if old.vec_global_version is Some(_) {
    gc_global_versions_grace(store, ns, manifest.id, GLOBAL_GC_GRACE_MS)
  }
}

///|
/// 预加载 manifest 全部段的向量（全局 IVF 单副本模式）。代际链
/// `manifest.global_gen = base + deltas`，**全部代都要读**——base 只有基线段，
/// delta 只含本批新段；只读 base 会让 compact 静默丢掉 delta 行（S2b）。
///
/// 返回 (seg_idx → 平铺向量, dim)。完整性校验：每个 (seg_idx,row) 必须恰好出现
/// 一次，dim 必须一致；缺 meta / 缺 part / 越界 / 重复 / 缺行一律 raise，
/// 绝不再补 0（review P1-5）。
async fn[S : @store.ObjectStore] load_global_vec_rows(
  store : S,
  ns : String,
  old : @format.ManifestData,
) -> (Map[Int, Array[Float]], Int) {
// 全局 IVF 单副本模式：从 global parts 预加载各段向量（没有 rows/vector.bin）。
// 代际链：manifest.global_gen = base + deltas，**全部代都要读**——base 只有
// 基线段，delta 只含本批新段；只读 base 会让 compact 静默丢掉 delta 行（S2b）。
// 完整性校验：每个 (seg_idx,row) 必须恰好出现一次，dim 必须一致；缺 meta /
// 缺 part / 越界 / 重复 / 缺行一律 raise，绝不再补 0（review P1-5）。
let global_vecs : Map[Int, Array[Float]] = Map([])
let seen : Map[Int, Array[Bool]] = Map([])
let mut gdim = 0
let has_global = old.vec_global_version is Some(_) ||
  old.global_gen is Some(_)
let global_vers : Array[String] = if has_global {
  global_gen_versions(old)
} else {
  []
}
let chain_base = match old.global_gen {
  Some(g) => g.base
  None => ""
}
if has_global {
  for ver in global_vers {
    let (_gm, vdim, parts) = read_global_gen_parts(
      store,
      ns,
      ver,
      Some(old),
      gdim,
      chain_base,
    )
    if vdim > 0 {
      gdim = vdim
    }
    for gp in parts {
      for i in 0..<gp.rows.length() {
        let (si, row) = gp.rows[i]
        let arr = match global_vecs.get(si) {
          Some(a) => a
          None => {
            let a : Array[Float] = Array(
              capacity=old.segments[si].row_count * gdim,
            )
            global_vecs.set(si, a)
            a
          }
        }
        let flags = match seen.get(si) {
          Some(f) => f
          None => {
            let f : Array[Bool] = Array(
              capacity=old.segments[si].row_count,
            )
            for _ in 0..<old.segments[si].row_count {
              f.push(false)
            }
            seen.set(si, f)
            f
          }
        }
        if flags[row] {
          raise @core.Corrupt("duplicate global vector row: (\{si},\{row})")
        }
        flags[row] = true
        while arr.length() < (row + 1) * gdim {
          arr.push(0.0)
        }
        for d in 0..<gdim {
          arr[row * gdim + d] = gp.data[i * gdim + d]
        }
      }
    }
  }
}
if has_global {
  if old.segments.length() > 0 && gdim == 0 {
    raise @core.Corrupt(
      "global vec metadata has no parts but manifest has segments",
    )
  }
  for si in 0..<old.segments.length() {
    let row_count = old.segments[si].row_count
    if row_count == 0 {
      continue
    }
    let arr = match global_vecs.get(si) {
      Some(a) => a
      None => raise @core.Corrupt("missing global vectors for segment \{si}")
    }
    if arr.length() != row_count * gdim {
      raise @core.Corrupt(
        "global vector count mismatch for segment \{si}: \{arr.length()} != \{row_count * gdim}",
      )
    }
    match seen.get(si) {
      Some(flags) =>
        for r in 0..<row_count {
          if !flags[r] {
            raise @core.Corrupt("missing global vector for row (\{si},\{r})")
          }
        }
      None => raise @core.Corrupt("missing global row map for segment \{si}")
    }
  }
}
  (global_vecs, gdim)
}
