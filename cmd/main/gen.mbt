// bench 数据与查询集生成（确定性，@core.Rng 种子 42）：
// - 10k docs：zipf 词表（120 英文词 + 40 中文双字词）30~80 token/文档；
//   8 簇 768 维向量 + 噪声；category=cat{i%8}；ts=1700000000+i；public=i%3!=0
// - 中文词直接拼进文本，tokenizer 单字切开；中文查询词取词的首字（同样单字）

///|
let vocab_en : Array[String] = [
  "time", "year", "people", "way", "day", "man", "thing", "woman", "life", "child",
  "world", "school", "state", "family", "student", "group", "country", "problem",
  "hand", "part", "place", "case", "week", "company", "system", "program", "question",
  "work", "government", "number", "night", "point", "home", "water", "room", "mother",
  "area", "money", "story", "fact", "month", "lot", "right", "study", "book", "eye",
  "job", "word", "business", "issue", "side", "kind", "head", "house", "service",
  "friend", "father", "power", "hour", "game", "line", "end", "member", "law", "car",
  "city", "community", "name", "team", "minute", "idea", "kid", "body", "information",
  "back", "parent", "face", "level", "office", "door", "health", "person", "art",
  "war", "history", "party", "result", "change", "morning", "reason", "research",
  "girl", "moment", "air", "teacher", "force", "education", "foot", "boy", "age",
  "policy", "process", "music", "market", "sense", "nation", "plan", "college", "interest",
  "death", "experience", "effect", "light", "machine", "salt", "storm", "ocean",
  "river", "forest", "mountain",
]

///|
let vocab_zh : Array[String] = [
  "星光", "大海", "山川", "月色", "河流", "森林", "风雪", "云海",
  "花开", "春天", "秋雨", "夏夜", "冬雪", "江湖", "古城", "灯火",
  "远方", "时光", "梦想", "自由", "勇气", "希望", "温暖", "孤独",
  "安静", "热闹", "旅途", "归来", "少年", "故事", "天空", "大地",
  "流星", "清风", "明月", "落花", "潮汐", "峡谷", "草原", "极光",
]

///|
/// zipf(r) = (r+1)^-0.7 的累计分布。
fn build_zipf_cum() -> Array[Double] {
  let total = vocab_en.length() + vocab_zh.length()
  let cum : Array[Double] = Array::new(capacity=total)
  let mut acc = 0.0
  for r in 0..<total {
    acc = acc + 1.0 / @math.pow((r + 1).to_double(), 0.7)
    cum.push(acc)
  }
  cum
}

///|
/// 按 zipf 采样一个词表下标。
fn sample_vocab_idx(rng : @core.Rng, cum : Array[Double]) -> Int {
  let x = rng.next_f64() * cum[cum.length() - 1]
  let mut i = 0
  while i < cum.length() && cum[i] < x {
    i += 1
  }
  if i >= cum.length() {
    cum.length() - 1
  } else {
    i
  }
}

///|
/// 采样一个查询词：英文词原样；中文词取首字（tokenizer 单字切开，保证命中）。
fn sample_term(rng : @core.Rng, cum : Array[Double]) -> String {
  let idx = sample_vocab_idx(rng, cum)
  if idx < vocab_en.length() {
    vocab_en[idx]
  } else {
    let toks = @core.tokenize(vocab_zh[idx - vocab_en.length()])
    if toks.is_empty() {
      vocab_zh[idx - vocab_en.length()]
    } else {
      toks[0]
    }
  }
}

///|
/// 生成一条文档文本（target 为目标 token 数；中文词贡献 2 token）。
fn gen_text(rng : @core.Rng, cum : Array[Double], target : Int) -> String {
  let mut text = ""
  let mut tokens = 0
  while tokens < target {
    let idx = sample_vocab_idx(rng, cum)
    if idx < vocab_en.length() {
      text = text + vocab_en[idx] + " "
      tokens += 1
    } else {
      text = text + vocab_zh[idx - vocab_en.length()]
      tokens += 2
    }
  }
  text
}

///|
/// 生成全部 10k docs（id=i；8 簇 768 维向量 + 噪声）。
fn gen_docs(rng : @core.Rng, cum : Array[Double]) -> Array[@core.Doc] {
  let dim = 768
  let n_clusters = 8
  let centers : Array[Float] = Array::new(capacity=n_clusters * dim)
  for _c in 0..<n_clusters {
    for _d in 0..<dim {
      centers.push(Float::from_double(rng.next_range(-1.0, 1.0)))
    }
  }
  let docs : Array[@core.Doc] = Array::new(capacity=10000)
  for i in 0..<10000 {
    let target = 30 + (rng.next_f64() * 51.0).to_int()
    let text = gen_text(rng, cum, target)
    let base = i % n_clusters * dim
    let vec : Array[Float] = Array::new(capacity=dim)
    for d in 0..<dim {
      vec.push(
        Float::from_double(
          centers[base + d].to_double() + rng.next_range(-0.05, 0.05),
        ),
      )
    }
    docs.push({
      id: i.to_uint64(),
      text,
      vector: vec,
      category: "cat\{i % 8}",
      ts: (1700000000 + i).to_int64(),
      public: i % 3 != 0,
    })
  }
  docs
}

///|
/// 生成 count 条 BM25 查询（1~2 个词，zipf 高频词保证命中）。
fn gen_bm25_queries(
  rng : @core.Rng,
  cum : Array[Double],
  count : Int,
) -> Array[String] {
  let out : Array[String] = Array::new()
  for i in 0..<count {
    let t1 = sample_term(rng, cum)
    if i % 3 == 2 {
      let t2 = sample_term(rng, cum)
      out.push(t1 + " " + t2)
    } else {
      out.push(t1)
    }
  }
  out
}

///|
/// 生成 count 条向量查询：取某些 doc 的向量加小噪声。
fn gen_vec_queries(
  rng : @core.Rng,
  docs : Array[@core.Doc],
  count : Int,
) -> Array[Array[Float]] {
  let out : Array[Array[Float]] = Array::new()
  for i in 0..<count {
    let di = (i * 337 + 11) % docs.length()
    let base = docs[di].vector
    let v : Array[Float] = Array::new(capacity=base.length())
    for x in base {
      v.push(Float::from_double(x.to_double() + rng.next_range(-0.01, 0.01)))
    }
    out.push(v)
  }
  out
}
