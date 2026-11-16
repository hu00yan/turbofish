///|

// FsStore 全流程测试（native target 专用，见 moon.pkg targets）。
// 每个测试用 @core.next_id() 生成唯一 root，互不污染、无需清理。

///|
/// 跨运行唯一的临时根目录：getpid（进程内 next_id 计数器每次 moon test 重置，
/// 必须掺入 pid 才能避免吃掉上次运行残留的版本状态）
fn fresh_root(prefix : String) -> String {
  "/tmp/turbofish_fsstore_\{prefix}_p\{test_pid()}_\{@core.next_id()}"
}

///|
/// 测试收尾：删光本测试写入的全部对象（数据 + .ver sidecar + 索引项），
/// 保证 pid 回收撞名时新运行也是干净起点
async fn cleanup_store(s : FsStore) -> Unit {
  let keys = s.list("")
  for k in keys {
    s.delete(k)
  }
}

///|
async test "put/get roundtrip + overwrite" {
  let s = FsStore::new(fresh_root("rw"))
  let data = b"hello turbofish"
  s.put("ns/a.bin", data)
  assert_eq(s.get("ns/a.bin"), Some(data))
  // 覆盖写
  let data2 = b"second version!"
  s.put("ns/a.bin", data2)
  assert_eq(s.get("ns/a.bin"), Some(data2))
  // 不存在的 key
  assert_eq(s.get("ns/missing.bin"), None)
  // 无目录前缀的 key
  s.put("top.bin", b"top")
  assert_eq(s.get("top.bin"), Some(b"top"))
  cleanup_store(s)
}

///|
async test "get_range: 区间读 + 越界截短 + 空区间" {
  let s = FsStore::new(fresh_root("range"))
  let data = Bytes::makei(100, i => (i % 251).to_byte())
  s.put("seg/rows/id.bin", data)
  // 正常区间 [10, 30)
  assert_eq(
    s.get_range("seg/rows/id.bin", @store.ByteRange::{ off: 10, len: 20 }),
    Some(data[10:30].to_owned()),
  )
  // 越界截短：[90, 200) → [90, 100)
  assert_eq(
    s.get_range("seg/rows/id.bin", @store.ByteRange::{ off: 90, len: 110 }),
    Some(data[90:100].to_owned()),
  )
  // offset 超出文件大小 → 空
  assert_eq(
    s.get_range("seg/rows/id.bin", @store.ByteRange::{ off: 100, len: 5 }),
    Some(Bytes::make(0, b'\x00')),
  )
  // 全量
  assert_eq(s.get_range("seg/rows/id.bin", @store.ByteRange::{ off: 0, len: 100 }), Some(data))
  // 不存在的 key
  assert_eq(s.get_range("seg/nope.bin", @store.ByteRange::{ off: 0, len: 5 }), None)
  // len=0 → 空
  assert_eq(
    s.get_range("seg/rows/id.bin", @store.ByteRange::{ off: 10, len: 0 }),
    Some(Bytes::make(0, b'\x00')),
  )
  cleanup_store(s)
}

///|
async test "list: 升序 + 前缀过滤（索引驱动）" {
  let s = FsStore::new(fresh_root("list"))
  s.put("ns/_segments/s2/meta.json", b"2")
  s.put("ns/_segments/s1/meta.json", b"1")
  s.put("ns/_meta/namespace.json", b"m")
  s.put("other/x.bin", b"x")
  // 全量升序：与 MemStore 一致，用 Array::sort() 同一比较器
  // （moonc 2026-06 的 String::compare 是"长度优先、再按码位"，见报告）
  let expected = [
    "ns/_meta/namespace.json", "ns/_segments/s1/meta.json", "ns/_segments/s2/meta.json",
    "other/x.bin",
  ]
  expected.sort()
  assert_eq(s.list(""), expected)
  // 前缀过滤
  assert_eq(s.list("ns/_segments/"), [
    "ns/_segments/s1/meta.json", "ns/_segments/s2/meta.json",
  ])
  assert_eq(s.list("ns/_segments/s1"), ["ns/_segments/s1/meta.json"])
  assert_eq(s.list("zzz/"), [])
  // 覆盖写后 list 不重复
  s.put("ns/_segments/s1/meta.json", b"1b")
  assert_eq(s.list("ns/_segments/s1").length(), 1)
  cleanup_store(s)
}

///|
async test "list 排序与 MemStore 完全一致" {
  let f = FsStore::new(fresh_root("xsort"))
  let m = @store.MemStore::new()
  let keys = ["b/2", "a/1", "bbb", "a/0/x", "c"]
  for k in keys {
    f.put(k, b"x")
    m.put(k, b"x")
  }
  assert_eq(f.list(""), m.list(""))
  cleanup_store(f)
}

///|
async test "delete: 数据 + 版本 sidecar + 索引项" {
  let s = FsStore::new(fresh_root("del"))
  s.put("a/b.bin", b"data")
  assert_eq(s.get("a/b.bin"), Some(b"data"))
  assert_eq(s.head_version("a/b.bin"), Some("v1"))
  s.delete("a/b.bin")
  assert_eq(s.get("a/b.bin"), None)
  assert_eq(s.head_version("a/b.bin"), None)
  assert_eq(s.list("a/"), [])
  // 版本 sidecar 文件也被删掉了（可再次 CAS None 建立）
  assert_eq(s.put_if_match("a/b.bin", @store.Expected(None), b"again"), true)
  // 删不存在的 key 是 no-op
  s.delete("a/b.bin")
  s.delete("never/existed.bin")
  assert_eq(s.list(""), [])
  cleanup_store(s)
}

///|
async test "put_if_match: 与 MemStore 一致的 CAS 语义" {
  let s = FsStore::new(fresh_root("cas"))
  // 新 key：expected=None 成功
  assert_eq(s.put_if_match("m/manifest.json", @store.Expected(None), b"v1-body"), true)
  assert_eq(s.head_version("m/manifest.json"), Some("v1"))
  // 新 key：expected=None 第二次必须失败（key 已存在）
  assert_eq(s.put_if_match("m/manifest.json", @store.Expected(None), b"bad"), false)
  // 正确版本串成功，版本自增
  assert_eq(s.put_if_match("m/manifest.json", @store.Expected(Some("v1")), b"v2-body"), true)
  assert_eq(s.get("m/manifest.json"), Some(b"v2-body"))
  assert_eq(s.head_version("m/manifest.json"), Some("v2"))
  // 过期版本失败，内容不变
  assert_eq(s.put_if_match("m/manifest.json", @store.Expected(Some("v1")), b"stale"), false)
  assert_eq(s.get("m/manifest.json"), Some(b"v2-body"))
  assert_eq(s.head_version("m/manifest.json"), Some("v2"))
  // 现版本再次成功
  assert_eq(s.put_if_match("m/manifest.json", @store.Expected(Some("v2")), b"v3-body"), true)
  assert_eq(s.head_version("m/manifest.json"), Some("v3"))
  // 不存在的 key：Some 期望失败
  assert_eq(s.put_if_match("m/nope.json", @store.Expected(Some("v1")), b"x"), false)
  cleanup_store(s)
}

///|
async test "put: 普通写也推进版本（与 MemStore put_raw 一致）" {
  let s = FsStore::new(fresh_root("ver"))
  s.put("k.bin", b"1")
  s.put("k.bin", b"2")
  s.put("k.bin", b"3")
  assert_eq(s.head_version("k.bin"), Some("v3"))
  assert_eq(s.get("k.bin"), Some(b"3"))
  cleanup_store(s)
}

///|
async test "sidecar 布局：数据按 key 落盘，版本在同目录 .{base}.ver" {
  let root = fresh_root("layout")
  let s = FsStore::new(root)
  let data = b"payload"
  s.put("ns/_segments/seg1/rows/id.bin", data)
  // 数据文件真的在 {root}/{key}
  assert_eq(fs_read_all(root + "/ns/_segments/seg1/rows/id.bin"), Some(data))
  // 版本 sidecar 在同目录
  assert_eq(
    fs_read_all(root + "/ns/_segments/seg1/rows/.id.bin.ver"),
    Some(@utf8.encode("v1")),
  )
  // 索引文件存在且记录了 key
  assert_eq(s.list("ns/_segments/seg1/rows/"), ["ns/_segments/seg1/rows/id.bin"])
  cleanup_store(s)
}

///|
fn expect_corrupt(key : String) -> Unit raise {
  let raised = try {
    let _ = FsStore::check_key(key)
    false
  } catch {
    _ => true
  }
  assert_eq(raised, true)
}

///|
async test "check_key: 非法 key 全部 raise Corrupt" {
  // 合法
  assert_eq(FsStore::check_key("a/b/c.bin"), "a/b/c.bin")
  assert_eq(FsStore::check_key("A9._-z"), "A9._-z")
  assert_eq(
    FsStore::check_key("ns/_meta/namespace.json"),
    "ns/_meta/namespace.json",
  )
  // 空与绝对路径
  expect_corrupt("")
  expect_corrupt("/abs/path")
  // 连续 '/'
  expect_corrupt("a//b")
  // 目录逃逸
  expect_corrupt("a/../b")
  expect_corrupt("..")
  // '.' 开头段（保留给 sidecar/索引）
  expect_corrupt("a/.hidden")
  expect_corrupt(".x")
  // '.tmp' 结尾段（保留给原子写）
  expect_corrupt("a/x.tmp")
  // 白名单外字符
  expect_corrupt("a/b c")
  expect_corrupt("a/b:c")
}

///|
async test "trait 泛型调用：FsStore 可作为 ObjectStore 使用" {
  let s = FsStore::new(fresh_root("trait"))
  let data = b"generic"
  s.put("g/k.bin", data)
  assert_eq(must_get(s, "g/k.bin"), data)
  cleanup_store(s)
}

///|
async test "BatchStore get_many：与逐个 get 逐位一致（含缺失 key，顺序不变）" {
  let s = FsStore::new(fresh_root("bget"))
  let a = Bytes::makei(64, i => i.to_byte())
  let b = Bytes::makei(64, i => (255 - i).to_byte())
  s.put("seg/a.bin", a)
  s.put("seg/b.bin", b)
  let keys = ["seg/a.bin", "seg/missing.bin", "seg/b.bin"]
  let batch = s.get_many(keys)
  // 返回长度与输入一致
  assert_eq(batch.length(), keys.length())
  // 与逐个 get 逐位一致
  for i in 0..<keys.length() {
    assert_eq(batch[i], s.get(keys[i]))
  }
  // None 保持在缺失下标；顺序不因缺失改变
  assert_eq(batch[0], Some(a))
  assert_eq(batch[1], None)
  assert_eq(batch[2], Some(b))
  // 空输入 → 空数组
  assert_eq(s.get_many([]).length(), 0)
  cleanup_store(s)
}

///|
async test "BatchStore get_range_many：与逐个 get_range 逐位一致（含缺失 key）" {
  let s = FsStore::new(fresh_root("brange"))
  let data = Bytes::makei(50, i => i.to_byte())
  s.put("seg/rows/id.bin", data)
  let ranges = [
    @store.KeyRange::{ key: "seg/rows/id.bin", off: 5, len: 10 },
    @store.KeyRange::{ key: "seg/missing.bin", off: 0, len: 4 },
    @store.KeyRange::{ key: "seg/rows/id.bin", off: 45, len: 100 },
  ]
  let batch = s.get_range_many(ranges)
  assert_eq(batch.length(), ranges.length())
  // 与逐个 get_range 逐位一致
  for i in 0..<ranges.length() {
    let k = ranges[i].key
    let off = ranges[i].off
    let len = ranges[i].len
    assert_eq(batch[i], s.get_range(k, @store.ByteRange::{ off: off, len: len }))
  }
  // None 保持在缺失下标；截短语义与单键一致
  assert_eq(batch[0], Some(data[5:15].to_owned()))
  assert_eq(batch[1], None)
  assert_eq(batch[2], Some(data[45:50].to_owned()))
  // 空输入 → 空数组
  assert_eq(s.get_range_many([]).length(), 0)
  cleanup_store(s)
}

///|
async fn[S : @store.ObjectStore] must_get(
  store : S,
  key : String,
) -> Bytes {
  match store.get(key) {
    Some(v) => v
    None => abort("missing key: \{key}")
  }
}

///|
/// 跨后端一致性契约（与 MemStore 同一套，store/conformance 维护）。
async test "conformance: FsStore 通过全部契约" {
  let report = @conformance.conformance_report(fn () { FsStore::new(fresh_root("conf")) })
  assert_eq(report, "")
}
