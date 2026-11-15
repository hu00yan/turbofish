// unicode_word 简化分词器：
// - ASCII 字母/数字连成一个词（小写化）
// - CJK 汉字 / 日文假名 / 谚文逐字成词（中文搜索的最小正确语义）
// - 其余字符视为分隔符

///|
fn is_cjk(c : Int) -> Bool {
  (c >= 0x3400 && c <= 0x4DBF) ||
  (c >= 0x4E00 && c <= 0x9FFF) ||
  (c >= 0xF900 && c <= 0xFAFF) || // 简繁兼容
  (c >= 0x3040 && c <= 0x30FF) || // 平假名+片假名
  (c >= 0xAC00 && c <= 0xD7AF) // 谚文
}

///|
pub fn tokenize_into(text : String, sink : (String) -> Unit) -> Unit {
  let chars : Array[Char] = Array()
  let flush = () => {
    if chars.length() > 0 {
      let mut term = String::from_array(chars.exact_view()).to_lower()
      // SPNDDIR1 的 term_len 是 u8；超长 ASCII token 截到 255 字节，
      // 构建与查询走同一分词器，避免 dir 长度回绕（review P2-2）。
      if term.length() > 255 {
        term = term[:255].to_owned()
      }
      chars.clear()
      sink(term)
    }
  }
  for ch in text.iter() {
    let c = ch.to_int()
    if is_cjk(c) {
      flush()
      sink(ch.to_string().to_lower())
    } else if ch.is_ascii_alphabetic() || ch.is_ascii_digit() {
      chars.push(ch)
    } else {
      flush()
    }
  }
  flush()
}

///|
pub fn tokenize(text : String) -> Array[String] {
  let out : Array[String] = Array()
  tokenize_into(text, fn(t) { out.push(t) })
  out
}

///|
test "tokenize ascii and cjk" {
  inspect(
    tokenize("Hello, World! 你好世界 v2.0").join("|"),
    content="hello|world|你|好|世|界|v2|0",
  )
  inspect(tokenize("").length(), content="0")
  inspect(tokenize("单字").length(), content="2")
}

///|
test "tokenize caps oversized ascii token at 255 bytes" {
  let long = "a".repeat(300)
  let toks = tokenize(long)
  assert_eq(toks.length(), 1)
  assert_eq(toks[0].length(), 255)
}
