// Demo schema 固定为 spec 中的六列（id/text/vector/category/ts/public）。
// schema.json 仍会写出，但本 MVP 的读写器按该固定 schema 实现。

///|
pub(all) struct Doc {
  id : UInt64
  text : String
  vector : Array[Float]
  category : String
  ts : Int64
  public : Bool
}

///|
pub const K1 : Double = 1.2

///|
pub const BM25_B : Double = 0.75

///|
pub const FORMAT_NAME : String = "seekpond/v1"
