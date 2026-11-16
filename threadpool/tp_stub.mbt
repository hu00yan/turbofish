// 非 native 后端（js/wasm/wasm-gc）没有 pthread worker pool；这里提供同签名
// 桩，使 moon check --target all 可编译。桩没有工作线程，submit 恒返回 -2
// （等价于 shutdown 语义），计数类接口返回 0/-1。

///|
/// 桩线程池：无工作线程、无资源，所有操作都是安全空操作。
pub enum TfThreadPool {
  Stub
}

///|
/// 桩：返回空线程池。参数无实际效果。
pub fn tf_tp_create(threads : Int, queue_cap : Int) -> TfThreadPool {
  let _ = threads
  let _ = queue_cap
  TfThreadPool::Stub
}

///|
/// 桩：无工作线程可执行 job，恒返回 -2（shutdown 语义）。
pub fn tf_tp_submit_nop(pool : TfThreadPool, delay_us : Int) -> Int {
  let _ = pool
  let _ = delay_us
  -2
}

///|
/// 桩：没有完成通知 pipe，返回 -1。
pub fn tf_tp_completion_fd(pool : TfThreadPool) -> Int {
  let _ = pool
  -1
}

///|
/// 桩：没有完成事件，恒返回 0。
pub fn tf_tp_drain(pool : TfThreadPool) -> Int {
  let _ = pool
  0
}

///|
/// 桩：不阻塞，恒返回 0。
pub fn tf_tp_wait_drain(pool : TfThreadPool, timeout_ms : Int) -> Int {
  let _ = pool
  let _ = timeout_ms
  0
}

///|
/// 桩：恒返回 0。
pub fn tf_tp_pending(pool : TfThreadPool) -> Int {
  let _ = pool
  0
}

///|
/// 桩：空操作。
pub fn tf_tp_shutdown(pool : TfThreadPool) -> Unit {
  let _ = pool
}

///|
/// 桩：空操作，可重复调用。
pub fn tf_tp_destroy(pool : TfThreadPool) -> Unit {
  let _ = pool
}
