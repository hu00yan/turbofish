// PQ16 码本训练（vec_storage=VPq16）。
//
// 与 IVF 一致采用 cosine 语义：先对整向量 L2 归一化，再按子空间做 L2 kmeans
// （归一化后 L2 距离与 cosine 单调等价）。码本与 codes 的二进制布局见
// format/quant.mbt（SPNDPQP1）。
//
// 训练参数：m=16（dim 不整除时向下取可整除的 m）、dsub=dim/m、
// 每子空间 k=256（样本不足时收缩到样本数）、iters=8、采样 ≤512 行（取 512
// 控制构建时间；对 10k 行数据 codebook 已足够稳定）。
// 确定性：@core.Rng 固定种子 4242。

///|
const PQ_M_MAX : Int = 16

///|
const PQ_K : Int = 256

///|
const PQ_ITERS : Int = 8

///|
const PQ_SAMPLE_MAX : Int = 512

///|
const PQ_SEED : UInt = 4242U

///|
/// dim 可用的最大子量化器个数（≤16 且整除 dim）。
fn pq_m_for(dim : Int) -> Int {
  let mut m = if dim < PQ_M_MAX { dim } else { PQ_M_MAX }
  while m > 1 && dim % m != 0 {
    m -= 1
  }
  m
}

///|
/// 整向量 L2 归一化（零向量原样保留）。
fn pq_normalize(data : Array[Float], dim : Int) -> Array[Float] {
  let count = if dim > 0 { data.length() / dim } else { 0 }
  let out : Array[Float] = Array(capacity=count * dim)
  for i in 0..<count {
    let norm = @core.norm_f32(data, i * dim, dim)
    for d in 0..<dim {
      let v = data[i * dim + d]
      out.push(
        if norm > 0.0 {
          Float::from_double(v.to_double() / norm)
        } else {
          v
        },
      )
    }
  }
  out
}

///|
/// 单子空间 kmeans（L2）。samples 是 n×dsub 行主序；返回 k×dsub 中心。
fn pq_kmeans(
  samples : Array[Float],
  n : Int,
  dsub : Int,
  k : Int,
  iters : Int,
  seed : UInt,
) -> Array[Float] {
  if n == 0 || dsub == 0 || k <= 0 {
    return []
  }
  let rng = @core.Rng::new(seed)
  // 随机初始化：取 k 个不同样本（k ≤ n）
  let idx : Array[Int] = Array(capacity=n)
  for i in 0..<n {
    idx.push(i)
  }
  for i in 0..<k {
    let j = i +
      (rng.next_u32() % (n - i).reinterpret_as_uint()).reinterpret_as_int()
    let t = idx[i]
    idx[i] = idx[j]
    idx[j] = t
  }
  let centers : Array[Float] = Array(capacity=k * dsub)
  for c in 0..<k {
    for d in 0..<dsub {
      centers.push(samples[idx[c] * dsub + d])
    }
  }
  let sums : Array[Double] = Array(capacity=k * dsub)
  for _ in 0..<(k * dsub) {
    sums.push(0.0)
  }
  let counts : Array[Int] = Array(capacity=k)
  for _ in 0..<k {
    counts.push(0)
  }
  for _ in 0..<iters {
    for i in 0..<(k * dsub) {
      sums[i] = 0.0
    }
    for c in 0..<k {
      counts[c] = 0
    }
    for si in 0..<n {
      let base = si * dsub
      let mut best = 0
      let mut best_d = 0.0
      for d in 0..<dsub {
        let diff = samples[base + d].to_double() - centers[d].to_double()
        best_d += diff * diff
      }
      for c in 1..<k {
        let cb = c * dsub
        let mut dist = 0.0
        for d in 0..<dsub {
          let diff = samples[base + d].to_double() - centers[cb + d].to_double()
          dist += diff * diff
        }
        if dist < best_d {
          best_d = dist
          best = c
        }
      }
      counts[best] = counts[best] + 1
      let cb = best * dsub
      for d in 0..<dsub {
        sums[cb + d] = sums[cb + d] + samples[base + d].to_double()
      }
    }
    for c in 0..<k {
      let cb = c * dsub
      if counts[c] == 0 {
        let r = (rng.next_u32() % n.reinterpret_as_uint()).reinterpret_as_int()
        for d in 0..<dsub {
          centers[cb + d] = samples[r * dsub + d]
        }
      } else {
        for d in 0..<dsub {
          centers[cb + d] = Float::from_double(
            sums[cb + d] / counts[c].to_double(),
          )
        }
      }
    }
  }
  centers
}

///|
/// 训练 PQ16：返回（codebooks m×256×dsub 行主序, codes count×m）。
/// data 为 count×dim 行主序。
pub fn train_pq(dim : Int, data : Array[Float]) -> (Array[Float], Array[UInt]) {
  let count = if dim > 0 { data.length() / dim } else { 0 }
  if count == 0 || dim == 0 {
    return ([], [])
  }
  let m = pq_m_for(dim)
  let dsub = dim / m
  let norm = pq_normalize(data, dim)
  let sample_n = if PQ_SAMPLE_MAX < count { PQ_SAMPLE_MAX } else { count }
  let rng = @core.Rng::new(PQ_SEED)
  // 部分 Fisher-Yates 选样本
  let idx : Array[Int] = Array(capacity=count)
  for i in 0..<count {
    idx.push(i)
  }
  for i in 0..<sample_n {
    let j = i +
      (rng.next_u32() % (count - i).reinterpret_as_uint()).reinterpret_as_int()
    let t = idx[i]
    idx[i] = idx[j]
    idx[j] = t
  }
  let codebooks : Array[Float] = Array(capacity=m * PQ_K * dsub)
  let codes : Array[UInt] = Array(capacity=count * m)
  for _ in 0..<(count * m) {
    codes.push(0U)
  }
  for c in 0..<m {
    let samples : Array[Float] = Array(capacity=sample_n * dsub)
    for si in 0..<sample_n {
      let row = idx[si]
      for d in 0..<dsub {
        samples.push(norm[row * dim + c * dsub + d])
      }
    }
    let k = if PQ_K < sample_n { PQ_K } else { sample_n }
    let centers = pq_kmeans(
      samples,
      sample_n,
      dsub,
      k,
      PQ_ITERS,
      PQ_SEED + c.reinterpret_as_uint(),
    )
    // 码本定长 256×dsub，k < 256 时补零
    for j in 0..<PQ_K {
      for d in 0..<dsub {
        codebooks.push(if j < k { centers[j * dsub + d] } else { 0.0 })
      }
    }
    // 全部行编码（在归一化向量上做最近中心分配）
    for row in 0..<count {
      let base = row * dim + c * dsub
      let mut best = 0
      let mut best_d = 0.0
      for d in 0..<dsub {
        let diff = norm[base + d].to_double() - centers[d].to_double()
        best_d += diff * diff
      }
      for j in 1..<k {
        let cb = j * dsub
        let mut dist = 0.0
        for d in 0..<dsub {
          let diff = norm[base + d].to_double() - centers[cb + d].to_double()
          dist += diff * diff
        }
        if dist < best_d {
          best_d = dist
          best = j
        }
      }
      codes[row * m + c] = best.reinterpret_as_uint()
    }
  }
  (codebooks, codes)
}
