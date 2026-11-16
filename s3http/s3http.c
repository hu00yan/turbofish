#include <curl/curl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct {
  char *data;
  size_t len;
  size_t cap;
} Buf;

typedef struct {
  int status;
  char *headers;
  size_t headers_len;
  char *body;
  size_t body_len;
} S3HttpResult;

static int buf_append(Buf *b, const void *data, size_t n) {
  if (n == 0) return 0;
  if (b->len + n + 1 > b->cap) {
    size_t cap = b->cap ? b->cap : 1024;
    while (cap < b->len + n + 1) cap *= 2;
    char *p = (char *)realloc(b->data, cap);
    if (!p) return 0;
    b->data = p;
    b->cap = cap;
  }
  memcpy(b->data + b->len, data, n);
  b->len += n;
  b->data[b->len] = '\0';
  return (int)n;
}

static size_t write_body_cb(void *ptr, size_t size, size_t nmemb, void *userdata) {
  Buf *b = (Buf *)userdata;
  return (size_t)buf_append(b, ptr, size * nmemb);
}

static size_t write_header_cb(void *ptr, size_t size, size_t nmemb, void *userdata) {
  Buf *b = (Buf *)userdata;
  return (size_t)buf_append(b, ptr, size * nmemb);
}

static int global_inited = 0;

void s3http_free(void *p);
void s3http_batch_free(void *p);

// ---------- 持久连接池 ----------
//
// libcurl multi 的连接缓存属于 multi handle；easy handle 复用则保留选项之外的
// session / DNS 缓存。这里把 multi 与 easy handle 都做成进程级持久对象，批量
// 调用之间可以复用 TCP/TLS 连接。MoonBit native 是单线程协作式，当前调用期间
// 不会重入，因此不需要锁。

typedef struct {
  CURL *easy;
  struct curl_slist *slist;
  Buf hb;
  Buf bb;
  int status;
  int started;
  int completed;
  CURLcode rc;
} ReqState;

typedef struct {
  int count;
  S3HttpResult **items;
} S3HttpBatch;

// 注意：g_multi / g_easies 是进程级无锁状态。当前 MoonBit native 运行时是
// 单线程协作式，store 调用不会跨 OS 线程重入；若未来引入多线程 worker，必须
// 改成每线程一份或加锁。
static CURLM *g_multi = NULL;
static CURL **g_easies = NULL;
static int g_easy_count = 0;
static long g_max_connects = 0;

static void ensure_global(void) {
  if (!global_inited) {
    curl_global_init(CURL_GLOBAL_DEFAULT);
    global_inited = 1;
  }
}

static int ensure_multi(int want) {
  ensure_global();
  if (!g_multi) {
    g_multi = curl_multi_init();
    if (!g_multi) return 0;
  }
  if (want > 0) {
    // 连接缓存只向上调整，不因为一次单发/小批量调用收缩缓存；
    // 这样跨批量调用仍能复用 TCP/TLS 连接。
    long maxconn = want < 64 ? 64 : (long)want;
    if (maxconn > g_max_connects) {
      g_max_connects = maxconn;
      curl_multi_setopt(g_multi, CURLMOPT_MAXCONNECTS, maxconn);
    }
  }
  return 1;
}

static int ensure_easies(int want) {
  if (want <= g_easy_count) return 1;
  CURL **p = (CURL **)realloc(g_easies, sizeof(CURL *) * (size_t)want);
  if (!p) return 0;
  g_easies = p;
  for (int i = g_easy_count; i < want; i++) {
    g_easies[i] = curl_easy_init();
    if (!g_easies[i]) {
      // 回滚到已成功创建的数量；清理本次已 init 的 handle，避免下次覆盖泄漏。
      for (int j = g_easy_count; j < i; j++) {
        curl_easy_cleanup(g_easies[j]);
        g_easies[j] = NULL;
      }
      return 0;
    }
  }
  g_easy_count = want;
  return 1;
}

static struct curl_slist *build_slist(const char *headers) {
  struct curl_slist *slist = NULL;
  if (!headers || !*headers) return NULL;
  char *copy = strdup(headers);
  if (!copy) return NULL;
  char *save = NULL;
  for (char *line = strtok_r(copy, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
    if (*line) slist = curl_slist_append(slist, line);
  }
  free(copy);
  return slist;
}

typedef struct {
  const char *method;
  const char *url;
  const char *headers;
  const uint8_t *body;
  int body_len;
} ReqInput;

static void finish_request(ReqState *st, CURLcode rc);

static int start_request(ReqState *st, CURL *easy, const ReqInput *in) {
  st->started = 1;
  st->completed = 0;
  st->status = 0;
  st->rc = CURLE_OK;
  st->easy = easy;
  st->slist = build_slist(in->headers);

  curl_easy_reset(easy);
  curl_easy_setopt(easy, CURLOPT_URL, in->url);
  curl_easy_setopt(easy, CURLOPT_CUSTOMREQUEST, in->method);
  curl_easy_setopt(easy, CURLOPT_HTTPHEADER, st->slist);
  curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, write_body_cb);
  curl_easy_setopt(easy, CURLOPT_WRITEDATA, &st->bb);
  curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, write_header_cb);
  curl_easy_setopt(easy, CURLOPT_HEADERDATA, &st->hb);
  curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);
  curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT, 10L);
  curl_easy_setopt(easy, CURLOPT_TIMEOUT, 120L);
  curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, 0L);
  if (in->body && in->body_len > 0) {
    curl_easy_setopt(easy, CURLOPT_POSTFIELDS, (const char *)in->body);
    curl_easy_setopt(easy, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)in->body_len);
  }
  curl_easy_setopt(easy, CURLOPT_PRIVATE, st);
  CURLMcode mc = curl_multi_add_handle(g_multi, easy);
  if (mc != CURLM_OK) {
    // 加入 multi 失败时不会有 CURLMSG_DONE，必须在这里收尾，否则调用方
    // 的 active 计数永远不会归零。
    finish_request(st, CURLE_FAILED_INIT);
    return 0;
  }
  return 1;
}

static void finish_request(ReqState *st, CURLcode rc) {
  st->completed = 1;
  st->rc = rc;
  if (rc == CURLE_OK) {
    long code = 0;
    curl_easy_getinfo(st->easy, CURLINFO_RESPONSE_CODE, &code);
    st->status = (int)code;
  } else {
    st->status = 0;
  }
  if (st->slist) {
    curl_slist_free_all(st->slist);
    st->slist = NULL;
  }
}

static void fill_error_result(S3HttpResult *r, const char *msg) {
  r->status = 0;
  r->headers = NULL;
  r->headers_len = 0;
  r->body = strdup(msg ? msg : "curl error");
  r->body_len = r->body ? strlen(r->body) : 0;
}

static S3HttpBatch *batch_new(int count) {
  S3HttpBatch *b = (S3HttpBatch *)calloc(1, sizeof(S3HttpBatch));
  if (!b) return NULL;
  b->count = count;
  if (count > 0) {
    b->items = (S3HttpResult **)calloc((size_t)count, sizeof(S3HttpResult *));
    if (!b->items) {
      free(b);
      return NULL;
    }
  }
  return b;
}

static int default_inflight(void) {
  const char *s = getenv("S3HTTP_MAX_INFLIGHT");
  if (s && *s) {
    char *end = NULL;
    long v = strtol(s, &end, 10);
    if (end != s && v > 0 && v < 4096) return (int)v;
  }
  return 32;
}

static S3HttpBatch *run_batch(const ReqInput *in, int count, int max_inflight) {
  S3HttpBatch *batch = batch_new(count);
  if (!batch) return NULL;
  if (count <= 0) return batch;

  int limit = max_inflight > 0 ? max_inflight : default_inflight();
  if (limit < 1) limit = 1;
  if (limit > count) limit = count;

  if (!ensure_multi(limit) || !ensure_easies(limit)) {
    for (int i = 0; i < count; i++) {
      S3HttpResult *r = (S3HttpResult *)calloc(1, sizeof(S3HttpResult));
      if (r) fill_error_result(r, "curl multi init failed");
      batch->items[i] = r;
    }
    return batch;
  }

  ReqState *states = (ReqState *)calloc((size_t)count, sizeof(ReqState));
  if (!states) {
    for (int i = 0; i < count; i++) {
      S3HttpResult *r = (S3HttpResult *)calloc(1, sizeof(S3HttpResult));
      if (r) fill_error_result(r, "out of memory");
      batch->items[i] = r;
    }
    return batch;
  }

  int next = 0;
  int active = 0;
  int aborted = 0;
  for (int i = 0; i < limit && i < count; i++) {
    if (!start_request(&states[i], g_easies[i], &in[i])) {
      aborted = 1;
      break;
    }
    next++;
    active++;
  }

  while (active > 0 && !aborted) {
    int still_running = 0;
    CURLMcode mc = curl_multi_perform(g_multi, &still_running);
    if (mc != CURLM_OK) {
      aborted = 1;
      break;
    }
    int msgs_left = 0;
    CURLMsg *msg;
    while ((msg = curl_multi_info_read(g_multi, &msgs_left))) {
      if (msg->msg != CURLMSG_DONE) continue;
      CURL *easy = msg->easy_handle;
      ReqState *st = NULL;
      curl_easy_getinfo(easy, CURLINFO_PRIVATE, &st);
      if (!st || st->completed) {
        // 不应发生；若发生也必须摘掉 handle 并减 active，避免死循环。
        curl_multi_remove_handle(g_multi, easy);
        active--;
        continue;
      }
      finish_request(st, msg->data.result);
      curl_multi_remove_handle(g_multi, easy);
      active--;
      if (next < count) {
        if (!start_request(&states[next], easy, &in[next])) {
          aborted = 1;
          break;
        }
        next++;
        active++;
      }
    }
    if (active > 0 && !aborted) {
      int numfds = 0;
      curl_multi_wait(g_multi, NULL, 0, 1000, &numfds);
    }
  }

  for (int i = 0; i < count; i++) {
    S3HttpResult *r = (S3HttpResult *)calloc(1, sizeof(S3HttpResult));
    if (!r) continue;
    if (!states[i].completed) {
      // 多路复用中止：未完成 / 未发出的请求用 status 0 表达，不压缩数组。
      fill_error_result(r, aborted ? "curl multi aborted" : "request not executed");
    } else if (states[i].rc != CURLE_OK) {
      const char *err = curl_easy_strerror(states[i].rc);
      fill_error_result(r, err ? err : "curl error");
      // 已完成但 curl 级失败：部分响应缓冲不会转移给 result，必须释放。
      free(states[i].hb.data);
      free(states[i].bb.data);
      states[i].hb.data = NULL;
      states[i].bb.data = NULL;
    } else {
      r->status = states[i].status;
      r->headers = states[i].hb.data;
      r->headers_len = states[i].hb.len;
      r->body = states[i].bb.data;
      r->body_len = states[i].bb.len;
    }
    batch->items[i] = r;
  }

  // 未完成请求的缓冲需要释放；完成请求的缓冲已转移给 result。
  // 中止时还要把仍挂在 multi 上的 easy handle 摘掉，避免污染下一次批量调用。
  for (int i = 0; i < count; i++) {
    if (!states[i].completed) {
      if (states[i].started && states[i].easy) {
        curl_multi_remove_handle(g_multi, states[i].easy);
      }
      free(states[i].hb.data);
      free(states[i].bb.data);
      if (states[i].slist) curl_slist_free_all(states[i].slist);
    }
  }
  free(states);
  return batch;
}

// ---------- 打包输入（供 MoonBit 一次 FFI 调用传入多个请求） ----------
//
// 布局（小端）：对每个请求依次为
//   method\0 url\0 headers\0 <uint32 body_len><body bytes>
// headers 用 "\n" 分隔的 "Key: Value"。body 可以为 0 字节。

static int read_le32(const uint8_t *p, int *out) {
  *out = (int)p[0] | ((int)p[1] << 8) | ((int)p[2] << 16) | ((int)p[3] << 24);
  return 0;
}

static const char *next_cstr(const uint8_t **pp, const uint8_t *end) {
  const uint8_t *p = *pp;
  const uint8_t *q = p;
  while (q < end && *q != 0) q++;
  if (q >= end) return NULL;
  *pp = q + 1;
  return (const char *)p;
}

void *s3http_perform_many(const uint8_t *reqs, int reqs_len, int count,
                          int max_inflight) {
  if (count < 0) return NULL;
  S3HttpBatch *batch = batch_new(count);
  if (!batch) return NULL;
  if (count == 0) return batch;

  ReqInput *in = (ReqInput *)calloc((size_t)count, sizeof(ReqInput));
  if (!in) {
    for (int i = 0; i < count; i++) {
      S3HttpResult *r = (S3HttpResult *)calloc(1, sizeof(S3HttpResult));
      if (r) fill_error_result(r, "out of memory");
      batch->items[i] = r;
    }
    return batch;
  }

  const uint8_t *p = reqs;
  const uint8_t *end = reqs + (reqs_len > 0 ? reqs_len : 0);
  int bad = 0;
  for (int i = 0; i < count; i++) {
    const char *method = next_cstr(&p, end);
    const char *url = method ? next_cstr(&p, end) : NULL;
    const char *headers = url ? next_cstr(&p, end) : NULL;
    if (!headers || p + 4 > end) {
      bad = 1;
      break;
    }
    int body_len = 0;
    read_le32(p, &body_len);
    p += 4;
    if (body_len < 0 || p + body_len > end) {
      bad = 1;
      break;
    }
    in[i].method = method;
    in[i].url = url;
    in[i].headers = headers;
    in[i].body = p;
    in[i].body_len = body_len;
    p += body_len;
  }

  if (bad) {
    free(in);
    for (int i = 0; i < count; i++) {
      S3HttpResult *r = (S3HttpResult *)calloc(1, sizeof(S3HttpResult));
      if (r) fill_error_result(r, "invalid packed request");
      batch->items[i] = r;
    }
    return batch;
  }

  S3HttpBatch *out = run_batch(in, count, max_inflight);
  free(in);
  if (out != batch) {
    s3http_batch_free(batch);
  }
  return out;
}

int s3http_batch_len(void *p) {
  S3HttpBatch *b = (S3HttpBatch *)p;
  return b ? b->count : 0;
}

void *s3http_batch_get(void *p, int i) {
  S3HttpBatch *b = (S3HttpBatch *)p;
  if (!b || i < 0 || i >= b->count) return NULL;
  return b->items[i];
}

void s3http_batch_free(void *p) {
  S3HttpBatch *b = (S3HttpBatch *)p;
  if (!b) return;
  if (b->items) {
    for (int i = 0; i < b->count; i++) {
      s3http_free(b->items[i]);
    }
    free(b->items);
  }
  free(b);
}

// ---------- 单请求（复用同一 multi 实现） ----------

void *s3http_perform(const char *method, const char *url, const char *headers,
                     const uint8_t *body, int body_len) {
  ReqInput in;
  in.method = method;
  in.url = url;
  in.headers = headers;
  in.body = body;
  in.body_len = body_len;
  S3HttpBatch *batch = run_batch(&in, 1, 1);
  if (!batch) return NULL;
  S3HttpResult *r = batch->count > 0 ? batch->items[0] : NULL;
  if (batch->count > 0) {
    batch->items[0] = NULL;
  }
  s3http_batch_free(batch);
  return r;
}

int s3http_status(void *p) {
  S3HttpResult *r = (S3HttpResult *)p;
  return r ? r->status : 0;
}

int s3http_headers_len(void *p) {
  S3HttpResult *r = (S3HttpResult *)p;
  return r ? (int)r->headers_len : 0;
}

int s3http_body_len(void *p) {
  S3HttpResult *r = (S3HttpResult *)p;
  return r ? (int)r->body_len : 0;
}

int s3http_read_headers(void *p, uint8_t *buf, int len) {
  S3HttpResult *r = (S3HttpResult *)p;
  if (!r || !buf || len <= 0) return 0;
  int n = (int)r->headers_len;
  if (n > len) n = len;
  memcpy(buf, r->headers, (size_t)n);
  return n;
}

int s3http_read_body(void *p, uint8_t *buf, int len) {
  S3HttpResult *r = (S3HttpResult *)p;
  if (!r || !buf || len <= 0) return 0;
  int n = (int)r->body_len;
  if (n > len) n = len;
  memcpy(buf, r->body, (size_t)n);
  return n;
}

void s3http_free(void *p) {
  S3HttpResult *r = (S3HttpResult *)p;
  if (!r) return;
  free(r->headers);
  free(r->body);
  free(r);
}

int s3http_now_amz_date(uint8_t *buf, int len) {
  if (!buf || len < 17) return 0;
  time_t t = time(NULL);
  struct tm tm;
  if (!gmtime_r(&t, &tm)) return 0;
  size_t n = strftime((char *)buf, (size_t)len, "%Y%m%dT%H%M%SZ", &tm);
  return (int)n;
}
