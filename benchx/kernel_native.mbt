// benchx/kernel_native.mbt —— 仅 native/llvm 后端编译。
// extern "C" 语法参照 ~/.moon/lib/core/bench/monotonic_clock_native.mbt：
//   pub extern "C" fn name(args) -> T = "c_symbol"
// C 侧指针用 #external 不透明类型进出（对齐 Timestamp 的用法）。

///|
#external
type CBuf

///|
extern "C" fn benchx_add2(x : Int, y : Int) -> Int = "benchx_add2"

///|
extern "C" fn benchx_buf_new(len : Int) -> CBuf = "benchx_buf_new"

///|
extern "C" fn benchx_buf_free(p : CBuf) -> Unit = "benchx_buf_free"

///|
extern "C" fn benchx_buf_len(p : CBuf) -> Int = "benchx_buf_len"

///|
extern "C" fn benchx_buf_set(p : CBuf, i : Int, v : Float) -> Unit = "benchx_buf_set"

///|
extern "C" fn benchx_buf_get(p : CBuf, i : Int) -> Float = "benchx_buf_get"

///|
extern "C" fn benchx_echo_f32(x : Float) -> Float = "benchx_echo_f32"

///|
extern "C" fn benchx_echo_f64(x : Double) -> Double = "benchx_echo_f64"

///|
extern "C" fn benchx_probe_mix(a : Int, f : Float, b : Int) -> Int = "benchx_probe_mix"

///|
extern "C" fn benchx_dot_f32(
  a : CBuf,
  ai : Int,
  b : CBuf,
  bi : Int,
  dim : Int,
) -> Double = "benchx_dot_f32"

///|
extern "C" fn benchx_dot_f32_8acc(
  a : CBuf,
  ai : Int,
  b : CBuf,
  bi : Int,
  dim : Int,
) -> Double = "benchx_dot_f32_8acc"

///|
extern "C" fn benchx_dot_f32_facc(
  a : CBuf,
  ai : Int,
  b : CBuf,
  bi : Int,
  dim : Int,
) -> Double = "benchx_dot_f32_facc"

///|
/// C 内核容器：行主序 float 矩阵（数据已拷入 C 侧 malloc 内存）。
struct CMatrix {
  ptr : CBuf
  nrows : Int
  dim : Int
}

///|
pub fn c_kernel_available() -> Bool {
  true
}

///|
/// FFI 探针（native）：直接调用 C 符号 benchx_add2。
pub fn probe_add2(x : Int, y : Int) -> Int {
  benchx_add2(x, y)
}

///|
pub fn probe_echo_f32(x : Float) -> Float {
  benchx_echo_f32(x)
}

///|
pub fn probe_echo_f64(x : Double) -> Double {
  benchx_echo_f64(x)
}

///|
pub fn probe_mix(a : Int, f : Float, b : Int) -> Int {
  benchx_probe_mix(a, f, b)
}

///|
pub fn probe_buf_roundtrip(v : Float) -> Float {
  let p = benchx_buf_new(16)
  benchx_buf_set(p, 5, v)
  let got = benchx_buf_get(p, 5)
  benchx_buf_free(p)
  got
}

///|
/// 把行主序数据搬进 C 侧缓冲（一次性 setup，不计入计时）。
pub fn cmat_new(rows : Array[Float], nrows : Int, dim : Int) -> CMatrix {
  let p = benchx_buf_new(nrows * dim)
  let n = nrows * dim
  for i in 0..<n {
    benchx_buf_set(p, i, rows[i])
  }
  { ptr: p, nrows, dim }
}

///|
pub fn cmat_free(m : CMatrix) -> Unit {
  benchx_buf_free(m.ptr)
}

///|
/// C 标量内核：dot(A行i, B行j)。
pub fn cmat_dot(ma : CMatrix, i : Int, mb : CMatrix, j : Int) -> Double {
  benchx_dot_f32(ma.ptr, i * ma.dim, mb.ptr, j * mb.dim, ma.dim)
}

///|
/// C 8 路展开内核。
pub fn cmat_dot_8acc(ma : CMatrix, i : Int, mb : CMatrix, j : Int) -> Double {
  benchx_dot_f32_8acc(ma.ptr, i * ma.dim, mb.ptr, j * mb.dim, ma.dim)
}

///|
/// C float 累加内核。
pub fn cmat_dot_facc(ma : CMatrix, i : Int, mb : CMatrix, j : Int) -> Double {
  benchx_dot_f32_facc(ma.ptr, i * ma.dim, mb.ptr, j * mb.dim, ma.dim)
}
