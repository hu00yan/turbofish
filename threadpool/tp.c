// threadpool/tp.c —— 纯 C pthread worker pool（仅 pthread + C 标准库）。
//
// 设计要点与原因：
// - worker 线程只执行 C 函数指针 job（void (*)(void*)）。MoonBit native 运行时
//   是引用计数/循环 GC，MoonBit 堆对象不能跨线程，因此 job 绝不能触碰 MoonBit
//   对象，也不能是 MoonBit 闭包。
// - 完成通知用 pipe(2)（macOS/Linux 均可用）：每完成 1 个 job 向写端写 1 字节。
//   字节只是唤醒信号；完成计数在锁内维护，pipe 满时丢字节不影响计数正确性
//   （pipe 满意味着读端可读，poll 一定能唤醒）。
// - 对外暴露句柄（槽位 index + 1）而非裸指针：destroy 把槽位置空，
//   重复 destroy、destroy 后 submit 都是明确定义的安全操作。
// - shutdown 策略：拒绝新 job，唤醒 worker；worker 把队列中已有 job 处理完
//   再退出（shutdown 时队列里的 job 已被接受，不应丢弃）。

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

typedef void (*tf_tp_job_fn)(void *);

typedef struct {
  tf_tp_job_fn fn;
  void *arg;
} TfTpJob;

typedef struct {
  pthread_mutex_t mtx;
  pthread_cond_t work_cv; /* worker 等待“有 job 或 shutdown” */
  TfTpJob *q;             /* 环形缓冲，容量 cap */
  int cap;
  int head;
  int tail;
  int count;
  int shutdown;   /* 置位后拒绝新 job，worker 排空队列后退出 */
  int nworkers;
  pthread_t *workers;
  int pipe_fd[2]; /* [0] 读端（poll/drain），[1] 写端（完成信号） */
  long submitted; /* 以下计数均在 mtx 保护下 */
  long completed;
  long drained;
} TfThreadPool;

/* ---------- 句柄表 ----------
 * MoonBit 侧只持有 int 句柄。destroy 置空槽位后句柄失效，
 * 重复 destroy 返回空操作，失效句柄上的 submit 返回 -2。
 * 表只在 API 调用线程访问（MoonBit 主线程），仍加锁以明确所有权。 */
static TfThreadPool **tf_tp_slots = NULL;
static int tf_tp_slots_cap = 0;
static pthread_mutex_t tf_tp_slot_mtx = PTHREAD_MUTEX_INITIALIZER;

static int tf_tp_slot_alloc(TfThreadPool *p) {
  pthread_mutex_lock(&tf_tp_slot_mtx);
  int i;
  for (i = 0; i < tf_tp_slots_cap; i++) {
    if (tf_tp_slots[i] == NULL) break;
  }
  if (i == tf_tp_slots_cap) {
    int new_cap = tf_tp_slots_cap ? tf_tp_slots_cap * 2 : 8;
    TfThreadPool **grown =
        (TfThreadPool **)realloc(tf_tp_slots, (size_t)new_cap * sizeof(TfThreadPool *));
    if (grown == NULL) {
      pthread_mutex_unlock(&tf_tp_slot_mtx);
      return 0; /* 调用方回滚整个 pool */
    }
    tf_tp_slots = grown;
    for (int j = tf_tp_slots_cap; j < new_cap; j++) tf_tp_slots[j] = NULL;
    tf_tp_slots_cap = new_cap;
  }
  tf_tp_slots[i] = p;
  pthread_mutex_unlock(&tf_tp_slot_mtx);
  return i + 1;
}

static TfThreadPool *tf_tp_slot_get(int handle) {
  if (handle <= 0) return NULL;
  pthread_mutex_lock(&tf_tp_slot_mtx);
  TfThreadPool *p = NULL;
  if (handle <= tf_tp_slots_cap) p = tf_tp_slots[handle - 1];
  pthread_mutex_unlock(&tf_tp_slot_mtx);
  return p;
}

/* ---------- 内部工具 ---------- */

static int tf_tp_set_nonblock(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0) return -1;
  return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

/* 完成 1 个 job：写 1 字节唤醒信号。非阻塞；pipe 满丢字节不影响计数。 */
static void tf_tp_signal_completion(TfThreadPool *p) {
  char b = 1;
  ssize_t w;
  do {
    w = write(p->pipe_fd[1], &b, 1);
  } while (w < 0 && errno == EINTR);
}

/* nop job：delay_us > 0 时在 worker 线程内延迟（nanosleep，非忙等）。 */
static void tf_tp_nop_job(void *arg) {
  long delay_us = (long)(intptr_t)arg;
  if (delay_us > 0) {
    struct timespec ts;
    ts.tv_sec = (time_t)(delay_us / 1000000L);
    ts.tv_nsec = (long)(delay_us % 1000000L) * 1000L;
    while (nanosleep(&ts, &ts) != 0 && errno == EINTR) {
    }
  }
}

static void *tf_tp_worker_main(void *arg) {
  TfThreadPool *p = (TfThreadPool *)arg;
  for (;;) {
    pthread_mutex_lock(&p->mtx);
    while (p->count == 0 && !p->shutdown) {
      pthread_cond_wait(&p->work_cv, &p->mtx);
    }
    if (p->count == 0) { /* shutdown 且队列已空 */
      pthread_mutex_unlock(&p->mtx);
      break;
    }
    TfTpJob job = p->q[p->head];
    p->head = (p->head + 1) % p->cap;
    p->count--;
    pthread_mutex_unlock(&p->mtx);

    job.fn(job.arg);

    pthread_mutex_lock(&p->mtx);
    p->completed++;
    pthread_mutex_unlock(&p->mtx);
    tf_tp_signal_completion(p);
  }
  return NULL;
}

/* 唤醒并 join 已创建的 workers[i0..i1)，用于创建失败回滚。 */
static void tf_tp_join_range(TfThreadPool *p, int i0, int i1) {
  pthread_mutex_lock(&p->mtx);
  p->shutdown = 1;
  pthread_cond_broadcast(&p->work_cv);
  pthread_mutex_unlock(&p->mtx);
  for (int i = i0; i < i1; i++) {
    pthread_join(p->workers[i], NULL);
  }
}

/* 拆除 pool 本体（join 之后调用）。 */
static void tf_tp_teardown(TfThreadPool *p) {
  if (p->pipe_fd[0] >= 0) close(p->pipe_fd[0]);
  if (p->pipe_fd[1] >= 0) close(p->pipe_fd[1]);
  pthread_cond_destroy(&p->work_cv);
  pthread_mutex_destroy(&p->mtx);
  free(p->q);
  free(p->workers);
  free(p);
}

/* ---------- 对外 API（FFI 句柄 = (void*)(intptr_t)(slot+1)） ---------- */

void *tf_tp_create(int32_t threads, int32_t queue_cap) {
  if (threads <= 0 || queue_cap <= 0) return NULL;

  TfThreadPool *p = (TfThreadPool *)calloc(1, sizeof(TfThreadPool));
  if (p == NULL) return NULL;
  p->pipe_fd[0] = p->pipe_fd[1] = -1;
  p->q = (TfTpJob *)calloc((size_t)queue_cap, sizeof(TfTpJob));
  p->workers = (pthread_t *)calloc((size_t)threads, sizeof(pthread_t));
  if (p->q == NULL || p->workers == NULL) goto fail_pre;
  p->cap = queue_cap;
  p->nworkers = threads;

  if (pipe(p->pipe_fd) != 0) goto fail_pre;
  if (tf_tp_set_nonblock(p->pipe_fd[0]) != 0) goto fail_pipe;
  if (tf_tp_set_nonblock(p->pipe_fd[1]) != 0) goto fail_pipe;

  if (pthread_mutex_init(&p->mtx, NULL) != 0) goto fail_pipe;
  if (pthread_cond_init(&p->work_cv, NULL) != 0) goto fail_mutex;

  for (int i = 0; i < threads; i++) {
    if (pthread_create(&p->workers[i], NULL, tf_tp_worker_main, p) != 0) {
      /* 回滚：唤醒并 join 已创建的 worker，再整体拆除 */
      tf_tp_join_range(p, 0, i);
      goto fail_cond;
    }
  }

  int handle = tf_tp_slot_alloc(p);
  if (handle == 0) {
    tf_tp_join_range(p, 0, threads);
    goto fail_cond;
  }
  return (void *)(intptr_t)handle;

fail_cond:
  pthread_cond_destroy(&p->work_cv);
fail_mutex:
  pthread_mutex_destroy(&p->mtx);
fail_pipe:
  close(p->pipe_fd[0]);
  close(p->pipe_fd[1]);
fail_pre:
  free(p->q);
  free(p->workers);
  free(p);
  return NULL;
}

/* FFI 辅助：MoonBit 侧不透明句柄无法直接判空，create 失败返回 NULL。 */
int32_t tf_tp_is_null(void *handle) { return handle == NULL; }

int32_t tf_tp_submit(void *handle, void (*fn)(void *), void *arg) {
  TfThreadPool *p = tf_tp_slot_get((int)(intptr_t)handle);
  if (p == NULL) return -2; /* 句柄已销毁，语义同 shutdown */
  pthread_mutex_lock(&p->mtx);
  if (p->shutdown) {
    pthread_mutex_unlock(&p->mtx);
    return -2;
  }
  if (p->count == p->cap) {
    pthread_mutex_unlock(&p->mtx);
    return -1; /* 满：不阻塞调用方 */
  }
  p->q[p->tail].fn = fn;
  p->q[p->tail].arg = arg;
  p->tail = (p->tail + 1) % p->cap;
  p->count++;
  p->submitted++;
  pthread_cond_signal(&p->work_cv);
  pthread_mutex_unlock(&p->mtx);
  return 0;
}

int32_t tf_tp_submit_nop(void *handle, int32_t delay_us) {
  return tf_tp_submit(handle, tf_tp_nop_job, (void *)(intptr_t)delay_us);
}

int32_t tf_tp_completion_fd(void *handle) {
  TfThreadPool *p = tf_tp_slot_get((int)(intptr_t)handle);
  return p == NULL ? -1 : p->pipe_fd[0];
}

int32_t tf_tp_drain(void *handle) {
  TfThreadPool *p = tf_tp_slot_get((int)(intptr_t)handle);
  if (p == NULL) return 0;
  /* 清空信号字节（仅唤醒用）；计数以锁内累计值为准 */
  char buf[256];
  for (;;) {
    ssize_t r = read(p->pipe_fd[0], buf, sizeof buf);
    if (r > 0) continue;
    if (r < 0 && errno == EINTR) continue;
    break;
  }
  pthread_mutex_lock(&p->mtx);
  long n = p->completed - p->drained;
  p->drained = p->completed;
  pthread_mutex_unlock(&p->mtx);
  return (int32_t)n;
}

int32_t tf_tp_wait_drain(void *handle, int32_t timeout_ms) {
  TfThreadPool *p = tf_tp_slot_get((int)(intptr_t)handle);
  if (p == NULL) return 0;
  if (timeout_ms > 0) {
    struct pollfd pf;
    pf.fd = p->pipe_fd[0];
    pf.events = POLLIN;
    pf.revents = 0;
    int r;
    do {
      r = poll(&pf, 1, timeout_ms);
    } while (r < 0 && errno == EINTR);
  }
  return tf_tp_drain(handle);
}

int32_t tf_tp_pending(void *handle) {
  TfThreadPool *p = tf_tp_slot_get((int)(intptr_t)handle);
  if (p == NULL) return 0;
  pthread_mutex_lock(&p->mtx);
  long n = p->submitted - p->completed;
  pthread_mutex_unlock(&p->mtx);
  return (int32_t)n;
}

void tf_tp_shutdown(void *handle) {
  TfThreadPool *p = tf_tp_slot_get((int)(intptr_t)handle);
  if (p == NULL) return;
  pthread_mutex_lock(&p->mtx);
  p->shutdown = 1;
  pthread_cond_broadcast(&p->work_cv);
  pthread_mutex_unlock(&p->mtx);
}

void tf_tp_destroy(void *handle) {
  int h = (int)(intptr_t)handle;
  if (h <= 0) return;
  pthread_mutex_lock(&tf_tp_slot_mtx);
  TfThreadPool *p = NULL;
  if (h <= tf_tp_slots_cap) {
    p = tf_tp_slots[h - 1];
    tf_tp_slots[h - 1] = NULL; /* 句柄立即失效：重复 destroy 走空操作 */
  }
  pthread_mutex_unlock(&tf_tp_slot_mtx);
  if (p == NULL) return;

  pthread_mutex_lock(&p->mtx);
  p->shutdown = 1;
  pthread_cond_broadcast(&p->work_cv);
  pthread_mutex_unlock(&p->mtx);
  for (int i = 0; i < p->nworkers; i++) {
    pthread_join(p->workers[i], NULL);
  }
  tf_tp_teardown(p);
}
