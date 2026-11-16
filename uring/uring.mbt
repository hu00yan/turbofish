// uring：极致文件 IO 完成引擎的 MoonBit 侧。
//
// 后端由 uring/uring.c 决定（对上层透明）：
// - Linux：内核 io_uring（raw syscall，不需要系统装 liburing）
// - macOS / 受限 Linux：pipe 唤醒 + 4 个 C pthread worker（真正的 pread/pwrite/fsync）
//
// 完成通知统一走一个 fd：C 侧每完成一个请求就让它可读（io_uring 用注册的
// eventfd，POSIX 路径用 pipe）。MoonBit 侧用 `@raw_fd.RawFd` 把它挂到 async
// 事件循环上，因此等待是真正的挂起（不是 sleep 轮询）。
//
// ===== 单等待者不变式 =====
// 完成 fd 是一条共享通道，多个协程同时 read 会互相偷字节导致漏唤醒。
// 因此引擎内所有“提交 + 等完成”的临界区都由 `gate : @async.Mutex` 串行化：
// 同一时刻只有一个协程在读完成 fd。批量接口在一次临界区里把所有请求灌进
// ring（并发度由 ring 深度提供，最多 depth/2 个请求同时在飞），然后一次性
// 收割所有 CQE——这就是“并发提交、一次收割”。
//
// ===== 内存安全 =====
// 数据缓冲全部在 C 侧 malloc，完成时由 `tf_uring_copy_result` 拷回 MoonBit
// FixedArray[Byte] 并释放；C worker 线程从不触碰 MoonBit 对象。

///|
/// 不透明句柄（C 侧句柄表下标）。只在 C 侧有意义，公开仅为满足类型可见性。
#external
pub type TfUringHandle

///|
extern "C" fn tf_uring_create_raw(depth : Int) -> TfUringHandle = "tf_uring_create"

///|
extern "C" fn tf_uring_is_null_raw(handle : TfUringHandle) -> Int = "tf_uring_is_null"

///|
extern "C" fn tf_uring_backend_kind_raw(handle : TfUringHandle) -> Int = "tf_uring_backend_kind"

///|
extern "C" fn tf_uring_notify_fd_raw(handle : TfUringHandle) -> Int = "tf_uring_notify_fd"

///|
#borrow(path)
extern "C" fn tf_uring_file_size_raw(path : Bytes, path_len : Int) -> Int64 = "tf_uring_file_size"

///|
#borrow(path)
extern "C" fn tf_uring_submit_read_raw(
  handle : TfUringHandle,
  path : Bytes,
  path_len : Int,
  offset : Int64,
  len : Int,
) -> Int = "tf_uring_submit_read"

///|
#borrow(path, data)
extern "C" fn tf_uring_submit_write_raw(
  handle : TfUringHandle,
  path : Bytes,
  path_len : Int,
  offset : Int64,
  data : Bytes,
  len : Int,
  sync : Int,
) -> Int = "tf_uring_submit_write"

///|
extern "C" fn tf_uring_harvest_raw(handle : TfUringHandle) -> Int = "tf_uring_harvest"

///|
extern "C" fn tf_uring_result_len_raw(handle : TfUringHandle, slot : Int) -> Int = "tf_uring_result_len"

///|
extern "C" fn tf_uring_result_errno_raw(handle : TfUringHandle, slot : Int) -> Int = "tf_uring_result_errno"

///|
#borrow(dst)
extern "C" fn tf_uring_copy_result_raw(
  handle : TfUringHandle,
  slot : Int,
  dst : FixedArray[Byte],
  cap : Int,
) -> Int = "tf_uring_copy_result"

///|
extern "C" fn tf_uring_discard_raw(handle : TfUringHandle, slot : Int) -> Unit = "tf_uring_discard"

///|
#borrow(from, to)
extern "C" fn tf_uring_rename_raw(
  from : Bytes,
  from_len : Int,
  to : Bytes,
  to_len : Int,
) -> Int = "tf_uring_rename"

///|
#borrow(path)
extern "C" fn tf_uring_unlink_raw(path : Bytes, path_len : Int) -> Int = "tf_uring_unlink"

///|
extern "C" fn tf_uring_close_raw(handle : TfUringHandle) -> Unit = "tf_uring_close"

///|
extern "C" fn tf_uring_next_tmp_id_raw() -> Int = "tf_uring_next_tmp_id"

///|
/// 一次文件 IO 完成引擎。
///
/// 构造后即可并发提交读/写请求；`close()` 之外的接口在 close 之后调用是
/// 未定义行为（本模块统一 abort，避免静默错乱）。
pub struct UringEngine {
  handle : TfUringHandle
  mut notify : @raw_fd.RawFd?
  backend : String
  depth : Int
  gate : @async.Mutex
  mut closed : Bool
}

///|
fn utf8_bytes(s : String) -> Bytes {
  let b = Buffer()
  b.write_string_utf8(s)
  b.to_bytes()
}

///|
fn empty_bytes() -> Bytes {
  Bytes::make(0, b'\x00')
}

///|
/// 创建引擎，`queue_depth` 是 ring 深度（同时在飞的请求上限）。
///
/// Linux 上优先用内核 io_uring；内核禁用（ENOSYS/EPERM）时自动退化到
/// POSIX pthread worker 路径，调用方无需关心。
pub async fn UringEngine::new(queue_depth? : Int = 64) -> UringEngine {
  let depth = if queue_depth < 2 {
    2
  } else if queue_depth > 4096 {
    4096
  } else {
    queue_depth
  }
  let handle = tf_uring_create_raw(depth)
  if tf_uring_is_null_raw(handle) != 0 {
    abort("UringEngine::new: cannot create completion ring (fd/thread exhaustion)")
  }
  let fd = tf_uring_notify_fd_raw(handle)
  if fd < 0 {
    tf_uring_close_raw(handle)
    abort("UringEngine::new: completion ring has no notify fd")
  }
  let backend = match tf_uring_backend_kind_raw(handle) {
    0 => "linux_io_uring"
    _ => "posix_pread_pool"
  }
  // RawFd 接管 fd 所有权（async 构造器，隐式 await）。
  let notify = @raw_fd.RawFd::RawFd(fd)
  {
    handle,
    notify: Some(notify),
    backend,
    depth,
    gate: @async.Mutex::Mutex(),
    closed: false,
  }
}

///|
/// 实际生效的后端：`"linux_io_uring"` 或 `"posix_pread_pool"`。
pub fn UringEngine::backend_kind(self : UringEngine) -> String {
  self.backend
}

///|
/// ring 深度（同时在飞请求上限）。
pub fn UringEngine::queue_depth(self : UringEngine) -> Int {
  self.depth
}

///|
/// 释放 ring 与全部资源。幂等：重复调用是空操作。
///
/// 顺序有讲究：先让 C 侧排空 worker 队列并关闭完成通知的写端，再关闭
/// MoonBit 持有的读端 RawFd（反向顺序会让 worker 的 write 撞上 EPIPE）。
pub fn UringEngine::close(self : UringEngine) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  tf_uring_close_raw(self.handle)
  match self.notify {
    Some(fd) => fd.close()
    None => ()
  }
  self.notify = None
}

///|
fn UringEngine::ensure_open(self : UringEngine) -> Unit {
  if self.closed {
    abort("UringEngine: engine already closed")
  }
}

///|
/// 当前批量提交的分片大小：不超过 ring 深度的一半，保证提交不会 EBUSY，
/// 同时留出足够并发度。
fn UringEngine::chunk_size(self : UringEngine) -> Int {
  let half = self.depth / 2
  if half < 1 {
    1
  } else {
    half
  }
}

///|
/// 等待完成通知（挂起当前协程直到有 CQE 落地）。调用方必须持有 `gate`。
async fn UringEngine::wait_signal(self : UringEngine) -> Unit {
  match self.notify {
    Some(fd) => {
      let buf : FixedArray[Byte] = FixedArray::make(64, b'\x00')
      let _ = fd.read(buf)
    }
    None => abort("UringEngine: wait on closed engine")
  }
}

///|
/// 收割直到 `slots` 全部完成。
///
/// `slots[i]` 是 C 侧槽位，`targets[i]` 是它在结果数组里的下标；
/// 返回每个 slot 的实际字节数（-1 表示该请求失败）。
/// `want_data=true` 时读请求的数据被拷进 `outs[target]`；写请求只保留长度。
async fn UringEngine::collect_slots(
  self : UringEngine,
  slots : Array[Int],
  targets : Array[Int],
  outs : Array[Bytes?],
  want_data : Bool,
) -> Array[Int] {
  let n = slots.length()
  // 结果数组长度取 outs 长度与 target 最大下标+1 的较大者：
  // 批量接口的 target 是原始 reqs 里的下标，可能超出本次分片的长度。
  let mut res_len = outs.length()
  for t in targets {
    if t + 1 > res_len {
      res_len = t + 1
    }
  }
  let lens : Array[Int] = Array::make(res_len, -1)
  let mut pending = n
  while pending > 0 {
    // 先把已完成的 CQE 全部取空（可信来源是完成队列，不是通知字节）
    while true {
      let slot = tf_uring_harvest_raw(self.handle)
      if slot < 0 {
        break
      }
      let mut k = -1
      for i in 0..<n {
        if slots[i] == slot {
          k = i
          break
        }
      }
      if k < 0 {
        // 不属于本次提交（不应发生）：立刻释放，避免 C buffer 泄漏
        tf_uring_discard_raw(self.handle, slot)
        continue
      }
      let idx = targets[k]
      let rl = tf_uring_result_len_raw(self.handle, slot)
      if want_data && rl >= 0 {
        let arr : FixedArray[Byte] = FixedArray::make(rl, b'\x00')
        let copied = tf_uring_copy_result_raw(self.handle, slot, arr, rl)
        lens[idx] = copied
        outs[idx] = Some(Bytes::from_array(arr.exact_view()))
      } else {
        lens[idx] = rl
        tf_uring_discard_raw(self.handle, slot)
      }
      pending -= 1
    }
    if pending > 0 {
      self.wait_signal()
    }
  }
  lens
}

///|
/// 提交读请求（调用方持有 gate），返回槽位或负 errno。
fn UringEngine::submit_read(self : UringEngine, path : Bytes, offset : Int, len : Int) -> Int {
  tf_uring_submit_read_raw(self.handle, path, path.length(), offset.to_int64(), len)
}

///|
/// 提交写请求（调用方持有 gate），返回槽位或负 errno。
fn UringEngine::submit_write(
  self : UringEngine,
  path : Bytes,
  offset : Int,
  data : Bytes,
  sync : Bool,
) -> Int {
  tf_uring_submit_write_raw(
    self.handle,
    path,
    path.length(),
    offset.to_int64(),
    data,
    data.length(),
    if sync {
      1
    } else {
      0
    },
  )
}

///|
/// 整文件读。文件不存在 / 打不开返回 `None`。
pub async fn UringEngine::read_file(self : UringEngine, path : String) -> Bytes? {
  self.ensure_open()
  let pb = utf8_bytes(path)
  let size = tf_uring_file_size_raw(pb, pb.length())
  if size < 0 {
    return None
  }
  if size == 0 {
    return Some(empty_bytes())
  }
  self.read_range(path, 0, size.to_int())
}

///|
/// 读 `[offset, offset+len)`。越界部分不会伪造数据：返回实际读到的字节
/// （可能短于 `len`，完全越界时是空 Bytes）。文件不存在返回 `None`。
pub async fn UringEngine::read_range(
  self : UringEngine,
  path : String,
  offset : Int,
  len : Int,
) -> Bytes? {
  self.ensure_open()
  if offset < 0 || len < 0 {
    return None
  }
  let pb = utf8_bytes(path)
  self.gate.acquire()
  let slot = self.submit_read(pb, offset, len)
  if slot < 0 {
    self.gate.release()
    return None
  }
  let slots : Array[Int] = [slot]
  let targets : Array[Int] = [0]
  let outs : Array[Bytes?] = Array::make(1, None)
  let lens = self.collect_slots(slots, targets, outs, true)
  self.gate.release()
  if lens[0] < 0 {
    return None
  }
  outs[0]
}

///|
/// 批量范围读：`reqs` 里每个 `(path, offset, len)` 都会在同一轮里提交到 ring，
/// 全部在飞之后一次性收割所有 CQE（真正的 IO 并发，而不是串行等待）。
/// 返回与 `reqs` 同长同序；单个请求失败（如文件不存在）只影响它自己的位置。
pub async fn UringEngine::read_ranges_batch(
  self : UringEngine,
  reqs : Array[(String, Int, Int)],
) -> Array[Bytes?] {
  self.ensure_open()
  let n = reqs.length()
  let outs : Array[Bytes?] = Array::make(n, None)
  if n == 0 {
    return outs
  }
  let chunk = self.chunk_size()
  let mut base = 0
  while base < n {
    let stop = if base + chunk > n {
      n
    } else {
      base + chunk
    }
    let paths : Array[Bytes] = []
    for i in base..<stop {
      let (path, _, _) = reqs[i]
      paths.push(utf8_bytes(path))
    }
    let slots : Array[Int] = []
    let targets : Array[Int] = []
    self.gate.acquire()
    for i in base..<stop {
      let (_, offset, len) = reqs[i]
      let slot = self.submit_read(paths[i - base], offset, len)
      if slot >= 0 {
        slots.push(slot)
        targets.push(i)
      }
    }
    if slots.length() > 0 {
      let _ = self.collect_slots(slots, targets, outs, true)
    }
    self.gate.release()
    base = stop
  }
  outs
}

///|
/// 原子写整个文件：先写同目录下的临时文件（可选 fsync），再 `rename(2)` 覆盖
/// 目标路径。同目录 rename 在 POSIX 上是原子的，读者永远看到旧内容或新内容。
///
/// 失败时清理临时文件并 abort（签名是 `-> Unit`，不抛错；调用方若需要错误
/// 语义请先用 `read_file`/`file_size` 之类的探测接口确认前提条件）。
pub async fn UringEngine::write_file_atomic(
  self : UringEngine,
  path : String,
  data : Bytes,
  sync? : Bool = false,
) -> Unit {
  self.ensure_open()
  let tmp = "\{path}.tftmp.\{tf_uring_next_tmp_id_raw()}"
  let tb = utf8_bytes(tmp)
  self.gate.acquire()
  let slot = self.submit_write(tb, 0, data, sync)
  if slot < 0 {
    self.gate.release()
    abort("UringEngine::write_file_atomic: submit failed for \{tmp} (errno \{-slot})")
  }
  let slots : Array[Int] = [slot]
  let targets : Array[Int] = [0]
  let outs : Array[Bytes?] = Array::make(0, None)
  let lens = self.collect_slots(slots, targets, outs, false)
  self.gate.release()
  if lens[0] < 0 {
    let err = tf_uring_result_errno_raw(self.handle, slot)
    let _ = tf_uring_unlink_raw(tb, tb.length())
    if err != 0 {
      abort(
        "UringEngine::write_file_atomic: write failed for \{tmp} (errno \{err})",
      )
    }
    abort("UringEngine::write_file_atomic: write failed for \{tmp}")
  }
  let pb = utf8_bytes(path)
  let rc = tf_uring_rename_raw(tb, tb.length(), pb, pb.length())
  if rc != 0 {
    let _ = tf_uring_unlink_raw(tb, tb.length())
    abort("UringEngine::write_file_atomic: rename failed for \{path} (errno \{-rc})")
  }
}

///|
/// 文件大小（字节）。打不开返回 `None`。
pub fn UringEngine::file_size(self : UringEngine, path : String) -> Int64? {
  self.ensure_open()
  let pb = utf8_bytes(path)
  let size = tf_uring_file_size_raw(pb, pb.length())
  if size < 0 {
    None
  } else {
    Some(size)
  }
}

///|
/// 删除文件（幂等：不存在也算成功）。主要给测试/清理路径用。
pub fn UringEngine::remove_file(self : UringEngine, path : String) -> Unit {
  self.ensure_open()
  let pb = utf8_bytes(path)
  let _ = tf_uring_unlink_raw(pb, pb.length())
}
