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
/// balanced k-means 容量约束 slack：每簇训练样本上限
/// `ceil(sample_n/k) × KMEANS_CAPACITY_SLACK`（1.25 = 允许簇超均值 25%）。
/// 等大小约束把簇行数偏置 E[s²]/E[s] 压向 mean ⇒ 每 probe 字节从
/// `E[s²]/E[s]×行字节`（尺寸偏置，≈4×mean）压到 `mean×行字节`。
pub const KMEANS_CAPACITY_SLACK : Double = 1.25

///|
/// 平衡分配每样本保留的候选簇数上界（全局距离升序贪心的截断深度；超过
/// 前 K 的候选只有在前 K 全满时才会用到，此时由兜底扫描补位）。
pub const KMEANS_TOP_C : Int = 128

///|
///|
/// Lloyd kmeans（balanced 等大小约束）：
/// - 确定性采样 min(nlist*8, docs.length()) 条向量（Rng 种子 42）
/// - k 收缩为 min(nlist, 样本数)，避免重复中心导致的常驻空簇
/// - 迭代 iters 轮：分配（所有 (样本, 簇) 候选对按距离全局升序贪心：
///   样本未分配且簇未满则落位；簇满则落到该样本次近的未满簇）
///   → 均值更新 → （cosine 时）归一化
/// - 空簇用「离当前中心最远的样本点」重置（确定性；比随机样本更能
///   打散簇行数分布——簇越均衡，probe 命中行数的尺寸偏置
///   E[size²]/E[size] 越小，冷 vec KB/q 越低）
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
  // 每簇容量上限（等大小约束）：ceil(sample_n/k) × KMEANS_CAPACITY_SLACK，
  // floor 取整。floor(1.25m) ≥ m = ceil(sample_n/k) ⇒ k×cap ≥ sample_n，
  // 贪心分配恒有未满簇可放（cap ≥ 1）。
  let m = (sample_n + k - 1) / k
  let cap = (m.to_double() * KMEANS_CAPACITY_SLACK).floor().to_int()
  // 平衡分配的全局距离升序贪心缓冲：每样本保留最近 ctop 个候选（距离+簇号），
  // 全部样本的 top-c 候选对做距离→桶计数排序（升序、确定性），再按序落位。
  // 内存 O(sample_n × ctop)；候选表之外的簇仅在前 ctop 全满时经兜底扫描补。
  let ctop = if k < KMEANS_TOP_C { k } else { KMEANS_TOP_C }
  let scratch : Array[(Double, Int)] = Array(capacity=k)
  for _ in 0..<k {
    scratch.push((0.0, 0))
  }
  let pair_n = sample_n * ctop
  let top_d : Array[Double] = Array(capacity=pair_n)
  for _ in 0..<pair_n {
    top_d.push(0.0)
  }
  let top_c : Array[Int] = Array(capacity=pair_n)
  let order : Array[Int] = Array(capacity=pair_n)
  for _ in 0..<pair_n {
    top_c.push(0)
    order.push(0)
  }
  let assigned : Array[Int] = Array(capacity=sample_n)
  for _ in 0..<sample_n {
    assigned.push(-1)
  }
  let nb = 65536
  let bcounts : Array[Int] = Array(capacity=nb)
  for _ in 0..<nb {
    bcounts.push(0)
  }
  let sums : Array[Double] = Array(capacity=k * dim)
  for _ in 0..<(k * dim) {
    sums.push(0.0)
  }
  let counts : Array[Int] = Array(capacity=k)
  for _ in 0..<k {
    counts.push(0)
  }
  // 分配时同步维护「离当前中心最远的样本」候选（按 best_d 降序前 k 个），
  // 供空簇确定性重置；不额外遍历样本。
  let far_d : Array[Double] = Array(capacity=k)
  let far_i : Array[Int] = Array(capacity=k)
  for _ in 0..<k {
    far_d.push(-1.0)
    far_i.push(-1)
  }
  let consider_far = fn(d : Double, si : Int) -> Unit {
    // 插入到 far_d 降序的前 k 位（k 个候选足够覆盖单轮空簇数）
    if d <= far_d[k - 1] {
      return
    }
    let mut pos = k - 1
    while pos > 0 && far_d[pos - 1] < d {
      far_d[pos] = far_d[pos - 1]
      far_i[pos] = far_i[pos - 1]
      pos = pos - 1
    }
    far_d[pos] = d
    far_i[pos] = si
  }
  for _ in 0..<iters {
    for i in 0..<(k * dim) {
      sums[i] = 0.0
    }
    for c in 0..<k {
      counts[c] = 0
    }
    for i in 0..<k {
      far_d[i] = -1.0
      far_i[i] = -1
    }
    for i in 0..<sample_n {
      assigned[i] = -1
    }
    // 分配（带容量，全局按距离升序贪心）：
    // 1) 每样本按距离升序取前 ctop 个候选簇（归一化中心内积最大 =
    //    cosine 距离最小；euclidean 时 l2sq 最小）；
    for si in 0..<sample_n {
      let v = docs[idx[si]].vector
      for c in 0..<k {
        let d = if euclidean {
          @core.l2sq_f32(v, 0, data, c * dim, dim)
        } else {
          @core.cosine_dist_f32(v, 0, data, c * dim, dim)
        }
        scratch[c] = (d, c)
      }
      scratch.sort_by(fn(a, b) {
        let cmp = a.0.compare(b.0)
        if cmp != 0 {
          cmp
        } else {
          a.1.compare(b.1)
        }
      })
      let base = si * ctop
      for r in 0..<ctop {
        let (d, c) = scratch[r]
        top_d[base + r] = d
        top_c[base + r] = c
      }
    }
    // 2) 全部候选对按距离升序（桶计数排序近似全排序，同桶内按 (样本, 序)
    //    升序，确定性）；
    let mut max_d = 0.0
    for p in 0..<pair_n {
      let d = top_d[p]
      if d > max_d {
        max_d = d
      }
    }
    let scale = if max_d > 0.0 {
      (nb.to_double() - 1.0) / max_d
    } else {
      0.0
    }
    for b in 0..<nb {
      bcounts[b] = 0
    }
    for p in 0..<pair_n {
      let b = (top_d[p] * scale).to_int()
      bcounts[b] = bcounts[b] + 1
    }
    let mut acc = 0
    for b in 0..<nb {
      let n = bcounts[b]
      bcounts[b] = acc
      acc = acc + n
    }
    for p in 0..<pair_n {
      let b = (top_d[p] * scale).to_int()
      order[bcounts[b]] = p
      bcounts[b] = bcounts[b] + 1
    }
    // 3) 按升序贪心落位：样本已分配或簇已满则跳过——簇满则该样本落到其
    //    候选表中下一个（次近）未满簇。
    for slot in 0..<pair_n {
      let p = order[slot]
      let si = p / ctop
      let c = top_c[p]
      if assigned[si] >= 0 || counts[c] >= cap {
        continue
      }
      assigned[si] = c
      counts[c] = counts[c] + 1
      let d = top_d[p]
      consider_far(d, si)
      let base = c * dim
      let v = docs[idx[si]].vector
      for f in 0..<dim {
        sums[base + f] = sums[base + f] + v[f].to_double()
      }
    }
    // 兜底：候选表前 ctop 全满的样本（cap ≥ 1 且 k×cap ≥ sample_n 时极罕见）
    // ——全量扫最近未满簇。
    for si in 0..<sample_n {
      if assigned[si] < 0 {
        let v = docs[idx[si]].vector
        let mut best = -1
        let mut best_d = 0.0
        for c in 0..<k {
          let d = if euclidean {
            @core.l2sq_f32(v, 0, data, c * dim, dim)
          } else {
            @core.cosine_dist_f32(v, 0, data, c * dim, dim)
          }
          if counts[c] < cap && (best < 0 || d < best_d) {
            best = c
            best_d = d
          }
        }
        if best < 0 {
          // 理论不可达：全部满也得放——取距离最小簇。
          best = 0
          best_d = if euclidean {
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
        }
        assigned[si] = best
        counts[best] = counts[best] + 1
        consider_far(best_d, si)
        let base = best * dim
        for f in 0..<dim {
          sums[base + f] = sums[base + f] + v[f].to_double()
        }
      }
    }
    // 更新：均值 → （cosine）归一化；空簇用「离当前中心最远的样本点」
    // 确定性重置（far 按 best_d 降序，多个空簇取不同的远点）。
    let mut far_slot = 0
    for c in 0..<k {
      let base = c * dim
      if counts[c] == 0 {
        let mut si = far_i[far_slot]
        if si < 0 {
          si = (rng.next_u32() % sample_n.reinterpret_as_uint()).reinterpret_as_int()
        }
        far_slot = far_slot + 1
        let v = docs[idx[si]].vector
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
