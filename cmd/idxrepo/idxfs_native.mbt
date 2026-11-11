// 文件系统 FFI（native/llvm）。路径一律以 NUL 结尾 Bytes 传入；
// 输出缓冲用 FixedArray[Byte]，C 侧写裸指针。

///|
#borrow(path)
extern "C" fn idxfs_file_mtime(path : Bytes) -> Int64 = "idxfs_file_mtime"

///|
#borrow(path)
extern "C" fn idxfs_file_size(path : Bytes) -> Int = "idxfs_file_size"

///|
#borrow(path, out)
extern "C" fn idxfs_read_file(
  path : Bytes,
  out : FixedArray[Byte],
  cap : Int,
) -> Int = "idxfs_read_file"

///|
#borrow(root, out)
extern "C" fn idxfs_walk(
  root : Bytes,
  out : FixedArray[Byte],
  cap : Int,
) -> Int = "idxfs_walk"

///|
extern "C" fn idxfs_now_us() -> Int64 = "idxfs_now_us"
