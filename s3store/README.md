# s3store：SigV4 签名库 + S3 协议层（纯 MoonBit，不接真实网络）

本包是 `turbofish` 的对象存储 S3 后端协议实现，**不含任何网络代码与凭据字面量**：
region / access key / secret key 全部由构造参数传入，时间由调用方注入的时钟闭包提供。
所有正确性由官方测试向量与 RecordingMock 传输保证（`s3_wbtest.mbt`，20 个测试）。

## 模块

| 文件 | 内容 |
|---|---|
| `sha256.mbt` | FIPS 180-4 SHA-256（向量：`""`/`"abc"`/56 字节/10⁶×'a'） |
| `hmac.mbt` | RFC 2104 HMAC-SHA256（向量：RFC 4231 case 1–3） |
| `sigv4.mbt` | SigV4 签名：canonical request → string-to-sign → HMAC 派生链 → Authorization 头 |
| `s3store.mbt` | `HttpTransport` trait、`RecordingMock`（记录+预置响应+最小 S3 状态模拟）、`S3Store[T]`（ObjectStore 实现） |

### 已验证的 SigV4 官方向量

- aws-sig-v4-test-suite `get-vanilla`（AKIDEXAMPLE / `wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY`，
  scope `20150830/us-east-1/service/aws4_request`，
  Signature `5fa00fa3...bf31`）与 `get-vanilla-query-unreserved`（`9c3e54bf...0197`）
- AWS S3 文档示例 GET `/test.txt`（Range: bytes=0-9，Signature `f0e8bdb7...db41`）与
  PUT `/test%24file.text`（Signature `98ad7217...108bd`）

注意：套件密钥是 `...K7MDENG+bPx...`（加号）；S3 canonical URI 需按 RFC 3986 编码
（`$` → `%24`），查询串按 UTF-8 字节序排序（MoonBit 的 `String::compare` 是
"长度优先"序，不能直接用于 canonical 排序，包内自实现 `byte_order_compare`）。

### ObjectStore 语义映射（与 store/mem.mbt MemStore 对齐）

| ObjectStore | S3 请求 | 语义 |
|---|---|---|
| `get` | GET object | 200 → Some(body)，404 → None |
| `put` | PUT object | 2xx → 更新 etag 缓存 |
| `put_if_match(key, None, v)` | PUT + `If-None-Match: *` | 对象不存在才成功；412 → false |
| `put_if_match(key, Some(ver), v)` | PUT + `If-Match: <ver>` | `ver` 即 ETag（版本串语义 = ETag）；412 → false |
| `get_range(key, off, len)` | GET + `Range: bytes=off-(off+len-1)` | 206 采用；200 手动截取；416 → 空；404 → None |
| `list(prefix)` | ListObjectsV2（list-type=2）+ continuation token 翻页 | 升序 key |
| `delete` | DELETE object | 204，静默 |
| `head_version(key)`（pub） | 缓存 miss 时 HEAD | 返回 ETag 作为版本串 |

条件写依赖 S3 的 conditional writes（2024-08 起支持 PutObject 的 If-Match /
If-None-Match）。**MVP 限制**：ETag 缓存只在本进程内；`put_if_match` 的期望值
原样上送服务端判定，412 由上层重读仲裁（不做自动 HEAD 重试）。

## 手动端到端验证步骤（可选，不在 CI 内）

本包不接真实网络。要对真实 S3 / MinIO / LocalStack 验证，需在使用方（如 `cmd/main`
或一个独立 native main 包）提供一个 `HttpTransport` 实现——MoonBit native 没有内置
HTTP 客户端，最小做法是经 FFI 调 `curl`（或接入任一 HTTP C 库）：

```moonbit
// 示意：native 下经 FFI popen 调 curl 的 transport（使用方实现，本包不提供）
impl HttpTransport for CurlTransport with execute(self, method, url, headers, body) {
  // 1. 组装 curl 参数：-X <method> -H "k: v"... --data-binary @- <url>
  // 2. 经 FFI 写 body、读回 status/headers/body
}
```

然后（凭据只从环境变量读取，**不要写进代码或命令行参数**）：

```bash
# 1. 起一个本地 S3（MinIO 为例）
docker run -p 9000:9000 minio/minio server /data
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...   # 测试专用凭据

# 2. 构造 S3Store（endpoint 指向 MinIO，region 随意如 us-east-1）
#    now_amz_date 注入真实 UTC 时间（格式 YYYYMMDDTHHMMSSZ）
let s = S3Store::new("http://127.0.0.1:9000", "test-bucket", "us-east-1",
  { access_key: <from env>, secret_key: <from env> },
  curl_transport, real_utc_clock)

# 3. 验证顺序（每步核对返回）：
#    put → get 读回一致 → get_range 区间一致 → put_if_match(None) 建对象
#    → 二次 put_if_match(None) 应 false → put_if_match(Some(head_version)) 应 true
#    → 过期版本应 false → list 升序 → delete 后 get 为 None
```

MinIO/LocalStack 均已实现 PutObject 的 If-Match/If-None-Match 条件写与
ListObjectsV2 分页，语义与 `MockS3Transport` 一致。

## 已知限制

- ListObjectsV2 响应用 tag 文本提取（非完整 XML 解析）；mock 生成的 XML 不转义 key
  （测试 key 均为纯 ASCII）。
- 不支持 Multipart Upload、CopyObject、版本控制（S3 Versioning）等高级 API。
- 真实时钟：MoonBit core 无稳定墙钟 API，`now_amz_date` 必须由使用方注入；
  测试注入固定值保证向量可复现。

## 真实 HTTP 传输与 MinIO 验证（2026-11）

`s3http` 包提供 native 的 `CurlTransport`（libcurl FFI），实现本包的
`HttpTransport` trait；`cmd/s3probe` 用它做真实 S3/MinIO 端到端读写。

- 平台链接：
  - macOS：Homebrew curl（`-L/opt/homebrew/opt/curl/lib -lcurl -Wl,-rpath,...`）
  - Linux：`libcurl4-openssl-dev`（`-lcurl`）
  - 链接 flags 放在 **main 包**的 `moon.pkg`（`options.link.native.cc-link-flags`）；
    放在库包的 `link.native` 不会作用于最终可执行文件。
- `now_amz_date()` 由 `s3http.c` 的 `gmtime_r` 提供，SigV4 需要。
- 已验证：PUT/GET/GET-Range/LIST/DELETE/build.ingest/query/compact 在 MinIO
  上全部跑通；`If-None-Match: *`（create CAS）可用。
- **CAS 补偿与回退**：MinIO 等部分存储可能不支持 PutObject + `If-Match`。
  `S3Store` 提供 `LeaseCoordinator` 接口与 `MemLeaseCoordinator` / 自定义租约仲裁：
  若设置 `set_conditional_writes_supported(false)` 或服务端返回 501/400，
  `put_if_match` 自动降级回退至租约保护下的无条件写入与版本核对。
- **读路径 0 LIST 保证**：读/打开路径通过 `{ns}/_head_ptr` 单次 GET 解析最新 head，
  或通过 `{ns}/_manifest/{id}.json` 直接加载版本化对象，绝不调用昂贵的 LIST 请求。
- 真实网络结果与 baseline/optimized 对照见 `../S3_MINIO_RESULTS.md`。
