///|
/// 非 native 后端没有进程 ID / getrandom；返回 0 仅保证编译。生产多写者请
/// 显式设置 `TURBOFISH_WRITER_ID`。
pub fn process_id() -> Int {
  0
}

///|
pub fn random_u64() -> UInt64 {
  0UL
}
