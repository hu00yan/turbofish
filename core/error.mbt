// seekpond/v1 统一错误类型。所有解码 / 读取路径失败都以 raise SpndError 表达，
// 编码路径（写入）不可失败。

///|
pub(all) suberror SpndError {
  BadMagic(String)
  Truncated(String)
  Corrupt(String)
  NotFound(String)
  CommitConflict(String)
} derive(Debug, Eq)
