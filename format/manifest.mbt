// namespace.json / manifest-{id}.json 的结构体与 JSON 互转。
// u64 id 经 Double 往返在 2^53 内无损（MVP 约束）。

///|
pub(all) struct SegmentMeta {
  id : String
  row_count : Int
  min_id : UInt64
  max_id : UInt64
  doc_len_sum : Int
  size_bytes : Int
} derive(Debug)

///|
pub(all) struct ManifestData {
  id : String
  parent : String?
  segments : Array[SegmentMeta]
  deleted : Array[UInt64]
  centroid_version : String
  num_docs : Int
  avg_doc_len : Double
} derive(Debug)

///|
pub(all) struct NamespaceMeta {
  format : String
  namespace : String
  head_manifest : String
  distance_metric : String
  vector_dim : Int
  vector_dtype : String
  k1 : Double
  b : Double
} derive(Debug)

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
pub fn ManifestData::to_json(self : ManifestData) -> Json {
  let segs : Array[Json] = Array::new()
  for s in self.segments {
    let sm : Map[String, Json] = Map::new()
    sm.set("id", Json::string(s.id))
    sm.set("row_count", Json::number(s.row_count.to_double()))
    sm.set("min_id", Json::number(s.min_id.to_double()))
    sm.set("max_id", Json::number(s.max_id.to_double()))
    sm.set("doc_len_sum", Json::number(s.doc_len_sum.to_double()))
    sm.set("size_bytes", Json::number(s.size_bytes.to_double()))
    segs.push(Json::object(sm))
  }
  let dels : Array[Json] = Array::new()
  for d in self.deleted {
    dels.push(Json::number(d.to_double()))
  }
  let m : Map[String, Json] = Map::new()
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
  m.set("centroid_version", Json::string(self.centroid_version))
  m.set("num_docs", Json::number(self.num_docs.to_double()))
  m.set("avg_doc_len", Json::number(self.avg_doc_len))
  Json::object(m)
}

///|
pub fn manifest_from_json(j : Json) -> ManifestData raise @core.SpndError {
  let m = jobj(j)
  let segs_json = jarr(jfield(m, "segments"))
  let segs : Array[SegmentMeta] = Array::new()
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
  let dels : Array[UInt64] = Array::new()
  for dj in jarr(jfield(m, "deleted")) {
    dels.push(jnum(dj).to_uint64())
  }
  {
    id: jstr_at(m, "id"),
    parent: jopt_str_at(m, "parent"),
    segments: segs,
    deleted: dels,
    centroid_version: jstr_at(m, "centroid_version"),
    num_docs: jnum_at(m, "num_docs").to_int(),
    avg_doc_len: jnum_at(m, "avg_doc_len"),
  }
}

///|
pub fn NamespaceMeta::to_json(self : NamespaceMeta) -> Json {
  let m : Map[String, Json] = Map::new()
  m.set("format", Json::string(self.format))
  m.set("namespace", Json::string(self.namespace))
  m.set("head_manifest", Json::string(self.head_manifest))
  m.set("distance_metric", Json::string(self.distance_metric))
  m.set("vector_dim", Json::number(self.vector_dim.to_double()))
  m.set("vector_dtype", Json::string(self.vector_dtype))
  m.set("fts_k1", Json::number(self.k1))
  m.set("fts_b", Json::number(self.b))
  Json::object(m)
}

///|
pub fn namespace_from_json(j : Json) -> NamespaceMeta raise @core.SpndError {
  let m = jobj(j)
  {
    format: jstr_at(m, "format"),
    namespace: jstr_at(m, "namespace"),
    head_manifest: jstr_at(m, "head_manifest"),
    distance_metric: jstr_at(m, "distance_metric"),
    vector_dim: jnum_at(m, "vector_dim").to_int(),
    vector_dtype: jstr_at(m, "vector_dtype"),
    k1: jnum_at(m, "fts_k1"),
    b: jnum_at(m, "fts_b"),
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
