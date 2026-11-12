// 进程级熵：writer id fallback 需要跨进程可区分。仅靠 @env.now() + 进程内
// 计数器会在同毫秒冷启动时确定性碰撞；PID + 真随机 64-bit 解决该问题。

///|
extern "C" fn turbofish_process_id() -> Int = "turbofish_process_id"

///|
extern "C" fn turbofish_random_u64() -> UInt64 = "turbofish_random_u64"

///|
pub fn process_id() -> Int {
  turbofish_process_id()
}

///|
pub fn random_u64() -> UInt64 {
  turbofish_random_u64()
}
