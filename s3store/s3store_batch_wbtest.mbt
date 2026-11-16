// S3Store 批量读契约测试：批量结果必须与逐项单发完全一致。

///|
async test "S3Store get_many 与逐个 get 完全一致（含缺失 key、重复 key、顺序）" {
  let m = MockS3Transport::new("bucket")
  m.seed("a.txt", b"alpha")
  m.seed("b.txt", b"beta")
  m.seed("empty.bin", b"")
  let s = S3Store::new(
    "https://s3.us-east-1.amazonaws.com",
    "bucket",
    "us-east-1",
    test_creds(),
    m,
    fixed_date(),
  )
  let keys = ["a.txt", "missing.txt", "b.txt", "a.txt", "empty.bin"]
  let batch = @store.ObjectStore::get_many(s, keys)
  assert_eq(batch.length(), keys.length())
  // 顺序 / None / 重复 key 均与单发一致
  for i in 0..<keys.length() {
    let single = s.get(keys[i])
    assert_eq(batch[i], single)
  }
  assert_eq(batch[0], Some(b"alpha"))
  assert_eq(batch[1], None)
  assert_eq(batch[2], Some(b"beta"))
  assert_eq(batch[3], Some(b"alpha"))
  assert_eq(batch[4], Some(b""))
  // Mock 是顺序 fallback：批量记录的请求顺序也应与随后逐项请求一致。
  assert_eq(m.requests.length(), keys.length() * 2)
  for i in 0..<keys.length() {
    assert_eq(m.requests[i].url, m.requests[keys.length() + i].url)
    assert_eq(m.requests[i].http_method, "GET")
  }
}

///|
async test "S3Store get_range_many 与逐个 get_range 完全一致（含 404 / 越界 / 空读）" {
  let m = MockS3Transport::new("bucket")
  m.seed("data.bin", b"0123456789")
  m.seed("short.bin", b"abc")
  let s = S3Store::new(
    "https://s3.us-east-1.amazonaws.com",
    "bucket",
    "us-east-1",
    test_creds(),
    m,
    fixed_date(),
  )
  let ranges = [
    @store.KeyRange::{ key: "data.bin", off: 2, len: 4 },
    @store.KeyRange::{ key: "missing.bin", off: 0, len: 3 },
    @store.KeyRange::{ key: "short.bin", off: 1, len: 100 },
    @store.KeyRange::{ key: "data.bin", off: 10, len: 5 },
    @store.KeyRange::{ key: "data.bin", off: 0, len: 0 },
    @store.KeyRange::{ key: "short.bin", off: 0, len: 3 },
  ]
  let batch = @store.ObjectStore::get_range_many(s, ranges)
  assert_eq(batch.length(), ranges.length())
  for i in 0..<ranges.length() {
    let r = ranges[i]
    let single = s.get_range(r.key, @store.ByteRange::{ off: r.off, len: r.len })
    assert_eq(batch[i], single)
  }
  assert_eq(batch[0], Some(b"2345"))
  assert_eq(batch[1], None)
  assert_eq(batch[2], Some(b"bc"))
  assert_eq(batch[3], Some(b""))
  assert_eq(batch[4], Some(b""))
  assert_eq(batch[5], Some(b"abc"))
}

///|
async test "S3Store 空批量返回空数组，不产生请求" {
  let m = MockS3Transport::new("bucket")
  let s = S3Store::new(
    "https://s3.us-east-1.amazonaws.com",
    "bucket",
    "us-east-1",
    test_creds(),
    m,
    fixed_date(),
  )
  let keys : Array[String] = []
  let ranges : Array[@store.KeyRange] = []
  assert_eq(@store.ObjectStore::get_many(s, keys).length(), 0)
  assert_eq(@store.ObjectStore::get_range_many(s, ranges).length(), 0)
  assert_eq(m.requests.length(), 0)
}
