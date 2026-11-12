// POSIX 文件 FFI 绑定（仅 native backend）。
//
// ABI 映射（docs.moonbitlang.com FFI 文档 + 实测）：
// - Int -> int32_t, Int64 -> int64_t, UInt -> uint32_t, UInt64 -> uint64_t
// - Bytes / FixedArray[Byte] -> uint8_t*（#borrow 参数免去 owned 约定的 decref，
//   因此可以直接绑定 libc 符号，无需写 C stub）
//
// 设计取舍（probe 结论，见 probe_native.mbt）：
// - stdio FILE* 是 64 位指针，Int 放不下；#external type 可以承载（void*），
//   但 MoonBit 侧无法判 NULL（fopen 失败返回 NULL 后续调用直接段错误），
//   除非引入 native-stub C 包装。POSIX fd 本身就是 int，失败返回 -1 可判，
//   故实现走 open/read/write/lseek/close/unlink/rename/mkdir（全部非 variadic）。
// - 写路径用 creat(path, mode)（O_WRONLY|O_CREAT|O_TRUNC 语义且非 variadic）；
//   读路径 open(path, O_RDONLY=0)；O_* 常量跨平台差异大，只依赖 O_RDONLY=0。

///|
/// UTF-8 + 显式 NUL 结尾，用作 C 字符串
pub fn cstr(s : String) -> Bytes {
  let b = Buffer()
  b.write_string_utf8(s)
  b.write_byte(b'\x00')
  b.to_bytes()
}

///|
#borrow(path)
extern "C" fn c_open_ro(path : Bytes, flags : Int) -> Int = "open"

///|
#borrow(path)
extern "C" fn c_creat(path : Bytes, mode : UInt) -> Int = "creat"

///|
#borrow(buf)
extern "C" fn c_read(fd : Int, buf : FixedArray[Byte], count : UInt64) -> Int64 = "read"

///|
#borrow(buf)
extern "C" fn c_write(
  fd : Int,
  buf : FixedArray[Byte],
  count : UInt64,
) -> Int64 = "write"

///|
extern "C" fn c_lseek(fd : Int, offset : Int64, whence : Int) -> Int64 = "lseek"

///|
extern "C" fn c_close(fd : Int) -> Int = "close"

///|
#borrow(path)
extern "C" fn c_unlink(path : Bytes) -> Int = "unlink"

///|
#borrow(old, new)
extern "C" fn c_rename(old : Bytes, new : Bytes) -> Int = "rename"

///|
#borrow(path)
extern "C" fn c_mkdir(path : Bytes, mode : UInt) -> Int = "mkdir"

///|
/// 进程号（测试用：让临时根目录跨 moon test 运行唯一——next_id 是进程内计数器，
/// 每次运行都从 0 重来）
extern "C" fn c_getpid() -> Int = "getpid"

///|
pub fn test_pid() -> Int {
  c_getpid()
}
