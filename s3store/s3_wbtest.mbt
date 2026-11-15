///|

// s3store 测试：sha/hmac 向量、SigV4 官方向量、请求构造器断言、mock CAS 流程。

///|
/// 测试辅助：hex 字符串 → Bytes
fn hex_decode(s : String) -> Bytes {
  let chars = s.to_array()
  let n = chars.length() / 2
  let arr : FixedArray[Byte] = FixedArray::make(n, b'\x00')
  for i in 0..<n {
    let hi = hex_val(chars[i * 2])
    let lo = hex_val(chars[i * 2 + 1])
    arr[i] = ((hi * 16 + lo) & 0xFF).to_byte()
  }
  Bytes::from_array(arr)
}

///|
fn hex_val(c : Char) -> Int {
  let v = c.to_int()
  if v >= 48 && v <= 57 {
    v - 48
  } else if v >= 97 && v <= 102 {
    v - 87
  } else if v >= 65 && v <= 70 {
    v - 55
  } else {
    abort("bad hex digit")
  }
}

///|
test "sha256: FIPS 向量" {
  // SHA256("")
  assert_eq(
    sha256_hex(b""),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  )
  // SHA256("abc")
  assert_eq(
    sha256_hex(b"abc"),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
  // 56 字节（跨 padding 边界）
  assert_eq(
    sha256_hex(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
  )
  // 1,000,000 × 'a'
  let million_a = b"a".repeat(1000000)
  assert_eq(
    sha256_hex(million_a),
    "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
  )
}

///|
test "hmac-sha256: RFC 4231 向量 case 1-3" {
  // Case 1: key = 0x0b × 20, data = "Hi There"
  let key1 = hex_decode("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
  assert_eq(
    hmac_sha256_hex(key1, b"Hi There"),
    "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
  )
  // Case 2: key = "Jefe", data = "what do ya want for nothing?"
  assert_eq(
    hmac_sha256_hex(b"Jefe", b"what do ya want for nothing?"),
    "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
  )
  // Case 3: key = 0xaa × 20, data = 0xdd × 50
  let key3 = hex_decode("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
  let data3 = hex_decode(
    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
  )
  assert_eq(
    hmac_sha256_hex(key3, data3),
    "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe",
  )
}

///|
test "bytes_to_hex / hex_decode roundtrip" {
  let raw = hex_decode("00ff10af")
  assert_eq(bytes_to_hex(raw), "00ff10af")
}

///|
test "sigv4: canonical request（get-vanilla 结构断言）" {
  // aws-sig-v4-test-suite get-vanilla 的 canonical request（官方 .creq 文件原文）
  let headers = [
    ("host", "example.amazonaws.com"),
    ("x-amz-date", "20150830T123600Z"),
  ]
  let canonical = sigv4_canonical_request(
    "GET", "/", "", headers, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  )
  assert_eq(
    canonical, "GET\n/\n\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  )
  // 官方 .sts 文件给出的 canonical request 哈希
  assert_eq(
    sha256_hex(@utf8.encode(canonical)),
    "bb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63",
  )
}

///|
test "sigv4: aws-sig-v4-test-suite get-vanilla（iam, AKIDEXAMPLE）" {
  let creds = S3Credentials::{
    access_key: "AKIDEXAMPLE",
    secret_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
  }
  let req = sigv4_sign_request(
    "GET",
    "https",
    "example.amazonaws.com",
    "/",
    [],
    [],
    Bytes::make(0, b'\x00'),
    creds,
    "us-east-1",
    "service",
    "20150830T123600Z",
  )
  // 官方 get-vanilla.authz 原文
  let mut auth = ""
  for h in req.headers {
    if h.0 == "Authorization" {
      auth = h.1
    }
  }
  assert_eq(
    auth, "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31",
  )
}

///|
test "sigv4: AWS S3 文档示例 GET（Range）" {
  let creds = S3Credentials::{
    access_key: "AKIAIOSFODNN7EXAMPLE",
    secret_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
  }
  let req = sigv4_sign_request(
    "GET",
    "https",
    "examplebucket.s3.amazonaws.com",
    "/test.txt",
    [],
    [
      ("Range", "bytes=0-9"),
      (
        "x-amz-content-sha256", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      ),
    ],
    Bytes::make(0, b'\x00'),
    creds,
    "us-east-1",
    "s3",
    "20130524T000000Z",
  )
  let mut auth = ""
  for h in req.headers {
    if h.0 == "Authorization" {
      auth = h.1
    }
  }
  assert_eq(
    auth, "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41",
  )
  // URL 组装
  assert_eq(req.url, "https://examplebucket.s3.amazonaws.com/test.txt")
}

///|
test "sigv4: AWS S3 文档示例 PUT（payload hash + storage class）" {
  let creds = S3Credentials::{
    access_key: "AKIAIOSFODNN7EXAMPLE",
    secret_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
  }
  let body = b"Welcome to Amazon S3."
  // 文档给出的 payload hash
  assert_eq(
    sha256_hex(body),
    "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072",
  )
  // 文档示例的 key 是 test$file.text：canonical URI 中 $ 按 RFC3986 编码为 %24
  let req = sigv4_sign_request(
    "PUT",
    "https",
    "examplebucket.s3.amazonaws.com",
    "/test%24file.text",
    [],
    [
      ("Date", "Fri, 24 May 2013 00:00:00 GMT"),
      ("x-amz-storage-class", "REDUCED_REDUNDANCY"),
      ("x-amz-content-sha256", sha256_hex(body)),
    ],
    body,
    creds,
    "us-east-1",
    "s3",
    "20130524T000000Z",
  )
  let mut auth = ""
  for h in req.headers {
    if h.0 == "Authorization" {
      auth = h.1
    }
  }
  assert_eq(
    auth, "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class, Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd",
  )
}

///|
test "uri_encode / canonical_query" {
  assert_eq(uri_encode("a b/c+d", false), "a%20b/c%2Bd")
  assert_eq(uri_encode("a b/c+d", true), "a%20b%2Fc%2Bd")
  assert_eq(uri_encode("unreserved-._~", true), "unreserved-._~")
  assert_eq(
    canonical_query([("max-keys", "100"), ("list-type", "2"), ("prefix", "ns/")]),
    "list-type=2&max-keys=100&prefix=ns%2F",
  )
}

///|
test "sigv4: aws-sig-v4-test-suite get-vanilla-query-unreserved" {
  let creds = S3Credentials::{
    access_key: "AKIDEXAMPLE",
    secret_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
  }
  let unreserved = "-._~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
  let req = sigv4_sign_request(
    "GET",
    "https",
    "example.amazonaws.com",
    "/",
    [(unreserved, unreserved)],
    [],
    Bytes::make(0, b'\x00'),
    creds,
    "us-east-1",
    "service",
    "20150830T123600Z",
  )
  // 官方 .authz 原文（query 全部 unreserved 时原样保留）
  let mut auth = ""
  for h in req.headers {
    if h.0 == "Authorization" {
      auth = h.1
    }
  }
  assert_eq(
    auth, "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=9c3e54bfcdf0b19771a7f523ee5669cdf59bc7cc0884027167c21bb143a40197",
  )
  assert_eq(
    req.url,
    "https://example.amazonaws.com/?\{unreserved}=\{unreserved}",
  )
}

// ---------- 构造器与 mock 传输 ----------

///|
fn test_creds() -> S3Credentials {
  S3Credentials::{
    access_key: "AKIDTEST",
    secret_key: "test-secret-do-not-use",
  }
}

///|
fn fixed_date() -> () -> String {
  () => "20250101T000000Z"
}

///|
test "GetObject 构造器：URL / host / 授权头结构 / 空 payload hash" {
  let m = MockS3Transport::new("bucket")
  let s = S3Store::new(
    "https://s3.us-east-1.amazonaws.com",
    "bucket",
    "us-east-1",
    test_creds(),
    m,
    fixed_date(),
  )
  ignore(s.get("ns/dir/a.txt"))
  assert_eq(m.requests.length(), 1)
  let r = m.requests[0]
  assert_eq(r.http_method, "GET")
  assert_eq(r.url, "https://s3.us-east-1.amazonaws.com/bucket/ns/dir/a.txt")
  // 固定三个协议头
  assert_eq(header_get(r.headers, "host"), Some("s3.us-east-1.amazonaws.com"))
  assert_eq(header_get(r.headers, "x-amz-date"), Some("20250101T000000Z"))
  assert_eq(
    header_get(r.headers, "x-amz-content-sha256"),
    Some("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
  )
  // 授权头结构
  let auth = header_get(r.headers, "authorization").unwrap_or("")
  assert_eq(
    auth,
    "AWS4-HMAC-SHA256 Credential=AKIDTEST/20250101/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=\{auth_signature(auth)}",
  )
  assert_eq(auth_signature(auth).length(), 64)
}

///|
/// 从 Authorization 头里抠出 Signature（结构断言辅助）
fn auth_signature(auth : String) -> String {
  match auth.find("Signature=") {
    Some(i) => auth[i + 10:].to_owned()
    None => ""
  }
}

///|
test "GetObject-Range / PutObject 条件头 / DeleteObject 构造器" {
  let m = MockS3Transport::new("bucket")
  let s = S3Store::new(
    "https://s3.us-east-1.amazonaws.com",
    "bucket",
    "us-east-1",
    test_creds(),
    m,
    fixed_date(),
  )
  // Range 读
  let gr = s.build_get_object("p.bin", Some("bytes=16-47"))
  assert_eq(header_get(gr.headers, "range"), Some("bytes=16-47"))
  // If-Match / If-None-Match
  let pm = s.build_put_object("p.bin", b"data", Some("etag-7"), None)
  assert_eq(header_get(pm.headers, "if-match"), Some("etag-7"))
  assert_eq(header_get(pm.headers, "if-none-match"), None)
  let pn = s.build_put_object("p.bin", b"data", None, Some("*"))
  assert_eq(header_get(pn.headers, "if-none-match"), Some("*"))
  assert_eq(pn.http_method, "PUT")
  assert_eq(pn.body, b"data")
  // DELETE
  let del = s.build_delete_object("p.bin")
  assert_eq(del.http_method, "DELETE")
  assert_eq(del.url, "https://s3.us-east-1.amazonaws.com/bucket/p.bin")
  // 业务头进入 SignedHeaders
  let auth = header_get(gr.headers, "authorization").unwrap_or("")
  assert_eq(header_get(gr.headers, "x-amz-date"), Some("20250101T000000Z"))
  assert_eq(
    auth.has_prefix(
      "AWS4-HMAC-SHA256 Credential=AKIDTEST/20250101/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=",
    ),
    true,
  )
}

///|
test "ListObjectsV2 构造器：query 编码与字节序排序" {
  let m = MockS3Transport::new("bucket")
  let s = S3Store::new(
    "https://s3.us-east-1.amazonaws.com",
    "bucket",
    "us-east-1",
    test_creds(),
    m,
    fixed_date(),
  )
  let req = s.build_list_objects_v2("ns/", 100, Some("tok/1"))
  assert_eq(
    req.url,
    "https://s3.us-east-1.amazonaws.com/bucket?continuation-token=tok%2F1&list-type=2&max-keys=100&prefix=ns%2F",
  )
}

///|
test "S3Store::new：缺 scheme 的 endpoint raise Corrupt" {
  let raised = try {
    let _ = S3Store::new(
      "s3.us-east-1.amazonaws.com",
      "bucket",
      "us-east-1",
      test_creds(),
      MockS3Transport::new("bucket"),
      fixed_date(),
    )
    false
  } catch {
    _ => true
  }
  assert_eq(raised, true)
}

///|
test "mock 状态模拟：get / 404 / range 206 / head / delete" {
  let m = MockS3Transport::new("bucket")
  m.seed("d/a.bin", Bytes::makei(100, i => (i % 251).to_byte()))
  let (st1, hs1, body1) = m.execute(
    "GET",
    "https://x/bucket/d/a.bin",
    [],
    Bytes::make(0, b'\x00'),
  )
  assert_eq(st1, 200)
  assert_eq(header_get(hs1, "etag"), Some("etag-1"))
  assert_eq(body1.length(), 100)
  // 404
  let (st2, _, _) = m.execute(
    "GET",
    "https://x/bucket/d/missing.bin",
    [],
    Bytes::make(0, b'\x00'),
  )
  assert_eq(st2, 404)
  // Range：bytes=50-59 → 206 + 10 字节
  let (st3, _, body3) = m.execute(
    "GET",
    "https://x/bucket/d/a.bin",
    [("range", "bytes=50-59")],
    Bytes::make(0, b'\x00'),
  )
  assert_eq(st3, 206)
  assert_eq(body3.length(), 10)
  // HEAD
  let (st4, hs4, body4) = m.execute(
    "HEAD",
    "https://x/bucket/d/a.bin",
    [],
    Bytes::make(0, b'\x00'),
  )
  assert_eq(st4, 200)
  assert_eq(header_get(hs4, "etag"), Some("etag-1"))
  assert_eq(body4.length(), 0)
  // DELETE
  let (st5, _, _) = m.execute(
    "DELETE",
    "https://x/bucket/d/a.bin",
    [],
    Bytes::make(0, b'\x00'),
  )
  assert_eq(st5, 204)
  let (st6, _, _) = m.execute(
    "GET",
    "https://x/bucket/d/a.bin",
    [],
    Bytes::make(0, b'\x00'),
  )
  assert_eq(st6, 404)
}

///|
test "mock 预置响应队列：execute 弹出预置值" {
  let m = MockS3Transport::new("bucket")
  m.seed("k", b"seeded") // 预置一个对象，供队列耗尽后验证状态模拟
  m.enqueue(503, [("Retry-After", "1")], b"slow down")
  m.enqueue(412, [], Bytes::make(0, b'\x00'))
  let (st1, hs1, body1) = m.execute("PUT", "https://x/bucket/k", [], b"x")
  assert_eq(st1, 503)
  assert_eq(header_get(hs1, "retry-after"), Some("1"))
  assert_eq(body1, b"slow down")
  let (st2, _, _) = m.execute("PUT", "https://x/bucket/k", [], b"x")
  assert_eq(st2, 412)
  // 队列耗尽后回到状态模拟（预置响应不落状态：对象仍是 seed 的内容）
  let (st3, _, body3) = m.execute(
    "GET",
    "https://x/bucket/k",
    [],
    Bytes::make(0, b'\x00'),
  )
  assert_eq(st3, 200)
  assert_eq(body3, b"seeded")
}

///|
test "S3Store CAS 流程（mock 状态模拟）：语义与 MemStore 对齐" {
  let m = MockS3Transport::new("bucket")
  let s = S3Store::new(
    "http://127.0.0.1:9000",
    "bucket",
    "us-east-1",
    test_creds(),
    m,
    fixed_date(),
  )
  // 新 key：expected=None 成功，版本 = etag-1
  assert_eq(s.put_if_match("m/manifest.json", None, b"v1-body"), true)
  assert_eq(s.head_version("m/manifest.json"), Some("etag-1"))
  // 再来一次 None：对象已存在 → 412 → false
  assert_eq(s.put_if_match("m/manifest.json", None, b"bad"), false)
  // 正确版本 → 成功，版本推进
  assert_eq(s.put_if_match("m/manifest.json", Some("etag-1"), b"v2-body"), true)
  assert_eq(s.get("m/manifest.json"), Some(b"v2-body"))
  assert_eq(s.head_version("m/manifest.json"), Some("etag-2"))
  // 过期版本 → 412 → false，内容不变
  assert_eq(s.put_if_match("m/manifest.json", Some("etag-1"), b"stale"), false)
  assert_eq(s.get("m/manifest.json"), Some(b"v2-body"))
  // 当前版本 → 成功
  assert_eq(s.put_if_match("m/manifest.json", Some("etag-2"), b"v3-body"), true)
  assert_eq(s.head_version("m/manifest.json"), Some("etag-3"))
  // 不存在的 key：Some 期望 → false；head_version → None
  assert_eq(s.put_if_match("m/nope.json", Some("etag-1"), b"x"), false)
  assert_eq(s.head_version("m/nope.json"), None)
  // get 未命中
  assert_eq(s.get("m/nope.json"), None)
}

///|
test "S3Store etag 缓存：预置 412 映射为 put_if_match false" {
  let m = MockS3Transport::new("bucket")
  let s = S3Store::new(
    "http://127.0.0.1:9000",
    "bucket",
    "us-east-1",
    test_creds(),
    m,
    fixed_date(),
  )
  assert_eq(s.put_if_match("k", None, b"v1"), true)
  let v1 = s.head_version("k").unwrap_or("")
  // 人为污染缓存：模拟读到过期 etag
  s.etag_cache.set("k", "etag-stale")
  // 缓存的 etag 与服务端不一致 → mock 412 → false（期望走 HEAD 刷新吗？不：
  // 契约是缓存命中即发 If-Match，失败返回 false 由上层重读仲裁）
  assert_eq(s.put_if_match("k", Some("etag-stale"), b"v2"), false)
  // 正确 etag 恢复
  assert_eq(s.put_if_match("k", Some(v1), b"v2"), true)
}

///|
test "S3Store get_range：206 截取 + 416 → 空 + 404 → None" {
  let m = MockS3Transport::new("bucket")
  let s = S3Store::new(
    "http://127.0.0.1:9000",
    "bucket",
    "us-east-1",
    test_creds(),
    m,
    fixed_date(),
  )
  let data = Bytes::makei(100, i => (i % 251).to_byte())
  s.put("seg/rows/id.bin", data)
  assert_eq(
    s.get_range("seg/rows/id.bin", 10, 20),
    Some(data[10:30].to_owned()),
  )
  // 越界截短：[90, 200) → mock 端 clamp 到 [90, 100)
  assert_eq(
    s.get_range("seg/rows/id.bin", 90, 110),
    Some(data[90:100].to_owned()),
  )
  // offset 超界 → 416 → 空
  assert_eq(
    s.get_range("seg/rows/id.bin", 100, 5),
    Some(Bytes::make(0, b'\x00')),
  )
  // len=0 → HEAD 探测
  assert_eq(
    s.get_range("seg/rows/id.bin", 10, 0),
    Some(Bytes::make(0, b'\x00')),
  )
  assert_eq(
    s.get_range("seg/rows/id.bin", 10, 0),
    Some(Bytes::make(0, b'\x00')),
  )
  // 不存在的 key
  assert_eq(s.get_range("seg/nope.bin", 0, 5), None)
  // 全量读
  assert_eq(s.get_range("seg/rows/id.bin", 0, 100), Some(data))
}

///|
test "S3Store list：mock 分页 continuation token 翻页" {
  let m = MockS3Transport::new("bucket")
  let s = S3Store::new(
    "http://127.0.0.1:9000",
    "bucket",
    "us-east-1",
    test_creds(),
    m,
    fixed_date(),
  )
  let keys = ["ns/5", "ns/1", "ns/3", "other/9", "ns/2", "ns/4"]
  for k in keys {
    m.seed(k, b"x")
  }
  // page_size=2 强制翻页（ns/1..ns/5 + 无 other）
  assert_eq(s.list_page("ns/", 2), ["ns/1", "ns/2", "ns/3", "ns/4", "ns/5"])
  // 单页
  assert_eq(s.list_page("ns/", 1000), ["ns/1", "ns/2", "ns/3", "ns/4", "ns/5"])
  // ObjectStore::list 全量
  assert_eq(s.list("ns/"), ["ns/1", "ns/2", "ns/3", "ns/4", "ns/5"])
  assert_eq(s.list(""), ["ns/1", "ns/2", "ns/3", "ns/4", "ns/5", "other/9"])
  assert_eq(s.list("zzz"), [])
  // delete 后 list 收缩
  s.delete("ns/3")
  assert_eq(s.list("ns/"), ["ns/1", "ns/2", "ns/4", "ns/5"])
}

///|
test "S3Store put/put_if_match 泛型 ObjectStore 调用 + plain put" {
  let m = MockS3Transport::new("bucket")
  let s = S3Store::new(
    "http://127.0.0.1:9000",
    "bucket",
    "us-east-1",
    test_creds(),
    m,
    fixed_date(),
  )
  s.put("p/k.bin", b"plain")
  assert_eq(must_get_s3(s, "p/k.bin"), b"plain")
  // plain put 也推进版本
  let v1 = s.head_version("p/k.bin").unwrap_or("")
  s.put("p/k.bin", b"plain2")
  let v2 = s.head_version("p/k.bin").unwrap_or("")
  assert_eq(v1 != v2, true)
  assert_eq(s.get("p/k.bin"), Some(b"plain2"))
}

///|
fn[T : @store.ObjectStore] must_get_s3(store : T, key : String) -> Bytes {
  match store.get(key) {
    Some(v) => v
    None => abort("missing key: \{key}")
  }
}

///|
test "S3Store: zero LIST requests on read/open paths via _head_ptr and versioned manifest" {
  let m = MockS3Transport::new("bucket")
  let s = S3Store::new(
    "http://127.0.0.1:9000",
    "bucket",
    "us-east-1",
    test_creds(),
    m,
    fixed_date(),
  )
  m.seed("ns/_head_ptr", @utf8.encode("manifest-20261112-001"))
  m.seed(
    "ns/_manifest/manifest-20261112-001.json",
    @utf8.encode("{\"id\":\"manifest-20261112-001\"}"),
  )
  m.requests.clear()

  // 1. resolve_head / read_head_pointer: 1 次 GET，0 LIST
  let ptr = s.read_head_pointer("ns")
  assert_eq(ptr, Some("manifest-20261112-001"))
  let head = s.resolve_head("ns", fallback="legacy")
  assert_eq(head, "manifest-20261112-001")
  assert_eq(m.requests.length(), 2)
  for r in m.requests {
    assert_eq(r.http_method, "GET")
    assert_eq(r.url.contains("list-type"), false)
    assert_eq(r.url.has_suffix("/bucket/ns/_head_ptr"), true)
  }

  // 2. 直接版本化 manifest 读：1 次 GET，0 LIST
  m.requests.clear()
  let man_bytes = s.get_versioned_manifest("ns", "manifest-20261112-001")
  assert_eq(man_bytes, Some(@utf8.encode("{\"id\":\"manifest-20261112-001\"}")))
  assert_eq(m.requests.length(), 1)
  assert_eq(m.requests[0].http_method, "GET")
  assert_eq(m.requests[0].url.contains("list-type"), false)
  assert_eq(
    m.requests[0].url.has_suffix(
      "/bucket/ns/_manifest/manifest-20261112-001.json",
    ),
    true,
  )
}

///|
test "S3Store: CAS via LeaseCoordinator fallback when conditional writes are disabled" {
  let m = MockS3Transport::new("bucket")
  let coord = MemLeaseCoordinator::new()
  let s = S3Store::new(
    "http://127.0.0.1:9000",
    "bucket",
    "us-east-1",
    test_creds(),
    m,
    fixed_date(),
  ).with_lease_coordinator(coord, owner_id="worker-A")
  s.set_conditional_writes_supported(false)
  assert_eq(s.conditional_writes_supported(), false)

  // expected=None 创建成功
  assert_eq(s.put_if_match("cas-fallback.json", None, b"v1-data"), true)
  assert_eq(s.get("cas-fallback.json"), Some(b"v1-data"))

  // expected=None 重复创建失败（对象已存在）
  assert_eq(s.put_if_match("cas-fallback.json", None, b"v1-dup"), false)
  assert_eq(s.get("cas-fallback.json"), Some(b"v1-data"))

  // 获取当前版本串（ETag）
  let ver1 = match s.head_version("cas-fallback.json") {
    Some(v) => v
    None => abort("missing version")
  }

  // expected=Some(ver1) 更新成功
  assert_eq(
    s.put_if_match("cas-fallback.json", Some(ver1), b"v2-data"),
    true,
  )
  assert_eq(s.get("cas-fallback.json"), Some(b"v2-data"))

  // 过期版本更新被拒绝
  assert_eq(
    s.put_if_match("cas-fallback.json", Some(ver1), b"v3-stale"),
    false,
  )
  assert_eq(s.get("cas-fallback.json"), Some(b"v2-data"))
}

///|
test "S3Store: LeaseCoordinator mutual exclusion on lease contention" {
  let m = MockS3Transport::new("bucket")
  let coord = MemLeaseCoordinator::new(now_ms=fn() { 1000L })
  let s = S3Store::new(
    "http://127.0.0.1:9000",
    "bucket",
    "us-east-1",
    test_creds(),
    m,
    fixed_date(),
  ).with_lease_coordinator(coord, owner_id="worker-A")
  s.set_conditional_writes_supported(false)

  // worker-B 抢先持有租约
  assert_eq(coord.acquire("contested.json", "worker-B", 5000L), true)

  // worker-A 尝试写入失败（租约冲突）
  assert_eq(s.put_if_match("contested.json", None, b"locked-out"), false)
  assert_eq(s.get("contested.json"), None)

  // worker-B 释放租约后，worker-A 成功写入
  assert_eq(coord.release("contested.json", "worker-B"), true)
  assert_eq(s.put_if_match("contested.json", None, b"now-succeeds"), true)
  assert_eq(s.get("contested.json"), Some(b"now-succeeds"))
}

///|
test "S3Store: dynamic degradation to LeaseCoordinator on 501 Not Implemented" {
  let m = MockS3Transport::new("bucket")
  m.set_conditional_writes_supported(false)
  let coord = MemLeaseCoordinator::new()
  let s = S3Store::new(
    "http://127.0.0.1:9000",
    "bucket",
    "us-east-1",
    test_creds(),
    m,
    fixed_date(),
  ).with_lease_coordinator(coord, owner_id="worker-auto")

  assert_eq(s.conditional_writes_supported(), true)

  // 触发 501，自动降级至 Lease 协调器并重试成功
  assert_eq(s.put_if_match("auto-deg.txt", None, b"auto-fallback-body"), true)
  assert_eq(s.conditional_writes_supported(), false)
  assert_eq(s.get("auto-deg.txt"), Some(b"auto-fallback-body"))
}
