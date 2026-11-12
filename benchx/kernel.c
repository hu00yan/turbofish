// benchx/kernel.c — benchx 的 C 内核（moon.pkg "native-stub" 声明，仅 native 后端编入）。
// 1) FFI 探针：benchx_add2 —— 验证 moon 是否会把包内 .c 文件编译并链接进可执行文件；
// 2) C 侧 malloc 缓冲：MoonBit 侧以 #external 不透明指针（void*）持有，
//    不依赖 Array/Bytes 的运行时内存布局；
// 3) f32 dot 内核 ×3：标量 double 累加 / 8 路独立累加器 / float 累加对照。
#include <stdint.h>
#include <stdlib.h>

// ---- FFI 探针：Int 参数映射 ----
int32_t benchx_add2(int32_t x, int32_t y) { return x + y; }

// ---- FFI 探针：Float/Double 参数映射（排查 ABI）----
float benchx_echo_f32(float x) { return x + 1.0f; }

double benchx_echo_f64(double x) { return x + 1.0; }

// 多参数顺序探针：检查 Float 参数是否会挤乱后续 Int 参数的位置
int32_t benchx_probe_mix(int32_t a, float f, int32_t b) {
  return a + b + (int32_t)(f + 0.5f);
}

// ---- 不透明缓冲（float 数组 + 长度）----
typedef struct {
  int32_t len;
  float *data;
} benchx_buf_t;

void *benchx_buf_new(int32_t len) {
  benchx_buf_t *b = (benchx_buf_t *)malloc(sizeof(benchx_buf_t));
  if (b == NULL) {
    return NULL;
  }
  b->len = len;
  b->data = (float *)malloc((size_t)len * sizeof(float));
  if (b->data == NULL) {
    free(b);
    return NULL;
  }
  return b;
}

void benchx_buf_free(void *p) {
  benchx_buf_t *b = (benchx_buf_t *)p;
  if (b == NULL) {
    return;
  }
  free(b->data);
  free(b);
}

int32_t benchx_buf_len(void *p) { return ((benchx_buf_t *)p)->len; }

void benchx_buf_set(void *p, int32_t i, float v) {
  ((benchx_buf_t *)p)->data[i] = v;
}

float benchx_buf_get(void *p, int32_t i) { return ((benchx_buf_t *)p)->data[i]; }

// ---- dot 内核（ap/bp 为 benchx_buf_t*，取行 ai/bi 起 dim 个元素）----

// 标量：double 累加（与 MoonBit @core.dot_f32 同语义：链式依赖的单累加器）
double benchx_dot_f32(const void *ap, int32_t ai, const void *bp, int32_t bi,
                      int32_t dim) {
  const float *x = ((const benchx_buf_t *)ap)->data + ai;
  const float *y = ((const benchx_buf_t *)bp)->data + bi;
  double s = 0.0;
  for (int32_t i = 0; i < dim; i++) {
    s += (double)x[i] * (double)y[i];
  }
  return s;
}

// 8 路独立累加器（消除链式依赖；-O3 无 fast-math 时不向量化 FP 归约，
// 但展开可提升 ILP）
double benchx_dot_f32_8acc(const void *ap, int32_t ai, const void *bp,
                           int32_t bi, int32_t dim) {
  const float *x = ((const benchx_buf_t *)ap)->data + ai;
  const float *y = ((const benchx_buf_t *)bp)->data + bi;
  double s0 = 0, s1 = 0, s2 = 0, s3 = 0, s4 = 0, s5 = 0, s6 = 0, s7 = 0;
  int32_t i = 0;
  int32_t n = dim / 8 * 8;
  for (; i < n; i += 8) {
    s0 += (double)x[i] * (double)y[i];
    s1 += (double)x[i + 1] * (double)y[i + 1];
    s2 += (double)x[i + 2] * (double)y[i + 2];
    s3 += (double)x[i + 3] * (double)y[i + 3];
    s4 += (double)x[i + 4] * (double)y[i + 4];
    s5 += (double)x[i + 5] * (double)y[i + 5];
    s6 += (double)x[i + 6] * (double)y[i + 6];
    s7 += (double)x[i + 7] * (double)y[i + 7];
  }
  double tail = 0.0;
  for (; i < dim; i++) {
    tail += (double)x[i] * (double)y[i];
  }
  return (((s0 + s1) + (s2 + s3)) + ((s4 + s5) + (s6 + s7))) + tail;
}

// float 累加对照（看 32 位累加的精度损失）
double benchx_dot_f32_facc(const void *ap, int32_t ai, const void *bp,
                           int32_t bi, int32_t dim) {
  const float *x = ((const benchx_buf_t *)ap)->data + ai;
  const float *y = ((const benchx_buf_t *)bp)->data + bi;
  float s = 0.0f;
  for (int32_t i = 0; i < dim; i++) {
    s += x[i] * y[i];
  }
  return (double)s;
}
