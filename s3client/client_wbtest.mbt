// 纯单元测试：签名 URL / 签名头 / Range / If-Match / 列表查询 / XML 解析 / 时间换算。
// 全部不依赖网络（不启动 mock server），断言确定性。

///|
const FIXED_AMZ : String = "20240102T030405Z"

///|
fn test_client() -> S3Client {
  S3Client::new(
    "https://s3.amazonaws.com",
    "bkt",
    "us-east-1",
    "AKIDEXAMPLE",
    "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
    now_amz_date=Some(fn() { FIXED_AMZ }),
  )
}

///|
fn signed_headers(l : Array[(String, String)]) -> String {
  let auth = match header_get(l, "authorization") {
    Some(a) => a
    None => return ""
  }
  match auth.find("SignedHeaders=") {
    Some(i) => {
      let rest = auth[i + 14:].to_owned()
      match rest.find(",") {
        Some(j) => rest[:j].to_owned()
        None => rest
      }
    }
    None => ""
  }
}

///|
fn signature_of(l : Array[(String, String)]) -> String {
  let auth = match header_get(l, "authorization") {
    Some(a) => a
    None => return ""
  }
  match auth.find("Signature=") {
    Some(i) => auth[i + 10:].to_owned()
    None => ""
  }
}

///|
test "object_path: 逐段编码与桶级路径" {
  let c = test_client()
  assert_eq(c.object_path("dir/a b.txt"), "/bkt/dir/a%20b.txt")
  assert_eq(c.object_path("a+b"), "/bkt/a%2Bb")
  assert_eq(c.object_path(""), "/bkt")
  assert_eq(c.object_path("x/y/z"), "/bkt/x/y/z")
}

///|
test "endpoint 解析" {
  let a = split_endpoint("http://127.0.0.1:9000/")
  assert_eq(a.0, "http")
  assert_eq(a.1, "127.0.0.1:9000")
  let b = split_endpoint("https://s3.amazonaws.com")
  assert_eq(b.0, "https")
  assert_eq(b.1, "s3.amazonaws.com")
  let c = split_endpoint("minio.local:9000")
  assert_eq(c.0, "https")
  assert_eq(c.1, "minio.local:9000")
}

///|
test "GET 签名 URL 与签名头" {
  let c = test_client()
  let req = c.build_get("dir/a b.txt", None)
  assert_eq(req.http_method, "GET")
  assert_eq(req.url, "https://s3.amazonaws.com/bkt/dir/a%20b.txt")
  // Host 由 http client 自动设置，但仍必须出现在签名头中
  assert_eq(header_get(req.headers, "host"), Some("s3.amazonaws.com"))
  assert_eq(header_get(req.headers, "x-amz-date"), Some(FIXED_AMZ))
  let empty_hash = @s3store.sha256_hex(Bytes::make(0, b'\x00'))
  assert_eq(header_get(req.headers, "x-amz-content-sha256"), Some(empty_hash))
  let auth = header_get(req.headers, "authorization").unwrap_or("")
  assert_true(auth.has_prefix("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20240102/us-east-1/s3/aws4_request,"))
  assert_eq(signed_headers(req.headers), "host;x-amz-content-sha256;x-amz-date")
  assert_eq(signature_of(req.headers).length(), 64)
  // 同一输入 → 同一签名（确定性，便于重试时 body 可重放）
  assert_eq(signature_of(c.build_get("dir/a b.txt", None).headers), signature_of(req.headers))
  // 不同 key → 不同签名
  assert_true(signature_of(c.build_get("dir/other.txt", None).headers) != signature_of(req.headers))
}

///|
test "Range 头与签名" {
  assert_eq(range_header(10, 10), "bytes=10-19")
  assert_eq(range_header(0, 1), "bytes=0-0")
  let c = test_client()
  let req = c.build_get("k", Some(range_header(10, 10)))
  assert_eq(header_get(req.headers, "range"), Some("bytes=10-19"))
  assert_eq(signed_headers(req.headers), "host;range;x-amz-content-sha256;x-amz-date")
  // Range 参与签名：带 Range 与不带 Range 的签名必须不同
  assert_true(signature_of(req.headers) != signature_of(c.build_get("k", None).headers))
}

///|
test "PUT 条件写：If-None-Match / If-Match" {
  let c = test_client()
  let body : Bytes = b"hello s3"
  let create = c.build_put("k", body, None, Some("*"))
  assert_eq(create.http_method, "PUT")
  assert_eq(header_get(create.headers, "if-none-match"), Some("*"))
  assert_eq(header_get(create.headers, "if-match"), None)
  assert_eq(
    signed_headers(create.headers),
    "host;if-none-match;x-amz-content-sha256;x-amz-date",
  )
  assert_eq(header_get(create.headers, "x-amz-content-sha256"), Some(@s3store.sha256_hex(body)))
  assert_eq(create.body, body)
  let update = c.build_put("k", body, Some("\"v1\""), None)
  assert_eq(header_get(update.headers, "if-match"), Some("\"v1\""))
  assert_eq(header_get(update.headers, "if-none-match"), None)
  assert_eq(
    signed_headers(update.headers),
    "host;if-match;x-amz-content-sha256;x-amz-date",
  )
  // 条件不同 → 签名不同
  assert_true(signature_of(create.headers) != signature_of(update.headers))
}

///|
test "DELETE / HEAD 请求构造" {
  let c = test_client()
  let d = c.build_delete("k")
  assert_eq(d.http_method, "DELETE")
  assert_eq(d.url, "https://s3.amazonaws.com/bkt/k")
  let h = c.build_head("k")
  assert_eq(h.http_method, "HEAD")
  assert_eq(h.body.length(), 0)
}

///|
test "ListObjectsV2 查询串（含分页 token）" {
  let c = test_client()
  let p1 = c.build_list("dir/", 1000, None)
  assert_eq(p1.url, "https://s3.amazonaws.com/bkt?list-type=2&max-keys=1000&prefix=dir%2F")
  let p2 = c.build_list("dir/", 1000, Some("tok en/1"))
  // canonical query 按字节序排序，token 值需 RFC3986 编码
  assert_eq(
    p2.url,
    "https://s3.amazonaws.com/bkt?continuation-token=tok%20en%2F1&list-type=2&max-keys=1000&prefix=dir%2F",
  )
  assert_true(signature_of(p1.headers) != signature_of(p2.headers))
}

///|
test "request_path 从签名 URL 中切出 path?query" {
  assert_eq(
    request_path("https://h/bkt/dir/a%20b.txt"),
    "/bkt/dir/a%20b.txt",
  )
  assert_eq(
    request_path("http://127.0.0.1:9000/bkt?list-type=2&prefix=x"),
    "/bkt?list-type=2&prefix=x",
  )
}

///|
test "ListObjectsV2 XML 解析（Key / IsTruncated / token，含实体反转义）" {
  let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" +
    "<ListBucketResult><Name>bkt</Name><Prefix>dir/</Prefix><KeyCount>2</KeyCount>" +
    "<MaxKeys>1000</MaxKeys><IsTruncated>true</IsTruncated>" +
    "<NextContinuationToken>1ueGcxLPRx1Tr</NextContinuationToken>" +
    "<Contents><Key>dir/a</Key><Size>1</Size></Contents>" +
    "<Contents><Key>dir/x&amp;y&lt;z&gt;</Key><Size>2</Size></Contents>" +
    "</ListBucketResult>"
  assert_eq(
    xml_tag_values(xml, "Key"),
    ["dir/a", "dir/x&y<z>"],
  )
  assert_eq(xml_first_value(xml, "IsTruncated"), Some("true"))
  assert_eq(xml_first_value(xml, "NextContinuationToken"), Some("1ueGcxLPRx1Tr"))
  // <KeyCount> 不能被误当作 <Key>
  assert_eq(xml_tag_values(xml, "KeyCount").length(), 1)
  assert_eq(xml_first_value(xml, "NoSuchTag"), None)
}

///|
test "amz_date：epoch 毫秒 → UTC" {
  assert_eq(amz_date_from_unix_ms(0UL), "19700101T000000Z")
  assert_eq(amz_date_from_unix_ms(1704164645000UL), "20240102T030405Z")
  assert_eq(amz_date_from_unix_ms(1704067199000UL), "20231231T235959Z")
  // 闰年 2 月 29 日
  assert_eq(amz_date_from_unix_ms(951825600000UL), "20000229T120000Z")
  // 默认时钟格式：16 位 `YYYYMMDDTHHMMSSZ`
  let now : String = default_amz_date()
  assert_eq(now.length(), 16)
  assert_eq(now[8:9], "T")
  assert_eq(now[15:16], "Z")
}

///|
test "重试状态码集合与成功判定" {
  for s in [429, 500, 502, 503, 504] {
    assert_true(is_retryable_status(s))
  }
  for s in [400, 401, 403, 404, 409, 412, 416, 501] {
    assert_false(is_retryable_status(s))
  }
  assert_true(is_ok_status(200))
  assert_true(is_ok_status(204))
  assert_true(is_ok_status(206))
  assert_false(is_ok_status(404))
  assert_false(is_ok_status(500))
}

///|
test "get_range 的本地切片逻辑（服务端忽略 Range 时）" {
  let body : Bytes = b"0123456789"
  assert_eq(slice_bytes(body, 2, 3), b"234")
  assert_eq(slice_bytes(body, 0, 10), body)
  // 越界钳制
  assert_eq(slice_bytes(body, 8, 10), b"89")
  assert_eq(slice_bytes(body, 10, 5).length(), 0)
  assert_eq(slice_bytes(body, 2, 0).length(), 0)
}
