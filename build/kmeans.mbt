// IVF kmeans（Lloyd 迭代）训练，cosine 语义。
//
// 查询侧用 cosine 距离，因此训练的分配/更新也统一 cosine 语义：
// 中心归一化后「按内积最大分配」等价于「cosine 距离最小」，存储的中心
// 恒为归一化后的 f32 向量，保证与 decode_centroids 出来的精排一致。
//
// 确定性：@core.Rng 种子固定 42，对 [0..N) 下标做部分 Fisher-Yates，
// 取前 min(nlist*8, N) 个作为训练样本。空簇用随机样本重置。

///|
/// 把 v 的归一化拷贝追加到 out（零向量原样追加，长度取 dim）。
fn append_normalized(out : Array[Float], v : Array[Float], dim : Int) -> Unit {
  let norm = @core.norm_f32(v, 0, dim)
  for i in 0..<dim {
    if norm > 0.0 {
      out.push(Float::from_double(v[i].to_double() / norm))
    } else {
      out.push(v[i])
    }
  }
}

///|
/// 原地归一化 data[base..base+dim)，零向量与已归一化向量不动。
fn normalize_center(data : Array[Float], base : Int, dim : Int) -> Unit {
  let norm = @core.norm_f32(data, base, dim)
  if norm > 0.0 && norm != 1.0 {
    for i in 0..<dim {
      data[base + i] = Float::from_double(data[base + i].to_double() / norm)
    }
  }
}

///|
///|
/// Lloyd kmeans：
/// - 确定性采样 min(nlist*8, docs.length()) 条向量（Rng 种子 42）
/// - k 收缩为 min(nlist, 样本数)，避免重复中心导致的常驻空簇
/// - 迭代 iters 轮：分配（距离最小）→ 均值更新 → （cosine 时）归一化
/// - 空簇用随机样本重置
/// - docs 为空 / dim 为 0 / nlist<=0 时返回空中心（dim=0 或 k=0）
/// euclidean=true：l2sq 分配、中心取原始均值不归一化（欧氏 IVF 语义）；
/// 否则 cosine 分配、中心归一化（默认，旧行为）。
pub fn train_centroids(
  docs : Array[@core.Doc],
  nlist : Int,
  iters : Int,
  euclidean : Bool,
) -> @format.Centroids {
  if docs.length() == 0 {
    return { dim: 0, data: [] }
  }
  let dim = docs[0].vector.length()
  if dim == 0 || nlist <= 0 {
    return { dim, data: [] }
  }
  let n = docs.length()
  // 样本量 = min(max(nlist*8, 8192), N)：旧上限 nlist*8 会让小 nlist（如 64 → 512 条）
  // 的中心质量成为 recall 瓶颈（1M 精确 GT 实测：nlist=64 封顶 0.916）；下限 8192
  // 保证中心见到足够分布。8192×nlist×dim×iters 的训练量在 native 上秒级。
  let want = if nlist * 8 < 8192 { 8192 } else { nlist * 8 }
  let sample_n = if want < n { want } else { n }
  let k = if nlist < sample_n { nlist } else { sample_n }
  let rng = @core.Rng::new(42U)
  // 部分 Fisher-Yates：idx 前 sample_n 个即确定性采样结果
  let idx : Array[Int] = Array(capacity=n)
  for i in 0..<n {
    idx.push(i)
  }
  for i in 0..<sample_n {
    // 注意 UInt::to_int 是位重解释：先在 UInt 域取模再转 Int，避免高位翻负
    let j = i +
      (rng.next_u32() % (n - i).reinterpret_as_uint()).reinterpret_as_int()
    let t = idx[i]
    idx[i] = idx[j]
    idx[j] = t
  }
  // 中心初始化：取前 k 个样本（cosine 归一化，euclidean 原始拷贝）
  let data : Array[Float] = Array(capacity=k * dim)
  for c in 0..<k {
    if euclidean {
      for f in 0..<dim {
        data.push(docs[idx[c]].vector[f])
      }
    } else {
      append_normalized(data, docs[idx[c]].vector, dim)
    }
  }
  let sums : Array[Double] = Array(capacity=k * dim)
  for _ in 0..<(k * dim) {
    sums.push(0.0)
  }
  let counts : Array[Int] = Array(capacity=k)
  for _ in 0..<k {
    counts.push(0)
  }
  for _ in 0..<iters {
    for i in 0..<(k * dim) {
      sums[i] = 0.0
    }
    for c in 0..<k {
      counts[c] = 0
    }
    // 分配：归一化中心内积最大 = cosine 距离最小；euclidean 时 l2sq 最小
    for si in 0..<sample_n {
      let v = docs[idx[si]].vector
      let mut best = 0
      let mut best_d = if euclidean {
        @core.l2sq_f32(v, 0, data, 0, dim)
      } else {
        @core.cosine_dist_f32(v, 0, data, 0, dim)
      }
      for c in 1..<k {
        let d = if euclidean {
          @core.l2sq_f32(v, 0, data, c * dim, dim)
        } else {
          @core.cosine_dist_f32(v, 0, data, c * dim, dim)
        }
        if d < best_d {
          best_d = d
          best = c
        }
      }
      counts[best] = counts[best] + 1
      let base = best * dim
      for f in 0..<dim {
        sums[base + f] = sums[base + f] + v[f].to_double()
      }
    }
    // 更新：均值 → （cosine）归一化；空簇用随机样本重置
    for c in 0..<k {
      let base = c * dim
      if counts[c] == 0 {
        let v = docs[idx[(rng.next_u32() % sample_n.reinterpret_as_uint()).reinterpret_as_int()]].vector
        for f in 0..<dim {
          data[base + f] = v[f]
        }
      } else {
        for f in 0..<dim {
          data[base + f] = Float::from_double(
            sums[base + f] / counts[c].to_double(),
          )
        }
      }
      if !euclidean {
        normalize_center(data, base, dim)
      }
    }
  }
  { dim, data }
}
