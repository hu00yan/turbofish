#include <stdint.h>
#include <unistd.h>

#if defined(__linux__)
#include <sys/random.h>
#include <time.h>

uint64_t turbofish_random_u64(void) {
  uint64_t x = 0;
  if (getrandom(&x, sizeof(x), 0) != (ssize_t)sizeof(x)) {
    x = ((uint64_t)getpid() << 32) ^ (uint64_t)time(NULL);
  }
  return x;
}
#else
#include <stdlib.h>

uint64_t turbofish_random_u64(void) {
  uint64_t x = 0;
  arc4random_buf(&x, sizeof(x));
  return x;
}
#endif

int turbofish_process_id(void) {
  return (int)getpid();
}
