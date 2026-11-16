// threadpool 的 native/llvm 后端：pthread worker pool（tp.c）的 FFI 薄封装。
// 句柄由 C 侧句柄表管理；destroy 后句柄失效，重复 destroy / destroy 后
// submit 均为明确定义的安全操作（submit 返回 -2）。

///|
/// 不透明句柄（C 侧句柄表的 slot index）。仅在 C 侧有意义，
/// 公开仅为满足 pub 接口的类型可见性要求，外部不要依赖其表示。
#external
pub type TfTpHandle

///|
extern "C" fn tf_tp_create_raw(
  threads : Int,
  queue_cap : Int,
) -> TfTpHandle = "tf_tp_create"

///|
extern "C" fn tf_tp_is_null_raw(handle : TfTpHandle) -> Int = "tf_tp_is_null"

///|
extern "C" fn tf_tp_submit_nop_raw(
  pool : TfTpHandle,
  delay_us : Int,
) -> Int = "tf_tp_submit_nop"

///|
extern "C" fn tf_tp_completion_fd_raw(pool : TfTpHandle) -> Int = "tf_tp_completion_fd"

///|
extern "C" fn tf_tp_drain_raw(pool : TfTpHandle) -> Int = "tf_tp_drain"

///|
extern "C" fn tf_tp_wait_drain_raw(
  pool : TfTpHandle,
  timeout_ms : Int,
) -> Int = "tf_tp_wait_drain"

///|
extern "C" fn tf_tp_pending_raw(pool : TfTpHandle) -> Int = "tf_tp_pending"

///|
extern "C" fn tf_tp_shutdown_raw(pool : TfTpHandle) -> Unit = "tf_tp_shutdown"

///|
extern "C" fn tf_tp_destroy_raw(pool : TfTpHandle) -> Unit = "tf_tp_destroy"

///|
/// pthread worker pool。内部是 C 侧句柄；worker 线程只执行 C job，
/// 不持有任何 MoonBit 对象。构造器私有，外部只能通过本模块函数操作。
pub enum TfThreadPool {
  Pool(TfTpHandle)
}

///|
/// 创建固定 `threads` 个 worker 的线程池，队列容量 `queue_cap`。
/// 两者都必须 > 0；分配/线程创建失败时 panic（OOM 无可恢复语义）。
pub fn tf_tp_create(threads : Int, queue_cap : Int) -> TfThreadPool {
  let handle = tf_tp_create_raw(threads, queue_cap)
  if tf_tp_is_null_raw(handle) != 0 {
    abort("tf_tp_create: invalid arguments or resource exhaustion")
  }
  TfThreadPool::Pool(handle)
}

///|
/// 提交一个 nop job（`delay_us` > 0 时在 worker 内延迟相应微秒）。
/// 返回 0 成功；-1 队列满（不阻塞调用方）；-2 已 shutdown/已 destroy。
pub fn tf_tp_submit_nop(pool : TfThreadPool, delay_us : Int) -> Int {
  let TfThreadPool::Pool(handle) = pool
  tf_tp_submit_nop_raw(handle, delay_us)
}

///|
/// 完成通知 pipe 的读端 fd。每完成 1 个 job 会写入 1 字节唤醒信号，
/// 可用于 poll/keccak 事件循环；失败时返回 -1。
pub fn tf_tp_completion_fd(pool : TfThreadPool) -> Int {
  let TfThreadPool::Pool(handle) = pool
  tf_tp_completion_fd_raw(handle)
}

///|
/// 返回自上次 drain 之后完成的 job 数，并清空唤醒信号字节。
pub fn tf_tp_drain(pool : TfThreadPool) -> Int {
  let TfThreadPool::Pool(handle) = pool
  tf_tp_drain_raw(handle)
}

///|
/// 最多等待 `timeout_ms` 毫秒（poll 在 completion fd 上，非 sleep 轮询）
/// 后执行一次 drain，返回自上次 drain 之后完成的 job 数。
/// `timeout_ms` <= 0 时等价于 `tf_tp_drain`。
pub fn tf_tp_wait_drain(pool : TfThreadPool, timeout_ms : Int) -> Int {
  let TfThreadPool::Pool(handle) = pool
  tf_tp_wait_drain_raw(handle, timeout_ms)
}

///|
/// 已接受但尚未完成的 job 数（排队中 + 执行中）。
pub fn tf_tp_pending(pool : TfThreadPool) -> Int {
  let TfThreadPool::Pool(handle) = pool
  tf_tp_pending_raw(handle)
}

///|
/// 优雅 shutdown：拒绝新 job（submit 返回 -2），worker 处理完队列中
/// 已接受的 job 后退出。可重复调用。
pub fn tf_tp_shutdown(pool : TfThreadPool) -> Unit {
  let TfThreadPool::Pool(handle) = pool
  tf_tp_shutdown_raw(handle)
}

///|
/// shutdown 并 join 全部 worker，释放资源。可重复调用（幂等）；
/// destroy 后 submit 返回 -2。
pub fn tf_tp_destroy(pool : TfThreadPool) -> Unit {
  let TfThreadPool::Pool(handle) = pool
  tf_tp_destroy_raw(handle)
}
