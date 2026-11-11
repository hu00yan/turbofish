// 非 native 后端的文件系统桩：真实文件 IO 只在 native/llvm 可用。
// 签名与 idxfs_native.mbt 中的 extern 声明一一对应。

///|
fn idxfs_file_mtime(_path : Bytes) -> Int64 {
  0L
}

///|
fn idxfs_file_size(_path : Bytes) -> Int {
  -1
}

///|
fn idxfs_read_file(
  _path : Bytes,
  _out : FixedArray[Byte],
  _cap : Int,
) -> Int {
  0
}

///|
fn idxfs_walk(_root : Bytes, _out : FixedArray[Byte], _cap : Int) -> Int {
  0
}

///|
fn idxfs_now_us() -> Int64 {
  0L
}
