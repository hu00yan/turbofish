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
      out.push((v[i].to_double() / norm).to_float())
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
      data[base + i] = (data[base + i].to_double() / norm).to_float()
    }
  }
}

///|
/// Lloyd kmeans（cosine）：
/// - 确定性采样 min(nlist*8, docs.length()) 条向量（Rng 种子 42）
/// - k 收缩为 min(nlist, 样本数)，避免重复中心导致的常驻空簇
/// - 迭代 iters 轮：分配（cosine 距离最小）→ 均值更新 → 归一化
/// - 空簇用随机样本重置
/// - docs 为空 / dim 为 0 / nlist<=0 时返回空中心（dim=0 或 k=0）
pub fn train_centroids(
  docs : Array[@core.Doc],
  nlist : Int,
  iters : Int,
) -> @format.Centroids {
  if docs.length() == 0 {
    return { dim: 0, data: [] }
  }
  let dim = docs[0].vector.length()
  if dim == 0 || nlist <= 0 {
    return { dim, data: [] }
  }
  let n = docs.length()
  let sample_n = if nlist * 8 < n {
    nlist * 8
  } else {
    n
  }
  let k = if nlist < sample_n {
    nlist
  } else {
    sample_n
  }
  let rng = @core.Rng::new(42U)
  // 部分 Fisher-Yates：idx 前 sample_n 个即确定性采样结果
  let idx : Array[Int] = Array::new(capacity=n)
  for i in 0..<n {
    idx.push(i)
  }
  for i in 0..<sample_n {
    // 注意 UInt::to_int 是位重解释：先在 UInt 域取模再转 Int，避免高位翻负
    let j = i + (rng.next_u32() % (n - i).to_uint()).to_int()
    let t = idx[i]
    idx[i] = idx[j]
    idx[j] = t
  }
  // 中心初始化：取前 k 个样本（归一化）
  let data : Array[Float] = Array::new(capacity=k * dim)
  for c in 0..<k {
    append_normalized(data, docs[idx[c]].vector, dim)
  }
  let sums : Array[Double] = Array::new(capacity=k * dim)
  for _ in 0..<(k * dim) {
    sums.push(0.0)
  }
  let counts : Array[Int] = Array::new(capacity=k)
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
    // 分配：与归一化中心的内积最大 = cosine 距离最小
    for si in 0..<sample_n {
      let v = docs[idx[si]].vector
      let mut best = 0
      let mut best_d = @core.cosine_dist_f32(v, 0, data, 0, dim)
      for c in 1..<k {
        let d = @core.cosine_dist_f32(v, 0, data, c * dim, dim)
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
    // 更新：均值 → 归一化；空簇用随机样本重置
    for c in 0..<k {
      let base = c * dim
      if counts[c] == 0 {
        let v = docs[idx[(rng.next_u32() % sample_n.to_uint()).to_int()]].vector
        for f in 0..<dim {
          data[base + f] = v[f]
        }
      } else {
        for f in 0..<dim {
          data[base + f] = (sums[base + f] / counts[c].to_double()).to_float()
        }
      }
      normalize_center(data, base, dim)
    }
  }
  { dim, data }
}
