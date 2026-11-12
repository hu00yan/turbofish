// benchx/kernel_stub.mbt —— 非 native 后端（wasm-gc/wasm/js）的占位实现。
// 与 kernel_native.mbt 保持同签名；C 内核不可用，数值行为退化为 0，
// bench 输出中 C 内核行会标注 N/A（c_kernel_available() == false）。

///|
struct CMatrix {
  dummy : Int
}

///|
pub fn c_kernel_available() -> Bool {
  false
}

///|
pub fn probe_add2(x : Int, y : Int) -> Int {
  x + y
}

///|
pub fn probe_echo_f32(x : Float) -> Float {
  x + 1.0
}

///|
pub fn probe_echo_f64(x : Double) -> Double {
  x + 1.0
}

///|
pub fn probe_mix(a : Int, f : Float, b : Int) -> Int {
  a + b + (f + 0.5).to_int()
}

///|
pub fn probe_buf_roundtrip(v : Float) -> Float {
  v
}

///|
pub fn cmat_new(rows : Array[Float], nrows : Int, dim : Int) -> CMatrix {
  ignore(rows)
  { dummy: nrows * dim }
}

///|
pub fn cmat_free(m : CMatrix) -> Unit {
  let _ = m.dummy
}

///|
pub fn cmat_dot(ma : CMatrix, i : Int, mb : CMatrix, j : Int) -> Double {
  ignore(ma)
  ignore(mb)
  ignore(i)
  ignore(j)
  0.0
}

///|
pub fn cmat_dot_8acc(ma : CMatrix, i : Int, mb : CMatrix, j : Int) -> Double {
  ignore(ma)
  ignore(mb)
  ignore(i)
  ignore(j)
  0.0
}

///|
pub fn cmat_dot_facc(ma : CMatrix, i : Int, mb : CMatrix, j : Int) -> Double {
  ignore(ma)
  ignore(mb)
  ignore(i)
  ignore(j)
  0.0
}
