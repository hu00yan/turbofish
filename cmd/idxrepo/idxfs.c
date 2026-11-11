// idxrepo 文件系统 stub（native）：目录树收集 + 文件读取。
// ABI 与 s3http.c 相同：MoonBit native 的 Bytes 传为指针（读端需自行保证
// NUL 结尾），FixedArray[Byte] 传为可写裸指针。

#include <dirent.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>

static const char *idxfs_skip_dirs[] = { "target", "node_modules", "_build" };

static int idxfs_skip_dir_name(const char *name) {
  if (name[0] == '.') return 1; // .git / .mooncakes / 隐藏目录
  for (size_t i = 0; i < sizeof(idxfs_skip_dirs) / sizeof(idxfs_skip_dirs[0]); i++) {
    if (strcmp(name, idxfs_skip_dirs[i]) == 0) return 1;
  }
  return 0;
}

// 递归收集 root 下全部普通文件的绝对路径，每行一个（'\n' 结尾）写进 out。
// out/cap 为 0 时只统计所需字节数（两段式调用：先探测，再分配写入）。
static void idxfs_walk_rec(const char *root, char *out, int cap, int *used) {
  DIR *d = opendir(root);
  if (!d) return;
  struct dirent *e;
  while ((e = readdir(d)) != NULL) {
    if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
    if (idxfs_skip_dir_name(e->d_name)) continue;
    char path[4096];
    if ((int)strlen(root) + (int)strlen(e->d_name) + 2 >= (int)sizeof(path)) continue;
    snprintf(path, sizeof(path), "%s/%s", root, e->d_name);
    struct stat st;
    if (stat(path, &st) != 0) continue; // stat：跟进 symlink（语料可用软链组装）
    if (S_ISDIR(st.st_mode)) {
      idxfs_walk_rec(path, out, cap, used);
    } else if (S_ISREG(st.st_mode)) {
      size_t len = strlen(path);
      if (out && *used + (int)len + 1 <= cap) {
        memcpy(out + *used, path, len);
        out[*used + len] = '\n';
      }
      *used += (int)len + 1;
    }
  }
  closedir(d);
}

int idxfs_walk(const char *root, uint8_t *out, int cap) {
  int used = 0;
  idxfs_walk_rec(root, (char *)out, cap, &used);
  return used;
}

long long idxfs_file_mtime(const char *path) {
  struct stat st;
  if (stat(path, &st) != 0) return 0;
  return (long long)st.st_mtime;
}

int idxfs_file_size(const char *path) {
  struct stat st;
  if (stat(path, &st) != 0) return -1;
  if (!S_ISREG(st.st_mode)) return -1;
  if (st.st_size > 1073741823) return -1; // >1GB 视为异常
  return (int)st.st_size;
}

int idxfs_read_file(const char *path, uint8_t *out, int cap) {
  FILE *f = fopen(path, "rb");
  if (!f) return -1;
  int n = (int)fread(out, 1, (size_t)cap, f);
  fclose(f);
  return n;
}

// 单调时钟 µs（@bench.monotonic_clock 在 native 可执行里不工作，这里自带一个）。
long long idxfs_now_us(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (long long)ts.tv_sec * 1000000LL + ts.tv_nsec / 1000;
}
