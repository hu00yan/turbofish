// 内存 S3 模拟器：HashMap 当对象存储 + 成本记账 + 一层"块缓存"模型。
//
// 成本模型（对标 turbopuffer 的 IO 成本口径）：
// - 每个 GET / ranged GET / LIST 都计一次请求（S3 按请求数计费）
// - 字节成本只对缓存未命中生效；整对象读会预热缓存，范围读只预热所命中的区间
// - 写入总是计字节，且写入内容视为已进缓存（write-through）
//
// cache 语义是"NVMe/内存块缓存"的一阶近似，用于产出冷/热两档查询成本。

///|
struct MemClassStat {
  mut reqs : Int
  mut bytes : Int
}

///|
pub struct MemStore {
  data : Map[String, Bytes]
  versions : Map[String, Int]
  cache : Set[String]
  ranges : Map[String, Array[(Int, Int)]]
  class_stats : Map[String, MemClassStat]
  mut next_ver : Int
  mut gets : Int
  mut get_bytes : Int
  mut ranged_gets : Int
  mut ranged_bytes : Int
  mut lists : Int
  mut puts : Int
  mut put_bytes : Int
  mut deletes : Int
  mut cas_ok : Int
  mut cas_fail : Int
}

///|
pub fn MemStore::new() -> MemStore {
  {
    data: Map::new(),
    versions: Map::new(),
    cache: Set::new(),
    ranges: Map::new(),
    class_stats: Map::new(),
    next_ver: 1,
    gets: 0,
    get_bytes: 0,
    ranged_gets: 0,
    ranged_bytes: 0,
    lists: 0,
    puts: 0,
    put_bytes: 0,
    deletes: 0,
    cas_ok: 0,
    cas_fail: 0,
  }
}

///|
pub fn classify_key(key : String) -> String {
  if contains(key, "/_meta/") {
    return "meta"
  }
  if contains(key, "/_manifest/") {
    return "manifest"
  }
  if contains(key, "/_centroids/") {
    return "centroids"
  }
  if key.has_suffix("/meta.json") {
    return "segmeta"
  }
  if contains(key, "/rows/") {
    return "rows"
  }
  if contains(key, "/fts/") {
    return "fts"
  }
  if contains(key, "/vec/") {
    return "vec"
  }
  "other"
}

///|
fn contains(s : String, sub : String) -> Bool {
  let n = s.length()
  let m = sub.length()
  if m == 0 || m > n {
    return false
  }
  for i in 0..=(n - m) {
    if s.substring(start=i, end=i + m) == sub {
      return true
    }
  }
  false
}

///|
fn MemStore::record_read(self : MemStore, key : String, size : Int, cached : Bool) -> Unit {
  let cls = classify_key(key)
  let st = match self.class_stats.get(cls) {
    Some(existing) => existing
    None => {
      let fresh : MemClassStat = { reqs: 0, bytes: 0 }
      self.class_stats.set(cls, fresh)
      fresh
    }
  }
  st.reqs += 1
  if !cached {
    st.bytes += size
  }
}

///|
fn MemStore::put_raw(self : MemStore, key : String, value : Bytes) -> Unit {
  self.data.set(key, value)
  self.versions.set(key, self.next_ver)
  self.next_ver += 1
  self.cache.add(key)
  self.ranges.remove(key)
}

///|
fn version_string(v : Int) -> String {
  "v\{v}"
}

///|
pub impl ObjectStore for MemStore with get(self : MemStore, key : String) -> Bytes? {
  self.gets += 1
  match self.data.get(key) {
    Some(value) => {
      let hit = self.cache.contains(key)
      if !hit {
        self.get_bytes += value.length()
      }
      self.record_read(key, value.length(), hit)
      self.cache.add(key)
      Some(value)
    }
    None => {
      self.record_read(key, 0, true)
      None
    }
  }
}

///|
pub impl ObjectStore for MemStore with put(self : MemStore, key : String, value : Bytes) -> Unit {
  self.puts += 1
  self.put_bytes += value.length()
  self.put_raw(key, value)
}

///|
pub impl ObjectStore for MemStore with put_if_match(
  self : MemStore,
  key : String,
  expected : String?,
  value : Bytes,
) -> Bool {
  let current = match self.versions.get(key) {
    Some(v) => Some(version_string(v))
    None => None
  }
  let ok = match (expected, current) {
    (None, None) => true
    (Some(e), Some(c)) => e == c
    _ => false
  }
  if ok {
    self.put_raw(key, value)
    self.cas_ok += 1
    true
  } else {
    self.cas_fail += 1
    false
  }
}

///|
pub impl ObjectStore for MemStore with get_range(
  self : MemStore,
  key : String,
  offset : Int,
  len : Int,
) -> Bytes? {
  self.ranged_gets += 1
  match self.data.get(key) {
    Some(value) => {
      let lo = if offset < 0 { 0 } else { offset }
      let hi = if offset + len > value.length() {
        value.length()
      } else {
        offset + len
      }
      if hi <= lo {
        return Some(Bytes::make(0, b'\x00'))
      }
      // 缓存命中（整对象或已覆盖该区间）则字节成本为 0
      let ranged_hit = match self.ranges.get(key) {
        Some(rs) => rs.iter().any(r => r.0 <= lo && r.1 >= hi)
        None => false
      }
      let hit = self.cache.contains(key) || ranged_hit
      if !hit {
        self.record_read(key, hi - lo, false)
        self.ranged_bytes += hi - lo
        match self.ranges.get(key) {
          Some(rs) => rs.push((lo, hi))
          None => self.ranges.set(key, [(lo, hi)])
        }
      } else {
        self.record_read(key, 0, true)
      }
      // 返回拷贝（模拟网络传输出的独立缓冲区）
      let b = Buffer()
      b.write_bytesview(value.view(start=lo, end=hi))
      Some(b.to_bytes())
    }
    None => {
      self.record_read(key, 0, true)
      None
    }
  }
}

///|
pub impl ObjectStore for MemStore with list(self : MemStore, prefix : String) -> Array[String] {
  self.lists += 1
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
pub impl ObjectStore for MemStore with delete(self : MemStore, key : String) -> Unit {
  self.deletes += 1
  self.data.remove(key)
  self.versions.remove(key)
  self.cache.remove(key)
  self.ranges.remove(key)
}

///|
pub fn MemStore::cost(self : MemStore) -> CostSnapshot {
  let classes : Array[(String, Int, Int)] = Array::new()
  for kv in self.class_stats.iter() {
    classes.push((kv.0, kv.1.reqs, kv.1.bytes))
  }
  classes.sort_by(fn(a, b) { a.0.compare(b.0) })
  {
    gets: self.gets,
    get_bytes: self.get_bytes,
    ranged_gets: self.ranged_gets,
    ranged_bytes: self.ranged_bytes,
    lists: self.lists,
    puts: self.puts,
    put_bytes: self.put_bytes,
    deletes: self.deletes,
    cas_ok: self.cas_ok,
    cas_fail: self.cas_fail,
    classes,
  }
}

///|
pub fn MemStore::reset_cost(self : MemStore) -> Unit {
  self.gets = 0
  self.get_bytes = 0
  self.ranged_gets = 0
  self.ranged_bytes = 0
  self.lists = 0
  self.puts = 0
  self.put_bytes = 0
  self.deletes = 0
  self.cas_ok = 0
  self.cas_fail = 0
  self.class_stats.clear()
}

///|
/// 模拟冷启动：清空块缓存。
pub fn MemStore::cold(self : MemStore) -> Unit {
  self.cache.clear()
  self.ranges.clear()
}

///|
/// 全部对象的总字节数（存储量口径）。
pub fn MemStore::total_object_bytes(self : MemStore) -> Int {
  let mut total = 0
  for kv in self.data.iter() {
    total += kv.1.length()
  }
  total
}

///|
pub fn MemStore::object_count(self : MemStore) -> Int {
  self.data.length()
}

///|
pub fn MemStore::head_version(self : MemStore, key : String) -> String? {
  match self.versions.get(key) {
    Some(v) => Some(version_string(v))
    None => None
  }
}
