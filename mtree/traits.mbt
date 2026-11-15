// 拔插三接口：PartStore / ManifestStore / MergePolicy。
// MergeTree 引擎只通过这三个 trait 触达存储与策略，不直接调 put/get。

///|
/// Part 的清单元数据（manifest 持有；读路径用它做二分定位，不用 GET part）。
#derive(Debug, Eq)
pub(all) struct PartMeta {
  part_id : String // PartStore 内容哈希 id（put_part 的返回值）
  level : Int // 0 = L0 delta part，1 = consolidated base part（或更高层）
  row_count : Int
  min_id : UInt64
  max_id : UInt64
  size_bytes : Int // part 对象字节数（写放大/分桶口径）
  mut tombstone_count : Int // 本 part 内已标记删除的墓碑行数
}

///|
/// 不可变 part 的存取。对象存储实现 = @store.ObjectStore 上做内容寻址。
pub(open) trait PartStore {
  /// PUT 一个 part 对象，返回内容哈希 PartId。同 bytes 两次调用必须返回
  /// 同一 id（幂等）；不同 bytes 返回不同 id。
  fn put_part(Self, Bytes) -> String
  /// 按 id 读 part；不存在返回 None。
  fn get_part(Self, String) -> Bytes?
  /// 按 id 范围读 [offset, offset + len)；用于 Footer 索引与列/倒排切片按需 Range GET。
  fn get_part_range(Self, String, Int, Int) -> Bytes?
}

///|
#derive(Debug, Eq)
pub(all) struct Manifest {
  mut seq : UInt64
  parts : Array[PartMeta]
  tombstones : Array[UInt64]
}

///|
pub fn Manifest::new() -> Manifest {
  { seq: 0UL, parts: [], tombstones: [] }
}

///|
pub fn Manifest::is_deleted(self : Manifest, id : UInt64) -> Bool {
  let mask = self.tombstone_mask()
  @format.roaring_contains(mask, id)
}

///|
pub fn Manifest::tombstone_mask(self : Manifest) -> Bytes {
  @format.encode_roaring(self.tombstones)
}

///|
pub fn Manifest::l0_count(self : Manifest) -> Int {
  let mut count = 0
  for p in self.parts {
    if p.level == 0 {
      count += 1
    }
  }
  count
}

///|
pub fn Manifest::total_rows(self : Manifest) -> Int {
  let mut rows = 0
  for p in self.parts {
    rows += p.row_count
  }
  rows
}

///|
pub fn Manifest::tombstone_ratio(_self : Manifest, part : PartMeta) -> Double {
  if part.row_count == 0 {
    0.0
  } else {
    part.tombstone_count.to_double() / part.row_count.to_double()
  }
}

///|
/// manifest 原子换代。默认实现 HeadManifestStore 用本包的
/// Manifest；实现负责并发仲裁（CAS/head-log），输家必须 raise CommitConflict。
pub(open) trait ManifestStore {
  /// 读当前 manifest（空 namespace 返回空 Manifest）。
  fn load(Self) -> Manifest raise @core.SpndError
  /// 原子换代发布；与并发写者冲突时 raise @core.CommitConflict。
  fn publish(Self, Manifest) -> Unit raise @core.SpndError
}

///|
/// 可插拔合并策略：tiered（本包 TieredPolicy）/ leveled（后续实验）。
pub(open) trait MergePolicy {
  /// 返回本轮要 merge 的 part id 集合；None = 本轮不合并。
  fn pick(self : Self, parts : Array[PartMeta]) -> Array[String]?
}


pub extend PartMeta with Debug::{to_repr}
pub extend PartMeta with Eq::{not_equal, equal}
pub extend Manifest with Debug::{to_repr}
pub extend Manifest with Eq::{not_equal, equal}
