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
  return n;
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

void *s3http_perform(const char *method, const char *url, const char *headers,
                     const uint8_t *body, int body_len) {
  if (!global_inited) {
    curl_global_init(CURL_GLOBAL_DEFAULT);
    global_inited = 1;
  }
  S3HttpResult *r = (S3HttpResult *)calloc(1, sizeof(S3HttpResult));
  if (!r) return NULL;
  Buf hb = {0}, bb = {0};
  CURL *curl = curl_easy_init();
  if (!curl) {
    r->status = 0;
    r->body = strdup("curl_easy_init failed");
    r->body_len = strlen(r->body);
    return r;
  }
  struct curl_slist *slist = NULL;
  if (headers && *headers) {
    char *copy = strdup(headers);
    if (copy) {
      char *save = NULL;
      for (char *line = strtok_r(copy, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        if (*line) slist = curl_slist_append(slist, line);
      }
      free(copy);
    }
  }
  curl_easy_setopt(curl, CURLOPT_URL, url);
  curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method);
  curl_easy_setopt(curl, CURLOPT_HTTPHEADER, slist);
  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_body_cb);
  curl_easy_setopt(curl, CURLOPT_WRITEDATA, &bb);
  curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, write_header_cb);
  curl_easy_setopt(curl, CURLOPT_HEADERDATA, &hb);
  curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
  curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 10L);
  curl_easy_setopt(curl, CURLOPT_TIMEOUT, 120L);
  curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 0L);
  if (body && body_len > 0) {
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, (const char *)body);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)body_len);
  }
  CURLcode rc = curl_easy_perform(curl);
  if (rc != CURLE_OK) {
    r->status = 0;
    const char *err = curl_easy_strerror(rc);
    r->body = strdup(err ? err : "curl error");
    r->body_len = strlen(r->body);
  } else {
    long code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &code);
    r->status = (int)code;
    r->headers = hb.data;
    r->headers_len = hb.len;
    r->body = bb.data;
    r->body_len = bb.len;
  }
  if (slist) curl_slist_free_all(slist);
  curl_easy_cleanup(curl);
  return (void *)r;
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
