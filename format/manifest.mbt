// namespace.json / manifest-{id}.json 的结构体与 JSON 互转。
// u64 id 经 Double 往返在 2^53 内无损（MVP 约束）。

///|
#derive(Debug)
pub(all) struct SegmentMeta {
  id : String
  row_count : Int
  min_id : UInt64
  max_id : UInt64
  doc_len_sum : Int
  size_bytes : Int
}

///|
/// 全局 IVF（`vec/global/*`）的代际链：`base` 是包含**全部基线段**向量的代，
/// `deltas` 按写入顺序追加后续 ingest 只含新段向量的代。读路径必须读
/// base + 全部 deltas（旧 JSON 没有该字段时视为「单代全量」，即只有
/// `vec_global_version` 指向的那一代）。
///
/// 不变式：base 与 deltas 中的每个代都是 self-contained 的 part 集合，
/// 只加不删；compact 会把整条链压成一个新的 base（`global_gen` 复位）。
#derive(Debug)
pub(all) struct GlobalGen {
  base : String
  deltas : Array[String]
}

///|
#derive(Debug)
pub(all) struct ManifestData {
  id : String
  parent : String?
  segments : Array[SegmentMeta]
  deleted : Array[UInt64]
  deleted_roar : String? // 可选：roaring tombstone 对象 key（新读路径优先）
  vec_global_version : String? // Some(v) = 向量在 vec/global/{v} 单副本；None = per-segment
  // 可选：全局 IVF delta 链（`vec_global_version` = global_gen.base）。
  // None = 旧布局（单代全量 base，无 delta）。
  global_gen : GlobalGen?
  centroid_version : String
  num_docs : Int
  avg_doc_len : Double
}

///|
#derive(Debug)
pub(all) struct NamespaceMeta {
  format : String
  ns_name : String
  head_manifest : String
  vec_global_version : String? // namespace 级全局 IVF 分区分代（None = 用 per-segment）
  distance_metric : String
  vector_dim : Int
  vector_dtype : String
  k1 : Double
  b : Double
  /// 全文分词器（"smartcn"/"kuromoji"/"nori"；None = 默认 word，旧数据兼容）。
  fts_tokenizer : String?
}

///|
fn jobj(j : Json) -> Map[String, Json] raise @core.SpndError {
  match j {
    Object(m) => m
    _ => raise @core.Corrupt("expected json object")
  }
}

///|
fn jstr(j : Json) -> String raise @core.SpndError {
  match j {
    String(s) => s
    _ => raise @core.Corrupt("expected json string")
  }
}

///|
fn jnum(j : Json) -> Double raise @core.SpndError {
  match j {
    Number(n, ..) => n
    _ => raise @core.Corrupt("expected json number")
  }
}

///|
fn jarr(j : Json) -> Array[Json] raise @core.SpndError {
  match j {
    Array(a) => a
    _ => raise @core.Corrupt("expected json array")
  }
}

///|
fn jfield(m : Map[String, Json], key : String) -> Json raise @core.SpndError {
  match m.get(key) {
    Some(v) => v
    None => raise @core.Corrupt("missing field \{key}")
  }
}

///|
fn jstr_at(m : Map[String, Json], key : String) -> String raise @core.SpndError {
  jstr(jfield(m, key))
}

///|
fn jnum_at(m : Map[String, Json], key : String) -> Double raise @core.SpndError {
  jnum(jfield(m, key))
}

///|
fn jopt_str_at(m : Map[String, Json], key : String) -> String? {
  match m.get(key) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
/// GlobalGen → Json（`{"base":..., "deltas":[...]}`）。
fn global_gen_to_json(g : GlobalGen) -> Json {
  let gm : Map[String, Json] = Map([])
  gm.set("base", Json::string(g.base))
  let ds : Array[Json] = Array(capacity=g.deltas.length())
  for d in g.deltas {
    ds.push(Json::string(d))
  }
  gm.set("deltas", Json::array(ds))
  Json::object(gm)
}

///|
/// 可选解析 `global_gen`：字段缺失 / 非对象 / 缺 `base` 都视为 None（旧数据兼容）。
/// `deltas` 缺失或含非字符串元素时按空列表/跳过处理，只保留字符串。
fn jopt_global_gen_at(m : Map[String, Json], key : String) -> GlobalGen? {
  let gm = match m.get(key) {
    Some(Object(x)) => Some(x)
    _ => None
  }
  match gm {
    Some(g) =>
      match jopt_str_at(g, "base") {
        Some(base) => {
          let deltas : Array[String] = Array()
          match g.get("deltas") {
            Some(Array(a)) =>
              for x in a {
                match x {
                  String(s) => deltas.push(s)
                  _ => ()
                }
              }
            _ => ()
          }
          Some({ base, deltas })
        }
        None => None
      }
    None => None
  }
}

///|
pub fn ManifestData::to_json(self : ManifestData) -> Json {
  let segs : Array[Json] = Array()
  for s in self.segments {
    let sm : Map[String, Json] = Map([])
    sm.set("id", Json::string(s.id))
    sm.set("row_count", Json::number(s.row_count.to_double()))
    sm.set("min_id", Json::number(s.min_id.to_double()))
    sm.set("max_id", Json::number(s.max_id.to_double()))
    sm.set("doc_len_sum", Json::number(s.doc_len_sum.to_double()))
    sm.set("size_bytes", Json::number(s.size_bytes.to_double()))
    segs.push(Json::object(sm))
  }
  let dels : Array[Json] = Array()
  for d in self.deleted {
    dels.push(Json::number(d.to_double()))
  }
  let m : Map[String, Json] = Map([])
  m.set("id", Json::string(self.id))
  m.set(
    "parent",
    match self.parent {
      Some(p) => Json::string(p)
      None => Json::null()
    },
  )
  m.set("segments", Json::array(segs))
  m.set("deleted", Json::array(dels))
  m.set(
    "deleted_roar",
    match self.deleted_roar {
      Some(k) => Json::string(k)
      None => Json::null()
    },
  )
  m.set(
    "vec_global_version",
    match self.vec_global_version {
      Some(v) => Json::string(v)
      None => Json::null()
    },
  )
  // 旧布局不写 global_gen：缺省即 None，保持旧 manifest JSON 字节不变。
  match self.global_gen {
    Some(g) => m.set("global_gen", global_gen_to_json(g))
    None => ()
  }
  m.set("centroid_version", Json::string(self.centroid_version))
  m.set("num_docs", Json::number(self.num_docs.to_double()))
  m.set("avg_doc_len", Json::number(self.avg_doc_len))
  Json::object(m)
}

///|
pub fn manifest_from_json(j : Json) -> ManifestData raise @core.SpndError {
  let m = jobj(j)
  let segs_json = jarr(jfield(m, "segments"))
  let segs : Array[SegmentMeta] = Array()
  for sj in segs_json {
    let sm = jobj(sj)
    segs.push({
      id: jstr_at(sm, "id"),
      row_count: jnum_at(sm, "row_count").to_int(),
      min_id: jnum_at(sm, "min_id").to_uint64(),
      max_id: jnum_at(sm, "max_id").to_uint64(),
      doc_len_sum: jnum_at(sm, "doc_len_sum").to_int(),
      size_bytes: jnum_at(sm, "size_bytes").to_int(),
    })
  }
  let dels : Array[UInt64] = Array()
  for dj in jarr(jfield(m, "deleted")) {
    dels.push(jnum(dj).to_uint64())
  }
  {
    id: jstr_at(m, "id"),
    parent: jopt_str_at(m, "parent"),
    segments: segs,
    deleted: dels,
    deleted_roar: jopt_str_at(m, "deleted_roar"),
    vec_global_version: jopt_str_at(m, "vec_global_version"),
    global_gen: jopt_global_gen_at(m, "global_gen"),
    centroid_version: jstr_at(m, "centroid_version"),
    num_docs: jnum_at(m, "num_docs").to_int(),
    avg_doc_len: jnum_at(m, "avg_doc_len"),
  }
}

///|
pub fn NamespaceMeta::to_json(self : NamespaceMeta) -> Json {
  let m : Map[String, Json] = Map([])
  m.set("format", Json::string(self.format))
  m.set("namespace", Json::string(self.ns_name))
  m.set("head_manifest", Json::string(self.head_manifest))
  m.set(
    "vec_global_version",
    match self.vec_global_version {
      Some(v) => Json::string(v)
      None => Json::null()
    },
  )
  m.set("distance_metric", Json::string(self.distance_metric))
  m.set("vector_dim", Json::number(self.vector_dim.to_double()))
  m.set("vector_dtype", Json::string(self.vector_dtype))
  m.set("fts_k1", Json::number(self.k1))
  m.set("fts_b", Json::number(self.b))
  m.set(
    "fts_tokenizer",
    match self.fts_tokenizer {
      Some(t) => Json::string(t)
      None => Json::null()
    },
  )
  Json::object(m)
}

///|
pub fn namespace_from_json(j : Json) -> NamespaceMeta raise @core.SpndError {
  let m = jobj(j)
  {
    format: jstr_at(m, "format"),
    ns_name: jstr_at(m, "namespace"),
    head_manifest: jstr_at(m, "head_manifest"),
    vec_global_version: jopt_str_at(m, "vec_global_version"),
    distance_metric: jstr_at(m, "distance_metric"),
    vector_dim: jnum_at(m, "vector_dim").to_int(),
    vector_dtype: jstr_at(m, "vector_dtype"),
    k1: jnum_at(m, "fts_k1"),
    b: jnum_at(m, "fts_b"),
    fts_tokenizer: jopt_str_at(m, "fts_tokenizer"),
  }
}

///|
/// demo schema.json 的静态内容（spec 第 2 节）。
pub fn demo_schema_json() -> Bytes {
  @utf8.encode(
    (
      #|{
      #|  "version": 1,
      #|  "primary_key": "id",
      #|  "fields": [
      #|    {"name": "id", "type": "u64", "index": "pk"},
      #|    {"name": "text", "type": "string", "fts": true},
      #|    {"name": "vector", "type": "vector", "dim": 768, "dtype": "f16"},
      #|    {"name": "category", "type": "string", "filter": true},
      #|    {"name": "ts", "type": "i64", "filter": true},
      #|    {"name": "public", "type": "bool", "filter": true}
      #|  ]
      #|}
    ),
  )
}

pub extend SegmentMeta with Debug::{to_repr}
pub extend GlobalGen with Debug::{to_repr}
pub extend ManifestData with Debug::{to_repr}
pub extend NamespaceMeta with Debug::{to_repr}
