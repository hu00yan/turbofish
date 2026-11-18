// specguard：存储规格的静态断言（W8 防回潮）。
//
// 这里只做**只读**检查：读源码文本、比对白名单、违规即 raise。不产生任何
// 运行时依赖，也没有任何线上路径会调用它（只在 wbtest 与手工跑 gate 时执行）。
//
// 四条断言（每条都在 `run()` 里）：
//   1. format|build|query|cmd 下 .mbt 不得把整型 id 经 `Json::number(...to_double())`
//      序列化。历史上已有 12 处（id 精度欠债，正在被另一路修复）以
//      `(路径#JSON key) → 允许条数` 的基线放行；基线只做「不得超过」，
//      所以修掉它们只会让计数下降，不会让断言红。
//   2. format/slab.mbt 的 magic 常量必须是白名单值（"SLAB" / "SLIX"，
//      以及 v2 规格预留的 "SLB1" / "SLB2"）；常量名缺失或值越界都失败。
//   3. 全仓 moon.pkg 不得新增 `native-stub` 之外还新增 `link:` / `*-link-flags`
//      段；`native-stub` 只放行 W8 基线里已有的 5 个 C 桩（s3http 的 libcurl
//      `link:` 段回归即红）。
//   4. cmd 下源码不得硬编码 macOS 包管理路径（/opt/homebrew/、/usr/local/opt/），
//      这类路径已真实导致 Linux 构建失败。

// ---------------------------------------------------------------------------
// 断言 1：整型 id 不得走 double 序列化
// ---------------------------------------------------------------------------

///|
/// 需要防回潮的整型 id 字段名（小写，按子串匹配源码行）。
let id_field_tokens : Array[String] = [
  "min_id", "max_id", "doc_id", "docid", "deleted", "int64",
]

///|
/// 已知的 id-double 历史点：`(路径#JSON key) → 允许出现的行数`。
///
/// 这些是「id 精度」缺陷的现存位置（format/manifest.mbt 等），由另一路
/// 改成字符串/二进制后自然归零。基线**只**用于放行历史点：任何新路径、
/// 或同 key 行数变多，都算违规。
let id_double_baseline : Array[(String, Int32)] = [
  ("format/manifest.mbt#min_id", 1),
  ("format/manifest.mbt#max_id", 1),
  ("build/segment.mbt#min_id", 1),
  ("build/segment.mbt#max_id", 1),
  ("build/slab.mbt#min_id", 1),
  ("build/slab.mbt#max_id", 1),
  ("query/slab_wbtest.mbt#min_id", 1),
  ("query/slab_wbtest.mbt#max_id", 1),
  ("query/query_wbtest.mbt#min_id", 1),
  ("query/query_wbtest.mbt#max_id", 1),
  // cmd/serve 的 deleted 是「墓碑计数」而非 id 本身，仍按字段名纳入扫描，
  // 故给 2 条额度（main.mbt:3063 与 :3141 各一条）。
  ("cmd/serve/main.mbt#deleted", 2),
]

///|
/// 单行是否为「整型 id 经 double 序列化」违规：
/// 同一行里既有 `Json::number`、又有 `to_double`，且带 id 类字段名 token。
pub fn line_forbidden_id_double(line : StringView) -> Bool {
  if !line.contains("Json::number") {
    return false
  }
  if !line.contains("to_double") {
    return false
  }
  for tok in id_field_tokens {
    if line.contains(tok) {
      return true
    }
  }
  false
}

///|
/// 扫一段源码文本，是否含违规行（用于「喂违规文本应判 true」的自测）。
pub fn scan_file_forbidden_id_double(text : StringView) -> Bool {
  for line in text.split("\n") {
    if line_forbidden_id_double(line) {
      return true
    }
  }
  false
}

///|
/// 违规行的归一化键：`路径#JSON key`。取行内第一个双引号字符串作为 key
/// （例如 `sm.set("min_id", Json::number(...))` → `min_id`），
/// 这样同一处代码行号漂移不会破基线；取不到字符串时退回整行文本。
pub fn violation_key(path : StringView, line : StringView) -> String {
  let mut key = first_quoted(line)
  if key.is_empty() {
    key = line.trim().to_owned()
  }
  "\{path}#\{key}"
}

///|
/// 行内第一个双引号字符串（没有则返回空串）。
pub fn first_quoted(line : StringView) -> String {
  let parts = quoted_strings(line)
  if parts.length() > 0 {
    parts[0]
  } else {
    ""
  }
}

///|
/// 某个基线键允许的条数（0 = 不许出现）。
pub fn id_double_baseline_count(key : String) -> Int32 {
  for entry in id_double_baseline {
    let (k, n) = entry
    if k == key {
      return n
    }
  }
  0
}

///|
/// 用「实际计数」对照基线，超出即 raise。抽出来是为了让测试能喂
/// 一份故意超额的计数，验证这条断言真的会失败。
pub fn verify_id_double_counts(counts : Map[String, Int32]) -> Unit raise {
  let bad = Array()
  for entry in counts {
    let (key, n) = entry
    let allow = id_double_baseline_count(key)
    if n > allow {
      bad.push("\{key}: \{n} 处 > 基线 \{allow}")
    }
  }
  if bad.length() > 0 {
    raise SpecViolation(
      "断言1 失败：整型 id 走了 double 序列化（新增 \{bad.length()} 处）：\{bad.join(", ")}",
    )
  }
}

// ---------------------------------------------------------------------------
// 断言 2：slab magic 常量
// ---------------------------------------------------------------------------

///|
/// 允许的 slab magic 字面量。"SLAB"=SlabV2 header/trailer，"SLIX"=index；
/// "SLB1"/"SLB2" 为后续规格预留。
pub fn magic_literal_allowed(lit : StringView) -> Bool {
  match lit {
    "SLAB" | "SLIX" | "SLB1" | "SLB2" => true
    _ => false
  }
}

///|
/// slab.mbt 的 magic 断言（纯函数）：常量定义必须逐字存在，且所有
/// `*_MAGIC : String = "..."` 的字面量必须在白名单内。
pub fn slab_magic_ok(text : StringView) -> Bool {
  // 两个 header/index magic 常量必须逐字存在且值在白名单内。
  match const_string_literal(text, "SLAB_MAGIC") {
    Some(lit) => if !magic_literal_allowed(lit) { return false }
    None => return false
  }
  match const_string_literal(text, "SLAB_INDEX_MAGIC") {
    Some(lit) => if !magic_literal_allowed(lit) { return false }
    None => return false
  }
  // 任何其它 `*_MAGIC : String = "..."` 常量也必须在白名单里。
  for line in text.split("\n") {
    if line.contains("_MAGIC : String = ") {
      let lit = first_quoted(line)
      if lit.is_empty() || !magic_literal_allowed(lit) {
        return false
      }
    }
  }
  true
}

///|
/// 取 `const <name> : String = "..."` 的字面量（找不到返回 None）。
pub fn const_string_literal(text : StringView, name : StringView) -> String? {
  for line in text.split("\n") {
    let t = line.trim()
    if t.contains(name) && t.contains(": String =") {
      let lit = first_quoted(t)
      if !lit.is_empty() {
        return Some(lit)
      }
    }
  }
  None
}

// ---------------------------------------------------------------------------
// 断言 3：moon.pkg 不得新增 C FFI
// ---------------------------------------------------------------------------

///|
/// `native-stub` 基线：W8 时仓库里真实存在的 5 个 C 桩（`包相对路径#文件名`）。
///
/// 说明：任务描述里提到的 `uring/uring_native.c` 与 `netutil/` 的
/// tpool-reserved 桩在仓库里**都不存在**（uring 的桩是 `uring/uring.c`，
/// netutil 没有任何 native-stub），所以这两个白名单项没有放行；
/// 实际放行的是下面这 5 个既有条目。新增任何一个都算违规。
let stub_baseline : Array[String] = [
  "core#entropy.c", "uring#uring.c", "threadpool#tp.c", "benchx#kernel.c", "cmd/idxrepo#idxfs.c",
]

///|
/// moon.pkg 里的 C 桩是否在基线内（`pkg_rel` 为空串表示仓库根）。
pub fn stub_allowed(pkg_rel : String, stub : String) -> Bool {
  let key = if pkg_rel.is_empty() { "\{stub}" } else { "\{pkg_rel}#\{stub}" }
  for entry in stub_baseline {
    if entry == key {
      return true
    }
  }
  false
}

///|
/// 去掉行注释（整行 `//` 与行尾 `//` 都处理），避免把注释里的提法当成配置。
pub fn strip_comment(line : StringView) -> StringView {
  match line.split_once("//") {
    Some(pair) => {
      let (before, _) = pair
      before
    }
    None => line
  }
}

///|
/// 取出 moon.pkg 文本里 `native-stub` 段声明的所有 `.c` 文件名（忽略注释）。
pub fn pkg_stub_names(text : StringView) -> Array[String] {
  let out = Array()
  let mut in_array = false
  for raw in text.split("\n") {
    let line = strip_comment(raw)
    if line.is_empty() {
      continue
    }
    if !in_array {
      if !line.contains("native-stub") {
        continue
      }
      in_array = !line.contains("]")
    } else if line.contains("]") {
      in_array = false
    }
    for s in quoted_strings(line) {
      if s.contains(".c") {
        out.push(s)
      }
    }
  }
  out
}

///|
/// 一行里的所有双引号字符串（按 `"` 切分后取奇数位）。
pub fn quoted_strings(line : StringView) -> Array[String] {
  let out = Array()
  let parts = line.split("\"")
  let mut i = 0
  for p in parts {
    if i % 2 == 1 {
      out.push(p.to_owned())
    }
    i = i + 1
  }
  out
}

///|
/// moon.pkg 里是否出现链接段（s3http 的 libcurl `link:` 曾写死 homebrew 路径）。
/// 这些段一律禁止回流：`link:` / `link-flags` / `cc-link-flags` / `stub-cc-flags`。
pub fn pkg_has_link_section(text : StringView) -> Bool {
  for raw in text.split("\n") {
    let line = strip_comment(raw)
    if line.is_empty() {
      continue
    }
    if line.contains("link:") ||
      line.contains("link-flags") ||
      line.contains("cc-link-flags") ||
      line.contains("stub-cc-flags") {
      return true
    }
  }
  false
}

// ---------------------------------------------------------------------------
// 断言 4：cmd 不得硬编码 macOS 包管理路径
// ---------------------------------------------------------------------------

///|
/// 单行是否含硬编码 homebrew / 自编译前缀路径（已真实导致 Linux 构建失败）。
pub fn line_hardcoded_host_path(line : StringView) -> Bool {
  line.contains("/opt/homebrew/") || line.contains("/usr/local/opt/")
}

// ---------------------------------------------------------------------------
// run()：读源码、跑四条断言
// ---------------------------------------------------------------------------

///|
/// specguard 的违规（断言失败一律用这个 suberror 抛出，便于 wbtest 捕获）。
pub suberror SpecViolation {
  SpecViolation(String)
}

///|
/// run() 的汇总结果（只用于测试与打印）。
#derive(Debug, Eq)
pub(all) struct SpecReport {
  id_double_sites : Int32
  mbt_files : Int32
  pkg_files : Int32
  stubs_allowlisted : Int32
}

///|
/// 定位仓库根：`moon test` 的 cwd 可能是模块根，也可能是包目录。
async fn find_root() -> String {
  let candidates : Array[String] = [".", "..", "../..", "../../.."]
  for c in candidates {
    let probe = if c == "." {
      "format/slab.mbt"
    } else {
      "\{c}/format/slab.mbt"
    }
    if @fs.exists(probe) {
      return c
    }
  }
  raise SpecViolation(
    "找不到仓库根（format/slab.mbt 不在 cwd 及其祖先里）",
  )
}

///|
/// 递归列出仓库内所有文件（相对仓库根的路径），跳过构建产物与依赖目录。
async fn list_files(root : String) -> Array[String] {
  let out : Array[String] = Array()
  walk_dir(root, "", out)
  out
}

///|
async fn walk_dir(root : String, rel : String, out : Array[String]) -> Unit {
  let base = if rel.is_empty() { root } else { "\{root}/\{rel}" }
  let names = @fs.readdir(base, sort=true)
  for name in names {
    if name == "_build" ||
      name == ".mooncakes" ||
      name == ".git" ||
      name == "target" {
      continue
    }
    let child_rel = if rel.is_empty() { name } else { "\{rel}/\{name}" }
    let child_path = "\{root}/\{child_rel}"
    let kind = @fs.kind(child_path)
    match kind {
      Directory => walk_dir(root, child_rel, out)
      Regular => out.push(child_rel)
      _ => ()
    }
  }
}

///|
/// 读文本文件（UTF-8）。
async fn read_text(path : String) -> String {
  @fs.read_file(path).text()
}

///|
/// 断言 1 的实现：扫 format/build/query/cmd 下所有 .mbt，按 `路径#key` 计数。
async fn check_id_double(root : String, files : Array[String]) -> Int32 {
  let counts : Map[String, Int32] = Map([])
  let mut scanned = 0
  for rel in files {
    let in_scope = (
        rel.has_prefix("format/") ||
        rel.has_prefix("build/") ||
        rel.has_prefix("query/") ||
        rel.has_prefix("cmd/")
      ) &&
      rel.has_suffix(".mbt")
    if !in_scope {
      continue
    }
    scanned = scanned + 1
    let text = read_text("\{root}/\{rel}")
    for line in text.split("\n") {
      if line_forbidden_id_double(line) {
        let key = violation_key(rel, line)
        counts.set(key, counts.get(key).unwrap_or(0) + 1)
      }
    }
  }
  let mut total = 0
  for entry in counts {
    let (_, n) = entry
    total = total + n
  }
  verify_id_double_counts(counts)
  scanned
}

///|
/// 断言 2 的实现：format/slab.mbt 的 magic 常量。
async fn check_slab_magic(root : String) -> Unit {
  let text = read_text("\{root}/format/slab.mbt")
  if !slab_magic_ok(text) {
    raise SpecViolation(
      "断言2 失败：format/slab.mbt 的 magic 常量越界（只允许 SLAB/SLIX/SLB1/SLB2）",
    )
  }
}

///|
/// 断言 3 的实现：全仓 moon.pkg 不得新增 native-stub，且不得有 link: 段。
async fn check_pkg_ffi(root : String, files : Array[String]) -> (Int32, Int32) {
  let mut pkgs = 0
  let mut stubs = 0
  for rel in files {
    if rel != "moon.pkg" && !rel.has_suffix("/moon.pkg") {
      continue
    }
    pkgs = pkgs + 1
    let pkg_rel = match rel.find("/moon.pkg") {
      Some(i) => rel.unsafe_substring(start=0, end=i)
      None => ""
    }
    let text = read_text("\{root}/\{rel}")
    if pkg_has_link_section(text) {
      raise SpecViolation(
        "断言3 失败：\{rel} 出现 link:/link-flags 段（C FFI 回流，且常写死 macOS 路径）",
      )
    }
    for stub in pkg_stub_names(text) {
      stubs = stubs + 1
      if !stub_allowed(pkg_rel, stub) {
        raise SpecViolation(
          "断言3 失败：\{rel} 新增 native-stub \"\{stub}\"（不在 W8 基线 5 条内）",
        )
      }
    }
  }
  (pkgs, stubs)
}

///|
/// 断言 4 的实现：cmd 下源码不得硬编码 homebrew / 自编译前缀路径。
async fn check_cmd_host_paths(root : String, files : Array[String]) -> Unit {
  for rel in files {
    if !rel.has_prefix("cmd/") || !rel.has_suffix(".mbt") {
      continue
    }
    let text = read_text("\{root}/\{rel}")
    let mut n = 0
    for line in text.split("\n") {
      n = n + 1
      if line_hardcoded_host_path(line) {
        raise SpecViolation(
          "断言4 失败：\{rel}:\{n} 硬编码了 macOS 包管理路径（会让 Linux 构建挂掉）",
        )
      }
    }
  }
}

///|
/// specguard 入口：读源码跑四条断言，违规即 raise；返回汇总计数。
pub async fn run() -> SpecReport {
  let root = find_root()
  let files = list_files(root)
  let scanned = check_id_double(root, files)
  check_slab_magic(root)
  let (pkgs, stubs) = check_pkg_ffi(root, files)
  check_cmd_host_paths(root, files)
  let report : SpecReport = {
    id_double_sites: scanned,
    mbt_files: files.length(),
    pkg_files: pkgs,
    stubs_allowlisted: stubs,
  }
  println(
    "specguard: OK（扫描 \{report.id_double_sites} 个 id-double 相关 .mbt，\{report.pkg_files} 个 moon.pkg 全在基线内，\{report.stubs_allowlisted} 个 native-stub 均放行）",
  )
  report
}
