test "s3http: now_amz_date format and CurlTransport initialization" {
  let d = @s3http.now_amz_date()
  assert_eq(d.length(), 16)
  assert_eq(d.has_suffix("Z"), true)
  let transport = @s3http.CurlTransport::new()
  assert_eq(transport.version, 1)
}
