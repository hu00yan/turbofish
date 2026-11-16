// 非 native 后端没有子进程能力；这里提供同签名桩，使 `moon check --target js`
// 等仍然能编译整个包。

///|
fn main {
  println("turbofish supervise requires a native target")
}
