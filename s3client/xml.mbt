// ListObjectsV2 响应 XML 的最小解析器。
//
// 只做两件事：抽某个标签的全部内文（<Key>）、抽某个标签的首个内文
// （<IsTruncated> / <NextContinuationToken>）。不用正则，不引入 XML 依赖。

///|
fn find_from(s : String, pat : String, from : Int) -> Int? {
  if from >= s.length() {
    return None
  }
  match s[from:].find(pat) {
    Some(i) => Some(from + i)
    None => None
  }
}

///|
/// XML 文本反转义（只需覆盖 S3 key 可能出现的实体）
pub fn xml_unescape(s : String) -> String {
  if !s.contains("&") {
    return s
  }
  s.replace_all(old="&quot;", new="\"")
  .replace_all(old="&apos;", new="'")
  .replace_all(old="&lt;", new="<")
  .replace_all(old="&gt;", new=">")
  .replace_all(old="&amp;", new="&")
}

///|
/// 抽取所有 `<tag>...</tag>` 的内文（按文档顺序，已反转义）
pub fn xml_tag_values(xml : String, tag : String) -> Array[String] {
  let open = "<" + tag + ">"
  let close = "</" + tag + ">"
  let out : Array[String] = []
  let mut pos = 0
  while pos < xml.length() {
    let start = match find_from(xml, open, pos) {
      Some(i) => i + open.length()
      None => break
    }
    let end = match find_from(xml, close, start) {
      Some(j) => j
      None => break
    }
    out.push(xml_unescape(xml[start:end].to_owned()))
    pos = end + close.length()
  }
  out
}

///|
/// 抽取首个 `<tag>...</tag>` 的内文（不存在 → None）
pub fn xml_first_value(xml : String, tag : String) -> String? {
  let open = "<" + tag + ">"
  let close = "</" + tag + ">"
  let start = match xml.find(open) {
    Some(i) => i + open.length()
    None => return None
  }
  match find_from(xml, close, start) {
    Some(j) => Some(xml_unescape(xml[start:j].to_owned()))
    None => None
  }
}
