// FsStore：本地目录 ObjectStore（native only，POSIX 文件 FFI）。
//
// 布局：
// - 数据文件   {root}/{key}                  （key 是相对路径，'/' 建子目录）
// - 版本文件   {root}/{dir}/.{base}.ver      （sidecar，内容 "v{n}"，与 MemStore 同语义）
// - 索引文件   {root}/.turbofish_index.json  （JSON 数组 [{"key","size"}..]）
//
// list 的 MVP 降级说明（契约允许）：不做 readdir FFI，list/前缀过滤全部走
// .turbofish_index.json 索引。索引由 put/delete 维护；绕过 FsStore 直接落盘的
// 文件不会出现在 list 里。数据文件本身仍按 key 落盘，get/get_range 不依赖索引。
//
// put 原子性：先写 {path}.tmp 再 rename（POSIX rename 同目录内原子）。
//
// 错误模型：ObjectStore trait 方法不允许 raise，因此——
// - 非法 key / 磁盘写失败：abort（契约违反或环境损坏，宁可崩也不静默丢数据）
// - 读失败（key 不存在 / 读不了）：按 MemStore 语义返回 None / 空区间
// 需要优雅处理的调用方用 raising 的 FsStore::check_key 先行校验。
//
// 并发：单进程 MVP。跨进程并发写同一 root 不做锁（索引与版本可能互相覆盖）。

///|
/// 本地目录对象存储。root 末尾的 '/' 会被剥掉。
pub struct FsStore {
  root : String
  mut index_cache : Map[String, Int]?
}

///|
/// 创建 store 并确保 root 目录存在。
pub fn FsStore::new(root : String) -> FsStore {
  let mut r = root
  while r.length() > 1 && r.has_suffix("/") {
    r = r[:r.length() - 1].to_owned()
  }
  let s = FsStore::{ root: r, index_cache: None }
  fs_mkdir_p(r, "")
  s
}

///|
/// key 校验：字符白名单 [A-Za-z0-9._/-]；禁止空 key、前导 '/'、连续 '/'、
/// ".."（目录逃逸）、以 '.' 开头的路径段（避免与 sidecar .ver / 索引文件冲突）、
/// 以 ".tmp" 结尾的路径段（避免与原子写临时文件冲突）。
/// 非法一律 raise @core.Corrupt。
pub fn FsStore::check_key(key : String) -> String raise @core.SpndError {
  if key.length() == 0 {
    raise @core.Corrupt("fsstore: empty key")
  }
  if key.has_prefix("/") {
    raise @core.Corrupt("fsstore: absolute key")
  }
  for seg in key.split("/") {
    check_segment(seg)
  }
  key
}

///|
fn check_segment(seg : StringView) -> Unit raise @core.SpndError {
  if seg.is_empty() {
    raise @core.Corrupt("fsstore: empty path component")
  }
  if seg == ".." {
    raise @core.Corrupt("fsstore: '..' not allowed")
  }
  match seg.get_char(0) {
    Some(c) =>
      if c.to_int() == 46 {
        // '.' 开头：与 .ver sidecar / 索引文件同名空间冲突
        raise @core.Corrupt("fsstore: dot-leading component")
      }
    None => raise @core.Corrupt("fsstore: empty path component")
  }
  if seg.has_suffix(".tmp") {
    raise @core.Corrupt("fsstore: '.tmp' suffix reserved")
  }
  for ch in seg.iter() {
    let c = ch.to_int()
    let ok = (c >= 48 && c <= 57) ||
      (c >= 65 && c <= 90) ||
      (c >= 97 && c <= 122) ||
      c == 46 ||
      c == 45 ||
      c == 95
    if !ok {
      raise @core.Corrupt("fsstore: illegal character in key")
    }
  }
}

///|
/// trait 方法内部用的校验：非法 key 视为程序员错误，直接 abort。
fn FsStore::checked(_self : FsStore, key : String) -> String {
  FsStore::check_key(key) catch {
    _ => abort("fsstore: invalid key")
  }
}

///|
fn dir_of(key : String) -> String {
  match key.rev_find("/") {
    Some(i) => key[:i + 1].to_owned()
    None => ""
  }
}

///|
fn FsStore::data_path(self : FsStore, key : String) -> String {
  self.root + "/" + key
}

///|
/// 数据文件的绝对路径（先按 FsStore 规则校验 key）。
/// 供上层完成引擎（io_uring / pread worker pool）直接按路径读，
/// 语义与 `ObjectStore::get` 完全一致；写路径仍走 `put`（需要原子 rename +
/// `.ver` 版本 sidecar + 索引维护，不能绕过）。
pub fn FsStore::file_path(
  self : FsStore,
  key : String,
) -> String raise @core.SpndError {
  self.data_path(FsStore::check_key(key))
}

///|
/// 版本 sidecar 与数据文件同目录：key "a/b/c.bin" → "a/b/.c.bin.ver"。
fn FsStore::ver_path(self : FsStore, key : String) -> String {
  let dir = dir_of(key)
  let mut base = key
  if dir.length() > 0 {
    base = key[dir.length():].to_owned()
  }
  self.root + "/" + dir + "." + base + ".ver"
}

///|
fn FsStore::index_path(self : FsStore) -> String {
  self.root + "/.turbofish_index.json"
}

// ---------- 原语层 ----------

///|
/// read() 可能短读，循环读满
fn fd_read_all(fd : Int, buf : FixedArray[Byte]) -> Bool {
  let n = buf.length()
  let mut done = 0
  while done < n {
    let got = c_read(fd, buf, n.to_uint64() - done.to_uint64())
    if got <= 0L {
      return false
    }
    done += got.to_int()
  }
  true
}

///|
/// write() 可能短写，循环写完
fn fd_write_all(fd : Int, buf : FixedArray[Byte]) -> Bool {
  let n = buf.length()
  let mut done = 0
  while done < n {
    let put = c_write(fd, buf, n.to_uint64() - done.to_uint64())
    if put <= 0L {
      return false
    }
    done += put.to_int()
  }
  true
}

///|
/// 读整个文件；打不开返回 None
fn fs_read_all(path : String) -> Bytes? {
  let fd = c_open_ro(cstr(path), 0)
  if fd < 0 {
    return None
  }
  let size = c_lseek(fd, 0L, 2) // SEEK_END
  if size < 0L || size > 2147483647L {
    ignore(c_close(fd))
    return None
  }
  ignore(c_lseek(fd, 0L, 0)) // SEEK_SET
  let buf = FixedArray::make(size.to_int(), b'\x00')
  let ok = fd_read_all(fd, buf)
  ignore(c_close(fd))
  if ok {
    Some(Bytes::from_array(buf))
  } else {
    None
  }
}

///|
/// 原子写：先写 path.tmp 再 rename。成功返回 true。
fn fs_write_atomic(path : String, data : Bytes) -> Bool {
  let tmp = path + ".tmp"
  let fd = c_creat(cstr(tmp), 420U) // 0644, O_WRONLY|O_CREAT|O_TRUNC
  if fd < 0 {
    return false
  }
  if !fd_write_all(fd, data.to_fixedarray()) {
    ignore(c_close(fd))
    ignore(c_unlink(cstr(tmp)))
    return false
  }
  if c_close(fd) != 0 {
    ignore(c_unlink(cstr(tmp)))
    return false
  }
  if c_rename(cstr(tmp), cstr(path)) != 0 {
    ignore(c_unlink(cstr(tmp)))
    return false
  }
  true
}

///|
/// 逐级建目录（mkdir -p），失败忽略——真正的失败由后续写暴露。
fn fs_mkdir_p(root : String, rel_dir : String) -> Unit {
  ignore(c_mkdir(cstr(root), 493U)) // 0755，已存在时 EEXIST 被忽略
  let mut acc = root
  for seg in rel_dir.split("/") {
    if seg.is_empty() {
      continue
    }
    acc = acc + "/" + seg.to_owned()
    ignore(c_mkdir(cstr(acc), 493U)) // 0755
  }
}

// ---------- 版本 sidecar ----------

///|
/// 读版本号（Int）；sidecar 缺失或内容损坏都按"无版本"处理（下次 put 自愈）。
fn FsStore::read_version(self : FsStore, key : String) -> Int? {
  let bs = fs_read_all(self.ver_path(key))
  match bs {
    Some(content) => {
      let s = @utf8.decode(content.exact_view()) catch { _ => return None }
      parse_version(s)
    }
    None => None
  }
}

///|
fn parse_version(s : String) -> Int? {
  if !s.has_prefix("v") {
    return None
  }
  let digits = s[1:].to_owned()
  if digits.length() == 0 {
    return None
  }
  let mut n = 0
  for ch in digits.iter() {
    let c = ch.to_int()
    if c < 48 || c > 57 {
      return None
    }
    n = n * 10 + (c - 48)
  }
  Some(n)
}

///|
fn FsStore::bump_version(self : FsStore, key : String) -> Unit {
  let cur = match self.read_version(key) {
    Some(n) => n
    None => 0
  }
  let ok = fs_write_atomic(self.ver_path(key), @utf8.encode("v\{cur + 1}"))
  if !ok {
    abort("fsstore: cannot write version sidecar")
  }
}

///|
/// 当前版本串（"v{n}"），与 MemStore::head_version 同语义。
pub fn FsStore::head_version(self : FsStore, key : String) -> String? {
  let k = self.checked(key)
  match self.read_version(k) {
    Some(n) => Some("v\{n}")
    None => None
  }
}

// ---------- 索引（list 的 MVP 降级实现） ----------

///|
/// 读索引；文件缺失返回空数组；损坏 abort（索引是唯一 list 来源，坏了宁可响）。
fn FsStore::load_index(self : FsStore) -> Array[(String, Int)] {
  let out : Array[(String, Int)] = Array()
  let content = match fs_read_all(self.index_path()) {
    Some(bs) => bs
    None => return out
  }
  let text = @utf8.decode(content.exact_view()) catch {
    _ => abort("fsstore: index not utf8")
  }
  let j = @json.parse(text) catch {
    _ => abort("fsstore: index not json")
  }
  match j {
    Json::Array(items) =>
      for it in items {
        match it {
          Json::Object(m) => {
            let k = match m.get("key") {
              Some(Json::String(s)) => s
              _ => abort("fsstore: index entry missing key")
            }
            let sz = match m.get("size") {
              Some(Json::Number(d, ..)) => d.to_int()
              _ => 0
            }
            out.push((k, sz))
          }
          _ => abort("fsstore: index entry not object")
        }
      }
    _ => abort("fsstore: index root not array")
  }
  out
}

///|
fn FsStore::save_index_map(self : FsStore, m : Map[String, Int]) -> Unit {
  let items : Array[Json] = Array(capacity=m.length())
  for k, sz in m {
    let entry : Map[String, Json] = Map([])
    entry.set("key", Json::string(k))
    entry.set("size", Json::number(sz.to_double()))
    items.push(Json::object(entry))
  }
  let text = Json::array(items).stringify()
  let ok = fs_write_atomic(self.index_path(), @utf8.encode(text))
  if !ok {
    abort("fsstore: cannot write index")
  }
}

///|
fn FsStore::get_index_map(self : FsStore) -> Map[String, Int] {
  match self.index_cache {
    Some(m) => m
    None => {
      let entries = self.load_index()
      let m : Map[String, Int] = Map([])
      for e in entries {
        m.set(e.0, e.1)
      }
      self.index_cache = Some(m)
      m
    }
  }
}

///|
fn FsStore::index_update(self : FsStore, key : String, size : Int) -> Unit {
  let m = self.get_index_map()
  m.set(key, size)
  self.save_index_map(m)
}

///|
fn FsStore::index_remove(self : FsStore, key : String) -> Unit {
  let m = self.get_index_map()
  if m.contains(key) {
    m.remove(key)
    self.save_index_map(m)
  }
}

// ---------- ObjectStore 实现 ----------

///|
/// put 公共路径：mkdir -p → 原子写数据 → bump 版本 → 更新索引
fn FsStore::put_raw(self : FsStore, key : String, value : Bytes) -> Unit {
  fs_mkdir_p(self.root, dir_of(key))
  if !fs_write_atomic(self.data_path(key), value) {
    abort("fsstore: write failed")
  }
  self.bump_version(key)
  self.index_update(key, value.length())
}

///|
pub impl @store.ObjectStore for FsStore with fn get(
  self : FsStore,
  key : String,
) -> Bytes? {
  let k = self.checked(key)
  fs_read_all(self.data_path(k))
}

///|
pub impl @store.ObjectStore for FsStore with fn put(
  self : FsStore,
  key : String,
  value : Bytes,
) -> Unit {
  let k = self.checked(key)
  self.put_raw(k, value)
}

///|
/// CAS 语义与 MemStore 一致：
/// expected=None 要求 key 不存在；Some(e) 要求当前版本串相等；否则失败不写。
pub impl @store.ObjectStore for FsStore with fn put_if_match(
  self : FsStore,
  key : String,
  expected : String?,
  value : Bytes,
) -> Bool {
  let k = self.checked(key)
  let current = self.read_version(k)
  let ok = match (expected, current) {
    (None, None) => true
    (Some(e), Some(c)) => e == "v\{c}"
    _ => false
  }
  if ok {
    self.put_raw(k, value)
    true
  } else {
    false
  }
}

///|
/// 范围读 [offset, offset+len)，越界截短，与 MemStore::get_range 公式一致。
pub impl @store.ObjectStore for FsStore with fn get_range(
  self : FsStore,
  key : String,
  offset : Int,
  len : Int,
) -> Bytes? {
  let k = self.checked(key)
  let fd = c_open_ro(cstr(self.data_path(k)), 0)
  if fd < 0 {
    return None
  }
  let size = c_lseek(fd, 0L, 2) // SEEK_END
  if size < 0L || size > 2147483647L {
    ignore(c_close(fd))
    return None
  }
  let isize = size.to_int()
  let lo = if offset < 0 { 0 } else { offset }
  let hi = if offset + len > isize { isize } else { offset + len }
  if hi <= lo {
    ignore(c_close(fd))
    return Some(Bytes::make(0, b'\x00'))
  }
  ignore(c_lseek(fd, lo.to_int64(), 0)) // SEEK_SET
  let buf = FixedArray::make(hi - lo, b'\x00')
  let ok = fd_read_all(fd, buf)
  ignore(c_close(fd))
  if ok {
    Some(Bytes::from_array(buf))
  } else {
    None
  }
}

///|
/// 前缀列出（走索引文件，见文件头 MVP 降级说明）。返回升序。
pub impl @store.ObjectStore for FsStore with fn list(
  self : FsStore,
  prefix : String,
) -> Array[String] {
  let m = self.get_index_map()
  let out : Array[String] = Array()
  for k, _ in m {
    if k.has_prefix(prefix) {
      out.push(k)
    }
  }
  out.sort()
  out
}

///|
/// 删除数据文件 + 版本 sidecar + 索引项。key 不存在时静默（与 MemStore 一致）。
pub impl @store.ObjectStore for FsStore with fn delete(
  self : FsStore,
  key : String,
) -> Unit {
  let k = self.checked(key)
  ignore(c_unlink(cstr(self.data_path(k))))
  ignore(c_unlink(cstr(self.ver_path(k))))
  self.index_remove(k)
}

///|
pub impl @store.ObjectStore for FsStore with fn head_version(
  self : FsStore,
  key : String
) -> String? {
  self.head_version(key)
}

// ---------- BatchStore（顺序等价批取，见 store/batch.mbt 契约） ----------

///|
/// 顺序 fallback：逐项委托现有单键 get；返回长度与输入一致，None 停在原下标。
pub impl @store.BatchStore for FsStore with fn get_many(
  self : FsStore,
  keys : Array[String],
) -> Array[Bytes?] {
  let out : Array[Bytes?] = Array()
  for k in keys {
    out.push(self.get(k))
  }
  out
}

///|
/// 顺序 fallback：逐项委托现有单键 get_range（元素为 (key, offset, len)）。
pub impl @store.BatchStore for FsStore with fn get_range_many(
  self : FsStore,
  ranges : Array[(String, Int, Int)],
) -> Array[Bytes?] {
  let out : Array[Bytes?] = Array()
  for r in ranges {
    out.push(self.get_range(r.0, r.1, r.2))
  }
  out
}

pub extend FsStore with @turbofish/store.ObjectStore::{put_if_match, put, list, get_range, get, delete, put_many}
pub extend FsStore with @turbofish/store.BatchStore::{get_many, get_range_many}
