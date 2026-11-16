/* uring/uring.c —— 异步文件 IO 完成引擎（不依赖外部 liburing）。
 *
 * 两条后端路径，对 MoonBit 侧接口完全一致：
 *
 * 1. Linux 内核路径（`__linux__`）：直接用 syscall 调 `io_uring_setup` /
 *    `io_uring_enter` / `io_uring_register`，mmap SQ/CQ ring 与 SQE 数组，
 *    并用 eventfd 作为完成通知（`IORING_REGISTER_EVENTFD`）：内核每投递一个
 *    CQE 就给 eventfd 加 1，MoonBit 侧用 `@raw_fd.RawFd` 读该 fd 唤醒事件循环。
 *    全程不需要系统安装 liburing（只用内核 UAPI 头 <linux/io_uring.h>）。
 *    内核返回 ENOSYS / EPERM（容器/旧内核禁用）时自动回退到下面这条路径。
 *
 * 2. POSIX 回退路径（macOS / 受限 Linux）：`pipe` + `fcntl(O_NONBLOCK|O_CLOEXEC)`
 *    的读端作为 notify_fd 暴露给 MoonBit；固定 4 个 C pthread worker 消费环形
 *    任务队列，执行真正的 pread / pwrite / fsync，每完成一个请求把结果写入
 *    完成槽位并向 pipe 写端写 1 字节唤醒事件循环。
 *
 * ===== 线程安全 / GC 安全铁律 =====
 * C worker 线程绝不持有指向 MoonBit GC 堆的对象，也不回调 MoonBit：
 * - 提交时立刻 open(2) 拿到 fd，并为 payload 单独 malloc 一块 C buffer
 *   （写请求把 MoonBit Bytes 拷进 C buffer，读请求直接读进 C buffer）；
 * - 完成时只把 (out_len, errno) 记录在 C 侧槽位里；
 * - MoonBit 主线程随后用 `tf_uring_copy_result(handle, slot, dst, cap)` 把数据
 *   拷回 MoonBit `FixedArray[Byte]`，并由同一个调用 free 掉 C buffer、close fd、
 *   释放槽位。
 * 因此没有任何 MoonBit 对象跨线程，也没有悬挂指针。
 *
 * ===== 通知通道的语义 =====
 * notify fd 只当“有完成事件”的唤醒信号用，完成的可信来源是完成队列本身：
 * MoonBit 侧一律先 `tf_uring_harvest()` 取空完成队列，取不到才去读 notify fd。
 * 这样即使 pipe/eventfd 的字节被合并、丢弃（pipe 满）也不会丢事件。
 */

#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE 1
#endif

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#ifdef __linux__
#include <linux/io_uring.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#endif

#define TF_URING_BACKEND_IO_URING 0
#define TF_URING_BACKEND_POSIX 1

#define TF_REQ_FREE 0
#define TF_REQ_INFLIGHT 1
#define TF_REQ_DONE 2

#define TF_OP_READ 0
#define TF_OP_WRITE 1

/* POSIX 回退路径的 worker 数量：固定 4 个（小文件随机读的甜点）。 */
#define TF_POSIX_WORKERS 4

/* 路径缓冲上限：显式长度 + 栈上 NUL 结尾，避免任何跨线程字符串生命周期问题。 */
#define TF_PATH_MAX 4096

typedef struct TfUring TfUring;

typedef struct {
  int32_t state;       /* TF_REQ_FREE / INFLIGHT / DONE */
  int32_t kind;        /* TF_OP_READ / TF_OP_WRITE */
  int32_t fd;          /* 提交时 open 得到的 fd，完成时 close */
  int32_t want;        /* 请求字节数 */
  int32_t out_len;     /* 实际传输字节数；-1 表示失败（见 err） */
  int32_t err;         /* 失败时的 errno（0 表示成功） */
  int64_t offset;
  uint8_t *buf;        /* C 侧 malloc 的 payload buffer（读入/写出） */
  int32_t cap;
  int32_t need_sync;   /* 写请求是否 fsync */
  int32_t pending_ops; /* io_uring: 该请求还剩几个 CQE（写 + fsync 链接 = 2） */
} TfReq;

struct TfUring {
  int32_t depth;
  int32_t backend;
  int notify_fd; /* 读端（POSIX pipe）或 eventfd（io_uring），交给 MoonBit 的 RawFd */
  int signal_fd; /* POSIX pipe 写端；io_uring 路径为 -1 */
  pthread_mutex_t mtx;
  pthread_cond_t work_cv;
  TfReq *reqs;
  int *done_q;
  int done_head, done_tail, done_count;
  int *work_q;
  int work_head, work_tail, work_count;
  int shutdown;
  pthread_t workers[TF_POSIX_WORKERS];
  int nworkers;
#ifdef __linux__
  int ring_fd;
  unsigned *sq_head;
  unsigned *sq_tail;
  unsigned *sq_ring_mask;
  unsigned *sq_ring_entries;
  unsigned *sq_flags;
  unsigned *sq_dropped;
  unsigned *sq_array;
  unsigned *cq_head;
  unsigned *cq_tail;
  unsigned *cq_ring_mask;
  unsigned *cq_ring_entries;
  struct io_uring_sqe *sqes;
  struct io_uring_cqe *cqes;
  void *sq_ptr;
  void *cq_ptr;
  size_t sq_map_sz;
  size_t cq_map_sz;
  size_t sqes_sz;
  int sqcq_shared;
#endif
};

/* ---------- 句柄表（同 threadpool/tp.c 的约定） ----------
 * MoonBit 只持有 int 句柄。close 把槽位置空后句柄立即失效，
 * 重复 close 是无害空操作，失效句柄上的 submit 返回 -EBADF。 */
static TfUring **tf_uring_slots = NULL;
static int tf_uring_slots_cap = 0;
static pthread_mutex_t tf_uring_slot_mtx = PTHREAD_MUTEX_INITIALIZER;

static int tf_uring_slot_alloc(TfUring *r) {
  pthread_mutex_lock(&tf_uring_slot_mtx);
  int i;
  for (i = 0; i < tf_uring_slots_cap; i++) {
    if (tf_uring_slots[i] == NULL) break;
  }
  if (i == tf_uring_slots_cap) {
    int new_cap = tf_uring_slots_cap ? tf_uring_slots_cap * 2 : 8;
    TfUring **grown =
        (TfUring **)realloc(tf_uring_slots, (size_t)new_cap * sizeof(TfUring *));
    if (grown == NULL) {
      pthread_mutex_unlock(&tf_uring_slot_mtx);
      return 0;
    }
    tf_uring_slots = grown;
    for (int j = tf_uring_slots_cap; j < new_cap; j++) tf_uring_slots[j] = NULL;
    tf_uring_slots_cap = new_cap;
  }
  tf_uring_slots[i] = r;
  pthread_mutex_unlock(&tf_uring_slot_mtx);
  return i + 1;
}

static TfUring *tf_uring_get(void *handle) {
  int h = (int)(intptr_t)handle;
  if (h <= 0) return NULL;
  pthread_mutex_lock(&tf_uring_slot_mtx);
  TfUring *r = NULL;
  if (h <= tf_uring_slots_cap) r = tf_uring_slots[h - 1];
  pthread_mutex_unlock(&tf_uring_slot_mtx);
  return r;
}

static TfUring *tf_uring_detach(void *handle) {
  int h = (int)(intptr_t)handle;
  if (h <= 0) return NULL;
  pthread_mutex_lock(&tf_uring_slot_mtx);
  TfUring *r = NULL;
  if (h <= tf_uring_slots_cap) {
    r = tf_uring_slots[h - 1];
    tf_uring_slots[h - 1] = NULL;
  }
  pthread_mutex_unlock(&tf_uring_slot_mtx);
  return r;
}

/* ---------- 通用工具 ---------- */

static int tf_uring_cloexec(int fd) {
  int flags = fcntl(fd, F_GETFD, 0);
  if (flags < 0) return -1;
  return fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

static int tf_uring_nonblock(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0) return -1;
  return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

/* 显式长度路径 → 栈上 NUL 结尾；返回 -ENAMETOOLONG / -EINVAL 等负 errno。 */
static int tf_uring_open_path(
  const uint8_t *path,
  int32_t path_len,
  int flags
) {
  if (path == NULL || path_len <= 0) return -EINVAL;
  if (path_len >= TF_PATH_MAX) return -ENAMETOOLONG;
  char p[TF_PATH_MAX];
  memcpy(p, path, (size_t)path_len);
  p[path_len] = '\0';
  int fd;
  do {
    fd = open(p, flags | O_CLOEXEC, 0644);
  } while (fd < 0 && errno == EINTR);
  return fd < 0 ? -errno : fd;
}

/* 完成 1 个请求：入完成队列（调用方必须持有 mtx）。 */
static void tf_uring_finish_locked(TfUring *r, int slot) {
  TfReq *q = &r->reqs[slot];
  q->state = TF_REQ_DONE;
  r->done_q[r->done_tail] = slot;
  r->done_tail = (r->done_tail + 1) % r->depth;
  r->done_count++;
}

/* 唤醒事件循环：POSIX 路径写 1 字节；io_uring 由内核 eventfd 负责。 */
static void tf_uring_wake(TfUring *r) {
  if (r->signal_fd < 0) return;
  char b = 1;
  ssize_t w;
  do {
    w = write(r->signal_fd, &b, 1);
  } while (w < 0 && errno == EINTR);
  (void)w;
}

/* 释放槽位（调用方持有 mtx）：free C buffer、close fd、槽位置空。 */static void tf_uring_release_locked(TfUring *r, int slot) {
  TfReq *q = &r->reqs[slot];
  if (q->buf != NULL) {
    free(q->buf);
    q->buf = NULL;
  }
  if (q->fd >= 0) {
    close(q->fd);
    q->fd = -1;
  }
  q->state = TF_REQ_FREE;
  q->want = 0;
  q->out_len = 0;
  q->err = 0;
  q->cap = 0;
  q->pending_ops = 0;
}

static int tf_uring_alloc_slot_locked(TfUring *r) {
  for (int i = 0; i < r->depth; i++) {
    if (r->reqs[i].state == TF_REQ_FREE) return i;
  }
  return -1;
}

/* ---------- POSIX 回退路径：pipe + 4 个 pthread worker ---------- */

static void tf_uring_posix_run_job(TfUring *r, int slot);

static void *tf_uring_worker_main(void *arg) {
  TfUring *r = (TfUring *)arg;
  /* 阻断 SIGPIPE：read 端被关闭时 write 只会返回 EPIPE 而不是杀进程。
   * 生成的 SIGPIPE 挂在线程自身，线程退出时被丢弃，不影响进程。 */
  sigset_t set;
  sigemptyset(&set);
  sigaddset(&set, SIGPIPE);
  pthread_sigmask(SIG_BLOCK, &set, NULL);
  for (;;) {
    pthread_mutex_lock(&r->mtx);
    while (r->work_count == 0 && !r->shutdown) {
      pthread_cond_wait(&r->work_cv, &r->mtx);
    }
    if (r->work_count == 0) { /* shutdown 且队列已空 */
      pthread_mutex_unlock(&r->mtx);
      break;
    }
    int slot = r->work_q[r->work_head];
    r->work_head = (r->work_head + 1) % r->depth;
    r->work_count--;
    pthread_mutex_unlock(&r->mtx);

    tf_uring_posix_run_job(r, slot);
  }
  return NULL;
}

static void tf_uring_posix_run_job(TfUring *r, int slot) {
  TfReq *q = &r->reqs[slot];
  int32_t total = 0;
  int32_t err = 0;
  if (q->kind == TF_OP_READ) {
    while (total < q->want) {
      ssize_t n = pread(
        q->fd,
        q->buf + total,
        (size_t)(q->want - total),
        (off_t)(q->offset + total)
      );
      if (n < 0) {
        if (errno == EINTR) continue;
        err = errno;
        total = -1;
        break;
      }
      if (n == 0) break; /* EOF */
      total += (int32_t)n;
    }
  } else {
    while (total < q->want) {
      ssize_t n = pwrite(
        q->fd,
        q->buf + total,
        (size_t)(q->want - total),
        (off_t)(q->offset + total)
      );
      if (n < 0) {
        if (errno == EINTR) continue;
        err = errno;
        total = -1;
        break;
      }
      if (n == 0) break;
      total += (int32_t)n;
    }
    if (total >= 0 && q->need_sync) {
      int rc;
      do {
        rc = fsync(q->fd);
      } while (rc != 0 && errno == EINTR);
      if (rc != 0) {
        err = errno;
        total = -1;
      }
    }
  }
  if (q->fd >= 0) {
    close(q->fd);
    q->fd = -1;
  }
  pthread_mutex_lock(&r->mtx);
  q->err = err;
  q->out_len = total;
  tf_uring_finish_locked(r, slot);
  pthread_mutex_unlock(&r->mtx);
  tf_uring_wake(r);
}

static int tf_uring_setup_posix(TfUring *r) {
  int fds[2];
  if (pipe(fds) != 0) return -errno;
  if (tf_uring_nonblock(fds[0]) != 0 || tf_uring_nonblock(fds[1]) != 0 ||
      tf_uring_cloexec(fds[0]) != 0 || tf_uring_cloexec(fds[1]) != 0) {
    int e = errno;
    close(fds[0]);
    close(fds[1]);
    return -e;
  }
  r->notify_fd = fds[0];
  r->signal_fd = fds[1];
  for (int i = 0; i < TF_POSIX_WORKERS; i++) {
    if (pthread_create(&r->workers[i], NULL, tf_uring_worker_main, r) != 0) {
      /* 回滚已创建的 worker */
      pthread_mutex_lock(&r->mtx);
      r->shutdown = 1;
      pthread_cond_broadcast(&r->work_cv);
      pthread_mutex_unlock(&r->mtx);
      for (int j = 0; j < i; j++) pthread_join(r->workers[j], NULL);
      close(fds[0]);
      close(fds[1]);
      r->notify_fd = -1;
      r->signal_fd = -1;
      return -EAGAIN;
    }
    r->nworkers++;
  }
  r->backend = TF_URING_BACKEND_POSIX;
  return 0;
}

/* ---------- Linux 内核路径：raw io_uring syscalls ---------- */

#ifdef __linux__

static int tf_uring_enter_raw(
  TfUring *r,
  unsigned submit,
  unsigned wait,
  unsigned flags
) {
  return (int)syscall(
    __NR_io_uring_enter,
    (unsigned)r->ring_fd,
    submit,
    wait,
    flags,
    (void *)0,
    (size_t)0
  );
}

static int tf_uring_setup_linux(TfUring *r, int entries) {
  struct io_uring_params p;
  memset(&p, 0, sizeof(p));
  int fd = (int)syscall(__NR_io_uring_setup, (unsigned)entries, &p);
  if (fd < 0) return -errno;
  r->ring_fd = fd;

  size_t sq_ring_sz = p.sq_off.array + p.sq_entries * sizeof(unsigned);
  size_t cq_ring_sz =
      p.cq_off.cqes + p.cq_entries * sizeof(struct io_uring_cqe);
  r->sqcq_shared = (p.features & IORING_FEAT_SINGLE_MMAP) != 0;
  if (r->sqcq_shared) {
    size_t sz = sq_ring_sz > cq_ring_sz ? sq_ring_sz : cq_ring_sz;
    void *ptr = mmap(
      NULL,
      sz,
      PROT_READ | PROT_WRITE,
      MAP_SHARED | MAP_POPULATE,
      fd,
      IORING_OFF_SQ_RING
    );
    if (ptr == MAP_FAILED) {
      int e = errno;
      close(fd);
      r->ring_fd = -1;
      return -e;
    }
    r->sq_ptr = ptr;
    r->cq_ptr = ptr;
    r->sq_map_sz = sz;
    r->cq_map_sz = sz;
  } else {
    void *sq = mmap(
      NULL,
      sq_ring_sz,
      PROT_READ | PROT_WRITE,
      MAP_SHARED | MAP_POPULATE,
      fd,
      IORING_OFF_SQ_RING
    );
    if (sq == MAP_FAILED) {
      int e = errno;
      close(fd);
      r->ring_fd = -1;
      return -e;
    }
    void *cq = mmap(
      NULL,
      cq_ring_sz,
      PROT_READ | PROT_WRITE,
      MAP_SHARED | MAP_POPULATE,
      fd,
      IORING_OFF_CQ_RING
    );
    if (cq == MAP_FAILED) {
      int e = errno;
      munmap(sq, sq_ring_sz);
      close(fd);
      r->ring_fd = -1;
      return -e;
    }
    r->sq_ptr = sq;
    r->cq_ptr = cq;
    r->sq_map_sz = sq_ring_sz;
    r->cq_map_sz = cq_ring_sz;
  }

  r->sqes_sz = p.sq_entries * sizeof(struct io_uring_sqe);
  void *sqes = mmap(
    NULL,
    r->sqes_sz,
    PROT_READ | PROT_WRITE,
    MAP_SHARED | MAP_POPULATE,
    fd,
    IORING_OFF_SQES
  );
  if (sqes == MAP_FAILED) {
    int e = errno;
    munmap(r->sq_ptr, r->sq_map_sz);
    if (!r->sqcq_shared) munmap(r->cq_ptr, r->cq_map_sz);
    r->sq_ptr = NULL;
    r->cq_ptr = NULL;
    close(fd);
    r->ring_fd = -1;
    return -e;
  }
  r->sqes = (struct io_uring_sqe *)sqes;

  char *sq = (char *)r->sq_ptr;
  char *cq = (char *)r->cq_ptr;
  r->sq_head = (unsigned *)(sq + p.sq_off.head);
  r->sq_tail = (unsigned *)(sq + p.sq_off.tail);
  r->sq_ring_mask = (unsigned *)(sq + p.sq_off.ring_mask);
  r->sq_ring_entries = (unsigned *)(sq + p.sq_off.ring_entries);
  r->sq_flags = (unsigned *)(sq + p.sq_off.flags);
  r->sq_dropped = (unsigned *)(sq + p.sq_off.dropped);
  r->sq_array = (unsigned *)(sq + p.sq_off.array);
  r->cq_head = (unsigned *)(cq + p.cq_off.head);
  r->cq_tail = (unsigned *)(cq + p.cq_off.tail);
  r->cq_ring_mask = (unsigned *)(cq + p.cq_off.ring_mask);
  r->cq_ring_entries = (unsigned *)(cq + p.cq_off.ring_entries);
  r->cqes = (struct io_uring_cqe *)(cq + p.cq_off.cqes);

  /* 完成通知：eventfd，内核每投递一个 CQE 就 +1，MoonBit 读它即被唤醒。 */
  int efd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
  if (efd < 0) {
    int e = errno;
    munmap(r->sqes, r->sqes_sz);
    munmap(r->sq_ptr, r->sq_map_sz);
    if (!r->sqcq_shared) munmap(r->cq_ptr, r->cq_map_sz);
    r->sqes = NULL;
    r->sq_ptr = NULL;
    r->cq_ptr = NULL;
    close(fd);
    r->ring_fd = -1;
    return -e;
  }
  int efd_arg = efd;
  if (syscall(__NR_io_uring_register, fd, IORING_REGISTER_EVENTFD, &efd_arg, 1) <
      0) {
    int e = errno;
    close(efd);
    munmap(r->sqes, r->sqes_sz);
    munmap(r->sq_ptr, r->sq_map_sz);
    if (!r->sqcq_shared) munmap(r->cq_ptr, r->cq_map_sz);
    r->sqes = NULL;
    r->sq_ptr = NULL;
    r->cq_ptr = NULL;
    close(fd);
    r->ring_fd = -1;
    return -e;
  }
  r->notify_fd = efd;
  r->signal_fd = -1;
  r->backend = TF_URING_BACKEND_IO_URING;
  return 0;
}

/* 预留一个 SQE；返回 SQE 指针，满则 NULL。调用方持有 mtx。 */
static struct io_uring_sqe *tf_uring_next_sqe(TfUring *r, unsigned *saved_tail) {
  unsigned head = __atomic_load_n(r->sq_head, __ATOMIC_ACQUIRE);
  unsigned tail = *r->sq_tail;
  if (tail - head >= *r->sq_ring_entries) return NULL;
  unsigned idx = tail & *r->sq_ring_mask;
  struct io_uring_sqe *sqe = &r->sqes[idx];
  memset(sqe, 0, sizeof(*sqe));
  r->sq_array[idx] = idx;
  *saved_tail = tail;
  /* RELEASE：先把 SQE 内容与 sq_array 写完，再发布新的 tail。 */
  __atomic_store_n(r->sq_tail, tail + 1, __ATOMIC_RELEASE);
  return sqe;
}

/* 收割 CQE（只在 MoonBit 主线程调用，调用方持有 mtx）。 */
static void tf_uring_reap_cqe_locked(TfUring *r) {
  unsigned head = *r->cq_head;
  unsigned tail = __atomic_load_n(r->cq_tail, __ATOMIC_ACQUIRE);
  while (head != tail) {
    struct io_uring_cqe *cqe = &r->cqes[head & *r->cq_ring_mask];
    int slot = (int)cqe->user_data;
    if (slot >= 0 && slot < r->depth) {
      TfReq *q = &r->reqs[slot];
      if (q->state == TF_REQ_INFLIGHT) {
        if (cqe->res < 0) {
          q->err = -cqe->res;
          q->out_len = -1;
        } else if (q->out_len >= 0) {
          /* WRITE 的 CQE 带字节数，链接的 FSYNC CQE 是 0，累加即可。 */
          q->out_len += cqe->res;
        }
        q->pending_ops--;
        if (q->pending_ops <= 0) {
          if (q->fd >= 0) {
            close(q->fd);
            q->fd = -1;
          }
          if (q->out_len > q->want) q->out_len = q->want;
          tf_uring_finish_locked(r, slot);
        }
      }
    }
    head++;
  }
  /* RELEASE：CQE 内容已读完，先把 head 前移发布给内核，内核才能复用条目。 */
  __atomic_store_n(r->cq_head, head, __ATOMIC_RELEASE);
}

/* 把 1 个（或链接的 2 个）op 提交进 ring 并 enter。调用方持有 mtx。 */
static int tf_uring_submit_linux_locked(TfUring *r, int slot) {
  TfReq *q = &r->reqs[slot];
  unsigned saved1 = 0, saved2 = 0;
  struct io_uring_sqe *sqe = tf_uring_next_sqe(r, &saved1);
  if (sqe == NULL) return -EBUSY;
  unsigned want_submit = 1;
  q->out_len = 0;
  q->pending_ops = 1;
  if (q->kind == TF_OP_READ) {
    sqe->opcode = IORING_OP_READ;
    sqe->fd = q->fd;
    sqe->addr = (uint64_t)(uintptr_t)q->buf;
    sqe->len = (uint32_t)q->want;
    sqe->off = (uint64_t)q->offset;
    sqe->user_data = (uint64_t)slot;
  } else {
    sqe->opcode = IORING_OP_WRITE;
    sqe->fd = q->fd;
    sqe->addr = (uint64_t)(uintptr_t)q->buf;
    sqe->len = (uint32_t)q->want;
    sqe->off = (uint64_t)q->offset;
    sqe->user_data = (uint64_t)slot;
    if (q->need_sync) {
      struct io_uring_sqe *fs = tf_uring_next_sqe(r, &saved2);
      if (fs == NULL) {
        __atomic_store_n(r->sq_tail, saved1, __ATOMIC_RELEASE); /* 回滚半条链 */
        return -EBUSY;
      }
      sqe->flags |= IOSQE_IO_LINK;
      fs->opcode = IORING_OP_FSYNC;
      fs->fd = q->fd;
      fs->user_data = (uint64_t)slot;
      q->pending_ops = 2;
      want_submit = 2;
    }
  }
  int rc;
  do {
    rc = tf_uring_enter_raw(r, want_submit, 0, 0);
  } while (rc < 0 && errno == EINTR);
  if (rc < 0) {
    int e = errno;
    /* 回滚 SQ 游标，避免后续 enter 提交一条无效 op。 */
    __atomic_store_n(r->sq_tail, saved1, __ATOMIC_RELEASE);
    return -e;
  }
  return 0;
}

#endif /* __linux__ */

/* ---------- 提交 ---------- */

static int32_t tf_uring_submit_common(
  void *handle,
  int32_t kind,
  const uint8_t *path,
  int32_t path_len,
  int64_t offset,
  const uint8_t *data,
  int32_t len,
  int32_t sync
) {
  TfUring *r = tf_uring_get(handle);
  if (r == NULL) return -EBADF;
  if (len < 0 || offset < 0) return -EINVAL;
  int fd = tf_uring_open_path(
    path,
    path_len,
    kind == TF_OP_READ ? O_RDONLY : (O_WRONLY | O_CREAT)
  );
  if (fd < 0) return fd; /* 负 errno：调用方直接映射为 None */

  uint8_t *buf = NULL;
  if (len > 0) {
    buf = (uint8_t *)malloc((size_t)len);
    if (buf == NULL) {
      close(fd);
      return -ENOMEM;
    }
    if (kind == TF_OP_WRITE) {
      if (data == NULL) {
        free(buf);
        close(fd);
        return -EINVAL;
      }
      memcpy(buf, data, (size_t)len);
    }
  }

  pthread_mutex_lock(&r->mtx);
  int slot = tf_uring_alloc_slot_locked(r);
  if (slot < 0) {
    pthread_mutex_unlock(&r->mtx);
    free(buf);
    close(fd);
    return -EBUSY;
  }
  if (len == 0) {
    /* 0 字节请求：不投递 op（部分内核拒绝 len=0 的 READ/WRITE），就地完成。
     * 写请求的 fsync 也在这里同步做完。 */
    TfReq *z = &r->reqs[slot];
    z->state = TF_REQ_INFLIGHT;
    z->kind = kind;
    z->fd = fd;
    z->want = 0;
    z->cap = 0;
    z->buf = NULL;
    z->offset = offset;
    z->need_sync = sync ? 1 : 0;
    z->pending_ops = 0;
    z->err = 0;
    z->out_len = 0;
    if (kind == TF_OP_WRITE && z->need_sync) {
      int rc;
      do {
        rc = fsync(fd);
      } while (rc != 0 && errno == EINTR);
      if (rc != 0) {
        z->err = errno;
        z->out_len = -1;
      }
    }
    close(fd);
    z->fd = -1;
    tf_uring_finish_locked(r, slot);
    pthread_mutex_unlock(&r->mtx);
    tf_uring_wake(r);
    return slot;
  }
  TfReq *q = &r->reqs[slot];
  q->state = TF_REQ_INFLIGHT;
  q->kind = kind;
  q->fd = fd;
  q->want = len;
  q->cap = len;
  q->buf = buf;
  q->err = 0;
  q->out_len = 0;
  q->offset = offset;
  q->need_sync = sync ? 1 : 0;
  q->pending_ops = 1;
  if (r->backend == TF_URING_BACKEND_POSIX) {
    r->work_q[r->work_tail] = slot;
    r->work_tail = (r->work_tail + 1) % r->depth;
    r->work_count++;
    pthread_cond_signal(&r->work_cv);
    pthread_mutex_unlock(&r->mtx);
    return slot;
  }
#ifdef __linux__
  int rc = tf_uring_submit_linux_locked(r, slot);
  if (rc != 0) {
    q->state = TF_REQ_FREE;
    q->buf = NULL;
    pthread_mutex_unlock(&r->mtx);
    free(buf);
    close(fd);
    return rc;
  }
  pthread_mutex_unlock(&r->mtx);
  return slot;
#else
  pthread_mutex_unlock(&r->mtx);
  free(buf);
  close(fd);
  return -ENOSYS;
#endif
}

/* ---------- 对外 API ---------- */

void *tf_uring_create(int32_t depth) {
  if (depth < 2) depth = 2;
  if (depth > 4096) depth = 4096;
  TfUring *r = (TfUring *)calloc(1, sizeof(TfUring));
  if (r == NULL) return NULL;
  r->depth = depth;
  r->notify_fd = -1;
  r->signal_fd = -1;
  r->reqs = (TfReq *)calloc((size_t)depth, sizeof(TfReq));
  r->done_q = (int *)calloc((size_t)depth, sizeof(int));
  r->work_q = (int *)calloc((size_t)depth, sizeof(int));
  if (r->reqs == NULL || r->done_q == NULL || r->work_q == NULL) {
    free(r->reqs);
    free(r->done_q);
    free(r->work_q);
    free(r);
    return NULL;
  }
  for (int i = 0; i < depth; i++) {
    r->reqs[i].state = TF_REQ_FREE;
    r->reqs[i].fd = -1;
  }
  if (pthread_mutex_init(&r->mtx, NULL) != 0) {
    free(r->reqs);
    free(r->done_q);
    free(r->work_q);
    free(r);
    return NULL;
  }
  if (pthread_cond_init(&r->work_cv, NULL) != 0) {
    pthread_mutex_destroy(&r->mtx);
    free(r->reqs);
    free(r->done_q);
    free(r->work_q);
    free(r);
    return NULL;
  }
  r->backend = TF_URING_BACKEND_POSIX;
#ifdef __linux__
  r->ring_fd = -1;
  /* 容器/旧内核返回 ENOSYS / EPERM 时静默回退到 POSIX worker 路径。 */
  if (tf_uring_setup_linux(r, depth) != 0) {
    r->notify_fd = -1;
    r->signal_fd = -1;
    r->backend = TF_URING_BACKEND_POSIX;
  }
#endif
  if (r->backend != TF_URING_BACKEND_IO_URING) {
    if (tf_uring_setup_posix(r) != 0) {
      pthread_cond_destroy(&r->work_cv);
      pthread_mutex_destroy(&r->mtx);
      free(r->reqs);
      free(r->done_q);
      free(r->work_q);
      free(r);
      return NULL;
    }
  }
  int handle = tf_uring_slot_alloc(r);
  if (handle == 0) {
    /* 句柄表扩容失败：整体回滚（worker 先唤醒排空再 join）。 */
    pthread_mutex_lock(&r->mtx);
    r->shutdown = 1;
    pthread_cond_broadcast(&r->work_cv);
    pthread_mutex_unlock(&r->mtx);
    for (int i = 0; i < r->nworkers; i++) pthread_join(r->workers[i], NULL);
    if (r->signal_fd >= 0) close(r->signal_fd);
#ifdef __linux__
    if (r->ring_fd >= 0) close(r->ring_fd);
#endif
    pthread_cond_destroy(&r->work_cv);
    pthread_mutex_destroy(&r->mtx);
    free(r->reqs);
    free(r->done_q);
    free(r->work_q);
    free(r);
    return NULL;
  }
  return (void *)(intptr_t)handle;
}

int32_t tf_uring_is_null(void *handle) { return handle == NULL; }

/* 临时文件名序号：同一进程内单调递增，保证并发 write_file_atomic
 * 即使写同一个目标路径也不会共用临时文件。 */
int32_t tf_uring_next_tmp_id(void) {
  static int32_t counter = 0;
  pthread_mutex_lock(&tf_uring_slot_mtx);
  counter++;
  int32_t out = counter;
  pthread_mutex_unlock(&tf_uring_slot_mtx);
  return out;
}

int32_t tf_uring_backend_kind(void *handle) {
  TfUring *r = tf_uring_get(handle);
  return r == NULL ? -1 : r->backend;
}

int32_t tf_uring_notify_fd(void *handle) {
  TfUring *r = tf_uring_get(handle);
  return r == NULL ? -1 : r->notify_fd;
}

int64_t tf_uring_file_size(const uint8_t *path, int32_t path_len) {
  int fd = tf_uring_open_path(path, path_len, O_RDONLY);
  if (fd < 0) return (int64_t)fd;
  struct stat st;
  int rc;
  do {
    rc = fstat(fd, &st);
  } while (rc != 0 && errno == EINTR);
  int e = rc == 0 ? 0 : errno;
  close(fd);
  if (rc != 0) return (int64_t)(-e);
  return (int64_t)st.st_size;
}

int32_t tf_uring_submit_read(
  void *handle,
  const uint8_t *path,
  int32_t path_len,
  int64_t offset,
  int32_t len
) {
  return tf_uring_submit_common(
    handle,
    TF_OP_READ,
    path,
    path_len,
    offset,
    NULL,
    len,
    0
  );
}

int32_t tf_uring_submit_write(
  void *handle,
  const uint8_t *path,
  int32_t path_len,
  int64_t offset,
  const uint8_t *data,
  int32_t len,
  int32_t sync
) {
  return tf_uring_submit_common(
    handle,
    TF_OP_WRITE,
    path,
    path_len,
    offset,
    data,
    len,
    sync
  );
}

int32_t tf_uring_harvest(void *handle) {
  TfUring *r = tf_uring_get(handle);
  if (r == NULL) return -1;
  pthread_mutex_lock(&r->mtx);
#ifdef __linux__
  if (r->backend == TF_URING_BACKEND_IO_URING) tf_uring_reap_cqe_locked(r);
#endif
  int slot = -1;
  if (r->done_count > 0) {
    slot = r->done_q[r->done_head];
    r->done_head = (r->done_head + 1) % r->depth;
    r->done_count--;
  }
  pthread_mutex_unlock(&r->mtx);
  return slot;
}

/* 返回 >= 0 实际字节数；-1 请求失败（errno 见 tf_uring_result_errno）；
 * -2 槽位未完成或参数非法。 */
int32_t tf_uring_result_len(void *handle, int32_t slot) {
  TfUring *r = tf_uring_get(handle);
  if (r == NULL || slot < 0 || slot >= r->depth) return -2;
  pthread_mutex_lock(&r->mtx);
  TfReq *q = &r->reqs[slot];
  int32_t out = -2;
  if (q->state == TF_REQ_DONE) out = q->out_len;
  pthread_mutex_unlock(&r->mtx);
  return out;
}

int32_t tf_uring_result_errno(void *handle, int32_t slot) {
  TfUring *r = tf_uring_get(handle);
  if (r == NULL || slot < 0 || slot >= r->depth) return 0;
  pthread_mutex_lock(&r->mtx);
  int32_t out = r->reqs[slot].err;
  pthread_mutex_unlock(&r->mtx);
  return out;
}

int32_t tf_uring_copy_result(
  void *handle,
  int32_t slot,
  uint8_t *dst,
  int32_t cap
) {
  TfUring *r = tf_uring_get(handle);
  if (r == NULL || slot < 0 || slot >= r->depth) return -1;
  pthread_mutex_lock(&r->mtx);
  TfReq *q = &r->reqs[slot];
  if (q->state != TF_REQ_DONE) {
    pthread_mutex_unlock(&r->mtx);
    return -1;
  }
  int32_t n = q->out_len > 0 ? q->out_len : 0;
  if (n > cap) n = cap;
  if (n > 0 && q->buf != NULL && dst != NULL) {
    memcpy(dst, q->buf, (size_t)n);
  }
  tf_uring_release_locked(r, slot);
  pthread_mutex_unlock(&r->mtx);
  return n;
}

void tf_uring_discard(void *handle, int32_t slot) {
  TfUring *r = tf_uring_get(handle);
  if (r == NULL || slot < 0 || slot >= r->depth) return;
  pthread_mutex_lock(&r->mtx);
  if (r->reqs[slot].state == TF_REQ_DONE) tf_uring_release_locked(r, slot);
  pthread_mutex_unlock(&r->mtx);
}

int32_t tf_uring_rename(
  const uint8_t *from,
  int32_t from_len,
  const uint8_t *to,
  int32_t to_len
) {
  if (from_len <= 0 || to_len <= 0 || from_len >= TF_PATH_MAX ||
      to_len >= TF_PATH_MAX) {
    return -EINVAL;
  }
  char a[TF_PATH_MAX];
  char b[TF_PATH_MAX];
  memcpy(a, from, (size_t)from_len);
  a[from_len] = '\0';
  memcpy(b, to, (size_t)to_len);
  b[to_len] = '\0';
  int rc;
  do {
    rc = rename(a, b);
  } while (rc != 0 && errno == EINTR);
  return rc == 0 ? 0 : -errno;
}

int32_t tf_uring_unlink(const uint8_t *path, int32_t path_len) {
  if (path_len <= 0 || path_len >= TF_PATH_MAX) return -EINVAL;
  char p[TF_PATH_MAX];
  memcpy(p, path, (size_t)path_len);
  p[path_len] = '\0';
  int rc;
  do {
    rc = unlink(p);
  } while (rc != 0 && errno == EINTR);
  return rc == 0 ? 0 : -errno;
}

void tf_uring_close(void *handle) {
  TfUring *r = tf_uring_detach(handle);
  if (r == NULL) return;

  /* 1) 让 POSIX worker 把队列排空并退出（此时读端仍开着，不会 EPIPE）。 */
  pthread_mutex_lock(&r->mtx);
  r->shutdown = 1;
  pthread_cond_broadcast(&r->work_cv);
  pthread_mutex_unlock(&r->mtx);
  for (int i = 0; i < r->nworkers; i++) {
    pthread_join(r->workers[i], NULL);
  }

#ifdef __linux__
  if (r->backend == TF_URING_BACKEND_IO_URING && r->ring_fd >= 0) {
    /* 2) 内核路径：短暂收割剩余 CQE，尽量让 in-flight 请求自然结束，
     *    再关 ring fd（关闭会取消仍未完成的请求）。 */
    for (int i = 0; i < 400; i++) {
      int inflight = 0;
      pthread_mutex_lock(&r->mtx);
      tf_uring_reap_cqe_locked(r);
      for (int s = 0; s < r->depth; s++) {
        if (r->reqs[s].state == TF_REQ_INFLIGHT) inflight++;
      }
      pthread_mutex_unlock(&r->mtx);
      if (inflight == 0) break;
      struct timespec ts;
      ts.tv_sec = 0;
      ts.tv_nsec = 1000000L; /* 1ms */
      nanosleep(&ts, NULL);
    }
    close(r->ring_fd);
    r->ring_fd = -1;
    if (r->sqes != NULL) munmap(r->sqes, r->sqes_sz);
    if (r->sq_ptr != NULL) munmap(r->sq_ptr, r->sq_map_sz);
    if (!r->sqcq_shared && r->cq_ptr != NULL) munmap(r->cq_ptr, r->cq_map_sz);
    r->sqes = NULL;
    r->sq_ptr = NULL;
    r->cq_ptr = NULL;
  }
#endif
  /* 3) 释放 payload buffer / fd，关闭 pipe 写端（读端由 MoonBit 的 RawFd 拥有）。 */
  pthread_mutex_lock(&r->mtx);
  for (int i = 0; i < r->depth; i++) tf_uring_release_locked(r, i);
  pthread_mutex_unlock(&r->mtx);
  if (r->signal_fd >= 0) close(r->signal_fd);
  r->signal_fd = -1;
  /* notify_fd 的所有权已转移给 MoonBit 的 @raw_fd.RawFd，这里不再 close。 */
  r->notify_fd = -1;
  pthread_cond_destroy(&r->work_cv);
  pthread_mutex_destroy(&r->mtx);
  free(r->reqs);
  free(r->done_q);
  free(r->work_q);
  free(r);
}
