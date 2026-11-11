// CJK 词典分词器（smartcn / kuromoji / nori 风格）。
//
// 契约（对齐 turbopuffer FTS 文档与 alyze crate 的功能面）：
// - smartcn：中文词典分词——把中文文本切成已知词（如「服装」一个词，不再逐字）；
//   未登录字回退单字（Lucene SmartCN 是 bigram-HMM，本实现是词典最大匹配近似，
//   非 Lucene 逐 token 对齐——完整 HMM 词典路径见文末 roadmap）。
// - kuromoji：日语形态分析——词典最大匹配 + 活用形归一到基础形
//   （食べました → 食べる），实现「食べる 搜到 食べました」的跨词形匹配；
//   覆盖一段/五段/サ変/カ変动词、い形容词；片假名外来语整段成词。
// - nori：韩语形态分析——助词剥离（그림을 → 그림 + 을）+ 用言基础形
//   （먹습니다 → 먹다）；未登录语节整节成词（Lucene nori unknown 同语义）。
// - 与默认 Word 分词器共存：拉丁/数字段仍走 word 路径（小写化 + 255B 上限），
//   构建与查询必须用同一 Tokenizer（namespace.json 配置）。
//
// 全部确定性：种子词表内嵌、查表结构初始化一次、无随机无 IO。词表是种子集
// （数百词），覆盖测试与常见词；完整词典（ICTCLAS / mecab-ipadic /
// mecab-ko-dic，Apache-2.0/BSD 许可）按 alyze dictionaries-v1 的方式在构建期
// 编译进二进制是第二阶段，本文件结构已为其预留（词表数组 + 形态表）。

///|
/// 分词器选择。Word = 既有 unicode_word 简化分词（默认，旧行为不变）。
pub(all) enum Tokenizer {
  Word
  Smartcn
  Kuromoji
  Nori
} derive(Eq, Show)

///|
/// 配置串 → Tokenizer：'word' / 'smartcn' / 'kuromoji' / 'nori'；未知返回 None。
pub fn parse_tokenizer(s : String) -> Tokenizer? {
  match s {
    "word" => Some(Word)
    "smartcn" => Some(Smartcn)
    "kuromoji" => Some(Kuromoji)
    "nori" => Some(Nori)
    _ => None
  }
}

///|
/// Tokenizer → 配置串（namespace.json 持久化用）。
pub fn tokenizer_to_string(t : Tokenizer) -> String {
  match t {
    Word => "word"
    Smartcn => "smartcn"
    Kuromoji => "kuromoji"
    Nori => "nori"
  }
}

// ---------- 中文（smartcn 风格：词典最大匹配，未登录字回退单字） ----------

///|
/// 中文种子词表（覆盖常见双字/多字词；ICTCLAS 完整词表为第二阶段）。
let zh_words : Array[String] = [
  "安全", "包含", "包括", "北京", "编译", "标准", "表示", "不能", "不同", "测试",
  "产品", "成功", "程序", "处理", "存储", "代码", "当前", "地址", "电影", "电脑",
  "对象", "服务", "服装", "衣服", "裤子", "鞋子", "功能", "公司", "工作", "购买",
  "管理", "广告", "规则", "国际", "过程", "函数", "合同", "欢迎", "环境", "返回",
  "会议", "机器", "基本", "喜欢", "计算", "价格", "价值", "简单", "结构", "结果",
  "今天", "金融", "开发", "开始", "科学", "客户", "空间", "控制", "类型", "历史",
  "例子", "连接", "列表", "内容", "配置", "朋友", "平均", "汽车", "清楚", "情况",
  "全部", "确定", "然后", "任务", "如果", "商品", "设计", "社会", "生产", "时间",
  "实现", "使用", "市场", "数据", "数据库", "搜索引擎", "全文检索", "服装店",
  "服务器", "计算机", "软件", "所有", "他们", "条件", "通过", "同时", "投资",
  "图片", "完整", "网络", "系统", "现在", "项目", "信息", "性能", "需要", "选择",
  "学习", "训练", "一样", "音乐", "应用", "用户", "语言", "运行", "支持", "知识",
  "执行", "直接", "指南", "中国", "中文", "重要", "状态", "资源", "自己", "自然",
  "组织", "最新", "引擎",
]

///|
/// 查表 Set（初始化一次，确定性）。
let zh_word_set : Set[String] = {
  let s : Set[String] = Set([])
  for w in zh_words {
    s.add(w)
  }
  s
}

///|
/// 中文最大匹配：词表命中即整词，未命中回退单字。
fn zh_emit(run : Array[Char], sink : (String) -> Unit) -> Unit {
  let n = run.length()
  let mut i = 0
  while i < n {
    let mut matched = false
    let mut len = if n - i < 8 { n - i } else { 8 }
    while len >= 2 {
      let sub = String::from_array(run[i:i + len])
      if zh_word_set.contains(sub) {
        sink(sub)
        i += len
        matched = true
        break
      }
      len -= 1
    }
    if !matched {
      sink(run[i].to_string())
      i += 1
    }
  }
}

// ---------- 日语（kuromoji 风格：活用归一到基础形） ----------

///|
/// 日语词典词条的活用类型。
enum JaType {
  JaIchidan // 一段动词（食べる）
  JaGodan // 五段动词（走る/書く/読む）
  JaSuru // サ変（する 及其后接动词）
  JaKuru // カ変（来る）
  JaAdjI // い形容词（高い）
  JaOther // 名词/片假名外来语等（无活用）
} derive(Eq)

///|
/// 日语种子词典：(基础形, 类型)。活用 surface 由规则表确定性生成。
let ja_base_words : Array[(String, JaType)] = [
  // 动词（一段）
  ("食べる", JaIchidan), ("見る", JaIchidan), ("いる", JaIchidan),
  ("考える", JaIchidan),
  // 动词（五段）
  ("走る", JaGodan), ("書く", JaGodan), ("読む", JaGodan), ("話す", JaGodan),
  ("待つ", JaGodan), ("飲む", JaGodan), ("買う", JaGodan), ("作る", JaGodan),
  ("分かる", JaGodan),
  // サ変 / カ変
  ("する", JaSuru), ("勉強する", JaSuru), ("検索する", JaSuru),
  ("保存する", JaSuru), ("比較する", JaSuru), ("来る", JaKuru),
  // い形容词
  ("高い", JaAdjI), ("大きい", JaAdjI), ("美しい", JaAdjI), ("新しい", JaAdjI),
  ("速い", JaAdjI), ("安い", JaAdjI),
  // 名词 / 片假名外来语
  ("日本", JaOther), ("日本語", JaOther), ("私", JaOther), ("本", JaOther),
  ("人", JaOther), ("時間", JaOther), ("会社", JaOther), ("今日", JaOther),
  ("明日", JaOther), ("水", JaOther), ("食べ物", JaOther), ("映画", JaOther),
  ("音楽", JaOther), ("コンピュータ", JaOther), ("プログラム", JaOther),
  ("データ", JaOther), ("検索", JaOther), ("全文検索", JaOther),
  ("検索エンジン", JaOther), ("エンジン", JaOther), ("形態素", JaOther),
  ("解析", JaOther), ("辞書", JaOther), ("実際", JaOther), ("簡単", JaOther),
  ("設計", JaOther), ("実装", JaOther), ("テスト", JaOther),
]

///|
/// 五段动词 词尾 う段 → い段（連用形；ます系）。
/// 假名音位表不规则（や/わ行有空位），用字符字面量精确匹配而非码位算术。
fn godan_i_row(c : Char) -> Char? {
  match c {
    'う' => Some('い')
    'く' => Some('き')
    'ぐ' => Some('ぎ')
    'す' => Some('し')
    'つ' => Some('ち')
    'ぬ' => Some('に')
    'ぶ' => Some('び')
    'む' => Some('み')
    'る' => Some('り')
    _ => None
  }
}

///|
/// 五段动词 词尾 う段 → あ段（未然形；う→わ 特例，買わない）。
fn godan_a_row(c : Char) -> Char? {
  match c {
    'う' => Some('わ')
    'く' => Some('か')
    'ぐ' => Some('が')
    'す' => Some('さ')
    'つ' => Some('た')
    'ぬ' => Some('な')
    'ぶ' => Some('ば')
    'む' => Some('ま')
    'る' => Some('ら')
    _ => None
  }
}

///|
/// 五段动词 テ形音变（く→いて/ぐ→いで/す→して/つ,る,う→って/む,ぶ,ぬ→んで）。
fn godan_te(c : Char) -> String? {
  match c {
    'く' => Some("いて")
    'ぐ' => Some("いで")
    'す' => Some("して")
    'つ' => Some("って")
    'る' => Some("って")
    'う' => Some("って")
    'む' => Some("んで")
    'ぶ' => Some("んで")
    'ぬ' => Some("んで")
    _ => None
  }
}

///|
/// (基础形, 类型) → 该基础形的常见活用 surface。数组顺序固定 ⇒ 确定性。
fn ja_inflections(base : String, ty : JaType) -> Array[String] {
  let out : Array[String] = Array::new()
  match ty {
    JaIchidan => {
      let stem = base[:base.length() - 1].to_owned()
      for suf in ["る", "ます", "ました", "ません", "て", "た", "ない",
        "なかった", "られる", "よう", "ろ", "れば", "たい"] {
        out.push(stem + suf)
      }
    }
    JaGodan => {
      // String 下标返回 UInt16（code unit）：先转 Char 数组再取词尾。
      let cs = base.to_array()
      let last = cs[cs.length() - 1]
      let stem = base[:base.length() - 1].to_owned()
      match godan_i_row(last) {
        Some(c) => {
          let s = stem + c.to_string()
          out.push(s + "ます")
          out.push(s + "ました")
          out.push(s + "ません")
        }
        None => ()
      }
      match godan_te(last) {
        Some(t) => {
          // テ形/タ形 = 词干 + 音变后缀（書く → 書いて/書いた）。
          out.push(stem + t)
          let tcs = t.to_array()
          let last2 = tcs[tcs.length() - 1].to_string()
          let stem_t = t[:t.length() - 1].to_owned()
          if last2 == "て" {
            out.push(stem + stem_t + "た")
          } else {
            out.push(stem + stem_t + "だ")
          }
        }
        None => ()
      }
      match godan_a_row(last) {
        Some(c) => {
          let s = stem + c.to_string()
          out.push(s + "ない")
          out.push(s + "なかった")
        }
        None => ()
      }
      out.push(stem + "れば")
      out.push(base)
    }
    JaSuru => {
      let stem = base[:base.length() - 2].to_owned() // 去掉「する」
      for suf in ["する", "します", "しました", "しません", "して", "した",
        "しない", "しなかった", "すれば", "したい"] {
        out.push(stem + suf)
      }
    }
    JaKuru => {
      let stem = base[:base.length() - 1].to_owned() // 来る→来
      for suf in ["る", "ます", "ました", "ません", "て", "た", "ない",
        "なかった"] {
        out.push(stem + suf)
      }
      // かな表记变体。
      out.push("くる")
      out.push("きます")
      out.push("きた")
    }
    JaAdjI => {
      let stem = base[:base.length() - 1].to_owned() // 去掉 い
      for suf in ["い", "く", "かった", "くない", "くなかった", "ければ",
        "くて"] {
        out.push(stem + suf)
      }
    }
    JaOther => out.push(base)
  }
  out
}

///|
/// 活用 surface → 基础形（初始化一次，确定性）。
let ja_surface_map : Map[String, String] = {
  let m : Map[String, String] = Map([])
  for kv in ja_base_words {
    let (base, ty) = kv
    for surf in ja_inflections(base, ty) {
      if !m.contains(surf) {
        m.set(surf, base)
      }
    }
    if !m.contains(base) {
      m.set(base, base)
    }
  }
  m
}

///|
/// 日语段输出：最长匹配活用表 → 基础形；未登录片假名整段（外来语语义单位），
/// 其余回退单字。
fn ja_emit(run : Array[Char], sink : (String) -> Unit) -> Unit {
  let n = run.length()
  let mut i = 0
  while i < n {
    let mut matched = false
    let mut len = if n - i < 10 { n - i } else { 10 }
    while len >= 1 {
      let sub = String::from_array(run[i:i + len])
      match ja_surface_map.get(sub) {
        Some(base) => {
          sink(base)
          i += len
          matched = true
          break
        }
        None => len -= 1
      }
    }
    if !matched {
      let c0 = run[i].to_int()
      if c0 >= 0x30A0 && c0 <= 0x30FF {
        // 未登录片假名：整段（kuromoji unknown 语义的近似）。
        let mut j = i
        while j < n && run[j].to_int() >= 0x30A0 && run[j].to_int() <= 0x30FF {
          j += 1
        }
        sink(String::from_array(run[i:j]))
        i = j
      } else {
        sink(run[i].to_string())
        i += 1
      }
    }
  }
}

// ---------- 韩语（nori 风格：助词剥离 + 用言基础形） ----------

///|
/// 韩语名词/常见词（种子表；mecab-ko-dic 完整词表为第二阶段）。
let ko_nouns : Array[String] = [
  "그림", "데이터", "데이터베이스", "사람", "사전", "검색", "검색엔진", "엔진",
  "언어", "한국어", "한국", "일본", "중국", "시간", "오늘", "내일", "회사",
  "음식", "밥", "물", "컴퓨터", "프로그램", "영화", "음악", "친구", "도서",
  "도서관", "문서", "문제", "결과", "기능", "디자인", "설치", "설명", "실제",
  "시스템", "테스트", "파일", "프로젝트", "학생", "학교", "형태소", "분석",
]

///|
/// 韩语动词/形容词活用 surface → 基础形（手工列举保证形态正确；
/// mecab-ko-dic + 自动活用生成是第二阶段）。
let ko_verbs : Array[(String, String)] = [
  ("먹습니다", "먹다"), ("먹어요", "먹다"), ("먹었습니다", "먹다"),
  ("먹고", "먹다"), ("먹으면", "먹다"), ("먹는다", "먹다"),
  ("합니다", "하다"), ("해요", "하다"), ("했습니다", "하다"), ("하고", "하다"),
  ("하면", "하다"), ("한다", "하다"),
  ("분석합니다", "분석하다"), ("분석해요", "분석하다"),
  ("검색합니다", "검색하다"), ("검색해요", "검색하다"), ("검색했습니다", "검색하다"),
  ("갑니다", "가다"), ("가요", "가다"), ("갔습니다", "가다"), ("가고", "가다"),
  ("가면", "가다"), ("간다", "가다"),
  ("봅니다", "보다"), ("봐요", "보다"), ("봤습니다", "보다"), ("보고", "보다"),
  ("보면", "보다"), ("본다", "보다"),
  ("있습니다", "있다"), ("있어요", "있다"), ("있고", "있다"),
  ("없습니다", "없다"), ("없어요", "없다"),
  ("만듭니다", "만들다"), ("만들어요", "만들다"), ("만들고", "만들다"),
  ("읽습니다", "읽다"), ("읽어요", "읽다"), ("읽고", "읽다"),
  ("써요", "쓰다"), ("쓰고", "쓰다"),
]

///|
/// 韩语助词（剥离顺序：长者优先）。
let ko_particles : Array[String] = [
  "에서는", "으로는", "에서도", "으로서", "으로써", "부터", "까지", "에서",
  "에게", "하고", "으로", "이나", "과", "와", "을", "를", "은", "는", "이",
  "가", "에", "도", "만", "로", "의",
]

///|
struct KoDict {
  verbs : Map[String, String]
  nouns : Set[String]
  particles : Set[String]
}

///|
let ko_dict_v : KoDict = {
  let verbs : Map[String, String] = Map([])
  for kv in ko_verbs {
    verbs.set(kv.0, kv.1)
  }
  let nouns : Set[String] = Set([])
  for w in ko_nouns {
    nouns.add(w)
  }
  let particles : Set[String] = Set([])
  for p in ko_particles {
    particles.add(p)
  }
  { verbs, nouns, particles }
}

///|
/// 韩语语节分析：活用表 → 基础形；名词 → 原样；剥最长助词后名词命中 →
/// 名词 + 助词；未登录 → 整语节一 token（nori unknown 语义）。
fn ko_emit(run : Array[Char], sink : (String) -> Unit) -> Unit {
  let d = ko_dict_v
  let n = run.length()
  let mut i = 0
  while i < n {
    let mut matched = false
    let mut len = if n - i < 12 { n - i } else { 12 }
    while len >= 1 {
      let sub = String::from_array(run[i:i + len])
      match d.verbs.get(sub) {
        Some(base) => {
          sink(base)
          i += len
          matched = true
          break
        }
        None =>
          if d.nouns.contains(sub) {
            sink(sub)
            i += len
            matched = true
            break
          } else {
            len -= 1
          }
      }
    }
    if !matched {
      // 助词剥离：从语节尾部剥最长助词再查名词（必须剩非空名词）。
      let mut plen = if n - i < 4 { n - i } else { 4 }
      while plen >= 1 {
        let p = String::from_array(run[n - plen:n])
        let stem = String::from_array(run[i:n - plen])
        if d.particles.contains(p) && d.nouns.contains(stem) {
          sink(stem)
          sink(p)
          i = n
          matched = true
          break
        }
        plen -= 1
      }
      if !matched {
        sink(String::from_array(run[i:n]))
        i = n
      }
    }
  }
}

// ---------- 分段驱动 ----------

///|
fn is_hiragana_katakana(c : Int) -> Bool {
  (c >= 0x3040 && c <= 0x30FF) || (c >= 0x31F0 && c <= 0x31FF)
}

///|
fn is_hangul_syllable(c : Int) -> Bool {
  c >= 0xAC00 && c <= 0xD7AF
}

///|
fn is_han(c : Int) -> Bool {
  (c >= 0x3400 && c <= 0x4DBF) ||
  (c >= 0x4E00 && c <= 0x9FFF) ||
  (c >= 0xF900 && c <= 0xFAFF)
}

///|
/// 带分词器的 tokenize_into：Word 走原实现（行为不变）。
/// 其余按 tokenizer 的主字类累积 CJK run 交给对应分析器；
/// 拉丁/数字段仍走 word 逻辑（小写化 + 255B 截断）；
/// 非主类 CJK 字符（如中文文本里的假名）逐字输出。
pub fn tokenize_into_with(
  tok : Tokenizer,
  text : String,
  sink : (String) -> Unit,
) -> Unit {
  match tok {
    Word => tokenize_into(text, sink)
    Smartcn =>
      cjk_analyze(text, sink, fn(c) { is_han(c) }, fn(run) { zh_emit(run, sink) })
    Kuromoji =>
      cjk_analyze(
        text,
        sink,
        fn(c) { is_han(c) || is_hiragana_katakana(c) },
        fn(run) { ja_emit(run, sink) },
      )
    Nori =>
      cjk_analyze(
        text,
        sink,
        fn(c) { is_hangul_syllable(c) },
        fn(run) { ko_emit(run, sink) },
      )
  }
}

///|
/// CJK 分析驱动（Word 之外的三个分词器共用）：
/// - ASCII 字母/数字连段：word 逻辑（小写化 + 255B 截断）；
/// - 主字类字符累积 run，类间切换或遇分隔符时整段交给 analyze_run；
/// - 其余字符一律分隔。
fn cjk_analyze(
  text : String,
  sink : (String) -> Unit,
  is_kind_char : (Int) -> Bool,
  analyze_run : (Array[Char]) -> Unit,
) -> Unit {
  let word_chars : Array[Char] = Array::new()
  let cjk_run : Array[Char] = Array::new()
  let flush_word = () => {
    if word_chars.length() > 0 {
      let mut term = String::from_array(word_chars.view()).to_lower()
      if term.length() > 255 {
        term = term[:255].to_owned()
      }
      word_chars.clear()
      sink(term)
    }
  }
  let flush_cjk = () => {
    if cjk_run.length() > 0 {
      analyze_run(cjk_run)
      cjk_run.clear()
    }
  }
  for ch in text.iter() {
    let c = ch.to_int()
    if ch.is_ascii_alphabetic() || ch.is_ascii_digit() {
      flush_cjk()
      word_chars.push(ch)
    } else if is_kind_char(c) {
      flush_word()
      cjk_run.push(ch)
    } else {
      flush_word()
      flush_cjk()
      // 非主类 CJK 字符（其它 tokenizer 的目标脚本）：逐字输出保持可检索。
      if is_han(c) || is_hiragana_katakana(c) || is_hangul_syllable(c) {
        sink(ch.to_string())
      }
    }
  }
  flush_word()
  flush_cjk()
}

///|
/// 带分词器的 tokenize。
pub fn tokenize_with(tok : Tokenizer, text : String) -> Array[String] {
  let out : Array[String] = Array::new()
  tokenize_into_with(tok, text, fn(t) { out.push(t) })
  out
}

///|
test "zh smartcn splits dictionary words" {
  inspect(tokenize_with(Smartcn, "我喜欢这件服装").join("|"),
    content="我|喜欢|这|件|服装")
  inspect(tokenize_with(Smartcn, "全文检索引擎").join("|"),
    content="全文检索|引擎")
  inspect(tokenize_with(Smartcn, "中文数据库系统").join("|"),
    content="中文|数据库|系统")
}

///|
test "kuromoji base form cross matching" {
  // 食べました → 食べる：与查询「食べる」命中同一 term（跨词形匹配）。
  inspect(tokenize_with(Kuromoji, "私は映画を食べました").join("|"),
    content="私|は|映画|を|食べる")
  inspect(tokenize_with(Kuromoji, "本を読みます").join("|"),
    content="本|を|読む")
  inspect(tokenize_with(Kuromoji, "コンピュータで検索します").join("|"),
    content="コンピュータ|で|検索する")
  // 五段动词：走ります→走る、書いて→書く；未然形：買わない→買う。
  inspect(tokenize_with(Kuromoji, "毎日走ります").join("|"),
    content="毎|日|走る")
  inspect(tokenize_with(Kuromoji, "レポートを書いた").join("|"),
    content="レポート|を|書く")
  inspect(tokenize_with(Kuromoji, "株を買わない").join("|"),
    content="株|を|買う")
}

///|
test "nori particle stripping and verb base forms" {
  inspect(tokenize_with(Nori, "그림을 분석합니다").join("|"),
    content="그림|을|분석하다")
  inspect(tokenize_with(Nori, "한국어 데이터를 검색합니다").join("|"),
    content="한국어|데이터|를|검색하다")
  inspect(tokenize_with(Nori, "밥을 먹었습니다").join("|"),
    content="밥|을|먹다")
}

///|
test "mixed latin and cjk keeps word path behavior" {
  inspect(tokenize_with(Smartcn, "Hello 服装 World v2").join("|"),
    content="hello|服装|world|v2")
  inspect(tokenize_with(Kuromoji, "abc 高いxyz").join("|"),
    content="abc|高い|xyz")
  // Word 分词器行为不变（回归锚点；与原 tokenize 测试同语义）。
  inspect(tokenize_with(Word, "Hello, World! 你好世界 v2.0").join("|"),
    content="hello|world|你|好|世|界|v2|0")
}

///|
test "parse and roundtrip tokenizer names" {
  inspect(parse_tokenizer("kuromoji"), content="Some(Kuromoji)")
  inspect(parse_tokenizer("nori"), content="Some(Nori)")
  inspect(parse_tokenizer("smartcn"), content="Some(Smartcn)")
  inspect(parse_tokenizer("word"), content="Some(Word)")
  inspect(parse_tokenizer("bogus"), content="None")
  inspect(tokenizer_to_string(Word), content="word")
  inspect(tokenizer_to_string(Kuromoji), content="kuromoji")
}

// Roadmap（第二阶段）：
// 1. 完整词典：构建期下载 ICTCLAS / mecab-ipadic / mecab-ko-dic（校验 SHA-256）
//    编译进二进制（alyze dictionaries-v1 方式），词表规模 → 十万级。
// 2. SmartCN 换 bigram-HMM（与 Lucene golden files 对齐）；
//    kuromoji/nori 换 MeCab 式 lattice（Viterbi + 连接代价）。
// 3. native 后端可选 FFI 到 alyze（MIT）做逐 token 对齐基准。

