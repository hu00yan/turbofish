// PartStore 与 ManifestStore 的对象存储实现（ObjPartStore / ObjManifestStore）。
//
// 契约纪律：
// 1. ObjPartStore：PUT 一个紧凑 part 仅产生 1 次 S3 PUT 请求，写入 {ns}/_parts/{part_id}.cpt；
// 2. Range GET：get_part_range 直接透传 store.get_range，供 Footer 与切片按需读取；
// 3. ObjManifestStore：通过 head pointer 换代发布与加载，读路径零 LIST 请求。

///|
pub struct ObjPartStore[S] {
  store : S
  ns : String
}

///|
pub fn[S : @store.ObjectStore] ObjPartStore::new(
  store : S,
  ns : String
) -> ObjPartStore[S] {
  { store, ns }
}

///|
pub fn[S] ObjPartStore::part_key(self : ObjPartStore[S], part_id : String) -> String {
  "\{self.ns}/_parts/\{part_id}.cpt"
}

///|
impl[S : @store.ObjectStore] PartStore for ObjPartStore[S] with put_part(
  self,
  bs : Bytes
) -> String {
  let part_id = @core.next_id()
  let key = self.part_key(part_id)
  self.store.put(key, bs)
  part_id
}

///|
impl[S : @store.ObjectStore] PartStore for ObjPartStore[S] with get_part(
  self,
  part_id : String
) -> Bytes? {
  self.store.get(self.part_key(part_id))
}

///|
impl[S : @store.ObjectStore] PartStore for ObjPartStore[S] with get_part_range(
  self,
  part_id : String,
  offset : Int,
  len : Int
) -> Bytes? {
  self.store.get_range(self.part_key(part_id), offset, len)
}

///|
pub struct ObjManifestStore[S] {
  store : S
  ns : String
}

///|
pub fn[S : @store.ObjectStore] ObjManifestStore::new(
  store : S,
  ns : String
) -> ObjManifestStore[S] {
  { store, ns }
}

///|
pub fn[S] ObjManifestStore::head_ptr_key(self : ObjManifestStore[S]) -> String {
  @store.head_pointer_key(self.ns)
}

///|
pub fn[S] ObjManifestStore::manifest_key(
  self : ObjManifestStore[S],
  seq : UInt64
) -> String {
  "\{self.ns}/_manifest/manifest-\{seq}.json"
}

///|
fn manifest_to_json(m : Manifest) -> Json {
  let root : Map[String, Json] = Map([])
  root.set("seq", Json::number(m.seq.to_double()))
  let parts_arr : Array[Json] = Array::new(capacity=m.parts.length())
  for p in m.parts {
    let pm : Map[String, Json] = Map([])
    pm.set("part_id", Json::string(p.part_id))
    pm.set("level", Json::number(p.level.to_double()))
    pm.set("row_count", Json::number(p.row_count.to_double()))
    pm.set("min_id", Json::number(p.min_id.to_double()))
    pm.set("max_id", Json::number(p.max_id.to_double()))
    pm.set("size_bytes", Json::number(p.size_bytes.to_double()))
    pm.set("tombstone_count", Json::number(p.tombstone_count.to_double()))
    parts_arr.push(Json::object(pm))
  }
  root.set("parts", Json::array(parts_arr))
  let tombstones_arr : Array[Json] = Array::new(capacity=m.tombstones.length())
  for t in m.tombstones {
    tombstones_arr.push(Json::number(t.to_double()))
  }
  root.set("tombstones", Json::array(tombstones_arr))
  Json::object(root)
}

///|
fn manifest_from_json(j : Json) -> Manifest raise @core.SpndError {
  let root = match j {
    Object(m) => m
    _ => raise @core.Corrupt("manifest is not json object")
  }
  let seq = match root.get("seq") {
    Some(Number(n, ..)) => n.to_uint64()
    _ => 0UL
  }
  let parts : Array[PartMeta] = Array::new()
  match root.get("parts") {
    Some(Array(arr)) =>
      for item in arr {
        match item {
          Object(pm) => {
            let part_id = match pm.get("part_id") {
              Some(String(s)) => s
              _ => raise @core.Corrupt("part_id missing in part meta")
            }
            let level = match pm.get("level") {
              Some(Number(n, ..)) => n.to_int()
              _ => 0
            }
            let row_count = match pm.get("row_count") {
              Some(Number(n, ..)) => n.to_int()
              _ => 0
            }
            let min_id = match pm.get("min_id") {
              Some(Number(n, ..)) => n.to_uint64()
              _ => 0UL
            }
            let max_id = match pm.get("max_id") {
              Some(Number(n, ..)) => n.to_uint64()
              _ => 0UL
            }
            let size_bytes = match pm.get("size_bytes") {
              Some(Number(n, ..)) => n.to_int()
              _ => 0
            }
            let tombstone_count = match pm.get("tombstone_count") {
              Some(Number(n, ..)) => n.to_int()
              _ => 0
            }
            parts.push({
              part_id,
              level,
              row_count,
              min_id,
              max_id,
              size_bytes,
              tombstone_count,
            })
          }
          _ => ()
        }
      }
    _ => ()
  }
  let tombstones : Array[UInt64] = Array::new()
  match root.get("tombstones") {
    Some(Array(arr)) =>
      for item in arr {
        match item {
          Number(n, ..) => tombstones.push(n.to_uint64())
          _ => ()
        }
      }
    _ => ()
  }
  { seq, parts, tombstones }
}

///|
impl[S : @store.ObjectStore] ManifestStore for ObjManifestStore[S] with load(
  self
) -> Manifest raise @core.SpndError {
  let head_ptr = match self.store.get(self.head_ptr_key()) {
    Some(bs) =>
      @utf8.decode(bs.view()) catch {
        _ => raise @core.Corrupt("invalid head_manifest pointer utf8")
      }
    None => return Manifest::new()
  }
  if head_ptr == "" {
    return Manifest::new()
  }
  let mkey = "\{self.ns}/_manifest/\{head_ptr}.json"
  match self.store.get(mkey) {
    Some(bs) => {
      let s = @utf8.decode(bs.view()) catch {
        _ => raise @core.Corrupt("manifest utf8 error")
      }
      let j = @json.parse(s) catch {
        _ => raise @core.Corrupt("manifest json parse error")
      }
      manifest_from_json(j)
    }
    None => raise @core.NotFound(mkey)
  }
}

///|
impl[S : @store.ObjectStore] ManifestStore for ObjManifestStore[S] with publish(
  self,
  m : Manifest
) -> Unit raise @core.SpndError {
  let mjson = manifest_to_json(m)
  let bs = @utf8.encode(mjson.stringify())
  let mkey = self.manifest_key(m.seq)
  self.store.put(mkey, bs)
  let head_val = "manifest-\{m.seq}"
  self.store.put(self.head_ptr_key(), @utf8.encode(head_val))
}
